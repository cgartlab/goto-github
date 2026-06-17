# goto-github.ps1 — PowerShell thin wrapper for GitHub hosts acceleration
#
# Architecture:
#   This is a THIN ADAPTER LAYER. All hosts logic lives in fetch.sh (bash).
#   This script:
#     1. Finds bash.exe (Git for Windows)
#     2. Calls bash.exe fetch.sh with appropriate arguments
#     3. Provides an interactive menu for PowerShell users
#     4. Parses and displays JSON output from fetch.sh --pwsh commands
#
#   ┌──────────────────┐       ┌───────────────────┐       ┌──────────────┐
#   │ goto-github.ps1  │ ────▶ │ bash.exe          │ ────▶ │ fetch.sh     │
#   │ (PowerShell)     │       │ (Git for Windows) │       │ (Bash logic) │
#   └──────────────────┘       └───────────────────┘       └──────────────┘
#
#   fetch.sh exposes a --pwsh subcommand that outputs machine-parseable JSON:
#     --pwsh auto    ▶ {"success":true} or {"error":"need_root","message":"..."}
#     --pwsh status  ▶ {"installed":bool, "ip":"...", "reachable":bool, "http_code":"..."}
#     --pwsh restore ▶ {"restored":true} or {"error":"need_root","message":"..."}
#     --pwsh source  ▶ {"source":"jsdelivr","fallback":"hellogithub"}
#
# Usage:
#   .\goto-github.ps1               — Interactive menu (1-3, Q)
#   .\goto-github.ps1 --help        — Show this help
#   .\goto-github.ps1 --pwsh status — Machine-parseable JSON output (for scripting)
#
# Requirements:
#   - Git for Windows (provides bash.exe): https://git-scm.com/download/win
#   - Administrator privileges for fetch/restore operations
#
# Administrator elevation:
#   When fetch.sh needs admin rights, it returns JSON {"error":"need_root"}.
#   This script detects that and prompts the user to re-run as Admin.
#   Automatic re-launch with Start-Process -Verb RunAs is offered.

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$FetchSh   = Join-Path $ScriptDir "fetch.sh"

# ── Find bash.exe (Git Bash) ──────────────────────────────────────────────────

$Bash = Get-Command bash.exe -ErrorAction SilentlyContinue
if (-not $Bash) {
    Write-Host ""
    Write-Host "  ❌ bash.exe not found." -ForegroundColor Red
    Write-Host ""
    Write-Host "  GoToGitHub requires Git for Windows (Git Bash) to run."
    Write-Host "  Download: https://git-scm.com/download/win"
    Write-Host ""
    Write-Host "  After installing, re-run this script."
    Write-Host ""
    exit 1
}

# Ensure fetch.sh exists
if (-not (Test-Path $FetchSh)) {
    Write-Host ""
    Write-Host "  ❌ fetch.sh not found in $ScriptDir" -ForegroundColor Red
    Write-Host ""
    exit 1
}

# ── Helper: invoke fetch.sh via bash.exe ──────────────────────────────────────

function Invoke-FetchSh {
    param([string]$SubCommand)

    $result = & $Bash.Path $FetchSh "--pwsh" $SubCommand 2>&1
    $exitCode = $LASTEXITCODE

    return @{
        Output   = $result
        ExitCode = $exitCode
    }
}

# ── Helper: display formatted status from JSON ────────────────────────────────

function Show-Status {
    param([string]$JsonRaw)

    try {
        $status = $JsonRaw | ConvertFrom-Json
    } catch {
        Write-Host "  ⚠ Failed to parse status JSON: $_" -ForegroundColor Yellow
        Write-Host "  Raw output: $JsonRaw"
        return
    }

    Write-Host ""
    Write-Host "  ═══════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "   GoToGitHub 状态" -ForegroundColor Cyan
    Write-Host "  ═══════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    if ($status.installed -eq $true) {
        Write-Host "  Installed : Yes" -ForegroundColor Green
        Write-Host "  IP        : $($status.ip)"
        if ($status.reachable -eq $true) {
            Write-Host "  Reachable : Yes (HTTP $($status.http_code))" -ForegroundColor Green
        } else {
            Write-Host "  Reachable : No (HTTP $($status.http_code))" -ForegroundColor Red
        }
    } else {
        Write-Host "  Installed : No" -ForegroundColor Yellow
        Write-Host "  IP        : (none)"
        Write-Host "  Reachable : N/A"
        Write-Host ""
        Write-Host "  Run 一键加速 (option 1) to install." -ForegroundColor Cyan
    }
    Write-Host ""
}

# ── Helper: run accelerated fetch ──────────────────────────────────────────────

function Start-Accelerate {
    Write-Host ""
    Write-Host "  ⚡ 正在获取并应用 GitHub 加速配置..." -ForegroundColor Cyan

    $result = Invoke-FetchSh -SubCommand "auto"
    $output  = $result.Output
    $exitCode = $result.ExitCode

    if ($exitCode -ne 0) {
        $parsed = $null
        try { $parsed = $output | ConvertFrom-Json } catch {}

        if ($parsed -and $parsed.error -eq "need_root") {
            Write-Host ""
            Write-Host "  ⚠ 需要管理员权限才能修改 hosts 文件。" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  操作步骤:" -ForegroundColor Cyan
            Write-Host "    1) 右键点击 PowerShell 图标" -ForegroundColor White
            Write-Host "    2) 选择「以管理员身份运行」" -ForegroundColor White
            Write-Host "    3) 重新运行此脚本" -ForegroundColor White
            Write-Host ""

            $relaunch = Read-Host "  是否尝试自动以管理员身份重启? (Y/N, 默认 N)"
            if ($relaunch -eq "Y" -or $relaunch -eq "y") {
                $psScriptPath = $MyInvocation.MyCommand.Path
                Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoExit", "-Command", "& '$psScriptPath'"
                exit 0
            }
            exit 1
        }

        Write-Host "  ❌ 加速失败:" -ForegroundColor Red
        Write-Host "  $output" -ForegroundColor Red
        exit 1
    }

    try {
        $parsed = $output | ConvertFrom-Json
        if ($parsed.success -eq $true) {
            Write-Host ""
            Write-Host "  ═══════════════════════════════════════" -ForegroundColor Green
            Write-Host "   ✅ GitHub 加速已成功应用！" -ForegroundColor Green
            Write-Host "  ═══════════════════════════════════════" -ForegroundColor Green
            Write-Host ""
        }
    } catch {
        Write-Host "  $output"
    }
}

