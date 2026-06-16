# 贡献指南

## 开发

```bash
git clone https://github.com/cgartlab/goto-github.git
cd goto-github

# 本地测试 fetch
sudo ./fetch.sh --status

# 测试扫描脚本
python3 scripts/scan.py
```

## 分支规范

- `main` — 稳定版本
- `dev-*` — 开发分支

## 提交规范

使用 [Conventional Commits](https://www.conventionalcommits.org/)：

```
feat: 添加新功能
fix: 修复问题
docs: 更新文档
refactor: 重构代码
chore: 日常维护（依赖更新、配置变更）
```

## PR 流程

1. 从 `main` 创建分支
2. 提交更改
3. 创建 PR 到 `main`
4. 合并后删除分支

## 文件结构

```
goto-github/
├── fetch.sh              # 本地获取并应用 IP
├── github-ips.json       # 云端扫描结果（自动更新）
├── scripts/
│   └── scan.py          # 云端 IP 扫描脚本
└── .github/workflows/
    └── scan.yml         # GitHub Actions 定时扫描
```