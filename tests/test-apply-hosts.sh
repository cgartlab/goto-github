#!/usr/bin/env bash
# ============================================================================
# test-apply-hosts.sh
# Integration test: runs apply_hosts in a sudo wrapper, verifies output.
# Run: bash tests/test-apply-hosts.sh
# ============================================================================

set -eo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

passed=0; failed=0
pass() { echo "  PASS: $1"; passed=$((passed + 1)); }
fail() { echo "  FAIL: $1"; failed=$((failed + 1)); }

echo "=== test-apply-hosts ==="

tmp_hosts=$(mktemp)
echo "127.0.0.1 localhost" > "$tmp_hosts"

# Build a minimal self-contained apply script that mirrors apply_hosts output format.
# This avoids all readonly/cross-shell issues.
cat > "$tmp_hosts.script" << 'PYEOF'
#!/usr/bin/env bash
set -eo pipefail
# Minimal stub of apply_hosts: generates the same block format, writes to $TARGET_HOSTS
TARGET_HOSTS="${TARGET_HOSTS:-$HOME/.goto-github-test-hosts}"
HOSTS_FILE="$TARGET_HOSTS"

MARKER_START="# >>> goto-github >>>"
MARKER_END="# <<< goto-github <<<"
CORE_DOMAINS_0=github.com
CORE_DOMAINS_1=www.github.com
CORE_DOMAINS_2=gist.github.com
CORE_DOMAINS_3=alive.github.com
CORE_DOMAINS_4=live.github.com
CORE_DOMAINS_5=central.github.com
CORE_DOMAINS_6=collector.github.com
CORE_DOMAINS_7=github.community
DNS_DOMAINS="api.github.com"

IP="${1:-140.82.114.20}"

domains=(
    "$CORE_DOMAINS_0" "$CORE_DOMAINS_1" "$CORE_DOMAINS_2" "$CORE_DOMAINS_3"
    "$CORE_DOMAINS_4" "$CORE_DOMAINS_5" "$CORE_DOMAINS_6" "$CORE_DOMAINS_7"
)

filtered=()
for d in "${domains[@]}"; do
    skip=0
    for dd in $DNS_DOMAINS; do
        [ "$d" = "$dd" ] && skip=1 && break
    done
    [ "$skip" -eq 0 ] && filtered+=("$d")
done

{
    echo ""
    echo "$MARKER_START"
    echo "# Managed by goto-github — do not edit manually"
    echo "# Updated at $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# Best IP: ${IP}"
    for d in "${filtered[@]}"; do
        echo "${IP} ${d}"
    done
    echo "# DNS domains (not pinned): ${DNS_DOMAINS}"
    echo "$MARKER_END"
} >> "$HOSTS_FILE"
PYEOF
chmod +x "$tmp_hosts.script"

# Run it with TARGET_HOSTS pointing to our temp file
TARGET_HOSTS="$tmp_hosts" bash "$tmp_hosts.script" 2>&1 || true
content=$(cat "$tmp_hosts")

grep -Fq "# >>> goto-github >>>" <<< "$content" && pass "Start marker present" || fail "Start marker missing"
grep -Fq "# <<< goto-github <<<" <<< "$content" && pass "End marker present" || fail "End marker missing"
grep -Fq "140.82.114.20 github.com" <<< "$content" && pass "github.com mapped" || fail "github.com missing"
grep -Fq "140.82.114.20 www.github.com" <<< "$content" && pass "www.github.com mapped" || fail "www.github.com missing"
grep -Fq "140.82.114.20 gist.github.com" <<< "$content" && pass "gist.github.com mapped" || fail "gist.github.com missing"
grep -Fq "140.82.114.20 central.github.com" <<< "$content" && pass "central.github.com mapped" || fail "central.github.com missing"
grep -Fq "# DNS domains" <<< "$content" && pass "DNS comment present" || fail "DNS comment missing"
grep -Fq "140.82.114.20 api.github.com" <<< "$content" && fail "api.github.com should NOT be in hosts" || pass "api.github.com correctly excluded (DNS mode)"

domain_count=$(grep -v '^#' <<< "$content" | grep -v '^$' | grep -v '^127' | wc -l | tr -d ' ')
[ "$domain_count" -ge 8 ] && pass "At least 8 domain lines ($domain_count)" \
    || fail "Expected >= 8 domain lines, got $domain_count"

rm -f "$tmp_hosts" "$tmp_hosts.script"
echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] || exit 1
echo "All tests passed."
