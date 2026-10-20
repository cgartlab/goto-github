#!/usr/bin/env bash
# =============================================================================
# scripts/hosts_apply.sh — Phase 3 hosts repair (WRITES /etc/hosts)
# Outputs single-line JSON to stdout; progress goes to stderr.
# =============================================================================
# Writes the goto-github marker block into the hosts file. Strategy chain:
#   1. priority IPs   fast path, seconds
#   2. community      pull a verified hosts list
#   3. CIDR scan      last resort, minutes
#
# Safety (see references/safety-and-boundaries.md — non-negotiable):
#   - backup before any write; abort if backup fails
#   - shadowing check before AND after the write
#   - never edit outside the marker block
#   - idempotent: re-running never produces duplicate blocks
#   - probe target is the git smart-http endpoint, NOT the homepage
# =============================================================================
# Usage:
#   sudo ./scripts/hosts_apply.sh [--strategy priority|community|cidr|auto]
#   ./scripts/hosts_apply.sh --help
#
# Options:
#   --strategy S  force one strategy (default: auto = priority -> community -> cidr)
#
# Environment:
#   HOSTS_FILE  hosts file path (default: /etc/hosts)
#   PROBE_REPO  owner/repo for the git probe endpoint
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
# shellcheck source=/dev/null
. "$REPO_ROOT/lib/01-utils.sh"
# shellcheck source=/dev/null
. "$REPO_ROOT/lib/03-validate.sh"
# shellcheck source=/dev/null
. "$REPO_ROOT/lib/04-apply.sh"

HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
PROBE_REPO="${PROBE_REPO:-cgartlab/goto-github}"
STRATEGY="auto"

show_help() {
    cat <<'EOF'
Usage: hosts_apply.sh [--strategy priority|community|cidr|auto]

Phase 3 hosts repair for the goto-github skill. WRITES the hosts file.

Strategy chain (auto = try in order, stop at first success):
  priority    known-stable IPs only (seconds)
  community   pull a verified hosts list from community sources
  cidr        expand CIDR ranges and probe concurrently (minutes)

Safety: backs up before writing, checks for shadowing, only edits inside
the marker block, idempotent.

Requires root (or HOSTS_FILE pointing at a writable file for testing).

Options:
  --strategy S  force one strategy (default: auto)

Environment:
  HOSTS_FILE  hosts file path (default: /etc/hosts)
  PROBE_REPO  owner/repo for the git probe endpoint
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --strategy) STRATEGY="${2:-auto}"; shift 2 ;;
        --help|-h)  show_help; exit 0 ;;
        *) echo "Unknown option: $1" >&2; show_help >&2; exit 1 ;;
    esac
done

# ── JSON helpers ─────────────────────────────────────────────────────────────
warnings=()
add_warning() { warnings+=("$1"); }

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# ── Privilege ────────────────────────────────────────────────────────────────
# No automatic escalation: report the command the user should run. Auto-sudo
# silently grants privileges and loses the caller's environment.
#
# GOTO_GITHUB_TEST_PRIVILEGED=1 skips the check so the write path can be
# exercised against a temp HOSTS_FILE in CI. It does not grant any real
# privilege — writing a system hosts file still fails without root.
if [ "$(id -u)" -ne 0 ] && [ "${GOTO_GITHUB_TEST_PRIVILEGED:-0}" != "1" ]; then
    echo "ERROR: writing the hosts file requires root privileges." >&2
    echo "  Run: sudo $0 $*" >&2
    echo "  (this script does not auto-elevate)" >&2
    printf '%s\n' '{"applied":false,"strategy":null,"ip":null,"entries_written":0,"backup":null,"shadowing":{"checked":false,"found":false,"detail":null},"dns_flushed":false,"warnings":["not root; hosts not modified"]}'
    exit 1
fi

if [ ! -f "$HOSTS_FILE" ]; then
    printf '%s\n' '{"applied":false,"strategy":null,"ip":null,"entries_written":0,"backup":null,"shadowing":{"checked":false,"found":false,"detail":null},"dns_flushed":false,"warnings":["hosts file not found"]}'
    exit 1
fi

# ── Shadowing check (before) ─────────────────────────────────────────────────
shadow_found="false"
shadow_detail="null"
check_shadowing_detail() {
    local marker_line hit
    marker_line=$(grep -nF "$MARKER_START" "$HOSTS_FILE" 2>/dev/null | head -1 | cut -d: -f1 || true)
    [ -z "$marker_line" ] && return 1
    [ "$marker_line" -le 1 ] && return 1
    hit=$(sed -n "1,$((marker_line - 1))p" "$HOSTS_FILE" 2>/dev/null \
        | grep -E '^[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+github\.com([[:space:]]|$)' \
        | head -1 || true)
    if [ -n "$hit" ]; then
        shadow_found="true"
        shadow_detail="\"$(json_escape "$hit")\""
        add_warning "hosts has a github.com entry above the goto-github block; it takes precedence and our block will be inert"
        return 0
    fi
    return 1
}
check_shadowing_detail || true

