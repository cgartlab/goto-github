# 贡献指南

## 开发环境

```bash
git clone https://github.com/cgartlab/goto-github.git
cd goto-github

./fetch.sh --help           # 查看帮助
./fetch.sh --status        # 查看状态（无需 sudo）
sudo ./fetch.sh             # 测试完整流程（需 sudo）
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
3. 确保 `make lint` 通过（`shellcheck fetch.sh` 0 warnings）
4. 创建 PR 指向 `main`
5. 合并后删除分支

## 文件结构

```
goto-github/
├── fetch.sh                # 核心逻辑 (Bash)
├── install.sh              # Unix 一键安装
├── goto-github.ps1         # PowerShell 适配层
├── install.ps1             # Windows 一键安装
├── Makefile                # Lint targets
├── .shellcheckrc          # ShellCheck 配置
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

## Lint

```bash
make lint
# 或
shellcheck fetch.sh install.sh
```
