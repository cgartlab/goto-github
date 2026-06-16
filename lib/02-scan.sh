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

  # Use retry_curl with backoff to handle transient network failures
  result=$(retry_curl "https://github.com/" "github.com:443:$ip" \
    "${CONNECT_TIMEOUT:-3}" "${MAX_TIME:-6}")

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

  # Check if lib/03-validate.sh was loaded via guard variable
  if [ "${_GOTO_GITHUB_03_INCLUDED:-0}" -eq 1 ]; then
    validate_ip_from_validate "$ip"
  else
    validate_ip_for_scan "$ip"
  fi
}

# -----------------------------------------------------------------------------
# validate_ip_for_domain - validate an IP against a specific domain
# Usage: validate_ip_for_domain <ip> <domain> [min_content_size]
# Returns "OK:ip:time:size" if valid, empty otherwise
# -----------------------------------------------------------------------------
validate_ip_for_domain() {
  local ip="$1"
  local domain="$2"
  local min_size="${3:-${MIN_CONTENT_SIZE:-100000}}"
  local result
  local http_code time_total size_download

  result=$(retry_curl "https://${domain}/" "${domain}:443:${ip}" \
    "${CONNECT_TIMEOUT:-3}" "${MAX_TIME:-6}")

  http_code="${result%%,*}"
  result="${result#*,}"
  time_total="${result%%,*}"
  size_download="${result##*,}"

  if [ -n "$http_code" ] && [ -n "$size_download" ] && [ "$size_download" -gt "$min_size" ] 2>/dev/null; then
    echo "OK:${ip}:${time_total}:${size_download}"
    return 0
  fi
  return 1
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
# scan_priority_ips_all - runs all priority IPs in parallel, returns ALL valid results
# Output: each line "OK:ip:time:size" (sorted by time, fastest first)
#         Returns 0 if any valid, 1 if none
# -----------------------------------------------------------------------------
scan_priority_ips_all() {
  local tmpfile
  tmpfile=$(mktemp -t goto-github.XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -f '$tmpfile'" EXIT

  # Run all priority IPs in parallel
  for ip in "${PRIORITY_IPS_0}" "${PRIORITY_IPS_1}" "${PRIORITY_IPS_2}" "${PRIORITY_IPS_3}" \
            "${PRIORITY_IPS_4}" "${PRIORITY_IPS_5}" "${PRIORITY_IPS_6}" "${PRIORITY_IPS_7}"; do
    (validate_ip "$ip" >> "$tmpfile") &
  done
  wait

  # Return all valid results sorted by time
  local count
  count=$(grep -c '^OK:' "$tmpfile" 2>/dev/null || echo 0)
  if [ "$count" -gt 0 ]; then
    sort -t: -k3 -n "$tmpfile" 2>/dev/null | grep '^OK:'
    rm -f "$tmpfile"
    trap - EXIT
    return 0
  fi

  rm -f "$tmpfile"
  trap - EXIT
  return 1
}

# -----------------------------------------------------------------------------
# scan_priority_ips - tests all PRIORITY_IPS in parallel, returns fastest valid
# Output format: ip:time:size or empty
# -----------------------------------------------------------------------------
scan_priority_ips() {
  local result
  result=$(scan_priority_ips_all | head -1)
  if [ -n "$result" ]; then
    echo "${result#OK:}"
    return 0
  fi
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

    if [ "$count" -ge "$batch_size" ]; then
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
      IFS='|' read -r best_ip best_time best_size <<< "$(echo "$cloud_json" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    s=d.get('servers',{}).get('github.com',{})
    print(s.get('best_ip','') + '|' + str(s.get('best_time','0')) + '|' + str(s.get('best_size','100000')))
except: pass
" 2>/dev/null)"

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
  local priority_best="" priority_time=""
  priority_best=$(scan_priority_ips)
  if [ -n "$priority_best" ]; then
    priority_time=$(echo "$priority_best" | cut -d: -f2)
    log "scan_all: priority IPs fastest: ${priority_time}s"
  fi

  # Phase 3: If priority returned few valid results, extend to CIDR scan
  local cidr_best="" cidr_time=""
  local priority_count
  priority_count=$(scan_priority_ips_all 2>/dev/null | grep -c '^OK:' || echo 0)
  if [ -z "$priority_best" ] || [ "$priority_count" -lt "${MIN_PRIORITY_HITS:-3}" ]; then
    log "scan_all: extending to CIDR scan (priority hits=$priority_count < MIN_PRIORITY_HITS=${MIN_PRIORITY_HITS:-3})"
    if cidr_best=$(scan_cidr_range); then
      cidr_time=$(echo "$cidr_best" | cut -d: -f2)
      log "scan_all: CIDR fastest: ${cidr_time}s"
    fi
  fi

  # Pick the better of the two
  local best_result=""
  if [ -n "$priority_best" ] && [ -n "$cidr_best" ]; then
    # Both available: pick the faster one
    if [ "$(echo "$priority_time < $cidr_time" | bc -l 2>/dev/null)" = "1" ]; then
      best_result="$priority_best"
      log "scan_all: priority wins (${priority_time}s < ${cidr_time}s)"
    else
      best_result="$cidr_best"
      log "scan_all: CIDR wins (${cidr_time}s <= ${priority_time}s)"
    fi
  elif [ -n "$priority_best" ]; then
    best_result="$priority_best"
  elif [ -n "$cidr_best" ]; then
    best_result="$cidr_best"
  fi

  if [ -n "$best_result" ]; then
    echo "$best_result"
    return 0
  fi

  return 1
}

# -----------------------------------------------------------------------------
# get_valid_ips_file — run scan, return path to temp file with all valid IPs
# Output: path to temp file, each line "ip:time:size"
#         Caller must rm the file when done (trap is set)
# -----------------------------------------------------------------------------
get_valid_ips_file() {
  local tmpfile
  tmpfile=$(mktemp -t goto-github-ips.XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -f '$tmpfile'" EXIT

  # Run priority IPs in parallel, collect all valid results
  local priority_tmp
  priority_tmp=$(mktemp -t goto-github-prio.XXXXXX)
  for ip in "${PRIORITY_IPS_0}" "${PRIORITY_IPS_1}" "${PRIORITY_IPS_2}" "${PRIORITY_IPS_3}" \
            "${PRIORITY_IPS_4}" "${PRIORITY_IPS_5}" "${PRIORITY_IPS_6}" "${PRIORITY_IPS_7}"; do
    (validate_ip "$ip" >> "$priority_tmp") &
  done
  wait

  local priority_count
  priority_count=$(grep -c '^OK:' "$priority_tmp" 2>/dev/null || echo 0)

  # If we have enough priority hits, use them
  if [ "$priority_count" -ge "${MIN_PRIORITY_HITS:-3}" ]; then
    grep '^OK:' "$priority_tmp" | sed 's/^OK://' | sort -t: -k2 -n > "$tmpfile"
    rm -f "$priority_tmp"
    trap - EXIT
    echo "$tmpfile"
    return 0
  fi

  # Otherwise, expand CIDR and scan more
  rm -f "$priority_tmp"
  local all_ips
  all_ips=$(expand_cidrs_to_ips)

  local batch_size="${CONCURRENT_BATCH:-100}"
  local count=0
  local batch=()

  while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    count=$((count + 1))
    batch+=("$ip")

    if [ "$count" -ge "$batch_size" ]; then
      for j in "${batch[@]}"; do
        (validate_ip "$j" >> "$tmpfile") &
      done
      wait

      # Early break if we have enough
      local found
      found=$(grep -c '^OK:' "$tmpfile" 2>/dev/null || echo 0)
      if [ "$found" -ge 10 ]; then
        sort -t: -k2 -n "$tmpfile" | grep '^OK:' | sed 's/^OK://' > "${tmpfile}.sorted"
        mv "${tmpfile}.sorted" "$tmpfile"
        trap - EXIT
        echo "$tmpfile"
        return 0
      fi
      count=0
      batch=()
    fi
  done <<< "$all_ips"

  # Process remaining batch
  if [ "${#batch[@]}" -gt 0 ]; then
    for j in "${batch[@]}"; do
      (validate_ip "$j" >> "$tmpfile") &
    done
    wait
  fi

  if [ -s "$tmpfile" ]; then
    sort -t: -k2 -n "$tmpfile" | grep '^OK:' | sed 's/^OK://' > "${tmpfile}.sorted"
    mv "${tmpfile}.sorted" "$tmpfile"
  fi

  trap - EXIT
  echo "$tmpfile"
  return 0
}

# -----------------------------------------------------------------------------
# scan_domain_group — test candidate IPs against a specific domain
# Usage: scan_domain_group <domain> <ip_list_file> [min_content_size]
#   ip_list_file: path to file with "ip:time:size" lines (from get_valid_ips_file)
#   min_content_size: optional, defaults to MIN_CONTENT_SIZE for CORE, 1024 for others
# Output: "OK:ip:time:size" lines sorted by time (fastest first)
# Returns: 0 if any valid, 1 if none
# -----------------------------------------------------------------------------
scan_domain_group() {
  local domain="$1"
  local ip_list_file="$2"
  local min_size="${3:-${MIN_CONTENT_SIZE:-100000}}"

  [ -z "$domain" ] || [ -z "$ip_list_file" ] && return 1
  [ ! -f "$ip_list_file" ] && return 1

  local tmpfile
  tmpfile=$(mktemp -t goto-github-group.XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -f '$tmpfile'" EXIT

  local running=0
  while IFS=: read -r ip time size; do
    [ -z "$ip" ] && continue
    (validate_ip_for_domain "$ip" "$domain" "$min_size" >> "$tmpfile") &

    running=$((running + 1))
    if [ "$running" -ge "${CONCURRENT_BATCH:-100}" ]; then
      wait
      running=0
    fi
  done < "$ip_list_file"
  wait

  local count
  count=$(grep -c '^OK:' "$tmpfile" 2>/dev/null || echo 0)
  if [ "$count" -gt 0 ]; then
    sort -t: -k3 -n "$tmpfile" 2>/dev/null | grep '^OK:'
    rm -f "$tmpfile"
    trap - EXIT
    return 0
  fi

  rm -f "$tmpfile"
  trap - EXIT
  return 1
}

# -----------------------------------------------------------------------------
# scan_all_groups — scan all domain groups from candidate IP file
# Usage: scan_all_groups <ip_list_file>
# Output: "GROUP:IP:TIME:SIZE" lines per group (GROUP is name, IP may be DNS_FALLBACK)
# Returns: 0 (always succeeds, groups with no valid IP get DNS_FALLBACK marker)
# -----------------------------------------------------------------------------
scan_all_groups() {
  local ip_list_file="$1"
  [ -z "$ip_list_file" ] && return 1

  local result_file
  result_file=$(mktemp -t goto-github-groups.XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -f '$result_file'" EXIT

  # Define groups: GROUP_NAME:DOMAIN:MIN_CONTENT_SIZE
  for group_info in \
    "CORE:github.com:${MIN_CONTENT_SIZE:-100000}" \
    "RAW:raw.githubusercontent.com:1024" \
    "CODELOAD:codeload.github.com:1024" \
    "OBJECTS:objects.githubusercontent.com:1024" \
    "ASSETS:github.githubassets.com:1024"; do

    local group_name="${group_info%%:*}"
    local remainder="${group_info#*:}"
    local group_domain="${remainder%%:*}"
    local group_min_size="${remainder##*:}"

    local result
    result=$(scan_domain_group "$group_domain" "$ip_list_file" "$group_min_size")

    if [ -n "$result" ]; then
      local best_line
      best_line=$(echo "$result" | head -1)
      # Strip "OK:" prefix
      echo "${group_name}:${best_line#OK:}"
    else
      echo "${group_name}:DNS_FALLBACK:::"
    fi
  done > "$result_file"

  cat "$result_file"
  rm -f "$result_file"
  trap - EXIT
  return 0
}
