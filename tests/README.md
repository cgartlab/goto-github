# tests/

Test suite for the bash implementation (`fetch.sh` + `lib/`). Zero external
dependencies — pure bash plus the standard Unix tools (sed, awk, grep, mktemp).
No network access: `curl` is mocked.

## Quick start

```bash
make test                              # run every test file
bash tests/test-04-apply.sh            # run a single file
make lint                              # shellcheck (warning severity)
make parity                            # bash <-> PowerShell constant parity
```

## Layout

```
tests/
  lib/
    test-helpers.sh        # assert functions + runner (run_test / test_report)
  test-00-constants.sh     # lib/00-constants.sh: markers, sources, probe tuning
  test-01-utils.sh         # lib/01-utils.sh: logging, HTTP-code, curl errors
  test-02-fetch.sh         # lib/02-fetch.sh: dead-IP filter, IP probe (mock curl)
  test-03-validate.sh      # lib/03-validate.sh: content validation, verify_hosts
  test-04-apply.sh         # lib/04-apply.sh: build/apply/remove block, shadowing
```

Each file is self-contained: it sources `tests/lib/test-helpers.sh`, sources the
module(s) under test, and redirects all side effects to a per-file temp dir.

## Conventions

- **Never touch the real `/etc/hosts`.** Tests override `HOSTS_FILE` to a temp
  file *after* sourcing `lib/00-constants.sh` (the default is only a fallback,
  the variable is not readonly).
- **Mock `curl`.** Define a `curl()` shell function in the test; bash resolves
  functions before PATH, so every `curl` call in the sourced modules uses it.
  Do not `unset -f curl` before `run_test` runs.
- **Stub `test_tcp_reachable`** when testing `filter_dead_core_ips` so the
  liveness filter is exercised without sockets.
- Test functions are passed to `run_test` by name, so shellcheck's SC2329
  ("never invoked") is a false positive here.

## What is NOT covered (and why)

| Function | Why skipped |
|---|---|
| `test_tcp_reachable` | Depends on `nc`/live sockets; covered indirectly via a stub in test-02. |
| `flush_dns` | Mutates the host DNS cache; not safe to run in CI. |
| `need_root` | Re-execs via `sudo`; would take over the test process. |
| `fetch_hosts_content`, `test_domain_ips` | Live network. Their building blocks (filter, probe, validate) are covered. |
| `show_status` | Prints a live curl result; `json_status` (same block parsing) is covered. |

## Adding a new test

1. Create `tests/test-NN-name.sh`.
2. `source "$REPO_ROOT/tests/lib/test-helpers.sh"` then `setup_tmpdir`.
3. `source` the module(s) under test from `lib/`.
4. Override `HOSTS_FILE` / mock `curl` as needed.
5. Write `test_*` functions, then `run_test "name" test_fn` for each.
6. End with `test_report` and `exit $?`.
7. `make test` and `make lint` must both pass.
