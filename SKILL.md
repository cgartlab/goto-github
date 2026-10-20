---
name: goto-github
description: GitHub 访问诊断与加速 skill。当用户说 GitHub 连不上/打不开/很慢/clone 失败/被墙、或问"GitHub 是否可用/直连是否正常/要不要改 hosts"、或需要诊断网络环境对 GitHub 各服务（网页/API/git/raw/下载）的连通性时激活：先探测环境（hosts/代理/DNS/gh 鉴权），再对 GitHub 各端点做统计采样判定，直连可用则报告、不可达则写入 hosts 标记块修复并验证。覆盖 macOS/Linux/Windows。Use this skill whenever the user asks whether GitHub is reachable or slow from their machine, wants to diagnose or fix GitHub connectivity problems (clone failures, page timeouts, API errors), or asks about modifying hosts for GitHub — even when they don't say "goto-github".
license: MIT
compatibility: Requires bash or PowerShell 7 (script detection per platform). curl is mandatory for probing. hosts modification requires admin/root privileges. All analysis is local — no third-party services. Windows PowerShell 5.1 is supported for the pull-based path only; the scan path requires PowerShell 7.
metadata:
  version: "2.0.0"
  date: "2026-10-20"
  reference: "https://github.com/cgartlab/goto-github"
---

# GoToGitHub — GitHub 连通性诊断与加速

诊断本机到 GitHub 的连通性，按证据分级判定，必要时写入 hosts 修复并验证。一次调用，给出可验证的结论：直连是否可用、哪个端点退化、要不要动 hosts、动完之后是否真的好了。

## 核心理念（3 条）

1. **先测后判，不猜**：任何结论必须来自实测采样（成功率 + 延迟分布），不来自单次 `curl` 的手感。单次成功/失败都是噪声——本 skill 的判定阈值建立在 10 次采样之上。判据见 `references/judgment-criteria.md`。
2. **分级报告，不糊成"能用/不能用"**：GitHub 是多个独立端点（网页/API/git/raw/下载），干扰是**按路径而非按 IP**的。实测中同 IP 的 API 100% 而网页 30%——报告必须分开说，合并成一个结论就丢掉了真正有用的信息。
3. **修必须有据，不改标记外部**：写 hosts 前先备份、检测遮蔽（其他工具的条目在标记上方会让整块失效）；只改 `# >>> goto-github >>>` / `# <<< goto-github <<<` 之间。失败必须留痕（`warnings[]`），把"没测成"写成"没有"是最危险的编造。

## 不可让渡的三条铁律（本文件只做路由，不复述细则）

1. **安全边界以 `references/safety-and-boundaries.md` 为准**（备份、标记块、遮蔽检测、不越界）。
2. **判定阈值与端点清单以 `references/judgment-criteria.md` 为准。**
3. **脚本 JSON 契约（字段、`null` vs `[]`）以 `references/probe-recipes.md` 为准。**

> 本文件只保留**路由** + **Phase 流程** + 上面 6 条元规则。历史上历次硬伤都源于 SKILL.md 内联了 references 的"速查副本"——副本更窄，且它是唯一保证被加载的文本，于是更弱的规则成了实际执行的规则。

## 何时使用

- 用户说 GitHub 打不开 / 连不上 / 很慢 / clone 失败 / push 失败 / 被墙。
- 用户问"GitHub 现在能用吗""直连是否正常""要不要改 hosts"。
- 需要诊断网络环境对 GitHub 各服务的连通性分级。

## 何时不用

- 用户只是问一个 git 命令怎么写、或某个 GitHub 页面内容是什么——直接答，别启动整套诊断。
- 目标是 GitLab / Bitbucket / 自建 Git 服务——本 skill 只针对 github.com 域名体系。

## 环境与前置探测（Phase 0，先做）

每次激活先跑 `scripts/env_detection.{sh,ps1} --help`，再调用它。它一次采齐六件事：

| 字段 | 为什么必须先知道 |
|---|---|
| `shell` | bash 还是 PowerShell——决定后续用哪套脚本 |
| `hosts_entry` | 已有 goto-github 条目 → 已装过，Phase 3 要覆盖写入 |
| `hosts_shadowed` | 标记上方有其他工具的 github.com 条目 → 整块失效，必须先报告 |
| `proxy_enabled` | 代理开着 → 所有探测都要绕代理，否则结论失真 |
| `dns_servers` | DNS 指向 → 解析结果是否可信的前提 |
| `gh_auth.state` | `keyring_ok` / `env_var_shadowed` / `none` → 影响 `gh` 命令是否可用 |

**`env_var_shadowed` 要单独报**：`GITHUB_TOKEN` 环境变量失效时，`gh` 会报 401，而 keyring 里的有效 token 被遮蔽。这不是网络问题，但会让用户以为 GitHub 出事了。`git` 操作走 credential.helper 不受影响——所以现象是"git 能用但 gh 不能"，诊断必须分开说。

