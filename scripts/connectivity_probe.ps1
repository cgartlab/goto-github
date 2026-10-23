#Requires -Version 5.1
<#
.SYNOPSIS
    Phase 1 connectivity sampling for the goto-github skill (read-only).

.DESCRIPTION
    Samples the full GitHub service surface N times each and reports success
    rate with latency distribution. Always bypasses the proxy.

    Why the full surface and not 5 endpoints: a developer reaches GitHub
    through many independent paths (git read/write, API, raw, registries, SSH).
    A narrow probe says "GitHub is fine" while `docker pull ghcr.io/...` is dead.

    Why N samples: single-request outcomes are near-random under path-based
    interference. Measured: the same endpoint went 60% -> 20% over three days,
    while api/git stayed at 100%. Only the success rate is meaningful.

    PowerShell 5.1 compatible (Windows default) and 7+.

.PARAMETER Attempts
    Samples per endpoint. Default 10. Below 5 the verdict is unstable.

.PARAMETER Timeout
    Connect timeout in seconds. Default 5.

.PARAMETER Scope
    fast (default) covers everything except registries/assets; all adds them.

.PARAMETER Repo
    owner/repo used for the git and download endpoints.

.PARAMETER Help
    Show this help.

.EXAMPLE
    .\scripts\connectivity_probe.ps1 -Attempts 10
#>
[CmdletBinding()]
param(
    [int]$Attempts = 10,
    [ValidateSet('fast', 'all')][string]$Scope = 'fast',
    [int]$Timeout = 5,
    [string]$Repo = 'cgartlab/goto-github',
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot

$showHelp = {
    Write-Output @'
Usage: connectivity_probe.ps1 [-Attempts N] [-Timeout SEC] [-Scope fast|all] [-Repo owner/repo] [-Help]

Phase 1 connectivity sampling for the goto-github skill. Read-only.

Samples every GitHub service surface N times each and reports success rate with
latency distribution (min/max/avg). Always bypasses the proxy. JSON on stdout,
progress on stderr.

Endpoint groups:
  web       github.com front page
  api       api.github.com (gh CLI, REST, GraphQL)
  git       smart-http: git_read (clone/fetch) and git_write (push handler)
  raw       raw.githubusercontent.com, gist.githubusercontent.com
  download  codeload.github.com (tarballs, zips)
  assets    github.githubassets.com
  ssh       tcp://github.com:22, tcp://ssh.github.com:443 (transport only;
            authentication is a separate dimension)
  registry  ghcr.io, npm.pkg.github.com, maven.pkg.github.com (-Scope all)

Options:
  -Attempts N   samples per endpoint (default 10; below 5 not meaningful)
  -Timeout SEC  connect timeout in seconds (default 5)
  -Scope S      fast (default) covers everything except registries/assets
  -Repo         owner/repo for git and download endpoints

Requires PowerShell 5.1+.
'@
}

if ($Help) { & $showHelp; exit 0 }

# shellcheck disable=SC1091
. (Join-Path $PSScriptRoot 'lib\endpoints.ps1')
. (Join-Path $PSScriptRoot 'lib\probe.ps1')

# Repo override must be applied before Get-Endpoints builds the URLs.
if ($Repo) { $script:PROBE_REPO = $Repo }

if ($Attempts -lt 5) {
    Write-StderrWarning "-Attempts $Attempts is below 5; the success rate is not statistically meaningful"
}

$timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$endpointsJson = New-Object System.Collections.Generic.List[string]

foreach ($ep in (Get-Endpoints -Scope $Scope)) {
    Write-Verbose "probing $($ep.Key) ($($ep.Url)) ..."

    $r = Invoke-EndpointProbe -Url $ep.Url -Kind $ep.Kind -Attempts $Attempts -Timeout $Timeout
    $rate = [int][math]::Round(($r.success / $Attempts) * 100)
    $lat = ConvertTo-LatencyJson -ProbeResult $r

    $obj = '{'
    $obj += '"key":' + (ConvertTo-JsonLiteral $ep.Key) + ','
    $obj += '"url":' + (ConvertTo-JsonLiteral $ep.Url) + ','
    $obj += '"group":' + (ConvertTo-JsonLiteral $ep.Group) + ','
    $obj += '"kind":' + (ConvertTo-JsonLiteral $ep.Kind) + ','
    $obj += '"success":' + $r.success + ','
    $obj += '"fail":' + $r.fail + ','
    $obj += '"rate":' + $rate + ','
    $obj += '"latency":' + $lat
    $obj += '}'
    $endpointsJson.Add($obj)

    Write-Verbose ('  -> {0}/{1} ({2}%)' -f $r.success, $Attempts, $rate)
}

$warnJson = '[]'
if ($Attempts -lt 5) {
    $warnJson = '["sample_size is ' + $Attempts + ' (below 5); the success rate is not statistically meaningful"]'
}

$json = '{'
$json += '"timestamp":"' + $timestamp + '",'
$json += '"proxy_bypassed":true,'
$json += '"attempts":' + $Attempts + ','
$json += '"scope":"' + $Scope + '",'
$json += '"endpoints":[' + ($endpointsJson -join ',') + '],'
$json += '"warnings":' + $warnJson
$json += '}'

[Console]::Out.Write($json)
