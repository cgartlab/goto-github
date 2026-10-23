# CLAUDE.md

## Project Overview

**GoToGitHub** — GitHub 连通性诊断与加速。先探测本机到 GitHub 各端点的连通性，按证据分级判定，必要时写入 hosts 修复并验证。

**两种用法共享同一套引擎与安全边界**：作为 Agent Skill（`SKILL.md` + `scripts/` + `references/`）让 AI 自动诊断修复，或作为 CLI 工具（`fetch.sh` / `goto-github.ps1` / `ps1/`）手动使用。

Bash 侧是薄入口 `fetch.sh` + `lib/` 模块（单元测试、mock curl、无网络）。Windows 有**两套 PowerShell 实现**：已发布的拉取式 `goto-github.ps1` 与实验性扫描式 `ps1/`（`install.ps1` **不**下载它）。

## Architecture

```
SKILL.md                    # Skill 入口：frontmatter + 路由 + Phase 决策树
references/                 # 判定标准 / JSON 契约 / 安全边界 / 环境要求（细则唯一真源）
├── judgment-criteria.md    # 10+ 端点、network/auth 双维度、噪声阈值
├── probe-recipes.md        # 4 个脚本的 JSON 字段语义、null vs [] 约定
├── safety-and-boundaries.md# hosts 红线：备份/标记块/遮蔽检测/不自动提权
└── environment-and-prereqs.md # 平台矩阵、绕代理、WSL/DoH/PS5.1 退出条件

scripts/                    # Skill 的黑盒脚本（bash .sh + PowerShell .ps1 双套同形 JSON）
├── env_detection.{sh,ps1}      # Phase 0 环境探测
├── connectivity_probe.{sh,ps1} # Phase 1 10+ 端点 × N 次统计采样
├── auth_probe.{sh,ps1}          # Phase 1b 凭据状态（ssh/https/gh），与网络维度分离
├── hosts_apply.{sh,ps1}        # Phase 3 写盘（备份→标记块→遮蔽检测→刷 DNS）
├── hosts_status.{sh,ps1}       # Phase 4 复测 + verdict
└── lib/constants.{sh,ps1}      # Skill 层常量真源（独立于 CLI 的 lib/ 与 ps1/lib/）

fetch.sh                    # Bash CLI 薄入口：解析参数 → source lib/ → 调度
lib/                        # Bash CLI 实现（被 fetch.sh source）
├── 00-constants.sh         # 数据常量（标记、数据源、探测调参）
├── 01-utils.sh             # 日志/平台/权限/DNS/TCP 工具
├── 02-fetch.sh             # 源拉取、死 IP 过滤、IP 探测
├── 03-validate.sh          # 内容校验、应用后验证
└── 04-apply.sh             # hosts 写入/移除、遮蔽检测、状态

goto-github.ps1             # PowerShell 拉取式（已发布）。Windows，无需 bash.exe
ps1/                        # PowerShell 扫描式（实验性，opt-in）
├── goto-github.ps1         # UAC 提权 → source lib/ → 按 <command> 调度
└── lib/                    # 00-constants .. 06-uninstall
```

**SKILL.md 只做路由 + Phase 流程**，细则全部下沉 `references/`。历史上历次硬伤都源于 SKILL.md 内联了 references 的"速查副本"——副本更窄，且它是唯一保证被加载的文本，于是更弱的规则成了实际执行的规则。

### 双语言契约

`scripts/*.sh` 与 `scripts/*.ps1` 必须输出**同形 JSON**：字段名一致、类型一致、key 顺序一致。`null` vs `[]` 的约定见 `references/probe-recipes.md`。改一侧必须同步改另一侧。

bash 侧插入 JSON 字符串的变量**必须过 `json_escape`**——Windows 路径的反斜杠在 JSON 里是转义字符，未转义会让整行不可解析。

### 多平台安装器

| 文件 | 角色 | 安装命令 |
|------|------|----------|
| `install.sh` | Unix 引导器 | `curl -sfL .../install.sh \| bash` |
| `goto-github.ps1` | PowerShell 原生（无 bash.exe） | 下载后运行 |
| `bootstrap.ps1` | Windows 引导器（推荐） | `irm .../bootstrap.ps1 \| iex` |
| `install.ps1` | Windows 安装器（备用） | `irm .../install.ps1 -OutFile "$env:TEMP\install.ps1"; & "$env:TEMP\install.ps1"` |

## 数据源

1. `https://cdn.jsdelivr.net/gh/521xueweihan/GitHub520@main/hosts` — 主源
2. `https://raw.hellogithub.com/hosts` — 备用源

## 探测目标

所有 IP 探测用 **git smart-http 端点**（`github/gitignore` 的 `info/refs?service=git-upload-pack`），**不是首页**：部分边缘 IP 能返回首页但不通 git 流量，用首页探测会选出"假阳性"IP。

`PROBE_TARGET` 只在 `ps1/lib/00-constants.ps1` 声明一次（bash 侧在 `lib/00-constants.sh`）。重复定义会让后 source 的静默遮蔽常量——`tests/test-ps-02-scan.ps1` 有断言锁住它。

## Commands

**Bash (macOS / Linux / Git Bash):**
```bash
sudo ./fetch.sh             # 拉取 → 验证 → 写入 hosts → 刷新 DNS
./fetch.sh --status         # 显示当前状态（无需 sudo）
sudo ./fetch.sh --restore   # 移除 goto-github 条目
./fetch.sh --help           # 显示帮助
```