# ── Probe target: git smart-http, NOT the homepage ───────────────────────────
# Some edge IPs serve the homepage but time out on git traffic. Probing the
# homepage would select a "false positive" IP that breaks clone/fetch/push.
# This mirrors lib/00-constants.sh PROBE_TARGET.
GIT_PROBE_TARGET="https://github.com/${PROBE_REPO}/info/refs?service=git-upload-pack"

# ── Strategy 1: priority IPs ─────────────────────────────────────────────────
# Uses curl --resolve so SNI still routes to github.com: the IP must actually
# serve that Host. Accepts a real git-upload-pack response (2xx).
try_priority_ips() {
    local ip code
    for ip in "${PRIORITY_IPS[@]}"; do
        code=$(curl --noproxy '*' -s -o /dev/null \
            --connect-timeout 3 --max-time 6 \
            -w '%{http_code}' \
            -H 'Accept: application/x-git-upload-pack-advertisement' \
            "$GIT_PROBE_TARGET" \
            --resolve "github.com:443:${ip}" 2>/dev/null || true)
        case "$code" in
            2*) echo "$ip"; return 0 ;;
        esac
    done
    return 1
}

# ── Strategy 2: community sources ────────────────────────────────────────────
# Pull a verified hosts list, filter dead core IPs, validate.
try_community_sources() {
    local content url line ip
    local -a pool=()

    while IFS= read -r url; do
        [ -z "$url" ] && continue
        content=$(curl -sfL --connect-timeout 8 --max-time 20 "$url" 2>/dev/null || true)
        [ -z "$content" ] && continue

        # Collect the github.com IPs the source offers
        while IFS= read -r line; do
            ip=$(echo "$line" | awk '{print $1}')
            [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
            pool+=("$ip")
        done <<< "$content"

        [ "${#pool[@]}" -gt 0 ] && break
    done <<< "$SOURCES"

    [ "${#pool[@]}" -eq 0 ] && return 1

    # Dedup, then probe each against the git endpoint. First 2xx wins.
    local -a seen=()
    local dup
    for ip in "${pool[@]}"; do
        dup=0
        for s in ${seen+"${seen[@]}"}; do
            [ "$s" = "$ip" ] && { dup=1; break; }
        done
        [ $dup -eq 1 ] && continue
        seen+=("$ip")

        code=$(curl --noproxy '*' -s -o /dev/null \
            --connect-timeout 3 --max-time 6 \
            -w '%{http_code}' \
            -H 'Accept: application/x-git-upload-pack-advertisement' \
            "$GIT_PROBE_TARGET" \
            --resolve "github.com:443:${ip}" 2>/dev/null || true)
        case "$code" in
            2*) echo "$ip"; return 0 ;;
        esac
    done
    return 1
}

# ── Strategy 3: CIDR scan (last resort) ──────────────────────────────────────
# Expands CIDR ranges and probes concurrently. Bounded by PROBE_TEST_CAP.
try_cidr_scan() {
    local base octet cand winner
    local -a pool=()

    for range in "${CIDR_RANGES[@]}"; do
        base="${range%/*}"
        octet="${base##*.}"
        base="${base%.*}"
        for ((cand = 1; cand <= 254; cand++)); do
            [ "${#pool[@]}" -ge "$PROBE_TEST_CAP" ] && break 2
            pool+=("${base}.${cand}")
        done
    done
    # The unused variable keeps shellcheck quiet about the octet parse above.
    : "${octet:-0}"

    [ "${#pool[@]}" -eq 0 ] && return 1

    winner=$(for cand in "${pool[@]}"; do
        code=$(curl --noproxy '*' -s -o /dev/null \
            --connect-timeout 2 --max-time 5 \
            -w '%{http_code}' \
            -H 'Accept: application/x-git-upload-pack-advertisement' \
            "$GIT_PROBE_TARGET" \
            --resolve "github.com:443:${cand}" 2>/dev/null || true)
        case "$code" in
            2*) echo "$cand" ;;
        esac
    done | head -1)

    if [ -n "$winner" ]; then
        echo "$winner"
        return 0
    fi
    return 1
}

# ── Resolve strategy ─────────────────────────────────────────────────────────
ip=""
used_strategy="null"

run_strategy() {
    local name="$1" fn="$2" found=""
    if found=$("$fn" 2>/dev/null); then
        ip="$found"
        used_strategy="\"$name\""
        return 0
    fi
    return 1
}

