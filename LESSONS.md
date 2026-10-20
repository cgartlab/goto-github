# LESSONS — goto-github

> GitHub 访问加速工具：Bash 3.2+（`fetch.sh`）+ 原生 PowerShell 5.1+（`goto-github.ps1`）双实现，实时拉取社区 hosts 源写入本地 hosts，含 IP 探测兜底与一键安装。
> 本仓库从真实失误沉淀的「教训→规则」清单。**会话开始先全文阅读并遵循其中所有规则**；出现新失误按 §维护 追加。
> 权威依据：Anthropic Claude Code memory/best practices（<200 行、具体可验证、第二次犯同样错即写入）；社区 lessons.md 惯例（Boris Cherny，Anthropic）。
> 来源：本仓库 AGENTS.md 的 ANTI-PATTERNS / NOTES + 已验证 fix 提交；预填为种子，后续由 Agent 在真实工作中增长。

## 维护
- **触发**：用户纠正 / Agent 自查到的失误 / 非显而易见的 gotcha。
- **格式**：`### <主题>` 下，每条 = 失误（具体场景）→ 规则（最小可执行指令），一行可验证。
- **只记项目特有、不可从代码推断的**；通用最佳实践不写；含糊措辞（"小心""注意"）删掉。
- **重复出现** → 升级进 `AGENTS.md` 硬规则；**月度审阅**裁剪过期项；目标 < 200 行。

## hosts 安全边界

- 失误：编辑了 hosts 标记区块外部 → 规则：只改 `# >>> goto-github >>>` / `# <<< goto-github <<<` 之间，区块外部一律不动（见 AGENTS.md「ANTI-PATTERNS」）
- 失误：apply 时产生重复的 hosts 标记区块 → 规则：apply 前先清理旧标记，保证幂等（commit e00c369）
- 失误：hosts 写入未严格错误检查，失败被静默吞掉 → 规则：hosts apply 必须 strict error checking（commit a2e81c8）
- 失误：删除/恢复前不备份 → 规则：先备份再改，restore 与源标签要硬化（commit a26b196）
- 失误：标记前存在其他工具写入的 github.com 条目仍继续写 → 规则：遮蔽检测要警告但不修改区块外部（见 AGENTS.md「NOTES」）

## 探测与容错

- 失误：单轮探测就定论，把 flaky IP 当可用；空池直接崩溃 → 规则：两轮探测过滤 flaky IP，并加空池防护（commit 37501b2）
- 失误：探测目标用 github.com 首页，探通了但 git 流量不通 → 规则：探测目标为 git smart-http 端点（见 AGENTS.md「NOTES」）
- 失误：`PROBE_TARGET` 在 `00-constants.ps1` 和 `02-scan.ps1` **各定义一份**，后 source 的 02-scan 静默遮蔽常量；改 constants 做回归验证时测试读到的仍是 02-scan 的旧值，反向验证连续报 PASS，差点把"没锁住"当"锁住了" → 规则：常量只在 `00-constants.ps1` 声明一次；重构时给同一常量找第二处落点前先全局 grep `^\$script:<NAME>\s*=`；反向验证前先确认"改动点 = 运行时所读点"（在测试内打印一次实际值，别信磁盘）
- 失误：curl 瞬时失败直接报错退出 → 规则：瞬时 curl 失败要重试，并且报告而非静默（commit b09700c、a5d5f71）
- 失误：tcp 探测假阴性 → 规则：区分"连通"与"未测出"，不要用假阴性触发兜底（commit 50309d7）
- 失误：交互删除无确认 → 规则：删除操作要确认提示（commit 50309d7）
- 失误：`ForEach-Object -Parallel -AsArray` —— `-AsArray` 不是 `ForEach-Object` 的参数（PS 7.6.7 参数表里没有），并行扫描调用**在探测任何 IP 之前就因参数绑定失败而抛错**；且 `-Parallel` 在隔离 runspace 执行，父作用域的函数（`Test-Ip`/`Find-Curl`）与 `$script:` 变量在块内都不可见，`param()` 也收不到管道值（commit 292b28f）。规则：向并行块传值只能用 `$using:`（变量）或环境变量（配置），块内不得调用父作用域函数；`-Parallel` 无 `-AsArray`，用 `@(...)` 防止单元素结果被拆成标量
- 失误：上面那个 bug 之所以漏进主干——`test-ps-02` 只测了纯数学的 `Expand-CidrToIPs`，从不触达并行扫描路径，CI 因此全绿而功能完全不可用。规则：**"未触达的代码路径"比"测试较少"更危险**；并发/IO 路径必须用 mock（`Find-Curl` 返回 `mock-curl.cmd`）至少覆盖一次，且要验证"坏代码会让测试变红"（把 bug 临时还原一次确认 FAIL，再复原）

