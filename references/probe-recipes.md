# 探测配方 — 脚本 JSON 契约

Phase 0/1/3/4 调用的脚本的字段语义。SKILL.md 不复述这些字段。

## 通用约定

- 所有脚本支持 `--help`，**先调 `--help` 再调用**。
- 所有脚本输出单行 JSON 到 stdout；进度/诊断信息一律走 stderr，不污染 stdout。
- bash 与 PowerShell 两套输出**同形同字段**，字段名一致、类型一致。
- 失败必须可见：采集失败时相关字段为 `null`，同时在 `warnings[]` 追加原因。**禁止把失败写成空值或 `[]`**——那会让消费方误判为"测了，结果是空"。
- 探测类脚本只读，绝不写 hosts。`hosts_apply` 是唯一写系统文件的脚本。

## env_detection — 环境探测（Phase 0）

```json
{
  "shell": "bash | pwsh",
  "platform": "macOS | Linux | Windows | Windows Git Bash",
  "curl": { "available": true, "path": "/usr/bin/curl" },
  "hosts_entry": {
    "present": false,
    "ip": null,
    "shadowed": false,
    "shadowing_detail": null
  },
  "proxy": {
    "enabled": false,
    "server": "127.0.0.1:7897",
    "source": "system | env | none"
  },
  "dns_servers": ["223.5.5.5", "223.6.6.6"],
  "gh_auth": {
    "state": "keyring_ok | env_var_shadowed | none | error",
    "warning": null
  },
  "privileged": false,
  "warnings": []
}
```

### 字段语义

| 字段 | 语义 |
|---|---|
| `shell` | 当前脚本自身运行在哪种 shell。**不是探测用户偏好**，是事实。 |
| `curl.available` | `false` → 停止后续所有探测，如实说明。curl 是硬依赖。 |
| `hosts_entry.present` | hosts 中是否存在 goto-github 标记块。`true` 表示已装过。 |
| `hosts_entry.ip` | 标记块中映射到 `github.com` 的 IP；无则为 `null`。 |
| `hosts_entry.shadowed` | 标记块**上方**（文件中更早的行）存在其他工具写入的 `github.com` 条目 → 整块失效。这是必须报告的静默故障。 |
| `proxy.enabled` | 系统代理开关。`true` 时 Phase 1 必须绕代理。 |
| `gh_auth.state` | `env_var_shadowed` = 环境变量 `GITHUB_TOKEN` 失效并遮蔽 keyring 有效 token。**这不是网络问题**，但会让 `gh` 报 401。git 操作不受影响。 |
| `privileged` | bash: 是否 root；Windows: 是否管理员。决定 Phase 3 能否执行。 |

### 已知陷阱（写脚本与读结果都适用）

- **`gh auth status` 的输出不可直接信任**：它同时列出失效的 env token（标 `X`）和有效的 keyring token（标 `✓`），容易看串。必须解析出哪个是 active。实测中 env token 失效导致所有 `gh` 命令 401，而 keyring token 完全正常。
- **hosts 文件里只有注释提到 github 不算条目**：必须匹配 `^\s*\d+\.\d+\.\d+\.\d+\s+github\.com`，不能 `grep github`。实测本机 hosts 有 `# Accelerating ... GitHub ...` 注释但无实际条目。
- **DNS 服务器列表可能为空**（无活动网卡）：`dns_servers` 为 `[]` 是合法值，与"查询失败"（`null` + warning）不同。

## connectivity_probe — 连通性采样（Phase 1）

```json
{
  "timestamp": "2026-10-23T12:00:00Z",
  "proxy_bypassed": true,
  "attempts": 10,
  "scope": "fast",
  "endpoints": [
    {
      "key": "git_read",
      "url": "https://github.com/.../info/refs?service=git-upload-pack",
      "group": "git",
      "kind": "git-smart",
      "success": 10,
      "fail": 0,
      "rate": 100,
      "latency": { "min": 0.59, "max": 0.60, "avg": 0.60 }
    }
  ],
  "warnings": []
}
```

### 字段语义

| 字段 | 语义 |
|---|---|
| `proxy_bypassed` | 必须为 `true`。为 `false` 说明探测走了代理，结论不可用于判定 |
| `attempts` | 每端点采样次数。复测必须与首测一致，否则不可比 |
| `scope` | `fast`（默认）或 `all`；决定 endpoint 集合 |
| `group` | `web`/`api`/`git`/`raw`/`download`/`assets`/`ssh`/`registry` |
| `kind` | `http` / `git-smart` / `tcp`。决定探测方式，不要凭名字猜 |
| `success` | 拿到真实 HTTP 状态码的次数（`tcp` 类为 TCP 握手成功次数）。**`000`（无响应）不算成功** |
| `rate` | `success / attempts * 100`，整数百分比 |
| `latency` | 仅统计成功的请求，单位秒。全失败时为 `null` |

### 已知陷阱

