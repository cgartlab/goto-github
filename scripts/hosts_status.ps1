#Requires -Version 7.0
<#
.SYNOPSIS
    Phase 4 verification + status for the goto-github skill (read-only).

.DESCRIPTION
    Re-samples the same 5 endpoints as connectivity_probe.ps1 and emits a
    verdict. With -Baseline the verdict compares against the pre-repair
    measurement, so "fixed" means "improved", not just "looks good now" (the
    network is time-varying).

.PARAMETER Attempts
    Samples per endpoint. Default 10; must match the baseline.

.PARAMETER Timeout
    Connect timeout in seconds. Default 5.

.PARAMETER Baseline
    Previous connectivity_probe JSON output.

.EXAMPLE
    .\scripts\hosts_status.ps1 -Baseline .\before.json
#>
[CmdletBinding()]
param(
    [int]$Attempts = 10,
    [int]$Timeout = 5,
    [string]$Baseline,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

$showHelp = {
    Write-Output @'
Usage: hosts_status.ps1 [-Attempts N] [-Timeout SEC] [-Baseline FILE] [-Help]

Phase 4 verification for the goto-github skill. Read-only.

Re-samples the same 5 endpoints as connectivity_probe.ps1 and emits a verdict:
  fixed          web crossed the threshold and git/api did not regress
  partial        at least one endpoint improved, threshold not reached
  not_fixed      no endpoint improved
  not_installed  no goto-github marker block present

Options:
  -Attempts N   samples per endpoint (default 10; must match the baseline)
  -Timeout SEC  connect timeout in seconds (default 5)
  -Baseline F   previous connectivity_probe JSON output; the verdict is
                computed against it (improvement, not just thresholds)

Environment:
  HOSTS_FILE  hosts file path (default: %SystemRoot%\System32\drivers\etc\hosts)
  PROBE_REPO  owner/repo for git/download endpoints
'@
}

if ($Help) { & $showHelp; exit 0 }

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib\constants.ps1')

$script:HostsFile = $script:HOSTS_FILE
$script:ProbeRepo = $script:PROBE_REPO

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

function Get-CurlPath {
    try { return (Get-Command curl.exe -ErrorAction Stop).Source } catch { return $null }
}

# ── Thresholds (must match references/judgment-criteria.md) ──────────────────
$GIT_OK = 85
$API_OK = 85
$WEB_OK = 60

# ── Endpoints (same order/shape as connectivity_probe.ps1) ───────────────────
$endpoints = [ordered]@{
    web       = 'https://github.com/'
    api       = 'https://api.github.com/'
    download  = "https://codeload.github.com/$script:ProbeRepo/tar.gz/refs/heads/main"
    raw       = "https://raw.githubusercontent.com/$script:ProbeRepo/main/README.md"
    git       = "https://github.com/$script:ProbeRepo/info/refs?service=git-upload-pack"
}

function Invoke-EndpointSample {
    param([string]$Url, [string]$Key)

    $curl = Get-CurlPath
    if (-not $curl) {
        Add-Warning "curl.exe not found; cannot probe $Key"
        return @{ success = 0; fail = $Attempts; times = @() }
    }

    $times = New-Object System.Collections.Generic.List[double]
    $ok = 0
    $fail = 0

    for ($i = 1; $i -le $Attempts; $i++) {
        # --noproxy '*' is mandatory: probing through a proxy measures the
        # proxy, not this machine's connectivity to GitHub.
        $out = & $curl --noproxy '*' -s -o NUL `
            --connect-timeout $Timeout --max-time ($Timeout + 2) `
            -w '%{http_code},%{time_total}' "$Url" 2>$null
        $rc = $LASTEXITCODE

        $parts = "$out" -split ','
        # Subexpression $(...), not `$x = if (...) {} else {}`: `if` is a
        # statement, not an expression, so it cannot be assigned directly.
        $code = $(if ($parts.Count -ge 1) { $parts[0] } else { '' })
        $t = $(if ($parts.Count -ge 2) { $parts[1] } else { '' })

        # rc=0 AND a real HTTP code. 000 = no response at all (connection
        # failed / timeout / DNS failure) and must not count as success.
        if ($rc -eq 0 -and $code -and $code -ne '000') {
            $ok++
            [double]$tv = 0
            if ([double]::TryParse($t, [ref]$tv)) { $times.Add($tv) }
        } else {
            $fail++
        }
    }

    return @{ success = $ok; fail = $fail; times = $times }
}

# ── Installed state ──────────────────────────────────────────────────────────
$installed = $false
$currentIp = $null
if (Test-Path $script:HostsFile) {
    $lines = [System.IO.File]::ReadAllLines($script:HostsFile)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -like "$($script:MARKER_START)*") {
            $installed = $true
            for ($j = $i; $j -lt $lines.Count; $j++) {
                if ($lines[$j] -like "$($script:MARKER_END)*") { break }
                if ($lines[$j] -match '^\s*(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s+github\.com(\s|$)') {
                    $currentIp = $Matches[1]
                    break
                }
            }
            break
        }
    }
}

