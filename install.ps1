<#
.SYNOPSIS
    One-line installer for GoToGitHub — GitHub access acceleration tool for Windows.

.DESCRIPTION
    Downloads fetch.sh (Git Bash script) and goto-github.ps1 (PowerShell wrapper)
    to $env:LOCALAPPDATA\goto-github\ and provides instructions for PATH registration.

    One-liner (run in PowerShell):
        irm https://raw.githubusercontent.com/cgartlab/goto-github/main/install.ps1 | iex

.PARAMETER Uninstall
    Remove the installation directory and all files.

.PARAMETER Update
    Re-download both files to the existing installation directory.

.EXAMPLE
    irm https://raw.githubusercontent.com/cgartlab/goto-github/main/install.ps1 | iex
    Install GoToGitHub (available as irm | iex one-liner).

.EXAMPLE
    .\install.ps1 -Update
    Re-download and refresh the installation.

.EXAMPLE
    .\install.ps1 -Uninstall
    Remove GoToGitHub from the system.

.EXAMPLE
    .\install.ps1 -WhatIf
    Preview what the installation would do without making changes.
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
$BaseUrl     = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$RepoBranch"

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
        Download a file from the repository to the install directory.
    #>
    param(
        [string]$FileName,
        [string]$Url,
        [string]$Destination
    )

    Write-Step "Downloading $FileName..."

    if (-not $PSCmdlet.ShouldProcess($Url, "Download $FileName")) {
        return
    }

    try {
        $iwrParams = @{
            Uri             = $Url
            OutFile         = $Destination
            TimeoutSec      = 30
            ErrorAction     = 'Stop'
            UseBasicParsing = $true
        }
        Invoke-WebRequest @iwrParams
        Write-Success "Saved to $Destination"
    } catch {
        Write-ErrorMsg "Failed to download $FileName"
        Write-Host "    $_" -ForegroundColor DarkRed
        throw
    }
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
    Write-Host "  从 Git Bash 运行（以管理员身份）:" -ForegroundColor White
    Write-Host "    sudo $InstallDir\fetch.sh" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  从 PowerShell 运行（以管理员身份）:" -ForegroundColor White
    Write-Host "    & $InstallDir\goto-github.ps1" -ForegroundColor Gray
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
    $allSucceeded = $true

    try {
        Invoke-Download -FileName 'fetch.sh' -Url "$BaseUrl/fetch.sh" -Destination $fetchShPath
    } catch {
        $allSucceeded = $false
    }

    # ── Download goto-github.ps1 (optional — may not exist in repo yet) ────
    $gotoGithubPs1Path = "$InstallDir\goto-github.ps1"
    try {
        Invoke-Download -FileName 'goto-github.ps1' -Url "$BaseUrl/goto-github.ps1" -Destination $gotoGithubPs1Path
    } catch {
        Write-Warn "goto-github.ps1 not yet available — may not exist in the repo."
        Write-Warn "fetch.sh was installed successfully and can be used from Git Bash."
    }

    if (-not $allSucceeded) {
        Write-ErrorMsg "Installation failed. Check your network connection and try again."
        exit 1
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
        Write-Host "    irm $BaseUrl/install.ps1 | iex"
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

        try {
            Invoke-Download -FileName 'fetch.sh' -Url "$BaseUrl/fetch.sh" -Destination $fetchShPath
        } catch {
            Write-ErrorMsg "Update failed."
            exit 1
        }

        try {
            Invoke-Download -FileName 'goto-github.ps1' -Url "$BaseUrl/goto-github.ps1" -Destination $gotoGithubPs1Path
        } catch {
            Write-Warn "goto-github.ps1 not available."
        }

        Write-Success "Updated successfully!"
        return
    }

    # Default: install
    Invoke-Install
}

# Entry point
Main
