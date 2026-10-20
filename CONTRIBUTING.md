# 贡献指南

## 开发环境

**Bash (macOS / Linux / Git Bash):**
```bash
git clone https://github.com/cgartlab/goto-github.git
cd goto-github

./fetch.sh --help           # 查看帮助
./fetch.sh --status         # 查看状态（无需 sudo）
sudo ./fetch.sh             # 测试完整流程（需 sudo）

./scripts/env_detection.sh        # skill：环境探测（只读）
./scripts/connectivity_probe.sh   # skill：连通性采样（只读）
```

**PowerShell (Windows):**
```powershell
git clone https://github.com/cgartlab/goto-github.git
cd goto-github

.\goto-github.ps1 --help        # 查看帮助
.\goto-github.ps1 --pwsh status # 查看状态
.\goto-github.ps1 --pwsh auto   # 测试完整流程（需管理员）

.\scripts\env_detection.ps1 -Help            # skill：环境探测（只读）
.\scripts\connectivity_probe.ps1 -Attempts 5 # skill：连通性采样（只读）
```

## 分支规范

- `main` — 稳定版本，受保护
- `dev-*` — 开发分支

## 提交规范

[Conventional Commits](https://www.conventionalcommits.org/)：

| 类型 | 说明 |
|------|------|
| `feat:` | 新功能 |
| `fix:` | 问题修复 |
| `docs:` | 文档更新 |
| `refactor:` | 重构（不影响功能） |
| `chore:` | 维护性变更（CI、依赖、配置） |

## PR 流程

1. 从 `main` 创建分支：`git switch -c dev-<feature>`
2. 开发并提交
3. 确保 `make lint`（shellcheck 0 warnings）、`make test`、`make parity`、`make skill-test` 通过；改到 `ps1/` 时再加 `make ps-test`（仅 Windows）
4. 创建 PR 指向 `main`
5. 合并后删除分支

## 改 skill 脚本的额外要求

`scripts/*.sh` 与 `scripts/*.ps1` 是**双语言契约**：改一侧必须同步另一侧，输出同形 JSON（字段名、类型、key 顺序一致）。

改完后必须验证：

1. **两侧 `--help` 都通**（`make skill-test`）
2. **两侧 JSON 都可解析且字段集合一致** —— bash 侧插进 JSON 字符串的变量必须过 `json_escape`，否则 Windows 路径的反斜杠会让整行不可解析
3. **写盘链路用测试钩子实测**，不要只看代码：
   ```bash
   export HOSTS_FILE=/tmp/test-hosts
   export GOTO_GITHUB_TEST_PRIVILEGED=1
   export GOTO_GITHUB_FORCE_IP=140.82.114.21
   ./scripts/hosts_apply.sh --strategy priority
   # 检查：标记块写入、块外内容保留、二次运行仍 1 个块（幂等）、备份生成
   ```
4. **改常量前先全局 grep**：`grep -rn '^\$script:<NAME>\s*=' ps1/ scripts/`。同一常量放两处定义时，后 source 的会静默遮蔽前者——改了一处、运行时读另一处，回归验证会给出完全错误的结论

## 文件结构

```
goto-github/
├── SKILL.md                # Skill 入口（frontmatter + 路由 + Phase 决策树）
├── references/             # 判定标准 / JSON 契约 / 安全边界 / 环境要求
├── scripts/                # Skill 脚本（.sh/.ps1 双套）+ lib/constants.{sh,ps1}
├── fetch.sh                # Bash 入口（薄）：source lib/ 并调度
├── lib/                    # Bash 实现模块（00-constants .. 04-apply）
├── install.sh              # Unix 一键安装（下载 fetch.sh + lib/）
├── goto-github.ps1         # PowerShell 拉取式实现（已发布）
├── ps1/                    # PowerShell 扫描式实现（实验性，默认不发布）
├── bootstrap.ps1          # Windows bootstrapper (irm | iex, 推荐)
├── install.ps1             # Windows 一键安装 (OutFile 备用)
├── shared/parity-check.sh  # bash ↔ PowerShell 常量一致性校验
├── tests/                  # 单元测试（bash test-00..04-*.sh / ps test-ps-00..04-*.ps1）
├── Makefile                # make lint / test / parity / ps-test / skill-test
├── .shellcheckrc          # ShellCheck 配置
├── .gitattributes          # 跨平台行尾
├── README.md
├── CONTRIBUTING.md
├── CLAUDE.md
├── AGENTS.md
├── LESSONS.md
└── .github/workflows/
    ├── shellcheck.yml      # Lint + 测试 + parity CI（含 windows-latest ps1/ 与 skill 脚本测试）
    ├── argus-review.yml    # AI review CI
    └── pr-automation.yml   # PR 自动化（打标/指派）
```

## Lint & 测试

```bash
make lint        # shellcheck --severity=warning（0 warnings）
make test        # bash 单元测试（mock curl，无需网络）
make parity      # bash ↔ PowerShell 常量一致性
make skill-test  # skill 脚本 --help 冒烟
make ps-test     # ps1/ 扫描式实现的单元测试（仅 Windows，需 pwsh 7）
```

## PowerShell 实现的两个坑

这两个在本仓库都真实踩过，写代码时直接避开：

- **`$x = if (...) {} else {}` 不合法**：`if` 是语句不是表达式，不能赋值。解析成"调用名为 if 的命令"，运行时报 `术语 'if' 不会被识别`，而 AST 解析器报告 0 error——静态检查完全看不出。用 `$(if ...)`。
- **`-f` 格式化 JSON 模板**：`'{"min":{0}}' -f 1` 里的 JSON 花括号被当格式占位符，报 `设置字符串格式时出错`。拼 JSON 用字符串拼接。

另外，任何含 `$script:` 的验证代码不要走 `pwsh -Command "..."`（外层 5.1 会话会提前展开成空），写成临时 `.ps1` 文件再 `pwsh -NoProfile -File` 执行。

## 两套 PowerShell 实现

`ps1/` 是实验性扫描式实现，与根 `goto-github.ps1`（拉取式）互斥且 CLI 不兼容，
`install.ps1` 不下载它。改任一套前先读 AGENTS.md 的 NOTES 段落确认意图。
