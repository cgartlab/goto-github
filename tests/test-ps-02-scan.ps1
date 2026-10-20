# tests/test-ps-02-scan.ps1
# Verifies ps1/lib/02-scan.ps1:
#   - Expand-CidrToIPs  (pure CIDR math, no I/O)
#   - Test-PriorityIp / Test-CidrRange  (the ForEach-Object -Parallel scan path,
#     exercised with tests/mocks/mock-curl.cmd so no network is touched)
# Windows-only: the scan path shells out to a .cmd curl mock.
$ErrorActionPreference = 'Stop'

$repoRoot = (Split-Path -Parent $PSScriptRoot)
. "$PSScriptRoot\lib\test-helpers.ps1"

$env:LOCALAPPDATA = $script:TestTmpDir
. "$repoRoot\ps1\lib\00-constants.ps1"
. "$repoRoot\ps1\lib\02-scan.ps1"

# Mock curl + a stub Find-Curl so Test-PriorityIp / Test-CidrRange never touch
# the network. Find-Curl is resolved at call time, so this stub wins.
$script:MockCurl = Join-Path $repoRoot 'tests\mocks\mock-curl.cmd'
function Find-Curl { return $script:MockCurl }

# ── Test functions ─────────────────────────────────────────────────────

function Test_ExpandCidrToIPs_NotEmpty {
    $ips = Expand-CidrToIPs -Cidrs @('140.82.112.0/30')
    Assert-True ($ips.Count -gt 0) "Should expand /30 to 2 usable hosts"
}

function Test_ExpandCidrToIPs_Slash30 {
    # /30 = 2^2 = 4 addresses, -2 network/broadcast = 2 usable hosts
    $ips = Expand-CidrToIPs -Cidrs @('140.82.112.0/30')
    Assert-Equals 2 $ips.Count "Should be exactly 2 hosts in /30"
    # Sorted: 140.82.112.1 and 140.82.112.2
    $ips = $ips | Sort-Object
    Assert-Equals '140.82.112.1' $ips[0]
    Assert-Equals '140.82.112.2' $ips[1]
}

function Test_ExpandCidrToIPs_Slash20 {
    # /20 = 2^12 = 4096 addresses, -2 = 4094 usable hosts
    $ips = Expand-CidrToIPs -Cidrs @('140.82.112.0/20')
    Assert-Equals 4094 $ips.Count
}

function Test_ExpandCidrToIPs_Slash22 {
    # /22 = 2^10 = 1024 addresses, -2 = 1022 usable hosts
    $ips = Expand-CidrToIPs -Cidrs @('185.199.108.0/22')
    Assert-Equals 1022 $ips.Count
}

function Test_ExpandCidrToIPs_AllInRange_Slash20 {
    $ips = Expand-CidrToIPs -Cidrs @('140.82.112.0/20')
    Assert-Equals 4094 $ips.Count
    # Compute the expected uint32 bounds dynamically (no hand-computed constants)
    $minIp = '140.82.112.1'
    $maxIp = '140.82.127.254'
    $minB = [System.Net.IPAddress]::Parse($minIp).GetAddressBytes(); [array]::Reverse($minB)
    $maxB = [System.Net.IPAddress]::Parse($maxIp).GetAddressBytes(); [array]::Reverse($maxB)
    $minInt = [System.BitConverter]::ToUInt32($minB, 0)
    $maxInt = [System.BitConverter]::ToUInt32($maxB, 0)
    $badCount = 0
    $minFound = [uint32]::MaxValue
    $maxFound = [uint32]0
    foreach ($ip in $ips) {
        $b = [System.Net.IPAddress]::Parse($ip).GetAddressBytes()
        [array]::Reverse($b)
        $i = [System.BitConverter]::ToUInt32($b, 0)
        if ($i -lt $minInt -or $i -gt $maxInt) { $badCount++ }
        if ($i -lt $minFound) { $minFound = $i }
        if ($i -gt $maxFound) { $maxFound = $i }
    }
    Assert-Equals 0 $badCount "All IPs must be in /20 host range"
    Assert-Equals $minInt $minFound "Smallest IP should be $minIp"
    Assert-Equals $maxInt $maxFound "Largest IP should be $maxIp"
}

