# GoToGitHub — Pure PowerShell hosts fetch script
# Fetches verified GitHub CDN IPs from community-maintained hosts sources and
# applies them to the Windows hosts file. No Git Bash required.

#Requires -Version 5.1

# ── Self-unblock: bypass Restricted/AllSigned execution policy ────────────────
$_ep = Get-ExecutionPolicy
if ($_ep -eq 'Restricted' -or $_ep -eq 'AllSigned') {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
}

# ── Constants ─────────────────────────────────────────────────────────────────
$script:HOSTS_FILE = "$env:SystemRoot\System32\drivers\etc\hosts"
$script:MARKER_START = '# >>> goto-github >>>'
$script:MARKER_END = '# <<< goto-github <<<'
$script:SOURCES = @(
    'https://cdn.jsdelivr.net/gh/521xueweihan/GitHub520@main/hosts'
    'https://raw.hellogithub.com/hosts'
    'https://raw.githubusercontent.com/521xueweihan/GitHub520/main/hosts'
)
$script:LAST_SOURCE_URL = $null
$script:VERSION = 'v1.0.0'

# Known-good candidate IP pools (verified reachable for direct access)
$script:FASTLY_IPS = @(
    '185.199.108.153', '185.199.109.153', '185.199.110.153', '185.199.111.153'
)
$script:AZURE_ASIA_IPS = @(
    '140.82.112.21', '20.205.243.166', '20.205.243.165', '140.82.114.26'
)
# Key domains that must work for normal GitHub usage
$script:KEY_DOMAINS = @(
    'github.com', 'api.github.com', 'codeload.github.com',
    'raw.githubusercontent.com', 'avatars.githubusercontent.com',
    'objects.githubusercontent.com', 'media.githubusercontent.com',
    'github.githubassets.com', 'live.github.com', 'education.github.com',
    'pipelines.actions.githubusercontent.com', 'github.io', 'githubstatus.com'
)

# ── Helpers ──────────────────────────────────────────────────────────────────
function Log-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Green
}

function Log-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Log-Error {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

# ── Privilege Check ────────────────────────────────────────────────────────────
function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    $adminRole = [Security.Principal.WindowsBuiltInRole]::Administrator
    return $principal.IsInRole($adminRole)
}

function Request-Admin {
    $message = @"

  ╔══════════════════════════════════════════════════════╗
  ║           ⚠ 需要管理员权限           ║
  ╚══════════════════════════════════════════════════════╝

  修改 hosts 文件需要 Windows 管理员权限。

  请按以下步骤操作:

    方法一（推荐）- 自动重启:
      输入 Y 后，脚本将自动以管理员身份重新启动

    方法二 - 手动操作:
      1) 关闭当前窗口
      2) 在开始菜单搜索「PowerShell」
      3) 右键点击「Windows PowerShell」
      4) 选择「以管理员身份运行」
      5) 重新运行此脚本

"@
    Write-Host $message -ForegroundColor Yellow

    $relaunch = Read-Host "  是否尝试自动以管理员身份重启? (Y/N, 默认 N)"
    if ($relaunch -eq 'Y' -or $relaunch -eq 'y') {
        $scriptPath = $MyInvocation.ScriptName
        if (-not $scriptPath) {
            $scriptPath = $PSCommandPath
        }
        Write-Host "  → 正在请求管理员权限..." -ForegroundColor Cyan
        $arguments = "-NoExit", "-ExecutionPolicy", "Bypass", "-Command", "cd '$PWD'; & '$scriptPath'"
        Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments
        Write-Host "  → 如果弹出 UAC 提示，请点击「是」" -ForegroundColor Yellow
        exit 0
    }
    Write-Host "  → 已取消。" -ForegroundColor Yellow
    return $false
}

# ── Content Validation ────────────────────────────────────────────────────────
function Test-ValidHostsContent {
    param([string]$Content)

    # Count valid IP lines (at least 10 required)
    $ipPattern = '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\s+'
    $ipLines = ($Content -split "`n" | Where-Object { $_ -match $ipPattern -and $_ -notmatch '^\s*#' })
    if ($ipLines.Count -lt 10) {
        Log-Error "Content validation failed: only $($ipLines.Count) valid IP lines (need >= 10)"
        return $false
    }

    # Check for github.com domain
    if ($Content -notmatch 'github\.com') {
        Log-Error "Content validation failed: no 'github.com' domain found"
        return $false
    }

    return $true
}

