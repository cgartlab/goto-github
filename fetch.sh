#!/usr/bin/env bash
# =============================================================================
# GoToGitHub — Direct hosts fetch from GitHub520 project
# Fetches verified GitHub CDN IPs from community-maintained hosts sources and
# applies them to /etc/hosts. No cloud scanning infrastructure needed.
# =============================================================================
# This is the entry point; the implementation lives in lib/:
#   lib/00-constants.sh  data constants
#   lib/01-utils.sh      logging, platform, privilege, DNS, TCP helpers
#   lib/02-fetch.sh      source fetching, dead-IP filtering, IP probe
#   lib/03-validate.sh   content validation, post-apply verification
#   lib/04-apply.sh      hosts apply/remove, shadowing check, status
# =============================================================================
# Usage:
#   sudo ./fetch.sh              # Fetch and apply hosts entries
#   ./fetch.sh --status         # Show current IP and connectivity
#   ./fetch.sh --restore        # Remove goto-github entries from /etc/hosts
#   ./fetch.sh --help           # Show this help
#
# Data sources:
#   https://cdn.jsdelivr.net/gh/521xueweihan/GitHub520@main/hosts
#   https://raw.hellogithub.com/hosts
#
# Environment variables:
#   HOSTS_FILE  — hosts file path (default: /etc/hosts)
# =============================================================================

set -euo pipefail

