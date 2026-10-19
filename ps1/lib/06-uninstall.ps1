# goto-github uninstallation functions (PowerShell)
# Dot-source after 00-constants.ps1, 01-utils.ps1, 02-scan.ps1, 03-validate.ps1, 04-apply.ps1
# Source order: 00, 01, 02, 03, 04, 05, 06
if (Get-Variable -Name 'GOTO_GITHUB_PS1_06_INCLUDED' -Scope Script -ErrorAction SilentlyContinue) { return }
$script:GOTO_GITHUB_PS1_06_INCLUDED = $true

# Safe install paths that Uninstall-Files will remove
# Mirrors bash 06-uninstall.sh safety check
$script:SAFE_INSTALL_PATHS = @(
    'C:\ProgramData\goto-github',
    'C:\goto-github'
)

# ---------------------------------------------------------------------------
# Uninstall-Scheduler: remove the scheduled task
# ---------------------------------------------------------------------------
function Uninstall-Scheduler {
    <#
    .SYNOPSIS
    Unregister the GoToGitHub scheduled task. Idempotent.
    #>
    Write-Log -Message "Removing scheduled task '$($script:SCHEDULER_LABEL)'..."

    try {
        $task = Get-ScheduledTask -TaskName $script:SCHEDULER_LABEL -ErrorAction SilentlyContinue
        if ($task) {
            Unregister-ScheduledTask -TaskName $script:SCHEDULER_LABEL -Confirm:$false
            Write-Log -Message "Scheduled task '$($script:SCHEDULER_LABEL)' removed"
            Write-Host "  Removed:          scheduled task '$($script:SCHEDULER_LABEL)'"
        } else {
            Write-Log -Message "Scheduled task '$($script:SCHEDULER_LABEL)' not found, skipping"
        }
    } catch {
        Write-Log -Message "Warning: failed to remove scheduled task: $_"
        Write-Host "  Warning:         failed to remove scheduled task: $_" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Uninstall-Files: remove the installation directory
# Safety check: only removes paths in $script:SAFE_INSTALL_PATHS
# ---------------------------------------------------------------------------
function Uninstall-Files {
    <#
    .SYNOPSIS
    Remove the GoToGitHub installation directory. Idempotent.
    Refuses to remove custom install paths (must be in safe list).
    #>
    Write-Log -Message "Removing installation directory '$($script:INSTALL_DIR)'..."

    $safe = $script:SAFE_INSTALL_PATHS
    $isSafe = $safe | Where-Object { $_ -ieq $script:INSTALL_DIR }

    if (-not $isSafe) {
        Write-Log -Message "Refusing to remove non-standard INSTALL_DIR: $($script:INSTALL_DIR)"
        Write-Host "  Warning:         INSTALL_DIR=$($script:INSTALL_DIR) is not in safe list. Skipping." -ForegroundColor Yellow
        return
    }

    if (Test-Path $script:INSTALL_DIR) {
        Remove-Item -LiteralPath $script:INSTALL_DIR -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log -Message "Removed: $($script:INSTALL_DIR)"
        Write-Host "  Removed:         $($script:INSTALL_DIR)"
    } else {
        Write-Log -Message "INSTALL_DIR does not exist, skipping"
    }
}

# ---------------------------------------------------------------------------
# Uninstall-Cache: remove the cache file
# ---------------------------------------------------------------------------
function Uninstall-Cache {
    <#
    .SYNOPSIS
    Remove the GoToGitHub cache file. Idempotent.
    #>
    Write-Log -Message "Removing cache file '$($script:CACHE_FILE)'..."

    if (Test-Path $script:CACHE_FILE) {
        Remove-Item -LiteralPath $script:CACHE_FILE -Force -ErrorAction SilentlyContinue
        Write-Log -Message "Removed: $($script:CACHE_FILE)"
    } else {
        Write-Log -Message "Cache file does not exist, skipping"
    }
}
