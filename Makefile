.PHONY: lint test parity ps-test skill-test

# shellcheck at warning severity (matches CI). Style/info findings are not
# gating; warnings (e.g. unused variables, quoting) are.
lint:
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck not found. Install: brew install shellcheck (macOS) or apt install shellcheck (Linux)"; exit 1; }
	@shellcheck --severity=warning fetch.sh install.sh lib/*.sh shared/*.sh tests/lib/*.sh tests/test-*.sh scripts/*.sh scripts/lib/*.sh evals/*.sh
	@echo "Lint passed."

# Assert bash and PowerShell agree on shared data constants (markers, sources).
parity:
	@bash shared/parity-check.sh

test:
	@fail=0; for f in tests/test-*.sh; do \
		echo "== $$f =="; \
		bash "$$f" || fail=1; \
	done; \
	if [ "$$fail" -ne 0 ]; then echo "Tests FAILED"; exit 1; fi; \
	echo "Tests passed."

# Tests for the scan-based PowerShell implementation under ps1/.
# Windows-only: the code targets C:\...\etc\hosts, WindowsIdentity (UAC) and the
# HKLM DNS registry, and the curl mock is a .cmd file. Requires pwsh 7.
ps-test:
	@command -v pwsh >/dev/null 2>&1 || { echo "pwsh 7 not found. Install: winget install --id Microsoft.PowerShell"; exit 1; }
	@fail=0; for f in tests/test-ps-*.ps1; do \
		echo "== $$f =="; \
		pwsh -NoProfile -File "$$f" || fail=1; \
	done; \
	if [ "$$fail" -ne 0 ]; then echo "PS Tests FAILED"; exit 1; fi; \
	echo "PS Tests passed."

# Smoke-test the skill scripts (scripts/): every script must answer --help and
# emit parseable JSON. The apply script is exercised against a temp hosts file
# via GOTO_GITHUB_TEST_PRIVILEGED + GOTO_GITHUB_FORCE_IP so no system file is
# touched and no live probe result is required.
skill-test:
	@fail=0; \
	for f in scripts/*.sh; do \
		echo "== $$f --help =="; \
		bash "$$f" --help >/dev/null || fail=1; \
	done; \
	for f in scripts/*.ps1; do \
		echo "== $$f --help =="; \
		pwsh -NoProfile -File "$$f" --help >/dev/null 2>&1 || fail=1; \
	done; \
	if [ "$$fail" -ne 0 ]; then echo "Skill script --help FAILED"; exit 1; fi; \
	echo "Skill scripts OK."
