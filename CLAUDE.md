# CLAUDE.md

## Project Overview

**GoToGitHub** — A single-script tool that fetches community-maintained GitHub domain mappings from [GitHub520](https://github.com/521xueweihan/GitHub520) and writes them to `/etc/hosts`. No scanning, no Python, no CI.

## Architecture

Single file: `fetch.sh` (263 lines, pure Bash 3.2+)

```
fetch.sh
├── fetch_hosts_content()    Fetch from sources with fallback
├── validate_hosts_content() Verify ≥10 IPs + github.com present
├── extract_hosts_lines()    Strip comments, emit IP+domain lines
├── build_hosts_block()      Wrap in markers + timestamp
├── apply_hosts()            Write block to /etc/hosts
├── remove_block()           Remove old block before re-apply
├── flush_dns()              Refresh DNS cache (macOS/Linux)
├── verify_hosts()           curl --resolve connectivity check
└── show_status()            --status output
```

## Data Sources

1. `https://cdn.jsdelivr.net/gh/521xueweihan/GitHub520@main/hosts` — primary
2. `https://raw.hellogithub.com/hosts` — fallback

## Commands

```bash
sudo ./fetch.sh             # Fetch → validate → apply → flush DNS
./fetch.sh --status         # Show current IP and HTTP status (no sudo)
sudo ./fetch.sh --restore   # Remove goto-github block
./fetch.sh --help           # Show usage
```

## Platform Support

| Platform | DNS flush command |
|----------|-------------------|
| macOS | `killall -HUP mDNSResponder; dscacheutil -flushcache` |
| Linux | `resolvectl flush-caches` |
| Windows/Git Bash | `ipconfig //flushdns` via cmd.exe |

## Branch & Commit Conventions

- `main` — stable releases only
- `dev-*` — development branches
- Commits follow [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`, `refactor:`, `chore:`

## CI

ShellCheck runs on every push/PR touching `fetch.sh`. Config: `.github/workflows/shellcheck.yml`.

## Development

```bash
make lint                    # Run shellcheck (requires shellcheck installed)
./fetch.sh --status         # Test read-only path (no sudo needed)
sudo ./fetch.sh             # Test full cycle (sudo required)
```

## File Layout

```
goto-github/
├── fetch.sh                # Entry point (263L)
├── Makefile                # make lint
├── .shellcheckrc           # SC1090/SC1091 disabled
├── .gitattributes          # text=auto (cross-platform line endings)
├── .github/workflows/
│   ├── shellcheck.yml      # Lint CI
│   └── opencode.yml        # AI review CI
├── README.md
├── CONTRIBUTING.md
├── AGENTS.md
└── LICENSE
```
