#!/usr/bin/env bash
# =============================================================================
# GoToGitHub — Local fetch script
# Fetches cloud-verified GitHub CDN IPs from the repo and applies to /etc/hosts
# =============================================================================
# Usage:
#   sudo ./fetch.sh              # Fetch and apply IPs
#   ./fetch.sh --status         # Show current IP status
#   ./fetch.sh --restore        # Remove goto-github entries from /etc/hosts
#   ./fetch.sh --help           # Show this help
#
# Environment variables:
#   GITHUB_IPS_URL   — URL to github-ips.json (default: auto-detect from branch)
#   HOSTS_FILE      — hosts file path (default: /etc/hosts)
# =============================================================================

set -euo pipefail

# ── Constants ────────────────────────────────────────────────────────────────
HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
MARKER_START="# >>> goto-github >>>"
MARKER_END="# <<< goto-github <<<"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ── Helpers ──────────────────────────────────────────────────────────────────
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

is_macos()  { [ "$(uname)" = "Darwin" ]; }
is_linux()  { [ "$(uname)" = "Linux" ]; }

# ── Retry curl ────────────────────────────────────────────────────────────────
# Usage: retry_curl <url> [connect_timeout] [max_time]
retry_curl() {
    local url="$1"
    local connect_timeout="${2:-5}"
    local max_time="${3:-15}"
    local attempt=0
    local max_attempts=3

    while [ $((attempt += 1)) -le $max_attempts ]; do
        if curl -sf --connect-timeout "$connect_timeout" \
               --max-time "$max_time" \
               -o /dev/null "$url" 2>/dev/null; then
            return 0
        fi
        if [ $attempt -lt $max_attempts ]; then
            log_warn "Retry $attempt/$max_attempts for $url"
            sleep 2
        fi
    done
    return 1
}

# ── Detect cloud URL ──────────────────────────────────────────────────────────
# Auto-detects the raw github-ips.json URL based on current git remote
detect_cloud_url() {
    local remote="${1:-origin}"
    local repo_url
    repo_url=$(git remote get-url "$remote" 2>/dev/null | sed 's/\.git$//')
    [ -z "$repo_url" ] && return 1

    # Extract owner/repo from git URL
    local owner_repo
    # shellcheck disable=SC2001
    owner_repo=$(echo "$repo_url" | sed 's|.*github\.com/||;s|\.git$||')
    [ -z "$owner_repo" ] && return 1

    # Determine branch (use current branch, fallback to main)
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    [ "$branch" = "HEAD" ] && branch="main"

    echo "https://raw.githubusercontent.com/${owner_repo}/${branch}/github-ips.json"
}

# ── Fetch IP JSON from cloud ──────────────────────────────────────────────────
fetch_cloud_json() {
    local url="$1"
    log_info "Fetching IPs from $url"

    local json
    json=$(curl -sf --connect-timeout 5 --max-time 15 "$url" 2>/dev/null) || {
        log_error "Failed to fetch $url"
        return 1
    }

    # Validate JSON structure
    if ! echo "$json" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'servers' in d" 2>/dev/null; then
        log_error "Invalid JSON from cloud (missing 'servers' key)"
        return 1
    fi

    echo "$json"
}

# ── Parse JSON and build hosts block ─────────────────────────────────────────
build_hosts_block() {
    local json="$1"

    echo "$json" | python3 -c "
import json, sys

d = json.load(sys.stdin)
servers = d.get('servers', {})

lines = []
lines.append('# >>> goto-github >>>')
lines.append('# Managed by GoToGitHub — $(date +%Y-%m-%d)')
lines.append('# Source: GitHub Actions cloud scan')

# Group domains by IP
ip_groups = {}
dns_domains = []

for domain, info in servers.items():
    mode = info.get('mode', 'hosts')
    if mode == 'dns':
        dns_domains.append(domain)
        continue
    best_ip = info.get('best_ip')
    if not best_ip:
        continue
    if best_ip not in ip_groups:
        ip_groups[best_ip] = []
    ip_groups[best_ip].append(domain)

# Write pinned domains
for ip, domains in sorted(ip_groups.items()):
    lines.append(f'{ip:15} {\" \".join(domains)}')

# DNS-only comment
if dns_domains:
    lines.append(f'# DNS domains (not pinned): {\" \".join(dns_domains)}')

lines.append('# <<< goto-github <<<')
print('\n'.join(lines))
" 2>/dev/null || {
        log_error "Failed to parse JSON"
        return 1
    }
}

# ── Check sudo ────────────────────────────────────────────────────────────────
# shellcheck disable=SC2120
need_sudo() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script requires sudo. Run: sudo $0"
        exit 1
    fi
}

