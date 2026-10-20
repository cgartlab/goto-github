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
