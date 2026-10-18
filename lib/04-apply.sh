#!/usr/bin/env bash
# =============================================================================
# lib/04-apply.sh — build block, apply/remove hosts, shadowing check, status
# Sourced after 00-constants.sh and 01-utils.sh. Do not execute directly.
# =============================================================================
# shellcheck shell=bash

if [ -n "${GOTO_GITHUB_04_APPLY_LOADED:-}" ]; then
    return 0
fi
GOTO_GITHUB_04_APPLY_LOADED=1

# ── Build hosts block from raw content ───────────────────────────────────────
build_hosts_block() {
    local content="$1"
    local lines
    lines=$(extract_hosts_lines "$content")
    echo "$MARKER_START"
    echo "# Managed by GoToGitHub — $(date +%Y-%m-%d)"
    echo "# Source: 521xueweihan/GitHub520"
    echo "$lines"
    echo "$MARKER_END"
}

# ── Backup rotation ──────────────────────────────────────────────────────────
prune_backups() {
    local bak
    # SC2012: intentional — ls -1t sorts by mtime to keep newest N backups.
    # find -printf is not portable to macOS BSD find.
    # shellcheck disable=SC2012
    while IFS= read -r bak; do
        rm -f "$bak"
    done < <(ls -1t "${HOSTS_FILE}.goto-github.bak."* 2>/dev/null | tail -n +"$((KEEP_BACKUPS + 1))")
}

# ── Apply hosts block ────────────────────────────────────────────────────────
apply_hosts() {
    local block="$1"
    local tmp_file backup perms
    # Backup current state (including any existing block) before modification.
    # cp -p may fail on some filesystems (e.g. Git Bash / NTFS), fall back to cp.
    backup="${HOSTS_FILE}.goto-github.bak.$(date +%Y%m%d%H%M%S)"
    if ! cp -p "$HOSTS_FILE" "$backup" 2>/dev/null && ! cp "$HOSTS_FILE" "$backup"; then
        log_error "Backup failed; aborting apply"
        exit 1
    fi
    prune_backups
    # Atomically replace hosts: build full content in a temp file then rename,
    # so an interrupted apply can never leave a half-written hosts file.
    tmp_file=$(mktemp "${HOSTS_FILE}.XXXXXXXX") || {
        log_error "Failed to create temp file; hosts unchanged"
        exit 1
    }
    TMP_FILE="$tmp_file"
    # Strip any previous goto-github block, preserving all other lines.
    # Pattern deliberately NOT $-anchored on the start marker (consistent with
    # remove_block): manually edited marker lines may carry trailing whitespace
    # or CR, and an anchored pattern would fail to match → duplicate blocks.
    sed "/^${MARKER_START}/,/^${MARKER_END}$/d" "$HOSTS_FILE" > "$tmp_file"
    printf "\n%s\n" "$block" >> "$tmp_file"
    # Preserve original permissions instead of hardcoding 644 (a user may have
    # customized them). macOS BSD stat uses -f %Lp, GNU/Linux uses -c %a.
    if is_macos; then
        perms=$(stat -f %Lp "$HOSTS_FILE" 2>/dev/null || true)
    else
        perms=$(stat -c %a "$HOSTS_FILE" 2>/dev/null || true)
    fi
    if [ -n "$perms" ]; then
        chmod "$perms" "$tmp_file" 2>/dev/null || chmod 644 "$tmp_file" 2>/dev/null || true
    else
        chmod 644 "$tmp_file" 2>/dev/null || true
    fi
    # root:wheel (macOS) and root:root (Linux) both have gid 0.
    chown 0:0 "$tmp_file" 2>/dev/null || true
    if ! mv -f "$tmp_file" "$HOSTS_FILE"; then
        rm -f "$tmp_file"
        # shellcheck disable=SC2034  # TMP_FILE is read by cleanup() in 01-utils.sh
        TMP_FILE=""
        log_error "Failed to replace $HOSTS_FILE; hosts unchanged (backup kept: $backup)"
        exit 1
    fi
    # shellcheck disable=SC2034  # TMP_FILE is read by cleanup() in 01-utils.sh
    TMP_FILE=""
    log_info "Applied to $HOSTS_FILE"
}

