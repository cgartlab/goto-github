.PHONY: lint

lint:
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck not found. Install: brew install shellcheck (macOS) or apt install shellcheck (Linux)"; exit 1; }
	@shellcheck fetch.sh install.sh
	@echo "Lint passed."