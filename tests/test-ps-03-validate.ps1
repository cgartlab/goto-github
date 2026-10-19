# tests/test-ps-03-validate.ps1
# Verifies ps1/lib/03-validate.ps1: Get-IpFromHosts, Test-IpQuick.
# Uses tests/mocks/mock-curl.ps1 to avoid real network calls.
$ErrorActionPreference = 'Stop'

$repoRoot = (Split-Path -Parent $PSScriptRoot)
. "$PSScriptRoot\lib\test-helpers.ps1"

$env:LOCALAPPDATA = $script:TestTmpDir
. "$repoRoot\ps1\lib\00-constants.ps1"
. "$repoRoot\ps1\lib\01-utils.ps1"
. "$repoRoot\ps1\lib\03-validate.ps1"

# Mock Find-Curl to return our .cmd mock path.
# .cmd is used instead of .ps1 because PowerShell's call operator parses args
# as PS parameters, which breaks for `-o NUL` (ambiguous with -OutVariable).
$mockCurl = Join-Path $repoRoot 'tests\mocks\mock-curl.cmd'
function Find-Curl { return $mockCurl }

# ── Test functions ─────────────────────────────────────────────────────

function Test_GetIpFromHosts_NoFile {
    $script:HOSTS_FILE = Join-Path $script:TestTmpDir 'nonexistent'
    $r = Get-IpFromHosts
    Assert-Equals $null $r "Missing hosts file should return `$null"
}

function Test_GetIpFromHosts_EmptyFile {
    $f = New-TestFile
    $script:HOSTS_FILE = $f
    $r = Get-IpFromHosts
    Assert-Equals $null $r
}

function Test_GetIpFromHosts_NoMarker {
    $f = New-TestFile
    '127.0.0.1 localhost' | Set-Content -LiteralPath $f
    $script:HOSTS_FILE = $f
    $r = Get-IpFromHosts
    Assert-Equals $null $r "No marker block should return null"
}

function Test_GetIpFromHosts_ValidIP {
    $f = New-TestFile
    @"
# Some comment
127.0.0.1 localhost
$($script:MARKER_START)
# Managed by goto-github
140.82.112.3 github.com
140.82.112.3 www.github.com
$($script:MARKER_END)
# Another comment
"@ | Set-Content -LiteralPath $f
    $script:HOSTS_FILE = $f
    $r = Get-IpFromHosts
    Assert-Equals '140.82.112.3' $r
}

function Test_GetIpFromHosts_ContentOutsideMarkersIgnored {
    $f = New-TestFile
    @"
# Some comment
8.8.8.8 fake-dns-server
$($script:MARKER_START)
185.199.108.153 gist.github.com
$($script:MARKER_END)
1.2.3.4 not-managed-here
"@ | Set-Content -LiteralPath $f
    $script:HOSTS_FILE = $f
    $r = Get-IpFromHosts
    Assert-Equals '185.199.108.153' $r "Only the IP inside the marker block should be returned"
}

function Test_GetIpFromHosts_EmptyMarkerBlock {
    $f = New-TestFile
    @"
$($script:MARKER_START)
# only comments, no IP
$($script:MARKER_END)
"@ | Set-Content -LiteralPath $f
    $script:HOSTS_FILE = $f
    $r = Get-IpFromHosts
    Assert-Equals $null $r "Marker block with no IP line should return null"
}

function Test_GetIpFromHosts_MarkerNotAtStart {
    $f = New-TestFile
    @"
# pre-existing content
$($script:MARKER_START)
192.30.252.1 alive.github.com
$($script:MARKER_END)
# post content
"@ | Set-Content -LiteralPath $f
    $script:HOSTS_FILE = $f
    $r = Get-IpFromHosts
    Assert-Equals '192.30.252.1' $r
}

function Test_TestIpQuick_ReachableIP {
    # 140.82.112.3 in our mock returns 200 → true
    $r = Test-IpQuick -IP '140.82.112.3'
    Assert-True $r "Mock returns 200 → should be reachable"
}

function Test_TestIpQuick_ServerError {
    # 140.82.112.4 in our mock returns 500 → false
    $r = Test-IpQuick -IP '140.82.112.4'
    Assert-False $r "Mock returns 500 → should NOT be reachable"
}

function Test_TestIpQuick_NotFound {
    # 185.199.* in our mock returns 404 → false
    $r = Test-IpQuick -IP '185.199.108.153'
    Assert-False $r "Mock returns 404 → should NOT be reachable"
}

function Test_TestIpQuick_NoCurl {
    # Override Find-Curl to return $null
    function Find-Curl { return $null }
    $r = Test-IpQuick -IP '140.82.112.3'
    Assert-False $r "No curl → should return false"
    # Restore mock
    function Find-Curl { return $mockCurl }
}

# ── Run all tests ──────────────────────────────────────────────────────

Test-Header
Run-Test "Get-IpFromHosts: no file → null"              { Test_GetIpFromHosts_NoFile }
Run-Test "Get-IpFromHosts: empty file → null"           { Test_GetIpFromHosts_EmptyFile }
Run-Test "Get-IpFromHosts: no marker → null"            { Test_GetIpFromHosts_NoMarker }
Run-Test "Get-IpFromHosts: valid IP in block"           { Test_GetIpFromHosts_ValidIP }
Run-Test "Get-IpFromHosts: ignores content outside markers"  { Test_GetIpFromHosts_ContentOutsideMarkersIgnored }
Run-Test "Get-IpFromHosts: empty marker block → null"   { Test_GetIpFromHosts_EmptyMarkerBlock }
Run-Test "Get-IpFromHosts: marker not at start of file"  { Test_GetIpFromHosts_MarkerNotAtStart }
Run-Test "Test-IpQuick: reachable IP → true"            { Test_TestIpQuick_ReachableIP }
Run-Test "Test-IpQuick: 500 → false"                    { Test_TestIpQuick_ServerError }
Run-Test "Test-IpQuick: 404 → false"                    { Test_TestIpQuick_NotFound }
Run-Test "Test-IpQuick: no curl → false"                { Test_TestIpQuick_NoCurl }
$rc = Test-Report
exit $rc
