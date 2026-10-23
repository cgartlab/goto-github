# AGENTS.md — goto-github

> **会话约定**：开始任何工作前，先读根目录 `LESSONS.md`（本仓库从真实失误沉淀的「教训→规则」清单）并遵循其中所有规则；遇到新失误按其 §维护 追加。依据：Anthropic Claude Code memory/best practices + 社区 lessons.md 惯例。

**分类**: 工具 (Tools) — 网络实用工具 · Agent Skill
**技术栈**: Bash 3.2+ (macOS/Linux/Git Bash) · PowerShell 5.1+ (Windows) · skill 脚本双实现均支持 bash 3.2+ / PS 5.1+ · ps1/ 扫描式仍需 PS 7+

GitHub 连通性诊断与加速。探测本机到 GitHub 各端点的连通性，按证据分级判定，必要时写入 hosts 修复并验证。**两种用法共享同一套引擎与安全边界**：Agent Skill（`SKILL.md` + `scripts/` + `references/`）与 CLI 工具（`fetch.sh` / `goto-github.ps1` / `ps1/`）。

## OVERVIEW

```
goto-github/
├── SKILL.md                # Skill 入口：frontmatter + 路由 + Phase 决策树
├── references/             # 细则唯一真源（SKILL.md 只做路由，不内联副本）
│   ├── judgment-criteria.md    # 10+ 端点、network/auth 双维度、噪声阈值
│   ├── probe-recipes.md        # 4 个脚本的 JSON 字段语义、null vs [] 约定
│   ├── safety-and-boundaries.md# hosts 红线：备份/标记块/遮蔽检测/不自动提权
│   └── environment-and-prereqs.md # 平台矩阵、绕代理、WSL/DoH/PS5.1 退出条件
├── scripts/                # Skill 黑盒脚本（bash .sh + PowerShell .ps1 双套同形 JSON）
│   ├── env_detection.{sh,ps1}      # Phase 0 环境探测
│   ├── connectivity_probe.{sh,ps1} # Phase 1 10+ 端点 × N 次统计采样
│   ├── auth_probe.{sh,ps1}         # Phase 1b 凭据状态（ssh/https/gh），与网络维度分离
│   ├── hosts_apply.{sh,ps1}        # Phase 3 写盘
│   ├── hosts_status.{sh,ps1}       # Phase 4 复测 + verdict
│   └── lib/constants.{sh,ps1}      # Skill 层常量真源（独立于 CLI 的 lib/ 与 ps1/lib/）
├── fetch.sh                # Bash 入口（薄）：解析参数 → source lib/ → 调度
├── lib/                    # Bash 实现模块（被 fetch.sh source）
│   ├── 00-constants.sh     # 数据常量（标记、数据源、探测参数）
│   ├── 01-utils.sh         # 日志/平台/权限/DNS/TCP 工具
│   ├── 02-fetch.sh         # 拉取、死 IP 过滤、IP 探测
│   ├── 03-validate.sh      # 内容校验、应用后验证
│   └── 04-apply.sh         # 写入/移除 hosts、遮蔽检测、状态
├── install.sh             # Unix 一键安装 (curl | bash，含 lib/)
├── goto-github.ps1         # PowerShell 原生实现（拉取式，已发布）
├── ps1/                    # PowerShell 扫描式实现（实验性，默认不发布）
│   ├── goto-github.ps1     # 入口：UAC 提权 → source lib/ → 按 <command> 调度
│   └── lib/                # 实现模块（00-constants .. 06-uninstall）
├── bootstrap.ps1          # Windows bootstrapper (irm | iex, 推荐)
├── install.ps1             # Windows 一键安装 (OutFile 备用)
├── shared/
│   └── parity-check.sh     # bash ↔ PowerShell 共享常量一致性校验
├── tests/                  # 单元测试（mock curl，无需网络）
│   ├── lib/test-helpers.sh
│   ├── test-00..04-*.sh    # Bash 实现
│   ├── lib/test-helpers.ps1
│   ├── test-ps-00..04-*.ps1 # ps1/ 扫描式实现（Windows-only）
│   └── mocks/mock-curl.cmd # PowerShell 测试的 curl 替身
├── Makefile                # make lint / test / parity / ps-test / skill-test
├── .shellcheckrc           # ShellCheck 配置
├── .gitattributes          # 跨平台行尾
├── TASKS.md                # 唯一任务列表（带依据与验收标准）
├── README.md
├── CONTRIBUTING.md
├── CLAUDE.md
├── AGENTS.md
├── LESSONS.md
├── LICENSE
└── .github/workflows/
    ├── shellcheck.yml      # Lint + 测试 + parity CI（含 windows-latest ps1/ 与 skill 脚本测试）
    ├── argus-review.yml    # AI review CI（argus-flash App；dependabot PR 跳过）
    ├── auto-assign.yml     # PR 自动 assign 作者
    └── pr-automation.yml   # 分支名自动打标 + assign + PC Automatic project board
```

