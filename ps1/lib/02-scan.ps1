# goto-github scanning logic (PowerShell)
# Dot-source after 00-constants.ps1 and 01-utils.ps1
if (Get-Variable -Name 'GOTO_GITHUB_PS1_02_INCLUDED' -Scope Script -ErrorAction SilentlyContinue) { return }
$script:GOTO_GITHUB_PS1_02_INCLUDED = $true

function Expand-CidrToIPs {
    <#
    .SYNOPSIS
    Expand all CIDR ranges to individual IPs, shuffled.
    Manual bit-manipulation since [System.Net.IPNetwork] is not in the BCL.
    Returns a shuffled array of IP strings.
    #>
    param([string[]]$Cidrs)

    $allIPs = [System.Collections.ArrayList]@()

    foreach ($cidr in $Cidrs) {
        $parts = $cidr -split '/'
        $ipStr = $parts[0]
        $prefixLen = [int]$parts[1]
        $hostBits = 32 - $prefixLen
        $hostCount = [uint32]([math]::Pow(2, $hostBits) - 2)

        $ipBytes = [System.Net.IPAddress]::Parse($ipStr).GetAddressBytes()
        [array]::Reverse($ipBytes)
        $ipUint = [System.BitConverter]::ToUInt32($ipBytes, 0)

        # Build mask: top $prefixLen bits set, rest zero.
        # Use [uint64] for the shift to avoid signed-Int32 overflow at bit 31
        # (1 -shl 31 in PowerShell returns -2147483648 which won't cast to uint32).
        $maskUint = [uint32]0
        for ($b = 0; $b -lt $prefixLen; $b++) {
            $bitPos = 31 - $b
            $maskUint = $maskUint -bor [uint32]([uint64]1 -shl $bitPos)
        }
        $networkStart = $ipUint -band $maskUint

        for ($i = 1; $i -le $hostCount; $i++) {
            $hostUint = $networkStart + $i
            $bytes = [System.BitConverter]::GetBytes($hostUint)
            [array]::Reverse($bytes)
            $null = $allIPs.Add([System.Net.IPAddress]::new($bytes).ToString())
        }
    }

    # Fisher-Yates shuffle
    $rng = [System.Random]::new()
    $n = $allIPs.Count
    while ($n -gt 1) {
        $n--
        $k = $rng.Next(0, $n + 1)
        $tmp = $allIPs[$k]
        $allIPs[$k] = $allIPs[$n]
        $allIPs[$n] = $tmp
    }

    return $allIPs.ToArray()
}

# Probe target lives in 00-constants.ps1 ($script:PROBE_TARGET) — it is a
# constant, so it must be declared in exactly one place. Duplicating it here
# would silently shadow the constant and let the two drift apart.

# ---------------------------------------------------------------------------
# Test-Ip: single-IP validation via curl.exe --resolve
# ---------------------------------------------------------------------------
function Test-Ip {
    <#
    .SYNOPSIS
    Test whether an IP serves real GitHub content.
    Uses curl.exe --resolve to direct HTTPS traffic to the specific IP.
    Returns a hashtable { IP, Time, Size } on success, or $null on failure.
    #>
    param([string]$IP)

    $curlPath = Find-Curl
    if (-not $curlPath) { return $null }

    try {
        # --resolve forces the IP while SNI still routes to github.com, so the
        # IP must actually serve that Host. The git endpoint is the only
        # target that proves git traffic works — the homepage can lie.
        $out = & $curlPath --resolve "github.com:443:$IP" `
            -s -o NUL `
            -w "%{http_code},%{time_total},%{size_download}" `
            --connect-timeout $script:CONNECT_TIMEOUT `
            --max-time $script:MAX_TIME `
            -H 'Accept: application/x-git-upload-pack-advertisement' `
            $script:PROBE_TARGET 2>$null

        if ($LASTEXITCODE -ne 0) { return $null }

        $parts = $out -split ','
        if ($parts.Count -lt 3) { return $null }

        $httpCode = $parts[0]
        $time = [double]$parts[1]
        $size = [long]$parts[2]

        if ($httpCode -ne '200' -and $httpCode -ne '301' -and $httpCode -ne '302') { return $null }
        if ($size -lt $script:MIN_CONTENT_SIZE) { return $null }

        return @{ IP = $IP; Time = $time; Size = $size }
    } catch {
        return $null
    }
}

