.PHONY: lint test parity

# shellcheck at warning severity (matches CI). Style/info findings are not
# gating; warnings (e.g. unused variables, quoting) are.
lint:
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck not found. Install: brew install shellcheck (macOS) or apt install shellcheck (Linux)"; exit 1; }
	@shellcheck --severity=warning fetch.sh install.sh lib/*.sh shared/*.sh tests/lib/*.sh tests/test-*.sh
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
