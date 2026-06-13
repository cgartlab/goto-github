#!/usr/bin/env bash
# ============================================================================
# test-extract-ip-from-hosts.sh
# Validates lib/03-validate.sh::extract_ip_from_hosts marker parsing
# Run: bash tests/test-extract-ip-from-hosts.sh
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/lib/00-constants.sh"
source "$PROJECT_ROOT/lib/01-utils.sh"
source "$PROJECT_ROOT/lib/03-validate.sh"

passed=0
failed=0

assert_equals() {
  local expected="$1"
  local actual="$2"
  local msg="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $msg"
    passed=$((passed + 1))
  else
    echo "  FAIL: $msg"
    echo "    expected: '$expected'"
    echo "    actual:   '$actual'"
    failed=$((failed + 1))
  fi
}

echo "=== test-extract-ip-from-hosts ==="

# Test 1: Normal block — should return first IP
tmp1=$(mktemp)
cat > "$tmp1" << 'EOF'
127.0.0.1 localhost
::1 localhost
# >>> goto-github >>>
# Managed by goto-github
140.82.114.20 github.com
140.82.114.20 www.github.com
185.199.108.133 raw.githubusercontent.com
# <<< goto-github <<<
EOF
assert_equals "140.82.114.20" "$(extract_ip_from_hosts "$tmp1")" "Normal block returns first IP"
rm -f "$tmp1"

# Test 2: Empty file — should return empty
tmp2=$(mktemp)
assert_equals "" "$(extract_ip_from_hosts "$tmp2")" "Empty file returns empty"
rm -f "$tmp2"

# Test 3: No markers — should return empty
tmp3=$(mktemp)
cat > "$tmp3" << 'EOF'
127.0.0.1 localhost
140.82.114.20 github.com
185.199.108.133 raw.githubusercontent.com
EOF
assert_equals "" "$(extract_ip_from_hosts "$tmp3")" "No markers returns empty"
rm -f "$tmp3"

# Test 4: Comments only in block — should return empty
tmp4=$(mktemp)
cat > "$tmp4" << 'EOF'
127.0.0.1 localhost
# >>> goto-github >>>
# Managed by goto-github
# Updated at 2026-01-01
# <<< goto-github <<<
EOF
assert_equals "" "$(extract_ip_from_hosts "$tmp4")" "Comments-only block returns empty"
rm -f "$tmp4"

# Test 5: IP with inline comment — should still parse IP
tmp5=$(mktemp)
cat > "$tmp5" << 'EOF'
127.0.0.1 localhost
# >>> goto-github >>>
# Managed by goto-github
140.82.112.3 github.com www.github.com  # some comment
# <<< goto-github <<<
EOF
assert_equals "140.82.112.3" "$(extract_ip_from_hosts "$tmp5")" "IP with inline comment returns correct IP"
rm -f "$tmp5"

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] && echo "All tests passed." || exit 1