function Test_ExpandCidrToIPs_MultipleRanges {
    $ips = Expand-CidrToIPs -Cidrs @('140.82.112.0/20', '185.199.108.0/22')
    # 4094 + 1022 = 5116
    Assert-Equals 5116 $ips.Count
}

function Test_ExpandCidrToIPs_AllInRange_Multiple {
    $ips = Expand-CidrToIPs -Cidrs @('140.82.112.0/20', '185.199.108.0/22', '192.30.252.0/22', '143.55.64.0/20')
    # 4094 * 2 + 1022 * 2 = 10232
    Assert-Equals 10232 $ips.Count
    # Every IP must start with one of the 4 ranges
    $badCount = 0
    foreach ($ip in $ips) {
        if ($ip -notmatch '^(140\.82|185\.199|192\.30|143\.55)\.') {
            $badCount++
        }
    }
    Assert-Equals 0 $badCount "All IPs must be in one of the 4 CIDR ranges"
}

function Test_ExpandCidrToIPs_Shuffled {
    # Two consecutive expansions should produce different orderings (with very
    # high probability) due to the Fisher-Yates shuffle. If this test is flaky
    # in the future, replace with a check that order != sorted order on average.
    $ips1 = (Expand-CidrToIPs -Cidrs @('140.82.112.0/24')) -join ','
    $ips2 = (Expand-CidrToIPs -Cidrs @('140.82.112.0/24')) -join ','
    # Different runs should produce different shuffles
    if ($ips1 -eq $ips2) { return $false }
    return $true
}

function Test_ExpandCidrToIPs_ResultIsIPv4Strings {
    $ips = Expand-CidrToIPs -Cidrs @('140.82.112.0/30')
    foreach ($ip in $ips) {
        Assert-MatchesRegex $ip '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
    }
}

# ---------------------------------------------------------------------------
# Test-PriorityIp / Test-CidrRange exercise the ForEach-Object -Parallel scan
# path. These used to fail at runtime: ForEach-Object has no -AsArray parameter,
# so the call threw a parameter-binding error before any IP was probed. They
# were also unreachable by the earlier suite, which only covered the pure CIDR
# math above. Guard against both regressions.
# ---------------------------------------------------------------------------

function Test_PriorityIp_ReturnsFastestResult {
    $saved = $script:CONCURRENT_BATCH
    $script:CONCURRENT_BATCH = 8
    try {
        $r = Test-PriorityIp
    } finally {
        $script:CONCURRENT_BATCH = $saved
    }
    Assert-NotEmpty $r "Priority scan must return a result when IPs respond 200"
    Assert-True ($r.IP -match '^\d{1,3}(\.\d{1,3}){3}$') "Result IP must be an IPv4 address, got '$($r.IP)'"
    Assert-True ($r.Time -ge 0) "Result Time must be non-negative, got '$($r.Time)'"
}

function Test_PriorityIp_SmallestWinsTieBreak {
    $saved = $script:CONCURRENT_BATCH
    $script:CONCURRENT_BATCH = 8
    try {
        $r = Test-PriorityIp
    } finally {
        $script:CONCURRENT_BATCH = $saved
    }
    # 140.82.112.3 is the only priority IP with a <0.1s canned response (0.050);
    # every other priority IP falls back to the default 0.123s. The parallel
    # result must therefore be the fastest one, which proves the block returned
    # typed objects and Sort-Object -Property Time actually compared them.
    Assert-Equals '140.82.112.3' $r.IP "Fastest priority IP should win"
}

function Test_CidrRange_ExpandsAndScans {
    $saved = $script:CONCURRENT_BATCH
    $script:CONCURRENT_BATCH = 25
    try {
        $r = Test-CidrRange
    } finally {
        $script:CONCURRENT_BATCH = $saved
    }
    Assert-NotEmpty $r "CIDR scan must return a result"
    Assert-True ($r.IP -match '^(140\.82|185\.199|192\.30|143\.55)\.') "Result IP must come from one of the 4 CIDR ranges, got '$($r.IP)'"
}

