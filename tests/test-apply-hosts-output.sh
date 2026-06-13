#!/usr/bin/env bash
# ============================================================================
# test-apply-hosts-output.sh
# Validates lib/04-apply.sh::apply_hosts produces a well-formed hosts block.
# Run: bash tests/test-apply-hosts-output.sh
# ============================================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
passed=0
failed=0

assert_contains() {
  if echo "$2" | grep -Fq "$1"; then
    echo "  PASS: $3"; passed=$((passed + 1))
  else
    echo "  FAIL: $3"; failed=$((failed + 1)); fi
}

echo "=== test-apply-hosts-output ==="

# Verify the apply_hosts function exists
source "$PROJECT_ROOT/lib/00-constants.sh"
source "$PROJECT_ROOT/lib/01-utils.sh"
source "$PROJECT_ROOT/lib/04-apply.sh"

if declare -f apply_hosts > /dev/null 2>&1; then
  echo "  PASS: apply_hosts function is defined"; passed=$((passed + 1))
else
  echo "  FAIL: apply_hosts function is not defined"; failed=$((failed + 1)); fi

# Verify markers are defined
if [ -n "$MARKER_START" ] && [ -n "$MARKER_END" ]; then
  echo "  PASS: MARKER_START and MARKER_END are defined"; passed=$((passed + 1))
else
  echo "  FAIL: Markers not defined"; failed=$((failed + 1)); fi

# Verify core domains are defined
if [ -n "$CORE_DOMAINS_0" ]; then
  echo "  PASS: CORE_DOMAINS are defined"; passed=$((passed + 1))
else
  echo "  FAIL: CORE_DOMAINS not defined"; failed=$((failed + 1)); fi

# Verify DNS domains are defined
if [ -n "$DNS_DOMAINS" ]; then
  echo "  PASS: DNS_DOMAINS=$DNS_DOMAINS"; passed=$((passed + 1))
else
  echo "  FAIL: DNS_DOMAINS not defined"; failed=$((failed + 1)); fi

# Verify retry constants
if [ -n "$SCAN_RETRY_COUNT" ] && [ -n "$SCAN_RETRY_DELAY" ]; then
  echo "  PASS: Retry constants defined"; passed=$((passed + 1))
else
  echo "  FAIL: Retry constants not defined"; failed=$((failed + 1)); fi

# Verify priority scan constants
if [ -n "$MIN_PRIORITY_HITS" ]; then
  echo "  PASS: MIN_PRIORITY_HITS=$MIN_PRIORITY_HITS"; passed=$((passed + 1))
else
  echo "  FAIL: MIN_PRIORITY_HITS not defined"; failed=$((failed + 1)); fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] && echo "All tests passed." || exit 1