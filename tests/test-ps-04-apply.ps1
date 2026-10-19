# tests/test-ps-04-apply.ps1
# Verifies ps1/lib/04-apply.ps1: Set-HostsBlock, Clear-Hosts, Get-HostsStatus.
# Uses a temp hosts file to avoid touching the real one.
$ErrorActionPreference = 'Stop'

$repoRoot = (Split-Path -Parent $PSScriptRoot)
. "$PSScriptRoot\lib\test-helpers.ps1"

$env:LOCALAPPDATA = $script:TestTmpDir
. "$repoRoot\ps1\lib\00-constants.ps1"
. "$repoRoot\ps1\lib\01-utils.ps1"
. "$repoRoot\ps1\lib\02-scan.ps1"  # Get-HostsStatus -> Verify-Hosts -> Test-Ip
. "$repoRoot\ps1\lib\03-validate.ps1"
. "$repoRoot\ps1\lib\04-apply.ps1"

# Override paths to temp locations
$script:HOSTS_FILE = New-TestFile
$script:CACHE_FILE = New-TestFile
$script:LOG_FILE = New-TestFile

# Mock Find-Curl so Verify-Hosts -> Test-Ip doesn't hit the network
$mockCurl = Join-Path $repoRoot 'tests\mocks\mock-curl.cmd'
function Find-Curl { return $mockCurl }

# Pre-existing hosts content (so we can verify it's preserved)
$preExistingContent = @"
# Pre-existing hosts file
127.0.0.1 localhost
::1 localhost
"@
Set-Content -LiteralPath $script:HOSTS_FILE -Value $preExistingContent -NoNewline

# ── Test functions ─────────────────────────────────────────────────────

function Test_SetHostsBlock_AddsBlock {
    Set-HostsBlock -IP '140.82.112.3'
    Assert-FileExists $script:HOSTS_FILE
    Assert-FileContains $script:HOSTS_FILE $script:MARKER_START
    Assert-FileContains $script:HOSTS_FILE $script:MARKER_END
    Assert-FileContains $script:HOSTS_FILE '140.82.112.3 github.com'
    Assert-FileContains $script:HOSTS_FILE '140.82.112.3 www.github.com'
}

function Test_SetHostsBlock_PreservesExistingContent {
    Set-HostsBlock -IP '140.82.112.3'
    Assert-FileContains $script:HOSTS_FILE '127.0.0.1 localhost'
    Assert-FileContains $script:HOSTS_FILE '::1 localhost'
    Assert-FileContains $script:HOSTS_FILE '# Pre-existing hosts file'
}

function Test_SetHostsBlock_UpdatesCache {
    Set-HostsBlock -IP '140.82.112.3'
    Assert-FileExists $script:CACHE_FILE
    $cache = Get-Content -LiteralPath $script:CACHE_FILE -Raw
    Assert-Contains $cache '140.82.112.3'
}

function Test_SetHostsBlock_Idempotent {
    Set-HostsBlock -IP '140.82.112.3'
    Set-HostsBlock -IP '140.82.112.3'
    Set-HostsBlock -IP '140.82.112.3'
    # Should still have exactly one block
    $content = Get-Content -LiteralPath $script:HOSTS_FILE -Raw
    $startCount = ([regex]::Matches($content, [regex]::Escape($script:MARKER_START))).Count
    $endCount = ([regex]::Matches($content, [regex]::Escape($script:MARKER_END))).Count
    Assert-Equals 1 $startCount "Marker start should appear exactly once after 3 inserts"
    Assert-Equals 1 $endCount
}

function Test_SetHostsBlock_ReplacesExistingBlock {
    Set-HostsBlock -IP '140.82.112.3'
    Set-HostsBlock -IP '185.199.108.153'
    # New IP should be present, old IP should not
    Assert-FileContains $script:HOSTS_FILE '185.199.108.153'
    # The marker block should now have 185.199.108.153 for all domains
    $content = Get-Content -LiteralPath $script:HOSTS_FILE -Raw
    # 8 lines like "185.199.108.153 <domain>"
    $ipLineCount = ([regex]::Matches($content, '185\.199\.108\.153 [a-z]')).Count
    Assert-Equals 8 $ipLineCount "All 8 domains should map to new IP"
}

function Test_ClearHosts_RemovesBlock {
    Set-HostsBlock -IP '140.82.112.3'
    Assert-FileContains $script:HOSTS_FILE $script:MARKER_START
    Clear-Hosts
    Assert-FileNotContains $script:HOSTS_FILE $script:MARKER_START
    Assert-FileNotContains $script:HOSTS_FILE '140.82.112.3'
}

function Test_ClearHosts_PreservesExistingContent {
    Set-HostsBlock -IP '140.82.112.3'
    Clear-Hosts
    Assert-FileContains $script:HOSTS_FILE '127.0.0.1 localhost'
    Assert-FileContains $script:HOSTS_FILE '::1 localhost'
}

function Test_ClearHosts_Idempotent {
    Clear-Hosts
    Clear-Hosts
    Clear-Hosts
    return $true  # should not throw
}

function Test_GetHostsStatus_NotInstalled {
    # Clear cache so the status reports "no cached IP"
    Clear-Cache -Path $script:CACHE_FILE
    $status = Get-HostsStatus
    Assert-Contains $status 'Current IP: (none)'
    Assert-Contains $status 'Not installed'
    Assert-Contains $status 'Cached IP:  (none)'
}

function Test_GetHostsStatus_WithEntry {
    Set-HostsBlock -IP '140.82.112.3'
    $status = Get-HostsStatus
    Assert-Contains $status 'Current IP: 140.82.112.3'
    Assert-Contains $status 'Cached IP:  140.82.112.3'
}

# Helper for negative assertion (since helpers only have Contains)
function Assert-FileNotContains {
    param([string]$Path, [string]$Needle)
    $content = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ($content -and $content.Contains($Needle)) { return $false }
    return $true
}

# ── Run all tests ──────────────────────────────────────────────────────

Test-Header
Run-Test "Set-HostsBlock adds marker block"             { Test_SetHostsBlock_AddsBlock }
Run-Test "Set-HostsBlock preserves existing content"    { Test_SetHostsBlock_PreservesExistingContent }
Run-Test "Set-HostsBlock updates cache"                 { Test_SetHostsBlock_UpdatesCache }
Run-Test "Set-HostsBlock is idempotent"                 { Test_SetHostsBlock_Idempotent }
Run-Test "Set-HostsBlock replaces existing block"       { Test_SetHostsBlock_ReplacesExistingBlock }
Run-Test "Clear-Hosts removes the block"                { Test_ClearHosts_RemovesBlock }
Run-Test "Clear-Hosts preserves existing content"        { Test_ClearHosts_PreservesExistingContent }
Run-Test "Clear-Hosts is idempotent"                    { Test_ClearHosts_Idempotent }
Run-Test "Get-HostsStatus: not installed"               { Test_GetHostsStatus_NotInstalled }
Run-Test "Get-HostsStatus: with entry"                  { Test_GetHostsStatus_WithEntry }
$rc = Test-Report
exit $rc