# ── Extract Valid Lines ────────────────────────────────────────────────────────
function Get-ValidHostsLines {
    param([string]$Content)

    $ipPattern = '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\s+'
    $lines = $Content -split "`n" | Where-Object {
        $_ -match $ipPattern
    } | ForEach-Object {
        # Remove comments and trailing whitespace
        $_ -replace '#.*', '' -replace '\s+$', ''
    } | Where-Object { $_ -ne '' }

    return $lines
}

# ── DNS Cache Flush ────────────────────────────────────────────────────────────
function Clear-DnsCache {
    Log-Info "Flushing DNS cache..."
    try {
        ipconfig //flushdns | Out-Null
    } catch {
        # Fallback: ignore if flush fails
    }
    Log-Info "DNS cache flushed"
}

# ── Block Management ──────────────────────────────────────────────────────────
function Test-BlockExists {
    if (-not (Test-Path $script:HOSTS_FILE)) {
        return $false
    }
    $content = Get-Content $script:HOSTS_FILE -Raw -ErrorAction SilentlyContinue
    return $content -match [regex]::Escape($script:MARKER_START)
}

function Remove-GotoBlock {
    if (-not (Test-BlockExists)) {
        return $true
    }

    try {
        # .NET methods: read/write as UTF-8 (no BOM) preserving non-ASCII lines.
        # Get-Content/Set-Content in PS 5.1 default to ANSI and would corrupt
        # UTF-8 comments in hosts when rewriting the whole file.
        $lines = [System.IO.File]::ReadAllLines($script:HOSTS_FILE)
    } catch {
        Log-Error "Failed to read hosts file: $_"
        return $false
    }
    $inBlock = $false
    $newLines = @()

    foreach ($line in $lines) {
        if ($line -match [regex]::Escape($script:MARKER_START)) {
            $inBlock = $true
            continue
        }
        if ($line -match [regex]::Escape($script:MARKER_END)) {
            $inBlock = $false
            continue
        }
        if (-not $inBlock) {
            $newLines += $line
        }
    }

    try {
        [System.IO.File]::WriteAllLines($script:HOSTS_FILE, $newLines)
        return $true
    } catch {
        Log-Error "Failed to remove block: $_"
        return $false
    }
}

function Add-HostsBlock {
    param([string[]]$Lines, [string]$SourceLabel = '521xueweihan/GitHub520')

    $blockContent = @(
        ''
        $script:MARKER_START
        "# Managed by GoToGitHub — $(Get-Date -Format 'yyyy-MM-dd')"
        "# Source: $SourceLabel"
    ) + $Lines + @(
        $script:MARKER_END
        ''
    )

    try {
        Add-Content -Path $script:HOSTS_FILE -Value $blockContent -Encoding ASCII -ErrorAction Stop
        Log-Info "Applied to $script:HOSTS_FILE"
        return $true
    } catch {
        Log-Error "Failed to write hosts file: $_"
        return $false
    }
}

# ── Backup ─────────────────────────────────────────────────────────────────────
function Backup-HostsFile {
    $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
    $backupPath = "$script:HOSTS_FILE.goto-github.bak.$timestamp"
    try {
        Copy-Item -Path $script:HOSTS_FILE -Destination $backupPath -ErrorAction Stop
    } catch {
        Log-Error "Backup failed: $_"
        return $false
    }
    # Retain only the 3 most recent backups
    Get-ChildItem "$script:HOSTS_FILE.goto-github.bak.*" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 3 |
        Remove-Item -ErrorAction SilentlyContinue
    return $true
}

# ── Source Label ───────────────────────────────────────────────────────────────
function Get-SourceLabel {
    param([string]$Url)

    if ($Url -like '*GitHub520*') {
        return '521xueweihan/GitHub520'
    }
    if ($Url -like '*hellogithub*') {
        return 'raw.hellogithub.com'
    }
    return '521xueweihan/GitHub520'
}

