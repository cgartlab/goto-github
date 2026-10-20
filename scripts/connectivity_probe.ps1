#Requires -Version 7.0
<#
.SYNOPSIS
    Phase 1 connectivity sampling for the goto-github skill (read-only).

.DESCRIPTION
    Samples 5 GitHub endpoints N times each and reports success rate plus
    latency distribution (min/max/avg). Always bypasses the proxy.

    Why N samples: single-request outcomes are near-random under path-based
    interference. Measured on a live machine: the same endpoint went 60% -> 30%
    between two runs one minute apart, while the API endpoint stayed at 100%.
    Only the success rate is meaningful.

    http_code 000 (no response at all) is NOT counted as success — counting it
    would report a fully blocked endpoint as "100% available".

.PARAMETER Attempts
    Samples per endpoint. Default 10. Below 5 the verdict is unstable and the
    report must say so.

.PARAMETER Timeout
    Connect timeout in seconds. Default 5.

.PARAMETER Repo
    owner/repo used for the git and download endpoints.

.EXAMPLE
    .\scripts\connectivity_probe.ps1 -Attempts 10
#>
[CmdletBinding()]
param(
    [int]$Attempts = 10,
    [int]$Timeout = 5,
    [string]$Repo = 'cgartlab/goto-github',
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

$showHelp = {
    Write-Output @'
Usage: connectivity_probe.ps1 [-Attempts N] [-Timeout SEC] [-Repo owner/repo] [-Help]

Phase 1 connectivity sampling for the goto-github skill. Read-only.

Samples 5 GitHub endpoints N times each and reports success rate plus
latency distribution (min/max/avg). Always bypasses the proxy.

Options:
  -Attempts N   samples per endpoint (default 10; below 5 the verdict is
                unstable and the report must say so)
  -Timeout SEC  connect timeout in seconds (default 5)
  -Repo         owner/repo for the git and download endpoints

Output: single-line JSON on stdout.
'@
}

if ($Help) { & $showHelp; exit 0 }

# Warnings must go to stderr, NOT the warning stream: in a pipeline capture the
# warning stream is forwarded to stdout, which would break the contract that
# stdout carries exactly one JSON line.
function Write-StderrWarning {
    param([string]$Message)
    [Console]::Error.WriteLine("WARNING: $Message")
}

if ($Attempts -lt 5) {
    Write-StderrWarning "--attempts $Attempts is below 5; the success rate is not statistically meaningful"
}

# ── Endpoint table (order is fixed — see references/judgment-criteria.md) ────
$endpoints = [ordered]@{
    web       = 'https://github.com/'
    api       = 'https://api.github.com/'
    download  = "https://codeload.github.com/$Repo/tar.gz/refs/heads/main"
    raw       = "https://raw.githubusercontent.com/$Repo/main/README.md"
    git       = "https://github.com/$Repo/info/refs?service=git-upload-pack"
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

# ── Sample one endpoint ──────────────────────────────────────────────────────
function Invoke-EndpointSample {
    param([string]$Url, [string]$Key)

    $curl = Get-CurlPath
    if (-not $curl) {
        Write-StderrWarning "curl.exe not found; cannot probe $Key"
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
        # (The unparenthesised form parses as a call to a command named `if`
        # and fails at runtime with "术语 'if' 不会被识别".)
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

# ── Main ─────────────────────────────────────────────────────────────────────
$timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$results = New-Object System.Collections.Generic.List[string]

foreach ($key in $endpoints.Keys) {
    $url = $endpoints[$key]
    Write-Verbose "probing $key ($url) ..."

    $r = Invoke-EndpointSample -Url $url -Key $key
    $rate = [int][math]::Round(($r.success / $Attempts) * 100)

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

    # String concatenation, not -f: the URL contains no braces but the JSON
    # template does, and -f treats every brace as a format placeholder.
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

# Sample-size caveat belongs in the JSON, not only in a warning stream.
$warnings = New-Object System.Collections.Generic.List[string]
if ($Attempts -lt 5) {
    $warnings.Add("sample_size is $Attempts (below 5); the success rate is not statistically meaningful")
}

$warnJson = $(if ($warnings.Count -eq 0) { '[]' } else { '[' + (($warnings | ForEach-Object { ConvertTo-JsonLiteral $_ }) -join ',') + ']' })
$json = '{'
$json += '"timestamp":"' + $timestamp + '",'
$json += '"proxy_bypassed":true,'
$json += '"attempts":' + $Attempts + ','
$json += '"endpoints":[' + ($results -join ',') + '],'
$json += '"warnings":' + $warnJson
$json += '}'

[Console]::Out.Write($json)
