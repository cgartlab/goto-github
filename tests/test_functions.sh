#!/usr/bin/env bash
# Unit tests for fetch.sh helper functions.
# Extracts functions from fetch.sh by name and asserts behaviour.
# No network required: curl is mocked. Run: bash tests/test_functions.sh
set -uo pipefail

# Constants are read by the functions pulled in via eval(), so the linter
# cannot see the usage. Exporting marks them as used externally (SC2034).
MARKER_START="# >>> goto-github >>>"
MARKER_END="# <<< goto-github <<<"
PROBE_RADIUS=7
PROBE_POOL_CAP=300
PROBE_TEST_CAP=50
PROBE_TIMEOUT=8
PROBE_TARGET="https://github.com/github/gitignore.git/info/refs?service=git-upload-pack"
CURL_RETRY_OPTS=(--retry 3 --retry-all-errors --retry-delay 2 --retry-max-time 60)
export MARKER_START MARKER_END PROBE_RADIUS PROBE_POOL_CAP PROBE_TEST_CAP PROBE_TIMEOUT PROBE_TARGET HOSTS_FILE
export CURL_RETRY_OPTS

HERE="$(cd "$(dirname "$0")" && pwd)"
FETCH_SH="$(cd "$HERE/.." && pwd)/fetch.sh"
PASS=0
FAIL=0

assert_eq() {
    local expected="$1" actual="$2" label="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf '  ✓ %s\n' "$label"
    else
        FAIL=$((FAIL + 1))
        printf '  ✗ %s\n    expected: %s\n    actual:   %s\n' "$label" "$expected" "$actual"
    fi
}

extract() {
    sed -n "/^$1()/,/^}/p" "$FETCH_SH"
}

# ── Constants (mirror fetch.sh) ──────────────────────────────────────────────

eval "$(extract check_shadowing)"
eval "$(extract is_http_code_ok)"
eval "$(extract probe_one_ip)"
eval "$(extract probe_github_ip)"

# ── is_http_code_ok: 000 must NOT count as reachable ─────────────────────────
printf '\nis_http_code_ok\n'

for code in 200 204 301 302 400 403 404 500 503; do
    is_http_code_ok "$code" && r=0 || r=1
    assert_eq "0" "$r" "HTTP $code → reachable"
done

# The regression: curl prints 000 on connection failure / no response.
is_http_code_ok "000" && r=0 || r=1
assert_eq "1" "$r" "HTTP 000 → NOT reachable (curl no-response)"

is_http_code_ok "" && r=0 || r=1
assert_eq "1" "$r" "empty → NOT reachable"

assert_eq "--retry 3 --retry-all-errors --retry-delay 2 --retry-max-time 60" "${CURL_RETRY_OPTS[*]}" "download retry options are configured"

for code in 0 00 099 12 1234 abc; do
    is_http_code_ok "$code" && r=0 || r=1
    assert_eq "1" "$r" "'$code' → NOT reachable (malformed)"
done

# ── check_shadowing ─────────────────────────────────────────────────────────
printf '\ncheck_shadowing\n'

# 1. Shadowing: github.com mapped BEFORE the marker → detected
tmp=$(mktemp); printf '127.0.0.1\tlocalhost\n140.82.113.20        github.com\n# >>> goto-github >>>\n20.205.243.166 github.com\n# <<< goto-github <<<\n' > "$tmp"
HOSTS_FILE="$tmp"
check_shadowing; assert_eq "0" "$?" "shadowed entry above marker is detected"

# 2. github.com only inside our block → no shadowing
tmp2=$(mktemp); printf '127.0.0.1\tlocalhost\n# >>> goto-github >>>\n20.205.243.166 github.com\n# <<< goto-github <<<\n' > "$tmp2"
HOSTS_FILE="$tmp2"
check_shadowing && r=1 || r=1
assert_eq "1" "$r" "our own block does not count as shadowing"

# 3. No goto-github block at all → no shadowing
tmp3=$(mktemp); printf '127.0.0.1\tlocalhost\n1.2.3.4 github.com\n' > "$tmp3"
HOSTS_FILE="$tmp3"
check_shadowing && r=1 || r=1
assert_eq "1" "$r" "absent marker → no shadowing reported"

# 4. Marker on line 1 → no preceding lines, no shadowing
tmp4=$(mktemp); printf '# >>> goto-github >>>\n1.2.3.4 github.com\n# <<< goto-github <<<\n' > "$tmp4"
HOSTS_FILE="$tmp4"
check_shadowing && r=1 || r=1
assert_eq "1" "$r" "marker on line 1 → nothing to shadow"

# 5. Subdomain only (api.github.com) → not a github.com shadow
tmp5=$(mktemp); printf '1.2.3.4 api.github.com\n# >>> goto-github >>>\n2.3.4.5 github.com\n# <<< goto-github <<<\n' > "$tmp5"
HOSTS_FILE="$tmp5"
check_shadowing && r=1 || r=1
assert_eq "1" "$r" "api.github.com is not a github.com shadow"

# 6. github.commm (similar name) → not a shadow (word boundary)
tmp6=$(mktemp); printf '1.2.3.4 github.commm\n# >>> goto-github >>>\n2.3.4.5 github.com\n# <<< goto-github <<<\n' > "$tmp6"
HOSTS_FILE="$tmp6"
check_shadowing && r=1 || r=1
assert_eq "1" "$r" "github.commm does not match github.com"

rm -f "$tmp" "$tmp2" "$tmp3" "$tmp4" "$tmp5" "$tmp6"

# ── probe_one_ip: mock curl, assert pass/fail classification ──────────────────
printf '\nprobe_one_ip\n'

# Mock curl: emit HTTP_CODE as the %{http_code} -w payload.
curl() {
    local a
    for a in "$@"; do
        case "$a" in
            *'%{http_code}'*) printf '%s' "$HTTP_CODE" ;;
        esac
    done
}

HTTP_CODE=200; probe_one_ip "1.2.3.4" > /tmp/probe_out
assert_eq "1.2.3.4" "$(cat /tmp/probe_out)" "HTTP 200 → IP reported as usable"

HTTP_CODE=400; probe_one_ip "1.2.3.4" > /tmp/probe_out
assert_eq "" "$(cat /tmp/probe_out)" "HTTP 400 → IP rejected"

HTTP_CODE=000; probe_one_ip "1.2.3.4" > /tmp/probe_out
assert_eq "" "$(cat /tmp/probe_out)" "HTTP 000 (unreachable) → IP rejected"

rm -f /tmp/probe_out

printf '\n── %d passed, %d failed ──\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