# ── IP Verification & Auto-Repair ─────────────────────────────────────────────
function Test-DomainReachable {
    param([string]$Domain, [string]$Ip)

    # Force connection to the specific IP via curl --resolve (skips hosts/DNS),
    # which proves the IP actually serves the domain over HTTPS.
    # Retry 3x because direct connections are intermittently reset; any success counts.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $code = curl.exe -s --noproxy "*" --connect-timeout 5 --resolve "${Domain}:443:${Ip}" -o NUL -w "%{http_code}" "https://${Domain}" 2>$null
        if ($code -match '^[2-4]\d\d$') {
            return $true
        }
    }
    return $false
}

function Get-RepairPool {
    param([string]$Domain)

    if ($Domain -like '*githubusercontent*' -or $Domain -like 'github.io' -or $Domain -like 'githubstatus.com' -or $Domain -like '*githubassets*' -or $Domain -like '*fastly*') {
        return $script:FASTLY_IPS
    }
    return $script:AZURE_ASIA_IPS
}

function Repair-HostsLines {
    param([string[]]$Lines)

    $repaired = @()
    $outLines = @()

    foreach ($line in $Lines) {
        $outLines += $line
        if ($line -notmatch '^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s+([\w.\-]+)$') {
            continue
        }
        $ip = $Matches[1]
        $domain = $Matches[2]
        if ($script:KEY_DOMAINS -notcontains $domain) {
            continue
        }

        if (Test-DomainReachable -Domain $domain -Ip $ip) {
            continue
        }

        # Current IP unreachable — try candidate pool
        $replacement = $null
        foreach ($candidate in (Get-RepairPool -Domain $domain)) {
            if ($candidate -eq $ip) { continue }
            if (Test-DomainReachable -Domain $domain -Ip $candidate) {
                $replacement = $candidate
                break
            }
        }

        if ($replacement) {
            $newLine = $line -replace '^\S+', $replacement
            $outLines[$outLines.Count - 1] = $newLine
            $repaired += "${domain}: ${ip} -> ${replacement}"
            Log-Warn "Repaired $domain ($ip unreachable, using $replacement)"
        } else {
            Log-Warn "Repair FAILED for $domain (no working IP found)"
        }
    }

    return @{ Lines = $outLines; Repaired = $repaired }
}

# ── Apply Hosts (shared by RunCycle / ManualSelect / --pwsh auto) ──────────────
function Invoke-ApplyHosts {
    param([string]$Content, [string]$SourceUrl = $script:LAST_SOURCE_URL)

    $lines = Get-ValidHostsLines -Content $Content
    if (-not (Backup-HostsFile)) {
        Log-Error 'Failed to create backup; aborting apply'
        return $false
    }
    if (-not (Remove-GotoBlock)) {
        Log-Error 'Failed to remove previous block; aborting apply'
        return $false
    }

    # Verify key domains and replace unreachable IPs before writing
    $repairResult = Repair-HostsLines -Lines $lines
    $lines = $repairResult.Lines
    if ($repairResult.Repaired.Count -gt 0) {
        Log-Info "Auto-repaired $($repairResult.Repaired.Count) unreachable host(s)"
    }

    $label = Get-SourceLabel -Url $SourceUrl
    if ([string]::IsNullOrWhiteSpace($label)) {
        $label = '521xueweihan/GitHub520'
    }
    if (-not (Add-HostsBlock -Lines $lines -SourceLabel $label)) {
        Log-Error 'Failed to write hosts block'
        return $false
    }
    Clear-DnsCache | Out-Null
    return $true
}

