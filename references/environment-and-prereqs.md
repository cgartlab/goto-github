# 环境与前置要求

Phase 0 前必须满足的条件，以及不支持的环境如何退出。

## 硬依赖

| 依赖 | 用途 | 缺失时 |
|---|---|---|
| `curl` | 全部探测与 hosts 写入 | 停止，说明"无法探测"。bash 侧无 curl 时不得退回 `wget`（其 `--resolve` 语义不同，探测结果不可比） |
| bash 或 PowerShell 7 | 运行脚本 | 见下方平台矩阵 |

curl 必须支持 `--resolve`（强制域名→指定 IP）。所有主流 curl 均支持；`--noproxy` 亦为必需。

## 平台矩阵

| 平台 | 可用脚本 | 说明 |
|---|---|---|
| macOS / Linux | `.sh` | bash 3.2+ |
| Windows PowerShell 7 | `.ps1` | 全部功能 |
| Windows PowerShell 5.1 | `.ps1`（仅拉取式） | 扫描式路径用 `ForEach-Object -Parallel` 等 PS7 特性，5.1 下语法错误 |
| Git Bash (Windows) | `.sh` | 需管理员权限写 hosts |
| WSL | 不支持 | WSL 的 hosts 行为与 Windows 不同，检测到则打印重定向说明并停止 |

**PS 5.1 限制的依据**：`-Parallel`（PS7）、`-Encoding utf8NoBOM`（PS7）、`[System.IO.File]::Move` 三参重载（.NET Core）。这些在 5.1 下直接失败，不是"降级"而是"报错"。

## 探测前必须绕代理

代理开启时测的是代理质量，不是本机→GitHub。必须：

- curl：`--noproxy '*'`
- PowerShell：`Invoke-WebRequest` 不继承代理配置，或显式 `-Proxy` 空

`connectivity_probe` 的 `proxy_bypassed` 字段必须为 `true`，否则结论不可用于判定。

## 权限（探测与修复不同）

| 动作 | 所需权限 |
|---|---|
| Phase 0/1 探测 | 无（普通用户） |
| Phase 3 写 hosts | root / 管理员 |
| Phase 4 复测 | 无 |

探测不需要特权——这是设计使然：先无特权诊断，再决定是否要特权修复。用户可以在没有管理员权限的情况下得到完整的分级报告。

## gh CLI 鉴权（可选，只影响 gh 相关诊断）

`gh_auth.state` 三态：

- `keyring_ok` — keyring 有效 token 生效
- `env_var_shadowed` — 环境变量 `GITHUB_TOKEN` 失效，遮蔽 keyring。**非网络问题**，但会让所有 `gh` 命令 401
- `none` / `error` — 无有效凭据

git 操作走 credential.helper，与 `gh` 的 token 解析路径不同。所以"git 能用但 gh 401"是可能的，且原因是本地配置不是网络。

## 退出条件（不猜测）

| 情况 | 行为 |
|---|---|
| 无 curl | 停止，说明无法探测 |
| WSL | 停止，说明 hosts 行为不同 |
| PS 5.1 + 扫描式路径 | 停止，说明需要 PS 7 |
| DNS 完全无法解析 | 继续探测（结果会显示失败），但在报告中单列"DNS 层故障"——这与"IP 层被阻断"是不同的根因 |

## 时变干扰的提示

实测：同一端点 1 分钟间隔的两次采样可差 30 个百分点。所以：

- 报告必须带时间戳。
- 引用几小时前的结论时必须重新采样。
- `--attempts` 少于 5 时，报告须标注样本不足。
