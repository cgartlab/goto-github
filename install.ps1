<#
.SYNOPSIS
    One-line installer for GoToGitHub — GitHub access acceleration tool for Windows.
    Supports multiple mirror sources for regions with GitHub access issues.

.DESCRIPTION
    Downloads fetch.sh (Git Bash script) and goto-github.ps1 (PowerShell wrapper)
    to $env:LOCALAPPDATA\goto-github\ and provides instructions for PATH registration.
    Automatically tries multiple mirror sources if the primary source fails.

    One-liner (run in PowerShell):
        irm https://raw.githubusercontent.com/cgartlab/goto-github/main/install.ps1 | iex
        irm https://cdn.jsdelivr.net/gh/cgartlab/goto-github@main/install.ps1 | iex

.PARAMETER Uninstall
    Remove the installation directory and all files.

.PARAMETER Update
    Re-download both files to the existing installation directory.

.EXAMPLE
    irm https://raw.githubusercontent.com/cgartlab/goto-github/main/install.ps1 | iex
    Install GoToGitHub (available as irm | iex one-liner).

.EXAMPLE
    irm https://cdn.jsdelivr.net/gh/cgartlab/goto-github@main/install.ps1 | iex
    Install using jsDelivr mirror (recommended for China).

.EXAMPLE
    .\install.ps1 -Update
    Re-download and refresh the installation.

.EXAMPLE
    .\install.ps1 -Uninstall
    Remove GoToGitHub from the system.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Uninstall,
    [switch]$Update
)

$ErrorActionPreference = 'Stop'

# ── Configuration ──────────────────────────────────────────────────────────────
$RepoOwner   = 'cgartlab'
$RepoName    = 'goto-github'
$RepoBranch  = 'main'
$InstallDir  = "$env:LOCALAPPDATA\goto-github"

# Mirror sources for fetch.sh and goto-github.ps1 (in order of preference)
$FetchMirrors = @(
    "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$RepoBranch/fetch.sh"
    "https://cdn.jsdelivr.net/gh/$RepoOwner/$RepoName@$RepoBranch/fetch.sh"
    "https://ghproxy.com/https://raw.githubusercontent.com/$RepoOwner/$RepoName/$RepoBranch/fetch.sh"
)

$Ps1Mirrors = @(
    "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$RepoBranch/goto-github.ps1"
    "https://cdn.jsdelivr.net/gh/$RepoOwner/$RepoName@$RepoBranch/goto-github.ps1"
    "https://ghproxy.com/https://raw.githubusercontent.com/$RepoOwner/$RepoName/$RepoBranch/goto-github.ps1"
)

# ── Helper functions ───────────────────────────────────────────────────────────

function Test-IsWSL {
    <#
    .SYNOPSIS
        Detect if running inside Windows Subsystem for Linux (not on Windows with WSL installed).
    .DESCRIPTION
        Checks WSL-specific environment variables that are only set when running
        inside a WSL distro. Does NOT check wsl.exe (which runs on Windows too).
    #>
    # WSL sets these env vars only inside the WSL environment
    if ($env:WSL_DISTRO_NAME) {
        return $true
    }

    # Check for WSL-specific /proc/version string (only accessible inside WSL)
    if (Test-Path '/proc/version') {
        try {
            $procVersion = Get-Content '/proc/version' -Raw -ErrorAction Stop
            if ($procVersion -match 'Microsoft|WSL') {
                return $true
            }
        } catch {
            # /proc/version not accessible — not WSL
        }
    }

    return $false
}

function Write-Step {
    <#
    .SYNOPSIS
        Write a step header to the console.
    #>
    param([string]$Message)
    Write-Host "  → $Message" -ForegroundColor Cyan
}

function Write-Success {
    <#
    .SYNOPSIS
        Write a success message.
    #>
    param([string]$Message)
    Write-Host "  ✔ $Message" -ForegroundColor Green
}

function Write-Warn {
    <#
    .SYNOPSIS
        Write a warning message.
    #>
    param([string]$Message)
    Write-Host "  ⚠ $Message" -ForegroundColor Yellow
}

function Write-ErrorMsg {
    <#
    .SYNOPSIS
        Write an error message.
    #>
    param([string]$Message)
    Write-Host "  ✘ $Message" -ForegroundColor Red
}

# ── Core actions ───────────────────────────────────────────────────────────────

function Invoke-Uninstall {
    <#
    .SYNOPSIS
        Remove the installation directory and all files.
    #>
    if (Test-Path $InstallDir) {
        if ($PSCmdlet.ShouldProcess($InstallDir, 'Remove directory')) {
            Remove-Item -Recurse -Force $InstallDir
        }
        Write-Success "Removed $InstallDir"
    } else {
        Write-Host "  Not installed — nothing to remove."
    }
}

function Invoke-Download {
    <#
    .SYNOPSIS
        Download a file from mirror sources with automatic fallback.
    #>
    param(
        [string]$FileName,
        [string[]]$Mirrors,
        [string]$Destination
    )

    Write-Step "Downloading $FileName..."
    Write-Host "  Trying mirror sources..." -ForegroundColor Gray

    foreach ($url in $Mirrors) {
        Write-Host "  Attempting: $url" -ForegroundColor Gray

        try {
            $iwrParams = @{
                Uri             = $url
                OutFile         = $Destination
                TimeoutSec      = 30
                ErrorAction     = 'SilentlyContinue'
                UseBasicParsing = $true
            }
            Invoke-WebRequest @iwrParams

            # Validate the file was downloaded correctly
            if (Test-Path $Destination) {
                $fileSize = (Get-Item $Destination).Length
                if ($fileSize -gt 100) {  # Basic validation: file should have content
                    Write-Success "Saved to $Destination (from: $url)"
                    return $true
                } else {
                    Write-Warn "Downloaded file too small ($fileSize bytes), trying next mirror..."
                    Remove-Item $Destination -Force -ErrorAction SilentlyContinue
                }
            }
        } catch {
            Write-Warn "Failed: $url ($($_.Exception.Message))"
        }
    }

    Write-ErrorMsg "Failed to download $FileName from all mirrors."
    return $false
}

