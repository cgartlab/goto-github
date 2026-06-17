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

SOURCES="
  https://cdn.jsdelivr.net/gh/521xueweihan/GitHub520@main/hosts
  https://raw.hellogithub.com/hosts
"

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
    local ip
    ip=$(sed -n "/^${MARKER_START}$/,/^${MARKER_END}$/p" "$HOSTS_FILE" 2>/dev/null \
        | grep -v "^${MARKER_START}" | grep -v "^${MARKER_END}" \
        | grep -v '^#' | awk '{print $1}' | head -1 || true)

    echo ""
    echo "=== GoToGitHub Status ==="
    echo ""

    if [ -z "$ip" ]; then
        echo "  IP: (not installed)"
        echo "  Run 'sudo ./fetch.sh' to install."
    else
        echo "  IP:   $ip"
        local http_code
        http_code=$(curl -sf --connect-timeout 3 --max-time 6 \
            --resolve "github.com:443:$ip" \
            -o /dev/null -w "%{http_code}" \
            "https://github.com/" 2>/dev/null) || http_code=""
        if ! echo "$http_code" | grep -qE '^[0-9]{3}$'; then
            http_code="000"
        fi
        if [ "$http_code" = "200" ]; then
            echo -e "  Status: ${GREEN}OK${NC} — github.com reachable"
        else
            echo -e "  Status: ${RED}FAILED${NC} (HTTP $http_code)"
        fi
    fi
    echo ""
}

# ── Apply hosts block ──────────────────────────────────────────────────────────
apply_hosts() {
    local block="$1"
    remove_block
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
    local ip
    ip=$(sed -n "/^${MARKER_START}$/,/^${MARKER_END}$/p" "$HOSTS_FILE" 2>/dev/null \
        | grep -v "^${MARKER_START}" | grep -v "^${MARKER_END}" \
        | grep -v '^#' | awk '{print $1}' | head -1 || true)
    if [ -z "$ip" ]; then
        log_warn "No IP found in hosts block"
        return 1
    fi
    log_info "Verifying IP $ip against github.com..."
    local http_code
    http_code=$(curl -sf --connect-timeout 3 --max-time 6 \
        --resolve "github.com:443:$ip" \
        -o /dev/null -w "%{http_code}" \
        "https://github.com/" 2>/dev/null) || http_code=""
    if ! echo "$http_code" | grep -qE '^[0-9]{3}$'; then
        http_code="000"
    fi
    if [ "$http_code" = "200" ]; then
        log_info "Verification PASSED — github.com reachable via $ip"
        return 0
    else
        log_warn "Verification FAILED — github.com returned HTTP $http_code via $ip"
        return 1
    fi
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

show_menu_header() {
    local platform
    local installed
    platform=$(detect_platform_str)
    if [ -f "$HOSTS_FILE" ] && grep -qF "$MARKER_START" "$HOSTS_FILE" 2>/dev/null; then
        installed="已安装"
    else
        installed="未安装"
    fi

    echo ""
    echo "========================================"
    echo "         GoToGitHub — GitHub 加速工具"
    echo "========================================"
    echo "  平台: $platform"
    echo "  状态: $installed"
    echo "----------------------------------------"
    echo "  请选择操作:"
    echo ""
    echo "    1) 🚀  自动驾驶 (Auto-pilot)"
    echo "        自动检测平台，一键完成全部操作"
    echo ""
    echo "    2) 🔧  手动选择 (Manual)"
    echo "        自选数据源，管理 hosts 条目"
    echo ""
    echo "    3) ⚡  一键加速 (One-click)"
    echo "        sudo 模式，适合熟练用户"
    echo ""
    echo "----------------------------------------"
    echo -n "  请输入 [1-3] (默认 1): "
}

show_menu() {
    local choice
    show_menu_header
    read -r choice
    choice="${choice:-1}"
    echo ""
    case "$choice" in
        1) auto_drive ;;
        2) manual_select ;;
        3) one_click_accelerate ;;
        *) log_error "无效选项: $choice"; echo ""; show_menu ;;
    esac
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
        # macOS / Linux: re-exec with sudo
        log_info "需要管理员权限，正在请求 sudo..."
        exec sudo "$0" --__auto
        # exec does not return
    fi

    # --- We are root from here ---
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
        echo ""
        echo "========================================"
        echo "  ✅ 加速成功！GitHub 已可正常访问"
        echo "========================================"
        echo ""
    else
        log_warn "加速已应用，但验证未完全通过。"
        echo "  提示: 运行 ./fetch.sh --status 查看详情"
    fi
}

