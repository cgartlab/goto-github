#!/usr/bin/env bash
# ============================================================================
# test-multi-cache.sh
# Validates multi-IP cache functions in lib/01-utils.sh
# Run: bash tests/test-multi-cache.sh
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/lib/00-constants.sh"
source "$PROJECT_ROOT/lib/01-utils.sh"

passed=0
failed=0

pass() { echo "  PASS: $1"; passed=$((passed + 1)); }
fail() { echo "  FAIL: $1"; failed=$((failed + 1)); }

echo "=== test-multi-cache ==="

# Test: write_multi_cache function exists
if declare -f write_multi_cache >/dev/null 2>&1; then
  pass "write_multi_cache is defined"
else
  fail "write_multi_cache is not defined"
fi

# Test: read_multi_cache function exists
if declare -f read_multi_cache >/dev/null 2>&1; then
  pass "read_multi_cache is defined"
else
  fail "read_multi_cache is not defined"
fi

# Build groups file
tmp_groups=$(mktemp)
cat > "$tmp_groups" << 'EOF'
CORE:140.82.112.3:0.234:102400
RAW:185.199.108.153:0.456:204800
CODELOAD:185.199.111.1:0.389:204800
OBJECTS:140.82.114.4:0.512:102400
ASSETS:185.199.109.1:0.345:102400
EOF

tmp_cache=$(mktemp)

# Call write_multi_cache via subprocess with explicit cache file path
bash -c '
  . "$1/lib/00-constants.sh"
  . "$1/lib/01-utils.sh"
  write_multi_cache "$2" "$3"
' _ "$PROJECT_ROOT" "$tmp_groups" "$tmp_cache" 2>/dev/null

# Verify cache file was created
[ -s "$tmp_cache" ] && pass "write_multi_cache creates non-empty cache file" || fail "write_multi_cache did not create cache file"

# Verify cache file contains expected entries
grep -q "^github.com:140.82.112.3:" "$tmp_cache" \
  && pass "cache contains github.com entry" \
  || fail "cache missing github.com entry"

grep -q "^raw.githubusercontent.com:185.199.108.153:" "$tmp_cache" \
  && pass "cache contains raw.githubusercontent.com entry" \
  || fail "cache missing raw.githubusercontent.com entry"

grep -q "^codeload.github.com:185.199.111.1:" "$tmp_cache" \
  && pass "cache contains codeload.github.com entry" \
  || fail "cache missing codeload.github.com entry"

grep -q "^objects.githubusercontent.com:140.82.114.4:" "$tmp_cache" \
  && pass "cache contains objects.githubusercontent.com entry" \
  || fail "cache missing objects.githubusercontent.com entry"

grep -q "^github.githubassets.com:185.199.109.1:" "$tmp_cache" \
  && pass "cache contains github.githubassets.com entry" \
  || fail "cache missing github.githubassets.com entry"

# Test: write_multi_cache skips DNS_FALLBACK entries
echo "CORE:DNS_FALLBACK:::" >> "$tmp_groups"
tmp_cache2=$(mktemp)
bash -c '
  . "$1/lib/00-constants.sh"
  . "$1/lib/01-utils.sh"
  write_multi_cache "$2" "$3"
' _ "$PROJECT_ROOT" "$tmp_groups" "$tmp_cache2" 2>/dev/null
grep -q "DNS_FALLBACK" "$tmp_cache2" \
  && fail "write_multi_cache should skip DNS_FALLBACK entries" \
  || pass "write_multi_cache skips DNS_FALLBACK entries"
rm -f "$tmp_cache2"

# Test: read_multi_cache outputs shell variable assignments
# Use optional cache_file parameter to bypass readonly CACHE_FILE
output=$(bash -c '
  . "'"$PROJECT_ROOT"'/lib/00-constants.sh"
  . "'"$PROJECT_ROOT"'/lib/01-utils.sh"
  read_multi_cache "$1"
' _ "$tmp_cache")

echo "$output" | grep -q "CORE_IP='140.82.112.3'" \
  && pass "read_multi_cache outputs CORE_IP" \
  || fail "read_multi_cache missing CORE_IP"

echo "$output" | grep -q "RAW_IP='185.199.108.153'" \
  && pass "read_multi_cache outputs RAW_IP" \
  || fail "read_multi_cache missing RAW_IP"

echo "$output" | grep -q "CODELOAD_IP='185.199.111.1'" \
  && pass "read_multi_cache outputs CODELOAD_IP" \
  || fail "read_multi_cache missing CODELOAD_IP"

echo "$output" | grep -q "OBJECTS_IP='140.82.114.4'" \
  && pass "read_multi_cache outputs OBJECTS_IP" \
  || fail "read_multi_cache missing OBJECTS_IP"

echo "$output" | grep -q "ASSETS_IP='185.199.109.1'" \
  && pass "read_multi_cache outputs ASSETS_IP" \
  || fail "read_multi_cache missing ASSETS_IP"

# Test: read_multi_cache returns 1 for missing file
result=$(bash -c '
  . "'"$PROJECT_ROOT"'/lib/00-constants.sh"
  . "'"$PROJECT_ROOT"'/lib/01-utils.sh"
  read_multi_cache "/nonexistent/path/cache"
' 2>/dev/null || echo "FAILED")
[ "$result" = "FAILED" ] && pass "read_multi_cache returns error for missing file" \
  || fail "read_multi_cache should return error for missing file"

rm -f "$tmp_groups" "$tmp_cache"

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
echo "All tests passed."
