#!/usr/bin/env bash
# goto-github uninstallation functions
# Source after 00-constants.sh, 01-utils.sh, 04-apply.sh
# Provides: uninstall_scheduler, uninstall_sudoers, uninstall_files, uninstall

# Guard pattern
case "${_GOTO_GITHUB_06_INCLUDED:-}" in
  1) return 0 ;;
esac
readonly _GOTO_GITHUB_06_INCLUDED=1

# ============================================================================
# Remove scheduler configuration
# macOS: unload launchd plist + remove file
# Linux: stop/disable systemd timer + remove unit files
# Usage: uninstall_scheduler
# ============================================================================
uninstall_scheduler() {
  if is_macos; then
    uninstall_launchd
  elif is_linux; then
    uninstall_systemd
  fi
}

# ============================================================================
# Remove macOS launchd plist
# Usage: uninstall_launchd
# ============================================================================
uninstall_launchd() {
  local plist_dest="$HOME/Library/LaunchAgents/$SCHEDULER_LABEL.plist"
  if [ -f "$plist_dest" ]; then
    launchctl unload "$plist_dest" 2>/dev/null || true
    rm -f "$plist_dest"
    log "launchd plist removed: $plist_dest"
    echo "  Removed:   $plist_dest"
  fi
}

# ============================================================================
# Remove Linux systemd units
# Usage: uninstall_systemd
# ============================================================================
uninstall_systemd() {
  local service_file="/etc/systemd/system/$SCHEDULER_LABEL.service"
  local timer_file="/etc/systemd/system/$SCHEDULER_LABEL.timer"

  if [ -f "$timer_file" ]; then
    sudo systemctl stop "$SCHEDULER_LABEL.timer" 2>/dev/null || true
    sudo systemctl disable "$SCHEDULER_LABEL.timer" 2>/dev/null || true
  fi

  if [ -f "$service_file" ]; then
    sudo rm -f "$service_file"
  fi
  if [ -f "$timer_file" ]; then
    sudo rm -f "$timer_file"
  fi

  sudo systemctl daemon-reload 2>/dev/null || true
  log "systemd units removed"
  echo "  Removed:   systemd service + timer"
}

# ============================================================================
# Remove symlink and install directory
# Usage: uninstall_files
# ============================================================================
uninstall_files() {
  # Remove symlink
  local symlink="/usr/local/bin/goto-github"
  if [ -L "$symlink" ]; then
    sudo rm -f "$symlink"
    log "symlink removed: $symlink"
    echo "  Removed:   $symlink"
  fi

  # Remove install directory (safety check)
  if [ -d "$INSTALL_DIR" ]; then
    case "$INSTALL_DIR" in
      /opt/goto-github|/usr/local/goto-github) ;;  # Safe paths
      *) die "Refusing to rm -rf: INSTALL_DIR=$INSTALL_DIR" ;;
    esac
    sudo rm -rf "$INSTALL_DIR"
    log "install directory removed: $INSTALL_DIR"
    echo "  Removed:   $INSTALL_DIR/"
  fi
}

# ============================================================================
# Remove passwordless sudoers entry (macOS only)
# Usage: uninstall_sudoers
# ============================================================================
uninstall_sudoers() {
  if ! is_macos; then
    return 0
  fi

  local sudoers_file="/etc/sudoers.d/goto-github"
  if [ -f "$sudoers_file" ]; then
    sudo rm -f "$sudoers_file"
    log "sudoers entry removed: $sudoers_file"
    echo "  Removed:   $sudoers_file"
  fi
}

# ============================================================================
# Remove cache file
# Usage: uninstall_cache
# ============================================================================
uninstall_cache() {
  if [ -f "$CACHE_FILE" ]; then
    rm -f "$CACHE_FILE"
    log "cache file removed: $CACHE_FILE"
    echo "  Removed:   $CACHE_FILE"
  fi
}

# ============================================================================
# Main uninstall entry point
# Cleans up everything: hosts, scheduler, files, sudoers, cache
# Usage: uninstall
# ============================================================================
uninstall() {
  echo ""
  echo "Uninstalling GoToGitHub..."
  echo ""

  clear_hosts
  flush_dns
  uninstall_scheduler
  uninstall_files
  uninstall_sudoers
  uninstall_cache

  echo ""
  echo "  GoToGitHub has been fully removed."
  echo "  /etc/hosts has been cleaned up."
  echo ""
}