# ---------------------------------------------------------------------------
# Test-PriorityIp: parallel scan of 8 known-good IPs, return fastest
# ---------------------------------------------------------------------------
function Test-PriorityIp {
    <#
    .SYNOPSIS
    Scan the 8 priority IPs in parallel and return the fastest valid result.
    Returns hashtable { IP, Time, Size } or $null.
    #>
    $curlPath = Find-Curl
    if (-not $curlPath) { return $null }

    # Capture into local variables so they are reachable via $using: from the
    # parallel runspace (parent-scope functions and $script: vars are NOT
    # visible in a -Parallel block).
    $localCurl = $curlPath
    $localIps = $script:PRIORITY_IPS
    $localTimeout = $script:CONNECT_TIMEOUT
    $localMaxTime = $script:MAX_TIME
    $localMinSize = $script:MIN_CONTENT_SIZE
    $localBatch = $script:CONCURRENT_BATCH
    $localTarget = $script:PROBE_TARGET

    # ForEach-Object -Parallel has no -AsArray parameter; @() stops a single
    # result from unwrapping to a bare scalar.
    $results = @($localIps | ForEach-Object -Parallel {
        $ip = $_

        # Probe the git smart-http endpoint, not the homepage: an IP can serve
        # the homepage while timing out on git traffic.
        $result = & $using:localCurl --resolve "github.com:443:$ip" `
            -s -o NUL `
            -w "%{http_code},%{time_total},%{size_download}" `
            --connect-timeout $using:localTimeout `
            --max-time $using:localMaxTime `
            -H 'Accept: application/x-git-upload-pack-advertisement' `
            $using:localTarget 2>$null

        if ($LASTEXITCODE -ne 0) { return }

        $parts = $result -split ','
        if ($parts.Count -lt 3) { return }

        $httpCode = $parts[0]
        $time = [double]$parts[1]
        $size = [long]$parts[2]

        if ($httpCode -ne '200' -and $httpCode -ne '301' -and $httpCode -ne '302') { return }
        if ($size -lt $using:localMinSize) { return }

        [pscustomobject]@{ IP = $ip; Time = $time; Size = $size }
    } -ThrottleLimit $localBatch)

    if (-not $results) { return $null }

    $best = $results | Sort-Object Time | Select-Object -First 1
    return @{ IP = $best.IP; Time = $best.Time; Size = $best.Size }
}

# ---------------------------------------------------------------------------
# Test-CidrRange: expand CIDRs, scan in parallel batches, early-break
# ---------------------------------------------------------------------------
function Test-CidrRange {
    <#
    .SYNOPSIS
    Scan expanded CIDR IPs in parallel batches (CONCURRENT_BATCH at a time).
    Early-breaks on first hit found.
    Returns hashtable { IP, Time, Size } or $null.
    #>
    $curlPath = Find-Curl
    if (-not $curlPath) { return $null }

    $localCurl = $curlPath
    $localTimeout = $script:CONNECT_TIMEOUT
    $localMaxTime = $script:MAX_TIME
    $localMinSize = $script:MIN_CONTENT_SIZE
    $localBatch = $script:CONCURRENT_BATCH
    $localRanges = $script:CIDR_RANGES
    $localTarget = $script:PROBE_TARGET

    $allIPs = Expand-CidrToIPs -Cidrs $localRanges
    if ($allIPs.Count -eq 0) { return $null }

    $total = $allIPs.Count

    for ($start = 0; $start -lt $total; $start += $localBatch) {
        $end = [Math]::Min($start + $localBatch - 1, $total - 1)
        $batch = $allIPs[$start..$end]

        # @() because a single surviving result would otherwise unwrap to a scalar.
        $results = @($batch | ForEach-Object -Parallel {
            $ip = $_

            # Probe the git smart-http endpoint, not the homepage: an IP can
            # serve the homepage while timing out on git traffic.
            $result = & $using:localCurl --resolve "github.com:443:$ip" `
                -s -o NUL `
                -w "%{http_code},%{time_total},%{size_download}" `
                --connect-timeout $using:localTimeout `
                --max-time $using:localMaxTime `
                -H 'Accept: application/x-git-upload-pack-advertisement' `
                $using:localTarget 2>$null

            if ($LASTEXITCODE -ne 0) { return }

            $parts = $result -split ','
            if ($parts.Count -lt 3) { return }

            $httpCode = $parts[0]
            $time = [double]$parts[1]
            $size = [long]$parts[2]

            if ($httpCode -ne '200' -and $httpCode -ne '301' -and $httpCode -ne '302') { return }
            if ($size -lt $using:localMinSize) { return }

            [pscustomobject]@{ IP = $ip; Time = $time; Size = $size }
        } -ThrottleLimit $localBatch)

        if ($results) {
            $best = $results | Sort-Object Time | Select-Object -First 1
            return @{ IP = $best.IP; Time = $best.Time; Size = $best.Size }
        }
    }

    return $null
}

# ---------------------------------------------------------------------------
# Invoke-ScanAll: priority first, CIDR fallback
# ---------------------------------------------------------------------------
function Invoke-ScanAll {
    <#
    .SYNOPSIS
    Try priority IPs first. If none found, fall back to full CIDR scan.
    Returns hashtable { IP, Time, Size } or $null.
    #>
    Write-Log -Message "Starting scan (priority IPs first)..."
    $result = Test-PriorityIp
    if ($result) {
        Write-Log -Message "Priority scan found IP: $($result.IP) in $($result.Time)s"
        return $result
    }

    Write-Log -Message "No priority IPs working. Starting CIDR batch scan..."
    $result = Test-CidrRange
    if ($result) {
        Write-Log -Message "CIDR scan found IP: $($result.IP) in $($result.Time)s"
    } else {
        Write-Log -Message "CIDR scan: no working IP found"
    }
    return $result
}
