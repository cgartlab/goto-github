#!/usr/bin/env bash
# ============================================================================
# GoToGitHub — Direct GitHub access from China via CDN IP scanning
# ============================================================================
# Usage:
#   goto-github run       — scan CDN IPs, update /etc/hosts, flush DNS
#   goto-github status    — show current IP and reachability status
#   goto-github uninstall — remove all GoToGitHub changes from the system
#   goto-github help      — show this help message
# ============================================================================
# Strict mode: fail fast, no hidden errors
set -o nounset
set -o pipefail
# No -o errexit: we handle errors explicitly in scan/apply logic

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
  echo "GoToGitHub: scanning for best GitHub IP..."
  echo ""

  local scan_result
  if scan_result=$(scan_all); then
    # scan_result format: ip:time:size
    local best_ip
    best_ip=$(echo "$scan_result" | cut -d: -f1)
    local response_time
    response_time=$(echo "$scan_result" | cut -d: -f2)
    local content_size
    content_size=$(echo "$scan_result" | cut -d: -f3)

    echo "  Best IP:   $best_ip"
    echo "  Response:  ${response_time}s"
    echo "  Content:   $((content_size / 1024))KB"
    echo ""

    apply_hosts "$best_ip"
    flush_dns

    echo ""
    echo "Done. github.com should now be reachable directly."
    echo "Try: curl -sI https://github.com/ | head -5"
  else
    echo "ERROR: No working GitHub IP found."
    echo "Possible causes:"
    echo "  - Your network is blocking all HTTPS outbound"
    echo "  - The GFW is actively blocking all CDN IPs"
    echo "  - DNS resolution for api.github.com is failing"
    echo ""
    echo "Try running again in a few minutes, or check your internet connection."
    return 1
  fi
}

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
  echo "    status      Show current IP and reachability status"
  echo "    install     Install to $INSTALL_DIR with scheduler"
  echo "    uninstall   Remove all GoToGitHub changes from the system"
  echo "    help        Show this help message"
  echo ""
  echo "  Examples:"
  echo "    goto-github run       # Immediate scan + apply"
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
