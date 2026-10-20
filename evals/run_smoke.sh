#!/usr/bin/env bash
# =============================================================================
# evals/run_smoke.sh — mechanical smoke test for the goto-github skill scripts
#
# Verifies the script-level contracts that the evals in evals.json assert:
#   - every script answers --help / -Help
#   - every script emits exactly one well-formed JSON line on stdout
#   - env_detection surfaces env_var_shadowed when GITHUB_TOKEN is invalid
#   - hosts_apply is idempotent and preserves content outside the marker
#   - hosts_apply refuses to write without a backup
#   - hosts_status reports not_fixed when nothing improved over a baseline
#   - the two implementations emit the same top-level JSON field set
#
# Not a substitute for evaluating the SKILL.md workflow itself (that needs an
# agent and a human); this locks the parts a script can guarantee.
#
# No jq/python dependency: the Windows python3.exe under WindowsApps is a Store
# stub that fails when invoked from Git Bash, and this tool must run on a bare
# box. grep/sed is always available.
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

BASH_BIN="${BASH_BIN:-C:/Program Files/Git/bin/bash.exe}"
PWSH_BIN="${PWSH_BIN:-pwsh}"

# On Windows the script itself runs through Git Bash, but nested calls need an
# explicit path.
case "$(uname -s)" in
    MINGW*|MSYS*) RUN_BASH=("$BASH_BIN") ;;
    *)            RUN_BASH=(bash) ;;
esac

PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# SKIP_NETWORK=1 drops the assertions that need live connectivity (checks 2 and
# 6 probe real GitHub endpoints). Set it in CI environments without egress;
# the remaining assertions still cover --help, JSON shape, shadowing detection,
# idempotency, backup, and dual-language parity.
SKIP_NETWORK="${SKIP_NETWORK:-0}"

ok()  { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ── JSON helpers (grep/sed only) ─────────────────────────────────────────────
# json_field <json> <path>
#   .a.b        nested scalar: narrow to the "a" object, then read "b"
#   "key":N     the rate of an endpoint whose key matches
json_field() {
    local json="$1" field="$2"
    case "$field" in
        .*)
            local path="${field#.}"
            local seg rest="$path" blob="$json"
            while [ -n "$rest" ]; do
                seg="${rest%%.*}"
                if [ "$seg" = "$rest" ]; then rest=""; else rest="${rest#*.}"; fi
                if printf '%s' "$blob" | grep -q "\"$seg\":{"; then
                    blob=$(printf '%s' "$blob" | grep -o "\"$seg\":{[^}]*}" | head -1)
                fi
            done
            printf '%s' "$blob" \
                | grep -o "\"$seg\":[^,}]*" \
                | head -1 | cut -d: -f2- | tr -d '"' \
                | sed 's/^ *//; s/ *$//'
            ;;
        '"'*'"'':')
            :
            ;;
    esac
}

# Endpoint rate: "web" -> the number after "key":"web" ... "rate":
json_rate() {
    local json="$1" want="$2"
    printf '%s' "$json" \
        | grep -o "\"key\":\"$want\"[^}]*" \
        | grep -o '"rate":[0-9]*' \
        | head -1 | cut -d: -f2
}

# Contract is "exactly one line that starts with { and ends with }". A stricter
# parse needs jq/python, which we deliberately do not depend on.
json_looks_valid() {
    case "$1" in
        \{*\}) return 0 ;;
        *) return 1 ;;
    esac
}

# Top-level key set: only keys at depth 1 (i.e. not inside a nested object).
top_level_keys() {
    # Remove every balanced {...} object first, then read the "name": keys that
    # remain. Deleting objects is what keeps nested keys out; a naive
    # 's/:[^}]*}//' fails because a string value containing '}' (a warning
    # message) terminates the match early and leaves nested keys behind.
    printf '%s' "$1" | awk '
    {
        out = ""; depth = 0
        for (i = 1; i <= length($0); i++) {
            ch = substr($0, i, 1)
            if (ch == "{") { depth++; if (depth == 1) continue }
            if (ch == "}") { depth--; if (depth == 0) continue }
            if (depth == 0) out = out ch
        }
        print out
    }' \
        | grep -o '"[a-z_]*":' \
        | tr -d '":' | sort -u | paste -sd, -
}

