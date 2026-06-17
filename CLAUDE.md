# CLAUDE.md

## Project Overview

**GoToGitHub** — A single-script tool that fetches community-maintained GitHub domain mappings from [GitHub520](https://github.com/521xueweihan/GitHub520) and writes them to `/etc/hosts`. No scanning, no Python, no CI.

## Architecture

```
fetch.sh                  # Core logic (~420L, pure Bash 3.2+)
├── need_root()           # Privilege escalation wrapper (sudo -E)
├── run_cycle()           # Core: fetch→apply→flush→verify (consolidated)
├── auto_drive()           # Thin wrapper: privilege check → run_cycle
├── one_click_accelerate() # Thin wrapper: same for menu
├── interactive_menu()     # 1234Q TTY menu
├── json_status()         # --pwsh status: pure JSON output
├── apply_hosts()          # Write with timestamped backup
├── restore_hosts()        # Remove goto-github block
├── fetch_hosts_content()  # Fetch with fallback
├── validate_hosts_content() # Verify ≥10 IPs + github.com
└── flush_dns()           # DNS flush (macOS/Linux/Windows Git Bash)
```

### Multi-Platform Installers

| File | Role | Install command |
|------|------|----------------|
| `install.sh` | Unix bootstrapper | `curl -sfL .../install.sh \| bash` |
| `goto-github.ps1` | PowerShell wrapper (thin) | Download + run |
| `install.ps1` | Windows installer | `irm .../install.ps1 \| iex` |

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
├── fetch.sh                # Core logic (~420L, pure Bash)
├── install.sh              # Unix one-line installer (curl | bash)
├── goto-github.ps1         # PowerShell thin wrapper
├── install.ps1             # Windows one-line installer (irm | iex)
├── Makefile                # make lint
├── .shellcheckrc           # SC1090/SC1091 disabled
├── .gitattributes          # text=auto (cross-platform line endings)
├── .github/workflows/
│   ├── shellcheck.yml      # Lint CI (fetch.sh + install.sh)
│   └── opencode.yml        # AI review CI
├── README.md
├── CONTRIBUTING.md
├── CLAUDE.md
├── AGENTS.md
└── LICENSE
```
