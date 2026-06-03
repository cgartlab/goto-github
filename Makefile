SHELL := /bin/bash
INSTALL_DIR ?= /opt/goto-github
BIN_DIR    ?= /usr/local/bin
CONFIG_DIR ?= /etc

# macOS launchd paths
MACOS_LAUNCHD_DIR := $(HOME)/Library/LaunchAgents

# Linux systemd paths
LINUX_SYSTEMD_DIR := /etc/systemd/system

# Files
BIN_SRC   := bin/goto-github.sh
LIBS      := lib/00-constants.sh lib/01-utils.sh lib/02-scan.sh lib/03-validate.sh lib/04-apply.sh lib/05-install.sh lib/06-uninstall.sh
CONTRIB   := contrib/macos/com.cgartlab.goto-github.plist contrib/linux/goto-github.service contrib/linux/goto-github.timer

.PHONY: all install uninstall install-macos install-linux test lint clean

all: lint

# ── Install ──────────────────────────────────────────────────────────────

install: check-platform validate-install-dir install-files
	@echo "✓ GoToGitHub installed to $(INSTALL_DIR)"
	@echo "  Run 'goto-github run' to scan and update /etc/hosts"

validate-install-dir:
	@if [ ! -d "$(dir $(INSTALL_DIR))" ]; then \
		echo "ERROR: Parent directory of INSTALL_DIR must exist: $(dir $(INSTALL_DIR))"; exit 1; \
	fi

install-files:
	@echo "Installing GoToGitHub to $(INSTALL_DIR)..."
	install -d "$(INSTALL_DIR)/bin" "$(INSTALL_DIR)/lib"
	install -m 755 "$(BIN_SRC)" "$(INSTALL_DIR)/bin/"
	install -m 644 $(LIBS) "$(INSTALL_DIR)/lib/"
	ln -sf "$(INSTALL_DIR)/bin/goto-github.sh" "$(BIN_DIR)/goto-github"

SCHEDULER_INTERVAL := $(shell sed -n 's/^readonly SCHEDULER_INTERVAL=\([0-9]\{1,\}\).*/\1/p' lib/00-constants.sh)
ifndef SCHEDULER_INTERVAL
$(error Failed to extract SCHEDULER_INTERVAL from lib/00-constants.sh)
endif

install-macos: install-files
	@echo "Installing launchd plist..."
	install -d "$(MACOS_LAUNCHD_DIR)"
	sed -e "s|/opt/goto-github|$(INSTALL_DIR)|g" \
	    -e "s|__SCHEDULER_INTERVAL__|$(SCHEDULER_INTERVAL)|g" \
	    contrib/macos/com.cgartlab.goto-github.plist > \
	    "$(MACOS_LAUNCHD_DIR)/com.cgartlab.goto-github.plist"
	launchctl load "$(MACOS_LAUNCHD_DIR)/com.cgartlab.goto-github.plist"
	@echo "✓ GoToGitHub installed (macOS launchd)"
	@echo "  Run 'goto-github run' to scan immediately"

install-linux: install-files
	@echo "Installing systemd units..."
	sed -e "s|/opt/goto-github|$(INSTALL_DIR)|g" \
	    contrib/linux/goto-github.service > \
	    "$(LINUX_SYSTEMD_DIR)/goto-github.service"
	sed -e "s|/opt/goto-github|$(INSTALL_DIR)|g" \
	    contrib/linux/goto-github.timer > \
	    "$(LINUX_SYSTEMD_DIR)/goto-github.timer"
	systemctl daemon-reload
	systemctl enable goto-github.timer
	systemctl start goto-github.timer
	@echo "✓ GoToGitHub installed (Linux systemd)"
	@echo "  Timer active — runs every 3 hours"

# ── Uninstall ────────────────────────────────────────────────────────────

uninstall:
	@echo "Removing GoToGitHub..."
	rm -f "$(BIN_DIR)/goto-github"
	rm -rf "$(INSTALL_DIR)"
	@echo "✓ GoToGitHub uninstalled"

uninstall-macos:
	-launchctl unload "$(MACOS_LAUNCHD_DIR)/com.cgartlab.goto-github.plist" 2>/dev/null
	rm -f "$(MACOS_LAUNCHD_DIR)/com.cgartlab.goto-github.plist"
	$(MAKE) uninstall

uninstall-linux:
	-systemctl stop goto-github.timer 2>/dev/null
	-systemctl disable goto-github.timer 2>/dev/null
	rm -f "$(LINUX_SYSTEMD_DIR)/goto-github.service"
	rm -f "$(LINUX_SYSTEMD_DIR)/goto-github.timer"
	systemctl daemon-reload
	$(MAKE) uninstall

# ── Quality ──────────────────────────────────────────────────────────────

lint:
	@echo "Running shellcheck..."
	shellcheck $(BIN_SRC) $(LIBS)

test:
	@echo "Running tests..."
	@bash_failed=0; pwsh_failed=0; bash_count=0; pwsh_count=0
	@for t in tests/test-*.sh; do \
		[ -f "$$t" ] || continue; \
		bash_count=$$((bash_count + 1)); \
		echo ""; \
		if ! bash "$$t"; then bash_failed=$$((bash_failed + 1)); fi; \
	done
	@if command -v pwsh >/dev/null 2>&1; then \
		for t in tests/test-ps-*.ps1; do \
			[ -f "$$t" ] || continue; \
			pwsh_count=$$((pwsh_count + 1)); \
			echo ""; \
			if ! pwsh -NoProfile -File "$$t"; then pwsh_failed=$$((pwsh_failed + 1)); fi; \
		done; \
	else \
		echo ""; \
		echo "(pwsh not found, skipping PowerShell tests)"; \
	fi
	@echo ""
	@echo "================================="
	@echo "Bash:    $$bash_count files"
	@echo "PowerShell: $$pwsh_count files"
	@echo "Failures: bash=$$bash_failed pwsh=$$pwsh_failed"
	@echo "================================="
	@if [ $$((bash_failed + pwsh_failed)) -gt 0 ]; then exit 1; fi
	@echo "✓ All tests passed"

# ── Helpers ──────────────────────────────────────────────────────────────

check-platform:
	@if [ "$$(uname)" = "Darwin" ]; then \
		echo "Platform: macOS"; \
	elif [ "$$(uname)" = "Linux" ]; then \
		echo "Platform: Linux"; \
	else \
		echo "Unsupported platform: $$(uname)"; exit 1; \
	fi

clean:
	rm -rf pkg/
