# CLAUDE.md

## Project Overview

**GoToGitHub** — A single-script tool that fetches community-maintained GitHub domain mappings from [GitHub520](https://github.com/521xueweihan/GitHub520) and writes them to `/etc/hosts`. No scanning, no Python, no CI.

## Architecture

```
fetch.sh                  # Core logic (~420L, pure Bash 3.2+, Unix/Linux/macOS/Git Bash)
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

goto-github.ps1           # Pure PowerShell implementation (Windows, no bash.exe)
├── Test-IsAdmin          # Check admin privileges
├── Request-Admin         # Auto-elevate via Start-Process -Verb RunAs
├── Test-ValidHostsContent # Verify ≥10 IPs + github.com
├── Get-HostsContent      # Fetch with fallback
├── Add-HostsBlock        # Write with timestamped backup
├── Remove-GotoBlock      # Remove goto-github block
├── Clear-DnsCache        # DNS flush via ipconfig
├── Test-HostsVerification # Verify github.com reachable via IP
└── Get-JSONStatus        # --pwsh status: pure JSON output
```

### Multi-Platform Installers

| File | Role | Install command |
|------|------|----------------|
| `install.sh` | Unix bootstrapper | `curl -sfL .../install.sh \| bash` |
| `goto-github.ps1` | PowerShell native (no bash.exe) | Download + run |
| `install.ps1` | Windows installer | `irm .../install.ps1 \| iex` |

## Data Sources

1. `https://cdn.jsdelivr.net/gh/521xueweihan/GitHub520@main/hosts` — primary
2. `https://raw.hellogithub.com/hosts` — fallback

## Commands

**Bash (macOS / Linux / Git Bash):**
```bash
sudo ./fetch.sh             # Fetch → validate → apply → flush DNS
./fetch.sh --status         # Show current IP and HTTP status (no sudo)
sudo ./fetch.sh --restore   # Remove goto-github block
./fetch.sh --help           # Show usage
```

**PowerShell (Windows):**
```powershell
.\goto-github.ps1               # Interactive menu (1234Q)
.\goto-github.ps1 --help        # Show usage
.\goto-github.ps1 --version     # Show version
.\goto-github.ps1 --status      # Human-readable status
.\goto-github.ps1 --pwsh status # JSON status (for scripting)
.\goto-github.ps1 --pwsh auto   # One-click accelerate (requires admin)
.\goto-github.ps1 --pwsh restore # Restore hosts (requires admin)
```

## Platform Support

| Platform | DNS flush command |
|----------|-------------------|
| macOS | `killall -HUP mDNSResponder; dscacheutil -flushcache` |
| Linux | `resolvectl flush-caches` |
| Windows | `ipconfig //flushdns` (PowerShell native) |

## Branch & Commit Conventions

- `main` — stable releases only
- `dev-*` — development branches
- Commits follow [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`, `refactor:`, `chore:`

## CI

ShellCheck runs on every push/PR touching `fetch.sh`. Config: `.github/workflows/shellcheck.yml`.

## Development

**Bash (macOS / Linux / Git Bash):**
```bash
make lint                    # Run shellcheck (requires shellcheck installed)
./fetch.sh --status         # Test read-only path (no sudo needed)
sudo ./fetch.sh             # Test full cycle (sudo required)
```

**PowerShell (Windows):**
```powershell
.\goto-github.ps1 --pwsh status  # Test status endpoint
.\goto-github.ps1 --pwsh auto    # Test full cycle (requires admin)
```

## File Layout

```
goto-github/
├── fetch.sh                # Core logic (~420L, pure Bash)
├── install.sh              # Unix one-line installer (curl | bash)
├── goto-github.ps1         # PowerShell native (no bash.exe)
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
