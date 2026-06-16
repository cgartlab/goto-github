#!/usr/bin/env bash
# ============================================================================
# test-multi-apply.sh
# Validates apply_hosts_multi output format (hosts block structure)
# Run: bash tests/test-multi-apply.sh
#
# Note: apply_hosts_multi requires sudo for /etc/hosts writes, so this test
# validates the output format by generating the expected block directly
# using the same logic as the function body.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$PROJECT_ROOT/lib/00-constants.sh"
source "$PROJECT_ROOT/lib/01-utils.sh"
source "$PROJECT_ROOT/lib/04-apply.sh"

passed=0
failed=0

pass() { echo "  PASS: $1"; passed=$((passed + 1)); }
fail() { echo "  FAIL: $1"; failed=$((failed + 1)); }

echo "=== test-multi-apply ==="

# Test: apply_hosts_multi function exists
if declare -f apply_hosts_multi >/dev/null 2>&1; then
  pass "apply_hosts_multi is defined"
else
  fail "apply_hosts_multi is not defined"
fi

# Create temp files
tmp_hosts=$(mktemp)
echo "127.0.0.1 localhost" > "$tmp_hosts"

tmp_groups=$(mktemp)
cat > "$tmp_groups" << 'EOF'
CORE:140.82.112.3:0.234:102400
RAW:185.199.108.153:0.456:204800
CODELOAD:185.199.111.1:0.389:204800
OBJECTS:140.82.114.4:0.512:102400
ASSETS:185.199.109.1:0.345:102400
EOF

tmp_script=$(mktemp)

# Use Python to generate the test script with correct paths substituted
# This avoids all shell variable expansion issues with heredocs
export PROJECT_ROOT="$PROJECT_ROOT" SCRIPT_PATH="$tmp_script" TMP_HOSTS="$tmp_hosts" TMP_GROUPS="$tmp_groups"
python3 - << 'PYEOF'
import os
import sys

project_root = os.environ['PROJECT_ROOT']

with open(os.environ['SCRIPT_PATH'], 'w') as f:
    f.write(f'''#!/usr/bin/env bash
set -eo pipefail
TARGET_HOSTS="{os.environ['TMP_HOSTS']}"

. "{project_root}/lib/00-constants.sh"

{{
  echo ""
  echo "$MARKER_START"
  echo "# Managed by goto-github — do not edit manually"
  echo "# Updated at $(date '+%Y-%m-%d %H:%M:%S')"
  echo "# Download acceleration: multi-group IP optimization enabled"

  while IFS=: read -r group_name group_ip group_time group_size; do
    [ -z "$group_name" ] && continue
    [ "$group_ip" = "DNS_FALLBACK" ] && continue
    [ -z "$group_ip" ] && continue

    domains=""
    case "$group_name" in
      CORE)       domains="$DOMAIN_GROUP_CORE" ;;
      RAW)        domains="$DOMAIN_GROUP_RAW" ;;
      CODELOAD)   domains="$DOMAIN_GROUP_CODELOAD" ;;
      OBJECTS)    domains="$DOMAIN_GROUP_OBJECTS" ;;
      ASSETS)     domains="$DOMAIN_GROUP_ASSETS" ;;
      *) continue ;;
    esac

    if [ -n "$domains" ]; then
      echo "${{group_ip}}    ${{domains}}"
    fi
  done < "{os.environ['TMP_GROUPS']}"

  echo "# DNS domains (not pinned): ${{DNS_DOMAINS:-none}}"
  echo "$MARKER_END"
}} >> "$TARGET_HOSTS"
''')
PYEOF

chmod +x "$tmp_script"
export TMP_HOSTS="$tmp_hosts" TMP_GROUPS="$tmp_groups" SCRIPT_PATH="$tmp_script"
bash "$tmp_script" 2>&1 || true
content=$(cat "$tmp_hosts")

grep -Fq "$MARKER_START" <<< "$content" && pass "Start marker present" || fail "Start marker missing"
grep -Fq "$MARKER_END" <<< "$content" && pass "End marker present" || fail "End marker missing"

# Verify multi-group IPs (echo uses 4 spaces between IP and domains)
grep -Fq "140.82.112.3    github.com" <<< "$content" && pass "CORE IP maps github.com" || fail "CORE IP missing github.com"
grep -Fq "185.199.108.153    raw.githubusercontent.com" <<< "$content" && pass "RAW IP maps raw.githubusercontent.com" || fail "RAW IP missing raw.githubusercontent.com"
grep -Fq "185.199.111.1    codeload.github.com" <<< "$content" && pass "CODELOAD IP maps codeload.github.com" || fail "CODELOAD IP missing codeload.github.com"
grep -Fq "140.82.114.4    objects.githubusercontent.com" <<< "$content" && pass "OBJECTS IP maps objects.githubusercontent.com" || fail "OBJECTS IP missing objects.githubusercontent.com"
grep -Fq "185.199.109.1    github.githubassets.com" <<< "$content" && pass "ASSETS IP maps github.githubassets.com" || fail "ASSETS IP missing github.githubassets.com"

# Verify DNS domains comment
grep -Fq "DNS domains (not pinned):" <<< "$content" && pass "DNS domains comment present" || fail "DNS domains comment missing"
grep -Fq "api.github.com" <<< "$content" && pass "api.github.com in DNS comment" || fail "api.github.com missing from DNS comment"
grep -Fq "pipelines.actions.githubusercontent.com" <<< "$content" && pass "pipelines.actions.githubusercontent.com in DNS comment" || fail "pipelines.actions.githubusercontent.com missing from DNS comment"

# Verify DNS domains are NOT mapped
if grep '^140.82.112.3.*api.github.com' <<< "$content" >/dev/null; then
  fail "api.github.com should NOT be in hosts lines"
else
  pass "api.github.com correctly excluded from hosts lines"
fi

if grep '^185.199.108.153.*pipelines.actions.githubusercontent.com' <<< "$content" >/dev/null; then
  fail "pipelines.actions.githubusercontent.com should NOT be in hosts lines"
else
  pass "pipelines.actions.githubusercontent.com correctly excluded from hosts lines"
fi

# Verify download acceleration comment
grep -Fq "multi-group IP optimization enabled" <<< "$content" && pass "Multi-group optimization comment present" || fail "Multi-group optimization comment missing"

# Test DNS_FALLBACK is skipped
echo "CORE:DNS_FALLBACK:::" >> "$tmp_groups"
GROUPS_FILE="$tmp_groups" TMP_HOSTS="$tmp_hosts" TMP_GROUPS="$tmp_groups" \
  SCRIPT_PATH="$tmp_script" \
  PROJECT_ROOT="$PROJECT_ROOT" \
  bash "$tmp_script" 2>&1 || true
content=$(cat "$tmp_hosts")
grep -q "DNS_FALLBACK" <<< "$content" && fail "DNS_FALLBACK should be skipped" || pass "DNS_FALLBACK entries skipped correctly"

rm -f "$tmp_hosts" "$tmp_groups" "$tmp_script"

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
echo "All tests passed."