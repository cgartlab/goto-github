# CLAUDE.md

## Project Overview

**GoToGitHub** — A Bash + PowerShell tool that fetches community-maintained GitHub domain mappings from [GitHub520](https://github.com/521xueweihan/GitHub520) and writes them to `/etc/hosts`. No scanning, no Python. The bash implementation is a thin `fetch.sh` entry point plus `lib/` modules (unit-tested, mock curl, no network).

## Architecture

```
fetch.sh                  # Thin entry point: parse args -> source lib/ -> dispatch
lib/                      # Bash implementation (sourced by fetch.sh)
├── 00-constants.sh       # Data constants (markers, sources, probe tuning)
├── 01-utils.sh           # Logging, platform, privilege, DNS, TCP helpers
├── 02-fetch.sh           # Source fetching, dead-IP filter, IP probe
├── 03-validate.sh        # Content validation, post-apply verification
└── 04-apply.sh           # Build/apply/remove hosts block, shadowing, status

fetch.sh also holds the CLI layer:
├── need_root()           # Privilege escalation wrapper (sudo -E)
├── run_cycle()           # Core: fetch->apply->flush->verify (consolidated)
├── auto_drive()           # Thin wrapper: privilege check -> run_cycle
├── one_click_accelerate() # Thin wrapper: same for menu
├── interactive_menu()     # 1234Q TTY menu
└── main()                 # Arg dispatch (--status/--restore/--pwsh/--probe/...)

goto-github.ps1           # Pure PowerShell implementation (Windows, no bash.exe)
├── Test-IsAdmin          # Check admin privileges
├── Request-Admin         # Auto-elevate via Start-Process -Verb RunAs
├── Test-ValidHostsContent # Verify >=10 IPs + github.com
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
| `bootstrap.ps1` | Windows bootstrapper (recommended) | `irm .../bootstrap.ps1 \| iex` |
| `install.ps1` | Windows installer (fallback) | `irm .../install.ps1 -OutFile "$env:TEMP\install.ps1"; & "$env:TEMP\install.ps1"` |

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

`.github/workflows/shellcheck.yml` runs on every push/PR touching `fetch.sh`,
`install.sh`, `lib/`, `shared/`, `tests/` or `*.ps1`:
- ShellCheck (severity: warning) over the whole repo
- `tests/test-*.sh` (bash unit tests, no network)
- `shared/parity-check.sh` (bash <-> PowerShell constant parity)
- PSScriptAnalyzer over `*.ps1`

## Development

**Bash (macOS / Linux / Git Bash):**
```bash
make lint                    # shellcheck --severity=warning (requires shellcheck)
make test                    # bash unit tests (mock curl, no network)
make parity                  # bash <-> PowerShell constant parity
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
├── fetch.sh                # Thin Bash entry point (sources lib/)
├── lib/                    # Bash modules: 00-constants .. 04-apply
├── install.sh              # Unix one-line installer (curl | bash, downloads lib/)
├── goto-github.ps1         # PowerShell native (no bash.exe)
├── bootstrap.ps1          # Windows bootstrapper (irm | iex, recommended)
├── install.ps1             # Windows installer (OutFile fallback, downloads lib/)
├── shared/parity-check.sh  # bash <-> PowerShell constant parity check
├── tests/                  # Bash unit tests (test-00..04-*.sh, mock curl)
├── Makefile                # make lint / make test / make parity
├── .shellcheckrc           # SC1090/SC1091 disabled
├── .gitattributes          # text=auto (cross-platform line endings)
├── .github/workflows/
│   ├── shellcheck.yml      # Lint + tests + parity CI
│   ├── argus-review.yml    # AI review CI
│   └── pr-automation.yml   # PR automation (labels/assign)
├── README.md
├── CONTRIBUTING.md
├── CLAUDE.md
├── AGENTS.md
├── LESSONS.md
└── LICENSE
```
