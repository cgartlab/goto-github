# goto-github apply functions (PowerShell)
# Dot-source after 00-constants.ps1, 01-utils.ps1, 02-scan.ps1, 03-validate.ps1
# Get-IpFromHosts is provided by 03-validate.ps1
if (Get-Variable -Name 'GOTO_GITHUB_PS1_04_INCLUDED' -Scope Script -ErrorAction SilentlyContinue) { return }
$script:GOTO_GITHUB_PS1_04_INCLUDED = $true

function Set-HostsBlock {
    <#
    .SYNOPSIS
    Replace the goto-github section in /etc/hosts with new entries.
    Uses atomic file operations to preserve CRLF/encoding.
    #>
    param([string]$IP)

    if ([string]::IsNullOrEmpty($IP)) { throw 'Set-HostsBlock: IP is required' }

    # Build the marker block
    $domains = $script:CORE_DOMAINS
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    $blockLines = [System.Text.StringBuilder]::new()
    $null = $blockLines.AppendLine($script:MARKER_START)
    $null = $blockLines.AppendLine("# Managed by goto-github -- do not edit manually")
    $null = $blockLines.AppendLine("# Updated at $timestamp")
    $null = $blockLines.AppendLine("# Best IP: $IP")
    foreach ($d in $domains) {
        $null = $blockLines.AppendLine("$IP $d")
    }
    $null = $blockLines.AppendLine($script:MARKER_END)
    $block = $blockLines.ToString()

    # Read existing hosts file (preserves CRLF)
    if (-not (Test-Path $script:HOSTS_FILE)) {
        throw "Hosts file not found: $($script:HOSTS_FILE)"
    }

    $content = [System.IO.File]::ReadAllText($script:HOSTS_FILE)

    # Check if marker exists
    $pattern = '(?ms)^# >>> goto-github >>>.*?# <<< goto-github <<<'
    if ([regex]::IsMatch($content, $pattern)) {
        # Replace existing block
        $newContent = [regex]::Replace($content, $pattern, $block.TrimEnd("`r`n"))
    } else {
        # Append new block
        $content = $content.TrimEnd("`r`n") + "`r`n`r`n"
        $newContent = $content + $block.TrimEnd("`r`n") + "`r`n"
    }

    # Atomic write: temp file + Move (NOT Move-Item, to avoid ACL copy step)
    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tempFile, $newContent, [System.Text.UTF8Encoding]::new($false))
        # File.Move on same NTFS volume is atomic via MoveFileEx(MOVEFILE_REPLACE_EXISTING)
        [System.IO.File]::Move($tempFile, $script:HOSTS_FILE, $true)
    } catch {
        if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
        throw "Failed to write hosts file: $_"
    }

    # Update cache
    Write-Cache -Path $script:CACHE_FILE -Value $IP
    Write-Log -Message "Applied IP $IP to $($script:HOSTS_FILE)"
}

function Clear-DnsCache {
    <#
    .SYNOPSIS
    Flush the OS DNS cache.
    ipconfig /flushdns does NOT require admin.
    #>
    Write-Log -Message "Flushing DNS cache..."
    try {
        & ipconfig /flushdns 2>&1 | Out-Null
        # Also restart Dnscache service to ensure full flush
        Restart-Service -Name Dnscache -Force -ErrorAction SilentlyContinue
        Write-Log -Message "DNS cache flushed"
    } catch {
        Write-Log -Message "DNS cache flush warning: $_"
    }
}

function Verify-Hosts {
    <#
    .SYNOPSIS
    Verify that the current IP in /etc/hosts is working.
    Returns $true if reachable, $false otherwise.
    #>
    $currentIP = Get-IpFromHosts
    if (-not $currentIP) {
        Write-Log -Message "Verify-Hosts: no goto-github entry found"
        return $false
    }

    Write-Log -Message "Verifying cached IP $currentIP..."
    $result = Test-Ip -IP $currentIP
    if ($result) {
        Write-Log -Message "Verify-Hosts: IP $currentIP is working"
        return $true
    }

    Write-Log -Message "Verify-Hosts: IP $currentIP is NOT working"
    return $false
}

function Get-HostsStatus {
    <#
    .SYNOPSIS
    Show formatted status report.
    #>
    $currentIP = Get-IpFromHosts
    $cachedIP = Read-Cache -Path $script:CACHE_FILE

    $lines = @()
    $lines += '=== GoToGitHub Status ==='
    $lines += ''

    if ($currentIP) {
        $lines += "  Current IP: $currentIP"
        $ok = Verify-Hosts
        if ($ok) {
            $lines += '  Status:     OK (reachable)'
        } else {
            $lines += '  Status:     FAILED (not reachable)'
        }
    } else {
        $lines += '  Current IP: (none)'
        $lines += '  Status:     Not installed'
    }
    $lines += ''

    if ($cachedIP) {
        $lines += "  Cached IP:  $cachedIP"
    } else {
        $lines += '  Cached IP:  (none)'
    }

    $lines += ''
    $lines += "  Hosts file: $($script:HOSTS_FILE)"
    $lines += "  Log file:   $($script:LOG_FILE)"

    $lines -join "`r`n"
}

function Clear-Hosts {
    <#
    .SYNOPSIS
    Remove the goto-github section from /etc/hosts.
    #>
    Write-Log -Message "Removing goto-github block from $($script:HOSTS_FILE)..."

    $content = [System.IO.File]::ReadAllText($script:HOSTS_FILE)
    $pattern = '(?ms)^# >>> goto-github >>>.*?# <<< goto-github <<<\r?\n?'

    if ([regex]::IsMatch($content, $pattern)) {
        $newContent = [regex]::Replace($content, $pattern, '')

        $tempFile = [System.IO.Path]::GetTempFileName()
        try {
            [System.IO.File]::WriteAllText($tempFile, $newContent, [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::Move($tempFile, $script:HOSTS_FILE, $true)
            Write-Log -Message "goto-github block removed from $($script:HOSTS_FILE)"
        } catch {
            if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue }
            throw "Failed to clear hosts file: $_"
        }
    } else {
        Write-Log -Message "No goto-github block found in $($script:HOSTS_FILE)"
    }
}
