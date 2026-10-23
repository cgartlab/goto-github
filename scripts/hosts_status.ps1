#Requires -Version 5.1
<#
.SYNOPSIS
    Phase 4 verification + status for the goto-github skill (read-only).

.DESCRIPTION
    Re-samples the core endpoints via the shared lib/probe.ps1 and reports a
    two-dimensional verdict:

      network -- live sample plus an optional comparison against -Baseline
      auth    -- passed through from auth_probe; an auth failure is NOT a
                network failure and is never folded into the network verdict

    PowerShell 5.1 compatible (Windows default) and 7+.

.PARAMETER Attempts
    Samples per endpoint. Default 10; must match the baseline.

.PARAMETER Timeout
    Connect timeout in seconds. Default 5.

.PARAMETER Baseline
    Previous connectivity_probe JSON output.

.PARAMETER Help
    Show this help.

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

$script:RepoRoot = Split-Path -Parent $PSScriptRoot

$showHelp = {
    Write-Output @'
Usage: hosts_status.ps1 [-Attempts N] [-Timeout SEC] [-Baseline FILE] [-Help]

Phase 4 verification for the goto-github skill. Read-only.

Re-samples every core endpoint and emits a verdict:
  fixed          core endpoints meet their thresholds without regression
  partial        at least one endpoint improved by >= 10 points, threshold not met
  not_fixed      no endpoint improved / core paths below 50%
  not_installed  no goto-github marker block present

Auth state (ssh / https) is reported as a separate dimension because an auth
failure is not a network failure.

Options:
  -Attempts N   samples per endpoint (default 10; must match the baseline)
  -Timeout SEC  connect timeout in seconds (default 5)
  -Baseline F   previous connectivity_probe JSON output

Requires PowerShell 5.1+.
'@
}

if ($Help) { & $showHelp; exit 0 }

. (Join-Path $PSScriptRoot 'lib\constants.ps1')
. (Join-Path $PSScriptRoot 'lib\endpoints.ps1')
. (Join-Path $PSScriptRoot 'lib\probe.ps1')

$HostsFile = $script:HOSTS_FILE

# -- Thresholds (must match references/judgment-criteria.md) ------------------
$GIT_OK = 85
$API_OK = 85
$WEB_OK = 60
# Minimum improvement (percentage points) that counts as a real gain over the
# baseline. Below this the difference is sampling noise, not a repair effect.
$IMPROVE_MARGIN = 10

# -- Installed state ----------------------------------------------------------
$installed = $false
$currentIp = $null
if (Test-Path $HostsFile) {
    $lines = [System.IO.File]::ReadAllLines($HostsFile)
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

# -- Sample -------------------------------------------------------------------
$timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$endpointsJson = New-Object System.Collections.Generic.List[string]
$rates = @{}

foreach ($ep in (Get-Endpoints -Scope 'fast')) {
    Write-Verbose "probing $($ep.Key) ..."
    $r = Invoke-EndpointProbe -Url $ep.Url -Kind $ep.Kind -Attempts $Attempts -Timeout $Timeout
    $rate = [int][math]::Round(($r.success / $Attempts) * 100)
    $rates[$ep.Key] = $rate
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
}

# -- Network verdict ----------------------------------------------------------
$verdict = 'not_fixed'
$warnings = New-Object System.Collections.Generic.List[string]

function Get-Rate {
    param([string]$Key)
    if ($rates.ContainsKey($Key)) { return [int]$rates[$Key] }
    return 0
}

if (-not $installed) {
    $verdict = 'not_installed'
} else {
    $webRate = Get-Rate 'web'
    $apiRate = Get-Rate 'api'
    $gitReadRate = Get-Rate 'git_read'

    if ($Baseline -and (Test-Path $Baseline)) {
        $base = Get-Content $Baseline -Raw | ConvertFrom-Json
        $baseRates = @{}
        foreach ($e in $base.endpoints) { $baseRates[$e.key] = [int]$e.rate }

        # Noise floor: a 1-point wobble is not an improvement.
        $improved = 0
        foreach ($k in 'web', 'api', 'git_read') {
            if ($baseRates.ContainsKey($k) -and ((Get-Rate $k) - $baseRates[$k]) -ge $IMPROVE_MARGIN) {
                $improved++
            }
        }

        if ($improved -gt 0 -and $gitReadRate -ge $GIT_OK -and $apiRate -ge $API_OK) {
            $verdict = 'fixed'
        } elseif ($improved -gt 0) {
            $verdict = 'partial'
            $warnings.Add('some endpoints improved but the core thresholds were not reached')
        } else {
            $verdict = 'not_fixed'
            $warnings.Add('no endpoint improved over the baseline; the hosts change did not help')
        }

        if ($gitReadRate -lt $GIT_OK -or $apiRate -lt $API_OK) {
            $warnings.Add('git_read or api is below threshold; the hosts entry may be shadowed or the IP is dead')
        }
    } else {
        # No baseline: threshold-only verdict, and say so.
        if ($gitReadRate -ge $GIT_OK -and $apiRate -ge $API_OK) {
            $verdict = 'fixed'
            $warnings.Add('verdict based on thresholds only (no -Baseline supplied); the network is time-varying so this does not prove the repair caused it')
        } elseif ($gitReadRate -ge 50 -or $apiRate -ge 50) {
            $verdict = 'partial'
            $warnings.Add('git_read or api is between 50% and the threshold; partially working')
        } else {
            $verdict = 'not_fixed'
            $warnings.Add('git_read and api are both below 50%; hosts cannot fix this - a proxy is required')
        }
    }

    if ($webRate -lt $WEB_OK) {
        $warnings.Add("web front page is at $webRate% (below $WEB_OK%); browsing is degraded but CLI paths may be fine")
    }
}

# -- Auth dimension (independent of network) ----------------------------------
$authSsh = if ($env:SSH_AUTH_STATE) { $env:SSH_AUTH_STATE } else { 'unknown' }
$authHttps = if ($env:HTTPS_AUTH_STATE) { $env:HTTPS_AUTH_STATE } else { 'unknown' }

# -- Emit ---------------------------------------------------------------------
$warnJson = if ($warnings.Count -eq 0) { '[]' } else { '[' + (($warnings | ForEach-Object { ConvertTo-JsonLiteral $_ }) -join ',') + ']' }

$json = '{'
$json += '"timestamp":"' + $timestamp + '",'
$json += '"installed":' + $installed.ToString().ToLower() + ','
$json += '"current_ip":' + (ConvertTo-JsonLiteral $currentIp) + ','
$json += '"endpoints":[' + ($endpointsJson -join ',') + '],'
$json += '"verdict":"' + $verdict + '",'
$json += '"auth":{"ssh":"' + $authSsh + '","https":"' + $authHttps + '"}'
$json += ',"warnings":' + $warnJson
$json += '}'

[Console]::Out.Write($json)
