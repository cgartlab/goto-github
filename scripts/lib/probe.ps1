# scripts/lib/probe.ps1 -- shared sampling primitives (PowerShell twin)
#
# Mirrors scripts/lib/probe.sh so connectivity_probe and hosts_status measure
# identically; if they diverged a baseline could never be compared.
#
# PowerShell 5.1 compatible: no -Parallel, no ??, no ternary, no ::new()
# where a New-Object works. Every function takes attempts/timeout explicitly
# rather than reading globals.

if (Get-Variable -Name 'GOTO_GITHUB_PROBE_LOADED' -Scope Script -ErrorAction SilentlyContinue) { return }
$script:GOTO_GITHUB_PROBE_LOADED = $true

function ConvertTo-JsonLiteral {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return 'null' }
    $v = $Value.Replace('\', '\\').Replace('"', '\"')
    $v = $v.Replace("`r", '').Replace("`n", '\n').Replace("`t", '\t')
    return "`"$v`""
}

function Get-CurlPath {
    try { return (Get-Command curl.exe -ErrorAction Stop).Source } catch { return $null }
}

function Write-StderrWarning {
    <#
    .SYNOPSIS
        Emit a warning on stderr.
    .DESCRIPTION
        Write-Warning goes to the warning stream, which is forwarded to stdout
        when the caller captures output -- that would break the "stdout is
        exactly one JSON line" contract.
    #>
    param([string]$Message)
    [Console]::Error.WriteLine("WARNING: $Message")
}

# -- Summarise ok/fail/times into a hashtable --------------------------------
# Latency is $null (rendered as JSON null) when there were zero successes:
# 0.000 would claim a measurement that never happened.
function Format-ProbeResult {
    param([int]$Ok, [int]$Fail, [double[]]$Times)

    $result = @{ success = $Ok; fail = $Fail; min = $null; max = $null; avg = $null }
    if ($Times -and $Times.Count -gt 0) {
        $stats = $Times | Measure-Object -Minimum -Maximum -Average
        $result.min = [math]::Round($stats.Minimum, 3)
        $result.max = [math]::Round($stats.Maximum, 3)
        $result.avg = [math]::Round($stats.Average, 3)
    }
    return $result
}

function ConvertTo-LatencyJson {
    param($ProbeResult)
    if ($null -eq $ProbeResult.min) { return 'null' }
    # Concatenation, not -f: JSON braces would be parsed as format placeholders.
    $s = '{'
    $s += '"min":' + $ProbeResult.min + ','
    $s += '"max":' + $ProbeResult.max + ','
    $s += '"avg":' + $ProbeResult.avg
    $s += '}'
    return $s
}

# -- Sample an HTTP URL N times ----------------------------------------------
# rc=0 AND a real HTTP code (not 000) = success. 000 means no response at all:
# connection failed, timeout, or DNS failure. Counting it as success would
# report a fully blocked endpoint as "100% available".
function Invoke-HttpProbe {
    param(
        [string]$Url,
        [string]$Accept = '',
        [int]$Attempts = 10,
        [int]$Timeout = 5
    )

    $curl = Get-CurlPath
    if (-not $curl) { return (Format-ProbeResult -Ok 0 -Fail $Attempts -Times @()) }

    $times = New-Object System.Collections.Generic.List[double]
    $ok = 0
    $fail = 0

    for ($i = 1; $i -le $Attempts; $i++) {
        $curlArgs = @('--noproxy', '*', '-s', '-o', 'NUL',
                  '--connect-timeout', $Timeout, '--max-time', ($Timeout + 2),
                  '-w', '%{http_code},%{time_total}')
        if ($Accept) { $curlArgs += @('-H', "Accept: $Accept") }
        $curlArgs += $Url

        $out = & $curl @curlArgs 2>$null
        $rc = $LASTEXITCODE

        $parts = "$out" -split ','
        # Subexpression $(...): `if` is a statement, not an assignable expression.
        $code = $(if ($parts.Count -ge 1) { $parts[0] } else { '' })
        $t = $(if ($parts.Count -ge 2) { $parts[1] } else { '' })

        if ($rc -eq 0 -and $code -and $code -ne '000') {
            $ok++
            [double]$tv = 0
            if ([double]::TryParse($t, [ref]$tv)) { $times.Add($tv) }
        } else {
            $fail++
        }
    }

    return (Format-ProbeResult -Ok $ok -Fail $fail -Times $times.ToArray())
}

# -- Sample a git smart-http endpoint ----------------------------------------
# The Accept header matters: GitHub's smart-http handler answers differently
# without it, so omitting it measures the wrong thing.
function Invoke-GitSmartProbe {
    param([string]$Url, [int]$Attempts = 10, [int]$Timeout = 5)
    return (Invoke-HttpProbe -Url $Url `
        -Accept 'application/x-git-upload-pack-advertisement' `
        -Attempts $Attempts -Timeout $Timeout)
}

# -- TCP reachability --------------------------------------------------------
# Measures the TRANSPORT only -- whether a key is authorized is a separate
# dimension (auth_probe), never folded in here.
function Test-TcpOnce {
    param([string]$HostName, [int]$Port, [int]$Timeout = 5)

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($HostName, $Port, $null, $null)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        if (-not $iar.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds($Timeout))) {
            $sw.Stop()
            return @{ ok = $false; seconds = 0 }
        }
        $client.EndConnect($iar)
        $sw.Stop()
        return @{ ok = $true; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 3) }
    } catch {
        return @{ ok = $false; seconds = 0 }
    } finally {
        $client.Close()
    }
}

function Invoke-TcpProbe {
    param([string]$HostName, [int]$Port, [int]$Attempts = 10, [int]$Timeout = 5)

    $times = New-Object System.Collections.Generic.List[double]
    $ok = 0
    $fail = 0

    for ($i = 1; $i -le $Attempts; $i++) {
        $r = Test-TcpOnce -HostName $HostName -Port $Port -Timeout $Timeout
        if ($r.ok) {
            $ok++
            $times.Add($r.seconds)
        } else {
            $fail++
        }
    }

    return (Format-ProbeResult -Ok $ok -Fail $fail -Times $times.ToArray())
}

# -- Dispatch by endpoint kind -----------------------------------------------
function Invoke-EndpointProbe {
    param(
        [string]$Url,
        [ValidateSet('http', 'git-smart', 'tcp')][string]$Kind,
        [int]$Attempts = 10,
        [int]$Timeout = 5
    )

    switch ($Kind) {
        'tcp' {
            $hp = $Url -replace '^tcp://', ''
            $tcpHost = $hp.Substring(0, $hp.LastIndexOf(':'))
            $tcpPort = [int]$hp.Substring($hp.LastIndexOf(':') + 1)
            return (Invoke-TcpProbe -HostName $tcpHost -Port $tcpPort -Attempts $Attempts -Timeout $Timeout)
        }
        'git-smart' {
            return (Invoke-GitSmartProbe -Url $Url -Attempts $Attempts -Timeout $Timeout)
        }
        default {
            return (Invoke-HttpProbe -Url $Url -Attempts $Attempts -Timeout $Timeout)
        }
    }
}
