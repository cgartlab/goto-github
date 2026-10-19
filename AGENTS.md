# AGENTS.md — goto-github

> **会话约定**：开始任何工作前，先读根目录 `LESSONS.md`（本仓库从真实失误沉淀的「教训→规则」清单）并遵循其中所有规则；遇到新失误按其 §维护 追加。依据：Anthropic Claude Code memory/best practices + 社区 lessons.md 惯例。

**分类**: 工具 (Tools) — 网络实用工具
**技术栈**: Bash 3.2+ (macOS/Linux/Git Bash) · PowerShell 5.1+ (Windows)

GitHub 访问加速工具。实时从社区维护的 hosts 源获取 GitHub 域名映射，写入本地 hosts 文件，无需本地扫描。

## OVERVIEW

```
goto-github/
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
├── Makefile                # make lint / make test / make parity / make ps-test
├── .shellcheckrc           # ShellCheck 配置
├── .gitattributes          # 跨平台行尾
├── README.md
├── CONTRIBUTING.md
├── CLAUDE.md
├── AGENTS.md
├── LESSONS.md
├── LICENSE
└── .github/workflows/
    ├── shellcheck.yml      # Lint + 测试 + parity CI（含 windows-latest ps1/ 测试）
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

### PowerShell (Windows)

| 命令 | 功能 | 需管理员 |
|------|------|---------|
| `.\goto-github.ps1` | 交互菜单 | 修改 hosts 时需要 |
| `.\goto-github.ps1 --pwsh status` | JSON 状态（脚本用） | ❌ |
| `.\goto-github.ps1 --pwsh auto` | 一键加速 | 修改 hosts 时需要 |
| `.\goto-github.ps1 --pwsh restore` | 恢复 hosts | 修改 hosts 时需要 |

### 一键安装

| 平台 | 命令 |
|------|------|
| Unix (macOS / Linux) | `curl -sfL .../install.sh \| bash` |
| Windows PowerShell | `irm .../bootstrap.ps1 \| iex` |

## CONVENTIONS

- **主分支**: `main`（稳定）；`dev-*` 分支开发
- **提交**: Conventional Commits（`feat:` `fix:` `docs:` `refactor:` `chore:`）
- **Lint**: `make lint`（shellcheck --severity=warning fetch.sh install.sh lib/ shared/ tests/，0 warnings）；`make test`（单元测试，mock curl 无需网络）；`make parity`（bash ↔ PowerShell 常量一致性）；`make ps-test`（ps1/ 扫描式实现，仅 Windows）
- **PR**: 始终指向 `main`，禁止直推

## ANTI-PATTERNS

- **NEVER** 编辑 hosts 标记区块外部
- **NEVER** 跳过 `shellcheck fetch.sh` 提交（Bash 版本）
- **NEVER** 直推 `main`，始终走 PR
- **NEVER** 在 PowerShell 实现中重新引入 bash.exe 依赖

## NOTES

- 依赖：
  - Unix: Bash 3.2+、curl、管理员权限
  - Windows: PowerShell 5.1+（原生，无需 Git Bash）
- 无 Python 依赖
- 单元测试：`tests/test-00..04-*.sh`（mock curl，无需网络）；`make test` 逐个运行
- **两套 PowerShell 实现并存且互斥**：根 `goto-github.ps1`（拉取式，从社区源下载已验证 IP，`install.ps1` 实际发布）与 `ps1/`（扫描式，自展开 CIDR 段逐个探测，实验性，`install.ps1` **不**下载）。二者标记相同、写同一个 hosts，同装会互相覆盖；CLI 接口也不兼容（根 `--pwsh auto|status|restore|source` vs ps1/ `run|install|status|help|uninstall`）。改任一套前先确认意图，不要"顺手统一"。
- `ps1/` 定位为**扫描式降级路径**：根 ps1 拉不到社区源时无兜底，`ps1/` 与 bash 侧 `lib/02-fetch.sh` 的 /24 探测兜底同位；代价是扫描约 1 万 IP 远重于拉取一个 hosts 文件。
- `tests/test-ps-*.ps1` **仅 Windows 可跑**：被测代码写 `C:\...\etc\hosts`、用 `WindowsIdentity` 判 UAC、读 HKLM DNS 注册表，且 `tests/mocks/mock-curl.cmd` 是 cmd batch。CI 的 `pwsh-test` job 跑 `windows-latest`；`pwsh-lint` 仍在 ubuntu（PSScriptAnalyzer 与平台无关）
- Bash 结构：`fetch.sh` 只做参数解析与调度，实现都在 `lib/`；新增功能改 `lib/`，不要在 `fetch.sh` 里重复实现
- 常量一致性：`shared/parity-check.sh`（`make parity`）保证 bash 与所有已存在的 PowerShell 实现（根 `goto-github.ps1` 拉取式、`ps1/lib/00-constants.ps1` 扫描式）标记一致，且根实现的社区源列表一致；可选文件缺失时输出显式 `SKIP:`，不当作已校验
- 探测兜底：所有源核心 IP 不可达时，从源 IP 扩展 ±7 的 /24 候选池并发探测，目标为 git smart-http 端点而非 github.com 首页（部分边缘 IP 返回首页但不通 git 流量）
- 遮蔽检测：标记之前存在其他工具写入的 github.com 条目时警告（不修改标记区块外部）
- Hosts 标记：`# >>> goto-github >>>` / `# <<< goto-github <<<`
- 数据源：jsDelivr CDN GitHub520（主）→ raw.hellogithub.com（备）
- 平台：macOS · Linux · Git Bash (Windows) · Windows PowerShell
- 安装路径（Unix）：`~/.local/share/goto-github/` + `~/.local/bin/goto-github`
- 安装路径（Windows）：`$env:LOCALAPPDATA\goto-github\`
- WSL：不支持（WSL hosts 行为与 Windows 不同，检测到 WSL 打印重定向消息）