manual_select() {
    echo "========== 手动选择 =========="
    echo ""
    show_status

    echo "  请选择:"
    echo "    1) jsDelivr CDN（主源）"
    echo "    2) raw.hellogithub.com（备用源）"
    echo "    3) 删除已有条目（恢复原状）"
    echo "    4) 返回主菜单"
    echo ""
    echo -n "  请输入 [1-4] (默认 4): "
    local choice
    read -r choice
    choice="${choice:-4}"

    local selected_source=""
    case "$choice" in
        1) selected_source="https://cdn.jsdelivr.net/gh/521xueweihan/GitHub520@main/hosts" ;;
        2) selected_source="https://raw.hellogithub.com/hosts" ;;
        3)
            if ! is_root; then
                if is_mingw; then
                    log_error "需要管理员权限。请以管理员身份运行 Git Bash。"
                    exit 1
                fi
                exec sudo "$0" --__manual "remove"
            fi
            remove_block && flush_dns
            log_info "已删除 goto-github 条目"
            return 0
            ;;
        4) show_menu; return 0 ;;
        *) log_error "无效选项: $choice"; manual_select; return 0 ;;
    esac

    if [ -n "$selected_source" ]; then
        if ! is_root; then
            if is_mingw; then
                log_error "需要管理员权限。请以管理员身份运行 Git Bash。"
                exit 1
            fi
            exec sudo "$0" --__manual "$selected_source"
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
    if is_root; then
        local raw_content block
        raw_content=$(fetch_hosts_content) || exit 1
        block=$(build_hosts_block "$raw_content")
        apply_hosts "$block"
        flush_dns
        verify_hosts || true
    elif is_mingw; then
        log_error "需要管理员权限。"
        echo ""
        echo "  请右键点击 Git Bash，选择「以管理员身份运行」，然后执行:"
        echo ""
        echo "    cd $(pwd)"
        echo "    ./fetch.sh"
        echo ""
    else
        log_info "正在请求 sudo..."
        exec sudo "$0" --__auto
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    case "${1:-}" in
        --__auto)
            # Internal: auto-drive mode (after sudo re-exec)
            auto_drive
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
        --help|-h)
            echo "Usage: $0 [--status|--restore|--help]"
            echo ""
            echo "  (no flags)     Interactive menu (auto-pilot, manual, one-click)"
            echo "                 Non-TTY / CI: runs full cycle if root"
            echo "  --status       Show current IP and connectivity status"
            echo "  --restore      Remove goto-github entries from /etc/hosts"
            echo "  --help         Show this help"
            echo ""
            echo "Data sources (mirror list with automatic fallback):"
            echo "  https://cdn.jsdelivr.net/gh/521xueweihan/GitHub520@main/hosts"
            echo "  https://raw.hellogithub.com/hosts"
            echo ""
            echo "Environment:"
            echo "  HOSTS_FILE  hosts file path (default: /etc/hosts)"
            echo ""
            echo "Platforms: macOS · Linux · Git Bash (Windows)"
            ;;
        "")
            # TTY: show interactive menu; non-TTY: run full cycle if root
            if is_tty; then
                show_menu
            elif ! is_root; then
                log_error "This operation requires sudo. Run: sudo $0"
                exit 1
            else
                local raw_content block
                raw_content=$(fetch_hosts_content) || exit 1
                block=$(build_hosts_block "$raw_content") || exit 1
                apply_hosts "$block"
                flush_dns
                if verify_hosts; then
                    log_info "Done. Run '$0 --status' to verify."
                else
                    log_warn "Applied but verification failed. Check your network or try again."
                fi
            fi
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Usage: $0 [--status|--restore|--help]"
            exit 1
            ;;
    esac
}

main "$@"