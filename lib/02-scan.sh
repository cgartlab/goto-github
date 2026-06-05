#!/usr/bin/env bash
# goto-github scanning logic
# Source order: 00-constants.sh -> 02-scan.sh
# (01-utils.sh optional, 03-validate.sh optional - this file is self-contained)

# Guard pattern
case "${_GOTO_GITHUB_02_INCLUDED:-}" in
  1) return 0 ;;
esac
readonly _GOTO_GITHUB_02_INCLUDED=1

# -----------------------------------------------------------------------------
# validate_ip_for_scan - fallback validator using curl
# Returns "OK:ip:time:size" if size > MIN_CONTENT_SIZE, else empty
# Called by scan functions when lib/03-validate.sh is not available
# -----------------------------------------------------------------------------
validate_ip_for_scan() {
  local ip="$1"
  local result
  local http_code time_total size_download

  # Use curl with resolve to test IP directly
  result=$(curl --resolve "github.com:443:$ip" \
    -s -o /dev/null \
    -w "%{http_code},%{time_total},%{size_download}" \
    --connect-timeout "${CONNECT_TIMEOUT:-3}" \
    --max-time "${MAX_TIME:-6}" \
    "https://github.com/" 2>/dev/null)

  # Parse curl output: http_code,time_total,size_download
  http_code="${result%%,*}"
  result="${result#*,}"
  time_total="${result%%,*}"
  size_download="${result##*,}"

  # Validate: HTTP 200 and content size threshold
  if [ -n "$http_code" ] && [ -n "$size_download" ] && [ "$size_download" -gt "${MIN_CONTENT_SIZE:-100000}" ] 2>/dev/null; then
    echo "OK:$ip:$time_total:$size_download"
    return 0
  fi
  return 1
}

# -----------------------------------------------------------------------------
# validate_ip - wrapper that prefers lib/03-validate.sh's function if available
# Falls back to validate_ip_for_scan
# -----------------------------------------------------------------------------
validate_ip() {
  local ip="$1"

  # Check if validate_ip from lib/03-validate.sh exists (function defined)
  if declare -f validate_ip_from_validate >/dev/null 2>&1; then
    validate_ip_from_validate "$ip"
  else
    validate_ip_for_scan "$ip"
  fi
}

# -----------------------------------------------------------------------------
# expand_cidrs_to_ips - expands CIDR_RANGES to individual IPs
# Outputs one IP per line, shuffled for fairness
# Returns 0 always (best-effort)
# -----------------------------------------------------------------------------
expand_cidrs_to_ips() {
  local python_cmd
  local all_ips
  local line

  # Build Python command to expand CIDRs
  python_cmd='import ipaddress, random, sys; '
  python_cmd+='nets = ['
  python_cmd+='"140.82.112.0/20", '
  python_cmd+='"185.199.108.0/22", '
  python_cmd+='"192.30.252.0/22", '
  python_cmd+='"143.55.64.0/20"'
  python_cmd+=']; '
  python_cmd+='all_ips = [str(h) for n in nets for h in ipaddress.IPv4Network(n, strict=False).hosts()]; '
  python_cmd+='random.shuffle(all_ips); '
  python_cmd+='print("\n".join(all_ips))'

  # Try Python3 expansion first
  if all_ips=$(python3 -c "$python_cmd" 2>/dev/null); then
    echo "$all_ips"
    return 0
  fi

  # Fallback: embedded IP list (200 IPs from 140.82.112-127)
  # .3, .4, .20, .21, .22 as last octet across 140.82.112-127
  local fallback_ips
  fallback_ips="
140.82.112.3 140.82.112.4 140.82.112.20 140.82.112.21 140.82.112.22
140.82.113.3 140.82.113.4 140.82.113.20 140.82.113.21 140.82.113.22
140.82.114.3 140.82.114.4 140.82.114.20 140.82.114.21 140.82.114.22
140.82.115.3 140.82.115.4 140.82.115.20 140.82.115.21 140.82.115.22
140.82.116.3 140.82.116.4 140.82.116.20 140.82.116.21 140.82.116.22
140.82.117.3 140.82.117.4 140.82.117.20 140.82.117.21 140.82.117.22
140.82.118.3 140.82.118.4 140.82.118.20 140.82.118.21 140.82.118.22
140.82.119.3 140.82.119.4 140.82.119.20 140.82.119.21 140.82.119.22
140.82.120.3 140.82.120.4 140.82.120.20 140.82.120.21 140.82.120.22
140.82.121.3 140.82.121.4 140.82.121.20 140.82.121.21 140.82.121.22
140.82.122.3 140.82.122.4 140.82.122.20 140.82.122.21 140.82.122.22
140.82.123.3 140.82.123.4 140.82.123.20 140.82.123.21 140.82.123.22
140.82.124.3 140.82.124.4 140.82.124.20 140.82.124.21 140.82.124.22
140.82.125.3 140.82.125.4 140.82.125.20 140.82.125.21 140.82.125.22
140.82.126.3 140.82.126.4 140.82.126.20 140.82.126.21 140.82.126.22
140.82.127.3 140.82.127.4 140.82.127.20 140.82.127.21 140.82.127.22
"

  # Shuffle fallback IPs using $RANDOM
  local shuffled
  shuffled=$(echo "$fallback_ips" | tr ' ' '\n' | grep -v '^$' | while read -r line; do
    echo "$RANDOM:$line"
  done | sort -t: -k1 -n | cut -d: -f2)

  echo "$shuffled"
  return 0
}

