#!/usr/bin/env bash
# ============================================================================
# test-multi-scan.sh
# Validates multi-group scan functions in lib/02-scan.sh
# Run: bash tests/test-multi-scan.sh
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/lib/00-constants.sh"
source "$PROJECT_ROOT/lib/01-utils.sh"
source "$PROJECT_ROOT/lib/02-scan.sh"
source "$PROJECT_ROOT/lib/03-validate.sh"

passed=0
failed=0

pass() { echo "  PASS: $1"; passed=$((passed + 1)); }
fail() { echo "  FAIL: $1"; failed=$((failed + 1)); }

echo "=== test-multi-scan ==="

# Test: get_valid_ips_file function exists
if declare -f get_valid_ips_file >/dev/null 2>&1; then
  pass "get_valid_ips_file is defined"
else
  fail "get_valid_ips_file is not defined"
fi

# Test: scan_domain_group function exists
if declare -f scan_domain_group >/dev/null 2>&1; then
  pass "scan_domain_group is defined"
else
  fail "scan_domain_group is not defined"
fi

# Test: scan_all_groups function exists
if declare -f scan_all_groups >/dev/null 2>&1; then
  pass "scan_all_groups is defined"
else
  fail "scan_all_groups is not defined"
fi

# Test: scan_domain_group rejects empty domain
result=$(scan_domain_group "" "$(mktemp)" 2>/dev/null || echo "FAILED")
[ "$result" = "FAILED" ] && pass "scan_domain_group rejects empty domain" \
  || fail "scan_domain_group should reject empty domain"

# Test: scan_domain_group rejects empty ip file
result=$(scan_domain_group "github.com" "" 2>/dev/null || echo "FAILED")
[ "$result" = "FAILED" ] && pass "scan_domain_group rejects empty file" \
  || fail "scan_domain_group should reject empty file"

# Test: scan_all_groups rejects empty ip file
result=$(scan_all_groups "" 2>/dev/null || echo "FAILED")
[ "$result" = "FAILED" ] && pass "scan_all_groups rejects empty file" \
  || fail "scan_all_groups should reject empty file"

# Note: get_valid_ips_file and scan_all_groups do real network I/O
# (parallel HTTP validation against multiple domains). These are tested
# integration-style in cmd_run flow. Unit tests skip network operations.

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
echo "All tests passed."
