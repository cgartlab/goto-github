# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Two version lines

The repository ships two things, and they version independently:

- **Skill package** — `SKILL.md` `metadata.version` + this file's headings.
  Bumped when the skill's contract (Phase flow, JSON fields, thresholds) changes.
- **CLI artifacts** — `install.sh` `VERSION` and `goto-github.ps1` `$script:VERSION`.
  These are what installed users see via `install.sh --version` and
  `goto-github.ps1 --version`. Bumped only when the CLI's user-visible
  behaviour changes.

2.0.0 restructures the repository into a skill package and fixes the `ps1/`
implementation's defects, but the shipped CLI entry points behave the same, so
the CLI artifacts stay at 1.0.0. Do not "helpfully" sync the two numbers — an
`install.sh --update` against a mismatched `VERSION` reports a bogus upgrade.

2.1.0 keeps that split: the skill's service surface, auth model and platform
support all changed, while the CLI entry points still behave the same, so the
CLI artifacts remain at 1.0.0.

## [2.1.0] — 2026-10-23

目标：在 macOS / Windows / Linux 上运行即可打通本地直连访问**全部** GitHub
服务。2.0.0 只测 5 个端点、要求 PowerShell 7、且把认证失败报成网络失败，
不满足这个目标。

### Added — 服务面从 5 个端点扩到 10+ 个

`scripts/lib/endpoints.{sh,ps1}` 成为端点清单的唯一真源，两个实现共享。

| 端点 | 覆盖 |
|---|---|
| `git_read` | git smart-http `upload-pack`（clone / fetch） |
| `git_write` | git smart-http `receive-pack`（**push**，此前完全未测） |
| `ssh22` / `ssh443` | SSH 传输层（22 端口，以及 22 被封时的 443 备用口） |
| `gist` / `assets` | gist 与静态资源 |
| `--scope all` | 追加 ghcr / npm.pkg / maven.pkg / avatars / objects / pages |

`git_write` 是新增的关键覆盖：只探读路径时，push 失败skill 无法解释。

### Added — `auth_probe` 把「认证失败」与「网络失败」分开

新脚本 `scripts/auth_probe.{sh,ps1}`，三路凭据状态，与网络维度并列、永不合并：

```
ssh.state     transport-ok | auth-fail | blocked | no-key | unknown
https.state   ok | permission-denied | no-credentials | unknown
gh.state      keyring_ok | env_var_shadowed | none | error
```

关键区分：`Permission denied (publickey)` → `auth-fail`（传输已通，密钥未注册）；
`Connection refused` / `timed out` → `blocked`（根本没连上）。两者都让 `ssh -T`
失败，但修复方向完全相反。

一次失败的 `git push` 至少有四种原因，连通性探测会把它们全报成 FAIL 并把
用户引向修网络——这正是本 skill 最该避免的错误。

### Added — 三平台 CI 门禁

新增 `cross-platform` job，矩阵 `ubuntu-latest / macos-latest / windows-latest`：

1. `.sh` 行尾检查（CRLF 让 shebang 变成 `bash\r`，Linux/macOS 无法执行）
2. bash 3.2 构造检查（`declare -A` / `mapfile` / `${x,,}` / nameref）
3. `.ps1` 编码检查（非 ASCII 且无 BOM 时 PS 5.1 按 ANSI 码页解码）
4. 嵌套 heredoc 检查（bash 3.2 无法解析 `$(cat <<EOF)`）
5. 五阶段端到端 `evals/run_e2e.sh`
6. 冒烟 `SKIP_NETWORK=1`

### Added — `evals/run_e2e.sh`

按用户真实用法跑完整五阶段（Phase 0 → 1 → 1b → 3 → 4），同时覆盖 bash 与
PowerShell 两条路径。与 `run_smoke.sh` 分工：smoke 检查单脚本契约，e2e 检查
阶段之间的衔接。不依赖网络。

### Changed — PowerShell 5.1 真正可用

Windows 默认是 PS 5.1，2.0.0 的 3 个 skill 脚本声明 `#Requires -Version 7.0`，
在默认环境直接拒绝运行。

