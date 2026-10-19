# goto-github utility functions (PowerShell)
# Dot-source after 00-constants.ps1
if (Get-Variable -Name 'GOTO_GITHUB_PS1_01_INCLUDED' -Scope Script -ErrorAction SilentlyContinue) { return }
$script:GOTO_GITHUB_PS1_01_INCLUDED = $true

function Test-IsAdmin {
    <#
    .SYNOPSIS
    Check if the current process is running with administrator privileges.
    #>
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = [Security.Principal.WindowsPrincipal]::new($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IsSystem {
    <#
    .SYNOPSIS
    Check if the current process is running as SYSTEM (S-1-5-18).
    Scheduled tasks run as SYSTEM by default.
    #>
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    return $sid -eq 'S-1-5-18'
}

function Write-Log {
    <#
    .SYNOPSIS
    Write a timestamped message to the log file.
    Creates the log directory if it does not exist.
    #>
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] $Message"
    try {
        $dir = Split-Path $script:LOG_FILE -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -LiteralPath $script:LOG_FILE -Value $line -Encoding utf8NoBOM -ErrorAction SilentlyContinue
    } catch {
        # Silent: logging should never crash the tool
    }
}

function Read-Cache {
    <#
    .SYNOPSIS
    Read a single-line value from a cache file.
    Returns the first line, trimmed, or $null if missing.
    #>
    param([string]$Path)
    if (Test-Path $Path) {
        try {
            return (Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction Stop).Trim()
        } catch {
            return $null
        }
    }
    return $null
}

function Write-Cache {
    <#
    .SYNOPSIS
    Write a value to a cache file (atomically via temp + rename).
    Creates directory if needed.
    #>
    param([string]$Path, [string]$Value)
    try {
        $dir = Split-Path $Path -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $tmp = "$Path.tmp"
        $Value | Set-Content -LiteralPath $tmp -Encoding utf8NoBOM -NoNewline -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Clear-Cache {
    <#
    .SYNOPSIS
    Remove a cache file if it exists.
    #>
    param([string]$Path)
    if (Test-Path $Path) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

function Find-Curl {
    <#
    .SYNOPSIS
    Find curl.exe on this system.
    curl.exe ships with Windows 10 1803+ in C:\Windows\System32\curl.exe.
    #>
    try {
        $path = (Get-Command curl.exe -ErrorAction Stop).Source
        return $path
    } catch {
        return $null
    }
}

function Get-DoHState {
    <#
    .SYNOPSIS
    Check if DNS-over-HTTPS is enabled on any interface.
    Returns a hashtable: @{ Explicit = $true/$false; AutoUpgrade = $true/$false }
    #>
    $result = @{ Explicit = $false; AutoUpgrade = $false }

    # Check explicit DoH configuration per interface
    try {
        $doh = Get-DnsClientDohServerAddress -ErrorAction SilentlyContinue
        if ($doh) {
            $configured = $doh | Where-Object { $_.DohClientConfig -ne 0 }
            if ($configured) { $result.Explicit = $true }
        }
    } catch {
        # Cmdlet may not exist on older Win10 versions
    }

    # Check DoH auto-upgrade (Win11 22H2+)
    try {
        $reg = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -Name 'DohAutoUpgradeState' -ErrorAction SilentlyContinue
        if ($reg.DohAutoUpgradeState -eq 1) { $result.AutoUpgrade = $true }
    } catch {
        # Registry key may not exist
    }

    return $result
}
