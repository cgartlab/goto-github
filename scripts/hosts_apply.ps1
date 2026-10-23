#Requires -Version 5.1
<#
.SYNOPSIS
    Phase 3 hosts repair for the goto-github skill (WRITES the hosts file).

.DESCRIPTION
    Writes the goto-github marker block into the Windows hosts file.
    Strategy chain: priority IPs -> community sources -> CIDR scan.

    Safety (see references/safety-and-boundaries.md -- non-negotiable):
      - backup before any write; abort if the backup fails
      - shadowing check before AND after the write
      - never edit outside the marker block
      - idempotent: re-running never produces duplicate blocks
      - probe target is the git smart-http endpoint, NOT the homepage
      - no automatic UAC elevation; report the command instead

.PARAMETER Strategy
    Force one strategy: priority, community, cidr, or auto (default).

.PARAMETER Help
    Show this help.

.EXAMPLE
    .\scripts\hosts_apply.ps1 -Strategy priority
#>
[CmdletBinding()]
param(
    [ValidateSet('priority', 'community', 'cidr', 'auto')]
    [string]$Strategy = 'auto',
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

$showHelp = {
    Write-Output @'
Usage: hosts_apply.ps1 [-Strategy priority|community|cidr|auto] [-Help]

Phase 3 hosts repair for the goto-github skill. WRITES the hosts file.

Strategy chain (auto = try in order, stop at first success):
  priority    known-stable IPs only (seconds)
  community   pull a verified hosts list from community sources
  cidr        expand CIDR ranges and probe concurrently (minutes)

Safety: backs up before writing, checks for shadowing, only edits inside
the marker block, idempotent. Does NOT auto-elevate.

Requires administrator privileges.

Environment:
  HOSTS_FILE  hosts file path (default: %SystemRoot%\System32\drivers\etc\hosts)
  PROBE_REPO  owner/repo for the git probe endpoint
'@
}

if ($Help) { & $showHelp; exit 0 }

# -- Resolve repo root and load the skill's own constants ---------------------
# scripts/lib/constants.ps1 is the skill layer's single source of truth. It is
# deliberately independent of ps1/lib/00-constants.ps1 (which belongs to the
# scan-based CLI and lacks SOURCES / KEEP_BACKUPS / PROBE_TEST_CAP).
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib\constants.ps1')

# constants.ps1 assigns into its own script scope; re-read the values here so
# this script's scope has them (dot-sourcing does not merge scopes).
$script:HostsFile = $script:HOSTS_FILE
$script:ProbeRepo = $script:PROBE_REPO

# Probe target: git smart-http, NOT the homepage. Some edge IPs serve the
# homepage but time out on git traffic, so a homepage probe selects
# "false positive" IPs that break clone/fetch/push.
$script:GitProbeTarget = "https://github.com/$script:ProbeRepo/info/refs?service=git-upload-pack"

$script:Warnings = New-Object System.Collections.Generic.List[string]
function Add-Warning {
    param([string]$Message)
    $script:Warnings.Add($Message) | Out-Null
}

function ConvertTo-JsonLiteral {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return 'null' }
    $v = $Value.Replace('\', '\\').Replace('"', '\"')
    $v = $v.Replace("`r", '').Replace("`n", '\n').Replace("`t", '\t')
    return "`"$v`""
}

function ConvertTo-WarningsJson {
    param([System.Collections.Generic.List[string]]$Warnings)
    if (-not $Warnings -or $Warnings.Count -eq 0) { return '[]' }
    return '[' + (($Warnings | ForEach-Object { ConvertTo-JsonLiteral $_ }) -join ',') + ']'
}

function Emit-Result {
    param(
        [bool]$Applied,
        [string]$UsedStrategy,
        [string]$Ip,
        [int]$Entries,
        [string]$Backup,
        [bool]$ShadowChecked,
        [bool]$ShadowFound,
        [string]$ShadowDetail,
        [bool]$DnsFlushed
    )
    $strategyLit = if ([string]::IsNullOrEmpty($UsedStrategy)) { 'null' } else { "`"$UsedStrategy`"" }
    $json = '{'
    $json += '"applied":' + $Applied.ToString().ToLower() + ','
    $json += '"strategy":' + $strategyLit + ','
    $json += '"ip":' + (ConvertTo-JsonLiteral $Ip) + ','
    $json += '"entries_written":' + $Entries + ','
    $json += '"backup":' + (ConvertTo-JsonLiteral $Backup) + ','
    $json += '"shadowing":{"checked":' + $ShadowChecked.ToString().ToLower() + ',"found":' + $ShadowFound.ToString().ToLower() + ',"detail":' + (ConvertTo-JsonLiteral $ShadowDetail) + '},'
    $json += '"dns_flushed":' + $DnsFlushed.ToString().ToLower() + ','
    $json += '"warnings":' + (ConvertTo-WarningsJson $script:Warnings)
    $json += '}'
    [Console]::Out.Write($json)
}

function Get-CurlPath {
    try { return (Get-Command curl.exe -ErrorAction Stop).Source } catch { return $null }
}

# -- Privilege (no auto-elevation) --------------------------------------------
# GOTO_GITHUB_TEST_PRIVILEGED=1 skips the check so the write path can be
# exercised against a temp HOSTS_FILE in CI. It grants no real privilege --
# writing a system hosts file still fails without admin rights.
function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = [Security.Principal.WindowsPrincipal]$id
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Test-CanWriteHosts {
    if ($env:GOTO_GITHUB_TEST_PRIVILEGED -eq '1') { return $true }
    return (Test-IsAdmin)
}

# -- Shadowing detection ------------------------------------------------------
# hosts resolves the FIRST match, so another tool's github.com entry ABOVE our
# marker makes the whole block inert. Report it; never edit outside the block.
function Get-ShadowingState {
    param([string[]]$Lines, [int]$MarkerStartIndex)

    for ($i = 0; $i -lt $MarkerStartIndex; $i++) {
        if ($Lines[$i] -match '^\s*\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\s+github\.com(\s|$)') {
            return $Lines[$i].Trim()
        }
    }
    return $null
}

# -- Probe one IP against the git endpoint ------------------------------------
function Test-IpForGit {
    param([string]$Ip)

    $curl = Get-CurlPath
    if (-not $curl) { return $false }

    # --resolve forces the IP while SNI still routes to github.com, so the IP
    # must actually serve that Host. A 2xx from the git endpoint is the only
    # acceptable answer -- the homepage can lie.
    $code = & $curl --noproxy '*' -s -o NUL `
        --connect-timeout 3 --max-time 6 `
        -w '%{http_code}' `
        -H 'Accept: application/x-git-upload-pack-advertisement' `
        $script:GitProbeTarget `
        --resolve "github.com:443:$Ip" 2>$null

    return ("$code" -match '^2')
}

# -- Strategy 1: priority IPs -------------------------------------------------
function Find-PriorityIp {
    foreach ($ip in $script:PRIORITY_IPS) {
        if (Test-IpForGit -Ip $ip) { return $ip }
    }
    return $null
}

# -- Strategy 2: community sources --------------------------------------------
function Find-CommunityIp {
    $curl = Get-CurlPath
    if (-not $curl) { return $null }

    $pool = New-Object System.Collections.Generic.List[string]
    foreach ($url in $script:SOURCES) {
        try {
            $raw = & $curl -sfL --noproxy '*' --connect-timeout 8 --max-time 20 $url 2>$null
        } catch { continue }
        if (-not $raw) { continue }

        foreach ($line in ($raw -split "`n")) {
            if ($line -match '^\s*(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s') {
                $pool.Add($Matches[1]) | Out-Null
            }
        }
        if ($pool.Count -gt 0) { break }
    }
    if ($pool.Count -eq 0) { return $null }

    $seen = @{}
    foreach ($ip in $pool) {
        if ($seen.ContainsKey($ip)) { continue }
        $seen[$ip] = $true
        if (Test-IpForGit -Ip $ip) { return $ip }
    }
    return $null
}

