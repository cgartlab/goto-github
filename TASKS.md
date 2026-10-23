# TASKS — goto-github

> 本文件是仓库的**唯一任务列表**。只记「有真实信号支持、尚未完成」的事项；
> 完成的条目移到 §近期完成 并注明 PR 号。写之前先核实信号，写不出证据的不要进表。
>
> 维护规则：新增任务须带 **依据**（命令输出 / 代码位置 / CI 结果）与
> **验收标准**（怎么算做完）。没有验收标准的条目视为愿望，不进本表。

最后更新：2026-10-24

---

## 高优先级

### T1. 给 v2.1.0 打 tag

**依据**：`git tag -l` 返回 0 条。仓库有 CHANGELOG 的 2.1.0 / 2.0.0 / 1.0.0 三个版本节，
但没有任何 tag 指向它们。外部无法引用「某个确切版本」。

**影响**：`install.sh --version` 报的是 `VERSION` 文件里的值，与 CHANGELOG 之间
没有可验证的锚点；用户报告问题时无法说明自己跑的是哪一版。

**验收标准**：
- `git tag -l` 至少列出 `v2.1.0`
- tag 指向 `main` 上包含 `## [2.1.0]` 条目的提交
- `git show v2.1.0 --stat` 能对应 CHANGELOG 2.1.0 的记录

**注意**：CLI 产物版本是 `1.0.0`（见 CHANGELOG 顶部「Two version lines」），
tag 打 `v2.1.0` 指的是 **skill 契约版本**，不是 CLI 版本。命名要避免混淆。

---

### T2. argus Bug 3：主模型超时不落入 fallback 队列

**依据**（跨仓库，`cgartlab/argus`）：

`.github/actions/argus-review/action.yml` 的 `run_with_fallback_queue` 里，

```bash
if [ $primary_exit_code -eq 124 ]; then
    # 注释写着 "treat as retryable so the fallback queue runs"
    # 但只 echo + dismiss_stale_reviews，既不设标志也不 return
fi
```

随后代码按 `$primary_output` 内容匹配 `retry_re`，超时输出不匹配，于是
`return $primary_exit_code` 提前退出，整个 fallback 队列被跳过。

**实测**：2026-10-19 12:35 的重跑，主模型 480s 超时后 **8ms 内直接进 restore 步**，
队列里的 `opencode/nemotron-3.5-super-vl-free`、`opencode/space-bunny-free` 完全没跑。

**影响**：所有 pin `cgartlab/argus@main` 的仓库，review 门在超时场景下
必红，且 fallback 形同虚设。

**修复方向**：把 `exit_code -eq 124` 分支并入 `elif` 链，或设置一个
`primary_unusable=1` 标志，让 124 绕过 `retry_re` 闸门直入 fallback 循环。

**验收标准**：
- 构造一次主模型超时（可用环境变量把主模型指向不可达地址）后，
  日志里能看到 fallback 队列的尝试记录
- 修复后 review 在超时场景下仍能产出结论，而不是直接失败

**为什么不在本仓库改**：这是 argus 仓库的代码，且那边有并行会话在工作，
动手前需先确认不撞车。

---

## 中优先级

### T3. bash 侧缺计划任务与卸载，与 ps1/ 能力不对等

**依据**：

| 能力 | bash (`fetch.sh`) | `ps1/` |
|---|---|---|
| 一次性运行 | `sudo ./fetch.sh` | `run` |
| 状态 | `--status` | `status` |
| 恢复 hosts | `--restore` | 随 `uninstall` |
| **自动刷新（计划任务）** | **无** | `install` 注册每 3 小时 SYSTEM 任务 |
| **卸载** | **无**（需手动 `rm` + `--restore`） | `uninstall` 完整清理 |

`grep -rn 'cron|systemd|launchd' fetch.sh lib/` 只命中 `systemctl restart systemd-resolved`，
那是 DNS 刷新，不是计划任务。

**影响**：hosts 里的 IP 会失效，bash 用户必须记得手动重跑；卸载也没有官方路径。