**Skill 脚本（bash）:**
```bash
./scripts/env_detection.sh          # Phase 0 环境探测（只读）
./scripts/connectivity_probe.sh     # Phase 1 采样（只读）
./scripts/auth_probe.sh           # Phase 1b 凭据状态（只读）
sudo ./scripts/hosts_apply.sh       # Phase 3 写 hosts（需 root）
./scripts/hosts_status.sh           # Phase 4 复测（只读）
```

**PowerShell (Windows):**
```powershell
.\goto-github.ps1               # 交互菜单 (1234Q)
.\goto-github.ps1 --help        # 显示用法
.\goto-github.ps1 --pwsh status # JSON 状态（脚本用）
.\goto-github.ps1 --pwsh auto   # 一键加速（需管理员）
.\goto-github.ps1 --pwsh restore # 恢复 hosts（需管理员）
```

**Skill 脚本（PowerShell 5.1+ / 7+）:**
```powershell
.\scripts\env_detection.ps1 -Help
.\scripts\connectivity_probe.ps1 -Attempts 10
.\scripts\auth_probe.ps1                      # Phase 1b 凭据状态（只读）
.\scripts\hosts_apply.ps1 -Strategy auto      # 需管理员
.\scripts\hosts_status.ps1 -Baseline .\before.json
```

## 平台支持

| 平台 | DNS 刷新命令 |
|----------|-------------------|
| macOS | `killall -HUP mDNSResponder; dscacheutil -flushcache` |
| Linux | `resolvectl flush-caches` |
| Windows | `ipconfig //flushdns`（PowerShell 原生） |
| WSL | 不支持（hosts 行为与 Windows 不同） |

## 分支与提交约定

- `main` — 稳定版本，受保护
- `dev-*` — 开发分支
- 提交遵循 [Conventional Commits](https://www.conventionalcommits.org/)：`feat:`、`fix:`、`docs:`、`refactor:`、`chore:`

## CI

`.github/workflows/shellcheck.yml` 在 push/PR 触及 `fetch.sh`、`install.sh`、`lib/`、`shared/`、`tests/`、`ps1/`、`scripts/` 或 `*.ps1` 时运行：
- ShellCheck（severity: warning）覆盖全仓库
- `tests/test-*.sh`（bash 单元测试，无网络）
- `shared/parity-check.sh`（bash ↔ PowerShell 常量一致性）
- PSScriptAnalyzer 覆盖 `*.ps1`（ubuntu-latest；平台无关，Error 才阻断）
- `tests/test-ps-*.ps1`（`ps1/` 扫描式测试，**windows-latest**）

## 开发

**Bash (macOS / Linux / Git Bash):**
```bash
make lint                    # shellcheck --severity=warning（0 warnings）
make test                    # bash 单元测试（mock curl，无网络）
make parity                  # bash ↔ PowerShell 常量一致性
./fetch.sh --status          # 测试只读路径（无需 sudo）
sudo ./fetch.sh              # 测试完整流程（需 sudo）
```

**PowerShell (Windows):**
```powershell
.\goto-github.ps1 --pwsh status  # 测试状态端点
make ps-test                    # ps1/ 测试 — 仅 Windows
make skill-test                 # skill 脚本 --help 冒烟
```

## 测试钩子（仅 CI/测试用）

| 变量 | 作用 |
|------|------|
| `GOTO_GITHUB_TEST_PRIVILEGED=1` | 跳过 root/admin 检查，以便对临时 hosts 文件测写盘逻辑。**不授予真实权限** |
| `GOTO_GITHUB_FORCE_IP=<ip>` | 绕过探测直接指定 IP，确定性地测写盘链路 |

## File Layout

```
goto-github/
├── SKILL.md                # Skill 入口（frontmatter + 路由 + Phase）
├── references/             # 判定标准 / JSON 契约 / 安全边界 / 环境要求
├── scripts/                # Skill 脚本（.sh/.ps1 双套）+ lib/constants.{sh,ps1}
├── fetch.sh                # Bash CLI 薄入口（source lib/）
├── lib/                    # Bash CLI 模块：00-constants .. 04-apply
├── install.sh              # Unix 一键安装器（curl | bash，下载 lib/）
├── goto-github.ps1         # PowerShell 拉取式（已发布）
├── ps1/                    # PowerShell 扫描式（实验性，opt-in）
├── bootstrap.ps1           # Windows 引导器（irm | iex，推荐）
├── install.ps1             # Windows 安装器（OutFile 备用，下载 lib/）
├── shared/parity-check.sh  # bash ↔ PowerShell 常量一致性检查
├── tests/                  # 单元测试（bash test-00..04-*.sh，ps test-ps-00..04-*.ps1）
├── Makefile                # make lint / test / parity / ps-test / skill-test
├── .shellcheckrc           # SC1090/SC1091 关闭
├── .gitattributes          # text=auto（跨平台行尾）
├── .github/workflows/
│   ├── shellcheck.yml      # Lint + 测试 + parity CI
│   ├── argus-review.yml    # AI review CI
│   └── pr-automation.yml   # PR 自动化（标签/assign）
├── TASKS.md                # 唯一任务列表（带依据与验收标准）
├── README.md
├── CONTRIBUTING.md
├── CLAUDE.md
├── AGENTS.md
├── LESSONS.md
└── LICENSE
```
