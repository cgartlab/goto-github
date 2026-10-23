#!/usr/bin/env bash
# =============================================================================
# scripts/connectivity_probe.sh — Phase 1 connectivity sampling (read-only)
# Outputs single-line JSON to stdout; progress goes to stderr.
# =============================================================================
# Samples the full GitHub service surface N times each, reporting success rate
# and latency distribution. ALWAYS bypasses the proxy (--noproxy '*') — probing
# through a proxy measures the proxy, not the machine's connectivity.
#
# Why the full surface and not 5 endpoints: a developer reaches GitHub through
# many independent paths (git read/write, API, raw, registries, SSH). A narrow
# probe says "GitHub is fine" while `docker pull ghcr.io/...` is dead.
#
# Why N samples: single-request outcomes are near-random under this kind of
# interference. Measured: the same endpoint went 60% -> 20% over three days,
# while api/git stayed at 100%. Only the success rate is meaningful.
#
# bash 3.2 compatible (macOS default).
# =============================================================================
# Usage:
#   ./scripts/connectivity_probe.sh [--attempts N] [--timeout SEC]
#                                   [--scope fast|all] [--help]
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

# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/constants.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/endpoints.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/probe.sh"

ATTEMPTS=10
CONNECT_TIMEOUT=5
SCOPE="fast"

show_help() {
    cat <<'EOF'
Usage: connectivity_probe.sh [--attempts N] [--timeout SEC] [--scope fast|all] [--help]

Phase 1 connectivity sampling for the goto-github skill. Read-only.

Samples every GitHub service surface N times each and reports success rate with
latency distribution (min/max/avg). Always bypasses the proxy. Machine-readable
JSON on stdout; progress on stderr.

Endpoint groups:
  web       github.com front page
  api       api.github.com (gh CLI, REST, GraphQL)
  git       smart-http: git_read (clone/fetch) and git_write (push handler)
  raw       raw.githubusercontent.com, gist.githubusercontent.com
  download  codeload.github.com (tarballs, zips)
  assets    github.githubassets.com
  ssh       tcp://github.com:22, tcp://ssh.github.com:443 (transport only;
            authentication is a separate dimension — see auth_probe)
  registry  ghcr.io, npm.pkg.github.com, maven.pkg.github.com (--scope all)

Options:
  --attempts N   samples per endpoint (default 10; below 5 not meaningful)
  --timeout SEC  connect timeout in seconds (default 5)
  --scope S      fast (default) covers everything except registries/assets

Environment:
  PROBE_REPO  owner/repo for git/download endpoints (default cgartlab/goto-github)
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --attempts) ATTEMPTS="${2:-10}"; shift 2 ;;
        --timeout)  CONNECT_TIMEOUT="${2:-5}"; shift 2 ;;
        --scope)    SCOPE="${2:-fast}"; shift 2 ;;
        --help|-h)  show_help; exit 0 ;;
        *) echo "Unknown option: $1" >&2; show_help >&2; exit 1 ;;
    esac
done

if [ "$ATTEMPTS" -lt 5 ]; then
    echo "WARNING: --attempts $ATTEMPTS is below 5; the success rate is not statistically meaningful" >&2
fi

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# ── Main ─────────────────────────────────────────────────────────────────────
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
endpoints_json=""
first=1

# fd 3, not stdin: curl in the loop body inherits stdin and can swallow the
# remaining endpoint lines (observed: 10 endpoints reduced to 9).
exec 3< <(list_endpoints "$SCOPE")
while IFS=$'\t' read -r key url group kind <&3; do
    [ -z "$key" ] && continue

    echo "  probing $key ($url) ..." >&2
    read -r ok fail min max avg <<< "$(probe_endpoint "$url" "$kind" "$ATTEMPTS" "$CONNECT_TIMEOUT")"
    rate=$(awk -v o="$ok" -v n="$ATTEMPTS" 'BEGIN{printf "%.0f", (o/n)*100}')

    if [ "$min" = "null" ]; then
        lat="null"
    else
        lat="{\"min\":$min,\"max\":$max,\"avg\":$avg}"
    fi

    [ $first -eq 0 ] && endpoints_json+=","
    first=0
    endpoints_json+="{\"key\":\"$key\",\"url\":\"$(json_escape "$url")\",\"group\":\"$group\",\"kind\":\"$kind\",\"success\":$ok,\"fail\":$fail,\"rate\":$rate,\"latency\":$lat}"

    echo "    -> $ok/$ATTEMPTS ($rate%)" >&2
done
# shellcheck disable=SC2181
exec 3<&-

warn_json="[]"
if [ "$ATTEMPTS" -lt 5 ]; then
    warn_json="[\"sample_size is $ATTEMPTS (below 5); the success rate is not statistically meaningful\"]"
fi

printf '%s\n' "$(cat <<EOF
{"timestamp":"$timestamp","proxy_bypassed":true,"attempts":$ATTEMPTS,"scope":"$SCOPE","endpoints":[$endpoints_json],"warnings":$warn_json}
EOF
)"
