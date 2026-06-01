# GoToGitHub

Direct GitHub access from China — no VPN, no proxy, just `/etc/hosts`.

在中國直連 GitHub，不需要 VPN 或代理，僅需維護 `/etc/hosts` 文件。

## How It Works / 工作原理

The GFW dynamically blocks HTTPS (TCP 443) to GitHub CDN IPs. Most IPs in GitHub's CDN range work fine — the GFW can't block all of them at once. GoToGitHub scans CDN IPs to find one that returns real GitHub HTML, then writes it to `/etc/hosts`.

GFW 會動態封鎖 GitHub CDN IP 的 HTTPS 連接。但 GitHub CDN 範圍內的 IP 不能被全部封鎖。GoToGitHub 掃描 CDN IP，找到能返回真實 GitHub 頁面的 IP，寫入 `/etc/hosts`。

Scan strategy / 掃描策略:
1. **Priority IPs** — 8 pre-verified IPs, tested in parallel (~2s)
2. **CIDR fallback** — full CDN range scan in batches of 100 concurrent IPs (~15-20s)
3. **Content validation** — rejects "OK" placeholder responses, requires >100KB real HTML

## Quick Start / 快速開始

```bash
git clone https://github.com/cgartlab/goto-github.git
cd goto-github

# Run once (requires sudo for /etc/hosts)
sudo ./bin/goto-github.sh run

# Install with scheduler (3-hour interval)
sudo ./bin/goto-github.sh install
```

After install, the CLI command `goto-github` is available system-wide:

```bash
goto-github run       # Scan + update /etc/hosts
goto-github status    # Check current IP and reachability
goto-github install   # Install to /opt/goto-github with scheduler
goto-github uninstall # Full removal
```

## Installation / 安裝

### One-time use / 單次使用

```bash
sudo ./bin/goto-github.sh run
```

### Full install with scheduler / 完整安裝（含定時器）

```bash
# From repo root / 在倉庫根目錄執行
sudo ./bin/goto-github.sh install
```

This installs to `/opt/goto-github/`, creates a symlink at `/usr/local/bin/goto-github`, and sets up automatic scanning:
- **macOS**: launchd plist, runs every 3 hours
- **Linux**: systemd timer, runs every 3 hours

### Makefile / 透過 Makefile 安裝

```bash
sudo make install          # auto-detects platform
sudo make install-macos    # force macOS install
sudo make install-linux    # force Linux install
sudo make uninstall        # full removal
```

## Commands / 命令

| Command / 命令 | Description / 說明 |
|---|---|
| `goto-github run` | Scan CDN IPs, update `/etc/hosts`, flush DNS cache |
| `goto-github status` | Show current IP, reachability, and install info |
| `goto-github install` | Install files + scheduler + sudoers (macOS) |
| `goto-github uninstall` | Remove all traces from the system |
| `goto-github help` | Show usage information |

## Project Structure / 項目結構

```
goto-github/
├── bin/
│   └── goto-github.sh      CLI entry point
├── lib/
│   ├── 00-constants.sh     Configuration and paths
│   ├── 01-utils.sh         Logging, platform detection, helpers
│   ├── 02-scan.sh          CDN IP scanning (priority + CIDR)
│   ├── 03-validate.sh      IP content validation
│   ├── 04-apply.sh         /etc/hosts management and DNS flush
│   ├── 05-install.sh       Platform-specific installers
│   └── 06-uninstall.sh     Complete uninstall logic
├── contrib/
│   ├── macos/              launchd plist template
│   └── linux/              systemd service + timer templates
├── Makefile                Install/uninstall automation
└── README.md
```

## Requirements / 依賴

- **Bash 3.2+** (macOS default)
- **curl** (pre-installed on macOS and most Linux)
- **python3** (optional, for full CIDR expansion via `ipaddress` module)
- **sudo** access for `/etc/hosts` modification

## How It Detects Working IPs / IP 檢測方法

GoToGitHub uses `curl --resolve` to test IPs directly (bypassing DNS):

```bash
curl --resolve "github.com:443:$IP" -s -o /dev/null \
  -w "%{http_code},%{time_total},%{size_download}" \
  --connect-timeout 3 --max-time 6 \
  https://github.com/
```

A valid IP must return HTTP 200 and download >100KB of content. This filters out CDN edges that return a small "OK" placeholder page (~3 bytes) instead of real GitHub HTML.

有效的 IP 必須返回 HTTP 200 且內容大於 100KB。這排除了那些只返回 "OK" 佔位頁面的 CDN 邊緣節點。

## CDN Ranges / CDN 範圍

Hardcoded from GitHub's [meta API](https://api.github.com/meta) (changes quarterly at most):

- `140.82.112.0/20`
- `185.199.108.0/22`
- `192.30.252.0/22`
- `143.55.64.0/20`

## DNS Recommendation / DNS 建議

Use AliDNS for more stable resolution within China:

```bash
# macOS
networksetup -setdnsservers Wi-Fi 223.5.5.5 223.6.6.6
```

## FAQ

**Q: Why not use GitHub Actions for cloud scanning?**

A: Cloud scanning can't detect GFW blocking from outside China. The GFW only blocks traffic originating from within China. Local scanning is the only reliable method.

**Q: How often should I scan?**

A: Every 3 hours is the default. The GFW blocks IPs within 1-2 minutes of detection, but new IPs become available immediately. The priority list scan takes only ~2 seconds.

**Q: Does this bypass the GFW?**

A: No. It uses GitHub's own CDN infrastructure that's legally accessible in China. The GFW blocks specific IPs dynamically but can't block the entire CDN range.

---

## License / 許可證

MIT
