# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**GoToGitHub** — A Bash tool that scans GitHub CDN IPs, validates them against real GitHub page content, and configures `/etc/hosts` to enable direct GitHub access from restricted networks.

## Architecture

```
bin/
  goto-github.sh          # Main CLI entrypoint — dispatches commands (run/status/install/uninstall/help)
lib/
  00-constants.sh         # Constants: paths, IPs, CIDRs, domains, curl params (sourced first)
  01-utils.sh             # Utilities: log, die, check_deps, is_macos, is_linux, check_sudo, cache I/O, banner
  02-scan.sh              # Scanning logic: CIDR expansion, parallel batch scanning, priority IP testing
  03-validate.sh          # Validation: curl-based IP verification, content-size check, hosts IP extraction
  04-apply.sh             # Apply: hosts file management (marker-based), DNS flush, status display
  05-install.sh           # Installation: file copy, launchd/systemd scheduler, sudoers (macOS)
  06-uninstall.sh         # Uninstallation: full cleanup of all components
```

**Module sourcing order** (strict dependency chain): `00` → `01` → `02` → `03` → `04` → `05` → `06`. Each module uses a guard variable (`_GOTO_GITHUB_XX_INCLUDED`) to prevent double-sourcing.

**Scanning pipeline** (`scan_all`):
1. Test 8 priority IPs in parallel → pick fastest valid one
2. If none pass, expand 4 CIDR ranges (~thousands of IPs) via Python3 (or fallback embedded list)
3. Scan CIDR IPs in batches of 100 with early-break on first valid hit
4. Validation: `curl --resolve` with content-size threshold (>100KB) and HTTP 200/301/302

**Hosts management**: Uses `# >>> goto-github >>>` / `# <<< goto-github <<<` markers to delimit the managed block. `apply_hosts` replaces the entire block atomically.

**Scheduler**: macOS → launchd (StartInterval=10800s); Linux → systemd service + timer (OnUnitActiveSec=3h, Persistent=true, RandomizedDelaySec=60).

## Development Commands

```bash
# Run lint (ShellCheck, severity=warning)
make lint

# Run tests
make test

# Install locally
sudo ./bin/goto-github.sh install

# Run a single scan
sudo ./bin/goto-github.sh run

# Check status
sudo ./bin/goto-github.sh status

# Uninstall
sudo ./bin/goto-github.sh uninstall

# Full build cycle (lint only, no build step needed for Bash)
make all

# Clean
make clean
```

## CI

GitHub Actions runs ShellCheck on push/PR to `main` and `dev-*` branches, triggered by changes to `bin/**`, `lib/**`, and `Makefile`. Config: [`.github/workflows/shellcheck.yml`](.github/workflows/shellcheck.yml).

## Branch & Commit Conventions

- `main` — stable releases
- `dev-*` — development branches
- Conventional Commits: `feat:`, `fix:`, `docs:`, `refactor:`, `fix(ci):`, `fix(security):`

## Platform Support

- **macOS**: `bin/goto-github.sh`, launchd plist (`contrib/macos/`), `sudoers.d` passwordless sudo for specific commands
- **Linux**: `bin/goto-github.sh`, systemd service + timer (`contrib/linux/`)
- Requires: Bash 3.2+, `curl`, `sudo`; `python3` optional (CIDR expansion fallback to embedded IP list)
