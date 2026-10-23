#!/usr/bin/env bash
# =============================================================================
# scripts/hosts_status.sh — Phase 4 verification + status (read-only)
# Outputs single-line JSON to stdout; progress goes to stderr.
# =============================================================================
# Re-samples the same endpoints as connectivity_probe.sh (via the shared
# lib/probe.sh) and reports a two-dimensional verdict:
#
#   network — recomputed from the live sample, plus a comparison against
#             --baseline when one is supplied
#   auth    — passed through from auth_probe via environment variables; an auth
#             failure is NOT a network failure and is never folded into the
#             network verdict
#
# bash 3.2 compatible (macOS default).
# =============================================================================
# Usage:
#   ./scripts/hosts_status.sh [--attempts N] [--timeout SEC]
#                            [--baseline <file.json>] [--help]
# =============================================================================

set -uo pipefail

_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
    _dir="$(cd -P "$(dirname "$_src")" && pwd)"
    _src="$(readlink "$_src")"
    [[ "$_src" != /* ]] && _src="$_dir/$_src"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
unset _src _dir

# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/constants.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/endpoints.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/probe.sh"

HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
ATTEMPTS=10
CONNECT_TIMEOUT=5
BASELINE=""

show_help() {
    cat <<'EOF'
Usage: hosts_status.sh [--attempts N] [--timeout SEC] [--baseline FILE] [--help]

Phase 4 verification for the goto-github skill. Read-only.

Re-samples every core endpoint and emits a verdict:
  fixed          core endpoints meet their thresholds without regression
  partial        at least one endpoint improved by >= 10 points, threshold not met
  not_fixed      no endpoint improved / core paths below 50%
  not_installed  no goto-github marker block present

Auth state (ssh / https) is read from SSH_AUTH_STATE and HTTPS_AUTH_STATE, set
by auth_probe. It is reported as a separate dimension because an auth failure
is not a network failure.

Options:
  --attempts N   samples per endpoint (default 10; must match the baseline)
  --timeout SEC  connect timeout in seconds (default 5)
  --baseline F   previous connectivity_probe JSON output; the verdict is
                 computed against it (improvement, not just thresholds)

Environment:
  HOSTS_FILE        hosts file path (default /etc/hosts)
  SSH_AUTH_STATE    transport-ok | auth-fail | blocked | unknown
  HTTPS_AUTH_STATE  ok | no-credentials | permission-denied | unknown
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --attempts) ATTEMPTS="${2:-10}"; shift 2 ;;
        --timeout)  CONNECT_TIMEOUT="${2:-5}"; shift 2 ;;
        --baseline) BASELINE="${2:-}"; shift 2 ;;
        --help|-h)  show_help; exit 0 ;;
        *) echo "Unknown option: $1" >&2; show_help >&2; exit 1 ;;
    esac
done

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# ── Thresholds (must match references/judgment-criteria.md) ──────────────────
GIT_OK=85
API_OK=85
WEB_OK=60
# Minimum improvement (percentage points) that counts as a real gain over the
# baseline. Below this the difference is sampling noise, not a repair effect.
IMPROVE_MARGIN=10

# ── Installed state ──────────────────────────────────────────────────────────
installed="false"
current_ip="null"
if grep -qF "$MARKER_START" "$HOSTS_FILE" 2>/dev/null; then
    installed="true"
    _ip=$(sed -n "/^${MARKER_START}/,/^${MARKER_END}$/p" "$HOSTS_FILE" 2>/dev/null \
        | grep -m1 -E '^[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+github\.com([[:space:]]|$)' \
        | awk '{print $1}' || true)
    [ -n "$_ip" ] && current_ip="\"$_ip\""
fi

# ── Sample ───────────────────────────────────────────────────────────────────
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
endpoints_json=""
first=1

# bash 3.2 has no associative arrays: keep a flat "key=rate" string and look
# values up with rate_of.
RATES=""

rate_of() {
    local key="$1"
    printf '%s' "$RATES" | tr ' ' '\n' | grep "^${key}=" | head -1 | cut -d= -f2
}

rate_or_zero() {
    local v
    v=$(rate_of "$1")
    if [ -n "$v" ]; then printf '%s' "$v"; else printf '0'; fi
}

# fd 3, not stdin: curl in the loop body inherits stdin and can swallow the
# remaining endpoint lines (observed: 10 endpoints reduced to 9).
exec 3< <(list_endpoints fast)
while IFS=$'\t' read -r key url group kind <&3; do
    [ -z "$key" ] && continue
    echo "  probing $key ..." >&2
    read -r ok fail min max avg <<< "$(probe_endpoint "$url" "$kind" "$ATTEMPTS" "$CONNECT_TIMEOUT")"
    rate=$(awk -v o="$ok" -v n="$ATTEMPTS" 'BEGIN{printf "%.0f", (o/n)*100}')
    RATES="$RATES ${key}=${rate}"
    if [ "$min" = "null" ]; then lat="null"; else lat="{\"min\":$min,\"max\":$max,\"avg\":$avg}"; fi
    [ $first -eq 0 ] && endpoints_json+=","
    first=0
    endpoints_json+="{\"key\":\"$key\",\"url\":\"$(json_escape "$url")\",\"group\":\"$group\",\"kind\":\"$kind\",\"success\":$ok,\"fail\":$fail,\"rate\":$rate,\"latency\":$lat}"
    echo "    -> $ok/$ATTEMPTS ($rate%)" >&2
done
exec 3<&-

# ── Network verdict ──────────────────────────────────────────────────────────
verdict="not_fixed"
warnings=()

if [ "$installed" = "false" ]; then
    verdict="not_installed"
else
    web_rate=$(rate_or_zero web)
    api_rate=$(rate_or_zero api)
    git_read_rate=$(rate_or_zero git_read)

    if [ -n "$BASELINE" ] && [ -f "$BASELINE" ]; then
        # Compare against the pre-repair measurement: "fixed" must mean
        # improvement, not just a good absolute number.
        base_web=$(grep -o '"key":"web"[^}]*"rate":[0-9]*' "$BASELINE" | grep -o '"rate":[0-9]*' | tail -1 | cut -d: -f2 || true)
        base_api=$(grep -o '"key":"api"[^}]*"rate":[0-9]*' "$BASELINE" | grep -o '"rate":[0-9]*' | tail -1 | cut -d: -f2 || true)
        base_git=$(grep -o '"key":"git_read"[^}]*"rate":[0-9]*' "$BASELINE" | grep -o '"rate":[0-9]*' | tail -1 | cut -d: -f2 || true)

        improved=0
        # Noise floor: a 1-point wobble is not an improvement.
        for pair in "web:$base_web:$web_rate" "api:$base_api:$api_rate" "git_read:$base_git:$git_read_rate"; do
            rest="${pair#*:}"; b="${rest%%:*}"; n="${rest##*:}"
            if [ -n "$b" ] && [ $((n - b)) -ge "$IMPROVE_MARGIN" ]; then
                improved=$((improved + 1))
            fi
        done

        if [ "$improved" -gt 0 ] && [ "$git_read_rate" -ge "$GIT_OK" ] && [ "$api_rate" -ge "$API_OK" ]; then
            verdict="fixed"
        elif [ "$improved" -gt 0 ]; then
            verdict="partial"
            warnings+=("some endpoints improved but the core thresholds were not reached")
        else
            verdict="not_fixed"
            warnings+=("no endpoint improved over the baseline; the hosts change did not help")
        fi

        if [ "$git_read_rate" -lt "$GIT_OK" ] || [ "$api_rate" -lt "$API_OK" ]; then
            warnings+=("git_read or api is below threshold; the hosts entry may be shadowed or the IP is dead")
        fi
    else
        # No baseline: threshold-only verdict, and say so.
        if [ "$git_read_rate" -ge "$GIT_OK" ] && [ "$api_rate" -ge "$API_OK" ]; then
            verdict="fixed"
            warnings+=("verdict based on thresholds only (no --baseline supplied); the network is time-varying so this does not prove the repair caused it")
        elif [ "$git_read_rate" -ge 50 ] || [ "$api_rate" -ge 50 ]; then
            verdict="partial"
            warnings+=("git_read or api is between 50% and the threshold; partially working")
        else
            verdict="not_fixed"
            warnings+=("git_read and api are both below 50%; hosts cannot fix this — a proxy is required")
        fi
    fi

    if [ "$web_rate" -lt "$WEB_OK" ]; then
        warnings+=("web front page is at ${web_rate}% (below ${WEB_OK}%); browsing is degraded but CLI paths may be fine")
    fi
fi

# ── Auth dimension (independent of network) ──────────────────────────────────
auth_ssh="${SSH_AUTH_STATE:-unknown}"
auth_https="${HTTPS_AUTH_STATE:-unknown}"

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

cat <<EOF
{"timestamp":"$timestamp","installed":$installed,"current_ip":$current_ip,"endpoints":[$endpoints_json],"verdict":"$verdict","auth":{"ssh":"$auth_ssh","https":"$auth_https"},"warnings":$warn_json}
EOF