- **`http_code` 为 `000` 不是成功**：curl 在连接失败/超时/DNS 失败时输出 `000`。必须显式排除。把它计入成功会让"完全不通"显示成"100% 可用"。
- **单端点 `success` 为 0 时 `latency` 必须是 `null`**，不是 `{min:0,max:0,avg:0}`。
- **`git-smart` 端点必须带 Accept 头**：`application/x-git-upload-pack-advertisement`。不带时 GitHub 的响应不同，测的就不是 git 路径。
- **`tcp` 端点用 `telnet://` 或 socket 握手**，不能用 HTTP 状态码。curl 的 `time_connect` 非零即表示握手完成；退出码非零是 peer 在握手后关闭，不算失败。
- **bash 循环里跑 curl 会吞 stdin**：`while read < <(...)` 的循环体里 curl 继承 stdin 并消费剩余行（实测 10 个端点变 9 个）。用 `exec 3< <(...)` + `read <&3`。

## auth_probe — 凭据状态（Phase 1b）

```json
{
  "ssh":   { "state": "auth-fail", "detail": "transport OK but the key is not authorized on any GitHub account" },
  "https": { "state": "ok",        "detail": "gh token has push permission on cgartlab/goto-github" },
  "gh":    { "state": "keyring_ok","warning": null },
  "warnings": ["SSH reaches GitHub but the key is not registered; use HTTPS or add the key to GitHub"]
}
```

### 字段语义

| 字段 | 取值 | 判定依据 |
|---|---|---|
| `ssh.state` | `transport-ok` | 输出含 `successfully authenticated` |
| | `auth-fail` | 输出含 `Permission denied (publickey)` — **传输已通** |
| | `blocked` | 输出含 `Connection refused` / `timed out` / `unreachable` |
| | `no-key` | `~/.ssh` 无私钥且 ssh-agent 未运行 |
| `https.state` | `ok` | helper 可用且 `gh api .../permissions.push` 为 `true` |
| | `permission-denied` | token 有效但 `push` 为 `false` |
| | `no-credentials` | 无 helper，或 gh 无可用 token |
| `gh.state` | `keyring_ok` | gh api 成功 |
| | `env_var_shadowed` | `GITHUB_TOKEN` 存在但失效 |

**`auth-fail` 与 `blocked` 必须区分**：前者说明 TCP/TLS/密钥交换全成功、只是密钥没注册；后者说明根本连不上。混为一谈会让用户去修网络或去换密钥，方向都是错的。

**检查顺序不能反**：先看有没有密钥文件，再跑 `ssh -T`。没有密钥时 `ssh -T` 同样返回 `Permission denied (publickey)`，与"密钥未授权"无法区分。

## hosts_apply — 写入 hosts（Phase 3）

```json
{
  "applied": true,
  "strategy": "priority | community | cidr",
  "ip": "140.82.114.21",
  "entries_written": 8,
  "backup": "/etc/hosts.goto-github.bak.20261020120000",
  "shadowing": { "checked": true, "found": false, "detail": null },
  "dns_flushed": true,
  "warnings": []
}
```

### 字段语义

| 字段 | 语义 |
|---|---|
| `strategy` | 实际生效的策略。按 `priority → community → cidr` 降级，**记录实际用了哪个**，不记录尝试过哪些。 |
| `backup` | 备份文件绝对路径。**必须非空**——没有备份就不许写。 |
| `shadowing.found` | 写入前检测到标记上方有其他工具条目。`true` 时仍可写入（不越界改外部），但必须在报告与 `warnings[]` 中说明"整块可能被遮蔽"。 |
| `dns_flushed` | `false` 时 hosts 已写但缓存未清，用户需手动刷新——必须如实报。 |
| `applied` | `false` 时 hosts 未被修改，`warnings[]` 说明原因。 |

## hosts_status — 复测与状态（Phase 4）

```json
{
  "timestamp": "2026-10-20T12:05:00Z",
  "installed": true,
  "current_ip": "140.82.114.21",
  "endpoints": [ "...same shape as connectivity_probe.endpoints..." ],
  "verdict": "fixed | partial | not_fixed | not_installed",
  "warnings": []
}
```

### verdict 语义

| 值 | 条件 |
|---|---|
| `fixed` | 修复前 `web` < 60% 且修复后 `web` ≥ 60%，至少一个端点高出基线 ≥ 10 个百分点（噪声阈值），且 git/api 未退化 |
| `partial` | 至少一个端点高出基线 ≥ 10 个百分点，但未达到阈值 |
| `not_fixed` | 无端点达到噪声阈值 |
| `not_installed` | 无 goto-github 标记块（Phase 3 未执行或失败） |

**噪声阈值（10 个百分点）是必需的**：采样噪声本身能产生 1–2 个百分点波动（实测 99% → 100% 纯属偶然）。不计阈值会让 `partial` 泛滥，而那正是 baseline 对比要避免的假阳性。

**`partial` 与 `not_fixed` 必须如实输出。** 写入 hosts 不等于修好了——实测存在写入后仍不通的情况（IP 失效、遮蔽、DoH 绕过）。验证不过就是没过。

## 双语言一致性

bash 与 PowerShell 脚本必须输出同形 JSON。校验方式：`make parity`（`shared/parity-check.sh`）保证共享常量（标记行、数据源列表）一致；JSON 契约靠 `evals/` 的 fixtures 对比字段集合。

改任何脚本的字段后，**两套都要改**，并同步更新本文件。