# -----------------------------------------------------------------------------
# scan_priority_ips - tests all PRIORITY_IPS in parallel
# Writes results to tmpfile, finds fastest valid IP after all complete
# Returns 0 if found, 1 if none valid
# Output format: ip:time:size or empty
# -----------------------------------------------------------------------------
scan_priority_ips() {
  local tmpfile
  local result
  local best_result
  local line

  tmpfile=$(mktemp -t goto-github.XXXXXX)
  # shellcheck disable=SC2064  # We want expansion at definition time, not signal time
  trap "rm -f '$tmpfile'" EXIT

  # Run all priority IPs in parallel
  for ip in "${PRIORITY_IPS_0}" "${PRIORITY_IPS_1}" "${PRIORITY_IPS_2}" "${PRIORITY_IPS_3}" \
            "${PRIORITY_IPS_4}" "${PRIORITY_IPS_5}" "${PRIORITY_IPS_6}" "${PRIORITY_IPS_7}"; do
    (validate_ip "$ip" >> "$tmpfile") &
  done

  # Wait for all background jobs to complete
  wait

  # Sort by response time (field 3 = time in OK:ip:time:size format)
  best_result=$(sort -t: -k3 -n "$tmpfile" 2>/dev/null | grep '^OK:' | head -1)

  if [ -n "$best_result" ]; then
    # Strip "OK:" prefix for output
    echo "${best_result#OK:}"
    rm -f "$tmpfile"
    trap - EXIT
    return 0
  fi

  rm -f "$tmpfile"
  trap - EXIT
  return 1
}

# -----------------------------------------------------------------------------
# scan_cidr_range - tests all IPs from CIDR expansion in parallel batches
# Uses CONCURRENT_BATCH from constants
# Early-breaks on first hit found
# Returns ip:time:size or empty
# -----------------------------------------------------------------------------
scan_cidr_range() {
  local tmpfile
  local batch_tmp
  local ip
  local result
  local best_result

  tmpfile=$(mktemp -t goto-github.XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -f '$tmpfile'" EXIT

  # Read all IPs from expand_cidrs_to_ips
  local all_ips
  all_ips=$(expand_cidrs_to_ips)

  # Process in batches of CONCURRENT_BATCH (default 100)
  local batch_size="${CONCURRENT_BATCH:-100}"
  local count=0
  local batch=()

  while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    count=$((count + 1))
    batch+=("$ip")

    if [ $count -ge $batch_size ]; then
      for j in "${batch[@]}"; do
        (validate_ip "$j" >> "$tmpfile") &
      done
      wait

      best_result=$(sort -t: -k3 -n "$tmpfile" 2>/dev/null | grep '^OK:' | head -1)
      if [ -n "$best_result" ]; then
        echo "${best_result#OK:}"
        rm -f "$tmpfile"
        trap - EXIT
        return 0
      fi

      count=0
      batch=()
    fi
  done <<< "$all_ips"

  # Process remaining batch
  if [ ${#batch[@]} -gt 0 ]; then
    for j in "${batch[@]}"; do
      (validate_ip "$j" >> "$tmpfile") &
    done
    wait

    best_result=$(sort -t: -k3 -n "$tmpfile" 2>/dev/null | grep '^OK:' | head -1)
    if [ -n "$best_result" ]; then
      echo "${best_result#OK:}"
      rm -f "$tmpfile"
      trap - EXIT
      return 0
    fi
  fi

  rm -f "$tmpfile"
  trap - EXIT
  return 1
}

# -----------------------------------------------------------------------------
# scan_all - tries (1) cloud fetch, (2) priority IPs, (3) CIDR range scan
# Returns the result of whichever succeeded (cloud first)
# Output: ip:time:size or empty
# -----------------------------------------------------------------------------
scan_all() {
  local result

  # Phase 1: Try cloud-sourced IPs from GitHub Actions (fastest, most reliable)
  # Cloud fetch returns JSON with the result; extract best IP in ip:time format
  if declare -f fetch_cloud_ips >/dev/null 2>&1; then
    local cloud_json best_ip best_time best_size
    cloud_json=$(fetch_cloud_ips 2>/dev/null)
    if [ -n "$cloud_json" ]; then
      best_ip=$(echo "$cloud_json" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    s=d.get('servers',{}).get('github.com',{})
    print(s.get('best_ip',''))
except: pass
" 2>/dev/null)
      best_time=$(echo "$cloud_json" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    s=d.get('servers',{}).get('github.com',{})
    print(s.get('best_time','0'))
except: pass
" 2>/dev/null)
      best_size=$(echo "$cloud_json" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    s=d.get('servers',{}).get('github.com',{})
    print(s.get('best_size','100000'))
except: pass
" 2>/dev/null)

      if [ -n "$best_ip" ]; then
        log "scan_all: cloud fetch successful (best IP: $best_ip)"
        write_cloud_cache "$cloud_json"
        echo "${best_ip}:${best_time:-0}:${best_size:-100000}"
        return 0
      fi
    fi
    log "scan_all: cloud fetch unavailable, trying local scan"
  fi

  # Phase 2: Try priority IPs first
  log "scan_all: trying priority IPs"
  if result=$(scan_priority_ips); then
    echo "$result"
    return 0
  fi

  # Phase 3: Fall back to CIDR range scan
  log "scan_all: priority IPs failed, falling back to CIDR scan"
  if result=$(scan_cidr_range); then
    echo "$result"
    return 0
  fi

  return 1
}