# ── Fetch Hosts Content ────────────────────────────────────────────────────────
function Get-HostsContent {
    foreach ($url in $script:SOURCES) {
        Log-Info "Fetching from $url"
        try {
            $response = Invoke-WebRequest -Uri $url -TimeoutSec 30 -UseBasicParsing -ErrorAction SilentlyContinue
            $raw = $response.Content
            if ($raw -is [byte[]]) {
                $content = [System.Text.Encoding]::UTF8.GetString($raw)
            } else {
                $content = [string]$raw
            }
            if ([string]::IsNullOrWhiteSpace($content)) {
                Log-Warn "Failed to fetch from $url (empty content)"
                continue
            }
            if (Test-ValidHostsContent -Content $content) {
                $script:LAST_SOURCE_URL = $url
                return $content
            }
            Log-Warn "Content validation failed for $url"
        } catch {
            Log-Warn "Failed to fetch from $url ($($_.Exception.Message))"
        }
    }

    Log-Error "All sources exhausted — no valid hosts content obtained."
    return $null
}

# ── Verify Hosts ───────────────────────────────────────────────────────────────
function Test-HostsVerification {
    # Get IP from block
    $blockContent = Get-Content $script:HOSTS_FILE -Raw -ErrorAction SilentlyContinue
    if (-not $blockContent) {
        Log-Warn "Cannot read hosts file"
        return $false
    }

    # Extract the IP mapped to github.com exactly (not subdomains like alive.github.com)
    $ipPattern = '(?m)^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s+github\.com\s*$'
    if ($blockContent -match $ipPattern) {
        $ip = $Matches[1]
    } else {
        Log-Warn "No IP found in hosts block"
        return $false
    }

    Log-Info "Verifying IP $ip against github.com..."

    # Test via curl --resolve (forces the specific IP, proves HTTPS serves the domain)
    if (Test-DomainReachable -Domain 'github.com' -Ip $ip) {
        Log-Info "Verification PASSED — github.com reachable via $ip"
        return $true
    } else {
        Log-Warn "Verification FAILED — github.com not reachable via $ip"
        return $false
    }
}

# ── JSON Interface ─────────────────────────────────────────────────────────────
function Get-JSONStatus {
    $installed = Test-BlockExists
    $ip = ''
    $reachable = $false
    $httpCode = '000'

    if ($installed) {
        # Get IP from block
        $blockContent = Get-Content $script:HOSTS_FILE -Raw -ErrorAction SilentlyContinue
        $ipPattern = '(?m)^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s+github\.com\s*$'
        if ($blockContent -match $ipPattern) {
            $ip = $Matches[1]
        }

        if ($ip) {
            # Test reachability via curl --resolve (forces the specific IP)
            if (Test-DomainReachable -Domain 'github.com' -Ip $ip) {
                $httpCode = '200'
                $reachable = $true
            } else {
                $httpCode = '000'
                $reachable = $false
            }
        }
    }

    $result = @{
        installed = $installed
        ip = $ip
        reachable = $reachable
        http_code = $httpCode
    }

    return $result | ConvertTo-Json -Compress
}

# ── Run Cycle (Apply Hosts) ────────────────────────────────────────────────────
function Start-RunCycle {
    $content = Get-HostsContent
    if (-not $content) {
        return $false
    }

    return Invoke-ApplyHosts -Content $content
}

# ── Show Status (Human-readable) ───────────────────────────────────────────────
function Show-Status {
    Write-Host ""
    Write-Host "=== GoToGitHub Status ===" -ForegroundColor Cyan
    Write-Host ""

    if (-not (Test-BlockExists)) {
        Write-Host "  IP: (not installed)" -ForegroundColor Yellow
        Write-Host "  Run '.\goto-github.ps1' to install." -ForegroundColor Cyan
        Write-Host ""
        return
    }

    $blockContent = Get-Content $script:HOSTS_FILE -Raw -ErrorAction SilentlyContinue
    $ipPattern = '(?m)^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s+github\.com\s*$'
    if ($blockContent -match $ipPattern) {
        $ip = $Matches[1]
        Write-Host "  IP:   $ip" -ForegroundColor Green
    } else {
        Write-Host "  IP:   (not found)" -ForegroundColor Yellow
        return
    }

    # Test reachability — same method as JSON status (curl --resolve forces the
    # specific IP). BindIPEndPointDelegate binds the LOCAL source endpoint, not
    # the target, so it cannot prove the mapped IP serves github.com.
    if (Test-DomainReachable -Domain 'github.com' -Ip $ip) {
        Write-Host "  Status: OK — github.com reachable" -ForegroundColor Green
    } else {
        Write-Host "  Status: FAILED (unreachable)" -ForegroundColor Red
    }

    Write-Host ""
}