# -- Strategy 3: CIDR scan (last resort) --------------------------------------
function Expand-CidrToIPs {
    <#
    .SYNOPSIS
        Expand CIDR ranges to usable host IPs (excludes network/broadcast).
    .DESCRIPTION
        Local copy of the CLI's Expand-CidrToIPs. Duplicated rather than
        dot-sourced because ps1/lib/02-scan.ps1 pulls in the whole scan stack
        (Write-Log, Find-Curl, ...) that this script does not need.
    #>
    param([string[]]$Cidrs)

    $ips = New-Object System.Collections.Generic.List[string]
    foreach ($cidr in $Cidrs) {
        $parts = $cidr -split '/'
        $baseIp = $parts[0]
        $prefix = [int]$parts[1]
        if ($prefix -lt 1 -or $prefix -gt 32) { continue }

        $b = [System.Net.IPAddress]::Parse($baseIp).GetAddressBytes()
        [array]::Reverse($b)
        $baseInt = [System.BitConverter]::ToUInt32($b, 0)

        $hostBits = 32 - $prefix
        $total = [math]::Pow(2, $hostBits)
        # /31 and /32 have no network/broadcast to exclude
        $first = if ($prefix -ge 31) { 0 } else { 1 }
        $last = if ($prefix -ge 31) { [int]$total - 1 } else { [int]$total - 2 }

        for ($i = $first; $i -le $last; $i++) {
            $v = $baseInt + $i
            $vb = [System.BitConverter]::GetBytes([uint32]$v)
            [array]::Reverse($vb)
            $ips.Add(([System.Net.IPAddress]$vb).ToString()) | Out-Null
        }
    }
    return $ips
}

