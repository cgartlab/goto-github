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
    Test whether an IP serves a real git smart-http advertisement.
    Returns $true on success, $false otherwise.

    A bare 2xx is NOT proof: some networks answer github.com with a synthetic
    "200 OK" whose body is the 4-byte string "OK". Checking status alone would
    accept it and then every real download fails a hash check. So the body is
    captured and must start with a 4-hex-digit pkt-line length (e.g. "001e").
    #>
    param([string]$IP)

    $curlPath = Find-Curl
    if (-not $curlPath) { return $false }

    $bodyFile = [System.IO.Path]::GetTempFileName()
    try {
        # Probe the git smart-http endpoint, not the homepage: an IP can serve
        # the homepage while timing out on git traffic.
        $code = & $curlPath --resolve "github.com:443:$IP" `
            -s -o $bodyFile `
            -w "%{http_code}" `
            --connect-timeout $script:CONNECT_TIMEOUT `
            --max-time $script:MAX_TIME `
            -H 'Accept: application/x-git-upload-pack-advertisement' `
            $script:PROBE_TARGET 2>$null

        if ($LASTEXITCODE -ne 0) { return $false }
        if ($code -ne '200') { return $false }

        $bytes = [System.IO.File]::ReadAllBytes($bodyFile)
        if ($bytes.Length -lt 4) { return $false }
        $head = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4)
        return ($head -match '^[0-9a-f]{4}$')
    } catch {
        return $false
    } finally {
        Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue
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
