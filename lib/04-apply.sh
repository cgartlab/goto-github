#!/usr/bin/env bash
# goto-github apply functions
# Source after 00-constants.sh and 01-utils.sh
# Provides: apply_hosts, flush_dns, verify_hosts, clear_hosts

# Guard pattern
case "${_GOTO_GITHUB_04_INCLUDED:-}" in
  1) return 0 ;;
esac
readonly _GOTO_GITHUB_04_INCLUDED=1

# ============================================================================
# Apply single IP to all CORE domains in /etc/hosts
# DEPRECATED: Use apply_hosts_multi() for multi-group optimization
# Kept for backward compatibility with cmd_fetch cloud path
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

  # Skip DNS-only domains (they return 400 when pinned to CDN IPs)
  local filtered_domains=()
  local d
  for d in "${domains[@]}"; do
    local skip=0
    local dd
    for dd in ${DNS_DOMAINS:-}; do
      if [ "$d" = "$dd" ]; then
        skip=1
        break
      fi
    done
    [ "$skip" -eq 0 ] && filtered_domains+=("$d")
  done

  local tmpblock
  tmpblock=$(mktemp -t goto-github.XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -f '$tmpblock'" EXIT

  {
    echo "$MARKER_START"
    echo "# Managed by goto-github — do not edit manually"
    echo "# Updated at $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# Best IP: ${ip}"
    for d in "${filtered_domains[@]}"; do
      echo "${ip} ${d}"
    done
    echo "# DNS domains (not pinned): ${DNS_DOMAINS}"
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
# Apply per-domain-group IPs to /etc/hosts
# Usage: apply_hosts_multi <groups_result_file>
#   groups_result_file format: "GROUP:IP:TIME:SIZE" lines
#     DNS_FALLBACK entries are skipped (those groups use normal DNS)
#   Writes multiple IP lines to /etc/hosts (one IP per domain group)
# ============================================================================
apply_hosts_multi() {
  local groups_file="$1"
  [ -z "$groups_file" ] && die "apply_hosts_multi: no groups file provided"
  [ ! -f "$groups_file" ] && die "apply_hosts_multi: groups file not found: $groups_file"

  local tmpblock
  tmpblock=$(mktemp -t goto-github.XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -f '$tmpblock'" EXIT

  {
    echo "$MARKER_START"
    echo "# Managed by goto-github — do not edit manually"
    echo "# Updated at $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# Download acceleration: multi-group IP optimization enabled"

    # Process each group
    while IFS=: read -r group_name group_ip group_time group_size; do
      # Skip DNS fallback groups and empty lines
      [ -z "$group_name" ] && continue
      [ "$group_ip" = "DNS_FALLBACK" ] && continue
      [ -z "$group_ip" ] && continue

      # Map group name to domain variable and get domains
      local domains
      case "$group_name" in
        CORE)       domains="$DOMAIN_GROUP_CORE" ;;
        RAW)        domains="$DOMAIN_GROUP_RAW" ;;
        CODELOAD)   domains="$DOMAIN_GROUP_CODELOAD" ;;
        OBJECTS)    domains="$DOMAIN_GROUP_OBJECTS" ;;
        ASSETS)     domains="$DOMAIN_GROUP_ASSETS" ;;
        *) continue ;;
      esac

      if [ -n "$domains" ]; then
        echo "${group_ip}    ${domains}"
      fi
    done < "$groups_file"

    echo "# DNS domains (not pinned): ${DNS_DOMAINS:-none}"
    echo "$MARKER_END"
  } > "$tmpblock"

  # Remove existing goto-github block
  if grep -q "^${MARKER_START}" "$HOSTS_FILE" 2>/dev/null; then
    log "Replacing existing goto-github block in $HOSTS_FILE with multi-IP config"
    if is_macos; then
      sudo sed -i '' "/^${MARKER_START}/,/^${MARKER_END}/d" "$HOSTS_FILE"
    else
      sudo sed -i "/^${MARKER_START}/,/^${MARKER_END}/d" "$HOSTS_FILE"
    fi
  else
    log "Adding goto-github multi-IP block to $HOSTS_FILE"
  fi

  # Append new block
  {
    echo ""
    cat "$tmpblock"
  } | sudo tee -a "$HOSTS_FILE" >/dev/null

  rm -f "$tmpblock"
  trap - EXIT

  # Write multi-IP cache
  write_multi_cache "$groups_file"
  log "Applied multi-IP hosts to $HOSTS_FILE"
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
  if validate_ip_quick "$current_ip" 2>/dev/null; then
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

  # Try to show per-group IPs from cache
  if [ -f "$CACHE_FILE" ]; then
    local has_multi_cache=0
    while IFS=: read -r domain ip time size; do
      [ -z "$domain" ] && continue
      has_multi_cache=1
      local domain_status="?"
      if validate_ip_quick_for_domain "$ip" "$domain" 2>/dev/null; then
        domain_status="OK"
      else
        domain_status="FAIL"
      fi
      printf "  %-45s %-16s %s\n" "$domain" "$ip" "$domain_status"
    done < "$CACHE_FILE"

    if [ "$has_multi_cache" -eq 1 ]; then
      echo ""
    fi
  fi

  # Also show the /etc/hosts applied IP (first one found)
  local current_ip
  current_ip=$(extract_ip_from_hosts 2>/dev/null)
  if [ -n "$current_ip" ]; then
    echo "  Current /etc/hosts primary IP: $current_ip"
    if validate_ip_quick "$current_ip" 2>/dev/null; then
      echo "  Status:     OK (reachable)"
    else
      echo "  Status:     FAILED (not reachable)"
    fi
  else
    echo "  Current IP: (none)"
    echo "  Status:     Not installed"
  fi
  echo ""

  # Cloud scan info
  local cloud_source="(none)"
  if [ -f "$CLOUD_CACHE_FILE" ]; then
    cloud_source=$(head -1 "$CLOUD_CACHE_FILE" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('updated_at','(stale)'))
except:
    print('(stale)')
" 2>/dev/null || echo "(stale)")
  fi
  echo "  Cloud scan: $cloud_source"
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
