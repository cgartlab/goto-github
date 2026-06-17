# AGENTS.md — goto-github

**分类**: 工具 (Tools) — 网络实用工具
**技术栈**: Bash 3.2+ · macOS / Linux / Git Bash

GitHub 访问加速工具。实时从社区维护的 hosts 源获取 GitHub 域名映射，写入 `/etc/hosts`。

## OVERVIEW

```
goto-github/
├── fetch.sh                # 唯一入口脚本 (263行)
├── Makefile                # make lint
├── .shellcheckrc           # ShellCheck 配置
├── .gitattributes          # 跨平台行尾
├── README.md
├── CONTRIBUTING.md
├── CLAUDE.md
├── AGENTS.md
├── LICENSE
└── .github/workflows/
    ├── shellcheck.yml      # Lint CI
    └── opencode.yml        # AI review CI
```

## COMMANDS

| 命令 | 功能 | 需 sudo |
|------|------|---------|
| `sudo ./fetch.sh` | 拉取 → 验证 → 写入 hosts → DNS刷新 | ✅ |
| `./fetch.sh --status` | 显示当前 IP 和连通性 | ❌ |
| `sudo ./fetch.sh --restore` | 移除 goto-github 条目 | ✅ |
| `./fetch.sh --help` | 显示帮助 | ❌ |

## CONVENTIONS

- **主分支**: `main`（稳定）；`dev-*` 分支开发
- **提交**: Conventional Commits（`feat:` `fix:` `docs:` `refactor:` `chore:`）
- **Lint**: `shellcheck fetch.sh`（0 warnings 方可提交）
- **PR**: 始终指向 `main`，禁止直推

## ANTI-PATTERNS

- **NEVER** 编辑 `/etc/hosts` 标记区块外部
- **NEVER** 跳过 `shellcheck fetch.sh` 提交
- **NEVER** 直推 `main`，始终走 PR

## NOTES

- 依赖：Bash 3.2+、curl、sudo
- 无 Python 依赖（纯 bash）
- Hosts 标记：`# >>> goto-github >>>` / `# <<< goto-github <<<`
- 数据源：jsDelivr CDN GitHub520（主）→ raw.hellogithub.com（备）
- 平台：macOS · Linux · Git Bash (Windows)
