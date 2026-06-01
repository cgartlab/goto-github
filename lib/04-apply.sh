# goto-github apply functions
# Source after 00-constants.sh and 01-utils.sh
# Provides: apply_hosts, flush_dns, verify_hosts, clear_hosts

# Guard pattern
case "${_GOTO_GITHUB_04_INCLUDED:-}" in
  1) return 0 ;;
esac
readonly _GOTO_GITHUB_04_INCLUDED=1

# ============================================================================
# Replace the goto-github section in /etc/hosts with new entries.
# Uses markers $MARKER_START / $MARKER_END to delimit the managed block.
# Usage: apply_hosts <ip>
# Returns: 0 on success
# ============================================================================
apply_hosts() {
  local ip="$1"
  [ -z "$ip" ] && die "apply_hosts: no IP provided"

  local domains=(
    "$CORE_DOMAINS_0" "$CORE_DOMAINS_1" "$CORE_DOMAINS_2" "$CORE_DOMAINS_3"
    "$CORE_DOMAINS_4" "$CORE_DOMAINS_5" "$CORE_DOMAINS_6" "$CORE_DOMAINS_7"
  )

  local tmpblock
  tmpblock=$(mktemp -t goto-github.XXXXXX)
  trap "rm -f '$tmpblock'" EXIT

  {
    echo "$MARKER_START"
    echo "# Managed by goto-github — do not edit manually"
    echo "# Updated at $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# Best IP: ${ip}"
    for d in "${domains[@]}"; do
      echo "${ip} ${d}"
    done
    echo "$MARKER_END"
  } > "$tmpblock"

  if grep -q "^${MARKER_START}" "$HOSTS_FILE" 2>/dev/null; then
    log "Replacing existing goto-github block in $HOSTS_FILE with IP $ip"
    if is_macos; then
      sudo sed -i '' "/^${MARKER_START}/,/^${MARKER_END}/d" "$HOSTS_FILE"
    else
      sudo sed -i "/^${MARKER_START}/,/^${MARKER_END}/d" "$HOSTS_FILE"
    fi
  else
    log "Adding goto-github block to $HOSTS_FILE with IP $ip"
  fi

  {
    echo ""
    cat "$tmpblock"
  } | sudo tee -a "$HOSTS_FILE" >/dev/null

  rm -f "$tmpblock"
  trap - EXIT

  write_cache "$CACHE_FILE" "$ip"
  log "Applied $ip to $HOSTS_FILE"
  return 0
}

# ============================================================================
# Flush OS DNS cache after /etc/hosts change.
# Works on both macOS and Linux.
# Usage: flush_dns
# ============================================================================
flush_dns() {
  log "Flushing DNS cache..."
  if is_macos; then
    # macOS: killall mDNSResponder (all macOS versions)
    sudo killall -HUP mDNSResponder 2>/dev/null || true
    # Also flush system DNS resolver cache (macOS 10.12+)
    sudo dscacheutil -flushcache 2>/dev/null || true
    log "DNS cache flushed (macOS)"
  elif is_linux; then
    # Linux: systemd-resolved or nscd
    if command -v resolvectl >/dev/null 2>&1; then
      sudo resolvectl flush-caches 2>/dev/null || true
    elif command -v systemd-resolve >/dev/null 2>&1; then
      sudo systemd-resolve --flush-caches 2>/dev/null || true
    elif command -v nscd >/dev/null 2>&1; then
      sudo nscd -i hosts 2>/dev/null || true
    fi
    # Also restart networking if needed
    log "DNS cache flushed (Linux)"
  fi
}

# ============================================================================
# Verify that the current hosts entry resolves to a working IP.
# Tests the IP currently in /etc/hosts (first github.com entry).
# Usage: verify_hosts
# Returns: 0 if working, 1 if not
# ============================================================================
verify_hosts() {
  local current_ip
  current_ip=$(extract_ip_from_hosts 2>/dev/null)
  if [ -z "$current_ip" ]; then
    log "verify_hosts: no goto-github entry found in $HOSTS_FILE"
    return 1
  fi

  log "Verifying cached IP $current_ip..."
  local result
  result=$(validate_ip_quick "$current_ip" 2>/dev/null)
  if [ $? -eq 0 ]; then
    log "verify_hosts: IP $current_ip is working"
    return 0
  fi

  log "verify_hosts: IP $current_ip is NOT working"
  return 1
}

# ============================================================================
# Show current hosts status information
# Usage: show_status
# Output: formatted status report
# ============================================================================
show_status() {
  echo "=== GoToGitHub Status ==="
  echo ""

  local current_ip
  current_ip=$(extract_ip_from_hosts 2>/dev/null)
  if [ -n "$current_ip" ]; then
    echo "  Current IP: $current_ip"

    local result
    result=$(validate_ip_quick "$current_ip" 2>/dev/null)
    if [ $? -eq 0 ]; then
      echo "  Status:     OK (reachable)"
    else
      echo "  Status:     FAILED (not reachable)"
    fi
  else
    echo "  Current IP: (none)"
    echo "  Status:     Not installed"
  fi
  echo ""

  local cached_ip
  cached_ip=$(read_cache "$CACHE_FILE")
  if [ -n "$cached_ip" ]; then
    echo "  Cached IP:  $cached_ip"
  else
    echo "  Cached IP:  (none)"
  fi

  echo ""
  echo "  Hosts file: $HOSTS_FILE"
  echo "  Log file:   $LOG_FILE"
  echo "  Install:    $INSTALL_DIR"
}

# ============================================================================
# Remove the goto-github section from /etc/hosts
# Usage: clear_hosts
# ============================================================================
clear_hosts() {
  log "Removing goto-github block from $HOSTS_FILE..."
  if grep -q "^${MARKER_START}" "$HOSTS_FILE" 2>/dev/null; then
    # macOS sed uses -i '', Linux sed uses -i without arg
    if is_macos; then
      sudo sed -i '' "/^${MARKER_START}/,/^${MARKER_END}/d" "$HOSTS_FILE"
    else
      sudo sed -i "/^${MARKER_START}/,/^${MARKER_END}/d" "$HOSTS_FILE"
    fi
    # Remove trailing blank lines left by deletion
    if is_macos; then
      sudo sed -i '' -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$HOSTS_FILE" 2>/dev/null || true
    else
      sudo sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$HOSTS_FILE" 2>/dev/null || true
    fi
    log "goto-github block removed from $HOSTS_FILE"
  else
    log "No goto-github block found in $HOSTS_FILE"
  fi
}