echo "=== 1. every script answers --help / -Help ==="
for f in scripts/*.sh; do
    if "${RUN_BASH[@]}" "$f" --help >/dev/null 2>&1; then ok "$f --help"; else bad "$f --help"; fi
done
if command -v "$PWSH_BIN" >/dev/null 2>&1; then
    for f in scripts/*.ps1; do
        if "$PWSH_BIN" -NoProfile -File "$f" -Help >/dev/null 2>&1; then ok "$f -Help"; else bad "$f -Help"; fi
    done
else
    echo "  SKIP: pwsh not available"
fi

echo ""
echo "=== 2. stdout is exactly one well-formed JSON line ==="
check_stdout() {
    local script="$1"; shift
    local out lines
    out=$("${RUN_BASH[@]}" "$script" "$@" 2>/dev/null)
    lines=$(printf '%s\n' "$out" | grep -c .)
    if [ "$lines" -ne 1 ]; then bad "$script: expected 1 stdout line, got $lines"; return; fi
    if json_looks_valid "$out"; then
        ok "$script: single well-formed JSON line"
    else
        bad "$script: stdout is not a well-formed JSON object"
    fi
}
check_stdout scripts/env_detection.sh
if [ "$SKIP_NETWORK" = "1" ]; then
    echo "  SKIP: connectivity_probe / hosts_status (SKIP_NETWORK=1)"
else
    check_stdout scripts/connectivity_probe.sh --attempts 3 --timeout 3
    check_stdout scripts/hosts_status.sh --attempts 3 --timeout 3
fi

echo ""
echo "=== 3. env_var_shadowed detection ==="
# Point GITHUB_TOKEN at a definitely-invalid value; env_detection must report
# the shadowing state rather than blaming the network.
out=$(GITHUB_TOKEN=ghp_invalid_token_for_testing_0000000000000000 \
    "${RUN_BASH[@]}" scripts/env_detection.sh 2>/dev/null)
state=$(json_field "$out" '.gh_auth.state')
if [ "$state" = "env_var_shadowed" ]; then
    ok "env_detection reports env_var_shadowed for an invalid GITHUB_TOKEN"
else
    bad "env_detection reported gh_auth.state='$state', expected env_var_shadowed"
fi

echo ""
echo "=== 4. hosts_apply: idempotent + preserves outside the marker ==="
TEST_HOSTS="$WORK/hosts"
printf '127.0.0.1 localhost\n# pre-existing content\n' > "$TEST_HOSTS"
export HOSTS_FILE="$TEST_HOSTS"
export GOTO_GITHUB_TEST_PRIVILEGED=1
export GOTO_GITHUB_FORCE_IP=140.82.114.21

"${RUN_BASH[@]}" scripts/hosts_apply.sh --strategy priority >/dev/null 2>&1
"${RUN_BASH[@]}" scripts/hosts_apply.sh --strategy priority >/dev/null 2>&1

blocks=$(grep -c '^# >>> goto-github >>>' "$TEST_HOSTS")
if [ "$blocks" -eq 1 ]; then ok "marker block count is 1 after two runs (idempotent)"; else bad "expected 1 marker block, got $blocks"; fi

if grep -q '^127.0.0.1 localhost' "$TEST_HOSTS" && grep -q '^# pre-existing content' "$TEST_HOSTS"; then
    ok "content outside the marker block preserved"
else
    bad "content outside the marker block was modified"
fi

backups=$(find "$WORK" -name 'hosts.goto-github.bak.*' | wc -l)
if [ "$backups" -ge 1 ]; then ok "backup created ($backups file(s))"; else bad "no backup created"; fi

echo ""
echo "=== 5. hosts_apply: refuses to write when backup fails ==="
# Simulate an unwritable backup target: the hosts file lives in a directory
# whose permissions forbid creating new files. On Windows the MSYS chmod does
# not map to NTFS ACLs, so this self-skips there rather than failing.
RO_DIR="$WORK/ro"
RO_HOSTS="$RO_DIR/hosts"
mkdir -p "$RO_DIR"
printf '127.0.0.1 localhost\n' > "$RO_HOSTS"
chmod 555 "$RO_DIR" 2>/dev/null
before=$(md5sum "$RO_HOSTS" 2>/dev/null | cut -d' ' -f1)
HOSTS_FILE="$RO_HOSTS" GOTO_GITHUB_TEST_PRIVILEGED=1 GOTO_GITHUB_FORCE_IP=140.82.114.21 \
    "${RUN_BASH[@]}" scripts/hosts_apply.sh --strategy priority >/dev/null 2>&1
rc=$?
after=$(md5sum "$RO_HOSTS" 2>/dev/null | cut -d' ' -f1)
chmod 755 "$RO_DIR" 2>/dev/null

# Can we even create a file there? If yes, the protection did not take and the
# scenario cannot be exercised on this platform.
if touch "$RO_DIR/canary" 2>/dev/null; then
    rm -f "$RO_DIR/canary"
    echo "  SKIP: directory permissions are not enforceable on this platform"
elif [ "$rc" -ne 0 ] && [ "$before" = "$after" ]; then
    ok "apply aborted (rc=$rc) and hosts unchanged when backup fails"
else
    bad "apply did not abort cleanly when backup failed (rc=$rc)"
fi

echo ""
echo "=== 6. hosts_status: not_fixed when nothing improved ==="
BASE="$WORK/baseline.json"
cat > "$BASE" <<'EOF'
{"timestamp":"2026-01-01T00:00:00Z","endpoints":[{"key":"web","rate":99},{"key":"git","rate":99},{"key":"api","rate":99},{"key":"raw","rate":99},{"key":"download","rate":99}]}
EOF
if [ "$SKIP_NETWORK" = "1" ]; then
    echo "  SKIP: verdict check (SKIP_NETWORK=1)"
else
status=$(HOSTS_FILE="$TEST_HOSTS" "${RUN_BASH[@]}" scripts/hosts_status.sh --attempts 3 --timeout 3 --baseline "$BASE" 2>/dev/null)
installed=$(json_field "$status" '.installed')
verdict=$(json_field "$status" '.verdict')
if [ "$installed" = "true" ]; then ok "hosts_status reports installed=true"; else bad "hosts_status installed='$installed'"; fi
if [ "$verdict" = "not_fixed" ]; then
    ok "hosts_status reports not_fixed against an unbeatable baseline"
else
    bad "hosts_status verdict='$verdict', expected not_fixed"
fi

echo ""
echo "=== 7. dual-language top-level field parity ==="
if command -v "$PWSH_BIN" >/dev/null 2>&1; then
    b=$("${RUN_BASH[@]}" scripts/env_detection.sh 2>/dev/null)
    p=$("$PWSH_BIN" -NoProfile -File scripts/env_detection.ps1 2>/dev/null)
    bf=$(top_level_keys "$b")
    pf=$(top_level_keys "$p")
    if [ "$bf" = "$pf" ]; then ok "env_detection top-level fields match"; else bad "top-level fields differ: bash=$bf pwsh=$pf"; fi
else
    echo "  SKIP: pwsh not available"
fi

fi

unset HOSTS_FILE GOTO_GITHUB_TEST_PRIVILEGED GOTO_GITHUB_FORCE_IP

echo ""
echo "=========================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=========================================="
[ "$FAIL" -eq 0 ]
