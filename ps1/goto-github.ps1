#!/usr/bin/env pwsh
# ============================================================================
# GoToGitHub — Direct GitHub access from China via CDN IP scanning
# PowerShell 7+ native implementation
# ============================================================================
# Usage:
#   .\ps1\goto-github.ps1 run       — scan CDN IPs, update /etc/hosts, flush DNS
#   .\ps1\goto-github.ps1 status    — show current IP and reachability status
#   .\ps1\goto-github.ps1 help      — show this help message
#   .\ps1\goto-github.ps1 uninstall — remove all GoToGitHub changes from the system
# ============================================================================

# Strict mode
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
# UAC elevation guard
# Must run before sourcing modules (to avoid partial state)
# ============================================================================
$needAdminCommands = @('run', 'install', 'uninstall')
$currentCommand = if ($args.Count -gt 0 -and $args[0] -notlike '-*') { $args[0].ToLower() } else { 'help' }

if ($needAdminCommands -contains $currentCommand -and $env:GOTO_GITHUB_ELEVATED -ne '1') {
    if (-not [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $env:GOTO_GITHUB_ELEVATED = '1'
        $argList = @('-NoProfile', '-File', $PSCommandPath, '-Elevated') + $args
        Write-Verbose "Re-launching with admin privileges..." -Verbose
        $proc = Start-Process pwsh -Verb RunAs -ArgumentList $argList -Wait -PassThru
        # $proc is $null when the user dismisses the UAC prompt. Under
        # Set-StrictMode -Version Latest, $proc.ExitCode then throws
        # PropertyNotFound instead of exiting cleanly.
        if ($proc) { exit $proc.ExitCode } else { exit 1 }
    }
}

# ============================================================================
# Find project root (this script's directory's parent)
# ============================================================================
$script:GOTO_GITHUB_ROOT = if ($env:GOTO_GITHUB_INSTALL_DIR) {
        $env:GOTO_GITHUB_INSTALL_DIR
    } else {
        Split-Path -Parent $PSScriptRoot  # ps1/ -> repo root (since this is in development mode)
    }

# ============================================================================
# Source library modules in dependency order
# Each module has a guard that prevents double-sourcing
# ============================================================================
$libDir = Join-Path $PSScriptRoot 'lib'
$modules = @(
    '00-constants.ps1'
    '01-utils.ps1'
    '02-scan.ps1'
    '03-validate.ps1'
    '04-apply.ps1'
    '05-install.ps1'
    '06-uninstall.ps1'
)

foreach ($module in $modules) {
    $path = Join-Path $libDir $module
    if (Test-Path $path) {
        . $path
    } else {
        Write-Error "ERROR: Cannot find library module: $path"
        exit 1
    }
}

# ============================================================================
# Check dependencies — curl.exe is required
# ============================================================================
$curlPath = Find-Curl
if (-not $curlPath) {
    Write-Error "ERROR: curl.exe not found. curl.exe is bundled with Windows 10 1803+ (Spring 2018 Update)."
    Write-Error "  Open PowerShell as Administrator and run: winget install curl"
    exit 1
}

# ============================================================================
# Command: run — scan + apply + flush DNS
# ============================================================================
function cmd_run {
    Write-Host "GoToGitHub: scanning for best GitHub IP..." -ForegroundColor Cyan
    Write-Host ""

    $result = Invoke-ScanAll
    if ($result) {
        $bestIP = $result.IP
        $time = $result.Time
        $sizeKB = [Math]::Round($result.Size / 1024)

        Write-Host "  Best IP:   $bestIP" -ForegroundColor Green
        Write-Host "  Response:  ${time}s"
        Write-Host "  Content:   ${sizeKB}KB"
        Write-Host ""

        try {
            Set-HostsBlock -IP $bestIP
            Clear-DnsCache
            Write-Host ""
            Write-Host "Done. github.com should now be reachable directly." -ForegroundColor Green
            Write-Host "Try: curl -sI https://github.com/ | head -5"
        } catch {
            Write-Error "ERROR: Failed to apply: $_"
            exit 1
        }
    } else {
        Write-Host "ERROR: No working GitHub IP found." -ForegroundColor Red
        Write-Host "Possible causes:"
        Write-Host "  - Your network is blocking all HTTPS outbound"
        Write-Host "  - The GFW is actively blocking all CDN IPs"
        Write-Host "  - DNS resolution for api.github.com is failing"
        Write-Host ""
        Write-Host "Try running again in a few minutes, or check your internet connection."
        exit 1
    }
}

# ============================================================================
# Command: status — show current state
# ============================================================================
function cmd_status {
    $status = Get-HostsStatus
    Write-Host $status

    # DoH warning
    $doh = Get-DoHState
    if ($doh.Explicit -or $doh.AutoUpgrade) {
        Write-Host ""
        Write-Host "WARNING: DNS-over-HTTPS is enabled on this system." -ForegroundColor Yellow
        Write-Host "  Apps that use DoH directly (e.g., browsers with secure DNS) will bypass the hosts entry."
        if ($doh.Explicit) { Write-Host "  - Explicit DoH configured on at least one interface" }
        if ($doh.AutoUpgrade) { Write-Host "  - DoH auto-upgrade is enabled" }
    }
}

# ============================================================================
# Command: help — usage information
# ============================================================================
function cmd_help {
    Write-Host @"
GoToGitHub — Direct GitHub access from China via CDN IP scanning

Usage: .\ps1\goto-github.ps1 <command>

Commands:
  run         Scan CDN IPs and update /etc/hosts (requires admin)
  install     Install to C:\ProgramData\goto-github and create scheduled task (requires admin)
  status      Show current IP and reachability status
  help        Show this help message
  uninstall   Remove all GoToGitHub changes from the system (requires admin)

Examples:
  .\ps1\goto-github.ps1 run       # Immediate scan + apply
  .\ps1\goto-github.ps1 install   # Install + schedule every-3-hour scan
  .\ps1\goto-github.ps1 status    # Check current status

Requirements:
  - PowerShell 7+ (PS 7.6.2 verified)
  - curl.exe (bundled with Windows 10 1803+)
  - Administrator privileges for hosts file modification, install, and uninstall
"@
}

# ============================================================================
# Command: install — copy to INSTALL_DIR, create scheduled task
# ============================================================================
function cmd_install {
    Write-Host "Installing GoToGitHub..." -ForegroundColor Cyan
    Write-Host ""

    # Determine install target (default: C:\ProgramData\goto-github)
    $installTarget = $env:GOTO_GITHUB_INSTALL_DIR
    if (-not $installTarget) { $installTarget = 'C:\ProgramData\goto-github' }

    # Update INSTALL_DIR for this session (Install-Files and Install-Scheduler use $script:INSTALL_DIR)
    $script:INSTALL_DIR = $installTarget

    try {
        Install-Files
        Install-Scheduler
        Write-Host ""
        Write-Host "  GoToGitHub installed to: $installTarget" -ForegroundColor Green
        Write-Host ""
        Write-Host "After install you can run:"
        Write-Host "  pwsh -File `"$installTarget\ps1\goto-github.ps1`" run         - immediate scan"
        Write-Host "  pwsh -File `"$installTarget\ps1\goto-github.ps1`" status      - show state"
        Write-Host "  pwsh -File `"$installTarget\ps1\goto-github.ps1`" uninstall   - remove everything"
        Write-Host ""
        Write-Host "The scheduled task '$($script:SCHEDULER_LABEL)' runs every 3 hours as SYSTEM."
        Write-Host ""
    } catch {
        Write-Error "ERROR during install: $_"
        exit 1
    }
}

# ============================================================================
# Command: uninstall — remove all GoToGitHub changes
# ============================================================================
function cmd_uninstall {
    Write-Host "Uninstalling GoToGitHub..." -ForegroundColor Cyan
    Write-Host ""

    try {
        Uninstall-Scheduler
        Clear-Hosts
        Clear-DnsCache
        Uninstall-Cache
        Uninstall-Files
        Write-Host ""
        Write-Host "  GoToGitHub has been fully removed." -ForegroundColor Green
        Write-Host "  /etc/hosts has been cleaned up."
        Write-Host "  Scheduled task removed."
        Write-Host "  Cache cleared."
    } catch {
        Write-Error "ERROR during uninstall: $_"
        exit 1
    }
}

# ============================================================================
# Dispatch
# ============================================================================
switch ($currentCommand) {
    'run'       { cmd_run }
    'install'   { cmd_install }
    'status'    { cmd_status }
    'help'      { cmd_help }
    '-elevated' { cmd_help }        # -Elevated flag consumed silently
    'uninstall' { cmd_uninstall }
    default {
        Write-Host "Unknown command: $currentCommand"
        Write-Host "Usage: .\ps1\goto-github.ps1 <run|install|status|help|uninstall>"
        exit 1
    }
}