# ── Interactive Menu ───────────────────────────────────────────────────────────
function Show-Menu {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  🔗 GitHub 访问加速" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1) 🚀 一键加速（推荐）" -ForegroundColor White
    Write-Host "  2) 🔧 手动选择数据源" -ForegroundColor White
    Write-Host "  3) 🗑️  恢复 hosts（移除加速）" -ForegroundColor White
    Write-Host "  4) 📊 查看当前状态" -ForegroundColor White
    Write-Host ""
    Write-Host "  Q) 🚪 退出" -ForegroundColor White
    Write-Host ""
}

function Start-InteractiveMenu {
    while ($true) {
        Show-Menu
        $choice = Read-Host "  请输入选项 [1-4, Q]"

        switch ($choice) {
            { $_ -eq '1' -or $_ -eq '' } {
                Start-OneClickAccelerate
                Write-Host ""
                Write-Host "按 Q 返回主菜单，或按 Enter 继续..." -ForegroundColor Cyan
                $cont = Read-Host
                if ($cont -eq 'Q' -or $cont -eq 'q') { }
            }
            { $_ -eq '2' } {
                Start-ManualSelect
                Write-Host ""
                Write-Host "按 Q 返回主菜单，或按 Enter 继续..." -ForegroundColor Cyan
                $cont = Read-Host
                if ($cont -eq 'Q' -or $cont -eq 'q') { }
            }
            { $_ -eq '3' } {
                Start-RestoreHosts
                Write-Host ""
                Write-Host "按 Q 返回主菜单，或按 Enter 继续..." -ForegroundColor Cyan
                $cont = Read-Host
                if ($cont -eq 'Q' -or $cont -eq 'q') { }
            }
            { $_ -eq '4' } {
                Show-Status
                Write-Host ""
                Write-Host "按 Q 返回主菜单，或按 Enter 继续..." -ForegroundColor Cyan
                $cont = Read-Host
                if ($cont -eq 'Q' -or $cont -eq 'q') { }
            }
            { $_ -eq 'Q' -or $_ -eq 'q' } {
                Write-Host ""
                Write-Host "  感谢使用 GoToGitHub，再见！" -ForegroundColor Cyan
                Write-Host ""
                exit 0
            }
            default {
                Write-Host ""
                Write-Host "  ⚠ 无效选项，请输入 1-4 或 Q" -ForegroundColor Yellow
                Write-Host ""
            }
        }
    }
}

function Start-OneClickAccelerate {
    if (-not (Test-IsAdmin)) {
        $result = Request-Admin
        if (-not $result) {
            Write-Host ""
            Write-Host "  ⚠ 操作已取消，需要管理员权限才能继续。" -ForegroundColor Yellow
            Write-Host ""
        }
        return
    }

    Write-Host ""
    Write-Host "  ⚡ 正在获取并应用 GitHub 加速配置..." -ForegroundColor Cyan
    Write-Host ""

    if (Start-RunCycle) {
        if (Test-HostsVerification) {
            Write-Host ""
            Write-Host "========================================" -ForegroundColor Green
            Write-Host "  ✅ GitHub 加速已成功应用！" -ForegroundColor Green
            Write-Host "========================================" -ForegroundColor Green
            Write-Host ""
            Write-Host "  现在可以访问 GitHub 了！" -ForegroundColor White
            Write-Host ""
        } else {
            Write-Host ""
            Write-Host "  ⚠ 加速已应用，但验证未完全通过。" -ForegroundColor Yellow
            Write-Host "  提示: 运行 --status 查看详情" -ForegroundColor Cyan
            Write-Host ""
        }
    } else {
        Write-Host ""
        Write-Host "  ❌ 加速失败：所有数据源均不可用" -ForegroundColor Red
        Write-Host ""
        Write-Host "  可能原因：" -ForegroundColor White
        Write-Host "    1) 您的网络无法访问 GitHub（如公司内网/代理环境）" -ForegroundColor Gray
        Write-Host "    2) DNS 被污染，建议先运行 --pwsh status 查看" -ForegroundColor Gray
        Write-Host "    3) 稍后重试，或使用「手动选择」尝试备用源" -ForegroundColor Gray
        Write-Host ""
    }
}

