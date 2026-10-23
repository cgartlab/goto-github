# 判定标准 - GitHub 连通性与凭据分级

Phase 2 的唯一权威判据。SKILL.md 不复述这些数字。

## 两个独立维度

判定分两层，**永不合并**：

| 维度 | 问题 | 由谁产出 |
|---|---|---|
| `network` | 这台机器能不能到达 GitHub？哪条路径退化了？ | `connectivity_probe` → `hosts_status` |
| `auth` | 这条路径需要的凭据在不在？ | `auth_probe` |

合并这两层是本 skill 最需要避免的错误：把「我没配密钥」报成「GitHub 不通」，会让用户去修网络——而网络根本没坏。

## 端点清单（固定，不可随意增减）

| key | URL | group | kind | 走这条路径的东西 |
|---|---|---|---|---|
| `web` | `https://github.com/` | web | http | 浏览器访问 |
| `api` | `https://api.github.com/` | api | http | REST / GraphQL / `gh` |
| `git_read` | `.../info/refs?service=git-upload-pack` | git | git-smart | clone / fetch |
| `git_write` | `.../info/refs?service=git-receive-pack` | git | git-smart | push |
| `raw` | `raw.githubusercontent.com/...` | raw | http | raw 文件 |
| `gist` | `gist.githubusercontent.com/` | raw | http | gist |
| `download` | `codeload.github.com/...tar.gz` | download | http | tarball / zip |
| `assets` | `github.githubassets.com/` | assets | http | 静态资源 |
| `ssh22` | `tcp://github.com:22` | ssh | tcp | SSH 传输（默认端口） |
| `ssh443` | `tcp://ssh.github.com:443` | ssh | tcp | SSH 传输（22 被封时） |

`--scope all` 追加：`ghcr`（容器镜像）、`npmpkg`、`mavenpkg`、`avatars`、`objects`、`pages`。

**为什么固定这些**：覆盖 GitHub 的全部独立路径（前端、API、git 读写、raw、下载、静态资源、SSH、registry）。少测一个就可能漏掉真实退化——实测 `git_write` 与 `git_read` 会分别失效。

**为什么探测必须绕代理**：`--noproxy '*'`。代理开启时测的是代理质量，不是本机→GitHub。

## network 维度阈值

| 分级 | 条件 | 结论 |
|---|---|---|
| `direct_ok` | `git_read` ≥ 85% **且** `api` ≥ 85% | 直连可用，不用改 hosts |
| `hosts_needed` | `git_read` ≥ 85% 或 `api` ≥ 85%，但 `web` < 60% | hosts 加速有实际收益（仅影响浏览） |
| `partial_degraded` | `git_read` 或 `api` 在 50%–85% | 间歇可用，hosts 可能改善，先说明再动 |
| `proxy_needed` | `git_read` < 50% **且** `api` < 50% | 不建议 hosts，建议代理 |

阈值依据（本机实测多轮 × 10 次/端点）：

- `git_read` 与 `api` 在直连环境下多数时候 ≥ 85%。低于此说明环境本身有问题。
- `web` 在直连环境下可低至 0%，且与 `git_read` 同 IP——**按路径干扰的直接证据**。所以 `web` 单独设阈值，不与 git 合并。
- 全端点 < 50% 时，hosts 改变的是域名→IP 映射，对整体阻断或路径级封锁无效。

## git 端点权重最高的理由

clone / fetch / push 全部走 git smart-HTTP，`gh` 与 CI 全部走 api。这两个可用 = "开发用途可用"。网页退化只影响浏览器浏览。

**因此报告禁止把端点合并成一个"GitHub 可用/不可用"结论。** 必须分端点列出成功率，再给分级。

非核心端点（`raw` / `gist` / `download` / `assets` / `ssh*` / registry）**报告但不参与分级**——一个 registry 慢不应把"能不能 clone"降级。它们出现在 `endpoints[]` 里供用户自行判断。

## auth 维度状态

| 路径 | 状态 | 含义 | 建议 |
|---|---|---|---|
| `ssh` | `transport-ok` | 密钥已授权 | 无 |
| | `auth-fail` | **传输正常**，密钥未注册 | 改用 HTTPS，或把公钥加到 GitHub |
| | `blocked` | 端口被封 | 改用 HTTPS 或 `ssh.github.com:443` |
| | `no-key` | 无密钥且 agent 未运行 | 用 HTTPS |
| `https` | `ok` | helper 可用且有 push 权限 | 无 |
| | `permission-denied` | 凭据有效但无写权限 | 换 token 或申请权限 |
| | `no-credentials` | 无 credential helper | 配置 `gh auth login` |
| `gh` | `keyring_ok` | 正常 | 无 |
| | `env_var_shadowed` | `GITHUB_TOKEN` 失效并遮蔽 keyring | 删除该环境变量 |
| | `none` | 无凭据 | `gh auth login` |

**`auth-fail` 与 `blocked` 的区别是判定关键**：
- `Permission denied (publickey)` → 走到了认证阶段 → 传输没问题 → `auth-fail`
- `Connection refused` / `timed out` → 没走到认证 → 传输有问题 → `blocked`

实测本机就是 `auth-fail`：`github.com:22` 与 `ssh.github.com:443` 都 TCP 可达，只是 `~/.ssh/id_rsa` 没在 GitHub 注册。而 git 走 HTTPS（`credential.https://github.com.helper = !gh auth git-credential`），push 实测通过——所以 SSH 不配完全不影响工作。

## 单次结果不是证据

同一端点在 1 分钟间隔内的两次 10 次采样可以差 30 个百分点（实测 `web` 60% → 30%，`git_read` 100% → 70%）。所以：

- 判定只用成功率，不用单次成败。
- 默认 10 次采样；少于 5 次时报告必须标注 `sample_size` 并说明"样本不足，判定不稳"。
- 复测（Phase 3 后）必须用与 Phase 1 相同的 `--attempts`，否则前后不可比。

## 改善的噪声阈值

`hosts_status --baseline` 判定"是否改善"时，端点成功率必须**高出基线至少 10 个百分点**才算改善。

理由：采样噪声本身就能产生 1–2 个百分点的波动（实测 99% → 100% 纯属偶然）。把这种波动计为"修复生效"会让 `partial` 泛滥——而那正是 baseline 对比要避免的假阳性。

## 采样时延也要报

成功率之外输出 min/max/avg：

- 成功但慢（avg > 3s）→ 报告"可用但体验差"，这与"不可用"是不同的结论。
- max 远高于 avg（如 avg 0.8s 而 max 6s）→ 尾部延迟差，间歇性丢包的典型形态。

## 时变干扰

实测两轮间隔仅数分钟，成功率出现 30 个百分点波动。结论必须带时间戳；用户拿几小时前的结论当现状是误用。复测永远优先于引用旧数据。
