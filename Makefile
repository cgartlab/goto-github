.PHONY: lint test

lint:
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck not found. Install: brew install shellcheck (macOS) or apt install shellcheck (Linux)"; exit 1; }
	@shellcheck fetch.sh install.sh tests/test_functions.sh
	@echo "Lint passed."

test:
	@bash tests/test_functions.sh
	@echo "Tests passed."