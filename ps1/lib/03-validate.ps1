# goto-github validation functions (PowerShell)
# Dot-source after 00-constants.ps1, 01-utils.ps1, 02-scan.ps1
# Source order: 00, 01, 02, 03, 04, 05, 06
if (Get-Variable -Name 'GOTO_GITHUB_PS1_03_INCLUDED' -Scope Script -ErrorAction SilentlyContinue) { return }
$script:GOTO_GITHUB_PS1_03_INCLUDED = $true

# ---------------------------------------------------------------------------
# Test-IpQuick: HTTP 200/301/302 only, no content size check
# Used for fast reachability tests (e.g., verifying cached IP)
# Mirrors bash 03-validate.sh::validate_ip_quick
# ---------------------------------------------------------------------------
function Test-IpQuick {
    <#
    .SYNOPSIS
    Test whether an IP returns HTTP 200/301/302 (no content size check).
    Faster than Test-Ip (in 02-scan.ps1) because it skips size validation.
    Returns $true on success, $false otherwise.
    #>
    param([string]$IP)

    $curlPath = Find-Curl
    if (-not $curlPath) { return $false }

    try {
        # Probe the git smart-http endpoint, not the homepage: an IP can serve
        # the homepage while timing out on git traffic.
        $code = & $curlPath --resolve "github.com:443:$IP" `
            -s -o NUL `
            -w "%{http_code}" `
            --connect-timeout $script:CONNECT_TIMEOUT `
            --max-time $script:MAX_TIME `
            -H 'Accept: application/x-git-upload-pack-advertisement' `
            $script:PROBE_TARGET 2>$null

        if ($LASTEXITCODE -ne 0) { return $false }
        return ($code -eq '200' -or $code -eq '301' -or $code -eq '302')
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Get-IpFromHosts: extract the current IP from /etc/hosts marker block
# Moved from 04-apply.ps1 to mirror bash 03-validate.sh::extract_ip_from_hosts
# ---------------------------------------------------------------------------
function Get-IpFromHosts {
    <#
    .SYNOPSIS
    Extract the current goto-github IP from /etc/hosts.
    Returns the IP string, or $null if no marker block or no IP line found.
    #>
    if (-not (Test-Path $script:HOSTS_FILE)) { return $null }

    $inSection = $false
    $ip = $null

    $lines = [System.IO.File]::ReadAllLines($script:HOSTS_FILE)
    foreach ($line in $lines) {
        if ($line -like "$($script:MARKER_START)*") {
            $inSection = $true
            continue
        }
        if ($line -like "$($script:MARKER_END)*") {
            break
        }
        if ($inSection) {
            # Match IPv4 pattern: "140.82.112.3 github.com"
            if ($line -match '\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b') {
                $ip = $matches[1]
                break
            }
        }
    }

    return $ip
}
