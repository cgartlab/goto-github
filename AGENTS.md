# AGENTS.md — goto-github

**分层**: 工具 (Tools) — 网络实用工具

**技术栈**: Bash 3.2+ | macOS / Linux

GitHub 访问加速工具。从社区维护的 hosts 源（GitHub520）获取 CDN IP，写入 `/etc/hosts`。

## OVERVIEW

```
goto-github/
├── fetch.sh                # 唯一入口脚本 (263行)
├── Makefile                # Lint targets
├── README.md
├── CONTRIBUTING.md
├── CLAUDE.md
├── AGENTS.md
├── LICENSE
├── .gitignore
├── .shellcheckrc           # ShellCheck config
└── .github/workflows/
    ├── shellcheck.yml
    └── opencode.yml
```

## COMMANDS

| 命令 | 功能 | 需 sudo |
|------|------|---------|
| `sudo ./fetch.sh` | 拉取 hosts → 验证 → 写入 → DNS刷新 | ✅ |
| `./fetch.sh --status` | 显示当前 IP 和连通性 | ❌ |
| `sudo ./fetch.sh --restore` | 移除 goto-github 条目 | ✅ |
| `./fetch.sh --help` | 显示帮助 | ❌ |

## CONVENTIONS

- **主分支**: `main`（稳定）；`dev-*` 分支开发
- **提交**: Conventional Commits (`feat:`, `fix:`, `docs:`, `refactor:`)
- **Lint**: `shellcheck fetch.sh`（0 warnings 必须）
- **PR**: 目标 `main`

## ANTI-PATTERNS

- **NEVER** 直接编辑 `/etc/hosts` 标记区块外部
- **NEVER** 跳过 `shellcheck fetch.sh` 提交
- **NEVER** 对 `main` 直接推送，始终走 PR

## NOTES

- 依赖: Bash 3.2+, `curl`, sudo
- 无 Python 依赖（纯 bash）
- hosts 标记：`# >>> goto-github >>>` / `# <<< goto-github <<<`
- 数据源：jsDelivr CDN GitHub520（主）+ raw.hellogithub.com（备）