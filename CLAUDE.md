# CLAUDE.md

## Project Overview

**GoToGitHub** — A Bash tool that fetches GitHub CDN IPs from community-maintained hosts sources (521xueweihan/GitHub520) and writes them to `/etc/hosts`. No local scanning, no Python dependency.

## Architecture

Single script: `fetch.sh` (263 lines, pure bash)

```
fetch.sh
├── fetch_hosts_content()   # 遍历数据源，返回第一个有效内容
├── validate_hosts_content() # 内容安全验证（IP数量 + github.com存在性）
├── extract_hosts_lines()   # 提取有效 IP+域名 行
├── build_hosts_block()     # 构建带标记的 hosts 区块
├── apply_hosts()           # 写入 /etc/hosts
├── remove_block()          # 移除旧区块
├── flush_dns()            # 刷新 DNS 缓存
├── verify_hosts()         # curl --resolve 验证连通性
└── show_status()          # --status 输出
```

## Data Sources (in priority order)
1. `https://cdn.jsdelivr.net/gh/521xueweihan/GitHub520@main/hosts` — primary
2. `https://raw.hellogithub.com/hosts` — fallback

## Commands

```bash
sudo ./fetch.sh              # Fetch and apply hosts
./fetch.sh --status         # Show current IP and connectivity
sudo ./fetch.sh --restore    # Remove goto-github block
./fetch.sh --help           # Show help
```

## Platform Support
- macOS: `killall -HUP mDNSResponder` for DNS flush
- Linux: `resolvectl flush-caches` for DNS flush

## Branch & Commit Conventions
- `main` — stable releases
- `dev-*` — development branches
- Conventional Commits: `feat:`, `fix:`, `docs:`, `refactor:`

## CI
ShellCheck runs on push/PR to `main` and `dev-*`. Config: `.github/workflows/shellcheck.yml`.

## Development
```bash
# Lint
shellcheck fetch.sh

# Test status (read-only, no sudo needed)
./fetch.sh --status

# Full cycle (requires sudo)
sudo ./fetch.sh
```