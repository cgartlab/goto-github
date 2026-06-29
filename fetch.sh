#!/usr/bin/env bash
# =============================================================================
# GoToGitHub — Direct hosts fetch from GitHub520 project
# Fetches verified GitHub CDN IPs from community-maintained hosts sources and
# applies them to /etc/hosts. No cloud scanning infrastructure needed.
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

# ── Constants ────────────────────────────────────────────────────────────────
HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
MARKER_START="# >>> goto-github >>>"
MARKER_END="# <<< goto-github <<<"

SOURCES="https://cdn.jsdelivr.net/gh/521xueweihan/GitHub520@main/hosts
https://raw.hellogithub.com/hosts
https://raw.githubusercontent.com/521xueweihan/GitHub520/main/hosts"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# ── Helpers ──────────────────────────────────────────────────────────────────
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

is_macos()  { [ "$(uname)" = "Darwin" ]; }
is_linux()  { [ "$(uname)" = "Linux" ]; }
is_mingw()  { [[ "$(uname)" == MINGW* || "$(uname)" == MSYS* ]]; }
is_root()   { [ "$(id -u)" -eq 0 ]; }
is_tty()    { [ -t 0 ]; }

# ── Privilege escalation ─────────────────────────────────────────────────────
# Re-exec with sudo, preserving HOSTS_FILE env var if set.
need_root() {
    [ "$(id -u)" -eq 0 ] && return 0
    if [ -n "${HOSTS_FILE:-}" ]; then
        exec sudo -E "$0" "$@"   # preserve HOSTS_FILE across sudo boundary
    else
        exec sudo "$0" "$@"
    fi
}

detect_platform_str() {
    if is_macos; then
        echo "macOS"
    elif is_linux; then
        echo "Linux"
    elif is_mingw; then
        echo "Windows Git Bash"
    else
        echo "$(uname)"
    fi
}

cleanup() {
    echo ""
    echo "  感谢使用 GoToGitHub，再见！"
    exit 0
}
trap cleanup INT TERM

# ── Content validation ───────────────────────────────────────────────────────
# Prevents malformed or malicious data from being written to /etc/hosts.
validate_hosts_content() {
    local content="$1"
    local ip_count
    ip_count=$(echo "$content" | grep -v '^#' | grep -v '^$' | grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || echo 0)
    if [ "$ip_count" -lt 10 ]; then
        log_error "Content validation failed: only $ip_count valid IP lines (need >= 10)"
        return 1
    fi
    if ! echo "$content" | grep -q 'github.com'; then
        log_error "Content validation failed: no 'github.com' domain found"
        return 1
    fi
    return 0
}

# ── Extract valid lines from raw hosts content ───────────────────────────────
# Returns only IP + domain lines, stripped of trailing comments.
extract_hosts_lines() {
    local content="$1"
    echo "$content" \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\s+' \
        | sed 's/#.*//' \
        | sed 's/[[:space:]]*$//' \
        | grep -v '^$'
}

# ── DNS cache flush ───────────────────────────────────────────────────────────
flush_dns() {
    log_info "Flushing DNS cache..."
    if is_macos; then
        killall -HUP mDNSResponder 2>/dev/null || true
        dscacheutil -flushcache 2>/dev/null || true
    elif is_linux; then
        resolvectl flush-caches 2>/dev/null || true
        systemctl restart systemd-resolved 2>/dev/null || true
    elif is_mingw; then
        # Windows: use native ipconfig via cmd.exe
        ipconfig //flushdns 2>/dev/null || true
    fi
    log_info "DNS cache flushed"
}