## 跨平台与编码

- 失误：PowerShell 实现里重新引入 bash.exe 依赖 → 规则：Windows 走原生 pwsh 实现，不依赖 bash.exe（见 AGENTS.md「ANTI-PATTERNS」）
- 失误：Windows `.ps1` 无 BOM，PS 5.1 下乱码 → 规则：所有 `.ps1` 加 UTF-8 BOM，`Invoke-WebRequest` 内容按 UTF-8 解码（commit 33e2c03、e4f4003、48212c6）
- 失误：加了自解锁代码，破坏了 `[CmdletBinding]` → 规则：不要在受 `CmdletBinding` 约束的脚本里加自解锁（commit ad035f5）
- 失误：把 WSL 当成 Windows 处理 → 规则：检测到 WSL 打印重定向消息，不支持（见 AGENTS.md「NOTES」）
- 失误：grep 在 macOS 上不可移植 → 规则：grep 用法要考虑 BSD/GNU 差异（commit 50309d7）
- 失误：PowerShell 里写 `$x = if (...) { } else { }` —— `if` 是语句不是表达式，不能赋值；解析成"调用名为 if 的命令"，运行时报 `术语 'if' 不会被识别`，而 AST 解析器（`Parser::ParseFile`）报告 0 error，静态检查完全看不出 → 规则：赋值用 `$(if (...) {} else {})` 子表达式形式；PowerShell 脚本写完除了 `bash -n` 等价物（AST 解析）外，还要扫一遍 `CommandAst.GetCommandName()` 是否为 `if/else/foreach/switch`，且必须实跑一次
- 失误：PowerShell 里用 `& pwsh -Command "… $script:VAR …"` 传脚本，外层 5.1 会话先把 `$script:` 展开成空，报 `必须在"+"运算符后提供值表达式` 或把空值当参数；一轮内连踩三次 → 规则：任何含 `$script:` / `$using:` 的验证代码一律写入临时 `.ps1` 文件再 `pwsh -NoProfile -File` 执行，不要走 `-Command` 字符串
- 失误：`Write-Warning` 写在 PowerShell 脚本里，管道捕获时 warning stream 被转发到 **stdout**，把"stdout 只有一行 JSON"的契约打破（`ConvertFrom-Json` 报 `Unexpected character encountered while parsing value`）→ 规则：要求 stdout 纯净的脚本，警告与错误一律 `[Console]::Error.WriteLine(...)`，不用 `Write-Warning` / `Write-Error`；`Write-Verbose` 安全（默认静默）
- 失误：JSON 模板用 `-f` 格式化，而模板本身含 `{` `}`（`'{"min":{0}}' -f …`），PowerShell 把 JSON 花括号当格式占位符，报 `设置字符串格式时出错: Input string was not in a correct format` → 规则：拼 JSON 用字符串拼接（`$s += '"k":' + $v`），不用 `-f`
- 失误：把 `ps1/` 的测试想当然塞进 ubuntu-latest 的同一个 job——其 curl 替身是 `mock-curl.cmd`（cmd batch），且被测代码写 `C:\...\etc\hosts`、用 `WindowsIdentity` 判 UAC、读 HKLM DNS 注册表，Linux 上必然红 → 规则：平台相关的实现用独立 job 跑对应 OS（`pwsh-test` → `windows-latest`）；平台无关的静态检查仍可共用（PSScriptAnalyzer 与 OS 无关）。判断依据是"被测代码依赖什么"，不是"测试文件后缀是什么"

## 安装与发布

