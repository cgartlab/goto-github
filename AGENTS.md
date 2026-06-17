# AGENTS.md — goto-github

**分类**: 工具 (Tools) — 网络实用工具
**技术栈**: Bash 3.2+ (macOS/Linux/Git Bash) · PowerShell 5.1+ (Windows)

GitHub 访问加速工具。实时从社区维护的 hosts 源获取 GitHub 域名映射，写入本地 hosts 文件，无需本地扫描。

## OVERVIEW

```
goto-github/
├── fetch.sh                # 核心逻辑 (Bash, ~420行)
├── install.sh             # Unix 一键安装 (curl | bash)
├── goto-github.ps1         # PowerShell 原生实现 (无需 Git Bash)
├── install.ps1             # Windows 一键安装 (irm | iex)
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

### Bash (macOS / Linux / Git Bash)

| 命令 | 功能 | 需 sudo |
|------|------|---------|
| `sudo ./fetch.sh` | 拉取 → 验证 → 写入 hosts → DNS刷新 | ✅ |
| `./fetch.sh --status` | 显示当前 IP 和连通性 | ❌ |
| `sudo ./fetch.sh --restore` | 移除 goto-github 条目 | ✅ |
| `./fetch.sh --help` | 显示帮助 | ❌ |

### PowerShell (Windows)

| 命令 | 功能 | 需管理员 |
|------|------|---------|
| `.\goto-github.ps1` | 交互菜单 | 修改 hosts 时需要 |
| `.\goto-github.ps1 --pwsh status` | JSON 状态（脚本用） | ❌ |
| `.\goto-github.ps1 --pwsh auto` | 一键加速 | 修改 hosts 时需要 |
| `.\goto-github.ps1 --pwsh restore` | 恢复 hosts | 修改 hosts 时需要 |

### 一键安装

| 平台 | 命令 |
|------|------|
| Unix (macOS / Linux) | `curl -sfL .../install.sh \| bash` |
| Windows PowerShell | `irm .../install.ps1 \| iex` |

## CONVENTIONS

- **主分支**: `main`（稳定）；`dev-*` 分支开发
- **提交**: Conventional Commits（`feat:` `fix:` `docs:` `refactor:` `chore:`）
- **Lint**: `shellcheck fetch.sh install.sh`（0 warnings 方可提交）
- **PR**: 始终指向 `main`，禁止直推

## ANTI-PATTERNS

- **NEVER** 编辑 hosts 标记区块外部
- **NEVER** 跳过 `shellcheck fetch.sh` 提交（Bash 版本）
- **NEVER** 直推 `main`，始终走 PR
- **NEVER** 在 PowerShell 实现中重新引入 bash.exe 依赖

## NOTES

- 依赖：
  - Unix: Bash 3.2+、curl、管理员权限
  - Windows: PowerShell 5.1+（原生，无需 Git Bash）
- 无 Python 依赖
- Hosts 标记：`# >>> goto-github >>>` / `# <<< goto-github <<<`
- 数据源：jsDelivr CDN GitHub520（主）→ raw.hellogithub.com（备）
- 平台：macOS · Linux · Git Bash (Windows) · Windows PowerShell
- 安装路径（Unix）：`~/.local/share/goto-github/` + `~/.local/bin/goto-github`
- 安装路径（Windows）：`$env:LOCALAPPDATA\goto-github\`
- WSL：不支持（WSL hosts 行为与 Windows 不同，检测到 WSL 打印重定向消息）
