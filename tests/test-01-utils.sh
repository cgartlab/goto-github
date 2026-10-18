#!/usr/bin/env bash
# tests/test-01-utils.sh
# Verifies the helper functions in lib/01-utils.sh: logging, platform
# predicates, HTTP-code classification, curl-error mapping, DNS flush.
# No network required. Exit 0 on full pass, 1 on any failure.

set -o nounset -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/tests/lib/test-helpers.sh"
setup_tmpdir

source "$REPO_ROOT/lib/00-constants.sh"
source "$REPO_ROOT/lib/01-utils.sh"

# ── Test functions ─────────────────────────────────────────────────────

# log_info → stdout, tagged [INFO]
test_log_info_stdout() {
    local out
    out=$(log_info "hello world")
    assert_contains "$out" "[INFO]" "log_info prefixes [INFO]"
    assert_contains "$out" "hello world" "log_info echoes the message"
}

# log_warn → stderr, tagged [WARN]
test_log_warn_stderr() {
    local out
    out=$(log_warn "careful" 2>&1 1>/dev/null)
    assert_contains "$out" "[WARN]" "log_warn prefixes [WARN]"
    assert_contains "$out" "careful"
}

# log_error → stderr, tagged [ERROR]
test_log_error_stderr() {
    local out
    out=$(log_error "boom" 2>&1 1>/dev/null)
    assert_contains "$out" "[ERROR]" "log_error prefixes [ERROR]"
}

# is_http_code_ok: real HTTP status codes (1xx-5xx) are OK
test_http_code_ok() {
    for code in 100 200 204 301 302 400 403 404 500 503 599; do
        if ! is_http_code_ok "$code"; then
            echo "    expected reachable: $code" >&2
            return 1
        fi
    done
    return 0
}

# curl prints 000 on connection failure / no response → must NOT be "reachable"
test_http_code_rejects_000() {
    is_http_code_ok "000" && return 1
    is_http_code_ok "" && return 1
    for code in 0 00 099 12 1234 abc; do
        is_http_code_ok "$code" && return 1
    done
    return 0
}

# describe_curl_error maps curl exit codes to actionable text
test_describe_curl_error() {
    assert_equals "connection failed"          "$(describe_curl_error 7 '')"
    assert_equals "unable to resolve host"     "$(describe_curl_error 6 '')"
    assert_equals "request timeout"            "$(describe_curl_error 28 '')"
    assert_equals "HTTP error response"        "$(describe_curl_error 22 '')"
    assert_equals "TLS connection error"       "$(describe_curl_error 35 '')"
    assert_equals "exit 99"                    "$(describe_curl_error 99 '')"
    assert_equals "connection failed, stderr: Could not resolve host" \
        "$(describe_curl_error 7 'Could not resolve host')"
}

# platform predicates return 0/1 without crashing and are mutually exclusive
test_platform_predicates() {
    local macos=0 linux=0
    is_macos && macos=1
    is_linux && linux=1
    if [ "$macos" -eq 1 ] && [ "$linux" -eq 1 ]; then
        echo "    is_macos and is_linux cannot both be true" >&2
        return 1
    fi
    assert_not_empty "$(detect_platform_str)"
}

# is_root returns a boolean-ish status (0 when root, 1 otherwise) without crashing
test_is_root_callable() {
    if is_root; then return 0; fi
    return 0
}

# ── Run all tests ──────────────────────────────────────────────────────

test_header
run_test "log_info writes to stdout"           test_log_info_stdout
run_test "log_warn writes to stderr"           test_log_warn_stderr
run_test "log_error writes to stderr"          test_log_error_stderr
run_test "is_http_code_ok accepts 1xx-5xx"     test_http_code_ok
run_test "is_http_code_ok rejects 000/malformed" test_http_code_rejects_000
run_test "describe_curl_error maps exit codes" test_describe_curl_error
run_test "platform predicates are consistent"  test_platform_predicates
run_test "is_root is callable"                 test_is_root_callable
test_report
exit $?
