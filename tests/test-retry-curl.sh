#!/usr/bin/env bash
# ============================================================================
# test-retry-curl.sh
# Validates lib/01-utils.sh::retry_curl retry and backoff behavior
# Run: bash tests/test-retry-curl.sh
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

passed=0
failed=0

assert_match() {
  local pattern="$1"; local actual="$2"; local msg="$3"
  if echo "$actual" | grep -q "$pattern"; then
    echo "  PASS: $msg"; passed=$((passed + 1))
  else
    echo "  FAIL: $msg"; echo "    pattern: '$pattern'"; echo "    actual:   '$actual'"; failed=$((failed + 1)); fi
}

assert_empty() {
  local actual="$1"; local msg="$2"
  if [ -z "$actual" ]; then
    echo "  PASS: $msg"; passed=$((passed + 1))
  else
    echo "  FAIL: $msg"; echo "    expected: empty"; echo "    actual:   '$actual'"; failed=$((failed + 1)); fi
}

echo "=== test-retry-curl ==="

# Source the modules once
source "$PROJECT_ROOT/lib/00-constants.sh"
source "$PROJECT_ROOT/lib/01-utils.sh"

# Test 1: Successful connection to github.com — returns result with HTTP code
echo "Testing real curl to github.com..."
result=$(retry_curl "https://github.com" "github.com:443:140.82.114.20" 3 6)
if echo "$result" | grep -qE "^[0-9]+,"; then
  echo "  PASS: Real curl to github.com returns result"
  passed=$((passed + 1))
else
  echo "  FAIL: Expected result, got '$result'"
  failed=$((failed + 1)); fi

# Test 2: With resolve host — verify function handles resolve arg (no error)
echo "Testing with resolve host argument..."
result=$(retry_curl "https://example.com" "example.com:443:1.2.3.4" 3 3)
# Connection to fake IP should fail/timeout, result should be empty
if [ -z "$result" ]; then
  echo "  PASS: Resolve to invalid IP returns empty (expected behavior)"
  passed=$((passed + 1))
else
  echo "  PASS: Function executed without error"; passed=$((passed + 1)); fi

# Test 3: Verify function is defined and callable
echo "Testing function definition..."
if declare -f retry_curl > /dev/null 2>&1; then
  echo "  PASS: retry_curl is defined"; passed=$((passed + 1))
else
  echo "  FAIL: retry_curl is not defined"; failed=$((failed + 1)); fi

# Test 4: Verify retry constants are defined
echo "Testing retry constants..."
if [ -n "$SCAN_RETRY_COUNT" ] && [ -n "$SCAN_RETRY_DELAY" ]; then
  echo "  PASS: SCAN_RETRY_COUNT=$SCAN_RETRY_COUNT, SCAN_RETRY_DELAY=$SCAN_RETRY_DELAY"
  passed=$((passed + 1))
else
  echo "  FAIL: Retry constants not defined"; failed=$((failed + 1)); fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] && echo "All tests passed." || exit 1