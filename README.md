# GoToGitHub

GitHub 访问加速工具 — 从社区维护的 hosts 源获取最优 CDN IP 并写入 `/etc/hosts`，无需本地扫描。

## 快速开始

```bash
sudo ./fetch.sh              # 拉取 hosts → 写入 /etc/hosts → 刷新 DNS
./fetch.sh --status         # 查看当前 IP 和连通性
sudo ./fetch.sh --restore   # 移除 goto-github 条目
```

## 工作原理

1. **拉取** — 从主源（jsDelivr CDN GitHub520）获取 hosts 文件，失败时自动回退到备用源
2. **验证** — 检查内容完整性（至少 10 行有效 IP 条目，且包含 github.com 域名）
3. **写入** — 在 `/etc/hosts` 中用 `# >>> goto-github >>>` / `# <<< goto-github <<<` 标记区块写入
4. **刷新** — macOS 使用 `killall -HUP mDNSResponder`，Linux 使用 `resolvectl flush-caches`

## 数据来源

| 源 | 说明 |
|----|------|
| `cdn.jsdelivr.net/gh/521xueweihan/GitHub520` | 主源（CDN 加速） |
| `raw.hellogithub.com/hosts` | 备用源 |

## 命令

| 命令 | 说明 | 需 sudo |
|------|------|---------|
| `./fetch.sh` | 拉取 hosts 并应用到 `/etc/hosts` | ✅ |
| `./fetch.sh --status` | 显示当前 IP 和连通性 | ❌ |
| `./fetch.sh --restore` | 移除 goto-github 条目 | ✅ |
| `./fetch.sh --help` | 显示帮助 | ❌ |

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `HOSTS_FILE` | `/etc/hosts` | 指定 hosts 文件路径 |

## 故障排除

- **验证失败**：运行 `./fetch.sh --status` 检查当前 IP 和 HTTP 状态码。如为 `000` 表示网络不通，可稍后重试。
- **无法连接**：检查 curl 是否可用，或手动访问数据源 URL 确认是否可达。
- **sudo 错误**：`fetch.sh` 写入 `/etc/hosts` 需要 root 权限。

## 依赖

- Bash 3.2+
- curl
- sudo 权限（配置 hosts 需要）

## 平台

macOS 和 Linux。

## 许可证

MIT