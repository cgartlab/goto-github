#!/usr/bin/env bash
# =============================================================================
# scripts/hosts_status.sh — Phase 4 verification + status (read-only)
# Outputs single-line JSON to stdout; progress goes to stderr.
# =============================================================================
# Re-samples the same 5 endpoints as connectivity_probe.sh and reports a
# verdict comparing the result against the thresholds in
# references/judgment-criteria.md.
#
# A previous probe result can be supplied via --baseline <file.json>; the
# verdict is then computed against that baseline rather than the thresholds
# alone, so "fixed" means "improved over the pre-repair measurement".
# =============================================================================
# Usage:
#   ./scripts/hosts_status.sh [--attempts N] [--timeout SEC]
#                            [--baseline <file.json>] [--help]
#
# Environment:
#   HOSTS_FILE  hosts file path (default: /etc/hosts)
#   PROBE_REPO  owner/repo for git/download endpoints
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

HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
PROBE_REPO="${PROBE_REPO:-cgartlab/goto-github}"
ATTEMPTS=10
CONNECT_TIMEOUT=5
BASELINE=""

show_help() {
    cat <<'EOF'
Usage: hosts_status.sh [--attempts N] [--timeout SEC] [--baseline FILE] [--help]

Phase 4 verification for the goto-github skill. Read-only.

Re-samples the same 5 endpoints as connectivity_probe.sh and emits a verdict:
  fixed        web crossed the threshold and git/api did not regress
  partial      at least one endpoint improved, threshold not reached
  not_fixed    no endpoint improved
  not_installed  no goto-github marker block present

Options:
  --attempts N   samples per endpoint (default 10; must match the baseline)
  --timeout SEC  connect timeout in seconds (default 5)
  --baseline F   previous connectivity_probe JSON output; the verdict is
                 computed against it (improvement, not just thresholds)

Environment:
  HOSTS_FILE  hosts file path (default: /etc/hosts)
  PROBE_REPO  owner/repo for git/download endpoints
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

# ── Endpoints (same order/shape as connectivity_probe.sh) ────────────────────
sample_endpoint() {
    local url="$1"
    local ok=0 fail=0 times=() i out rc code t
    for ((i = 1; i <= ATTEMPTS; i++)); do
        out=$(curl --noproxy '*' -s -o /dev/null \
            --connect-timeout "$CONNECT_TIMEOUT" --max-time $((CONNECT_TIMEOUT + 2)) \
            -w '%{http_code},%{time_total}' "$url" 2>/dev/null)
        rc=$?
        code="${out%%,*}"
        if [ $rc -eq 0 ] && [ "$code" != "000" ] && [ -n "$code" ]; then
            ok=$((ok + 1))
            t="${out##*,}"
            times+=("$t")
        else
            fail=$((fail + 1))
        fi
    done

    local min="" max="" sum="0" avg=""
    if [ ${#times[@]} -gt 0 ]; then
        for t in "${times[@]}"; do
            min=$(awk -v a="$t" -v b="${min:-99}" 'BEGIN{print (a<b)?a:b}')
            max=$(awk -v a="$t" -v b="${max:-0}" 'BEGIN{print (a>b)?a:b}')
            sum=$(awk -v a="$t" -v b="$sum" 'BEGIN{printf "%.6f", a+b}')
        done
        avg=$(awk -v s="$sum" -v n="${#times[@]}" 'BEGIN{printf "%.3f", s/n}')
        min=$(awk -v m="$min" 'BEGIN{printf "%.3f", m}')
        max=$(awk -v m="$max" 'BEGIN{printf "%.3f", m}')
    fi
    printf '%d %d %s %s %s\n' "$ok" "$fail" "${min:-null}" "${max:-null}" "${avg:-null}"
}

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
declare -A rates=()

probe_urls() {
    printf 'web\thttps://github.com/\n'
    printf 'api\thttps://api.github.com/\n'
    printf 'download\thttps://codeload.github.com/%s/tar.gz/refs/heads/main\n' "$PROBE_REPO"
    printf 'raw\thttps://raw.githubusercontent.com/%s/main/README.md\n' "$PROBE_REPO"
    printf 'git\thttps://github.com/%s/info/refs?service=git-upload-pack\n' "$PROBE_REPO"
}

while IFS=$'\t' read -r key url; do
    [ -z "$key" ] && continue
    echo "  probing $key ..." >&2
    read -r ok fail min max avg <<< "$(sample_endpoint "$url")"
    rate=$(awk -v o="$ok" -v n="$ATTEMPTS" 'BEGIN{printf "%.0f", (o/n)*100}')
    rates["$key"]=$rate
    if [ "$min" = "null" ]; then lat="null"; else lat="{\"min\":$min,\"max\":$max,\"avg\":$avg}"; fi
    [ $first -eq 0 ] && endpoints_json+=","
    first=0
    endpoints_json+="{\"key\":\"$key\",\"url\":\"$(json_escape "$url")\",\"success\":$ok,\"fail\":$fail,\"rate\":$rate,\"latency\":$lat}"
    echo "    -> $ok/$ATTEMPTS ($rate%)" >&2
done < <(probe_urls)

# ── Verdict ──────────────────────────────────────────────────────────────────
verdict="not_fixed"
warnings=()

if [ "$installed" = "false" ]; then
    verdict="not_installed"
else
    web_rate=${rates[web]:-0}
    git_rate=${rates[git]:-0}
    api_rate=${rates[api]:-0}

    if [ -n "$BASELINE" ] && [ -f "$BASELINE" ]; then
        # Compare against the pre-repair measurement: "fixed" must mean
        # improvement, not just a good absolute number (the network is
        # time-varying; a good number now does not prove we caused it).
        base_web=$(grep -o '"key":"web"[^}]*"rate":[0-9]*' "$BASELINE" | grep -o '"rate":[0-9]*' | tail -1 | cut -d: -f2 || true)
        base_git=$(grep -o '"key":"git"[^}]*"rate":[0-9]*' "$BASELINE" | grep -o '"rate":[0-9]*' | tail -1 | cut -d: -f2 || true)
        base_api=$(grep -o '"key":"api"[^}]*"rate":[0-9]*' "$BASELINE" | grep -o '"rate":[0-9]*' | tail -1 | cut -d: -f2 || true)

        improved=0
        # Noise floor: a 1-point wobble is not an improvement. The network is
        # time-varying enough that 99% -> 100% happens by chance; counting that
        # as "the repair helped" is exactly the false positive this baseline
        # comparison exists to prevent.
        for pair in "web:$base_web:$web_rate" "git:$base_git:$git_rate" "api:$base_api:$api_rate"; do
            rest="${pair#*:}"; b="${rest%%:*}"; n="${rest##*:}"
            if [ -n "$b" ] && [ $((n - b)) -ge "$IMPROVE_MARGIN" ]; then
                improved=$((improved + 1))
            fi
        done

        if [ "$web_rate" -ge "$WEB_OK" ] && [ "$improved" -gt 0 ] \
           && [ "$git_rate" -ge "$GIT_OK" ] && [ "$api_rate" -ge "$API_OK" ]; then
            verdict="fixed"
        elif [ "$improved" -gt 0 ]; then
            verdict="partial"
            warnings+=("some endpoints improved but the thresholds were not reached")
        else
            verdict="not_fixed"
            warnings+=("no endpoint improved over the baseline; the hosts change did not help")
        fi

        if [ "$git_rate" -lt "$GIT_OK" ] || [ "$api_rate" -lt "$API_OK" ]; then
            warnings+=("git or api endpoint is below threshold; the hosts entry may be shadowed or the IP is dead")
        fi
    else
        # No baseline: threshold-only verdict, and say so.
        if [ "$web_rate" -ge "$WEB_OK" ] && [ "$git_rate" -ge "$GIT_OK" ] && [ "$api_rate" -ge "$API_OK" ]; then
            verdict="fixed"
            warnings+=("verdict based on thresholds only (no --baseline supplied); the network is time-varying so this does not prove the repair caused it")
        elif [ "$web_rate" -ge "$WEB_OK" ]; then
            verdict="partial"
            warnings+=("web endpoint is healthy but git/api are below threshold")
        else
            verdict="not_fixed"
            warnings+=("web endpoint is still below the $WEB_OK% threshold")
        fi
    fi
fi

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

printf '%s\n' "$(cat <<EOF
{"timestamp":"$timestamp","installed":$installed,"current_ip":$current_ip,"endpoints":[$endpoints_json],"verdict":"$verdict","warnings":$warn_json}
EOF
)"
