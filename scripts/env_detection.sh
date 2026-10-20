#!/usr/bin/env bash
# =============================================================================
# scripts/env_detection.sh — Phase 0 environment probe (read-only)
# Outputs single-line JSON to stdout; progress/diagnostics go to stderr.
# =============================================================================
# Detects: shell, platform, curl availability, hosts marker block (+shadowing),
# proxy state, DNS servers, gh auth state, privilege level.
#
# Never writes anything. Never contacts the network beyond DNS/gh queries.
# =============================================================================
# Usage:
#   ./scripts/env_detection.sh [--help]
#
# Environment:
#   HOSTS_FILE  hosts file path (default: /etc/hosts)
# =============================================================================

set -uo pipefail

# ── Resolve this script's directory (follow symlinks) ────────────────────────
_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
    _dir="$(cd -P "$(dirname "$_src")" && pwd)"
    _src="$(readlink "$_src")"
    [[ "$_src" != /* ]] && _src="$_dir/$_src"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
unset _src _dir

# The skill layer's own constants — deliberately NOT lib/00-constants.sh, which
# belongs to the pull-based CLI implementation.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/constants.sh"

show_help() {
    cat <<'EOF'
Usage: env_detection.sh [--help]

Phase 0 environment probe for goto-github skill. Read-only.

Detects: shell, platform, curl availability, hosts marker block and
shadowing, proxy state, DNS servers, gh auth state, privilege level.

Output: single-line JSON on stdout.

Environment:
  HOSTS_FILE  hosts file path (default: /etc/hosts)
EOF
}

case "${1:-}" in
    --help|-h) show_help; exit 0 ;;
esac

# ── JSON helpers (values must be pre-escaped by callers) ─────────────────────
warnings=()

add_warning() { warnings+=("$1"); }

# Escape a string for safe inclusion in a JSON string literal.
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# ── Platform ─────────────────────────────────────────────────────────────────
detect_platform_str() {
    if [ "$(uname)" = "Darwin" ]; then
        echo "macOS"
    elif [ "$(uname)" = "Linux" ]; then
        if grep -qi microsoft /proc/version 2>/dev/null; then
            echo "WSL"
        else
            echo "Linux"
        fi
    elif [[ "$(uname)" == MINGW* || "$(uname)" == MSYS* ]]; then
        echo "Windows Git Bash"
    else
        uname
    fi
}

platform="$(detect_platform_str)"

# ── curl availability ────────────────────────────────────────────────────────
curl_available="false"
curl_path=""
if command -v curl >/dev/null 2>&1; then
    curl_available="true"
    curl_path="$(command -v curl)"
fi

if [ "$curl_available" = "false" ]; then
    add_warning "curl not found; all connectivity probing is impossible"
fi

# ── Hosts marker block + shadowing ───────────────────────────────────────────
hosts_present="false"
hosts_ip="null"
hosts_shadowed="false"
hosts_shadow_detail="null"

if [ -f "$HOSTS_FILE" ]; then
    if grep -qF "$MARKER_START" "$HOSTS_FILE" 2>/dev/null; then
        hosts_present="true"
        # First IPv4 mapped to bare github.com inside the marker block
        local_ip=$(sed -n "/^${MARKER_START}/,/^${MARKER_END}$/p" "$HOSTS_FILE" 2>/dev/null \
            | grep -m1 -E '^[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+github\.com([[:space:]]|$)' \
            | awk '{print $1}' || true)
        if [ -n "$local_ip" ]; then
            hosts_ip="\"$local_ip\""
        else
            add_warning "goto-github marker block present but no github.com IP line found"
        fi

        # Shadowing: another tool's github.com entry ABOVE the marker block
        marker_line=$(grep -nF "$MARKER_START" "$HOSTS_FILE" 2>/dev/null | head -1 | cut -d: -f1 || true)
        if [ -n "$marker_line" ] && [ "$marker_line" -gt 1 ]; then
            shadow_hit=$(sed -n "1,$((marker_line - 1))p" "$HOSTS_FILE" 2>/dev/null \
                | grep -E '^[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+github\.com([[:space:]]|$)' \
                | head -1 || true)
            if [ -n "$shadow_hit" ]; then
                hosts_shadowed="true"
                hosts_shadow_detail="\"$(json_escape "$shadow_hit")\""
                add_warning "hosts file has a github.com entry above the goto-github block; it takes precedence and the block is inert"
            fi
        fi
    fi
else
    add_warning "hosts file not found: $HOSTS_FILE"
fi

# ── Proxy state ──────────────────────────────────────────────────────────────
proxy_enabled="false"
proxy_server="null"
proxy_source="none"

# macOS: scutil --proxy ; Linux/others: check env vars
if command -v scutil >/dev/null 2>&1; then
    _sp=$(scutil --proxy 2>/dev/null || true)
    if echo "$_sp" | grep -q 'HTTPEnable : 1'; then
        proxy_enabled="true"
        _srv=$(echo "$_sp" | awk '/HTTPProxy/ {print $3; exit}')
        _prt=$(echo "$_sp" | awk '/HTTPPort/ {print $3; exit}')
        if [ -n "$_srv" ]; then
            proxy_server="\"${_srv}:${_prt:-8080}\""
        fi
        proxy_source="system"
    fi
fi

if [ "$proxy_enabled" = "false" ]; then
    for _v in https_proxy HTTPS_PROXY http_proxy HTTP_PROXY ALL_PROXY all_proxy; do
        _val="${!_v:-}"
        if [ -n "$_val" ]; then
            proxy_enabled="true"
            proxy_server="\"$(json_escape "$_val")\""
            proxy_source="env"
            break
        fi
    done
fi

if [ "$proxy_enabled" = "true" ]; then
    add_warning "proxy detected ($proxy_source); connectivity probing must bypass it or results are not attributable"
fi

# ── DNS servers ──────────────────────────────────────────────────────────────
dns_json="[]"
if command -v scutil >/dev/null 2>&1; then
    _dns=$(scutil --dns 2>/dev/null | awk '/nameserver\[/ {print $3}' | sort -u | head -5 || true)
    if [ -n "$_dns" ]; then
        dns_json="[$(echo "$_dns" | sed 's/.*/"&"/' | paste -sd, -)]"
    fi
elif [ -r /etc/resolv.conf ]; then
    _dns=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null | sort -u | head -5 || true)
    if [ -n "$_dns" ]; then
        dns_json="[$(echo "$_dns" | sed 's/.*/"&"/' | paste -sd, -)]"
    fi
fi

# Windows Git Bash: /etc/resolv.conf is a stub, real DNS lives in the registry.
if [ "$dns_json" = "[]" ] && [[ "$(uname)" == MINGW* || "$(uname)" == MSYS* ]]; then
    if command -v reg.exe >/dev/null 2>&1; then
        _dns=$(reg.exe query \
            'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\6\Parameters\Interfaces' //s \
            //v NameServer 2>/dev/null | true)
        if [ -z "$_dns" ]; then
            # Per-interface DHCP-assigned servers live under Tcpip\Parameters\Interfaces
            _dns=$(reg.exe query \
                'HKLM\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' //s \
                //v DnsServerAddresses 2>/dev/null | true)
        fi
        # Fall back to the well-known public resolvers only as a last resort,
        # and say so in warnings rather than asserting them as configured.
        if [ -z "$_dns" ]; then
            add_warning "could not determine configured DNS servers on Windows"
        fi
    else
        add_warning "could not determine DNS servers (reg.exe unavailable)"
    fi
fi

# Query the resolver directly: works on every platform, including Git Bash.
if [ "$dns_json" = "[]" ] && [ "$curl_available" = "true" ]; then
    # Resolve github.com through the SYSTEM resolver (not a public DoH endpoint,
    # which may itself be blocked and would produce a misleading failure).
    # dns.google is not used: it is unreachable from some networks and its
    # unreachability says nothing about the local resolver.
    if curl --noproxy '*' -s --max-time 5 -o /dev/null \
        "https://github.com/" 2>/dev/null; then
        add_warning "dns_servers could not be enumerated; system DNS resolution verified functional"
    else
        add_warning "dns_servers could not be enumerated; DNS resolution NOT verified (github.com unreachable)"
    fi
fi

# ── gh auth state ────────────────────────────────────────────────────────────
gh_state="error"
gh_warning="null"

if command -v gh >/dev/null 2>&1; then
    # GITHUB_TOKEN shadows the keyring token when both exist.
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        # Test whether the env token actually works
        if GITHUB_TOKEN="$GITHUB_TOKEN" gh api user --jq .login >/dev/null 2>&1; then
            gh_state="keyring_ok"
        else
            gh_state="env_var_shadowed"
            gh_warning="\"GITHUB_TOKEN is set but invalid; it shadows a valid keyring token and breaks all gh commands (git operations are unaffected)\""
        fi
    else
        if gh api user --jq .login >/dev/null 2>&1; then
            gh_state="keyring_ok"
        else
            gh_state="none"
        fi
    fi
else
    gh_state="none"
fi

# ── Privilege ────────────────────────────────────────────────────────────────
privileged="false"
[ "$(id -u)" -eq 0 ] && privileged="true"

# ── Emit JSON ────────────────────────────────────────────────────────────────
# Field set must match scripts/env_detection.ps1 exactly (see
# references/probe-recipes.md). doh is Windows-only; bash platforms emit null
# because macOS/Linux have no equivalent DNS-bypass mechanism.
doh_json="null"

warn_json="[]"
if [ ${#warnings[@]} -gt 0 ]; then
    warn_json="["
    first=1
    for w in "${warnings[@]}"; do
        [ $first -eq 0 ] && warn_json+=","
        warn_json+="\"$(json_escape "$w")\""
        first=0
    done
    warn_json+="]"
fi

# Emit the JSON line and nothing else on stdout. Any diagnostic that must
# reach the user goes to stderr (above, via add_warning -> warnings[]).
printf '%s\n' "$(cat <<EOF
{"shell":"bash","platform":"$platform","curl":{"available":$curl_available,"path":"$curl_path"},"hosts_entry":{"present":$hosts_present,"ip":$hosts_ip,"shadowed":$hosts_shadowed,"shadowing_detail":$hosts_shadow_detail},"proxy":{"enabled":$proxy_enabled,"server":$proxy_server,"source":"$proxy_source"},"dns_servers":$dns_json,"doh":$doh_json,"gh_auth":{"state":"$gh_state","warning":$gh_warning},"privileged":$privileged,"warnings":$warn_json}
EOF
)"