- `ForEach-Object -Parallel` → runspace pool（5.1/7 都支持）
- `File.Move(src, dst, overwrite)` → `File.Replace`（三参重载是 .NET Core 专属）
- `[Type]::new()` → `New-Object` / 强制转换
- 临时文件改到 hosts 同目录（`File.Replace` 要求同卷）
- 7 个 `.ps1` 归一为纯 ASCII（PS 5.1 按 ANSI 码页解码无 BOM 文件会乱码）

### Fixed — 跨平台致命缺陷（4 个，全部由 CI 暴露）

- **`.sh` 写入 CRLF**：shebang 变 `bash\r`，Linux/macOS 报
  `/usr/bin/env: 'bash\r': No such file`
- **`declare -A`**：macOS 自带 bash 3.2 不支持关联数组，直接语法错误
- **`case` 嵌套在 `$( )` 的 `for` 循环内**：bash 3.2 报
  `syntax error near unexpected token ';;'`，指向一行完全合法的代码。
  本地 bash 5.3 与 Linux CI 全绿，只有 macOS 暴露
- **`mktemp -t prefix-XXXXXX`**：BSD mktemp 要求 Xs 是最后字符

### Fixed — 其他

- `hosts_status` 改善判定加 10 个百分点噪声阈值：99% → 100% 的 1 点波动
  曾被计为「修复生效」
- bash 拼 JSON 未转义反斜杠会让整行不可解析（Windows 路径）
- PowerShell `Write-Warning` 的 warning stream 在管道捕获时被转发到 stdout，
  破坏「stdout 只有一行 JSON」契约
- `backup_hosts()` 的返回值被 `set -o pipefail` 污染（`ls` 空 glob 返回非零）
- `Get-Service` 检测 ssh-agent 在 Linux/macOS 上不存在

### Changed — 判定模型

`references/judgment-criteria.md` 改写为**两个独立维度**：`network`（四档）+
`auth`（三路），明确禁止合并。非核心端点（raw / gist / download / assets /
ssh* / registry）报告但不参与分级——一个 registry 慢不应把「能不能 clone」降级。

### Verification

| 平台 | 运行时 | 结果 |
|---|---|---|
| macOS | bash 3.2.57（系统自带） | e2e pass |
| Ubuntu | bash 5.x | e2e pass |
| Windows | PowerShell 5.1 + Git Bash | e2e pass |

本机（Windows）另跑：`shellcheck --severity=warning` 0 warning、bash 单元测试
5 文件全过、`parity` OK、PS7 单元测试 58/58、PSScriptAnalyzer 0 error、
`evals/run_e2e.sh` 25/25。

## [2.0.0] — 2026-10-20

### Added — Skill 包形态

仓库重构为 **Agent Skill 包**：仓库即 skill，CLI 引擎保留为 skill 的修复引擎，两种用法共享同一套引擎与安全边界。

- `SKILL.md` — skill 入口（frontmatter + 路由 + Phase 决策树 + 6 条元规则）
- `references/` — 细则唯一真源：
  - `judgment-criteria.md` 5 端点固定、4 档分级阈值、噪声阈值
  - `probe-recipes.md` 4 个脚本的 JSON 字段语义、`null` vs `[]` 约定
  - `safety-and-boundaries.md` hosts 红线
  - `environment-and-prereqs.md` 平台矩阵与退出条件
- `scripts/` — 黑盒脚本（bash `.sh` + PowerShell `.ps1` 双套同形 JSON）：
  - `env_detection` Phase 0 环境探测
  - `connectivity_probe` Phase 1 5 端点 × N 次统计采样
  - `hosts_apply` Phase 3 写盘
  - `hosts_status` Phase 4 复测 + verdict
  - `lib/constants.{sh,ps1}` skill 层常量真源（独立于 CLI 的 `lib/` 与 `ps1/lib/`）
- `evals/evals.json` + `evals/run_smoke.sh` — 6 个用例 + 18 项机械断言
- `make skill-test` target

### Added — ps1/ 缺陷修复

原 argus 评审 P1/P2/P3 全部消解：

