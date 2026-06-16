#!/usr/bin/env bash
# ============================================================================
# GoToGitHub — Direct GitHub access from China via CDN IP scanning
# ============================================================================
# Usage:
#   goto-github run       — scan CDN IPs, update /etc/hosts, flush DNS
#   goto-github fetch     — fetch cloud-sourced IPs from GitHub Actions (fast)
#   goto-github status    — show current IP and reachability status
#   goto-github install   — install to INSTALL_DIR with scheduler
#   goto-github uninstall — remove all GoToGitHub changes from the system
#   goto-github help      — show this help message
# ============================================================================
# Strict mode: fail fast, no hidden errors
set -o nounset
set -o pipefail
set -o errexit

# ============================================================================
# Find project root (this script's directory's parent)
# ============================================================================
_GOTO_GITHUB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly _GOTO_GITHUB_ROOT

# ============================================================================
# Source all library modules in dependency order
# Each module has a guard that prevents double-sourcing
# ============================================================================
for _module in \
  "$_GOTO_GITHUB_ROOT/lib/00-constants.sh" \
  "$_GOTO_GITHUB_ROOT/lib/01-utils.sh" \
  "$_GOTO_GITHUB_ROOT/lib/02-scan.sh" \
  "$_GOTO_GITHUB_ROOT/lib/03-validate.sh" \
  "$_GOTO_GITHUB_ROOT/lib/04-apply.sh" \
  "$_GOTO_GITHUB_ROOT/lib/07-fetch.sh" \
  "$_GOTO_GITHUB_ROOT/lib/05-install.sh" \
  "$_GOTO_GITHUB_ROOT/lib/06-uninstall.sh"; do
  if [ -f "$_module" ]; then
    source "$_module" || die "Failed to source $_module"
  else
    _alt_module="${INSTALL_DIR}/lib/${_module##*/}"
    if [ -f "$_alt_module" ]; then
      source "$_alt_module" || die "Failed to source $_alt_module"
    fi
  fi
done
unset _module _alt_module

# ============================================================================
# Check dependencies early
# ============================================================================
check_deps curl

# ============================================================================
# Command: run — scan + apply + flush
# ============================================================================
cmd_run() {
  check_sudo
  echo "GoToGitHub: scanning for best GitHub IPs..."
  echo ""

  # Phase 1: Try cloud-sourced IPs from GitHub Actions (fastest, most reliable)
  # Cloud fetch returns JSON with per-domain best IPs
  if declare -f fetch_cloud_ips >/dev/null 2>&1; then
    local cloud_json
    cloud_json=$(fetch_cloud_ips 2>/dev/null)
    if [ -n "$cloud_json" ]; then
      local hosts_block
      hosts_block=$(extract_hosts_block "$cloud_json" 2>/dev/null)
      if [ -n "$hosts_block" ]; then
        echo "  Cloud source: available"
        apply_cloud_hosts "$cloud_json" || {
          echo "  Cloud apply failed, falling back to local scan..."
        }
        write_cloud_cache "$cloud_json"
        flush_dns

        echo ""
        echo "Done. All GitHub domains configured with cloud-verified IPs."
        echo "Run 'goto-github status' for details."
        return 0
      fi
    fi
  fi

  echo "  Cloud source: unavailable"
  echo "  Running local scan..."
  echo ""

  # Phase 2: Local multi-group scan
  local valid_ips_file=""
  if valid_ips_file=$(get_valid_ips_file 2>/dev/null); then
    # Got valid IPs — now scan per domain group
    local groups_result=""
    groups_result=$(scan_all_groups "$valid_ips_file" 2>/dev/null)

    # Clean up temp file
    rm -f "$valid_ips_file" 2>/dev/null || true

    if [ -n "$groups_result" ]; then
      echo "  Per-group scan complete:"
      echo ""

      # Show summary of each group's result
      while IFS=: read -r group group_ip group_time group_size; do
        case "$group_ip" in
          DNS_FALLBACK) echo "  - ${group}:     DNS (no pin available)" ;;
          "") ;;
          *) echo "  - ${group}:    ${group_ip} (${group_time}s)" ;;
        esac
      done <<< "$groups_result"
      echo ""

      apply_hosts_multi <<< "$groups_result" || {
        echo "ERROR: Failed to apply hosts"
        return 1
      }
      flush_dns

      echo ""
      echo "Done. GitHub domains are now optimized with per-group IPs."
      echo "Run 'goto-github status' for details."
      return 0
    fi
    rm -f "$valid_ips_file" 2>/dev/null || true
  fi

  echo "ERROR: No working GitHub IP found."
  echo "Possible causes:"
  echo "  - Your network is blocking all HTTPS outbound"
  echo "  - The GFW is actively blocking all CDN IPs"
  echo "  - DNS resolution for api.github.com is failing"
  echo ""
  echo "Try running again in a few minutes, or check your internet connection."
  return 1
}

# ============================================================================
# Command: fetch — cloud-sourced IPs (fast path)
# Delegates to cmd_fetch in lib/07-fetch.sh
# ============================================================================
# (cmd_fetch is defined in lib/07-fetch.sh and sourced above)

# ============================================================================
# Command: status — show current state
# ============================================================================
cmd_status() {
  show_status
}

# ============================================================================
# Command: uninstall — remove everything
# ============================================================================
cmd_uninstall() {
  check_sudo
  uninstall
}

# ============================================================================
# Command: install — set up system scheduling
# ============================================================================
cmd_install() {
  check_sudo
  install "$_GOTO_GITHUB_ROOT"
}

# ============================================================================
# Command: help — usage information
# ============================================================================
cmd_help() {
  banner
  echo ""
  echo "  Usage: goto-github <command>"
  echo ""
  echo "  Commands:"
  echo "    run         Scan CDN IPs and update /etc/hosts (requires sudo)"
  echo "    fetch       Fetch cloud-verified IPs from GitHub Actions (fast)"
  echo "    status      Show current IP and reachability status"
  echo "    install     Install to $INSTALL_DIR with scheduler"
  echo "    uninstall   Remove all GoToGitHub changes from the system"
  echo "    help        Show this help message"
  echo ""
  echo "  Examples:"
  echo "    goto-github run       # Immediate scan + apply"
  echo "    goto-github fetch     # Fast cloud-sourced IP update"
  echo "    goto-github status    # Check current status"
  echo "    goto-github install   # Install + scheduler setup"
  echo "    goto-github uninstall # Full removal"
  echo ""
}

# ============================================================================
# Dispatch
# ============================================================================
main() {
  case "${1:-help}" in
    run)
      cmd_run
      ;;
    fetch)
      cmd_fetch
      ;;
    status)
      cmd_status
      ;;
    install)
      cmd_install
      ;;
    uninstall)
      cmd_uninstall
      ;;
    help|--help|-h)
      cmd_help
      ;;
    *)
      echo "Unknown command: $1"
      echo "Usage: goto-github <run|status|install|uninstall|help>"
      exit 1
      ;;
  esac
}

main "$@"
