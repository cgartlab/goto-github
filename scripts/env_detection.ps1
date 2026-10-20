#Requires -Version 5.1
<#
.SYNOPSIS
    Phase 0 environment probe for the goto-github skill (read-only).

.DESCRIPTION
    Detects shell, platform, curl availability, hosts marker block and
    shadowing, proxy state, DNS servers, gh auth state, and privilege level.
    Emits single-line JSON to stdout. Never writes anything.

.PARAMETER Help
    Show this help.

.EXAMPLE
    .\scripts\env_detection.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# ── Resolve repo root (scripts/ -> repo root) ────────────────────────────────
$script:RepoRoot = Split-Path -Parent $PSScriptRoot

# ── Shared constants ─────────────────────────────────────────────────────────
# The PowerShell constants live in ps1/lib/ (the PowerShell implementation);
# lib/ holds the bash implementation. The two must agree on markers and
# sources — that contract is enforced by shared/parity-check.sh.
. (Join-Path $script:RepoRoot 'ps1\lib\00-constants.ps1')

$script:HostsFile = if ($env:HOSTS_FILE) { $env:HOSTS_FILE } else { "$env:SystemRoot\System32\drivers\etc\hosts" }

# ── JSON escaping ────────────────────────────────────────────────────────────
function ConvertTo-JsonLiteral {
    <#
    .SYNOPSIS
        Render a value as a JSON literal, or 'null' when it is absent.
        Empty string is treated as absent so the PowerShell output matches the
        bash output (which emits null, not "").
    #>
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return 'null' }
    $v = $Value.Replace('\', '\\').Replace('"', '\"')
    $v = $v.Replace("`r", '').Replace("`n", '\n').Replace("`t", '\t')
    return "`"$v`""
}

function ConvertTo-WarningsJson {
    param([string[]]$Warnings)
    if (-not $Warnings -or $Warnings.Count -eq 0) { return '[]' }
    $parts = $Warnings | ForEach-Object { ConvertTo-JsonLiteral $_ }
    return '[' + ($parts -join ',') + ']'
}

# ── Collect warnings in one place ────────────────────────────────────────────
$script:Warnings = New-Object System.Collections.Generic.List[string]

function Add-Warning {
    param([string]$Message)
    $script:Warnings.Add($Message) | Out-Null
}

# ── Platform ─────────────────────────────────────────────────────────────────
$platform = if ($env:WSL_DISTRO_NAME) {
    'WSL'
} elseif (Test-Path '/proc/version') {
    $pv = Get-Content '/proc/version' -Raw -ErrorAction SilentlyContinue
    if ($pv -match 'Microsoft|WSL') { 'WSL' } else { 'Linux' }
} elseif ($IsWindows -or $env:OS -eq 'Windows_NT') {
    'Windows'
} elseif ($IsMacOS) {
    'macOS'
} else {
    'Linux'
}

if ($platform -eq 'WSL') {
    Add-Warning 'WSL detected; hosts behaviour differs from Windows — this skill does not support WSL'
}

# ── curl availability ────────────────────────────────────────────────────────
$curlAvailable = $false
$curlPath = $null
try {
    $cmd = Get-Command curl.exe -ErrorAction Stop
    $curlAvailable = $true
    $curlPath = $cmd.Source
} catch {
    Add-Warning 'curl.exe not found; all connectivity probing is impossible'
}

# ── Hosts marker block + shadowing ───────────────────────────────────────────
$hostsPresent = $false
$hostsIp = $null
$hostsShadowed = $false
$shadowDetail = $null

if (Test-Path $script:HostsFile) {
    $lines = [System.IO.File]::ReadAllLines($script:HostsFile)
    $markerStart = $script:MARKER_START
    $markerEnd = $script:MARKER_END

    $startIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -like "$markerStart*") { $startIdx = $i; break }
    }

    if ($startIdx -ge 0) {
        $hostsPresent = $true

        # First IPv4 mapped to bare github.com inside the block
        for ($i = $startIdx; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -like "$markerEnd*") { break }
            if ($lines[$i] -match '^\s*(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s+github\.com(\s|$)') {
                $hostsIp = $Matches[1]
                break
            }
        }
        if (-not $hostsIp) {
            Add-Warning 'goto-github marker block present but no github.com IP line found'
        }

        # Shadowing: another tool's github.com entry ABOVE the block
        for ($i = 0; $i -lt $startIdx; $i++) {
            if ($lines[$i] -match '^\s*\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\s+github\.com(\s|$)') {
                $hostsShadowed = $true
                $shadowDetail = $lines[$i].Trim()
                Add-Warning 'hosts file has a github.com entry above the goto-github block; it takes precedence and the block is inert'
                break
            }
        }
    }
} else {
    Add-Warning "hosts file not found: $script:HostsFile"
}

# ── Proxy state ──────────────────────────────────────────────────────────────
$proxyEnabled = $false
$proxyServer = $null
$proxySource = 'none'

$ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
if ($ie -and $ie.ProxyEnable -eq 1 -and $ie.ProxyServer) {
    $proxyEnabled = $true
    $proxyServer = $ie.ProxyServer
    $proxySource = 'system'
}

if (-not $proxyEnabled) {
    foreach ($v in 'https_proxy', 'HTTPS_PROXY', 'http_proxy', 'HTTP_PROXY', 'ALL_PROXY', 'all_proxy') {
        $val = [Environment]::GetEnvironmentVariable($v, 'Process')
        if ($val) {
            $proxyEnabled = $true
            $proxyServer = $val
            $proxySource = 'env'
            break
        }
    }
}

if ($proxyEnabled) {
    Add-Warning "proxy detected ($proxySource); connectivity probing must bypass it or results are not attributable"
}

# ── DNS servers ──────────────────────────────────────────────────────────────
$dnsServers = @()
try {
    $dnsServers = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.ServerAddresses } |
        ForEach-Object { $_.ServerAddresses } |
        Select-Object -Unique
} catch {
    Add-Warning 'could not enumerate configured DNS servers'
}
if (-not $dnsServers -or $dnsServers.Count -eq 0) {
    Add-Warning 'no DNS servers reported for any interface'
}

# ── gh auth state ────────────────────────────────────────────────────────────
$ghState = 'error'
$ghWarning = $null

if (Get-Command gh -ErrorAction SilentlyContinue) {
    if ($env:GITHUB_TOKEN) {
        # The env var shadows the keyring token. Test whether it actually works
        # before blaming the network.
        try {
            $null = & gh api user --jq .login 2>&1
            if ($LASTEXITCODE -eq 0) {
                $ghState = 'keyring_ok'
            } else {
                $ghState = 'env_var_shadowed'
                $ghWarning = 'GITHUB_TOKEN is set but invalid; it shadows a valid keyring token and breaks all gh commands (git operations are unaffected)'
            }
        } catch {
            $ghState = 'env_var_shadowed'
            $ghWarning = 'GITHUB_TOKEN is set but could not be validated; it may shadow a valid keyring token'
        }
    } else {
        try {
            $null = & gh api user --jq .login 2>&1
            if ($LASTEXITCODE -eq 0) { $ghState = 'keyring_ok' } else { $ghState = 'none' }
        } catch {
            $ghState = 'none'
        }
    }
} else {
    $ghState = 'none'
}

# ── Privilege ────────────────────────────────────────────────────────────────
$privileged = $false
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = [Security.Principal.WindowsPrincipal]::new($id)
    $privileged = $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {
    Add-Warning 'could not determine administrator status'
}

# ── DoH state (Windows only; hosts is bypassed by DoH clients) ───────────────
$dohState = $null
if ($platform -eq 'Windows') {
    $dohExplicit = $false
    $dohAuto = $false
    try {
        $doh = Get-DnsClientDohServerAddress -ErrorAction SilentlyContinue
        if ($doh | Where-Object { $_.DohClientConfig -ne 0 }) { $dohExplicit = $true }
    } catch { }
    try {
        $reg = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -Name 'DohAutoUpgradeState' -ErrorAction SilentlyContinue
        if ($reg.DohAutoUpgradeState -eq 1) { $dohAuto = $true }
    } catch { }
    if ($dohExplicit -or $dohAuto) {
        $dohState = @{ explicit = $dohExplicit; auto_upgrade = $dohAuto }
        Add-Warning 'DNS-over-HTTPS is enabled; apps that use DoH bypass the hosts file'
    }
}

# ── Emit JSON (single line, stdout only) ─────────────────────────────────────
$dohJson = if ($null -eq $dohState) { 'null' } else { '{"explicit":' + $dohState.explicit.ToString().ToLower() + ',"auto_upgrade":' + $dohState.auto_upgrade.ToString().ToLower() + '}' }
$dnsJson = if ($dnsServers -and $dnsServers.Count -gt 0) { '[' + (($dnsServers | ForEach-Object { ConvertTo-JsonLiteral $_ }) -join ',') + ']' } else { '[]' }

$json = '{'
$json += '"shell":"pwsh",'
$json += '"platform":"' + $platform + '",'
$json += '"curl":{"available":' + $curlAvailable.ToString().ToLower() + ',"path":' + (ConvertTo-JsonLiteral $curlPath) + '},'
$json += '"hosts_entry":{"present":' + $hostsPresent.ToString().ToLower() + ',"ip":' + (ConvertTo-JsonLiteral $hostsIp) + ',"shadowed":' + $hostsShadowed.ToString().ToLower() + ',"shadowing_detail":' + (ConvertTo-JsonLiteral $shadowDetail) + '},'
$json += '"proxy":{"enabled":' + $proxyEnabled.ToString().ToLower() + ',"server":' + (ConvertTo-JsonLiteral $proxyServer) + ',"source":"' + $proxySource + '"},'
$json += '"dns_servers":' + $dnsJson + ','
$json += '"doh":' + $dohJson + ','
$json += '"gh_auth":{"state":"' + $ghState + '","warning":' + (ConvertTo-JsonLiteral $ghWarning) + '},'
$json += '"privileged":' + $privileged.ToString().ToLower() + ','
$json += '"warnings":' + (ConvertTo-WarningsJson $script:Warnings)
$json += '}'

[Console]::Out.Write($json)
