# TASKS — goto-github

> 本文件是仓库的**唯一任务列表**。只记「有真实信号支持、尚未完成」的事项；
> 完成的条目移到 §近期完成 并注明 PR 号。写之前先核实信号，写不出证据的不要进表。
>
> 维护规则：新增任务须带 **依据**（命令输出 / 代码位置 / CI 结果）与
> **验收标准**（怎么算做完）。没有验收标准的条目视为愿望，不进本表。

最后更新：2026-10-24

---

## 低优先级

### T5. `ps1/` 与根 `goto-github.ps1` 的长期去留 → [issue #61](https://github.com/cgartlab/goto-github/issues/61)

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
| 2.1.x（argus 侧） | T2 完成：argus 超时后真正进入 fallback 队列（`eb60ac3`），并由 argus #209 / v0.6.7 修掉校验器假失败与 `bump_version` 未提升 Unreleased | argus#209 |
| 2.1.x | T3 完成（方案 B）：README 新增「自动刷新与卸载（bash 侧需自建）」，给出 systemd timer / cron 两种示例与卸载步骤；同时修正示例路径——安装脚本把命令放在 `~/.local/bin`，此前示例误写 `/usr/local/bin` | — |
| 2.1.x | T4 完成：`--scope all` 的 6 个端点纳入 e2e（两侧各 3 条断言，反向验证过）；顺带修掉 `pages` 端点硬编码维护者个人站点的问题，改为从 `PROBE_REPO` 的 owner 推导 | — |
| 2.1.0 tag | `v2.1.0` 已打并推送（annotated tag，指向 `0b2080c`） | — |
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