## COMMANDS

### Bash (macOS / Linux / Git Bash)

| 命令 | 功能 | 需 sudo |
|------|------|---------|
| `sudo ./fetch.sh` | 拉取 → 验证 → 写入 hosts → DNS刷新 | ✅ |
| `./fetch.sh --status` | 显示当前 IP 和连通性 | ❌ |
| `./fetch.sh --probe` | 探测可用的 github.com IP（诊断用，不写 hosts） | ❌ |
| `sudo ./fetch.sh --restore` | 移除 goto-github 条目 | ✅ |
| `./fetch.sh --help` | 显示帮助 | ❌ |

### Skill 脚本（bash）

| 命令 | 功能 | 需 root |
|------|------|---------|
| `./scripts/env_detection.sh` | Phase 0 环境探测（只读） | ❌ |
| `./scripts/connectivity_probe.sh` | Phase 1 采样（只读） | ❌ |
| `./scripts/auth_probe.sh` | Phase 1b 凭据状态（只读） | ❌ |
| `sudo ./scripts/hosts_apply.sh` | Phase 3 写 hosts | ✅ |
| `./scripts/hosts_status.sh` | Phase 4 复测（只读） | ❌ |

### PowerShell (Windows)

| 命令 | 功能 | 需管理员 |
|------|------|---------|
| `.\goto-github.ps1` | 交互菜单 | 修改 hosts 时需要 |
| `.\goto-github.ps1 --pwsh status` | JSON 状态（脚本用） | ❌ |
| `.\goto-github.ps1 --pwsh auto` | 一键加速 | 修改 hosts 时需要 |
| `.\goto-github.ps1 --pwsh restore` | 恢复 hosts | 修改 hosts 时需要 |

### Skill 脚本（PowerShell 5.1+ / 7+）

| 命令 | 功能 | 需管理员 |
|------|------|---------|
| `.\scripts\env_detection.ps1 -Help` | Phase 0 环境探测（只读） | ❌ |
| `.\scripts\connectivity_probe.ps1 -Attempts 10` | Phase 1 采样（只读） | ❌ |
| `.\scripts\auth_probe.ps1` | Phase 1b 凭据状态（只读） | ❌ |
| `.\scripts\hosts_apply.ps1 -Strategy auto` | Phase 3 写 hosts | ✅ |
| `.\scripts\hosts_status.ps1 -Baseline .\b.json` | Phase 4 复测（只读） | ❌ |

### 一键安装

| 平台 | 命令 |
|------|------|
| Unix (macOS / Linux) | `curl -sfL .../install.sh \| bash` |
| Windows PowerShell | `irm .../bootstrap.ps1 \| iex` |

## CONVENTIONS

- **主分支**: `main`（稳定）；`dev-*` 分支开发
- **提交**: Conventional Commits（`feat:` `fix:` `docs:` `refactor:` `chore:`）
- **Lint**: `make lint`（shellcheck --severity=warning fetch.sh install.sh lib/ shared/ tests/ scripts/，0 warnings）；`make test`（单元测试，mock curl 无需网络）；`make parity`（bash ↔ PowerShell 常量一致性）；`make ps-test`（ps1/ 扫描式实现，仅 Windows）；`make skill-test`（skill 脚本 `--help` 冒烟）
- **PR**: 始终指向 `main`，禁止直推

## ANTI-PATTERNS

- **NEVER** 编辑 hosts 标记区块外部
- **NEVER** 无备份写 hosts（备份失败即中止）
- **NEVER** 跳过 `shellcheck` 提交（Bash 版本）
- **NEVER** 直推 `main`，始终走 PR
- **NEVER** 在 PowerShell 实现中重新引入 bash.exe 依赖
- **NEVER** 在同一常量放两处定义（后 source 的会静默遮蔽前者；新增常量前先全局 grep）
- **NEVER** 把 `$x = if (...) {} else {}` 当合法 PowerShell（`if` 是语句不是表达式；用 `$(if ...)`）
- **NEVER** 在 bash 拼 JSON 时不过 `json_escape`（Windows 路径反斜杠会让整行不可解析）
- **NEVER** 用 `-f` 格式化含 `{}` 的 JSON 模板（花括号被当格式占位符；用字符串拼接）
- **NEVER** 让 SKILL.md 内联 references 的细则副本（副本更窄，且它是唯一保证被加载的文本）

## NOTES

- 依赖：
  - Unix: Bash 3.2+、curl、管理员权限
  - Windows: PowerShell 5.1+（拉取式）/ 7+（扫描式与 skill 脚本）、curl.exe
