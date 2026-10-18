#!/usr/bin/env bash
# =============================================================================
# lib/02-fetch.sh — source fetching, dead-IP filtering, last-resort IP probe
# Sourced after 00-constants.sh and 01-utils.sh. Do not execute directly.
# =============================================================================
# shellcheck shell=bash

if [ -n "${GOTO_GITHUB_02_FETCH_LOADED:-}" ]; then
    return 0
fi
GOTO_GITHUB_02_FETCH_LOADED=1

# ── Filter dead core domain IPs from hosts content ───────────────────────────
# Removes lines for core domains (github.com, api.github.com, etc.) whose IPs
# are unreachable. CDN domains (avatars, raw, objects) are NOT checked.
# Returns filtered content on stdout; returns 1 if ALL core IPs are dead.
filter_dead_core_ips() {
    local content="$1"
    local line ip domain
    local dead_core_count=0
    local total_core_count=0

    while IFS= read -r line; do
        # Skip empty lines and comments
        [ -z "$line" ] && continue
        [[ "$line" =~ ^# ]] && continue

        # Extract IP and domain
        ip=$(echo "$line" | awk '{print $1}')
        domain=$(echo "$line" | awk '{print $2}')
        if [ -z "$ip" ] || [ -z "$domain" ]; then
            continue
        fi

        # Check if this is a core domain
        if echo "$CORE_DOMAINS" | grep -qw "$domain"; then
            total_core_count=$((total_core_count + 1))
            if ! test_tcp_reachable "$ip" "443" "3"; then
                echo -e "${YELLOW}[WARN]${NC} Skipping $domain (unreachable IP: $ip)" >&2
                dead_core_count=$((dead_core_count + 1))
                continue
            fi
        fi

        echo "$line"
    done <<< "$content"

    if [ "$total_core_count" -gt 0 ] && [ "$dead_core_count" -eq "$total_core_count" ]; then
        echo -e "${YELLOW}[WARN]${NC} All core domain IPs are unreachable in this source" >&2
        return 1
    fi
    return 0
}

# ── Last-resort IP probe ─────────────────────────────────────────────────────
# Pool = unique IPs the sources still serve, each expanded to a ±PROBE_RADIUS
# window per /24. Probed in parallel via --resolve (SNI still routes the
# request to github.com, so the IP must actually serve that Host).
probe_one_ip() {
    local cand="$1" rc
    rc=$(curl -s -o /dev/null --connect-timeout 4 --max-time "$PROBE_TIMEOUT" \
        -w "%{http_code}" -H "Accept: application/x-git-upload-pack-advertisement" \
        "$PROBE_TARGET" \
        --resolve "github.com:443:${cand}" 2>/dev/null || true)
    case "$rc" in
        2*) printf '%s\n' "$cand" ;;
    esac
}

probe_github_ip() {
    local url line ip base octet cand winner round1
    local -a pool=()
    local -a dedup=()
    local seen="" result_file content

    result_file=$(mktemp "${TMPDIR:-/tmp}/goto-github-probe.XXXXXX") || return 1

    while IFS= read -r url; do
        [ -z "$url" ] && continue
        content=$(curl -sfL --connect-timeout 8 --max-time 20 "$url" 2>/dev/null || true)
        [ -z "$content" ] && continue
        while IFS= read -r line; do
            ip=$(echo "$line" | awk '{print $1}')
            [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
            base="${ip%.*}"
            octet="${ip##*.}"
            for ((cand=octet-PROBE_RADIUS; cand<=octet+PROBE_RADIUS; cand++)); do
                if [ "$cand" -ge 1 ] && [ "$cand" -le 254 ] && [ "${#pool[@]}" -lt "$PROBE_POOL_CAP" ]; then
                    pool+=("${base}.$cand")
                fi
            done
        done <<< "$content"
    done <<< "$SOURCES"

    # Empty-array expansion under set -u aborts on bash 3.2 (macOS default), so
    # bail before iterating: this is exactly the "every source is dead" case.
    if [ "${#pool[@]}" -eq 0 ]; then
        rm -f "$result_file"
        return 1
    fi

    for ip in "${pool[@]}"; do
        if [[ " $seen " != *" $ip "* ]]; then
            seen="${seen:+ }$ip"
            dedup+=("$ip")
            [ "${#dedup[@]}" -ge "$PROBE_TEST_CAP" ] && break
        fi
    done

    if [ "${#dedup[@]}" -eq 0 ]; then
        rm -f "$result_file"
        return 1
    fi

    # Round 1: which candidates answer at all.
    for cand in "${dedup[@]}"; do
        probe_one_ip "$cand" >> "$result_file" &
    done
    wait

    if [ ! -s "$result_file" ]; then
        rm -f "$result_file"
        return 1
    fi

    # Round 2: edge IPs flake — a candidate can answer 200 then time out on the
    # next request. Re-test the survivors so the IP committed to hosts is the
    # most stable one. If every survivor flakes, fall back to round 1: a flaky
    # IP still beats no IP at all.
    round1=$(sort -u "$result_file")
    : > "$result_file"
    while IFS= read -r cand; do
        [ -z "$cand" ] && continue
        probe_one_ip "$cand" >> "$result_file" &
    done <<< "$round1"
    wait

    if [ -s "$result_file" ]; then
        winner=$(head -1 "$result_file")
    else
        winner=$(head -1 <<< "$round1")
    fi
    rm -f "$result_file"
    printf '%s\t%s\n' "$winner" "github.com"
    return 0
}

# ── Fetch from sources with fallback ─────────────────────────────────────────
fetch_hosts_content() {
    local content url filtered label curl_error_tmp curl_rc source_error
    while IFS= read -r url; do
        [ -z "$url" ] && continue

        case "$url" in
            *jsdelivr*)     label="jsDelivr CDN" ;;
            *hellogithub*)  label="raw.hellogithub.com" ;;
            *github*)       label="GitHub Raw" ;;
            *)              label="$url" ;;
        esac

        echo -e "\n  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
        printf "  ${CYAN}  📡 正在获取数据源: %s${NC}\n" "$label" >&2
        echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2

        curl_error_tmp=$(mktemp)
        content=$(curl -sfL "${CURL_RETRY_OPTS[@]}" --connect-timeout 10 --max-time 30 "$url" 2>"$curl_error_tmp") && curl_rc=0 || curl_rc=$?
        if [ "$curl_rc" -ne 0 ] || [ -z "$content" ]; then
            source_error=$(describe_curl_error "$curl_rc" "$(tr -d '\r' < "$curl_error_tmp" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')")
            printf "  ${RED}  ✗ 数据源 %s 获取失败 (%s)${NC}\n" "$label" "$source_error" >&2
            rm -f "$curl_error_tmp"
            continue
        fi
        rm -f "$curl_error_tmp"
        printf "  ${GREEN}  ✓ 数据源 %s 获取成功${NC}\n" "$label" >&2

        # Filter out dead core IPs (github.com, api.github.com, etc.)
        # NOTE: no 2>&1 here — WARN messages must reach the terminal, only
        # filtered content is captured on stdout.
        if ! filtered=$(filter_dead_core_ips "$content"); then
            echo -e "  ${YELLOW}  ⚠ 核心域名 IP 全部不可用，尝试下一个数据源...${NC}" >&2
            continue
        fi
        content="$filtered"

        if validate_hosts_content "$content"; then
            # Show per-domain IP test results (output to stderr)
            test_domain_ips "$content" >&2
            local ip_rc=$?
            if [ "$ip_rc" -eq 2 ]; then
                echo -e "  ${YELLOW}  ⚠ 数据源 IP 不可达，尝试下一个数据源...${NC}" >&2
                continue
            fi
            echo "$content"
            return 0
        fi
        printf "  ${RED}  ✗ 数据源 %s 格式验证失败${NC}\n" "$label" >&2
    done <<< "$SOURCES"

    echo -e "  ${YELLOW}  🔎 所有数据源 IP 不可达，尝试主动探测可用 IP...${NC}" >&2
    if content=$(probe_github_ip); then
        echo -e "  ${GREEN}  ✓ 探测到可用 IP，启用探测模式${NC}" >&2
        echo "$content"
        return 0
    fi

    echo -e "\n  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
    echo -e "  ${RED}  ✗ 所有数据源均不可用，且探测未找到可用 IP${NC}" >&2
    echo -e "  ${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
    return 1
}
