#!/usr/bin/env bash
# =============================================================================
# scripts/lib/probe.sh — shared sampling primitives
#
# Sourced by connectivity_probe.sh and hosts_status.sh so both measure exactly
# the same way. Keeping one copy matters: if the two diverged, a baseline taken
# by probe could never be compared against a status run.
#
# Every probe_* function takes (attempts, timeout) explicitly rather than
# reading globals — implicit cross-file globals are invisible to shellcheck and
# to a reader.
#
# bash 3.2 compatible (macOS default): no associative arrays, no mapfile.
# =============================================================================
# shellcheck shell=bash

if [ -n "${GOTO_GITHUB_PROBE_LOADED:-}" ]; then
    return 0
fi
GOTO_GITHUB_PROBE_LOADED=1

# ── Turn ok/fail/times into "ok fail min max avg" ────────────────────────────
# min/max/avg are the literal string "null" when there were zero successes:
# reporting 0.000 would claim a latency that was never measured.
probe_summarize() {
    local ok="$1" fail="$2"
    shift 2
    local times=("$@")
    local min="" max="" sum="0" avg="" t

    # Drop the empty placeholder that "${times[@]:-}" produces when there are
    # no elements (bash 3.2 expands an empty array to one empty string).
    if [ ${#times[@]} -eq 1 ] && [ -z "${times[0]}" ]; then
        times=()
    fi

    if [ ${#times[@]} -gt 0 ]; then
        for t in "${times[@]}"; do
            min=$(awk -v a="$t" -v b="${min:-99}" 'BEGIN{print (a<b)?a:b}')
            max=$(awk -v a="$t" -v b="${max:-0}" 'BEGIN{print (a>b)?a:b}')
            sum=$(awk -v a="$t" -v b="$sum" 'BEGIN{printf "%.6f", a+b}')
        done
        avg=$(awk -v s="$sum" -v n="${#times[@]}" 'BEGIN{printf "%.3f", s/n}')
        min=$(awk -v m="$min" 'BEGIN{printf "%.3f", m}')
        max=$(awk -v m="$max" 'BEGIN{printf "%.3f", m}')
    fi

    printf '%d %d %s %s %s\n' "$ok" "$fail" "${min:-null}" "${max:-null}" "${avg:-null}"
}

# ── Sample an HTTP URL N times ──────────────────────────────────────────────
# probe_http <url> <accept-header> <attempts> <timeout>
#
# rc=0 AND a real HTTP code (not 000) = success. 000 means no response at all:
# connection failed, timeout, or DNS failure. Counting it as success would
# report a fully blocked endpoint as "100% available".
probe_http() {
    local url="$1" accept="$2" attempts="$3" timeout="$4"
    local ok=0 fail=0
    local times=()
    local i out rc code t

    for ((i = 1; i <= attempts; i++)); do
        # </dev/null: this loop usually runs inside `while read < <(...)`.
        # Without it curl inherits the loop's stdin and consumes the remaining
        # endpoint lines, silently truncating the scan (observed: 10 -> 9).
        if [ -n "$accept" ]; then
            out=$(curl --noproxy '*' -s -o /dev/null \
                --connect-timeout "$timeout" --max-time $((timeout + 2)) \
                -H "Accept: $accept" \
                -w '%{http_code},%{time_total}' "$url" 2>/dev/null)
        else
            out=$(curl --noproxy '*' -s -o /dev/null \
                --connect-timeout "$timeout" --max-time $((timeout + 2)) \
                -w '%{http_code},%{time_total}' "$url" 2>/dev/null)
        fi
        rc=$?
        code="${out%%,*}"
        if [ $rc -eq 0 ] && [ "$code" != "000" ] && [ -n "$code" ]; then
            ok=$((ok + 1))
            t="${out##*,}"
            times+=("$t")
        else
            fail=$((fail + 1))
        fi
    done

    probe_summarize "$ok" "$fail" "${times[@]:-}"
}

# ── Sample a git smart-http endpoint ────────────────────────────────────────
# probe_git_smart <url> <attempts> <timeout>
# The Accept header matters: GitHub's smart-http handler answers differently
# without it, so omitting it measures the wrong thing.
probe_git_smart() {
    probe_http "$1" 'application/x-git-upload-pack-advertisement' "$2" "$3"
}

# ── TCP reachability ────────────────────────────────────────────────────────
# probe_tcp_once <host> <port> <timeout>
# Emits "1 <connect_time>" or "0 0". Measures the TRANSPORT only — whether a
# key is authorized is a separate dimension (auth_probe), never folded in.
probe_tcp_once() {
    local host="$1" port="$2" timeout="$3"
    local ct rc

    ct=$(curl --noproxy '*' -s -o /dev/null \
        --connect-timeout "$timeout" --max-time $((timeout + 2)) \
        -w '%{time_connect}' "telnet://${host}:${port}" 2>/dev/null)
    rc=$?

    # curl telnet:// exits non-zero when the peer closes after the handshake,
    # but a non-zero time_connect means the TCP handshake completed.
    if [ -n "$ct" ] && [ "$ct" != "0.000000" ]; then
        printf '1 %s\n' "$ct"
        return 0
    fi
    if [ $rc -eq 0 ]; then
        printf '1 0.001\n'
        return 0
    fi
    printf '0 0\n'
    return 1
}

# probe_tcp <host> <port> <attempts> <timeout>
probe_tcp() {
    local host="$1" port="$2" attempts="$3" timeout="$4"
    local ok=0 fail=0
    local times=()
    local i r

    for ((i = 1; i <= attempts; i++)); do
        r=$(probe_tcp_once "$host" "$port" "$timeout")
        if [ "${r%% *}" = "1" ]; then
            ok=$((ok + 1))
            times+=("${r##* }")
        else
            fail=$((fail + 1))
        fi
    done

    probe_summarize "$ok" "$fail" "${times[@]:-}"
}

# ── Dispatch by endpoint kind ───────────────────────────────────────────────
# probe_endpoint <url> <kind> <attempts> <timeout>
probe_endpoint() {
    local url="$1" kind="$2" attempts="$3" timeout="$4"
    case "$kind" in
        tcp)
            # url is tcp://host:port
            local hp="${url#tcp://}"
            probe_tcp "${hp%%:*}" "${hp##*:}" "$attempts" "$timeout"
            ;;
        git-smart) probe_git_smart "$url" "$attempts" "$timeout" ;;
        *)         probe_http "$url" "" "$attempts" "$timeout" ;;
    esac
}