- 无 Python 依赖
- **Skill 与 CLI 的分层**：`SKILL.md` 只做路由 + Phase 流程 + 6 条元规则；判定阈值、JSON 契约、安全边界、环境要求全部在 `references/`。`scripts/lib/constants.{sh,ps1}` 是 skill 层自己的常量真源，**不**依赖 CLI 的 `lib/` 与 `ps1/lib/`——CLI 改动不能 silently 改变 skill 写什么
- **双语言契约**：`scripts/*.sh` 与 `scripts/*.ps1` 输出同形 JSON（字段名、类型、key 顺序一致）。改一侧必须同步另一侧
- **探测目标**：所有 IP 探测用 git smart-http 端点（`info/refs?service=git-upload-pack`），不是首页。`PROBE_TARGET` 只在 `ps1/lib/00-constants.ps1` 声明一次；`tests/test-ps-02-scan.ps1` 有断言锁住它，且做过反向验证（改回首页 → 3 个断言 FAIL）
- **分级报告**：禁止把所有端点合并成"能用/不能用"。干扰按路径而非按 IP（实测同 IP 的 API 100% 而网页 30%）
- **单次结果不是证据**：判定只用成功率（默认 10 次采样）。实测同一端点 1 分钟间隔两次采样可差 30 个百分点
- **未改善要如实报**：`hosts_status` 的 verdict 支持 `--baseline` 对比；无改善时输出 `not_fixed`，不宣称修复
- 单元测试：`tests/test-00..04-*.sh`（mock curl，无需网络）；`make test` 逐个运行
- **两套 PowerShell 实现并存且互斥**：根 `goto-github.ps1`（拉取式，从社区源下载已验证 IP，`install.ps1` 实际发布）与 `ps1/`（扫描式，自展开 CIDR 段逐个探测，实验性，`install.ps1` **不**下载）。二者标记相同、写同一个 hosts，同装会互相覆盖；CLI 接口也不兼容（根 `--pwsh auto|status|restore|source` vs ps1/ `run|install|status|help|uninstall`）。改任一套前先确认意图，不要"顺手统一"。
- `ps1/` 定位为**扫描式降级路径**：根 ps1 拉不到社区源时无兜底，`ps1/` 与 bash 侧 `lib/02-fetch.sh` 的 /24 探测兜底同位；代价是扫描约 1 万 IP 远重于拉取一个 hosts 文件。
- `tests/test-ps-*.ps1` **仅 Windows 可跑**：被测代码写 `C:\...\etc\hosts`、用 `WindowsIdentity` 判 UAC、读 HKLM DNS 注册表，且 `tests/mocks/mock-curl.cmd` 是 cmd batch。CI 的 `pwsh-test` job 跑 `windows-latest`；`pwsh-lint` 仍在 ubuntu（PSScriptAnalyzer 与平台无关）
- Bash 结构：`fetch.sh` 只做参数解析与调度，实现都在 `lib/`；新增功能改 `lib/`，不要在 `fetch.sh` 里重复实现
- 常量一致性：`shared/parity-check.sh`（`make parity`）保证 bash 与所有已存在的 PowerShell 实现（根 `goto-github.ps1` 拉取式、`ps1/lib/00-constants.ps1` 扫描式）标记一致，且根实现的社区源列表一致；可选文件缺失时输出显式 `SKIP:`，不当作已校验
- 探测兜底：所有源核心 IP 不可达时，从源 IP 扩展 ±7 的 /24 候选池并发探测，目标为 git smart-http 端点而非 github.com 首页（部分边缘 IP 返回首页但不通 git 流量）
- 遮蔽检测：标记之前存在其他工具写入的 github.com 条目时警告（不修改标记区块外部）
- **不自动提权**：skill 脚本与 CLI 检测到无 root/管理员时报告需要执行的命令，不自动 `sudo`、不弹 UAC（自动提权会让用户在不知情下授予权限，且提权后环境变量丢失导致行为不一致）
- **DoH 绕过**：Windows 启用 DNS-over-HTTPS 时，浏览器等应用绕过 hosts 直接加密解析，hosts 写入对这些应用无效。Phase 0 检测到即警告
- **gh 鉴权与网络无关**：`GITHUB_TOKEN` 环境变量失效会遮蔽 keyring 有效 token，让所有 `gh` 命令 401 而 git 操作正常。`env_detection` 输出 `env_var_shadowed` 状态，报告中必须与网络问题分开说
- Hosts 标记：`# >>> goto-github >>>` / `# <<< goto-github <<<`
- 数据源：jsDelivr CDN GitHub520（主）→ raw.hellogithub.com（备）
- 平台：macOS · Linux · Git Bash (Windows) · Windows PowerShell
- 安装路径（Unix）：`~/.local/share/goto-github/` + `~/.local/bin/goto-github`
- 安装路径（Windows）：`$env:LOCALAPPDATA\goto-github\`
- WSL：不支持（WSL hosts 行为与 Windows 不同，检测到 WSL 打印重定向消息）
- **测试钩子**（仅 CI/测试用，不授予真实权限）：`GOTO_GITHUB_TEST_PRIVILEGED=1` 跳过权限检查；`GOTO_GITHUB_FORCE_IP=<ip>` 绕过探测直接指定 IP