function Start-ManualSelect {
    Write-Host "========== 手动选择 ==========" -ForegroundColor Cyan
    Write-Host ""
    Show-Status

    Write-Host "  请选择:"
    Write-Host "    1) jsDelivr CDN（主源）"
    Write-Host "    2) raw.hellogithub.com（备用源）"
    Write-Host "    3) 删除已有条目（恢复原状）"
    Write-Host "    4) 返回主菜单"
    Write-Host ""

    $sourceChoice = Read-Host "  请输入 [1-4] (默认 4)"
    if ([string]::IsNullOrWhiteSpace($sourceChoice)) {
        $sourceChoice = '4'
    }

    switch ($sourceChoice) {
        '1' {
            $selectedSource = 'https://cdn.jsdelivr.net/gh/521xueweihan/GitHub520@main/hosts'
        }
        '2' {
            $selectedSource = 'https://raw.hellogithub.com/hosts'
        }
        '3' {
            if (-not (Test-IsAdmin)) {
                $result = Request-Admin
                if (-not $result) {
                    Write-Host ""
                    Write-Host "  ⚠ 操作已取消。" -ForegroundColor Yellow
                    Write-Host ""
                }
                return
            }
            if (-not (Remove-GotoBlock)) {
                Write-Host ""
                Write-Host "  ❌ 删除失败：无法删除 goto-github 条目" -ForegroundColor Red
                Write-Host ""
                return
            }
            Clear-DnsCache | Out-Null
            Write-Host ""
            Write-Host "  ✅ 已删除 goto-github 条目" -ForegroundColor Green
            Write-Host ""
            return
        }
        '4' {
            return
        }
        default {
            Log-Error "无效选项: $sourceChoice"
            return
        }
    }

    if ($selectedSource) {
        if (-not (Test-IsAdmin)) {
            $result = Request-Admin
            if (-not $result) {
                Write-Host ""
                Write-Host "  ⚠ 操作已取消。" -ForegroundColor Yellow
                Write-Host ""
            }
            return
        }

        Write-Host "  使用数据源: $selectedSource" -ForegroundColor Cyan

        try {
            $response = Invoke-WebRequest -Uri $selectedSource -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
            $raw = $response.Content
            if ($raw -is [byte[]]) {
                $content = [System.Text.Encoding]::UTF8.GetString($raw)
            } else {
                $content = [string]$raw
            }

            if (-not (Test-ValidHostsContent -Content $content)) {
                Write-Host ""
                Write-Host "  ❌ 该源数据格式不正确。" -ForegroundColor Red
                Write-Host ""
                return
            }

            if (-not (Invoke-ApplyHosts -Content $content -SourceUrl $selectedSource)) {
                Write-Host ""
                Write-Host "  ❌ 应用失败，请检查 hosts 文件。" -ForegroundColor Red
                Write-Host ""
                return
            }
            if (Test-HostsVerification) {
                Write-Host ""
                Write-Host "  ✅ GitHub 加速已成功应用！" -ForegroundColor Green
                Write-Host ""
            } else {
                Write-Host ""
                Write-Host "  ⚠ 加速已应用，但验证未完全通过。" -ForegroundColor Yellow
                Write-Host ""
            }

        } catch {
            Write-Host ""
            Write-Host "  ❌ 从该源获取数据失败: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host ""
        }
    }
}

function Start-RestoreHosts {
    if (-not (Test-IsAdmin)) {
        $result = Request-Admin
        if (-not $result) {
            Write-Host ""
            Write-Host "  ⚠ 操作已取消。" -ForegroundColor Yellow
            Write-Host ""
        }
        return
    }

    if (Test-BlockExists) {
        if (-not (Remove-GotoBlock)) {
            Write-Host ""
            Write-Host "  ❌ 恢复失败：无法删除 goto-github 条目" -ForegroundColor Red
            Write-Host ""
            return $false
        }
        Write-Host ""
        Write-Host "  ✅ 已恢复原始 hosts 文件" -ForegroundColor Green
        Write-Host ""
        return $true
    } else {
        Write-Host ""
        Write-Host "  ℹ 未找到 goto-github 条目，无需恢复" -ForegroundColor Cyan
        Write-Host ""
        return $true
    }
}

