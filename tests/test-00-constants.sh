#!/usr/bin/env bash
# tests/test-00-constants.sh
# Verifies the data constants in lib/00-constants.sh are well-formed.
# Exit 0 on full pass, 1 on any failure.

set -o nounset -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/tests/lib/test-helpers.sh"
setup_tmpdir

# Source the module under test
source "$REPO_ROOT/lib/00-constants.sh"

# ── Test functions ─────────────────────────────────────────────────────

# Marker lines match the format every other tool/section expects
test_markers_defined() {
    assert_equals "# >>> goto-github >>>" "$MARKER_START"
    assert_equals "# <<< goto-github <<<" "$MARKER_END"
}

# Hosts file default
test_hosts_file_default() {
    assert_equals "/etc/hosts" "$HOSTS_FILE"
}

# The three mirror sources are https URLs, primary = jsDelivr, fallback = hellogithub
test_sources() {
    local count
    count=$(printf '%s\n' "$SOURCES" | grep -c '^https://')
    assert_equals "3" "$count" "expected 3 https sources"
    assert_contains "$SOURCES" "cdn.jsdelivr.net" "primary source is jsDelivr"
    assert_contains "$SOURCES" "raw.hellogithub.com" "fallback source is hellogithub"
    assert_contains "$SOURCES" "raw.githubusercontent.com" "tertiary source is GitHub raw"
}

# curl retry policy is configured (retries transient failures)
test_curl_retry_opts() {
    assert_equals "--retry 3 --retry-all-errors --retry-delay 2 --retry-max-time 60" "${CURL_RETRY_OPTS[*]}"
}

# Core domains include the canonical github.com and the API/codeload hosts
test_core_domains() {
    assert_contains " $CORE_DOMAINS " " github.com "
    assert_contains " $CORE_DOMAINS " " api.github.com "
    assert_contains " $CORE_DOMAINS " " codeload.github.com "
}

# Probe tuning is sane and targets a git smart-http endpoint (not the homepage)
test_probe_constants() {
    assert_matches_regex "$PROBE_RADIUS" '^[1-9][0-9]*$'
    assert_matches_regex "$PROBE_POOL_CAP" '^[1-9][0-9]*$'
    assert_matches_regex "$PROBE_TEST_CAP" '^[1-9][0-9]*$'
    assert_matches_regex "$PROBE_TIMEOUT" '^[1-9][0-9]*$'
    assert_contains "$PROBE_TARGET" "git-upload-pack" "probe target must be git smart-http"
    # Test cap must not exceed pool cap, or the cap is meaningless
    [ "$PROBE_TEST_CAP" -le "$PROBE_POOL_CAP" ] || return 1
}

# Backup rotation keeps a positive number of backups
test_keep_backups() {
    assert_matches_regex "$KEEP_BACKUPS" '^[1-9][0-9]*$'
}

# Colors are defined (may be empty when not a tty, but must be set)
test_colors_defined() {
    for v in RED GREEN YELLOW CYAN NC; do
        if [ -z "${!v+x}" ]; then return 1; fi
    done
    return 0
}

# ── Run all tests ──────────────────────────────────────────────────────

test_header
run_test "marker lines are correct"           test_markers_defined
run_test "HOSTS_FILE defaults to /etc/hosts"  test_hosts_file_default
run_test "mirror sources are well-formed"     test_sources
run_test "curl retry options configured"      test_curl_retry_opts
run_test "core domains include github.com"    test_core_domains
run_test "probe constants are sane"           test_probe_constants
run_test "KEEP_BACKUPS is a positive integer" test_keep_backups
run_test "color variables are defined"        test_colors_defined
test_report
exit $?
