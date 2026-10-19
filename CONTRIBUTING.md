# 贡献指南

## 开发环境

**Bash (macOS / Linux / Git Bash):**
```bash
git clone https://github.com/cgartlab/goto-github.git
cd goto-github

./fetch.sh --help           # 查看帮助
./fetch.sh --status         # 查看状态（无需 sudo）
sudo ./fetch.sh             # 测试完整流程（需 sudo）
```

**PowerShell (Windows):**
```powershell
git clone https://github.com/cgartlab/goto-github.git
cd goto-github

.\goto-github.ps1 --help        # 查看帮助
.\goto-github.ps1 --pwsh status # 查看状态
.\goto-github.ps1 --pwsh auto   # 测试完整流程（需管理员）
```

## 分支规范

- `main` — 稳定版本，受保护
- `dev-*` — 开发分支

## 提交规范

[Conventional Commits](https://www.conventionalcommits.org/)：

| 类型 | 说明 |
|------|------|
| `feat:` | 新功能 |
| `fix:` | 问题修复 |
| `docs:` | 文档更新 |
| `refactor:` | 重构（不影响功能） |
| `chore:` | 维护性变更（CI、依赖、配置） |

## PR 流程

1. 从 `main` 创建分支：`git switch -c dev-<feature>`
2. 开发并提交
3. 确保 `make lint`（shellcheck 0 warnings）、`make test`、`make parity` 通过；改到 `ps1/` 时再加 `make ps-test`（仅 Windows）
4. 创建 PR 指向 `main`
5. 合并后删除分支

## 文件结构

```
goto-github/
├── fetch.sh                # Bash 入口（薄）：source lib/ 并调度
├── lib/                    # Bash 实现模块（00-constants .. 04-apply）
├── install.sh              # Unix 一键安装（下载 fetch.sh + lib/）
├── goto-github.ps1         # PowerShell 拉取式实现（已发布）
├── ps1/                    # PowerShell 扫描式实现（实验性，默认不发布）
├── bootstrap.ps1          # Windows bootstrapper (irm | iex, 推荐)
├── install.ps1             # Windows 一键安装 (OutFile 备用)
├── shared/parity-check.sh  # bash ↔ PowerShell 常量一致性校验
├── tests/                  # 单元测试（bash test-00..04-*.sh / ps test-ps-00..04-*.ps1）
├── Makefile                # make lint / make test / make parity / make ps-test
├── .shellcheckrc          # ShellCheck 配置
├── .gitattributes          # 跨平台行尾
├── README.md
├── CONTRIBUTING.md
├── CLAUDE.md
├── AGENTS.md
├── LESSONS.md
└── .github/workflows/
    ├── shellcheck.yml      # Lint + 测试 + parity CI（含 windows-latest ps1/ 测试）
    ├── argus-review.yml    # AI review CI
    └── pr-automation.yml   # PR 自动化（打标/指派）
```

## Lint & 测试

```bash
make lint     # shellcheck --severity=warning（0 warnings）
make test     # bash 单元测试（mock curl，无需网络）
make parity   # bash ↔ PowerShell 常量一致性
make ps-test  # ps1/ 扫描式实现的单元测试（仅 Windows，需 pwsh 7）
```

`ps1/` 是实验性扫描式实现，与根 `goto-github.ps1`（拉取式）互斥且 CLI 不兼容，
`install.ps1` 不下载它。改任一套前先读 AGENTS.md 的 NOTES 段落确认意图。