# ── Resolve this script's real directory (follow symlinks) ───────────────────
# The installed command is a symlink (~/.local/bin/goto-github) pointing at
# <install-dir>/fetch.sh; lib/ lives next to the real script, not the symlink.
_gg_source="${BASH_SOURCE[0]}"
while [ -L "$_gg_source" ]; do
    _gg_dir="$(cd -P "$(dirname "$_gg_source")" && pwd)"
    _gg_source="$(readlink "$_gg_source")"
    [[ "$_gg_source" != /* ]] && _gg_source="$_gg_dir/$_gg_source"
done
GG_SCRIPT_DIR="$(cd -P "$(dirname "$_gg_source")" && pwd)"
unset _gg_source _gg_dir

# ── Source library modules in dependency order ───────────────────────────────
for _gg_module in 00-constants 01-utils 02-fetch 03-validate 04-apply; do
    _gg_lib="$GG_SCRIPT_DIR/lib/${_gg_module}.sh"
    if [ ! -f "$_gg_lib" ]; then
        echo "ERROR: missing library module: $_gg_lib" >&2
        echo "  Reinstall with: curl -sfL https://raw.githubusercontent.com/cgartlab/goto-github/main/install.sh | bash" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    . "$_gg_lib"
done
unset _gg_module _gg_lib

# ── Interrupt handling ───────────────────────────────────────────────────────
trap cleanup INT TERM

# ── Interactive menu ─────────────────────────────────────────────────────────
show_menu() {
    echo ""
    echo "========================================"
    echo "  🔗 GitHub 访问加速"
    echo "========================================"
    echo ""
    echo "  1) 🚀 一键加速（推荐）"
    echo "  2) 🔧 手动选择数据源"
    echo "  3) 🗑️  恢复 hosts（移除加速）"
    echo "  4) 📊 查看当前状态"
    echo ""
    echo "  Q) 🚪 退出"
    echo ""
}

interactive_menu() {
    show_menu
    echo -n "  请输入选项 [1-4, Q]: "
    local choice
    read -r choice
    echo ""

    case "${choice:-}" in
        1|'')
            one_click_accelerate
            ;;
        2)
            manual_select
            ;;
        3)
            if ! is_root; then
                if is_mingw; then
                    log_error "需要管理员权限。请以管理员身份运行 Git Bash。"
                    exit 1
                fi
                need_root "$0" --__restore
                return
            fi
            restore_hosts
            flush_dns
            echo ""
            echo "✅ 已恢复原始 hosts 文件"
            echo ""
            ;;
        4)
            show_status
            ;;
        Q|q)
            echo "已退出"
            exit 0
            ;;
        *)
            echo "无效选项，请输入 1-4 或 Q"
            echo ""
            ;;
    esac
}

# ── Core cycle ─────────────────────────────────────────────────────────────
# run_cycle SILENT: if true, suppress "验证未完全通过" warning and exit 0
run_cycle() {
    local silent="${1:-false}"
    local raw_content block
    raw_content=$(fetch_hosts_content) || {
        exit 1
    }
    block=$(build_hosts_block "$raw_content")
    apply_hosts "$block"
    flush_dns
    if check_shadowing; then
        log_warn "检测到 $HOSTS_FILE 在 goto-github 标记之前已有 github.com 条目（其他工具写入），"
        log_warn "它会优先生效并遮蔽我们的映射。请手动删除或更新该条目。"
    fi
    echo ""
    if verify_hosts; then
        echo "========================================"
        echo "  ✅ 加速成功！GitHub 已可正常访问"
        echo "========================================"
        echo ""
    else
        log_warn "加速已应用，但验证未完全通过。"
        echo "  提示: 运行 ./fetch.sh --status 查看详情"
        [ "$silent" = "true" ] && return 0
        return 1
    fi
}

auto_drive() {
    log_info "自动驾驶模式启动..."

    if ! is_root; then
        if is_mingw; then
            log_error "Windows Git Bash 需要管理员权限。"
            echo ""
            echo "  请右键点击 Git Bash 图标，选择「以管理员身份运行」，"
            echo "  然后在弹出的窗口中执行:"
            echo ""
            echo "    cd $(pwd)"
            echo "    ./fetch.sh"
            echo ""
            exit 1
        fi
        log_info "需要管理员权限，正在请求 sudo..."
        need_root "$0" --__cycle
        return
    fi

    run_cycle false
}

manual_select() {
    echo "========== 手动选择 =========="
    echo ""
    show_status

    echo "  请选择:"
    echo "    1) jsDelivr CDN（主源）"
    echo "    2) raw.hellogithub.com（备用源）"
    echo "    3) GitHub Raw（直连源）"
    echo "    4) 删除已有条目（恢复原状）"
    echo "    5) 返回主菜单"
    echo ""
    echo -n "  请输入 [1-5] (默认 5): "
    local choice
    read -r choice
    choice="${choice:-5}"

    local selected_source=""
    case "$choice" in
        1) selected_source="https://cdn.jsdelivr.net/gh/521xueweihan/GitHub520@main/hosts" ;;
        2) selected_source="https://raw.hellogithub.com/hosts" ;;
        3) selected_source="https://raw.githubusercontent.com/521xueweihan/GitHub520/main/hosts" ;;
        4)
            echo ""
            echo "  ⚠ 确认删除所有 goto-github hosts 条目？(Y/N, 默认 N)"
            echo -n "  请输入 [Y/N]: "
            local confirm
            read -r confirm
            confirm="${confirm:-N}"
            if [ "$confirm" != "Y" ] && [ "$confirm" != "y" ]; then
                echo "  已取消。"
                return 0
            fi
            if ! is_root; then
                if is_mingw; then
                    log_error "需要管理员权限。请以管理员身份运行 Git Bash。"
                    exit 1
                fi
                need_root "$0" --__manual "remove"
                return
            fi
            remove_block && flush_dns
            log_info "已删除 goto-github 条目"
            return 0
            ;;
        5) show_menu; return 0 ;;
        *) log_error "无效选项: $choice"; manual_select; return 0 ;;
    esac

    if [ -n "$selected_source" ]; then
        if ! is_root; then
            if is_mingw; then
                log_error "需要管理员权限。请以管理员身份运行 Git Bash。"
                exit 1
            fi
            need_root "$0" --__manual "$selected_source"
            return
        fi

        log_info "使用数据源: $selected_source"
        local raw_content block
        raw_content=$(curl -sfL "${CURL_RETRY_OPTS[@]}" --connect-timeout 10 --max-time 30 "$selected_source" 2>/dev/null) || {
            log_error "从该源获取数据失败，请检查网络后重试。"
            echo ""
            echo "  按 Enter 返回菜单..."
            read -r _
            manual_select
            return 0
        }
        if ! validate_hosts_content "$raw_content"; then
            log_error "该源数据格式不正确。"
            echo ""
            echo "  按 Enter 返回菜单..."
            read -r _
            manual_select
            return 0
        fi
        block=$(build_hosts_block "$raw_content")
        apply_hosts "$block"
        flush_dns
        verify_hosts || true
    fi
}

one_click_accelerate() {
    if ! is_root; then
        if is_mingw; then
            log_error "需要管理员权限。"
            echo ""
            echo "  请右键点击 Git Bash，选择「以管理员身份运行」，然后执行:"
            echo ""
            echo "    cd $(pwd)"
            echo "    ./fetch.sh"
            echo ""
        else
            log_info "正在请求 sudo..."
            need_root "$0" --__cycle true
        fi
        return
    fi

    run_cycle true   # silent=true: suppress warning, exit 0
}

# ── Restore hosts (remove goto-github block) ─────────────────────────────────
restore_hosts() {
    if grep -qF "$MARKER_START" "$HOSTS_FILE" 2>/dev/null; then
        remove_block
        log_info "已恢复原始 hosts 文件"
    else
        log_info "未找到 goto-github 条目，无需恢复"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    case "${1:-}" in
        --__cycle)
            # Internal: run_cycle mode (after sudo re-exec)
            # $2 optional: "true" = silent mode (suppress verify warnings)
            run_cycle "${2:-false}"
            ;;
        --__manual)
            # Internal: manual mode with pre-selected source (after sudo re-exec)
            if [ "${2:-}" = "remove" ]; then
                remove_block && flush_dns
                log_info "已删除 goto-github 条目"
            elif [ -n "${2:-}" ]; then
                local raw_content block
                raw_content=$(curl -sfL "${CURL_RETRY_OPTS[@]}" --connect-timeout 10 --max-time 30 "$2" 2>/dev/null) || {
                    log_error "从该源获取数据失败"
                    exit 1
                }
                if ! validate_hosts_content "$raw_content"; then
                    log_error "该源数据格式不正确"
                    exit 1
                fi
                block=$(build_hosts_block "$raw_content")
                apply_hosts "$block"
                flush_dns
                verify_hosts || true
            fi
            ;;
        --__restore)
            # Internal: restore mode (after sudo re-exec from interactive menu)
            restore_hosts
            flush_dns
            ;;
        --probe)
            # Diagnostic: probe for a working github.com IP without touching hosts.
            probe_github_ip || { log_error "未找到可用的 github.com IP"; exit 1; }
            ;;
        --status)
            show_status
            ;;
        --restore)
            if [ "$(id -u)" -ne 0 ]; then
                log_error "This operation requires sudo. Run: sudo $0 --restore"
                exit 1
            fi
            if grep -qF "$MARKER_START" "$HOSTS_FILE" 2>/dev/null; then
                remove_block
                flush_dns
                log_info "Removed goto-github entries from $HOSTS_FILE"
            else
                log_info "No goto-github entries found"
            fi
            ;;
        --pwsh)
            # PowerShell thin-wrapper interface: output machine-parseable format
            shift
            case "${1:-auto}" in
                auto)
                    # PowerShell auto-drive: same as run_cycle but from PS
                    if ! is_root; then
                        echo '{"error":"need_root","message":"run with sudo"}' >&2
                        exit 1
                    fi
                    # Silent fetch and apply
                    local raw_content block
                    raw_content=$(fetch_hosts_content 2>/dev/null) || {
                        echo '{"error":"fetch_failed","message":"All sources exhausted"}' >&2
                        exit 1
                    }
                    block=$(build_hosts_block "$raw_content")
                    apply_hosts "$block" >/dev/null 2>&1
                    flush_dns >/dev/null 2>&1
                    verify_hosts >/dev/null 2>&1
                    echo '{"success":true}'
                    ;;
                status)
                    json_status
                    ;;
                restore)
                    if ! is_root; then
                        echo '{"error":"need_root","message":"run with sudo"}' >&2
                        exit 1
                    fi
                    remove_block
                    flush_dns >/dev/null 2>&1
                    echo '{"restored":true}'
                    ;;
                source)
                    # Output current source selection
                    echo '{"source":"jsdelivr","fallback":"hellogithub","tertiary":"github_raw"}'
                    ;;
                *)
                    echo "{\"error\":\"unknown_subcommand\",\"message\":\"Usage: --pwsh auto|status|restore|source\"}" >&2
                    exit 1
                    ;;
            esac
            ;;
        --help|-h)
            echo "Usage: $0 [--status|--restore|--pwsh SUBCMD|--version|--help]"
            echo ""
            echo "  (no flags)     Interactive menu (1234Q keys)"
            echo "                 Non-TTY / CI: runs full cycle if root"
            echo "  --pwsh SUBCMD  PowerShell 接口（auto|status|restore|source）"
            echo "  --status       显示当前状态"
            echo "  --restore      恢复 hosts 文件"
            echo "  --version      显示版本"
            echo "  -h, --help     显示帮助"
            echo ""
            echo "Data sources (mirror list with automatic fallback):"
            echo "  https://cdn.jsdelivr.net/gh/521xueweihan/GitHub520@main/hosts"
            echo "  https://raw.hellogithub.com/hosts"
            echo "  https://raw.githubusercontent.com/521xueweihan/GitHub520/main/hosts"
            echo ""
            echo "Environment:"
            echo "  HOSTS_FILE  hosts file path (default: /etc/hosts)"
            echo ""
            echo "Platforms: macOS · Linux · Git Bash (Windows)"
            ;;
        --version|-v)
            echo "GoToGitHub v1.0.0"
            echo "https://github.com/cgartlab/goto-github"
            ;;
        "")
            # Interactive menu (TTY) or one-click (non-TTY with sudo)
            if is_tty; then
                interactive_menu
            elif is_root; then
                run_cycle false
            else
                log_error "This operation requires sudo. Run: sudo $0"
                exit 1
            fi
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Usage: $0 [--status|--restore|--pwsh|--help]"
            exit 1
            ;;
    esac
}

main "$@"
