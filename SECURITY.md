# Security Policy

## 报告漏洞

请不要在公开的 issue 中报告安全问题。请使用 GitHub 的私密漏洞报告：

1. 进入仓库 **Security** 标签页
2. 点击 **Report a vulnerability**
3. 提供复现步骤与影响范围

我会在 7 天内确认收到，并在可行时给出修复时间线。

## 支持范围

仅支持 `main` 最近一个版本。更早的提交不受支持。

## 本项目的敏感面

`goto-github` 会**写入系统 hosts 文件**，并从 GitHub（含 RAW fallback 数据源）拉取仓库映射。请特别留意：

- **恶意条目注入** — 若上游数据源被污染，可能写入指向恶意 IP 的 hosts 记录。写入前建议人工核对 diff。
- **权限要求** — 修改 hosts 通常需要管理员 / root 权限。不要以高权限常驻运行。
- **Shell 注入** — Bash 与 PowerShell 双实现都涉及字符串拼接。

## 致谢

有效漏洞报告将在致谢中注明。
