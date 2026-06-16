#!/usr/bin/env bash
# goto-github validation functions
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/03-validate.sh"
# DO NOT execute directly.

# Guard against double-sourcing
case "${_GOTO_GITHUB_03_INCLUDED:-}" in
  1) return 0 ;;
esac
readonly _GOTO_GITHUB_03_INCLUDED=1

# ============================================================================
# Validate IP by checking if it serves real GitHub content via curl
# Called by 02-scan.sh's validate_ip wrapper
# Usage: validate_ip_from_validate <ip_address>
# Output: OK:ip:time:size on success, nothing on failure
# Returns: 0 on success, 1 on failure
# ============================================================================
validate_ip_from_validate() {
  local ip="$1"
  [ -z "$ip" ] && return 1

  local result
  result=$(retry_curl "https://github.com" "github.com:443:$ip" "$CONNECT_TIMEOUT" "$MAX_TIME")

  [ -z "$result" ] && return 1

  # Parse: code,time,size
  local code time size
  code=$(echo "$result" | cut -d, -f1)
  time=$(echo "$result" | cut -d, -f2)
  size=$(echo "$result" | cut -d, -f3)

  # Check for valid HTTP response
  case "$code" in
    200|301|302) ;;
    *) return 1 ;;
  esac

  # Check minimum content size (silently handles non-numeric size)
  [ "$size" -gt "$MIN_CONTENT_SIZE" ] 2>/dev/null || return 1

  echo "OK:$ip:$time:$size"
  return 0
}

# ============================================================================
# Validate IP by checking if it serves real content for a SPECIFIC domain.
# Used for per-group scanning (download domains, assets, etc.)
# Usage: validate_ip_for_domain <ip_address> <domain> [min_content_size]
#   min_content_size: optional, defaults to MIN_CONTENT_SIZE (100000)
# Output: OK:ip:time:size on success, nothing on failure
# Returns: 0 on success, 1 on failure
# ============================================================================
validate_ip_for_domain() {
  local ip="$1"
  local domain="$2"
  local min_size="${3:-${MIN_CONTENT_SIZE:-100000}}"
  [ -z "$ip" ] || [ -z "$domain" ] && return 1

  local result
  result=$(retry_curl "https://${domain}/" "${domain}:443:${ip}" "$CONNECT_TIMEOUT" "$MAX_TIME")

  [ -z "$result" ] && return 1

  # Parse: code,time,size
  local code time size
  code=$(echo "$result" | cut -d, -f1)
  time=$(echo "$result" | cut -d, -f2)
  size=$(echo "$result" | cut -d, -f3)

  # Check for valid HTTP response
  case "$code" in
    200|301|302) ;;
    *) return 1 ;;
  esac

  # Check minimum content size
  [ "$size" -gt "$min_size" ] 2>/dev/null || return 1

  echo "OK:$ip:$time:$size"
  return 0
}

# ============================================================================
# Quick validation - just check HTTP 200, no content size check
# Usage: validate_ip_quick <ip_address>
# Returns: 0 if HTTP 200, 1 otherwise
# ============================================================================
validate_ip_quick() {
  local ip="$1"
  [ -z "$ip" ] && return 1

  local code
  code=$(curl --resolve "github.com:443:$ip" -s -o /dev/null -w "%{http_code}" --connect-timeout "$CONNECT_TIMEOUT" --max-time "$MAX_TIME" "https://github.com" 2>/dev/null)

  [ "$code" = "200" ]
}

# ============================================================================
# Quick validation for a specific domain — just check HTTP 200.
# Usage: validate_ip_quick_for_domain <ip_address> <domain>
# Returns: 0 if HTTP 200, 1 otherwise
# ============================================================================
validate_ip_quick_for_domain() {
  local ip="$1"
  local domain="$2"
  [ -z "$ip" ] || [ -z "$domain" ] && return 1

  local code
  code=$(curl --resolve "${domain}:443:${ip}" -s -o /dev/null \
    -w "%{http_code}" --connect-timeout "$CONNECT_TIMEOUT" \
    --max-time "$MAX_TIME" "https://${domain}/" 2>/dev/null)

  [ "$code" = "200" ]
}

# ============================================================================
# Extract IP from the goto-github section in /etc/hosts
# Usage: extract_ip_from_hosts [file] [domain]
#   file: optional path to hosts file (defaults to HOSTS_FILE)
#   domain: optional domain to find the IP for (defaults to first IP found)
# Output: IP address or empty if not found
# Returns: 0
# ============================================================================
extract_ip_from_hosts() {
  local hosts_file="${1:-${HOSTS_FILE}}"
  local domain_filter="${2:-}"

  local line
  local in_section=0
  local ip=""

  while IFS= read -r line; do
    case "$line" in
      "$MARKER_START"*)
        in_section=1
        continue
        ;;
      "$MARKER_END"*)
        break
        ;;
    esac

    if [ "$in_section" -eq 1 ]; then
      # Skip comment lines
      case "$line" in '#'*) continue ;; esac

      local first_field
      first_field=$(echo "$line" | awk '{print $1}')

      # Validate IP format
      case "$first_field" in
        [0-9]*.[0-9]*.[0-9]*.[0-9]*) ;;
        *) continue ;;
      esac

      if [ -n "$domain_filter" ]; then
        # Check if domain_filter is in this line's domains
        local line_domains
        line_domains=$(echo "$line" | awk '{$1=""; print $0}')
        if echo "$line_domains" | grep -wq "$domain_filter"; then
          echo "$first_field"
          return 0
        fi
      else
        # Legacy behavior: return first IP found
        echo "$first_field"
        return 0
      fi
    fi
  done < "$hosts_file"

  echo ""
  return 0
}