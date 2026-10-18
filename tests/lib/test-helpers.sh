#!/usr/bin/env bash
# tests/lib/test-helpers.sh
# Vendored zero-dependency test framework for goto-github.
# Source this in your test-*.sh file, then call run_test and assert_*.
#
# Usage:
#   #!/usr/bin/env bash
#   set -o nounset -o pipefail
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/test-helpers.sh"
#
#   test_constants_have_values() {
#     assert_not_empty "$MARKER_START" "MARKER_START should be defined"
#   }
#
#   test_header
#   run_test "constants have values" test_constants_have_values
#   test_report
#   exit $?

# Reset errexit to allow per-test failure capture
set +o errexit

# Per-file state
TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0
CURRENT_TEST=""
TEST_TMP_DIR=""

# Color codes (no-op if not a tty)
if [ -t 1 ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; DIM='\033[2m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; DIM=''; NC=''
fi

# Print a header banner for the current test file
test_header() {
    local name
    name=$(basename "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}")
    echo ""
    echo -e "${DIM}── $name ──${NC}"
}

# ── Assertions (each returns 0 on pass, 1 on fail) ──────────────────────

assert_equals() {
    local expected="$1" actual="$2" message="${3:-}"
    if [ "$expected" = "$actual" ]; then return 0; fi
    echo -e "  ${RED}FAIL${NC}: $CURRENT_TEST" >&2
    echo -e "    Expected: ${YELLOW}'$expected'${NC}" >&2
    echo -e "    Actual:   ${YELLOW}'$actual'${NC}" >&2
    [ -n "$message" ] && echo -e "    Message:  $message" >&2
    return 1
}

assert_not_equals() {
    local unexpected="$1" actual="$2" message="${3:-}"
    if [ "$unexpected" != "$actual" ]; then return 0; fi
    echo -e "  ${RED}FAIL${NC}: $CURRENT_TEST" >&2
    echo -e "    Expected NOT: ${YELLOW}'$unexpected'${NC}" >&2
    echo -e "    Actual:        ${YELLOW}'$actual'${NC}" >&2
    [ -n "$message" ] && echo -e "    Message:  $message" >&2
    return 1
}

assert_not_empty() {
    local actual="$1" message="${2:-}"
    if [ -n "$actual" ]; then return 0; fi
    echo -e "  ${RED}FAIL${NC}: $CURRENT_TEST" >&2
    echo -e "    Expected: non-empty value" >&2
    echo -e "    Actual:   empty" >&2
    [ -n "$message" ] && echo -e "    Message:  $message" >&2
    return 1
}

assert_contains() {
    local haystack="$1" needle="$2" message="${3:-}"
    if [[ "$haystack" == *"$needle"* ]]; then return 0; fi
    echo -e "  ${RED}FAIL${NC}: $CURRENT_TEST" >&2
    echo -e "    Haystack: ${YELLOW}'$haystack'${NC}" >&2
    echo -e "    Needle:   ${YELLOW}'$needle'${NC}" >&2
    [ -n "$message" ] && echo -e "    Message:  $message" >&2
    return 1
}

assert_matches_regex() {
    local string="$1" pattern="$2" message="${3:-}"
    if [[ "$string" =~ $pattern ]]; then return 0; fi
    echo -e "  ${RED}FAIL${NC}: $CURRENT_TEST" >&2
    echo -e "    String:   ${YELLOW}'$string'${NC}" >&2
    echo -e "    Pattern:  ${YELLOW}'$pattern'${NC}" >&2
    [ -n "$message" ] && echo -e "    Message:  $message" >&2
    return 1
}

assert_file_exists() {
    local path="$1" message="${2:-}"
    if [ -f "$path" ]; then return 0; fi
    echo -e "  ${RED}FAIL${NC}: $CURRENT_TEST" >&2
    echo -e "    Expected file: ${YELLOW}'$path'${NC}" >&2
    [ -n "$message" ] && echo -e "    Message:  $message" >&2
    return 1
}

assert_file_contains() {
    local path="$1" needle="$2" message="${3:-}"
    if [ ! -f "$path" ]; then
        echo -e "  ${RED}FAIL${NC}: $CURRENT_TEST (file missing)" >&2
        echo -e "    Path: ${YELLOW}'$path'${NC}" >&2
        [ -n "$message" ] && echo -e "    Message:  $message" >&2
        return 1
    fi
    if grep -qF -- "$needle" "$path"; then return 0; fi
    echo -e "  ${RED}FAIL${NC}: $CURRENT_TEST" >&2
    echo -e "    Path:   ${YELLOW}'$path'${NC}" >&2
    echo -e "    Needle: ${YELLOW}'$needle'${NC}" >&2
    [ -n "$message" ] && echo -e "    Message:  $message" >&2
    return 1
}

assert_not_contains() {
    local haystack="$1" needle="$2" message="${3:-}"
    if [[ "$haystack" != *"$needle"* ]]; then return 0; fi
    echo -e "  ${RED}FAIL${NC}: $CURRENT_TEST" >&2
    echo -e "    Haystack: ${YELLOW}'$haystack'${NC}" >&2
    echo -e "    Should NOT contain: ${YELLOW}'$needle'${NC}" >&2
    [ -n "$message" ] && echo -e "    Message:  $message" >&2
    return 1
}

assert_file_not_contains() {
    local path="$1" needle="$2" message="${3:-}"
    if [ ! -f "$path" ]; then return 0; fi
    if ! grep -qF -- "$needle" "$path"; then return 0; fi
    echo -e "  ${RED}FAIL${NC}: $CURRENT_TEST" >&2
    echo -e "    Path:   ${YELLOW}'$path'${NC}" >&2
    echo -e "    Should NOT contain: ${YELLOW}'$needle'${NC}" >&2
    [ -n "$message" ] && echo -e "    Message:  $message" >&2
    return 1
}

# ── Test runner ─────────────────────────────────────────────────────────

# Run a test function. Captures return code, tracks pass/fail.
# Usage: run_test "test name" test_function_name
run_test() {
    local name="$1" test_fn="$2"
    CURRENT_TEST="$name"
    TEST_COUNT=$((TEST_COUNT + 1))
    if "$test_fn"; then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo -e "  ${GREEN}PASS${NC}: $name"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# Final report. Returns nonzero if any test failed.
test_report() {
    echo ""
    if [ "$FAIL_COUNT" -gt 0 ]; then
        echo -e "${RED}FAIL: $FAIL_COUNT failed, $PASS_COUNT passed, $TEST_COUNT total${NC}"
        return 1
    else
        echo -e "${GREEN}OK: $PASS_COUNT passed, $TEST_COUNT total${NC}"
        return 0
    fi
}

# Per-test-file temp directory, auto-cleaned on exit
setup_tmpdir() {
    TEST_TMP_DIR=$(mktemp -d -t goto-github-test.XXXXXX)
    trap 'rm -rf "$TEST_TMP_DIR"' EXIT
}