function Show-Instructions {
    <#
    .SYNOPSIS
        Print post-install instructions.
    #>
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  ✅ GoToGitHub 安装成功!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  安装目录: $InstallDir" -ForegroundColor White
    Write-Host ""
    Write-Host "  📖 使用方法" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Windows PowerShell（推荐）:" -ForegroundColor White
    Write-Host "    1) 右键点击 PowerShell → 以管理员身份运行" -ForegroundColor Gray
    Write-Host "    2) 运行: & '$InstallDir\goto-github.ps1'" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Git Bash（备选）:" -ForegroundColor White
    Write-Host "    sudo $InstallDir\fetch.sh" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  📌 将安装目录添加到 PATH（当前用户）:" -ForegroundColor Yellow
    Write-Host ""
    $pathCmd = '[Environment]::SetEnvironmentVariable("Path",'
    $pathCmd += ' [Environment]::GetEnvironmentVariable("Path", "User")'
    $pathCmd += ' + ";' + $InstallDir + '", "User")'
    Write-Host "    $pathCmd" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  🔗 项目主页: https://github.com/$RepoOwner/$RepoName" -ForegroundColor Gray
    Write-Host ""
}

function Invoke-Install {
    <#
    .SYNOPSIS
        Download and install GoToGitHub to the user's local app data directory.
    #>
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  GoToGitHub — Windows Installer" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # ── Create install directory ───────────────────────────────────────────
    Write-Step "Creating install directory..."
    if ($PSCmdlet.ShouldProcess($InstallDir, 'Create directory')) {
        $null = New-Item -ItemType Directory -Force -Path $InstallDir
    }
    Write-Success "$InstallDir"

    # ── Download fetch.sh (required) ───────────────────────────────────────
    $fetchShPath = "$InstallDir\fetch.sh"
    $fetchSuccess = Invoke-Download -FileName 'fetch.sh' -Mirrors $FetchMirrors -Destination $fetchShPath

    # ── Download goto-github.ps1 (required for PowerShell users) ─────────────
    $gotoGithubPs1Path = "$InstallDir\goto-github.ps1"
    $ps1Success = Invoke-Download -FileName 'goto-github.ps1' -Mirrors $Ps1Mirrors -Destination $gotoGithubPs1Path

    if (-not $fetchSuccess) {
        Write-ErrorMsg "Installation failed. Check your network connection and try again."
        Write-Host ""
        Write-Host "  Alternative: Download manually from GitHub:" -ForegroundColor Yellow
        Write-Host "    mkdir $InstallDir" -ForegroundColor Gray
        Write-Host "    curl -L https://github.com/$RepoOwner/$RepoName/raw/$RepoBranch/fetch.sh -o $fetchShPath" -ForegroundColor Gray
        Write-Host ""
        exit 1
    }

    if (-not $ps1Success) {
        Write-Warn "goto-github.ps1 download failed. fetch.sh was installed — use Git Bash as fallback."
    }

    Show-Instructions
}

# ── Main ───────────────────────────────────────────────────────────────────────

function Main {
    # WSL detection — must run in native Windows PowerShell, not WSL
    if (Test-IsWSL) {
        Write-ErrorMsg "WSL detected. GoToGitHub requires Windows PowerShell or Git Bash, not WSL."
        Write-Host ""
        Write-Host "  Run this installer in Windows PowerShell with:"
        Write-Host "    irm https://raw.githubusercontent.com/$RepoOwner/$RepoName/$RepoBranch/install.ps1 | iex"
        Write-Host ""
        exit 1
    }

    if ($Uninstall) {
        Invoke-Uninstall
        return
    }

    if ($Update) {
        if (-not (Test-Path $InstallDir)) {
            Write-ErrorMsg "GoToGitHub is not installed. Run without -Update to install."
            exit 1
        }

        Write-Host ""
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host "  GoToGitHub — Update" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host ""

        $fetchShPath = "$InstallDir\fetch.sh"
        $gotoGithubPs1Path = "$InstallDir\goto-github.ps1"

        Write-Step "Updating fetch.sh..."
        $fetchSuccess = Invoke-Download -FileName 'fetch.sh' -Mirrors $FetchMirrors -Destination $fetchShPath

        Write-Step "Updating goto-github.ps1..."
        $ps1Success = Invoke-Download -FileName 'goto-github.ps1' -Mirrors $Ps1Mirrors -Destination $gotoGithubPs1Path

        if ($fetchSuccess) {
            Write-Success "fetch.sh updated successfully!"
        } else {
            Write-ErrorMsg "Failed to update fetch.sh."
        }

        if ($ps1Success) {
            Write-Success "goto-github.ps1 updated successfully!"
        } elseif (-not (Test-Path $gotoGithubPs1Path)) {
            Write-Warn "goto-github.ps1 download failed."
        }

        if ($fetchSuccess -or $ps1Success) {
            Write-Success "Update completed!"
        } else {
            Write-ErrorMsg "Update failed. Check your network connection."
        }
        return
    }

    # Default: install
    Invoke-Install
}

# Entry point
Main
