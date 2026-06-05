#!/usr/bin/env bash
# goto-github cloud fetch functions
# Source after 00-constants.sh, 01-utils.sh, 04-apply.sh
# Provides: fetch_cloud_ips, cloud_cache_is_valid, cmd_fetch
#
# This module enables the "cloud-first" architecture:
#   GitHub Actions → scans IPs from GitHub's network → publishes to Gist
#   Local machines → fetch pre-verified IPs from Gist → apply to hosts
#   Fallback → traditional local scan if cloud unreachable

# Guard pattern
case "${_GOTO_GITHUB_07_INCLUDED:-}" in
  1) return 0 ;;
esac
readonly _GOTO_GITHUB_07_INCLUDED=1

# ============================================================================
# Fetch pre-verified IP list from the GoToGitHub cloud scan Gist.
# Uses GIST_RAW_URL from 00-constants.sh; falls back to env var if set.
# Usage: fetch_cloud_ips
# Output: JSON string on success, empty on failure
# Returns: 0 on success, 1 on failure
# ============================================================================
fetch_cloud_ips() {
  local url="${GIST_RAW_URL:-}"
  [ -z "$url" ] && return 1

  log "fetch_cloud_ips: fetching from $url"

  local result
  result=$(curl -s --connect-timeout 5 --max-time 10 "$url" 2>/dev/null)

  if [ -z "$result" ]; then
    log "fetch_cloud_ips: curl failed or returned empty response"
    return 1
  fi

  # Basic JSON validation: must contain "servers" and "hosts_block"
  if ! echo "$result" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    assert 'servers' in d
    assert 'hosts_block' in d
    sys.exit(0)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
    log "fetch_cloud_ips: invalid JSON response"
    return 1
  fi

  echo "$result"
  log "fetch_cloud_ips: success"
  return 0
}

# ============================================================================
# Check if the cloud cache is still valid (last fetch < CLOUD_CACHE_TTL seconds)
# Usage: cloud_cache_is_valid
# Returns: 0 if valid, 1 if stale or no cache
# ============================================================================
cloud_cache_is_valid() {
  local cache_file="${CLOUD_CACHE_FILE:-$HOME/.goto-github-cloud-cache}"

  if [ ! -f "$cache_file" ]; then
    return 1
  fi

  local now last_mod age
  now=$(date +%s)
  last_mod=$(stat -f "%m" "$cache_file" 2>/dev/null || stat -c "%Y" "$cache_file" 2>/dev/null || echo 0)
  age=$((now - last_mod))

  if [ "$age" -lt "${CLOUD_CACHE_TTL:-86400}" ]; then
    return 0
  fi

  log "cloud_cache: cache is stale (age=${age}s > ttl=${CLOUD_CACHE_TTL:-86400}s)"
  return 1
}

# ============================================================================
# Write cloud scan result to local cache
# Usage: write_cloud_cache <json_string>
# ============================================================================
write_cloud_cache() {
  local json="$1"
  local cache_file="${CLOUD_CACHE_FILE:-$HOME/.goto-github-cloud-cache}"
  write_cache "$cache_file" "$json"
}

# ============================================================================
# Read local cloud cache
# Usage: read_cloud_cache
# Output: JSON string or empty
# ============================================================================
read_cloud_cache() {
  local cache_file="${CLOUD_CACHE_FILE:-$HOME/.goto-github-cloud-cache}"
  read_cache "$cache_file"
}

# ============================================================================
# Clear local cloud cache
# Usage: clear_cloud_cache
# ============================================================================
clear_cloud_cache() {
  local cache_file="${CLOUD_CACHE_FILE:-$HOME/.goto-github-cloud-cache}"
  clear_cache "$cache_file"
}

# ============================================================================
# Extract best IP for github.com from the cloud scan result
# Usage: extract_ip_from_cloud <json>
# Output: IP address or empty
# ============================================================================
extract_ip_from_cloud() {
  local json="$1"
  [ -z "$json" ] && return 1

  echo "$json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    s = d.get('servers', {})
    gh = s.get('github.com', {})
    if gh.get('mode') == 'hosts':
        print(gh.get('best_ip', ''))
except Exception:
    pass
" 2>/dev/null || return 1
}

# ============================================================================
# Extract hosts block from cloud scan result
# Usage: extract_hosts_block <json>
# Output: hosts block text or empty
# ============================================================================
extract_hosts_block() {
  local json="$1"
  [ -z "$json" ] && return 1

  echo "$json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('hosts_block', ''))
except Exception:
    pass
" 2>/dev/null || return 1
}

