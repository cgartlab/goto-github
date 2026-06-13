#!/usr/bin/env bash
# goto-github utility functions
# Source after 00-constants.sh, before 02-scan.sh
# Provides: log, die, check_deps, is_macos, is_linux, check_sudo

# Guard pattern
case "${_GOTO_GITHUB_01_INCLUDED:-}" in
  1) return 0 ;;
esac
readonly _GOTO_GITHUB_01_INCLUDED=1

# ============================================================================
# Write a timestamped log message to LOG_FILE
# Usage: log "message" [message...]
# Globals: LOG_FILE
# ============================================================================
log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  {
    printf "[%s] " "$timestamp"
    printf "%s " "$@"
    printf "\n"
  } >> "$LOG_FILE" 2>/dev/null || true
}

# ============================================================================
# Print error and exit
# Usage: die "error message"
# ============================================================================
die() {
  echo "ERROR: $*" >&2
  log "FATAL: $*"
  # In interactive shell, return error instead of exiting
  if [[ $- == *i* ]]; then
    return 1
  else
    exit 1
  fi
}

# ============================================================================
# Check that required commands are available
# Usage: check_deps curl python3
# Exits with error if any missing
# ============================================================================
check_deps() {
  local missing=""
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing="$missing $cmd"
    fi
  done
  if [ -n "$missing" ]; then
    die "Missing required commands:$missing"
  fi
}

# ============================================================================
# Detect if running on macOS
# Returns: 0 if macOS, 1 otherwise
# ============================================================================
is_macos() {
  [ "$(uname)" = "Darwin" ]
}

# ============================================================================
# Detect if running on Linux
# Returns: 0 if Linux, 1 otherwise
# ============================================================================
is_linux() {
  [ "$(uname)" = "Linux" ]
}

# ============================================================================
# Check if we have sudo access (required for /etc/hosts modification)
# Usage: check_sudo
# Exits with error if no sudo
# ============================================================================
check_sudo() {
  if ! sudo -n true 2>/dev/null; then
    echo "This command requires sudo access to modify /etc/hosts."
    if sudo -v; then
      echo "Authorization granted."
    else
      die "sudo authentication failed"
    fi
  fi
}

# ============================================================================
# Read a single-line value from a config/cache file
# Usage: read_cache <file>
# Output: line content or empty
# ============================================================================
read_cache() {
  local file="$1"
  if [ -f "$file" ] && [ -r "$file" ]; then
    head -1 "$file"
  fi
}

# ============================================================================
# Write a value to a cache file (atomically)
# Usage: write_cache <file> <value>
# ============================================================================
write_cache() {
  local file="$1"
  local value="$2"
  local dir
  dir=$(dirname "$file")
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 1
  printf "%s\n" "$value" > "$file" 2>/dev/null || return 1
  return 0
}

# ============================================================================
# Clear a cache file
# Usage: clear_cache <file>
# ============================================================================
clear_cache() {
  local file="$1"
  rm -f "$file" 2>/dev/null || true
}

# ============================================================================
# Print a banner for CLI output
# Usage: banner
# ============================================================================
banner() {
  echo "  ┌─┐ ________ _______ _________ _______ ________ ─┐"
  echo "  │ ││   __  \\  _  \\  \\___  //  ____|  _  \\  ___│ │"
  echo "  │ ││  |  \\  \\ |_|  \\   /  /|  /    | |_|  \\___  \\ │"
  echo "  │ ││  |__/  /  _  /  /  /_ |  \\___ |  _  /   __)  │"
  echo "  │ ││_______/|_| \\_\\ /_____/ \\______|_| \\_\\______/ │"
  echo "  └─┘───────────────────────────────────────────────┘"
}

# ============================================================================
# Retry curl with linear backoff.
# Usage: retry_curl <url> <resolve_host> <connect_timeout> <max_time>
#   resolve_host: e.g. "github.com:443:$ip" or empty
# Outputs: last non-empty stdout, or empty on all failures
# Globals used: SCAN_RETRY_COUNT, SCAN_RETRY_DELAY
# ============================================================================
retry_curl() {
  local url="$1"
  local resolve_host="$2"
  local connect_timeout="${3:-${CONNECT_TIMEOUT:-3}}"
  local max_time="${4:-${MAX_TIME:-6}}"
  local retries="${SCAN_RETRY_COUNT:-2}"
  local delay="${SCAN_RETRY_DELAY:-1}"

  local resolve_arg=""
  if [ -n "$resolve_host" ]; then
    resolve_arg="--resolve $resolve_host"
  fi

  local result=""
  local attempt=0

  while [ "$attempt" -le "$retries" ]; do
    if [ -n "$resolve_arg" ]; then
      result=$(curl -s -o /dev/null \
        --resolve "$resolve_host" \
        -w "%{http_code},%{time_total},%{size_download}" \
        --connect-timeout "$connect_timeout" \
        --max-time "$max_time" \
        "$url" 2>/dev/null)
    else
      result=$(curl -s -o /dev/null \
        -w "%{http_code},%{time_total},%{size_download}" \
        --connect-timeout "$connect_timeout" \
        --max-time "$max_time" \
        "$url" 2>/dev/null)
    fi

    if [ -n "$result" ]; then
      echo "$result"
      return 0
    fi

    attempt=$((attempt + 1))
    [ "$attempt" -le "$retries" ] && sleep "$delay"
  done

  # All attempts failed
  echo ""
  return 1
}
