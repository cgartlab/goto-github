#!/usr/bin/env bash
# =============================================================================
# scripts/connectivity_probe.sh — Phase 1 connectivity sampling (read-only)
# Outputs single-line JSON to stdout; progress goes to stderr.
# =============================================================================
# Samples 5 GitHub endpoints N times each, reporting success rate and latency
# distribution. ALWAYS bypasses the proxy (--noproxy '*') — probing through a
# proxy measures the proxy, not the machine's connectivity to GitHub.
#
# Why N samples: single-request outcomes are near-random under this kind of
# interference. Measured: the same endpoint went 60% -> 30% between two runs
# one minute apart. Only the success rate is meaningful.
# =============================================================================
# Usage:
#   ./scripts/connectivity_probe.sh [--attempts N] [--timeout SEC] [--help]
#
# Options:
#   --attempts N   samples per endpoint (default 10, minimum 5 for a verdict)
#   --timeout SEC  connect timeout in seconds (default 5)
#
# Environment:
#   PROBE_REPO  owner/repo used for git/download endpoints (default: this repo)
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

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=/dev/null
. "$REPO_ROOT/lib/00-constants.sh"

ATTEMPTS=10
CONNECT_TIMEOUT=5
PROBE_REPO="${PROBE_REPO:-cgartlab/goto-github}"

show_help() {
    cat <<'EOF'
Usage: connectivity_probe.sh [--attempts N] [--timeout SEC] [--help]

Phase 1 connectivity sampling for the goto-github skill. Read-only.

Samples 5 GitHub endpoints N times each and reports success rate plus
latency distribution (min/max/avg). Always bypasses the proxy.

Options:
  --attempts N   samples per endpoint (default 10; below 5 the verdict is
                 unstable and the report must say so)
  --timeout SEC  connect timeout in seconds (default 5)

Output: single-line JSON on stdout.

Environment:
  PROBE_REPO  owner/repo for git/download endpoints (default cgartlab/goto-github)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --attempts) ATTEMPTS="${2:-10}"; shift 2 ;;
        --timeout)  CONNECT_TIMEOUT="${2:-5}"; shift 2 ;;
        --help|-h)  show_help; exit 0 ;;
        *) echo "Unknown option: $1" >&2; show_help >&2; exit 1 ;;
    esac
done

# Guard: fewer than 5 samples cannot support a verdict.
if [ "$ATTEMPTS" -lt 5 ]; then
    echo "WARNING: --attempts $ATTEMPTS is below 5; the success rate is not statistically meaningful" >&2
fi

# ── Endpoint table (order is fixed — see references/judgment-criteria.md) ────
# key<TAB>url
endpoints() {
    printf 'web\thttps://github.com/\n'
    printf 'api\thttps://api.github.com/\n'
    printf 'download\thttps://codeload.github.com/%s/tar.gz/refs/heads/main\n' "$PROBE_REPO"
    printf 'raw\thttps://raw.githubusercontent.com/%s/main/README.md\n' "$PROBE_REPO"
    printf 'git\thttps://github.com/%s/info/refs?service=git-upload-pack\n' "$PROBE_REPO"
}

# ── JSON escaping ────────────────────────────────────────────────────────────
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# ── Sample one endpoint N times ──────────────────────────────────────────────
# Emits: "success fail min max avg" (avg/min/max empty when zero successes)
sample_endpoint() {
    local url="$1"
    local ok=0 fail=0
    local times=()
    local i out rc code t

    for ((i = 1; i <= ATTEMPTS; i++)); do
        out=$(curl --noproxy '*' -s -o /dev/null \
            --connect-timeout "$CONNECT_TIMEOUT" \
            --max-time $((CONNECT_TIMEOUT + 2)) \
            -w '%{http_code},%{time_total}' \
            "$url" 2>/dev/null)
        rc=$?

        # rc=0 AND a real HTTP code (not 000) = success.
        # 000 means no response at all: connection failed, timeout, or DNS
        # failure. Counting it as success would report a fully blocked
        # endpoint as "100% available".
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

# ── Main ─────────────────────────────────────────────────────────────────────
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
endpoints_json=""
first=1

while IFS=$'\t' read -r key url; do
    [ -z "$key" ] && continue

    echo "  probing $key ($url) ..." >&2

    read -r ok fail min max avg <<< "$(sample_endpoint "$url")"
    rate=$(awk -v o="$ok" -v n="$ATTEMPTS" 'BEGIN{printf "%.0f", (o/n)*100}')

    if [ "$min" = "null" ]; then
        lat="null"
    else
        lat="{\"min\":$min,\"max\":$max,\"avg\":$avg}"
    fi

    [ $first -eq 0 ] && endpoints_json+=","
    first=0
    endpoints_json+="{\"key\":\"$key\",\"url\":\"$(json_escape "$url")\",\"success\":$ok,\"fail\":$fail,\"rate\":$rate,\"latency\":$lat}"

    echo "    -> $ok/$ATTEMPTS ($rate%)" >&2
done < <(endpoints)

# Sample-size caveat belongs in the JSON, not only on stderr.
sample_warning=""
if [ "$ATTEMPTS" -lt 5 ]; then
    sample_warning="\"sample_size is $ATTEMPTS (below 5); the success rate is not statistically meaningful\""
fi

warn_json="[]"
if [ -n "$sample_warning" ]; then
    warn_json="[$sample_warning]"
fi

printf '%s\n' "$(cat <<EOF
{"timestamp":"$timestamp","proxy_bypassed":true,"attempts":$ATTEMPTS,"endpoints":[$endpoints_json],"warnings":$warn_json}
EOF
)"