# ── Remove existing goto-github block from hosts file ────────────────────────
remove_block() {
    if ! grep -qF "$MARKER_START" "$HOSTS_FILE" 2>/dev/null; then
        return 0
    fi
    local escaped_start escaped_end
    escaped_start=$(printf '%s\n' "$MARKER_START" | sed 's/[\/&]/\\&/g')
    escaped_end=$(printf '%s\n' "$MARKER_END" | sed 's/[\/&]/\\&/g')
    if is_macos; then
        # macOS sed requires empty string argument for -i
        sed -i '' "/^${escaped_start}/,/^${escaped_end}/d" "$HOSTS_FILE"
    else
        # GNU sed (Linux, MINGW64, MSYS) — use -- to stop sed from
        # interpreting leading dash in patterns as options
        sed -i -- "/^${escaped_start}/,/^${escaped_end}/d" "$HOSTS_FILE"
    fi
}

# ── Hosts shadowing check ────────────────────────────────────────────────────
# /etc/hosts resolves the first match, so a github.com entry written by another
# tool ABOVE our marker makes our whole block inert. We never edit outside the
# marker, so this reports the condition instead of fixing it.
check_shadowing() {
    local marker_line
    marker_line=$(grep -nF "$MARKER_START" "$HOSTS_FILE" 2>/dev/null | head -1 | cut -d: -f1)
    [ -z "$marker_line" ] && return 1
    [ "$marker_line" -le 1 ] && return 1
    sed -n "1,$((marker_line - 1))p" "$HOSTS_FILE" \
        | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+github\.com([[:space:]]|$)'
}

# ── Show current status ──────────────────────────────────────────────────────
show_status() {
    local block_exists ip_count has_github
    block_exists=$(sed -n "/^${MARKER_START}$/,/^${MARKER_END}$/p" "$HOSTS_FILE" 2>/dev/null || true)

    echo ""
    echo "=== GoToGitHub Status ==="
    echo ""

    if [ -z "$block_exists" ]; then
        echo "  Status: (not installed)"
        echo "  Run 'sudo ./fetch.sh' to install."
    else
        ip_count=$(echo "$block_exists" | grep -cE '^\s*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
        has_github=$(echo "$block_exists" | grep -cE '\s+github\.com\b' || true)
        echo "  Entries: $ip_count"
        echo "  github.com: $has_github entry(s)"

        # Test actual connectivity through hosts file
        local http_code
        http_code=$(curl -s --connect-timeout 10 --max-time 20 \
            "${CURL_RETRY_OPTS[@]}" \
            -o /dev/null -w "%{http_code}" \
            "https://github.com/" 2>/dev/null || true)
        if is_http_code_ok "$http_code"; then
            echo -e "  Status: ${GREEN}OK${NC} — github.com reachable (HTTP $http_code)"
        else
            echo -e "  Status: ${RED}FAILED${NC} — github.com unreachable"
        fi
    fi
    echo ""
}

# ── PowerShell subcommand interface ──────────────────────────────────────────
# Outputs machine-parseable JSON for --pwsh status
json_status() {
    local ip_count="0" has_github="false" reachable="false" http_code=""

    # 统计 hosts 块中的条目
    local block_content
    block_content=$(sed -n "/^${MARKER_START}$/,/^${MARKER_END}$/p" "$HOSTS_FILE" 2>/dev/null || true)
    if [ -n "$block_content" ]; then
        ip_count=$(echo "$block_content" | grep -cE '^\s*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
        if echo "$block_content" | grep -qE '\s+github\.com\b'; then
            has_github="true"
        fi
        # 直接测试 GitHub 连通性（通过 hosts 文件解析）
        http_code=$(curl -s --connect-timeout 10 --max-time 20 \
            "${CURL_RETRY_OPTS[@]}" \
            -o /dev/null -w "%{http_code}" \
            "https://github.com/" 2>/dev/null || true)
        if is_http_code_ok "$http_code"; then
            reachable="true"
        fi
    fi

    # Detect if block exists
    local block_exists="false"
    if grep -q "$MARKER_START" "$HOSTS_FILE" 2>/dev/null; then
        block_exists="true"
    fi

    cat <<EOF
{
  "installed": $block_exists,
  "entries": $ip_count,
  "has_github": $has_github,
  "reachable": $reachable,
  "http_code": "${http_code:-}"
}
EOF
}