# ── Main ──────────────────────────────────────────────────────────────────────
function Show-Help {
    Write-Host @"

Usage: .\goto-github.ps1 [选项]

  (无参数)      交互菜单 (1-4, Q)
  --help, -h   显示本帮助
  --version, -v 显示版本信息

  脚本接口 (返回 JSON):
    --pwsh status   获取当前状态
    --pwsh source   获取数据源信息
    --pwsh auto     一键加速 (需管理员)
    --pwsh restore  恢复 hosts (需管理员)

  管理员权限:
    hosts 文件修改需要管理员权限。
    脚本会自动请求提升权限。

  数据源:
    https://cdn.jsdelivr.net/gh/521xueweihan/GitHub520@main/hosts
    https://raw.hellogithub.com/hosts

环境变量:
    无 (使用 Windows 系统 hosts 文件)

平台: Windows (PowerShell 5.1+)
"@
}

function Show-Version {
    Write-Host "GoToGitHub $script:VERSION"
    Write-Host "https://github.com/cgartlab/goto-github"
}

# Parse arguments
$arg = $args[0]

switch ($arg) {
    { $_ -eq '--help' -or $_ -eq '-h' -or [string]::IsNullOrWhiteSpace($_) } {
        if ([string]::IsNullOrWhiteSpace($_)) {
            # No args: interactive menu
            Start-InteractiveMenu
        } else {
            Show-Help
        }
        exit 0
    }
    { $_ -eq '--version' -or $_ -eq '-v' } {
        Show-Version
        exit 0
    }
    { $_ -eq '--status' } {
        Show-Status
        exit 0
    }
    { $_ -eq '--restore' } {
        if (-not (Test-IsAdmin)) {
            Log-Error "This operation requires admin. Run as Administrator."
            exit 1
        }
        if (-not (Start-RestoreHosts)) {
            exit 1
        }
        Clear-DnsCache | Out-Null
        exit 0
    }
    { $_ -eq '--pwsh' } {
        $subCmd = $args[1]
        if ([string]::IsNullOrWhiteSpace($subCmd)) {
            $subCmd = 'auto'
        }

        switch ($subCmd) {
            'auto' {
                if (-not (Test-IsAdmin)) {
                    Write-Error '{"error":"need_root","message":"run as administrator"}'
                    exit 1
                }
                $content = Get-HostsContent
                if (-not $content) {
                    Write-Error '{"error":"fetch_failed","message":"All sources exhausted"}'
                    exit 1
                }
                if (-not (Invoke-ApplyHosts -Content $content)) {
                    Write-Error '{"error":"apply_failed","message":"Failed to apply hosts block"}'
                    exit 1
                }
                # Silently verify
                Test-HostsVerification | Out-Null
                Write-Output '{"success":true}'
                exit 0
            }
            'status' {
                Write-Output (Get-JSONStatus)
                exit 0
            }
            'restore' {
                if (-not (Test-IsAdmin)) {
                    Write-Error '{"error":"need_root","message":"run as administrator"}'
                    exit 1
                }
                if (-not (Remove-GotoBlock)) {
                    Write-Error '{"error":"restore_failed","message":"Failed to restore hosts file"}'
                    exit 1
                }
                Clear-DnsCache | Out-Null
                Write-Output '{"restored":true}'
                exit 0
            }
            'source' {
                Write-Output '{"source":"jsdelivr","fallback":"hellogithub","tertiary":"github_raw"}'
                exit 0
            }
            default {
                Write-Error '{"error":"unknown_subcommand","message":"Usage: --pwsh auto|status|restore|source"}'
                exit 1
            }
        }
    }
    default {
        Log-Error "Unknown option: $arg"
        Write-Host "Usage: .\goto-github.ps1 [--help|--version|--status|--restore|--pwsh SUBCMD]"
        exit 1
    }
}
