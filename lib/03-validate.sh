#!/usr/bin/env bash
# =============================================================================
# lib/03-validate.sh — content validation and post-apply verification
# Sourced after 00-constants.sh and 01-utils.sh. Do not execute directly.
# =============================================================================
# shellcheck shell=bash

if [ -n "${GOTO_GITHUB_03_VALIDATE_LOADED:-}" ]; then
    return 0
fi
GOTO_GITHUB_03_VALIDATE_LOADED=1

# ── Content validation ───────────────────────────────────────────────────────
# Prevents malformed or malicious data from being written to /etc/hosts.
validate_hosts_content() {
    local content="$1"
    local ip_count
    ip_count=$(echo "$content" | grep -v '^#' | grep -v '^$' | grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || echo 0)
    if [ "$ip_count" -lt 10 ]; then
        log_error "Content validation failed: only $ip_count valid IP lines (need >= 10)"
        return 1
    fi
    if ! echo "$content" | grep -q 'github.com'; then
        log_error "Content validation failed: no 'github.com' domain found"
        return 1
    fi
    return 0
}

# ── Extract valid lines from raw hosts content ───────────────────────────────
# Returns only IP + domain lines, stripped of trailing comments.
extract_hosts_lines() {
    local content="$1"
    echo "$content" \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\s+' \
        | sed 's/#.*//' \
        | sed 's/[[:space:]]*$//' \
        | grep -v '^$'
}

# ── Verify domain IPs with live progress display ─────────────────────────────
# Tests core GitHub domains against IPs from hosts content.
# Returns: 0=all passed, 1=partial, 2=all failed
# All output goes to stderr (stdout reserved for content return)
test_domain_ips() {
    local raw_content="$1"
    local -a domains=("github.com" "api.github.com" "codeload.github.com")
    local passed=0 failed=0 skipped=0

    echo -e "" >&2
    echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
    echo -e "  ${CYAN}  🔍 正在测试域名连通性...${NC}" >&2
    echo -e "  ${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2

    for domain in "${domains[@]}"; do
        local ip http_code
        ip=$(echo "$raw_content" | grep -m1 -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\s+${domain}\b" | awk '{print $1}')
        if [ -z "$ip" ]; then
            printf "  ${YELLOW}  −${NC}  %-24s (该源未包含此域名)\n" "$domain" >&2
            skipped=$((skipped + 1))
            continue
        fi

        printf "  ${CYAN}  ○${NC}  测试 %s → %s ... " "$domain" "$ip" >&2

        http_code=$(curl -s --connect-timeout 5 --max-time 8 \
            "${CURL_RETRY_OPTS[@]}" \
            -o /dev/null -w "%{http_code}" \
            --resolve "${domain}:443:${ip}" \
            "https://${domain}/" 2>/dev/null || echo "000")

        if [ "$http_code" != "000" ] && [ -n "$http_code" ]; then
            printf "\r  ${GREEN}  ✓${NC}  %-24s → %-16s (HTTP %s)\n" "$domain" "$ip" "$http_code" >&2
            passed=$((passed + 1))
        else
            printf "\r  ${RED}  ✗${NC}  %-24s → %-16s ${RED}连接超时${NC}\n" "$domain" "$ip" >&2
            failed=$((failed + 1))
        fi
    done

    echo -e "" >&2
    if [ "$failed" -eq 0 ] && [ "$passed" -gt 0 ]; then
        printf "  ${GREEN}  ✓ 所有 %d 个域名均可访问${NC}\n" "$passed" >&2
        return 0
    elif [ "$failed" -gt 0 ] && [ "$passed" -gt 0 ]; then
        printf "  ${YELLOW}  ⚠  %d 个通过, %d 个失败 (部分不可达)${NC}\n" "$passed" "$failed" >&2
        return 1
    else
        echo -e "  ${RED}  ✗ 所有域名均不可达 — 数据源 IP 已过期${NC}" >&2
        return 2
    fi
}

# ── Verify applied IP ────────────────────────────────────────────────────────
# 验证 hosts 块已正确写入
verify_hosts() {
    local block_exists ip_count has_github
    block_exists=$(sed -n "/^${MARKER_START}$/,/^${MARKER_END}$/p" "$HOSTS_FILE" 2>/dev/null || true)
    if [ -z "$block_exists" ]; then
        log_warn "No goto-github block found in hosts file"
        return 1
    fi

    # 统计有效 IP 条目
    ip_count=$(echo "$block_exists" | grep -cE '^\s*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
    # 检查 github.com 是否存在
    has_github=$(echo "$block_exists" | grep -cE '\s+github\.com\b' || true)

    if [ "$ip_count" -lt 10 ]; then
        log_warn "Hosts block has only $ip_count entries (expected >= 10)"
        return 1
    fi
    if [ "$has_github" -eq 0 ]; then
        log_warn "Hosts block missing github.com entry"
        return 1
    fi

    log_info "Hosts block verified: $ip_count entries, github.com entry present"
    return 0
}
