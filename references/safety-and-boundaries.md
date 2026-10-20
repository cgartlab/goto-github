# 安全边界 — hosts 操作红线

Phase 3 执行前必须满足的全部条件。SKILL.md 不复述细则。

## 绝对禁止

1. **不编辑标记区块外部**。只改 `# >>> goto-github >>>` 与 `# <<< goto-github <<<` 之间的行。区块外的一切（含其他工具写的 github.com 条目）一律不碰。
2. **不无备份写入**。没有成功创建备份文件就不许改 hosts。备份失败 → 中止，hosts 保持原样。
3. **不跳过遮蔽检测**。写入前必须检查标记上方是否存在其他工具的 `github.com` 条目。检测到就警告——但**不修改**（规则 1），只报告。
4. **不用假阴性触发兜底**。TCP 探测失败 ≠ 不可达（超时、防火墙丢包都会失败）。区分"连通"与"未测出"，不要用未测出来启动 CIDR 全扫描。
5. **不静默失败**。任何步骤失败都要进 `warnings[]` 或中止。把"没测成"写成"没有"是最危险的编造。

## 为什么标记块必须隔离

hosts 文件是多工具共写的公共资源。本机实测：hosts 中有另一工具留下的 `# Accelerating Notion, GitHub, Steam` 区块。若不隔离，两个工具会互相覆盖对方的条目，用户无法归因。

## 幂等

重复运行 `hosts_apply` 不得产生重复标记块。写入前必须先清除已有标记块（保留块外所有行），再写新块。这是硬要求——重复块会让 hosts 文件无限增长，且后面的块永远不生效（hosts 取首个匹配）。

## 遮蔽检测的具体形态

`/etc/hosts`（与 Windows hosts）取**首个匹配**。所以：

```
其他工具的条目        ← 优先生效
# >>> goto-github >>>
140.82.114.21 github.com
# <<< goto-github <<<
```

这种情况下 goto-github 的整块是死的，而工具会报告"已写入成功"。**这是静默故障**，必须在 Phase 0 就检出、在 Phase 3 写入后再检出一次、在 Phase 4 报告中说明。

检测方法：找到标记起始行行号，检查其上方的行中是否有 `^\s*\d+\.\d+\.\d+\.\d+\s+github\.com(\s|$)`。只检测，不删除——删除他人条目违反规则 1。

## 权限

| 平台 | 写入 hosts 所需 | 脚本行为 |
|---|---|---|
| macOS / Linux | root | bash 脚本检测 `id -u`，非 root 时报错并给出 `sudo` 命令，**不自动提权** |
| Windows | 管理员 | ps1 脚本检测 `WindowsPrincipal.IsInRole(Administrator)`，非管理员时报错说明，**不自动弹 UAC** |

**不自动提权的理由**：自动 `sudo` / 自动弹 UAC 会让用户在不知情下授予权限，且提权后原 shell 的环境变量丢失会导致行为不一致。明确告知需要的命令，让用户自己执行。

**例外**：`ps1/goto-github.ps1`（CLI 兼容层）保留原有的 UAC 重拉逻辑——那是已发布 CLI 的行为，不属于本 skill 的诊断路径。skill 的 `hosts_apply.ps1` 不自动提权。

## DoH 绕过（Windows 必须检测）

DNS-over-HTTPS 启用时，浏览器等应用绕过 hosts 直接加密解析 DNS，hosts 写入对这些应用无效。Phase 0 若检测到 DoH（`Get-DnsClientDohServerAddress` 非零配置或 `DohAutoUpgradeState=1`），必须在报告中警告：hosts 已写但部分应用不生效。

## 清理

卸载/恢复只删标记块内部，不动外部。恢复后 hosts 应恢复到写入前的状态（由备份保证可验证）。
