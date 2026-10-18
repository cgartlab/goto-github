#!/usr/bin/env bash
# tests/test-02-fetch.sh
# Verifies lib/02-fetch.sh: filter_dead_core_ips, probe_one_ip, probe_github_ip.
# curl and the TCP check are mocked so no network is touched.
# Exit 0 on full pass, 1 on any failure.

set -o nounset -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/tests/lib/test-helpers.sh"
setup_tmpdir

source "$REPO_ROOT/lib/00-constants.sh"
source "$REPO_ROOT/lib/01-utils.sh"
source "$REPO_ROOT/lib/02-fetch.sh"

# ── Test functions: filter_dead_core_ips ───────────────────────────────
# Override the TCP check so the filter logic is tested without network.
DEAD_IPS=""
test_tcp_reachable() {
    local ip="$1"
    case " $DEAD_IPS " in
        *" $ip "*) return 1 ;;
        *) return 0 ;;
    esac
}

test_filter_keeps_reachable() {
    DEAD_IPS=""
    local content out
    content=$'1.2.3.4 github.com\n5.6.7.8 api.github.com\n9.9.9.9 avatars.githubusercontent.com'
    out=$(filter_dead_core_ips "$content" 2>/dev/null)
    assert_contains "$out" "1.2.3.4 github.com"
    assert_contains "$out" "5.6.7.8 api.github.com"
    assert_contains "$out" "9.9.9.9 avatars.githubusercontent.com"
}

test_filter_drops_dead_core() {
    DEAD_IPS="1.2.3.4"
    local content out
    content=$'1.2.3.4 github.com\n5.6.7.8 api.github.com\n9.9.9.9 avatars.githubusercontent.com'
    out=$(filter_dead_core_ips "$content" 2>/dev/null)
    assert_not_contains "$out" "1.2.3.4" "dead github.com line must be dropped"
    assert_contains "$out" "5.6.7.8 api.github.com" "reachable core line kept"
    assert_contains "$out" "9.9.9.9 avatars.githubusercontent.com"
}

test_filter_fails_when_all_core_dead() {
    DEAD_IPS="1.2.3.4 5.6.7.8"
    local content
    content=$'1.2.3.4 github.com\n5.6.7.8 api.github.com\n9.9.9.9 avatars.githubusercontent.com'
    if filter_dead_core_ips "$content" >/dev/null 2>&1; then
        echo "    all-core-dead must return non-zero" >&2
        return 1
    fi
    return 0
}

# Non-core domains are never checked, even when the checker says "dead"
test_filter_ignores_noncore() {
    DEAD_IPS="9.9.9.9"
    local content out
    content=$'9.9.9.9 avatars.githubusercontent.com\n1.2.3.4 github.com'
    out=$(filter_dead_core_ips "$content" 2>/dev/null)
    assert_contains "$out" "9.9.9.9 avatars.githubusercontent.com" "non-core domain is not filtered"
}

# ── Test functions: probe_one_ip ───────────────────────────────────────
# Mock curl to emit a configurable HTTP code for the probe target.
HTTP_CODE="200"
curl() {
    local a url=""
    for a in "$@"; do
        case "$a" in
            http*) url="$a" ;;
        esac
    done
    case "$url" in
        *gitignore*) printf '%s' "${HTTP_CODE:-200}" ;;
        *) printf '%s' "${MOCK_SOURCE_CONTENT:-}" ;;
    esac
}

test_probe_one_ip_accepts_2xx() {
    HTTP_CODE=200
    assert_equals "1.2.3.4" "$(probe_one_ip '1.2.3.4')"
    HTTP_CODE=204
    assert_equals "1.2.3.4" "$(probe_one_ip '1.2.3.4')"
}

test_probe_one_ip_rejects_non_2xx() {
    HTTP_CODE=400
    assert_equals "" "$(probe_one_ip '1.2.3.4')"
    HTTP_CODE=000
    assert_equals "" "$(probe_one_ip '1.2.3.4')"
}

# ── Test functions: probe_github_ip ────────────────────────────────────
test_probe_github_ip_success() {
    MOCK_SOURCE_CONTENT=$'140.82.113.20\tgithub.com\n20.205.243.166\tapi.github.com'
    HTTP_CODE=200
    local out rc=0
    out=$(probe_github_ip 2>/dev/null) || rc=$?
    assert_equals "0" "$rc" "reachable candidate → probe succeeds"
    assert_equals "github.com" "$(printf '%s' "$out" | cut -f2)" "output is a github.com hosts line"
    printf '%s' "$out" | cut -f1 | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || return 1
    return 0
}

test_probe_github_ip_all_unreachable() {
    MOCK_SOURCE_CONTENT=$'140.82.113.20\tgithub.com'
    HTTP_CODE=000
    if probe_github_ip >/dev/null 2>&1; then
        echo "    all candidates unreachable must fail" >&2
        return 1
    fi
    return 0
}

test_probe_github_ip_empty_sources() {
    MOCK_SOURCE_CONTENT=""
    HTTP_CODE=200
    if probe_github_ip >/dev/null 2>&1; then
        echo "    empty sources must fail" >&2
        return 1
    fi
    return 0
}

# NOTE: the curl mock above stays in effect for the whole script (the process
# exits after the run), so it must not be unset before run_test executes.

# ── Run all tests ──────────────────────────────────────────────────────

test_header
run_test "filter_dead_core_ips keeps reachable"        test_filter_keeps_reachable
run_test "filter_dead_core_ips drops dead core IPs"    test_filter_drops_dead_core
run_test "filter_dead_core_ips fails when all core dead" test_filter_fails_when_all_core_dead
run_test "filter_dead_core_ips ignores non-core domains" test_filter_ignores_noncore
run_test "probe_one_ip accepts 2xx"                    test_probe_one_ip_accepts_2xx
run_test "probe_one_ip rejects non-2xx"                test_probe_one_ip_rejects_non_2xx
run_test "probe_github_ip succeeds on reachable candidate" test_probe_github_ip_success
run_test "probe_github_ip fails when all unreachable"  test_probe_github_ip_all_unreachable
run_test "probe_github_ip fails on empty sources"      test_probe_github_ip_empty_sources
test_report
exit $?
