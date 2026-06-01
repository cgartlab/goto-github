#!/usr/bin/env bash
# goto-github constants
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/00-constants.sh"
# DO NOT execute directly.

# Guard against double-sourcing
case "${_GOTO_GITHUB_00_INCLUDED:-}" in
  1) return 0 ;;
esac
readonly _GOTO_GITHUB_00_INCLUDED=1

# Default install directory (overridable via env)
INSTALL_DIR="${INSTALL_DIR:-/opt/goto-github}"
readonly INSTALL_DIR

# Derived paths
readonly BIN_DIR="${INSTALL_DIR}/bin"
readonly LIB_DIR="${INSTALL_DIR}/lib"

# Hosts file
readonly HOSTS_FILE="/etc/hosts"

# Markers for hosts file sections
readonly MARKER_START="# >>> goto-github >>>"
readonly MARKER_END="# <<< goto-github <<<"

# Cache file (last working IP)
readonly CACHE_FILE="$HOME/.goto-github-cache"

# Log file (platform-specific path)
if [ "$(uname)" = "Darwin" ]; then
  readonly LOG_FILE="$HOME/Library/Logs/goto-github.log"
else
  readonly LOG_DIR="$HOME/.local/share/goto-github"
  [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR" 2>/dev/null
  readonly LOG_FILE="$LOG_DIR/goto-github.log"
fi

# Scheduler (launchd on macOS, systemd on Linux)
readonly SCHEDULER_LABEL="com.cgartlab.goto-github"
readonly SCHEDULER_INTERVAL=10800

# Priority IPs (verified-good, return real HTML)
readonly PRIORITY_IPS_0="140.82.112.3"
readonly PRIORITY_IPS_1="140.82.113.3"
readonly PRIORITY_IPS_2="140.82.114.3"
readonly PRIORITY_IPS_3="140.82.113.4"
readonly PRIORITY_IPS_4="140.82.114.4"
readonly PRIORITY_IPS_5="140.82.113.20"
readonly PRIORITY_IPS_6="140.82.114.20"
readonly PRIORITY_IPS_7="140.82.112.20"

# CIDR ranges for GitHub
readonly CIDR_RANGES_0="140.82.112.0/20"
readonly CIDR_RANGES_1="185.199.108.0/22"
readonly CIDR_RANGES_2="192.30.252.0/22"
readonly CIDR_RANGES_3="143.55.64.0/20"

# Core domains
readonly CORE_DOMAINS_0="github.com"
readonly CORE_DOMAINS_1="www.github.com"
readonly CORE_DOMAINS_2="gist.github.com"
readonly CORE_DOMAINS_3="alive.github.com"
readonly CORE_DOMAINS_4="live.github.com"
readonly CORE_DOMAINS_5="central.github.com"
readonly CORE_DOMAINS_6="collector.github.com"
readonly CORE_DOMAINS_7="github.community"

# curl settings
readonly CONCURRENT_BATCH=100
readonly CONNECT_TIMEOUT=3
readonly MAX_TIME=6
readonly MIN_CONTENT_SIZE=100000
readonly MIN_CACHE_TTL=300