# ── Helper: restore hosts ──────────────────────────────────────────────────────

function Restore-Hosts {
    $result   = Invoke-FetchSh -SubCommand "restore"
    $output   = $result.Output
    $exitCode = $result.ExitCode

    if ($exitCode -ne 0) {
        $parsed = $null
        try { $parsed = $output | ConvertFrom-Json } catch {}

        if ($parsed -and $parsed.error -eq "need_root") {
            Write-Host ""
            Write-Host "  ⚠ 需要管理员权限才能修改 hosts 文件。" -ForegroundColor Yellow
            Write-Host "  请以管理员身份重新运行 PowerShell。" -ForegroundColor Yellow
            Write-Host ""
            exit 1
        }

        Write-Host "  ❌ 恢复失败: $output" -ForegroundColor Red
        exit 1
    }

    Write-Host ""
    Write-Host "  ✅ 已恢复原始 hosts 文件" -ForegroundColor Green
    Write-Host ""
}

# ── Show version ───────────────────────────────────────────────────────────────

function Show-Version {
    Write-Host ""
    Write-Host "  GoToGitHub PowerShell Wrapper v1.0.0"
    Write-Host "  https://github.com/cgartlab/goto-github"
    Write-Host ""
}

# ── Show help ──────────────────────────────────────────────────────────────────

function Show-Help {
    Write-Host ""
    Write-Host "  ═══════════════════════════════════════"
    Write-Host "   GoToGitHub — GitHub Hosts 加速工具"
    Write-Host "  ═══════════════════════════════════════"
    Write-Host ""
    Write-Host "  用法: .\goto-github.ps1 [选项]"
    Write-Host ""
    Write-Host "  选项:"
    Write-Host "    (无参数)      交互菜单 (1-3, Q)"
    Write-Host "    --help, -h    显示本帮助"
    Write-Host "    --version, -v 显示版本信息"
    Write-Host ""
    Write-Host "  脚本接口 (返回 JSON):"
    Write-Host "    --pwsh status   获取当前状态"
    Write-Host "    --pwsh source   获取数据源信息"
    Write-Host "    --pwsh auto     一键加速 (需管理员)"
    Write-Host "    --pwsh restore  恢复 hosts (需管理员)"
    Write-Host ""
    Write-Host "  管理员权限:"
    Write-Host "    hosts 文件修改需要管理员权限。"
    Write-Host "    请右键点击 PowerShell, 选择「以管理员身份运行」。"
    Write-Host ""
    Write-Host "  依赖: Git for Windows (bash.exe)"
    Write-Host "  下载: https://git-scm.com/download/win"
    Write-Host ""
}

# ── Main ───────────────────────────────────────────────────────────────────────

# Collect positional args (supports: .\goto-github.ps1 --pwsh status)
$subCommand = $args -join ' '

switch -Regex ($subCommand) {
    "^(--help|-h)$" {
        Show-Help
        exit 0
    }
    "^(--version|-v)$" {
        Show-Version
        exit 0
    }
    "^--pwsh\s+" {
        # Direct passthrough — for scripting. Extract the subcommand after --pwsh
        $fetchSubCmd = $subCommand -replace '^--pwsh\s+', ''
        $result = Invoke-FetchSh -SubCommand $fetchSubCmd
        Write-Output $result.Output
        exit $result.ExitCode
    }
    "^$" {
        # Interactive menu (no args passed)
        do {
            Write-Host ""
            Write-Host "  ═══════════════════════════════════════" -ForegroundColor Cyan
            Write-Host "   🔗 GitHub 访问加速" -ForegroundColor Cyan
            Write-Host "  ═══════════════════════════════════════" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "   1) 🚀 一键加速（推荐）" -ForegroundColor White
            Write-Host "   2) 📊 查看当前状态" -ForegroundColor White
            Write-Host "   3) 🗑️  恢复 hosts" -ForegroundColor White
            Write-Host "   Q) 🚪 退出" -ForegroundColor White
            Write-Host ""
            $choice = Read-Host "  请输入选项 [1-3, Q]"

            switch -Regex ($choice) {
                "^1$" { Start-Accelerate }
                "^2$" {
                    $result = Invoke-FetchSh -SubCommand "status"
                    Show-Status -JsonRaw $result.Output
                }
                "^3$" { Restore-Hosts }
                "^(Q|q)$" {
                    Write-Host ""
                    Write-Host "  感谢使用 GoToGitHub，再见！" -ForegroundColor Cyan
                    Write-Host ""
                    exit 0
                }
                default {
                    Write-Host ""
                    Write-Host "  ⚠ 无效选项，请输入 1-3 或 Q" -ForegroundColor Yellow
                }
            }
        } while ($true)
    }
    default {
        Write-Host ""
        Write-Host "  ⚠ 未知选项: $subCommand" -ForegroundColor Yellow
        Write-Host "  使用 --help 查看帮助。" -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
}