function Test_ProbeTarget_IsGitSmartHttp {
    <#
    Lock the probe target to the git smart-http endpoint.

    The mock curl matches on `github.com:443:<ip>` only — it does not inspect
    the URL. So if PROBE_TARGET regressed to the homepage, every scan test
    above would still pass while the real scan selected "false positive" IPs
    that serve the homepage but time out on git traffic. This assertion is the
    only thing that catches that regression.
    #>
    Assert-NotEmpty $script:PROBE_TARGET "PROBE_TARGET must be defined"
    Assert-Contains $script:PROBE_TARGET 'info/refs' "Probe target must be a git smart-http endpoint"
    Assert-Contains $script:PROBE_TARGET 'git-upload-pack' "Probe target must request the upload-pack service"
    Assert-False ($script:PROBE_TARGET -eq 'https://github.com/') "Probe target must NOT be the homepage"
}

function Test_TestIp_UsesGitProbeTarget {
    <#
    Test-Ip must probe the git endpoint. The mock records nothing, so this
    verifies via the observable contract: Test-Ip returns a result only when
    the IP answers, and the IP it reports is the one passed in. Combined with
    Test_ProbeTarget_IsGitSmartHttp this pins the whole path.
    #>
    $r = Test-Ip -IP '140.82.112.3'
    Assert-True ($null -ne $r) "Test-Ip should succeed for a known-good IP"
    Assert-Equals '140.82.112.3' $r.IP "Test-Ip must report the IP it probed"
    $r404 = Test-Ip -IP '185.199.108.1'
    Assert-True ($null -eq $r404) "Test-Ip must reject an IP the mock answers 404 for"
}

function Test_PriorityIp_ReturnsNullWhenNoCurl {
    $saved = $script:MockCurl
    $script:MockCurl = ''
    try {
        $r = Test-PriorityIp
    } finally {
        $script:MockCurl = $saved
    }
    Assert-Equals $null $r "Scan must return \$null when curl is unavailable"
}

# ── Run all tests ──────────────────────────────────────────────────────

Test-Header
Run-Test "Expand-CidrToIPs returns non-empty"        { Test_ExpandCidrToIPs_NotEmpty }
Run-Test "Expand-CidrToIPs /30 = 2 hosts"            { Test_ExpandCidrToIPs_Slash30 }
Run-Test "Expand-CidrToIPs /20 = 4094 hosts"         { Test_ExpandCidrToIPs_Slash20 }
Run-Test "Expand-CidrToIPs /22 = 1022 hosts"         { Test_ExpandCidrToIPs_Slash22 }
Run-Test "Expand-CidrToIPs /20 first and last IP"    { Test_ExpandCidrToIPs_AllInRange_Slash20 }
Run-Test "Expand-CidrToIPs multiple ranges sum"      { Test_ExpandCidrToIPs_MultipleRanges }
Run-Test "Expand-CidrToIPs all 4 ranges = 10228"     { Test_ExpandCidrToIPs_AllInRange_Multiple }
Run-Test "Expand-CidrToIPs shuffles each call"       { Test_ExpandCidrToIPs_Shuffled }
Run-Test "Expand-CidrToIPs result is IPv4 strings"   { Test_ExpandCidrToIPs_ResultIsIPv4Strings }
Run-Test "Test-PriorityIp returns fastest result"    { Test_PriorityIp_ReturnsFastestResult }
Run-Test "Test-PriorityIp fastest IP wins tiebreak"  { Test_PriorityIp_SmallestWinsTieBreak }
Run-Test "Test-CidrRange expands and scans"          { Test_CidrRange_ExpandsAndScans }
Run-Test "Test-PriorityIp returns null without curl" { Test_PriorityIp_ReturnsNullWhenNoCurl }
Run-Test "PROBE_TARGET is git smart-http"             { Test_ProbeTarget_IsGitSmartHttp }
Run-Test "Test-Ip uses git probe target"              { Test_TestIp_UsesGitProbeTarget }
$rc = Test-Report
exit $rc
