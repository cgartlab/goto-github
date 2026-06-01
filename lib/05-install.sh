# goto-github installation functions
# Source after 00-constants.sh, 01-utils.sh, 04-apply.sh
# Provides: install_files, install_scheduler, install_sudoers, install

# Guard pattern
case "${_GOTO_GITHUB_05_INCLUDED:-}" in
  *1*) return 0 ;;
esac
readonly _GOTO_GITHUB_05_INCLUDED=1

# Source directory detection — where the repo/scripts live at install time
_GOTO_GITHUB_SRC=""
detect_src_dir() {
  _GOTO_GITHUB_SRC=$(dirname "$(dirname "$(realpath "$0" 2>/dev/null || echo "$0")")")
}

# ============================================================================
# Copy bin/ and lib/ files to INSTALL_DIR
# Usage: install_files <src_dir>
# src_dir: path to the goto-github repository root
# ============================================================================
install_files() {
  local src_dir="$1"
  [ -d "$src_dir/bin" ] || die "install_files: missing bin/ in $src_dir"
  [ -d "$src_dir/lib" ] || die "install_files: missing lib/ in $src_dir"

  log "Installing files to $INSTALL_DIR..."
  sudo mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/lib" 2>/dev/null
  sudo cp "$src_dir/bin/goto-github.sh" "$INSTALL_DIR/bin/"
  sudo cp "$src_dir/lib/"*.sh "$INSTALL_DIR/lib/"
  sudo chmod 755 "$INSTALL_DIR/bin/goto-github.sh"
  sudo chmod 644 "$INSTALL_DIR/lib/"*.sh

  # Create symlink from /usr/local/bin
  sudo ln -sf "$INSTALL_DIR/bin/goto-github.sh" /usr/local/bin/goto-github 2>/dev/null || true

  log "Files installed to $INSTALL_DIR"
  echo "  Installed: $INSTALL_DIR/bin/goto-github.sh"
  echo "  Symlink:   /usr/local/bin/goto-github"
}

# ============================================================================
# Install scheduler for periodic updates
# macOS: launchd plist
# Linux: systemd service + timer
# Usage: install_scheduler
# ============================================================================
install_scheduler() {
  if is_macos; then
    install_launchd
  elif is_linux; then
    install_systemd
  else
    log "install_scheduler: unsupported platform, skipping scheduler"
    echo "  Warning: unsupported platform, scheduler not installed"
  fi
}

# ============================================================================
# Install macOS launchd plist
# Uses template from contrib/macos/ or generates inline
# Usage: install_launchd
# ============================================================================
install_launchd() {
  local plist_dest="$HOME/Library/LaunchAgents/$SCHEDULER_LABEL.plist"

  # Check if a template exists next to the script
  local template
  template="$(dirname "$(dirname "$0")")/contrib/macos/$SCHEDULER_LABEL.plist"
  if [ -f "$template" ]; then
    sudo cp "$template" "$plist_dest"
  else
    # Generate plist inline
    /usr/libexec/PlistBuddy -c "Add Label string $SCHEDULER_LABEL" "$plist_dest" 2>/dev/null || {
      # Fallback: write plist directly
      cat > /tmp/goto-github.plist <<-PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$SCHEDULER_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_DIR/bin/goto-github.sh</string>
        <string>run</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>$SCHEDULER_INTERVAL</integer>
    <key>StandardOutPath</key>
    <string>/var/log/goto-github.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/goto-github.err</string>
</dict>
</plist>
PLIST
      sudo cp /tmp/goto-github.plist "$plist_dest"
      rm -f /tmp/goto-github.plist
    }
  fi

  sudo chmod 644 "$plist_dest"
  launchctl load "$plist_dest" 2>/dev/null || true
  log "launchd plist installed: $plist_dest"
  echo "  Launchd:   $plist_dest (interval: ${SCHEDULER_INTERVAL}s)"
}

# ============================================================================
# Install Linux systemd service + timer
# Uses templates from contrib/linux/ or generates inline
# Usage: install_systemd
# ============================================================================
install_systemd() {
  local service_file="/etc/systemd/system/$SCHEDULER_LABEL.service"
  local timer_file="/etc/systemd/system/$SCHEDULER_LABEL.timer"

  # Check for template
  local service_template
  local timer_template
  service_template="$(dirname "$(dirname "$0")")/contrib/linux/$SCHEDULER_LABEL.service"
  timer_template="$(dirname "$(dirname "$0")")/contrib/linux/$SCHEDULER_LABEL.timer"

  if [ -f "$service_template" ] && [ -f "$timer_template" ]; then
    sudo cp "$service_template" "$service_file"
    sudo cp "$timer_template" "$timer_file"
    sudo sed -i "s|/opt/goto-github|$INSTALL_DIR|g" "$service_file" "$timer_file"
  else
    # Write service file inline
    cat > /tmp/goto-github.service <<-SVC
[Unit]
Description=GoToGitHub - run GitHub hosts scan once
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/bin/goto-github.sh run
StandardOutput=append:/var/log/goto-github.log
StandardError=append:/var/log/goto-github.log
Nice=10
SVC
    sudo cp /tmp/goto-github.service "$service_file"

    # Write timer file
    cat > /tmp/goto-github.timer <<-TMR
[Unit]
Description=GoToGitHub - periodic GitHub hosts scan

[Timer]
OnBootSec=5min
OnUnitActiveSec=3h
Persistent=true
RandomizedDelaySec=60

[Install]
WantedBy=timers.target
TMR
    sudo cp /tmp/goto-github.timer "$timer_file"
    rm -f /tmp/goto-github.service /tmp/goto-github.timer
  fi

  sudo chmod 644 "$service_file" "$timer_file"
  sudo systemctl daemon-reload
  sudo systemctl enable "$SCHEDULER_LABEL.timer"
  sudo systemctl start "$SCHEDULER_LABEL.timer"
  log "systemd units installed: $service_file, $timer_file"
  echo "  Systemd:   $service_file + timer (every 3h)"
}

# ============================================================================
# Install passwordless sudo for specific commands (macOS only)
# Creates /etc/sudoers.d/goto-github
# Usage: install_sudoers
# ============================================================================
install_sudoers() {
  if ! is_macos; then
    return 0
  fi

  local sudoers_file="/etc/sudoers.d/goto-github"
  local current_user
  current_user=$(whoami)

  # Only install if not already present
  if [ -f "$sudoers_file" ] && grep -q "$current_user" "$sudoers_file" 2>/dev/null; then
    log "sudoers entry already exists for $current_user"
    return 0
  fi

  echo "Installing passwordless sudo for hosts modification..."
  echo "${current_user} ALL=(ALL) NOPASSWD: /usr/bin/cp, /usr/bin/sed, /usr/bin/tee, /usr/bin/killall, /usr/sbin/dscacheutil" | \
    sudo tee "$sudoers_file" >/dev/null
  sudo chmod 440 "$sudoers_file"
  log "sudoers entry installed for $current_user"
  echo "  Sudoers:   $sudoers_file (passwordless for cp/sed/tee/killall/dscacheutil)"
}

# ============================================================================
# Main install entry point
# Usage: install <src_dir>
# ============================================================================
install() {
  local src_dir="$1"
  echo ""
  echo "Installing GoToGitHub..."
  echo ""

  install_files "$src_dir"
  install_scheduler
  install_sudoers

  echo ""
  echo "  Installation complete."
  echo "  Run 'goto-github run' to scan and update /etc/hosts"
  echo "  Run 'goto-github status' to check current status"
  echo "  Run 'goto-github uninstall' to remove"
  echo ""
}
