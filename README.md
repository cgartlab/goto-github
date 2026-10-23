# GoToGitHub

[![Lint](https://github.com/cgartlab/goto-github/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/cgartlab/goto-github/actions/workflows/shellcheck.yml)
[![Argus-Flash Review](https://github.com/cgartlab/goto-github/actions/workflows/argus-review.yml/badge.svg)](https://github.com/cgartlab/goto-github/actions/workflows/argus-review.yml)
[![MIT License](https://img.shields.io/github/license/cgartlab/goto-github?style=flat-square)](https://github.com/cgartlab/goto-github/blob/main/LICENSE)

GitHub 访问诊断与加速。先探测本机到 GitHub 各端点的连通性，按证据分级判定，必要时写入 hosts 修复并验证。

**两种用法**：作为 **Agent Skill** 让 AI 自动诊断修复，或作为 **CLI 工具**手动使用。两种用法共享同一套引擎与安全边界。

---

## 作为 Skill 使用

仓库本身即 skill。经 magpie Library 安装后，对 Agent 说：

- "GitHub 打不开 / 连不上 / 很慢"
- "clone 失败 / push 失败"
- "GitHub 现在能用吗 / 直连是否正常 / 要不要改 hosts"

Skill 会依次执行：环境探测 → 10+ 端点统计采样 → 分级判定 → （需要时）写 hosts 修复 → 复测验证，最后给出分级报告。

核心设计：**分级报告而非"能用/不能用"**。GitHub 是多个独立端点，干扰按路径而非按 IP——实测中同 IP 的 API 100% 而网页 30%。合并成一个结论会丢失真正有用的信息。

```
Phase 0   环境探测     hosts 条目 / 遮蔽 / 代理 / DNS / gh 鉴权 / DoH
Phase 1   连通性采样   10+ 端点 × N 次（默认 10），绕代理，000 不计成功
                       web / api / git_read / git_write / raw / gist /
                       download / assets / ssh22 / ssh443
Phase 1b  凭据探测     ssh / https / gh 三路状态，与网络维度分开
Phase 2   判定         network（四档）+ auth（三路），两个维度永不合并
Phase 3   修复         优先级 IP → 社区源 → CIDR 扫描；备份→标记块→遮蔽检测→刷 DNS
Phase 4   报告         复测对比，未改善则如实报 not_fixed
```

**认证失败不等于网络失败**。一次失败的 `git push` 至少有四种原因，连通性探测会把它们全报成 FAIL 并把用户引向修网络：

```
auth_probe 实测输出：
  ssh    auth-fail        <- 传输正常（22/443 都可达），密钥未在任何 GitHub 账号注册
  https  ok               <- gh token 有 push 权限，所以 push 一直正常
  gh     keyring_ok
```

Skill 文档：`SKILL.md`（路由与流程）、`references/`（判定阈值、JSON 契约、安全边界、环境要求）。

---

### 直接运行 skill 脚本

脚本是黑盒的：先 `--help`，输出单行 JSON 到 stdout，进度走 stderr。不通过 Agent 也能用。

**bash（macOS / Linux / Git Bash）**

```bash
./scripts/env_detection.sh                    # Phase 0 环境探测（只读）
./scripts/connectivity_probe.sh --attempts 10 # Phase 1 连通性采样（只读）
./scripts/connectivity_probe.sh --scope all   # 追加 registry / pages
./scripts/auth_probe.sh                       # Phase 1b 凭据状态（只读）
sudo ./scripts/hosts_apply.sh                 # Phase 3 写 hosts（需 root）
./scripts/hosts_status.sh --baseline before.json  # Phase 4 复测（只读）
```

**PowerShell（Windows，5.1 与 7 均可）**

```powershell
.\scripts\env_detection.ps1                     # Phase 0
.\scripts\connectivity_probe.ps1 -Attempts 10   # Phase 1
.\scripts\connectivity_probe.ps1 -Scope all     # 追加 registry / pages
.\scripts\auth_probe.ps1                        # Phase 1b
.\scripts\hosts_apply.ps1 -Strategy auto        # Phase 3（需管理员）
.\scripts\hosts_status.ps1 -Baseline .\before.json
```

典型用法：先 `connectivity_probe.sh > before.json` 存基线，`hosts_apply` 修复，再 `hosts_status.sh --baseline before.json` 看是否真的改善。


---

## 作为 CLI 使用

### 一键安装

| 平台 | 命令 |
|------|------|
| macOS / Linux | `curl -sfL https://raw.githubusercontent.com/cgartlab/goto-github/main/install.sh \| bash` |
| Windows PowerShell | `irm https://raw.githubusercontent.com/cgartlab/goto-github/main/bootstrap.ps1 \| iex` |

国内网络可用 jsDelivr 镜像：把 URL 里的 `raw.githubusercontent.com` 换成 `cdn.jsdelivr.net/gh/cgartlab/goto-github@main`。

### Bash (macOS / Linux / Git Bash)

| 命令 | 功能 | 需 sudo |
|------|------|---------|
| `sudo ./fetch.sh` | 拉取 → 验证 → 写入 hosts → DNS 刷新 | ✅ |
| `./fetch.sh --status` | 显示当前 IP 和连通性 | ❌ |
| `./fetch.sh --probe` | 探测可用的 github.com IP（诊断用，不写 hosts） | ❌ |
| `sudo ./fetch.sh --restore` | 移除 goto-github 条目 | ✅ |
| `./fetch.sh --help` | 显示帮助 | ❌ |

#### 自动刷新与卸载（bash 侧需自建）

bash 版本是**无状态脚本**：不注册计划任务。运行时会写 hosts 标记块，并在其旁边保留最近 5 个 `hosts.goto-github.bak.*` 备份；除此之外不写任何系统位置。
`ps1/` 的 `install` 会注册每 3 小时的 SYSTEM 任务，bash 侧没有对应物——这是有意的，
因为 launchd / systemd / cron 三种宿主各有语义（用户级 vs 系统级、唤醒补跑、
失败重试），硬做一套会引入比它解决的问题更多的不确定性。

需要自动刷新时，用你自己的调度器。hosts 里的 IP 会失效，刷新频率取 3–6 小时较合适。

注意：安装脚本把命令放在 ~/.local/bin/goto-github（不是 /usr/local/bin），而定时任务以 root 身份运行时 ~ 指向 root 的家目录，所以下面一律写绝对路径 —— 把 /home/YOU 换成实际安装用户的 home。

**Linux（systemd timer，关机 / 休眠后自动补跑）**

```ini
# /etc/systemd/system/goto-github.service
[Unit]
Description=Refresh GitHub hosts entries
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/home/YOU/.local/bin/goto-github
```

```ini
# /etc/systemd/system/goto-github.timer
[Unit]
Description=Refresh GitHub hosts entries every 3h

[Timer]
OnBootSec=5min
OnCalendar=*:0/3
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now goto-github.timer
```

> **`Persistent=true` 只对 `OnCalendar=` 生效。** 单调定时器（`OnBootSec` / `OnUnitActiveSec`）在休眠或关机期间不会补跑——如果只用那两种，错过的时间段就跳过了。上面的组合用 `OnBootSec` 覆盖开机，用 `OnCalendar` + `Persistent` 覆盖日常与补跑。

**Linux / macOS（cron，更简单但没有唤醒补跑）**

```bash
sudo crontab -e
# 每 3 小时的第 17 分钟执行
17 */3 * * * /home/YOU/.local/bin/goto-github >/dev/null 2>&1
```

**卸载**

```bash
# $HOME 在 sudo 之前展开；sudo 通常会把 PATH 重置为 secure_path，
# 里面不含 ~/.local/bin，直接写 `sudo goto-github` 会 command not found。
sudo "$HOME/.local/bin/goto-github" --restore
rm -rf ~/.local/share/goto-github ~/.local/bin/goto-github
```

如果按上面的示例配了定时器，先停掉它，否则删掉二进制后它会一直失败：

```bash
sudo systemctl disable --now goto-github.timer
sudo rm -f /etc/systemd/system/goto-github.service \
           /etc/systemd/system/goto-github.timer
sudo systemctl daemon-reload
# cron 用户：sudo crontab -e 删掉那行 goto-github

# 备份文件保留在 hosts 旁边，确认无误后可清理：
#   sudo rm -f /etc/hosts.goto-github.bak.*
```

> `--restore` 不会碰 hosts 里其他工具的条目。

### PowerShell (Windows)

| 命令 | 功能 | 需管理员 |
|------|------|---------|
| `.\goto-github.ps1` | 交互菜单 | 修改 hosts 时需要 |
| `.\goto-github.ps1 --pwsh status` | JSON 状态（脚本用） | ❌ |
| `.\goto-github.ps1 --pwsh auto` | 一键加速 | ✅ |
| `.\goto-github.ps1 --pwsh restore` | 恢复 hosts | ✅ |

> **两套 PowerShell 实现并存且互斥**：根 `goto-github.ps1`（拉取式，`install.ps1` 实际发布）与 `ps1/`（扫描式，实验性，**不**默认下载）。二者标记相同、写同一个 hosts，同装会互相覆盖；CLI 接口也不兼容（`--pwsh auto|status|restore|source` vs `run|install|status|help|uninstall`）。

---

## 工作原理

```
数据源（jsDelivr CDN 加速）→ fetch.sh → 内容验证 → 写入 /etc/hosts → DNS 刷新
```

1. **拉取** — 从 GitHub520 社区项目获取 hosts，失败时自动切换备用源
2. **验证** — 检查 IP 条目数量（≥10）和 github.com 域名存在性
3. **写入** — 在 `/etc/hosts` 中以标记区块隔离写入，不影响其他条目
4. **刷新** — macOS / Linux 刷新本地 DNS 缓存
5. **探测** — 当所有源的核心 IP 均不可达时，自动探测可用的 GitHub 边缘 IP

### 数据源

| 源 | 说明 |
|----|------|
| `cdn.jsdelivr.net/gh/521xueweihan/GitHub520@main/hosts` | 主源（CDN 加速） |
| `raw.hellogithub.com/hosts` | 备用源（回退使用） |

### IP 探测（兜底）

GitHub 按 IP 精确干扰时，社区源列出的 IP 可能恰好被阻断。此时不会直接报错，而是主动探测：

- **候选池** — 数据源中出现的唯一 IP，各扩展 ±7 的 /24 窗口（上限 300），去重后取前 50 个
- **探测目标** — `github/gitignore` 的 git smart-http 端点，而非 `github.com` 首页。部分边缘 IP 能返回首页但不通 git 流量，只测首页会选出"假阳性"IP
- **并发测试** — 返回首个 HTTP 2xx 的 IP，写入 hosts 启用探测模式

单独诊断：`./fetch.sh --probe`（只探测不写 hosts）。

⚠️ 探测到的 IP 同样是动态的，后续可能失效。另外，如果 `/etc/hosts` 在 goto-github 标记**之前**存在其他工具写入的 github.com 条目，它会优先生效并遮蔽本工具的映射 —— 脚本会在应用后警告此情况，需手动处理。

---

## 安全边界

- **只改标记区块内部**：`# >>> goto-github >>>` / `# <<< goto-github <<<` 之外一律不碰
- **先备份再写**：备份失败即中止，hosts 保持原样
- **遮蔽检测**：标记上方有其他工具的 github.com 条目时警告（不修改区块外部）
- **幂等**：重复运行不产生重复标记块
- **不自动提权**：需要 root/管理员时报告命令，不自动 `sudo` / 不弹 UAC

---

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `HOSTS_FILE` | `/etc/hosts` | 指定 hosts 文件路径 |
| `PROBE_REPO` | `cgartlab/goto-github` | git/下载探测端点用的仓库 |
| `GOTO_GITHUB_TEST_PRIVILEGED` | — | 置 `1` 跳过权限检查（仅测试，不授予真实权限） |
| `GOTO_GITHUB_FORCE_IP` | — | 绕过探测直接指定 IP（仅测试） |

## 依赖

| 平台 | 依赖 |
|------|------|
| macOS / Linux | Bash 3.2+、curl |
| Windows | PowerShell 5.1+（拉取式与 skill 脚本）或 PowerShell 7+（扫描式 `ps1/`）、curl.exe |

所有平台修改 hosts 均需要管理员权限。

## 平台

- **macOS / Linux**: Bash 脚本
- **Windows**: PowerShell 原生实现（无需 Git Bash）
- **WSL**: 不支持（hosts 行为与 Windows 不同）

## 开发

```bash
make lint        # shellcheck --severity=warning（0 warnings，含 scripts/ 与 evals/）
make test        # bash 单元测试（mock curl，无需网络）
make parity      # bash ↔ PowerShell 常量一致性
make skill-test  # skill 脚本 --help 冒烟
make e2e         # 五阶段端到端（bash + PowerShell 两条路径）
make ps-test     # ps1/ 单元测试（仅 Windows，需 pwsh 7）
```

要做的改动若对应 `TASKS.md` 里的条目，按它的验收标准收尾。

## 许可证

MIT