环境不支持（无 curl / 非 Windows 却跑 ps1 路径）→ 停止并如实说明，不猜测结论。

## 脚本使用约定

`scripts/` 下是本 skill 的黑盒采集/执行脚本（bash `.sh` 与 PowerShell `.ps1` 两套，输出同形 JSON）。**先 `--help`（PowerShell 侧为 `-Help`）再调用**；除非 `--help` 不够用，不要读源码——它们存在是为了被调用，不是为了被读进上下文。

采集脚本只做只读探测，绝不自己写 hosts。执行脚本（`hosts_apply`）会改系统文件，调用前必须确认 Phase 2 判定为"需要修复"，且环境探测显示有权限（bash: root；Windows: 管理员）。字段语义见 `references/probe-recipes.md`，不要凭字段名猜。

## 工作流总览（决策树）

```
Phase 0 环境探测（env_detection）
   ├─ 无 curl / 平台不符          → 停止，说明原因
   └─ env_var_shadowed            → 记入报告，不影响后续探测
   |
Phase 1 连通性采样（connectivity_probe）
   └─ 5 端点 × N 次（默认 10），--noproxy 强制绕代理
   |
Phase 2 判定（judgment-criteria.md）
   ├─ direct_ok（git/API 高成功率）      → 跳 Phase 3，直接报告
   ├─ hosts_needed（git 可用但网页退化） → Phase 3 修复
   └─ proxy_needed（全端点都低）         → 建议代理，不建议 hosts
   |
Phase 3 修复（hosts_apply：优先级 IP → 社区源 → CIDR 扫描）
   ├─ 备份 → 写标记块 → 遮蔽检测 → 刷新 DNS
   └─ hosts_status 验证（复测 Phase 1 同端点）
   |
Phase 4 报告（含"是否已修复"判定 + warnings[]）
```

## Phase 1 — 连通性采样

调用 `connectivity_probe.{sh,ps1}`，采 5 个端点。**每个端点多次采样**（默认 10 次，`--attempts` 可调），输出成功率与 min/max/avg 延迟：

| 端点 | 测什么 |
|---|---|
| `github.com/` | 网页前端 |
| `api.github.com` | REST API（`gh` 走这条） |
| `codeload.github.com` | tarball/zip 下载 |
| `raw.githubusercontent.com` | raw 文件 |
| `github.com info/refs` | git smart-HTTP 协议（clone/fetch/push 走这条） |

**为什么要绕代理**：探测必须加 `--noproxy '*'`（curl）或清空代理配置。代理开着时测出来的是代理质量，不是本机到 GitHub 的真实连通性——结论会完全反向。

**为什么多次采样**：单次请求的成败在这个网络环境下接近随机（实测同一端点连续 10 次成功率在 30%–100% 间波动）。判定阈值只对成功率有意义，对单次结果没有意义。

## Phase 2 — 判定

按 `references/judgment-criteria.md` 的阈值分级。三条要点：

1. **git 端点权重最高**。clone/fetch/push 全走 smart-HTTP，API 走 api.github.com——这两个可用，"开发用途"就是可用的，网页退化不等于不能用。
2. **网页单独看**。网页路径（`github.com/`）与 git/API 路径（`info/refs`、`api.`）可能差 40 个百分点，实测如此。报告必须分开写。
3. **全端点都低时不要建议 hosts**。hosts 只改域名→IP 映射，挡不住路径级封锁或整体阻断；那种情况应该建议代理，写 hosts 是无效动作。

## Phase 3 — 修复

判定为 `hosts_needed` 时调用 `hosts_apply.{sh,ps1}`。策略有序降级（快路径优先，重扫描兜底）：

```
1. 优先级 IP    已知稳定的少量 IP，先试（秒级）
2. 社区源拉取   GitHub520 等源，取一批已验证 IP
3. CIDR 扫描    展开网段并发探测（分钟级，最后兜底）
```

写盘顺序固定：**备份 → 写标记块 → 遮蔽检测 → 刷新 DNS**。任何一步失败即中止，hosts 保持原样（备份已留）。幂等：重复运行不产生重复标记块。

探测目标**必须是 git smart-http 端点**（`info/refs?service=git-upload-pack`），不是首页：部分边缘 IP 能返回首页但不通 git 流量，用首页探测会选出"假阳性"IP。

## Phase 4 — 报告

调用 `hosts_status.{sh,ps1}` 复测，与 Phase 1 数据对比，输出四件事：

1. **修复前状态**：5 端点成功率表（Phase 1 数据）。
2. **修复动作**：用了哪个策略、写入哪个 IP、备份文件路径。
3. **修复后状态**：复测结果，与修复前对比。
4. **判定**：`fixed` / `partial`（部分端点改善）/ `not_fixed` + `warnings[]`。

`partial` 和 `not_fixed` 也要如实说——写入 hosts 不等于修好了，验证不过就是没过。
