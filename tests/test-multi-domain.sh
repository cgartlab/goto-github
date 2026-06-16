#!/usr/bin/env bash
# ============================================================================
# test-multi-domain.sh
# Validates domain-group validation functions in lib/03-validate.sh
# Run: bash tests/test-multi-domain.sh
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/lib/00-constants.sh"
source "$PROJECT_ROOT/lib/01-utils.sh"
source "$PROJECT_ROOT/lib/03-validate.sh"

passed=0
failed=0

pass() { echo "  PASS: $1"; passed=$((passed + 1)); }
fail() { echo "  FAIL: $1"; failed=$((failed + 1)); }

echo "=== test-multi-domain ==="

# Test: validate_ip_for_domain function exists
if declare -f validate_ip_for_domain >/dev/null 2>&1; then
  pass "validate_ip_for_domain is defined"
else
  fail "validate_ip_for_domain is not defined"
fi

# Test: validate_ip_quick_for_domain function exists
if declare -f validate_ip_quick_for_domain >/dev/null 2>&1; then
  pass "validate_ip_quick_for_domain is defined"
else
  fail "validate_ip_quick_for_domain is not defined"
fi

# Test: validate_ip_for_domain returns empty for empty ip
result=$(validate_ip_for_domain "" "github.com" 2>/dev/null || echo "")
[ -z "$result" ] && pass "validate_ip_for_domain rejects empty IP" || fail "validate_ip_for_domain should reject empty IP"

# Test: validate_ip_for_domain returns empty for empty domain
result=$(validate_ip_for_domain "140.82.114.20" "" 2>/dev/null || echo "")
[ -z "$result" ] && pass "validate_ip_for_domain rejects empty domain" || fail "validate_ip_for_domain should reject empty domain"

# Test: validate_ip_quick_for_domain rejects empty ip (returns failure exit code)
if validate_ip_quick_for_domain "" "github.com" 2>/dev/null; then
  fail "validate_ip_quick_for_domain should reject empty IP"
else
  pass "validate_ip_quick_for_domain rejects empty IP"
fi

# Test: validate_ip_quick_for_domain rejects empty domain
if validate_ip_quick_for_domain "140.82.114.20" "" 2>/dev/null; then
  fail "validate_ip_quick_for_domain should reject empty domain"
else
  pass "validate_ip_quick_for_domain rejects empty domain"
fi

# Test: extract_ip_from_hosts with domain parameter
tmp=$(mktemp)
cat > "$tmp" << 'EOF'
127.0.0.1 localhost
# >>> goto-github >>>
140.82.112.3 github.com www.github.com
185.199.108.153 raw.githubusercontent.com
185.199.111.1 codeload.github.com
# <<< goto-github <<<
EOF

result=$(extract_ip_from_hosts "$tmp" "github.com")
[ "$result" = "140.82.112.3" ] && pass "extract_ip_from_hosts returns github.com IP" || fail "extract_ip_from_hosts github.com: got '$result'"

result=$(extract_ip_from_hosts "$tmp" "raw.githubusercontent.com")
[ "$result" = "185.199.108.153" ] && pass "extract_ip_from_hosts returns raw.githubusercontent.com IP" || fail "extract_ip_from_hosts raw.githubusercontent.com: got '$result'"

result=$(extract_ip_from_hosts "$tmp" "codeload.github.com")
[ "$result" = "185.199.111.1" ] && pass "extract_ip_from_hosts returns codeload.github.com IP" || fail "extract_ip_from_hosts codeload.github.com: got '$result'"

result=$(extract_ip_from_hosts "$tmp" "objects.githubusercontent.com")
[ -z "$result" ] && pass "extract_ip_from_hosts returns empty for unmapped domain" || fail "extract_ip_from_hosts unmapped domain: got '$result'"

# Legacy behavior: no domain param returns first IP
result=$(extract_ip_from_hosts "$tmp")
[ "$result" = "140.82.112.3" ] && pass "extract_ip_from_hosts legacy (no domain) returns first IP" || fail "extract_ip_from_hosts legacy: got '$result'"

rm -f "$tmp"

# Test: DOMAIN_GROUP_* constants are defined
for group in CORE RAW CODELOAD OBJECTS ASSETS; do
  var="DOMAIN_GROUP_${group}"
  if [ -n "${!var}" ]; then
    pass "DOMAIN_GROUP_${group} is defined"
  else
    fail "DOMAIN_GROUP_${group} is not defined"
  fi
done

# Test: DNS_DOMAINS includes pipelines.actions.githubusercontent.com
echo "$DNS_DOMAINS" | grep -qw "pipelines.actions.githubusercontent.com" \
  && pass "DNS_DOMAINS includes pipelines.actions.githubusercontent.com" \
  || fail "DNS_DOMAINS should include pipelines.actions.githubusercontent.com"

# Test: DNS_DOMAINS includes api.github.com
echo "$DNS_DOMAINS" | grep -qw "api.github.com" \
  && pass "DNS_DOMAINS includes api.github.com" \
  || fail "DNS_DOMAINS should include api.github.com"

# Test: ALL_HOSTS_DOMAINS is not empty
[ -n "$ALL_HOSTS_DOMAINS" ] && pass "ALL_HOSTS_DOMAINS is defined" || fail "ALL_HOSTS_DOMAINS is empty"

# Test: DOMAIN_GROUP_NAMES contains expected groups
for g in CORE RAW CODELOAD OBJECTS ASSETS; do
  echo "$DOMAIN_GROUP_NAMES" | grep -qw "$g" \
    && pass "DOMAIN_GROUP_NAMES contains $g" \
    || fail "DOMAIN_GROUP_NAMES missing $g"
done

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
echo "All tests passed."