- **P1** probe 目标从 `github.com` 首页改为 git smart-http 端点（`02-scan.ps1` 3 处 + `03-validate.ps1` 1 处）。首页会选出"假阳性"IP——能返回首页但不通 git 流量
- **P2** `Set-HostsBlock` 增加备份 + 按 `KEEP_BACKUPS` 轮换，备份失败即中止
- **P2** 写 temp 后先把原 hosts 的 ACL 应用到 temp，避免 `File.Move` 覆盖时丢权限
- **P2** 新增 `Get-ShadowingState`，标记上方有其他工具的 `github.com` 条目时明确报"整块 INERT"
- **P3** UAC 取消时 `$proc` 为 null 导致 `StrictMode` 抛 `PropertyNotFound`，改为 `exit 1`

### Added — 测试与 CI

- `tests/test-ps-02-scan.ps1` 新增 2 个断言锁死 probe 目标（PS 断言 56 → 58），并做反向验证：把 `PROBE_TARGET` 改回首页 → 3 个断言 FAIL 且退出码 1
- CI `pwsh-test` job 增加 skill 脚本测试（写盘链路 + 幂等性 + verdict）
- CI 增加 SKILL.md frontmatter schema 校验与 `references/` 路径触发

### Fixed — 重构过程中发现并修掉的缺陷

- **`PROBE_TARGET` 重复定义**：`00-constants.ps1` 与 `02-scan.ps1` 各一份，后 source 的静默遮蔽前者。后果是改常量做回归验证时测试读到旧值，反向验证连续报 PASS
- **bash 拼 JSON 未转义反斜杠**：`hosts_apply.sh` 的 `backup` 字段在 Windows 下输出 `C:\...` 原样反斜杠，JSON 非法，`ConvertFrom-Json` 报 `Unrecognized escape sequence`，双语言契约破裂
- **PowerShell `Write-Warning` 污染 stdout**：warning stream 在管道捕获时被转发到 stdout，打破"stdout 只有一行 JSON"的契约。改用 `[Console]::Error.WriteLine`
- **`hosts_status` 改善判定无噪声阈值**：99% → 100% 的 1 个百分点波动被计为"修复生效"，导致 `partial` 泛滥。新增 10 个百分点噪声阈值
- 4 个 PowerShell skill 脚本此前全部缺 `-Help`（报"找不到与参数名称 '-help' 匹配的参数"），与 SKILL.md 的"先 `--help` 再调用"契约相悖

### Changed

- `README.md` 重写为双身份：Skill 用法 + CLI 用法
- `CLAUDE.md` / `AGENTS.md` / `CONTRIBUTING.md` 同步 skill 包结构、双语言契约、测试钩子
- `Makefile` 纳入 `scripts/` 与 `evals/`
- `LESSONS.md` 新增 5 条教训（重复定义、JSON 转义、`Write-Warning`、PowerShell 语句当表达式、`-f` 格式化 JSON）

### Verification

| 检查 | 结果 |
|---|---|
| `bash -n`（所有 `.sh`） | 通过 |
| `shellcheck --severity=warning` | 0 warnings（覆盖 `scripts/`、`evals/`） |
| bash 单元测试 | 5 文件全过 |
| `shared/parity-check.sh` | PARITY OK |
| PowerShell 单元测试 | 58/58（原 56） |
| PSScriptAnalyzer | 0 error / 8 warning（与重构前一致，未引入新项） |
| 双语言 JSON 契约 | 4 组字段集合全部一致 |
| 写盘链路实测 | 标记块写入、块外内容保留、幂等、备份生成 |
| 反向验证 | `PROBE_TARGET` 回归首页 → 断言 FAIL 且退出码 1 |
| `evals/run_smoke.sh` | 18 PASS / 0 FAIL |

## [1.0.0] — 2026-02-06

### Added

- Bash 实现：`fetch.sh` + `lib/` 模块（00-constants .. 04-apply）
- PowerShell 实现：`goto-github.ps1`（拉取式，已发布）
- PowerShell 扫描式实现：`ps1/`（实验性，opt-in）
- 数据源：jsDelivr CDN GitHub520（主）→ raw.hellogithub.com（备）
- IP 探测兜底：源 IP ±7 的 /24 候选池，两轮探测过滤 flaky IP
- 遮蔽检测、备份轮换、幂等写入
- 单元测试（bash + ps1）、`shared/parity-check.sh`、CI（shellcheck + 测试 + parity + PSScriptAnalyzer）
- 一键安装：`install.sh`（Unix）、`bootstrap.ps1` / `install.ps1`（Windows）
