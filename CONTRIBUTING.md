# 贡献指南

## 开发

```bash
# 克隆仓库
git clone https://github.com/cgartlab/goto-github.git
cd goto-github

# 运行 lint
make lint

# 本地测试
sudo ./bin/goto-github.sh run
```

## 分支规范

- `main` — 稳定版本
- `dev-*` — 开发分支（如 `dev-fix-scan`）

## 提交规范

使用 [Conventional Commits](https://www.conventionalcommits.org/)：

```
feat: 添加新功能
fix: 修复问题
docs: 更新文档
refactor: 重构代码
```

## PR 流程

1. 从 `main` 创建 `dev-xxx` 分支
2. 提交更改，确保 `make lint` 通过
3. 创建 PR 到 `main`
4. 合并后删除分支