# ── Sample ───────────────────────────────────────────────────────────────────
$timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$results = New-Object System.Collections.Generic.List[string]
$rates = @{}

foreach ($key in $endpoints.Keys) {
    $url = $endpoints[$key]
    Write-Verbose "probing $key ..."

    $r = Invoke-EndpointSample -Url $url -Key $key
    $rate = [int][math]::Round(($r.success / $Attempts) * 100)
    $rates[$key] = $rate

    if ($r.times.Count -gt 0) {
        $stats = $r.times | Measure-Object -Minimum -Maximum -Average
        # Concatenation, not -f: the JSON braces would be parsed as format
        # placeholders ("Input string was not in a correct format").
        $lat = '{'
        $lat += '"min":' + [math]::Round($stats.Minimum, 3) + ','
        $lat += '"max":' + [math]::Round($stats.Maximum, 3) + ','
        $lat += '"avg":' + [math]::Round($stats.Average, 3)
        $lat += '}'
    } else {
        # Zero successes: latency is unknown, not zero.
        $lat = 'null'
    }

    $obj = '{'
    $obj += '"key":"' + $key + '",'
    $obj += '"url":' + (ConvertTo-JsonLiteral $url) + ','
    $obj += '"success":' + $r.success + ','
    $obj += '"fail":' + $r.fail + ','
    $obj += '"rate":' + $rate + ','
    $obj += '"latency":' + $lat
    $obj += '}'
    $results.Add($obj)
}

# ── Verdict ──────────────────────────────────────────────────────────────────
$verdict = 'not_fixed'

if (-not $installed) {
    $verdict = 'not_installed'
} else {
    $webRate = $rates['web']
    $gitRate = $rates['git']
    $apiRate = $rates['api']

    if ($Baseline -and (Test-Path $Baseline)) {
        # Compare against the pre-repair measurement: "fixed" must mean
        # improvement, not just a good absolute number.
        $baseRaw = Get-Content $Baseline -Raw
        $base = $baseRaw | ConvertFrom-Json

        $baseRates = @{}
        foreach ($e in $base.endpoints) { $baseRates[$e.key] = [int]$e.rate }

        $improved = 0
        foreach ($k in 'web', 'git', 'api') {
            if ($baseRates.ContainsKey($k) -and $rates[$k] -gt $baseRates[$k]) { $improved++ }
        }

        if ($webRate -ge $WEB_OK -and $improved -gt 0 -and $gitRate -ge $GIT_OK -and $apiRate -ge $API_OK) {
            $verdict = 'fixed'
        } elseif ($improved -gt 0) {
            $verdict = 'partial'
            Add-Warning 'some endpoints improved but the thresholds were not reached'
        } else {
            $verdict = 'not_fixed'
            Add-Warning 'no endpoint improved over the baseline; the hosts change did not help'
        }

        if ($gitRate -lt $GIT_OK -or $apiRate -lt $API_OK) {
            Add-Warning 'git or api endpoint is below threshold; the hosts entry may be shadowed or the IP is dead'
        }
    } else {
        # No baseline: threshold-only verdict, and say so.
        if ($webRate -ge $WEB_OK -and $gitRate -ge $GIT_OK -and $apiRate -ge $API_OK) {
            $verdict = 'fixed'
            Add-Warning 'verdict based on thresholds only (no -Baseline supplied); the network is time-varying so this does not prove the repair caused it'
        } elseif ($webRate -ge $WEB_OK) {
            $verdict = 'partial'
            Add-Warning 'web endpoint is healthy but git/api are below threshold'
        } else {
            $verdict = 'not_fixed'
            Add-Warning "web endpoint is still below the ${WEB_OK}% threshold"
        }
    }
}

if ($Attempts -lt 5) {
    Add-Warning "sample_size is $Attempts (below 5); the success rate is not statistically meaningful"
}

# ── Emit ─────────────────────────────────────────────────────────────────────
$warnJson = if ($script:Warnings.Count -eq 0) { '[]' } else { '[' + (($script:Warnings | ForEach-Object { ConvertTo-JsonLiteral $_ }) -join ',') + ']' }

$json = '{'
$json += '"timestamp":"' + $timestamp + '",'
$json += '"installed":' + $installed.ToString().ToLower() + ','
$json += '"current_ip":' + (ConvertTo-JsonLiteral $currentIp) + ','
$json += '"endpoints":[' + ($results -join ',') + '],'
$json += '"verdict":"' + $verdict + '",'
$json += '"warnings":' + $warnJson
$json += '}'

[Console]::Out.Write($json)
