#!/usr/bin/env bash
# tests/test-03-validate.sh
# Verifies lib/03-validate.sh: validate_hosts_content, extract_hosts_lines,
# verify_hosts. Uses a temp HOSTS_FILE. Exit 0 on full pass, 1 on any failure.

set -o nounset -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/tests/lib/test-helpers.sh"
setup_tmpdir

source "$REPO_ROOT/lib/00-constants.sh"
source "$REPO_ROOT/lib/01-utils.sh"
source "$REPO_ROOT/lib/03-validate.sh"

# Sample content with 12 IP lines including github.com
SAMPLE=$'# comment line\n140.82.112.3 github.com\n140.82.112.3 api.github.com\n140.82.112.3 codeload.github.com\n185.199.108.153 raw.githubusercontent.com\n185.199.108.153 avatars.githubusercontent.com\n185.199.108.153 objects.githubusercontent.com\n185.199.108.153 media.githubusercontent.com\n185.199.108.153 github.githubassets.com\n185.199.108.153 camo.githubusercontent.com\n185.199.108.153 github.io\n185.199.108.153 user-images.githubusercontent.com\n185.199.108.153 cloud.githubusercontent.com'

# ── Test functions ─────────────────────────────────────────────────────

test_validate_accepts_good_content() {
    validate_hosts_content "$SAMPLE"
}

test_validate_rejects_too_few_ips() {
    local small=$'140.82.112.3 github.com\n140.82.112.3 api.github.com'
    if validate_hosts_content "$small" >/dev/null 2>&1; then
        echo "    <10 IP lines must be rejected" >&2
        return 1
    fi
    return 0
}

test_validate_rejects_missing_github() {
    # 12 IP lines but none for github.com
    local content="" i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        content="${content}185.199.108.${i} example${i}.com"$'\n'
    done
    if validate_hosts_content "$content" >/dev/null 2>&1; then
        echo "    content without github.com must be rejected" >&2
        return 1
    fi
    return 0
}

test_extract_hosts_lines() {
    local raw=$'# a comment\n140.82.112.3 github.com   # trailing comment\n\nnot-an-ip line\n185.199.108.153 raw.githubusercontent.com'
    local out
    out=$(extract_hosts_lines "$raw")
    assert_equals "140.82.112.3 github.com
185.199.108.153 raw.githubusercontent.com" "$out"
}

test_verify_hosts_ok() {
    local f="$TEST_TMP_DIR/hosts_ok"
    printf '%s\n' "$MARKER_START" > "$f"
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        printf '140.82.112.3 host%d.example.com\n' "$i" >> "$f"
    done
    printf '140.82.112.3 github.com\n' >> "$f"
    printf '%s\n' "$MARKER_END" >> "$f"
    HOSTS_FILE="$f"
    verify_hosts
}

test_verify_hosts_missing_block() {
    local f="$TEST_TMP_DIR/hosts_missing"
    printf '127.0.0.1 localhost\n' > "$f"
    HOSTS_FILE="$f"
    if verify_hosts >/dev/null 2>&1; then
        echo "    no marker block must fail verification" >&2
        return 1
    fi
    return 0
}

test_verify_hosts_too_few_entries() {
    local f="$TEST_TMP_DIR/hosts_few"
    printf '%s\n140.82.112.3 github.com\n%s\n' "$MARKER_START" "$MARKER_END" > "$f"
    HOSTS_FILE="$f"
    if verify_hosts >/dev/null 2>&1; then
        echo "    <10 entries must fail verification" >&2
        return 1
    fi
    return 0
}

# ── Run all tests ──────────────────────────────────────────────────────

test_header
run_test "validate_hosts_content accepts good content"  test_validate_accepts_good_content
run_test "validate_hosts_content rejects too few IPs"   test_validate_rejects_too_few_ips
run_test "validate_hosts_content rejects missing github.com" test_validate_rejects_missing_github
run_test "extract_hosts_lines strips comments/blanks"   test_extract_hosts_lines
run_test "verify_hosts passes on a good block"          test_verify_hosts_ok
run_test "verify_hosts fails without a block"           test_verify_hosts_missing_block
run_test "verify_hosts fails with too few entries"      test_verify_hosts_too_few_entries
test_report
exit $?
