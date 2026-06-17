# 贡献指南

## 开发

```bash
git clone https://github.com/cgartlab/goto-github.git
cd goto-github

# 查看帮助
./fetch.sh --help

# 查看当前状态（无需 sudo）
./fetch.sh --status

# 测试完整流程（需要 sudo）
sudo ./fetch.sh
```

## 分支规范

- `main` — 稳定版本
- `dev-*` — 开发分支

## 提交规范

使用 [Conventional Commits](https://www.conventionalcommits.org/)：
- `feat:` 添加新功能
- `fix:` 修复问题
- `docs:` 更新文档
- `refactor:` 重构

## PR 流程

1. 从 `main` 创建分支
2. 提交更改
3. 确保 `shellcheck fetch.sh` 无警告
4. 创建 PR 到 `main`
5. 合并后删除分支

## 文件结构

```
goto-github/
├── fetch.sh              # 唯一入口脚本
├── Makefile              # Lint targets
├── README.md
├── CONTRIBUTING.md
├── CLAUDE.md
├── AGENTS.md
├── LICENSE
├── .gitignore
├── .shellcheckrc         # ShellCheck config
└── .github/workflows/
    ├── shellcheck.yml
    └── opencode.yml
```

## Lint

```bash
shellcheck fetch.sh
```