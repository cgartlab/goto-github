# goto-github installation functions (PowerShell)
# Dot-source after 00-constants.ps1, 01-utils.ps1, 02-scan.ps1, 03-validate.ps1, 04-apply.ps1
# Source order: 00, 01, 02, 03, 04, 05, 06
if (Get-Variable -Name 'GOTO_GITHUB_PS1_05_INCLUDED' -Scope Script -ErrorAction SilentlyContinue) { return }
$script:GOTO_GITHUB_PS1_05_INCLUDED = $true

# ---------------------------------------------------------------------------
# Install-Files: copy script files to $script:INSTALL_DIR
# Source: $script:PS1_DIR\  (PS1_DIR is already the ps1/ directory; works in dev and installed modes)
# Dest:   $script:INSTALL_DIR\ps1\
# ---------------------------------------------------------------------------
function Install-Files {
    <#
    .SYNOPSIS
    Copy ps1/ directory from source to $script:INSTALL_DIR\ps1.
    Source is $script:PS1_DIR (which is the ps1/ directory itself).
    No-op if source and destination resolve to the same path.
    #>
    Write-Log -Message "Installing files to $($script:INSTALL_DIR)\ps1..."

    $srcDir = $script:PS1_DIR
    $dstDir = Join-Path $script:INSTALL_DIR 'ps1'

    # Verify source
    $srcMain = Join-Path $srcDir 'goto-github.ps1'
    if (-not (Test-Path $srcMain)) {
        throw "Install-Files: source not found: $srcMain"
    }

    # Skip if same path (reinstall from installed location)
    $srcResolved = (Resolve-Path -LiteralPath $srcDir -ErrorAction SilentlyContinue).Path
    $dstResolved = [System.IO.Path]::GetFullPath($dstDir)
    if ($srcResolved -and ($srcResolved.TrimEnd('\') -ieq $dstResolved.TrimEnd('\'))) {
        Write-Log -Message "Source and destination are the same path, skipping copy"
        Write-Host "  Files already in place: $dstDir"
        return
    }

    # Create destination structure
    $dstLib = Join-Path $dstDir 'lib'
    New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
    New-Item -ItemType Directory -Path $dstLib -Force | Out-Null

    # Copy main script
    Copy-Item -LiteralPath $srcMain -Destination (Join-Path $dstDir 'goto-github.ps1') -Force

    # Copy lib modules
    $srcLib = Join-Path $srcDir 'lib'
    if (Test-Path $srcLib) {
        Copy-Item -Path (Join-Path $srcLib '*.ps1') -Destination $dstLib -Force
    }

    Write-Log -Message "Files installed: $dstDir"
    Write-Host "  Files installed:   $dstDir"
}

# ---------------------------------------------------------------------------
# Install-Scheduler: create Windows Scheduled Task
# Runs as SYSTEM every 3 hours, calls goto-github.ps1 run
# Mirrors Linux systemd's OnBootSec=5min + OnUnitActiveSec=3h + Persistent=true
# ---------------------------------------------------------------------------
function Install-Scheduler {
    <#
    .SYNOPSIS
    Register a Windows Scheduled Task that runs 'goto-github run' every 3 hours.
    Task runs as SYSTEM (no UAC, no per-user context).
    #>
    Write-Log -Message "Installing scheduled task '$($script:SCHEDULER_LABEL)'..."

    $scriptPath = Join-Path $script:INSTALL_DIR 'ps1\goto-github.ps1'
    if (-not (Test-Path $scriptPath)) {
        throw "Install-Scheduler: script not found at $scriptPath (run Install-Files first)"
    }

    # Action: pwsh.exe -NoProfile -File "<INSTALL_DIR>\ps1\goto-github.ps1" run
    $action = New-ScheduledTaskAction `
        -Execute 'pwsh.exe' `
        -Argument "-NoProfile -File `"$scriptPath`" run" `
        -WorkingDirectory $script:INSTALL_DIR

    # Trigger: starts 5 min from now, then repeats every 3 hours for 10 years
    # This is the standard Windows pattern for repeating tasks. Combined with
    # StartWhenAvailable in settings, missed runs (e.g., after reboot) are caught up.
    # Mirrors Linux systemd's OnBootSec=5min + OnUnitActiveSec=3h + Persistent=true.
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) `
        -RepetitionInterval (New-TimeSpan -Hours 3) `
        -RepetitionDuration (New-TimeSpan -Days 3650)

    # Principal: SYSTEM with highest privileges
    $principal = New-ScheduledTaskPrincipal `
        -UserId 'SYSTEM' `
        -LogonType ServiceAccount `
        -RunLevel Highest

    # Settings: resilient across reboots and battery state
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 5) `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

    Register-ScheduledTask `
        -TaskName $script:SCHEDULER_LABEL `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Force `
        -Description "GoToGitHub: periodic scan and update of GitHub hosts (every 3 hours)" `
        -ErrorAction Stop

    Write-Log -Message "Scheduled task '$($script:SCHEDULER_LABEL)' installed"
    Write-Host "  Scheduled task:   $($script:SCHEDULER_LABEL) (every 3 hours, runs as SYSTEM)"
}

# ---------------------------------------------------------------------------
# Test-SchedulerInstalled: check if the task is already registered
# ---------------------------------------------------------------------------
function Test-SchedulerInstalled {
    <#
    .SYNOPSIS
    Returns $true if the GoToGitHub scheduled task is already registered.
    #>
    try {
        $task = Get-ScheduledTask -TaskName $script:SCHEDULER_LABEL -ErrorAction Stop
        return ($null -ne $task)
    } catch {
        return $false
    }
}
