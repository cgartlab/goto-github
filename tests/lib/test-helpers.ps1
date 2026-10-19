# tests/lib/test-helpers.ps1
# Vendored zero-dependency test framework for goto-github PowerShell port.
# Dot-source this in your test-ps-*.ps1 file, then call Run-Test and Assert-*.
#
# Design: Assert-* functions print messages on failure and set a flag.
# Run-Test checks the flag after the test runs. This is more reliable than
# relying on PowerShell function return values, which can be confusing with
# multiple outputs and `return` semantics.
#
# Usage:
#   . $PSScriptRoot\lib\test-helpers.ps1
#
#   function Test_ConstantsHaveValues {
#       Assert-NotEmpty $script:MARKER_START "MARKER_START should be defined"
#   }
#
#   Test-Header
#   Run-Test "constants have values" ${function:Test_ConstantsHaveValues}
#   Test-Report
#   exit $LASTEXITCODE

$script:TestCount = 0
$script:PassCount = 0
$script:FailCount = 0
$script:CurrentTest = ''
$script:AssertFailed = $false
$script:TestTmpDir = ''

# Per-test-file temp dir, auto-cleaned on exit
$script:TestTmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("goto-github-test-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $script:TestTmpDir -Force | Out-Null
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    if ($script:TestTmpDir -and (Test-Path $script:TestTmpDir)) {
        Remove-Item -LiteralPath $script:TestTmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-Header {
    $name = if ($MyInvocation.PSCommandPath) { Split-Path $MyInvocation.PSCommandPath -Leaf } else { 'test' }
    Write-Host ""
    Write-Host "── $name ──" -ForegroundColor DarkGray
}

# ── Assertions ──────────────────────────────────────────────────────────
# Each Assert-* function:
#   - On pass: returns silently
#   - On fail: prints a message AND sets $script:AssertFailed = $true
# Run-Test checks the flag after the test function completes.

function Assert-Equals {
    param($Expected, $Actual, [string]$Message = '')
    if ($Expected -eq $Actual) { return }
    Write-Host "  FAIL: $script:CurrentTest" -ForegroundColor Red
    Write-Host "    Expected: '$Expected'"
    Write-Host "    Actual:   '$Actual'"
    if ($Message) { Write-Host "    Message:  $Message" }
    $script:AssertFailed = $true
}

function Assert-NotEquals {
    param($Unexpected, $Actual, [string]$Message = '')
    if ($Unexpected -ne $Actual) { return }
    Write-Host "  FAIL: $script:CurrentTest" -ForegroundColor Red
    Write-Host "    Expected NOT: '$Unexpected'"
    Write-Host "    Actual:        '$Actual'"
    if ($Message) { Write-Host "    Message:  $Message" }
    $script:AssertFailed = $true
}

function Assert-NotEmpty {
    param($Actual, [string]$Message = '')
    if ($null -ne $Actual -and "$Actual" -ne '') { return }
    Write-Host "  FAIL: $script:CurrentTest" -ForegroundColor Red
    Write-Host "    Expected: non-empty value"
    Write-Host "    Actual:   '$Actual'"
    if ($Message) { Write-Host "    Message:  $Message" }
    $script:AssertFailed = $true
}

function Assert-True {
    param([bool]$Actual, [string]$Message = '')
    if ($Actual) { return }
    Write-Host "  FAIL: $script:CurrentTest" -ForegroundColor Red
    Write-Host "    Expected: true"
    Write-Host "    Actual:   '$Actual'"
    if ($Message) { Write-Host "    Message:  $Message" }
    $script:AssertFailed = $true
}

function Assert-False {
    param([bool]$Actual, [string]$Message = '')
    if (-not $Actual) { return }
    Write-Host "  FAIL: $script:CurrentTest" -ForegroundColor Red
    Write-Host "    Expected: false"
    Write-Host "    Actual:   '$Actual'"
    if ($Message) { Write-Host "    Message:  $Message" }
    $script:AssertFailed = $true
}

function Assert-Contains {
    param([string]$Haystack, [string]$Needle, [string]$Message = '')
    if ($Haystack -and $Haystack.Contains($Needle)) { return }
    Write-Host "  FAIL: $script:CurrentTest" -ForegroundColor Red
    Write-Host "    Haystack: '$Haystack'"
    Write-Host "    Needle:   '$Needle'"
    if ($Message) { Write-Host "    Message:  $Message" }
    $script:AssertFailed = $true
}

function Assert-MatchesRegex {
    param([string]$String, [string]$Pattern, [string]$Message = '')
    if ($String -and $String -match $Pattern) { return }
    Write-Host "  FAIL: $script:CurrentTest" -ForegroundColor Red
    Write-Host "    String:   '$String'"
    Write-Host "    Pattern:  '$Pattern'"
    if ($Message) { Write-Host "    Message:  $Message" }
    $script:AssertFailed = $true
}

function Assert-FileExists {
    param([string]$Path, [string]$Message = '')
    if (Test-Path -LiteralPath $Path) { return }
    Write-Host "  FAIL: $script:CurrentTest" -ForegroundColor Red
    Write-Host "    Expected file: '$Path'"
    if ($Message) { Write-Host "    Message:  $Message" }
    $script:AssertFailed = $true
}

function Assert-FileNotExists {
    param([string]$Path, [string]$Message = '')
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Write-Host "  FAIL: $script:CurrentTest" -ForegroundColor Red
    Write-Host "    Expected file to NOT exist: '$Path'"
    if ($Message) { Write-Host "    Message:  $Message" }
    $script:AssertFailed = $true
}

function Assert-FileContains {
    param([string]$Path, [string]$Needle, [string]$Message = '')
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "  FAIL: $script:CurrentTest (file missing)" -ForegroundColor Red
        Write-Host "    Path: '$Path'"
        if ($Message) { Write-Host "    Message:  $Message" }
        $script:AssertFailed = $true
        return
    }
    $content = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ($content -and $content.Contains($Needle)) { return }
    Write-Host "  FAIL: $script:CurrentTest" -ForegroundColor Red
    Write-Host "    Path:   '$Path'"
    Write-Host "    Needle: '$Needle'"
    if ($Message) { Write-Host "    Message:  $Message" }
    $script:AssertFailed = $true
}

function Assert-FileNotContains {
    param([string]$Path, [string]$Needle, [string]$Message = '')
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $content = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if (-not $content -or -not $content.Contains($Needle)) { return }
    Write-Host "  FAIL: $script:CurrentTest" -ForegroundColor Red
    Write-Host "    Path:   '$Path'"
    Write-Host "    Should NOT contain: '$Needle'"
    if ($Message) { Write-Host "    Message:  $Message" }
    $script:AssertFailed = $true
}

# ── Test runner ─────────────────────────────────────────────────────────

function Run-Test {
    param([string]$Name, [scriptblock]$Test)
    $script:CurrentTest = $Name
    $script:TestCount++
    $script:AssertFailed = $false
    try {
        & $Test | Out-Null
        if ($script:AssertFailed) {
            $script:FailCount++
        } else {
            $script:PassCount++
            Write-Host "  PASS: $Name" -ForegroundColor Green
        }
    } catch {
        $script:FailCount++
        Write-Host "  FAIL: $Name (exception)" -ForegroundColor Red
        Write-Host "    Exception: $_"
    }
}

function Test-Report {
    Write-Host ""
    if ($script:FailCount -gt 0) {
        Write-Host "FAIL: $($script:FailCount) failed, $($script:PassCount) passed, $($script:TestCount) total" -ForegroundColor Red
        return 1
    } else {
        Write-Host "OK: $($script:PassCount) passed, $($script:TestCount) total" -ForegroundColor Green
        return 0
    }
}

# Helper: create a unique temp file in the test temp dir
function New-TestFile {
    param([string]$Suffix = '.tmp')
    return (Join-Path $script:TestTmpDir ([Guid]::NewGuid().ToString('N') + $Suffix))
}
