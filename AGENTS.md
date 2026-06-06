# AGENTS.md — goto-github

**分层**: 工具 (Tools) — 网络实用工具

**技术栈**: Bash 3.2+ | macOS launchd / Linux systemd

GitHub CDN IP 扫描工具。自动扫描 GitHub CDN IP 段，验证可用性，将最快可用节点写入 `/etc/hosts`，支持定时调度和安装/卸载。

## OVERVIEW

```
goto-github/
├── bin/
│   └── goto-github.sh      # 入口脚本 (162行)
├── lib/                     # 7 个模块 (~1120 LOC)
│   ├── 00-constants.sh      # 常量 (IP段/域名/路径)
│   ├── 01-utils.sh          # 工具函数
│   ├── 02-scan.sh           # CDN IP 并发扫描
│   ├── 03-validate.sh       # HTTP 响应验证 (>100KB)
│   ├── 04-apply.sh          # /etc/hosts 写入 (标记区块)
│   ├── 05-install.sh        # 安装到 /opt/goto-github
│   └── 06-uninstall.sh      # 完全卸载
├── contrib/
│   ├── linux/               # systemd service + timer (3h)
│   └── macos/               # launchd plist (15min)
├── README.md
├── CONTRIBUTING.md
├── LICENSE                  # MIT
├── Makefile                 # install/lint/test 目标
└── .github/workflows/       # CI: shellcheck
```

**注意**: 当前工作区目录**不是 git 仓库**（无 `.git`），实际源在 `github.com/cgartlab/goto-github`。

## COMMANDS

| 命令 | 功能 | 需 sudo |
|---|---|---|
| `goto-github run` | 扫描 IP 并更新 `/etc/hosts` | ✅ |
| `goto-github status` | 显示当前 IP 与连通性 | ❌ |
| `goto-github install` | 安装 + 启用定时任务 | ✅ |
| `goto-github uninstall` | 完全移除 | ✅ |
| `goto-github help` | 使用帮助 | ❌ |

## CONVENTIONS

- **主分支**: `main`（稳定）；`dev-*` 分支开发
- **提交**: Conventional Commits (`feat:`, `fix:`, `docs:`, `refactor:`)
- **Lint**: `make lint` → shellcheck（配置在 `.shellcheckrc`）
- **PR**: 目标 `main`，`make lint` 必须通过
- **模块加载**: 严格顺序（00→01→02→03→04→05→06），含双重引入保护
- **hosts 文件**: 使用 `# >>> goto-github >>>` / `# <<< goto-github <<<` 标记区块，不干扰其他 hosts 条目

## ANTI-PATTERNS

- **NEVER** 直接编辑 `/etc/hosts` 标记区块外部
- **NEVER** 跳过 `make lint` 提交
- **NEVER** 对 `main` 直接推送，始终走 PR
- **NEVER** 手动运行 `lib/*.sh` 模块——它们仅供 `bin/goto-github.sh` source 调用
- **NEVER** 在 Bash 代码中混入 Go——这是纯 Bash 项目

## NOTES

- 依赖: Bash 3.2+, `curl`, 可选 `python3`（CIDR 展开）
- 两个调度间隔不一致: Linux 3h / macOS 15min（这是设计意图）
- 安装后运行时文件: `~/.goto-github-cache`（缓存），`~/Library/Logs/goto-github.log` 或 `~/.local/share/goto-github/goto-github.log`
- 本机当前**未安装**（`/opt/goto-github` 不存在）