# ============================================================================
# DNS-only domains — these should NOT be added to /etc/hosts because GFW
# intercepts their IPs and returns 400 Bad Request.
# Usage: extract_dns_domains <json>
# Output: space-separated domain list or empty
# ============================================================================
extract_dns_domains() {
  local json="$1"
  [ -z "$json" ] && return 1

  echo "$json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    servers = d.get('servers', {})
    dns = [name for name, info in servers.items() if info.get('mode') == 'dns']
    print(' '.join(dns))
except Exception:
    pass
" 2>/dev/null || return 1
}

# ============================================================================
# Apply cloud scan results to /etc/hosts and flush DNS.
# Usage: apply_cloud_hosts <json>
# Returns: 0 on success
# ============================================================================
apply_cloud_hosts() {
  local json="$1"
  [ -z "$json" ] && die "apply_cloud_hosts: no JSON provided"

  local hosts_block dns_domains
  hosts_block=$(extract_hosts_block "$json")
  dns_domains=$(extract_dns_domains "$json")

  if [ -z "$hosts_block" ]; then
    log "apply_cloud_hosts: no hosts block found in cloud data"
    return 1
  fi

  log "apply_cloud_hosts: applying cloud-sourced hosts block"
  echo "$hosts_block"
  echo ""

  # Remove existing goto-github block
  if grep -q "^${MARKER_START}" "$HOSTS_FILE" 2>/dev/null; then
    log "apply_cloud_hosts: removing existing block from $HOSTS_FILE"
    if is_macos; then
      sudo sed -i '' "/^${MARKER_START}/,/^${MARKER_END}/d" "$HOSTS_FILE"
    else
      sudo sed -i "/^${MARKER_START}/,/^${MARKER_END}/d" "$HOSTS_FILE"
    fi
  fi

  # Extract the lines between markers (skip marker lines themselves)
  local clean_block
  clean_block=$(echo "$hosts_block" | grep -v "^#" | sed '/^$/d')

  # Append new block
  {
    echo ""
    echo "$MARKER_START"
    echo "# Managed by GoToGitHub Cloud Scan"
    echo "# Updated at $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# DNS domains (not in hosts): ${dns_domains:-none}"
    echo "$clean_block"
    echo "$MARKER_END"
  } | sudo tee -a "$HOSTS_FILE" >/dev/null

  log "apply_cloud_hosts: applied to $HOSTS_FILE"
  return 0
}

# ============================================================================
# Command: fetch — fetch cloud-sourced IPs, apply to hosts, flush DNS
# This is the primary fast path: no scanning, just apply pre-verified results.
# If cloud fetch fails, suggest running the traditional scan.
# Usage: cmd_fetch
# ============================================================================
cmd_fetch() {
  check_sudo
  # Cloud fetch requires Python3 for JSON parsing; local scan has fallback
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required for cloud fetch (JSON parsing)."
    echo "Falling back to local IP scan..."
    echo "  Run: sudo ${BASH_SOURCE[0]:-$0} run"
    return 1
  fi

  echo "GoToGitHub: fetching cloud-sourced IP list..."
  echo ""

  local json
  json=$(fetch_cloud_ips)
  if [ -z "$json" ]; then
    echo ""
    echo "ERROR: Could not fetch cloud scan results."
    echo ""
    echo "Possible causes:"
    echo "  - No internet connection"
    echo "  - Gist raw URL is unreachable from your network"
    echo "  - No GIST_ID has been configured in the repo secrets"
    echo ""
    echo "Falling back to local IP scan..."
    echo "  Run: sudo ${BASH_SOURCE[0]:-$0} run"
    return 1
  fi

  local best_ip
  best_ip=$(extract_ip_from_cloud "$json")

  if [ -z "$best_ip" ]; then
    echo "WARNING: No valid hosts IP found in cloud scan data."
    echo "Falling back to local IP scan..."
    return 1
  fi

  echo "  Cloud source:  $GIST_RAW_URL"
  echo "  Best IP:       $best_ip"
  echo ""

  apply_cloud_hosts "$json"
  write_cloud_cache "$json"
  flush_dns

  echo ""
  echo "Done. github.com is configured with cloud-verified IPs."
  echo "Run 'goto-github status' to check current state."
  return 0
}
