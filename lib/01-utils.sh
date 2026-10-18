#!/usr/bin/env bash
# =============================================================================
# lib/01-utils.sh — logging, platform detection, privilege, DNS, TCP helpers
# Sourced after 00-constants.sh. Do not execute directly.
# =============================================================================
# shellcheck shell=bash

if [ -n "${GOTO_GITHUB_01_UTILS_LOADED:-}" ]; then
    return 0
fi
GOTO_GITHUB_01_UTILS_LOADED=1

# ── Logging ──────────────────────────────────────────────────────────────────
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── Platform / privilege predicates ──────────────────────────────────────────
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
        uname
    fi
}

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

# ── Interrupt cleanup ────────────────────────────────────────────────────────
# Remove any temp file left by an interrupted apply.
cleanup() {
    [ -n "${TMP_FILE:-}" ] && rm -f "$TMP_FILE"
    echo ""
    echo "  感谢使用 GoToGitHub，再见！"
    exit 0
}

# ── TCP reachability test ────────────────────────────────────────────────────
# Returns 0 if IP:port is reachable, 1 if not.
test_tcp_reachable() {
    local ip="$1"
    local port="${2:-443}"
    local timeout="${3:-3}"
    if command -v nc >/dev/null 2>&1; then
        nc -z -w "$timeout" "$ip" "$port" 2>/dev/null
    else
        # Fallback: use curl to test connection (exit code 0 = success, 22 = HTTP error = TCP worked)
        local rc=0
        curl -s --insecure --connect-timeout "$timeout" --max-time "$((timeout + 2))" \
            -o /dev/null "https://${ip}:${port}/" 2>/dev/null || rc=$?
        # 0 = success, 22 = HTTP error (TCP worked), 35 = TLS connect error (TCP worked),
        # 60 = cert mismatch (expected when connecting by IP — TCP still works)
        [ "$rc" -eq 0 ] || [ "$rc" -eq 22 ] || [ "$rc" -eq 35 ] || [ "$rc" -eq 60 ]
    fi
}

# curl reports 000 when there is no response at all (connection failed, timeout,
# or DNS failure). Real HTTP status codes are 1xx-5xx, so requiring a leading
# 1-5 keeps 000 from being miscounted as "reachable" — a hosts entry can point
# at a dead IP and still print OK otherwise.
is_http_code_ok() {
    case "$1" in
        [1-5][0-9][0-9]) return 0 ;;
    esac
    return 1
}

# Map common curl failures to short, actionable diagnostics.
describe_curl_error() {
    local rc="$1" stderr="$2"

    case "$rc" in
        3) printf 'redirect loop' ;;
        5) printf 'unable to resolve proxy host' ;;
        6) printf 'unable to resolve host' ;;
        7) printf 'connection failed' ;;
        22) printf 'HTTP error response' ;;
        28) printf 'request timeout' ;;
        35) printf 'TLS connection error' ;;
        60) printf 'SSL certificate problem' ;;
        0) printf 'empty response' ;;
        *) printf 'exit %s' "$rc" ;;
    esac

    if [ -n "$stderr" ]; then
        printf ', stderr: %s' "$stderr"
    fi
}

# ── DNS cache flush ──────────────────────────────────────────────────────────
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
