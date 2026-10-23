#!/usr/bin/env bash
# =============================================================================
# evals/run_e2e.sh — end-to-end acceptance for the skill's five phases
#
# Runs the whole flow the way a user would and asserts every step produces
# valid output. Unlike run_smoke.sh (which checks script contracts in
# isolation), this exercises the actual Phase 0 -> 1 -> 1b -> 3 -> 4 sequence.
#
# Covers both implementations on the current platform:
#   bash path  -> scripts/*.sh
#   PS path    -> scripts/*.ps1 via the platform's default PowerShell
#                 (powershell.exe on Windows, pwsh elsewhere — that is what a
#                 user actually has)
#
# No network dependency: Phase 1 tolerates all-zero rates, and Phase 3 uses
# GOTO_GITHUB_FORCE_IP against a temp hosts file.
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

BASH_BIN="${BASH_BIN:-C:/Program Files/Git/bin/bash.exe}"
case "$(uname -s)" in
    MINGW*|MSYS*) RUN_BASH=("$BASH_BIN"); PS_EXE="${PS_EXE:-powershell.exe}" ;;
    *)            RUN_BASH=(bash);        PS_EXE="${PS_EXE:-pwsh}" ;;
esac
HAVE_PS=0
command -v "${PS_EXE%% *}" >/dev/null 2>&1 && HAVE_PS=1

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }

valid_json() { case "$1" in \{*\}) return 0 ;; *) return 1 ;; esac; }

marker_count() { grep -c '^# >>> goto-github >>>' "$1" 2>/dev/null || echo 0; }

echo "========== bash path: Phase 0 -> 1 -> 1b -> 3 -> 4 =========="

out=$("${RUN_BASH[@]}" scripts/env_detection.sh 2>/dev/null)
valid_json "$out" && ok "Phase 0 env_detection: JSON" || bad "Phase 0 env_detection"
case "$out" in *'"shell":"bash"'*) ok "Phase 0 reports shell=bash" ;; *) bad "Phase 0 shell field" ;; esac

out=$("${RUN_BASH[@]}" scripts/connectivity_probe.sh --attempts 5 --timeout 5 2>/dev/null)
valid_json "$out" && ok "Phase 1 connectivity_probe: JSON" || bad "Phase 1 connectivity_probe"
n=$(printf '%s' "$out" | grep -o '"key":' | wc -l)
[ "$n" -ge 10 ] && ok "Phase 1 covers $n endpoints (>=10)" || bad "Phase 1 only $n endpoints"
case "$out" in *'"key":"git_write"'*) ok "Phase 1 includes git_write (push path)" ;; *) bad "git_write missing" ;; esac
case "$out" in *'"key":"ssh443"'*)   ok "Phase 1 includes ssh443" ;;              *) bad "ssh443 missing" ;; esac

out=$("${RUN_BASH[@]}" scripts/auth_probe.sh 2>/dev/null)
valid_json "$out" && ok "Phase 1b auth_probe: JSON" || bad "Phase 1b auth_probe"
case "$out" in *'"ssh":{"state":'*)   ok "Phase 1b reports ssh state" ;;   *) bad "ssh state missing" ;; esac
case "$out" in *'"https":{"state":'*) ok "Phase 1b reports https state" ;; *) bad "https state missing" ;; esac

TMPH=$(mktemp -t gg-e2e-XXXXXX)
printf '127.0.0.1 localhost\n# keep\n' > "$TMPH"
out=$(HOSTS_FILE="$TMPH" GOTO_GITHUB_TEST_PRIVILEGED=1 GOTO_GITHUB_FORCE_IP=140.82.114.21 \
      "${RUN_BASH[@]}" scripts/hosts_apply.sh --strategy priority 2>/dev/null)
valid_json "$out" && ok "Phase 3 hosts_apply: JSON" || bad "Phase 3 hosts_apply"
case "$out" in *'"applied":true'*) ok "Phase 3 applied=true" ;; *) bad "Phase 3 not applied" ;; esac
grep -q '^# keep' "$TMPH" && ok "Phase 3 preserved content outside marker" || bad "Phase 3 clobbered hosts"
[ "$(marker_count "$TMPH")" -eq 1 ] && ok "Phase 3 wrote exactly 1 marker block" || bad "Phase 3 wrote $(marker_count "$TMPH") blocks"

out=$(HOSTS_FILE="$TMPH" "${RUN_BASH[@]}" scripts/hosts_status.sh --attempts 3 --timeout 5 2>/dev/null)
valid_json "$out" && ok "Phase 4 hosts_status: JSON" || bad "Phase 4 hosts_status"
case "$out" in *'"installed":true'*) ok "Phase 4 sees installed=true" ;; *) bad "Phase 4 installed flag" ;; esac
case "$out" in *'"auth":{"ssh":'*)   ok "Phase 4 carries auth dimension" ;; *) bad "Phase 4 auth missing" ;; esac

rm -f "$TMPH" "$TMPH".goto-github.bak.* 2>/dev/null

echo ""
echo "========== PowerShell path: same five phases =========="
if [ "$HAVE_PS" -eq 0 ]; then
    echo "  SKIP: $PS_EXE not found"
else
    out=$("$PS_EXE" -NoProfile -File scripts/env_detection.ps1 2>/dev/null)
    valid_json "$out" && ok "PS Phase 0 env_detection: JSON" || bad "PS Phase 0"

    out=$("$PS_EXE" -NoProfile -File scripts/connectivity_probe.ps1 -Attempts 3 -Timeout 5 2>/dev/null)
    valid_json "$out" && ok "PS Phase 1 connectivity_probe: JSON" || bad "PS Phase 1"
    n=$(printf '%s' "$out" | grep -o '"key":' | wc -l)
    [ "$n" -ge 10 ] && ok "PS Phase 1 covers $n endpoints" || bad "PS Phase 1 only $n endpoints"

    out=$("$PS_EXE" -NoProfile -File scripts/auth_probe.ps1 2>/dev/null)
    valid_json "$out" && ok "PS Phase 1b auth_probe: JSON" || bad "PS Phase 1b"
    case "$out" in *'"ssh":{"state":'*) ok "PS Phase 1b reports ssh state" ;; *) bad "PS ssh state" ;; esac

    TMPW=$(mktemp -t gg-e2e-XXXXXX)
    printf '127.0.0.1 localhost\n# keep\n' > "$TMPW"
    out=$(HOSTS_FILE="$TMPW" GOTO_GITHUB_TEST_PRIVILEGED=1 GOTO_GITHUB_FORCE_IP=140.82.114.21 \
          "$PS_EXE" -NoProfile -File scripts/hosts_apply.ps1 -Strategy priority 2>/dev/null)
    case "$out" in *'"applied":true'*) ok "PS Phase 3 applied=true" ;; *) bad "PS Phase 3" ;; esac
    grep -q '^# keep' "$TMPW" && ok "PS Phase 3 preserved outside marker" || bad "PS Phase 3 clobbered hosts"

    out=$(HOSTS_FILE="$TMPW" "$PS_EXE" -NoProfile -File scripts/hosts_status.ps1 -Attempts 3 -Timeout 5 2>/dev/null)
    case "$out" in *'"installed":true'*) ok "PS Phase 4 sees installed=true" ;; *) bad "PS Phase 4" ;; esac
    case "$out" in *'"auth":{"ssh":'*) ok "PS Phase 4 carries auth dimension" ;; *) bad "PS auth missing" ;; esac

    rm -f "$TMPW" "$TMPW".goto-github.bak.* 2>/dev/null
fi

echo ""
echo "=========================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "=========================================="
[ "$FAIL" -eq 0 ]
