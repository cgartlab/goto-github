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

# The skill layer's own constants — deliberately NOT lib/00-constants.sh, which
# belongs to the pull-based CLI implementation.
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/constants.sh"

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

# ── Backup + write (local implementations; the CLI's lib/ is not sourced) ────
# Backup before every write; prune to KEEP_BACKUPS newest.
backup_hosts() {
    local backup
    backup="${HOSTS_FILE}.goto-github.bak.$(date +%Y%m%d%H%M%S)"
    # cp -p may fail on filesystems that cannot preserve metadata (macOS APFS
    # with restricted dirs, Git Bash on NTFS). Fall back to plain cp; only if
    # BOTH fail is the backup considered failed.
    if ! cp -p "$HOSTS_FILE" "$backup" 2>/dev/null; then
        if ! cp "$HOSTS_FILE" "$backup" 2>/dev/null; then
            add_warning "backup failed (cannot write ${backup}); aborting without touching hosts"
            return 1
        fi
    fi
    # Prune older backups. The pipeline's exit status is deliberately ignored:
    # with `set -o pipefail`, `ls` returns non-zero when the glob matches
    # nothing, and that status would leak into this function's return value
    # (the caller reads stdout, so a non-zero exit would drop the backup path).
    {
        # shellcheck disable=SC2012
        ls -1t "${HOSTS_FILE}.goto-github.bak."* 2>/dev/null \
            | tail -n +"$((KEEP_BACKUPS + 1))" \
            | while IFS= read -r old; do rm -f "$old"; done
    } 2>/dev/null || true
    printf '%s\n' "$backup"
    return 0
}

# ── Platform predicates ──────────────────────────────────────────────────────
# Defined before first use: write_hosts_block() below calls is_macos().
is_macos() { [ "$(uname)" = "Darwin" ]; }
is_linux() { [ "$(uname)" = "Linux" ]; }

# Strip any existing block, append the new one. Atomic via temp + mv.
# Preserves permissions (macOS stat -f %Lp, GNU stat -c %a).
write_hosts_block() {
    local ip="$1"
    local tmp_file perms

    # BSD mktemp (macOS) rejects a template whose Xs are not the final
    # characters, and behaves differently with paths containing dots. Build the
    # template so it is always "<dir>/<name>.XXXXXXXX" with the Xs last, and
    # fall back to a plain mktemp if that still fails.
    local hosts_dir hosts_base
    hosts_dir=$(dirname "$HOSTS_FILE")
    hosts_base=$(basename "$HOSTS_FILE")
    tmp_file=$(mktemp "${hosts_dir}/${hosts_base}.XXXXXXXX" 2>/dev/null) \
        || tmp_file=$(mktemp "${hosts_dir}/.goto-github.XXXXXXXX" 2>/dev/null) \
        || tmp_file=$(mktemp 2>/dev/null)

    if [ -z "$tmp_file" ]; then
        add_warning "failed to create temp file; hosts unchanged"
        return 1
    fi

    # Remove any previous block (idempotency), keep every other line
    sed "/^${MARKER_START}/,/^${MARKER_END}$/d" "$HOSTS_FILE" > "$tmp_file"

    {
        printf '\n%s\n' "$MARKER_START"
        printf '%s\n' "# Managed by goto-github -- do not edit manually"
        printf '%s\n' "# Updated at $(date '+%Y-%m-%d %H:%M:%S')"
        printf '%s\n' "# Best IP: $ip"
        local d
        for d in $CORE_DOMAINS; do
            printf '%s %s\n' "$ip" "$d"
        done
        printf '%s\n' "$MARKER_END"
    } >> "$tmp_file"

    if is_macos; then
        perms=$(stat -f %Lp "$HOSTS_FILE" 2>/dev/null || true)
    else
        perms=$(stat -c %a "$HOSTS_FILE" 2>/dev/null || true)
    fi
    if [ -n "$perms" ]; then
        chmod "$perms" "$tmp_file" 2>/dev/null || chmod 644 "$tmp_file" 2>/dev/null || true
    else
        chmod 644 "$tmp_file" 2>/dev/null || true
    fi
    chown 0:0 "$tmp_file" 2>/dev/null || true

    if ! mv -f "$tmp_file" "$HOSTS_FILE"; then
        rm -f "$tmp_file"
        add_warning "failed to replace $HOSTS_FILE; hosts unchanged (backup kept)"
        return 1
    fi
    return 0
}

flush_dns_cache() {
    if is_macos; then
        killall -HUP mDNSResponder 2>/dev/null || true
        dscacheutil -flushcache 2>/dev/null || true
    elif [ "$(uname)" = "Linux" ]; then
        resolvectl flush-caches 2>/dev/null || true
        systemctl restart systemd-resolved 2>/dev/null || true
    elif [[ "$(uname)" == MINGW* || "$(uname)" == MSYS* ]]; then
        ipconfig //flushdns 2>/dev/null || true
    fi
    return 0
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
backup_result=$(backup_hosts) || {
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
}

if ! write_hosts_block "$ip"; then
    warn_json="["
    first=1
    for w in "${warnings[@]}"; do
        [ $first -eq 0 ] && warn_json+=","
        warn_json+="\"$(json_escape "$w")\""
        first=0
    done
    warn_json+="]"
    printf '%s\n' "$(cat <<EOF
{"applied":false,"strategy":$used_strategy,"ip":"$ip","entries_written":0,"backup":"$(json_escape "$backup_result")","shadowing":{"checked":true,"found":$shadow_found,"detail":$shadow_detail},"dns_flushed":false,"warnings":$warn_json}
EOF
)"
    exit 1
fi

backup_path="$backup_result"
# Escape for JSON: Windows paths carry backslashes, which are escape
# characters in JSON strings. Unescaped they make the whole line unparseable
# (ConvertFrom-Json: "Unrecognized escape sequence").
backup_path_json="$(json_escape "$backup_path")"

# Count entries actually written inside the marker block
entries=$(sed -n "/^${MARKER_START}/,/^${MARKER_END}$/p" "$HOSTS_FILE" 2>/dev/null \
    | grep -cE '^\s*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)

# ── Shadowing check (after) ──────────────────────────────────────────────────
check_shadowing_detail || true

# ── DNS flush ────────────────────────────────────────────────────────────────
dns_flushed="true"
if ! flush_dns_cache >/dev/null 2>&1; then
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
{"applied":true,"strategy":$used_strategy,"ip":"$ip","entries_written":$entries,"backup":"$backup_path_json","shadowing":{"checked":true,"found":$shadow_found,"detail":$shadow_detail},"dns_flushed":$dns_flushed,"warnings":$warn_json}
EOF
)"