**验收标准**（二选一，先定方向再动手）：
- **方案 A（补齐）**：macOS 用 launchd plist、Linux 用 systemd timer / cron，
  `fetch.sh install` 注册、`fetch.sh uninstall` 移除；README 记录
- **方案 B（写清现状）**：在 README 明确「bash 侧需用户自建 cron」，并给出示例

**决策点**：A 会让 bash 侧从「无状态脚本」变成「需要维护的东西」，
影响面比 ps1/ 更大。建议先做 B，等有真实需求再升 A。

---

### T4. `connectivity_probe --scope all` 未被 CI 覆盖

**依据**：CI 的 `cross-platform` job 跑的是 `evals/run_e2e.sh`，其中
`connectivity_probe` 默认 `--scope fast`（10 个端点）。`--scope all` 追加的
6 个端点（ghcr / npmpkg / mavenpkg / avatars / objects / pages）在 CI 里从未执行。

**影响**：这 6 个端点的探测逻辑出错不会被发现。它们只在用户手动加
`--scope all` 时才会跑到。

**验收标准**：
- CI 增加一步 `connectivity_probe --scope all --attempts 1`
- 断言输出里端点数为 16（fast 的 10 + all 追加的 6）
- 允许端点自身失败（外部网络不可控），只断言 **JSON 结构正确、端点齐全**

---

## 低优先级

### T5. `ps1/` 与根 `goto-github.ps1` 的长期去留

**依据**：两套 PowerShell 实现并存且互斥（同一份 hosts 标记、不兼容的 CLI）。

- 根 `goto-github.ps1`：拉取式，`install.ps1` 实际发布
- `ps1/`：扫描式，实验性，`install.ps1` 不下载

**现状**：这个并存关系在 README / AGENTS.md / CLAUDE.md 都有说明，不是隐蔽缺陷。

**待决**：长期是合并、保留，还是把 `ps1/` 作为独立发行出去。
在决定前不应「顺手统一」。

**验收标准**：形成书面决定并更新三处文档；在此之前不动代码。

---

## 近期完成（2026-10-23 / 10-24）

| 版本 | 内容 | PR |
|---|---|---|
| 2.1.0 | 服务面 5 → 10+ 端点；新增 `auth_probe` 分离认证/网络失败；PS 5.1 真正可用；三平台 CI 矩阵 | #56, #57 |
| 2.0.0 | 仓库重构为 Agent Skill 包（`SKILL.md` + `references/` + `scripts/` + `evals/`） | #55 |

**2.1.0 修掉的跨平台致命缺陷**（均由 CI 暴露，非代码评审发现）：

1. `.sh` 写入 CRLF → shebang 变 `bash\r`，Linux/macOS 无法执行
2. `declare -A` → macOS 自带 bash 3.2 直接语法错误
3. `case` 嵌套在 `$( )` 的 `for` 循环内 → bash 3.2 报 `syntax error near ';;'`，指向无关行
4. `mktemp -t prefix-XXXXXX` → BSD mktemp 要求 Xs 在末尾
5. `File.Move` 三参重载 → .NET Framework 不支持，PS 5.1 写盘失败
6. `Get-Service` 检测 ssh-agent → Linux/macOS 无此 cmdlet
7. PowerShell `Write-Warning` 污染 stdout → 破坏「stdout 只有一行 JSON」契约
8. bash 拼 JSON 未转义反斜杠 → Windows 路径让整行不可解析
9. `backup_hosts()` 返回值被 `pipefail` 污染 → `ls` 空 glob 返回非零

---

## 已知但不在计划内

| 项 | 原因 |
|---|---|
| WSL 支持 | WSL 的 hosts 行为与 Windows 不同，语义上无法统一；检测到即提示 |
| 网页浏览加速 | 属浏览器体验，用户明确表示走代理，不由本 skill 负责 |
| 打 tag 后的 release 自动化 | 当前无发布流水线需求；先手动打 tag，有需要再建 workflow |
