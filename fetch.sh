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

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    case "${1:-}" in
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
            echo "  (no flags)     Fetch GitHub CDN hosts and apply to /etc/hosts (requires sudo)"
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
            if [ "$(id -u)" -ne 0 ]; then
                log_error "This operation requires sudo. Run: sudo $0"
                exit 1
            fi
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
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Usage: $0 [--status|--restore|--help]"
            exit 1
            ;;
    esac
}

main "$@"