# ── PowerShell subcommand interface ──────────────────────────────────────────
# Outputs machine-parseable JSON for --pwsh status
json_status() {
    local ip_count="0" has_github="false" reachable="false" http_code=""

    # 统计 hosts 块中的条目
    local block_content
    block_content=$(sed -n "/^${MARKER_START}$/,/^${MARKER_END}$/p" "$HOSTS_FILE" 2>/dev/null || true)
    if [ -n "$block_content" ]; then
        ip_count=$(echo "$block_content" | grep -cE '^\s*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
        if echo "$block_content" | grep -qE '\s+github\.com\b'; then
            has_github="true"
        fi
        # 直接测试 GitHub 连通性（通过 hosts 文件解析）
        http_code=$(curl -s --connect-timeout 10 --max-time 20 \
            -o /dev/null -w "%{http_code}" \
            "https://github.com/" 2>/dev/null || true)
        if echo "$http_code" | grep -qE '^[0-9]{3}$'; then
            reachable="true"
        fi
    fi

    # Detect if block exists
    local block_exists="false"
    if grep -q "$MARKER_START" "$HOSTS_FILE" 2>/dev/null; then
        block_exists="true"
    fi

    cat <<EOF
{
  "installed": $block_exists,
  "entries": $ip_count,
  "has_github": $has_github,
  "reachable": $reachable,
  "http_code": "${http_code:-}"
}
EOF
}

# ── Remove existing goto-github block from hosts file ────────────────────────
remove_block() {
    if ! grep -qF "$MARKER_START" "$HOSTS_FILE" 2>/dev/null; then
        return 0
    fi
    local escaped_start escaped_end
    escaped_start=$(printf '%s\n' "$MARKER_START" | sed 's/[\/&]/\\&/g')
    escaped_end=$(printf '%s\n' "$MARKER_END" | sed 's/[\/&]/\\&/g')
    if is_macos; then
        # macOS sed requires empty string argument for -i
        sed -i '' "/^${escaped_start}/,/^${escaped_end}/d" "$HOSTS_FILE"
    else
        # GNU sed (Linux, MINGW64, MSYS) — use -- to stop sed from
        # interpreting leading dash in patterns as options
        sed -i -- "/^${escaped_start}/,/^${escaped_end}/d" "$HOSTS_FILE"
    fi
}

# ── Show current status ───────────────────────────────────────────────────────
show_status() {
    local block_exists ip_count has_github
    block_exists=$(sed -n "/^${MARKER_START}$/,/^${MARKER_END}$/p" "$HOSTS_FILE" 2>/dev/null || true)

    echo ""
    echo "=== GoToGitHub Status ==="
    echo ""

    if [ -z "$block_exists" ]; then
        echo "  Status: (not installed)"
        echo "  Run 'sudo ./fetch.sh' to install."
    else
        ip_count=$(echo "$block_exists" | grep -cE '^\s*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
        has_github=$(echo "$block_exists" | grep -cE '\s+github\.com\b' || true)
        echo "  Entries: $ip_count"
        echo "  github.com: $has_github entry(s)"

        # Test actual connectivity through hosts file
        local http_code
        http_code=$(curl -s --connect-timeout 10 --max-time 20 \
            -o /dev/null -w "%{http_code}" \
            "https://github.com/" 2>/dev/null || true)
        if echo "$http_code" | grep -qE '^[0-9]{3}$'; then
            echo -e "  Status: ${GREEN}OK${NC} — github.com reachable (HTTP $http_code)"
        else
            echo -e "  Status: ${RED}FAILED${NC} — github.com unreachable"
        fi
    fi
    echo ""
}

# ── Apply hosts block ──────────────────────────────────────────────────────────
apply_hosts() {
    local block="$1"
    remove_block
    # Backup before modification
    cp "$HOSTS_FILE" "${HOSTS_FILE}.goto-github.bak.$(date +%Y%m%d%H%M%S)"
    printf "\n%s\n" "$block" >> "$HOSTS_FILE"
    log_info "Applied to $HOSTS_FILE"
}

# ── Fetch from sources with fallback ──────────────────────────────────────────
fetch_hosts_content() {
    local content url
    while IFS= read -r url; do
        [ -z "$url" ] && continue
        log_info "Fetching from $url"
        content=$(curl -sfL --connect-timeout 10 --max-time 30 "$url" 2>/dev/null || true)
        if [ -z "$content" ]; then
            log_warn "Failed to fetch from $url"
            continue
        fi
        if validate_hosts_content "$content"; then
            echo "$content"
            return 0
        fi
        log_warn "Content validation failed for $url"
    done <<< "$SOURCES"

    log_error "All sources exhausted — no valid hosts content obtained."
    return 1
}

# ── Verify applied IP ───────────────────────────────────────────────────────────
verify_hosts() {
    # 验证 hosts 块已正确写入
    local block_exists ip_count has_github
    block_exists=$(sed -n "/^${MARKER_START}$/,/^${MARKER_END}$/p" "$HOSTS_FILE" 2>/dev/null || true)
    if [ -z "$block_exists" ]; then
        log_warn "No goto-github block found in hosts file"
        return 1
    fi

    # 统计有效 IP 条目
    ip_count=$(echo "$block_exists" | grep -cE '^\s*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
    # 检查 github.com 是否存在
    has_github=$(echo "$block_exists" | grep -cE '\s+github\.com\b' || true)

    if [ "$ip_count" -lt 10 ]; then
        log_warn "Hosts block has only $ip_count entries (expected >= 10)"
        return 1
    fi
    if [ "$has_github" -eq 0 ]; then
        log_warn "Hosts block missing github.com entry"
        return 1
    fi

    log_info "Hosts block verified: $ip_count entries, github.com entry present"
    return 0
}
# ── Build hosts block from raw content ────────────────────────────────────────
build_hosts_block() {
    local content="$1"
    local lines
    lines=$(extract_hosts_lines "$content")
    echo "$MARKER_START"
    echo "# Managed by GoToGitHub — $(date +%Y-%m-%d)"
    echo "# Source: 521xueweihan/GitHub520"
    echo "$lines"
    echo "$MARKER_END"
}

# ── Interactive menu ──────────────────────────────────────────────────────────

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
        log_error "所有数据源均不可用，请检查网络连接后重试。"
        exit 1
    }
    block=$(build_hosts_block "$raw_content")
    apply_hosts "$block"
    flush_dns
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
        raw_content=$(curl -sfL --connect-timeout 10 --max-time 30 "$selected_source" 2>/dev/null) || {
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
            need_root "$0" --__cycle
        fi
        return
    fi

    run_cycle true   # silent=true: suppress warning, exit 0
}

# ── Restore hosts (remove goto-github block) ──────────────────────────────────
restore_hosts() {
    if grep -qF "$MARKER_START" "$HOSTS_FILE" 2>/dev/null; then
        remove_block
        log_info "已恢复原始 hosts 文件"
    else
        log_info "未找到 goto-github 条目，无需恢复"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    case "${1:-}" in
        --__cycle)
            # Internal: run_cycle mode (after sudo re-exec)
            run_cycle false
            ;;
        --__manual)
            # Internal: manual mode with pre-selected source (after sudo re-exec)
            if [ "${2:-}" = "remove" ]; then
                remove_block && flush_dns
                log_info "已删除 goto-github 条目"
            elif [ -n "${2:-}" ]; then
                local raw_content block
                raw_content=$(curl -sfL --connect-timeout 10 --max-time 30 "$2" 2>/dev/null) || {
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