# tests/test-ps-00-constants.ps1
# Verifies all data constants in ps1/lib/00-constants.ps1 are well-formed.
$ErrorActionPreference = 'Stop'

$repoRoot = (Split-Path -Parent $PSScriptRoot)
. "$PSScriptRoot\lib\test-helpers.ps1"

# Source the module
. "$repoRoot\ps1\lib\00-constants.ps1"

# ── Test functions ─────────────────────────────────────────────────────

function Test_MarkersDefined {
    Assert-NotEmpty $script:MARKER_START "MARKER_START"
    Assert-NotEmpty $script:MARKER_END   "MARKER_END"
    Assert-Equals '# >>> goto-github >>>' $script:MARKER_START
    Assert-Equals '# <<< goto-github <<<' $script:MARKER_END
}

function Test_SchedulerConfig {
    Assert-NotEmpty $script:SCHEDULER_LABEL
    Assert-MatchesRegex $script:SCHEDULER_LABEL '^[a-z]+\.[a-z]+\.[a-z\-]+$'
    Assert-Equals 10800 $script:SCHEDULER_INTERVAL "Should be 3h in seconds"
}

function Test_PriorityIpsValid {
    foreach ($i in 0..7) {
        $var = Get-Variable -Name "PRIORITY_IPS_$i" -Scope Script
        $ip = $var.Value
        Assert-MatchesRegex $ip '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' "PRIORITY_IPS_$i must be IPv4"
    }
}

function Test_CidrRangesValid {
    foreach ($i in 0..3) {
        $var = Get-Variable -Name "CIDR_RANGES_$i" -Scope Script
        $cidr = $var.Value
        Assert-MatchesRegex $cidr '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$' "CIDR_RANGES_$i must be CIDR"
    }
}

function Test_CoreDomainsValid {
    foreach ($i in 0..7) {
        $var = Get-Variable -Name "CORE_DOMAINS_$i" -Scope Script
        $dom = $var.Value
        Assert-NotEmpty $dom "CORE_DOMAINS_$i must be defined"
        Assert-MatchesRegex $dom '^[a-zA-Z0-9][a-zA-Z0-9\-]*\.[a-zA-Z0-9\-]+' "CORE_DOMAINS_$i must look like a domain"
    }
}

function Test_CoreDomainsContainsGithub {
    $found = $false
    foreach ($i in 0..7) {
        $var = Get-Variable -Name "CORE_DOMAINS_$i" -Scope Script
        if ($var.Value -eq 'github.com') { $found = $true; break }
    }
    Assert-True $found "CORE_DOMAINS must contain 'github.com'"
}

function Test_TuningConstants {
    Assert-MatchesRegex "$script:CONCURRENT_BATCH" '^[1-9][0-9]*$'
    Assert-MatchesRegex "$script:CONNECT_TIMEOUT"   '^[1-9][0-9]*$'
    Assert-MatchesRegex "$script:MAX_TIME"          '^[1-9][0-9]*$'
    Assert-MatchesRegex "$script:MIN_CONTENT_SIZE"  '^[1-9][0-9]*$'
    if ($script:CONNECT_TIMEOUT -ge $script:MAX_TIME) { return $false }
    if ($script:MIN_CONTENT_SIZE -le 0) { return $false }
    return $true
}

function Test_HostsFilePath {
    Assert-Equals "$env:SystemRoot\System32\drivers\etc\hosts" $script:HOSTS_FILE
}

function Test_InstallDir {
    Assert-NotEmpty $script:INSTALL_DIR
}

function Test_PriorityIpsArrayMatchesScalars {
    # $script:PRIORITY_IPS should have 8 entries matching PRIORITY_IPS_0..7
    if ($script:PRIORITY_IPS.Count -ne 8) { return $false }
    for ($i = 0; $i -lt 8; $i++) {
        $scalar = (Get-Variable -Name "PRIORITY_IPS_$i" -Scope Script).Value
        if ($script:PRIORITY_IPS[$i] -ne $scalar) { return $false }
    }
    return $true
}

function Test_CidrRangesArrayMatchesScalars {
    if ($script:CIDR_RANGES.Count -ne 4) { return $false }
    for ($i = 0; $i -lt 4; $i++) {
        $scalar = (Get-Variable -Name "CIDR_RANGES_$i" -Scope Script).Value
        if ($script:CIDR_RANGES[$i] -ne $scalar) { return $false }
    }
    return $true
}

function Test_CoreDomainsArrayMatchesScalars {
    if ($script:CORE_DOMAINS.Count -ne 8) { return $false }
    for ($i = 0; $i -lt 8; $i++) {
        $scalar = (Get-Variable -Name "CORE_DOMAINS_$i" -Scope Script).Value
        if ($script:CORE_DOMAINS[$i] -ne $scalar) { return $false }
    }
    return $true
}

# ── Run all tests ──────────────────────────────────────────────────────

Test-Header
Run-Test "markers defined and correct"            { Test_MarkersDefined }
Run-Test "scheduler label and interval"           { Test_SchedulerConfig }
Run-Test "all 8 PRIORITY_IPS are valid IPv4"      { Test_PriorityIpsValid }
Run-Test "all 4 CIDR_RANGES are valid"            { Test_CidrRangesValid }
Run-Test "all 8 CORE_DOMAINS are valid"           { Test_CoreDomainsValid }
Run-Test "CORE_DOMAINS contains github.com"       { Test_CoreDomainsContainsGithub }
Run-Test "tuning constants are sane"              { Test_TuningConstants }
Run-Test "HOSTS_FILE points to System32\drivers\etc\hosts"  { Test_HostsFilePath }
Run-Test "INSTALL_DIR is set"                     { Test_InstallDir }
Run-Test "PRIORITY_IPS array matches scalars"     { Test_PriorityIpsArrayMatchesScalars }
Run-Test "CIDR_RANGES array matches scalars"      { Test_CidrRangesArrayMatchesScalars }
Run-Test "CORE_DOMAINS array matches scalars"     { Test_CoreDomainsArrayMatchesScalars }
$rc = Test-Report
exit $rc