- 失误：跳过 shellcheck 提交 → 规则：`make lint`（shellcheck fetch.sh install.sh tests/）必须 0 warnings（见 AGENTS.md「ANTI-PATTERNS」）
- 失误：直推 `main` → 规则：始终走 PR，PR 指向 `main`（见 AGENTS.md「ANTI-PATTERNS」）
- 失误：安装脚本无校验和，用户拿不到完整性保证 → 规则：install 加 checksum 校验（commit 915da98）
- 失误：bootstrap 用会过期的 CDN 当主 URL → 规则：GitHub raw 作主 URL，并给下载内容加 BOM（commit 2d4db84）
- 失误：`fetch.sh` 拆出 `lib/` 后，`install.sh`/`install.ps1` 仍只下载 `fetch.sh`，安装结果缺模块而崩溃 → 规则：安装器必须一并下载 `lib/*.sh`（含 update 路径与 SHA256SUMS 条目）

## 重构与模块化

- 失误：1000+ 行实现塞在单一 `fetch.sh`，函数无法直接单元测试（只能 `sed` 抽取 + `eval`）→ 规则：实现拆到 `lib/NN-*.sh`，`fetch.sh` 只做入口调度，测试直接 `source` 模块
- 失误：`fetch.sh` 经符号链接安装后，用 `dirname "$0"` 定位 `lib/` 会指向 `~/.local/bin` → 规则：解析 `BASH_SOURCE[0]` 并跟随符号链接（`while [ -L ]` + `readlink`）取得真实脚本目录
- 失误：新增 `.sh` 文件后 `Makefile`/CI 仍只 lint 旧文件 → 规则：lint 覆盖 `fetch.sh install.sh lib/ shared/ tests/`，`make test` 用 `tests/test-*.sh` 通配
- 失误：`SHA256SUMS` 里 `.ps1` 记录的是 CRLF 工作树哈希，与 raw 提供的 LF blob 不一致 → 规则：`SHA256SUMS` 以 LF blob 计算（`.sh` 已 `eol=lf`）；改动 `fetch.sh` 后必须重算其哈希
- 失误：把 `fetch.sh` 改成 `source lib/` 会改变分发形态（单文件 → 多文件）→ 规则：此类架构变更先与用户确认方向（拉取 vs 扫描、单文件 vs 多文件），再动手
- 失误：`parity-check.sh` 只校验根 `goto-github.ps1`，漏掉 `ps1/lib/00-constants.ps1`；后者一旦漂移，两套 PS 实现写出互不可见的 hosts 块而 CI 无感 → 规则：parity 覆盖所有已存在的 PS 常量文件；文件缺失必须显式 `SKIP:` 并说明未校验，绝不静默当作已校验
- 失误：bash 拼 JSON 时把 Windows 路径（`C:\Users\...`）原样插入 `"backup":"$path"`，反斜杠在 JSON 字符串里是转义字符，整行变成非法 JSON，PowerShell `ConvertFrom-Json` 报 `Unrecognized escape sequence` → 规则：bash 侧所有插入 JSON 字符串的变量必须过 `json_escape`（先转义 `\` 再转义 `"`）；双语言契约下这是硬要求——一侧不可解析即契约破裂
- 失误：`extract_ps_marker` 内 `grep | head -1 | sed` 在 grep 无匹配时返回非 0，`set -o errexit -o pipefail` 在命令替换处直接中止，`die()` 不被调用 → 症状是 exit=1 但 stderr 空（CI 失败无诊断）→ 规则：提取函数末尾 `return 0`，调用处显式检查空值并分别报"未声明"与"值漂移"
- 失误：双引号正则里写 `"\$?script:$var"`，shellcheck 0.11 报 SC1087（把 `$?script` 当数组展开）→ 规则：正则用拼接构造，`\$?script:` 留在单引号字面量里；`sed` 里的 `\$` 同样转义
- 失误：bash 测试 harness 用 `out=$(cmd); rc=$?` 但外层 `set -e`，命令替换失败即中止外层，后续 echo 全不执行——误判成"被测脚本静默失败"→ 规则：捕获退出码必须 `set +e` 包裹；heredoc 用 `<<'EOF'` 引号形式，否则 `$script:` 被 shell 展开成 `:`，测出的内容根本不是想要的
