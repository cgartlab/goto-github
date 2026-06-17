# GoToGitHub

GitHub 访问加速工具。实时从社区维护的 hosts 源获取 GitHub 域名映射，写入本地 `/etc/hosts`，无需本地扫描。

## 一句话说明

```
sudo ./fetch.sh              # 拉取 → 写入 hosts → 刷新 DNS
./fetch.sh --status         # 查看当前状态（无需 sudo）
sudo ./fetch.sh --restore   # 移除 goto-github 条目
```

## 工作原理

```
数据源（jsDelivr CDN 加速）→ fetch.sh → 内容验证 → 写入 /etc/hosts → DNS 刷新
```

1. **拉取** — 从 GitHub520 社区项目获取 hosts，失败时自动切换备用源
2. **验证** — 检查 IP 条目数量（≥10）和 github.com 域名存在性
3. **写入** — 在 `/etc/hosts` 中以标记区块隔离写入，不影响其他条目
4. **刷新** — macOS / Linux 刷新本地 DNS 缓存

## 数据源

| 源 | 说明 |
|----|------|
| `cdn.jsdelivr.net/gh/521xueweihan/GitHub520@main/hosts` | 主源（CDN 加速） |
| `raw.hellogithub.com/hosts` | 备用源（回退使用） |

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `HOSTS_FILE` | `/etc/hosts` | 指定 hosts 文件路径 |

## 依赖

- Bash 3.2+
- curl
- sudo（写入 hosts 需要）

## 平台

macOS · Linux · Git Bash (Windows)

## Acknowledgements

GoToGitHub would not exist without the community-maintained hosts data provided by the [GitHub520](https://github.com/521xueweihan/GitHub520) project. All CDN IP data comes directly from their work.

---

## 鸣谢

GoToGitHub 依赖 [GitHub520](https://github.com/521xueweihan/GitHub520) 社区项目维护的 hosts 数据，所有 CDN IP 均来源于此。

## 许可证

MIT