# ── Flush DNS cache ───────────────────────────────────────────────────────────
flush_dns() {
    log_info "Flushing DNS cache..."
    if is_macos; then
        killall -HUP mDNSResponder 2>/dev/null || true
        dscacheutil -flushcache 2>/dev/null || true
    elif is_linux; then
        resolvectl flush-caches 2>/dev/null || true
        systemctl restart systemd-resolved 2>/dev/null || true
    fi
    log_info "DNS cache flushed"
}

# ── Remove existing goto-github block ────────────────────────────────────────
remove_block() {
    if ! grep -qF "$MARKER_START" "$HOSTS_FILE" 2>/dev/null; then
        return 0  # Nothing to remove
    fi

    if is_macos; then
        sed -i '' "/^${MARKER_START//\//\\/}/,/^${MARKER_END//\//\\/}/d" "$HOSTS_FILE"
    else
        sed -i "/^${MARKER_START//\//\\/}/,/^${MARKER_END//\//\\/}/d" "$HOSTS_FILE"
    fi
}

# ── Apply hosts entry ──────────────────────────────────────────────────────────
apply_hosts() {
    local block="$1"

    remove_block

    {
        echo ""
        echo "$block"
    } | sudo tee -a "$HOSTS_FILE" > /dev/null

    log_info "Applied to $HOSTS_FILE"
}

# ── Verify applied IP ───────────────────────────────────────────────────────────
verify_hosts() {
    local ip
    ip=$(sed -n "/^${MARKER_START}$/,/^${MARKER_END}$/p" "$HOSTS_FILE" 2>/dev/null \
        | grep -v "^${MARKER_START}" | grep -v "^${MARKER_END}" \
        | grep -v '^#' | awk '{print $1}' | head -1)

    if [ -z "$ip" ]; then
        log_warn "No IP found in hosts block"
        return 1
    fi

    log_info "Verifying IP $ip against github.com..."
    local http_code
    http_code=$(curl -sf --connect-timeout 3 --max-time 6 \
        --resolve "github.com:443:$ip" \
        -o /dev/null \
        -w "%{http_code}" \
        "https://github.com/" 2>/dev/null || echo "000")

    if [ "$http_code" = "200" ]; then
        log_info "Verification PASSED — github.com reachable via $ip"
        return 0
    else
        log_warn "Verification FAILED — github.com returned HTTP $http_code via $ip"
        return 1
    fi
}

# ── Show status ───────────────────────────────────────────────────────────────
show_status() {
    local ip block_time

    ip=$(sed -n "/^${MARKER_START}$/,/^${MARKER_END}$/p" "$HOSTS_FILE" 2>/dev/null \
        | grep -v "^${MARKER_START}" | grep -v "^${MARKER_END}" \
        | grep -v '^#' | awk '{print $1}' | head -1)

    block_time=$(sed -n "/^${MARKER_START}$/,/^${MARKER_END}$/p" "$HOSTS_FILE" 2>/dev/null \
        | grep '# Updated at\|# Managed by GoToGitHub' | head -1)

    echo ""
    echo "=== GoToGitHub Status ==="
    echo ""

    if [ -z "$ip" ]; then
        echo "  IP: (not installed)"
    else
        echo "  IP:   $ip"
    fi

    if [ -n "$block_time" ]; then
        echo "  $block_time"
    fi

    if [ -n "$ip" ]; then
        local http_code
        http_code=$(curl -sf --connect-timeout 3 --max-time 6 \
            --resolve "github.com:443:$ip" \
            -o /dev/null \
            -w "%{http_code}" \
            "https://github.com/" 2>/dev/null || echo "000")

        if [ "$http_code" = "200" ]; then
            echo -e "  Status: ${GREEN}OK${NC}"
        else
            echo -e "  Status: ${RED}FAILED${NC} (HTTP $http_code)"
        fi
    fi

    echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    case "${1:-}" in
        --status)
            show_status
            ;;
        --restore)
            need_sudo "$@"
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
            echo "  Without flags:   Fetch cloud IPs and apply to /etc/hosts (requires sudo)"
            echo "  --status:       Show current IP and status"
            echo "  --restore:      Remove goto-github entries from /etc/hosts"
            echo ""
            echo "Environment:"
            echo "  GITHUB_IPS_URL  URL to github-ips.json (auto-detected if not set)"
            echo "  HOSTS_FILE     hosts file path (default: /etc/hosts)"
            ;;
        "")
            need_sudo "$@"

            # Detect or use provided URL
            local url="${GITHUB_IPS_URL:-}"
            if [ -z "$url" ]; then
                url=$(detect_cloud_url) || {
                    log_error "Failed to auto-detect cloud URL. Set GITHUB_IPS_URL manually."
                    exit 1
                }
            fi

            log_info "Using cloud URL: $url"

            # Fetch and parse
            local json block
            json=$(fetch_cloud_json "$url") || exit 1
            block=$(build_hosts_block "$json") || exit 1

            # Apply
            apply_hosts "$block"
            flush_dns

            # Verify
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