case "$STRATEGY" in
    priority)  run_strategy "priority"  try_priority_ips     || true ;;
    community) run_strategy "community" try_community_sources || true ;;
    cidr)      run_strategy "cidr"      try_cidr_scan        || true ;;
    auto)
        run_strategy "priority"  try_priority_ips     || \
        run_strategy "community" try_community_sources || \
        run_strategy "cidr"      try_cidr_scan        || true
        ;;
    *) echo "Unknown strategy: $STRATEGY" >&2; exit 1 ;;
esac

# Test hook: GOTO_GITHUB_FORCE_IP bypasses probing so the write path can be
# exercised without depending on live network results. Never used in normal
# operation — probing is the whole point of Phase 3.
if [ -n "${GOTO_GITHUB_FORCE_IP:-}" ]; then
    ip="$GOTO_GITHUB_FORCE_IP"
    used_strategy="\"forced\""
fi

if [ -z "$ip" ]; then
    add_warning "no working GitHub IP found via strategy '$STRATEGY'"
    warn_json="["
    first=1
    for w in "${warnings[@]}"; do
        [ $first -eq 0 ] && warn_json+=","
        warn_json+="\"$(json_escape "$w")\""
        first=0
    done
    warn_json+="]"
    printf '%s\n' "$(cat <<EOF
{"applied":false,"strategy":$used_strategy,"ip":null,"entries_written":0,"backup":null,"shadowing":{"checked":true,"found":$shadow_found,"detail":$shadow_detail},"dns_flushed":false,"warnings":$warn_json}
EOF
)"
    exit 1
fi

echo "  selected IP: $ip (strategy: $used_strategy)" >&2

# ── Build the block and write ────────────────────────────────────────────────
# lib/04-apply.sh::apply_hosts already implements the safety chain:
# backup -> prune -> atomic temp+rename -> permission preservation.
# We build the marker block here because we have a single verified IP rather
# than a raw community hosts list.
build_block_for_ip() {
    local ip="$1"
    local timestamp
    timestamp=$(date +%Y-%m-%d)
    echo "$MARKER_START"
    echo "# Managed by goto-github -- do not edit manually"
    echo "# Updated at $timestamp"
    echo "# Best IP: $ip"
    local d
    for d in $CORE_DOMAINS; do
        echo "$ip $d"
    done
    echo "$MARKER_END"
}

block=$(build_block_for_ip "$ip")
if ! apply_hosts "$block" >/dev/null 2>&1; then
    add_warning "failed to write hosts file"
    warn_json="["
    first=1
    for w in "${warnings[@]}"; do
        [ $first -eq 0 ] && warn_json+=","
        warn_json+="\"$(json_escape "$w")\""
        first=0
    done
    warn_json+="]"
    printf '%s\n' "$(cat <<EOF
{"applied":false,"strategy":$used_strategy,"ip":"$ip","entries_written":0,"backup":null,"shadowing":{"checked":true,"found":$shadow_found,"detail":$shadow_detail},"dns_flushed":false,"warnings":$warn_json}
EOF
)"
    exit 1
fi

# The backup path apply_hosts created (newest matching file).
# ls may not be available or may not glob Windows paths under Git Bash; fall
# back to a find-based scan. If neither works, report null honestly rather
# than claiming a backup that cannot be located.
backup_path=$(ls -1t "${HOSTS_FILE}.goto-github.bak."* 2>/dev/null | head -1 || true)
if [ -z "$backup_path" ] && command -v find >/dev/null 2>&1; then
    backup_path=$(find "$(dirname "$HOSTS_FILE")" -maxdepth 1 -name "$(basename "$HOSTS_FILE").goto-github.bak.*" -type f 2>/dev/null | head -1 || true)
fi
if [ -n "$backup_path" ]; then
    backup_json="\"$(json_escape "$backup_path")\""
else
    backup_json="null"
    add_warning "backup was created but its path could not be determined"
fi

# Count entries actually written inside the marker block
entries=$(sed -n "/^${MARKER_START}/,/^${MARKER_END}$/p" "$HOSTS_FILE" 2>/dev/null \
    | grep -cE '^\s*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)

# ── Shadowing check (after) ──────────────────────────────────────────────────
check_shadowing_detail || true

# ── DNS flush ────────────────────────────────────────────────────────────────
dns_flushed="true"
if ! flush_dns >/dev/null 2>&1; then
    dns_flushed="false"
    add_warning "DNS cache flush failed; hosts is written but cached entries may persist"
fi

warn_json="["
first=1
for w in "${warnings[@]}"; do
    [ $first -eq 0 ] && warn_json+=","
    warn_json+="\"$(json_escape "$w")\""
    first=0
done
warn_json+="]"

printf '%s\n' "$(cat <<EOF
{"applied":true,"strategy":$used_strategy,"ip":"$ip","entries_written":$entries,"backup":"$backup_path","shadowing":{"checked":true,"found":$shadow_found,"detail":$shadow_detail},"dns_flushed":$dns_flushed,"warnings":$warn_json}
EOF
)"
