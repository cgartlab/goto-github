# tests/test-ps-01-utils.ps1
# Verifies utility functions in ps1/lib/01-utils.ps1: Read-Cache, Write-Cache,
# Clear-Cache, Write-Log, Find-Curl, Get-DoHState, Test-IsAdmin, Test-IsSystem.
$ErrorActionPreference = 'Stop'

$repoRoot = (Split-Path -Parent $PSScriptRoot)
. "$PSScriptRoot\lib\test-helpers.ps1"

# Override LOCALAPPDATA so sourced constants point to temp dir
$env:LOCALAPPDATA = $script:TestTmpDir
. "$repoRoot\ps1\lib\00-constants.ps1"
. "$repoRoot\ps1\lib\01-utils.ps1"

# ── Test functions ─────────────────────────────────────────────────────

function Test_ReadCache_Missing {
    $r = Read-Cache -Path (Join-Path $script:TestTmpDir 'nonexistent')
    Assert-Equals $null $r "Missing file should return `$null"
}

function Test_WriteCache_RoundTrip {
    $f = New-TestFile
    $ok = Write-Cache -Path $f -Value '140.82.112.3'
    Assert-True $ok "Write-Cache should succeed"
    Assert-FileExists $f
    Assert-FileContains $f '140.82.112.3'
    $r = Read-Cache -Path $f
    Assert-Equals '140.82.112.3' $r
}

function Test_WriteCache_CreatesParentDir {
    $f = Join-Path $script:TestTmpDir 'nested/deep/cache'
    $ok = Write-Cache -Path $f -Value 'value'
    Assert-True $ok
    Assert-FileExists $f
    Assert-FileContains $f 'value'
}

function Test_ClearCache_Removes {
    $f = New-TestFile
    'old' | Set-Content -LiteralPath $f -NoNewline
    Assert-FileExists $f
    Clear-Cache -Path $f
    if (Test-Path $f) { return $false }
    return $true
}

function Test_ClearCache_Idempotent {
    # Should not throw on missing file
    Clear-Cache -Path (Join-Path $script:TestTmpDir 'nonexistent')
    return $true
}

function Test_WriteLog_WritesTimestamped {
    $script:LOG_FILE = Join-Path $script:TestTmpDir 'test.log'
    Write-Log -Message 'test message A'
    Write-Log -Message 'test message B'
    Assert-FileExists $script:LOG_FILE
    Assert-FileContains $script:LOG_FILE 'test message A'
    Assert-FileContains $script:LOG_FILE 'test message B'
    $first = Get-Content -LiteralPath $script:LOG_FILE -TotalCount 1
    # Format: [YYYY-MM-DD HH:MM:SS] message
    Assert-MatchesRegex $first '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]'
}

function Test_FindCurl_ReturnsPath {
    # curl.exe is bundled with Windows 10 1803+
    $r = Find-Curl
    if ($null -eq $r) { return $false }
    Assert-Contains "$r" 'curl' "Path should contain 'curl'"
}

function Test_TestIsAdmin_ReturnsBool {
    $r = Test-IsAdmin
    # Should be $true or $false, not throw
    if ($r -isnot [bool]) { return $false }
    return $true
}

function Test_TestIsSystem_ReturnsBool {
    $r = Test-IsSystem
    if ($r -isnot [bool]) { return $false }
    return $true
}

function Test_GetDoHState_HasExpectedShape {
    $r = Get-DoHState
    # Should be a hashtable with Explicit and AutoUpgrade keys
    if ($null -eq $r) { return $false }
    if (-not $r.ContainsKey('Explicit')) { return $false }
    if (-not $r.ContainsKey('AutoUpgrade')) { return $false }
    if ($r.Explicit -isnot [bool]) { return $false }
    if ($r.AutoUpgrade -isnot [bool]) { return $false }
    return $true
}

# ── Run all tests ──────────────────────────────────────────────────────

Test-Header
Run-Test "Read-Cache on missing file returns null"    { Test_ReadCache_Missing }
Run-Test "Write-Cache + Read-Cache round-trip"         { Test_WriteCache_RoundTrip }
Run-Test "Write-Cache creates parent directories"      { Test_WriteCache_CreatesParentDir }
Run-Test "Clear-Cache removes existing file"           { Test_ClearCache_Removes }
Run-Test "Clear-Cache is idempotent"                   { Test_ClearCache_Idempotent }
Run-Test "Write-Log writes timestamped message"        { Test_WriteLog_WritesTimestamped }
Run-Test "Find-Curl returns path to curl.exe"          { Test_FindCurl_ReturnsPath }
Run-Test "Test-IsAdmin returns bool"                   { Test_TestIsAdmin_ReturnsBool }
Run-Test "Test-IsSystem returns bool"                  { Test_TestIsSystem_ReturnsBool }
Run-Test "Get-DoHState returns hashtable with keys"    { Test_GetDoHState_HasExpectedShape }
$rc = Test-Report
exit $rc
