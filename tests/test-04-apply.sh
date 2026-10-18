#!/usr/bin/env bash
# tests/test-04-apply.sh
# Verifies lib/04-apply.sh: build_hosts_block, apply_hosts, remove_block,
# check_shadowing, json_status. Uses a temp HOSTS_FILE — never the real one.
# Exit 0 on full pass, 1 on any failure.

set -o nounset -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/tests/lib/test-helpers.sh"
setup_tmpdir

source "$REPO_ROOT/lib/00-constants.sh"
source "$REPO_ROOT/lib/01-utils.sh"
source "$REPO_ROOT/lib/03-validate.sh"
source "$REPO_ROOT/lib/04-apply.sh"

SAMPLE=$'140.82.112.3 github.com\n140.82.112.3 api.github.com\n185.199.108.153 raw.githubusercontent.com'

# Fresh temp hosts file with pre-existing (non-managed) content
new_hosts() {
    local f="$TEST_TMP_DIR/hosts.$RANDOM"
    printf '# Pre-existing hosts file\n127.0.0.1 localhost\n::1 localhost\n' > "$f"
    printf '%s' "$f"
}

count_marker() { grep -cF "$1" "$2"; }

# ── build_hosts_block ──────────────────────────────────────────────────

test_build_block() {
    local block
    block=$(build_hosts_block "$SAMPLE")
    assert_contains "$block" "$MARKER_START"
    assert_contains "$block" "$MARKER_END"
    assert_contains "$block" "140.82.112.3 github.com"
    assert_contains "$block" "Source: 521xueweihan/GitHub520"
}

# ── apply_hosts ────────────────────────────────────────────────────────

test_apply_adds_block() {
    HOSTS_FILE=$(new_hosts)
    local block
    block=$(build_hosts_block "$SAMPLE")
    apply_hosts "$block" >/dev/null 2>&1
    assert_file_contains "$HOSTS_FILE" "$MARKER_START"
    assert_file_contains "$HOSTS_FILE" "$MARKER_END"
    assert_file_contains "$HOSTS_FILE" "140.82.112.3 github.com"
    assert_file_contains "$HOSTS_FILE" "127.0.0.1 localhost"
}

test_apply_creates_backup() {
    HOSTS_FILE=$(new_hosts)
    local block
    block=$(build_hosts_block "$SAMPLE")
    apply_hosts "$block" >/dev/null 2>&1
    local n=0 bak
    for bak in "${HOSTS_FILE}.goto-github.bak."*; do
        [ -e "$bak" ] && n=$((n + 1))
    done
    [ "$n" -ge 1 ]
}

test_apply_idempotent() {
    HOSTS_FILE=$(new_hosts)
    local block
    block=$(build_hosts_block "$SAMPLE")
    apply_hosts "$block" >/dev/null 2>&1
    apply_hosts "$block" >/dev/null 2>&1
    apply_hosts "$block" >/dev/null 2>&1
    assert_equals "1" "$(count_marker "$MARKER_START" "$HOSTS_FILE")" "exactly one start marker"
    assert_equals "1" "$(count_marker "$MARKER_END" "$HOSTS_FILE")" "exactly one end marker"
}

test_apply_replaces_block() {
    HOSTS_FILE=$(new_hosts)
    apply_hosts "$(build_hosts_block "$SAMPLE")" >/dev/null 2>&1
    local other=$'185.199.108.153 github.com\n185.199.108.153 api.github.com'
    apply_hosts "$(build_hosts_block "$other")" >/dev/null 2>&1
    assert_file_contains "$HOSTS_FILE" "185.199.108.153 github.com"
    assert_file_not_contains "$HOSTS_FILE" "140.82.112.3 github.com" "old block must be replaced"
}

# ── remove_block ───────────────────────────────────────────────────────

test_remove_block() {
    HOSTS_FILE=$(new_hosts)
    apply_hosts "$(build_hosts_block "$SAMPLE")" >/dev/null 2>&1
    remove_block
    assert_file_not_contains "$HOSTS_FILE" "$MARKER_START"
    assert_file_not_contains "$HOSTS_FILE" "140.82.112.3"
    assert_file_contains "$HOSTS_FILE" "127.0.0.1 localhost" "pre-existing content preserved"
}

test_remove_block_idempotent() {
    HOSTS_FILE=$(new_hosts)
    remove_block
    remove_block
    return 0
}

# ── check_shadowing ────────────────────────────────────────────────────

test_shadowing_detected() {
    HOSTS_FILE=$(new_hosts)
    printf '140.82.113.20        github.com\n%s\n20.205.243.166 github.com\n%s\n' \
        "$MARKER_START" "$MARKER_END" > "$HOSTS_FILE"
    check_shadowing
}

test_shadowing_own_block_only() {
    HOSTS_FILE=$(new_hosts)
    printf '%s\n20.205.243.166 github.com\n%s\n' "$MARKER_START" "$MARKER_END" > "$HOSTS_FILE"
    if check_shadowing; then
        echo "    our own block must not count as shadowing" >&2
        return 1
    fi
    return 0
}

test_shadowing_marker_on_line_one() {
    HOSTS_FILE=$(new_hosts)
    printf '%s\n1.2.3.4 github.com\n%s\n' "$MARKER_START" "$MARKER_END" > "$HOSTS_FILE"
    if check_shadowing; then
        echo "    marker on line 1 → nothing can shadow" >&2
        return 1
    fi
    return 0
}

test_shadowing_word_boundary() {
    HOSTS_FILE=$(new_hosts)
    printf '1.2.3.4 github.commm\n%s\n2.3.4.5 github.com\n%s\n' "$MARKER_START" "$MARKER_END" > "$HOSTS_FILE"
    if check_shadowing; then
        echo "    github.commm must not match github.com" >&2
        return 1
    fi
    return 0
}

# ── json_status ────────────────────────────────────────────────────────

test_json_status_installed() {
    HOSTS_FILE=$(new_hosts)
    apply_hosts "$(build_hosts_block "$SAMPLE")" >/dev/null 2>&1
    # Mock curl so the reachability probe returns 200
    curl() { printf '200'; }
    local out
    out=$(json_status)
    unset -f curl
    assert_contains "$out" '"installed": true'
    assert_contains "$out" '"has_github": true'
    assert_contains "$out" '"reachable": true'
}

test_json_status_not_installed() {
    HOSTS_FILE=$(new_hosts)
    curl() { printf '000'; }
    local out
    out=$(json_status)
    unset -f curl
    assert_contains "$out" '"installed": false'
    assert_contains "$out" '"reachable": false'
}

# ── Run all tests ──────────────────────────────────────────────────────

test_header
run_test "build_hosts_block wraps content in markers"  test_build_block
run_test "apply_hosts adds the marker block"           test_apply_adds_block
run_test "apply_hosts creates a backup"                test_apply_creates_backup
run_test "apply_hosts is idempotent"                   test_apply_idempotent
run_test "apply_hosts replaces an existing block"      test_apply_replaces_block
run_test "remove_block removes the block"              test_remove_block
run_test "remove_block is idempotent"                  test_remove_block_idempotent
run_test "check_shadowing detects a shadow"            test_shadowing_detected
run_test "check_shadowing ignores our own block"       test_shadowing_own_block_only
run_test "check_shadowing with marker on line 1"       test_shadowing_marker_on_line_one
run_test "check_shadowing respects word boundary"      test_shadowing_word_boundary
run_test "json_status reports installed"               test_json_status_installed
run_test "json_status reports not installed"           test_json_status_not_installed
test_report
exit $?
