# tests/test-ps-02-scan.ps1
# Verifies the pure-math CIDR expansion in ps1/lib/02-scan.ps1:Expand-CidrToIPs.
# Does NOT test Test-Ip / Test-PriorityIp / Test-CidrRange (those need curl
# and are exercised by mock-curl.ps1 in test-ps-03-validate.ps1).
$ErrorActionPreference = 'Stop'

$repoRoot = (Split-Path -Parent $PSScriptRoot)
. "$PSScriptRoot\lib\test-helpers.ps1"

$env:LOCALAPPDATA = $script:TestTmpDir
. "$repoRoot\ps1\lib\00-constants.ps1"
. "$repoRoot\ps1\lib\02-scan.ps1"

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
$rc = Test-Report
exit $rc