function Find-CidrIp {
    $curl = Get-CurlPath
    if (-not $curl) { return $null }

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($range in $script:CIDR_RANGES) {
        $expanded = Expand-CidrToIPs -Cidrs @($range)
        foreach ($ip in $expanded) {
            if ($candidates.Count -ge $script:PROBE_TEST_CAP) { break }
            $candidates.Add($ip) | Out-Null
        }
    }
    if ($candidates.Count -eq 0) { return $null }

    # Runspace pool, not ForEach-Object -Parallel: -Parallel is PowerShell 7+
    # only, and this skill must run on Windows PowerShell 5.1 (the Windows
    # default). Runspace pools exist in both.
    return (Find-IpInParallel -Candidates $candidates.ToArray() -Curl $curl)
}

function Find-IpInParallel {
    <#
    .SYNOPSIS
        Probe candidate IPs concurrently and return the first that answers 2xx.
    .DESCRIPTION
        Uses a runspace pool so this works on PowerShell 5.1 and 7+ alike.
        Each runspace gets the values it needs as script arguments -- runspaces
        do not share the caller's scope.
    #>
    param(
        [string[]]$Candidates,
        [string]$Curl
    )

    $target = $script:GitProbeTarget
    $timeout = $script:CONNECT_TIMEOUT
    $maxTime = $script:MAX_TIME
    $batch = [Math]::Min($script:CONCURRENT_BATCH, $Candidates.Count)

    $pool = [runspacefactory]::CreateRunspacePool(1, $batch)
    $pool.Open()

    $scriptBlock = {
        param($ip, $curlPath, $url, $ct, $mt)
        $code = & $curlPath --noproxy '*' -s -o NUL `
            --connect-timeout $ct --max-time $mt `
            -w '%{http_code}' `
            -H 'Accept: application/x-git-upload-pack-advertisement' `
            $url `
            --resolve "github.com:443:$ip" 2>$null
        if ("$code" -match '^2') { return $ip }
        return $null
    }

    try {
        $jobs = New-Object System.Collections.Generic.List[object]
        foreach ($ip in $Candidates) {
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            $null = $ps.AddScript($scriptBlock).AddArgument($ip).AddArgument($Curl).
                AddArgument($target).AddArgument($timeout).AddArgument($maxTime)
            $jobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke() })
        }

        foreach ($job in $jobs) {
            $out = $job.PS.EndInvoke($job.Handle)
            $job.PS.Dispose()
            if ($out -and $out.Count -gt 0) {
                $hit = @($out | Where-Object { $_ -and $_ -ne $null } | Select-Object -First 1)
                if ($hit.Count -gt 0) { return $hit[0] }
            }
        }
        return $null
    } finally {
        $pool.Close()
        $pool.Dispose()
    }
}

# -- Backup -------------------------------------------------------------------
function Backup-Hosts {
    $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
    $backupPath = "$script:HostsFile.goto-github.bak.$timestamp"
    try {
        Copy-Item -LiteralPath $script:HostsFile -Destination $backupPath -ErrorAction Stop
    } catch {
        Add-Warning "backup failed: $($_.Exception.Message); aborting without touching hosts"
        return $null
    }
    # Retain only the most recent KEEP_BACKUPS
    Get-ChildItem "$script:HostsFile.goto-github.bak.*" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $script:KEEP_BACKUPS |
        Remove-Item -ErrorAction SilentlyContinue
    return $backupPath
}

# -- Write the marker block ---------------------------------------------------
function Write-HostsBlock {
    param([string]$Ip)

    $lines = [System.IO.File]::ReadAllLines($script:HostsFile)
    $markerStart = $script:MARKER_START
    $markerEnd = $script:MARKER_END

    # Drop any existing block, keep everything else (idempotency).
    $out = New-Object System.Collections.Generic.List[string]
    $inBlock = $false
    foreach ($line in $lines) {
        if ($line -like "$markerStart*") { $inBlock = $true; continue }
        if ($line -like "$markerEnd*") { $inBlock = $false; continue }
        if (-not $inBlock) { $out.Add($line) | Out-Null }
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $null = $out.Add('')
    $null = $out.Add($markerStart)
    $null = $out.Add('# Managed by goto-github -- do not edit manually')
    $null = $out.Add("# Updated at $timestamp")
    $null = $out.Add("# Best IP: $Ip")
    foreach ($d in $script:CORE_DOMAINS) {
        $null = $out.Add("$Ip $d")
    }
    $null = $out.Add($markerEnd)

    # Atomic replace. File.Move(src, dst, overwrite) is .NET Core only -- the
    # three-argument overload does not exist in .NET Framework, which is what
    # Windows PowerShell 5.1 runs on ("Cannot find an overload for Move and the
    # argument count 3"). File.Replace is available on both and preserves the
    # destination's ACL, so it is the portable choice when the target exists.
    #
    # File.Replace also requires source and destination to be on the same
    # volume, so the temp file is created next to the hosts file rather than in
    # %TEMP% (which may be on another drive).
    $hostsDir = Split-Path -Parent $script:HostsFile
    $tempFile = Join-Path $hostsDir ('.goto-github-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllLines($tempFile, $out)

        if (Test-Path $script:HostsFile) {
            $backupForReplace = "$tempFile.orig"
            [System.IO.File]::Replace($tempFile, $script:HostsFile, $backupForReplace)
            if (Test-Path $backupForReplace) { Remove-Item $backupForReplace -Force -ErrorAction SilentlyContinue }
        } else {
            [System.IO.File]::Move($tempFile, $script:HostsFile)
        }
    } catch {
        if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
        throw "failed to write hosts file: $($_.Exception.Message)"
    }

    return ($script:CORE_DOMAINS.Count)
}

# -- DNS flush ----------------------------------------------------------------
function Invoke-DnsFlush {
    try {
        & ipconfig /flushdns 2>&1 | Out-Null
        Restart-Service -Name Dnscache -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        Add-Warning "DNS cache flush failed: $($_.Exception.Message); hosts is written but cached entries may persist"
        return $false
    }
}

# -- Main ---------------------------------------------------------------------
if (-not (Test-CanWriteHosts)) {
    # Report the command; never auto-elevate. stderr, so stdout stays a clean
    # single JSON line.
    [Console]::Error.WriteLine("ERROR: writing the hosts file requires administrator privileges. Run PowerShell as Administrator and retry (this script does not auto-elevate).")
    Emit-Result -Applied $false -UsedStrategy $null -Ip $null -Entries 0 -Backup $null `
        -ShadowChecked $false -ShadowFound $false -ShadowDetail $null -DnsFlushed $false
    exit 1
}

if (-not (Test-Path $script:HostsFile)) {
    Add-Warning "hosts file not found: $script:HostsFile"
    Emit-Result -Applied $false -UsedStrategy $null -Ip $null -Entries 0 -Backup $null `
        -ShadowChecked $false -ShadowFound $false -ShadowDetail $null -DnsFlushed $false
    exit 1
}

# Shadowing check (before)
$shadowChecked = $true
$shadowFound = $false
$shadowDetail = $null
$lines = [System.IO.File]::ReadAllLines($script:HostsFile)
$startIdx = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -like "$($script:MARKER_START)*") { $startIdx = $i; break }
}
if ($startIdx -ge 0) {
    $hit = Get-ShadowingState -Lines $lines -MarkerStartIndex $startIdx
    if ($hit) {
        $shadowFound = $true
        $shadowDetail = $hit
        Add-Warning 'hosts has a github.com entry above the goto-github block; it takes precedence and our block will be inert'
    }
}

# Resolve strategy
$ip = $null
$usedStrategy = $null
switch ($Strategy) {
    'priority'  { $ip = Find-PriorityIp;   $usedStrategy = 'priority' }
    'community' { $ip = Find-CommunityIp;  $usedStrategy = 'community' }
    'cidr'      { $ip = Find-CidrIp;       $usedStrategy = 'cidr' }
    'auto' {
        $ip = Find-PriorityIp
        if ($ip) { $usedStrategy = 'priority' }
        else {
            $ip = Find-CommunityIp
            if ($ip) { $usedStrategy = 'community' }
            else {
                $ip = Find-CidrIp
                if ($ip) { $usedStrategy = 'cidr' }
            }
        }
    }
}

# Test hook: GOTO_GITHUB_FORCE_IP bypasses probing so the write path can be
# exercised deterministically in CI. Grants no privilege.
if ($env:GOTO_GITHUB_FORCE_IP) {
    $ip = $env:GOTO_GITHUB_FORCE_IP
    $usedStrategy = 'forced'
}

if (-not $ip) {
    Add-Warning "no working GitHub IP found via strategy '$Strategy'"
    Emit-Result -Applied $false -UsedStrategy $usedStrategy -Ip $null -Entries 0 -Backup $null `
        -ShadowChecked $shadowChecked -ShadowFound $shadowFound -ShadowDetail $shadowDetail -DnsFlushed $false
    exit 1
}

Write-Verbose "selected IP: $ip (strategy: $usedStrategy)"

# Backup BEFORE any write. No backup -> no write.
$backup = Backup-Hosts
if (-not $backup) {
    Emit-Result -Applied $false -UsedStrategy $usedStrategy -Ip $ip -Entries 0 -Backup $null `
        -ShadowChecked $shadowChecked -ShadowFound $shadowFound -ShadowDetail $shadowDetail -DnsFlushed $false
    exit 1
}

try {
    $entries = Write-HostsBlock -Ip $ip
} catch {
    Add-Warning $_.Exception.Message
    Emit-Result -Applied $false -UsedStrategy $usedStrategy -Ip $ip -Entries 0 -Backup $backup `
        -ShadowChecked $shadowChecked -ShadowFound $shadowFound -ShadowDetail $shadowDetail -DnsFlushed $false
    exit 1
}

# Shadowing check (after) -- the write cannot have introduced one, but the
# block position may have moved relative to other entries.
if ($startIdx -ge 0) {
    $lines2 = [System.IO.File]::ReadAllLines($script:HostsFile)
    $start2 = -1
    for ($i = 0; $i -lt $lines2.Count; $i++) {
        if ($lines2[$i] -like "$($script:MARKER_START)*") { $start2 = $i; break }
    }
    if ($start2 -ge 0) {
        $hit2 = Get-ShadowingState -Lines $lines2 -MarkerStartIndex $start2
        if ($hit2) {
            $shadowFound = $true
            $shadowDetail = $hit2
        }
    }
}

$dnsFlushed = Invoke-DnsFlush

Emit-Result -Applied $true -UsedStrategy $usedStrategy -Ip $ip -Entries $entries -Backup $backup `
    -ShadowChecked $shadowChecked -ShadowFound $shadowFound -ShadowDetail $shadowDetail -DnsFlushed $dnsFlushed
