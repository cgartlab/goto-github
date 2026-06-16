# GoToGitHub

GitHub 访问加速工具 — 通过找到最快 CDN IP 并配置 hosts 来加速访问。

## 架构

```
GitHub Actions (每 3 小时)
  └── scripts/scan.py → github-ips.json → 提交到仓库

本地机器
  └── fetch.sh → 读取 github-ips.json → 写入 /etc/hosts
```

## 快速开始

```bash
# 一键安装（下载 fetch.sh）
sudo curl -o /usr/local/bin/fetch.sh \
  https://raw.githubusercontent.com/cgartlab/goto-github/main/fetch.sh
sudo chmod +x /usr/local/bin/fetch.sh

# 获取最优 IP 并配置 hosts
sudo fetch.sh

# 查看状态
fetch.sh --status

# 恢复 hosts（原样）
sudo fetch.sh --restore
```

或者直接 clone 运行：

```bash
git clone https://github.com/cgartlab/goto-github.git
cd goto-github
sudo ./fetch.sh
```

## 工作流程

### 云端（GitHub Actions）

每 3 小时自动运行 `scripts/scan.py`：
1. 测试 8 个已知优先级 IP
2. 如需要，展开 CIDR 段扫描更多候选 IP
3. 为每个域名组找到最优 IP
4. 结果写入 `github-ips.json` 并提交到仓库

### 本地（fetch.sh）

1. 从仓库拉取 `github-ips.json`
2. 解析 JSON，构建 hosts block
3. 清理旧的 goto-github block
4. 写入新的 IP 配置到 `/etc/hosts`
5. 刷新 DNS 缓存
6. 验证 IP 是否可用

## 域名组

| 组 | 域名 | 用途 |
|----|------|------|
| CORE | github.com, www.github.com, gist.github.com 等 | 核心网页浏览 |
| RAW | raw.githubusercontent.com | raw 文件下载 |
| CODELOAD | codeload.github.com | 仓库归档下载 |
| OBJECTS | objects.githubusercontent.com | Release / LFS |
| ASSETS | github.githubassets.com, avatars.githubusercontent.com | 静态资源 |

**DNS-only 域名**（不写入 hosts）：
- `api.github.com` — CDN 路由不同，固定 IP 返回 400
- `pipelines.actions.githubusercontent.com` — GitHub Actions 基础设施

## 命令

| 命令 | 说明 |
|------|------|
| `fetch.sh` | 从云端获取 IP 并配置 hosts（需要 sudo） |
| `fetch.sh --status` | 显示当前 IP 和状态 |
| `fetch.sh --restore` | 移除 goto-github 条目 |
| `fetch.sh --help` | 显示帮助 |

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `GITHUB_IPS_URL` | 自动检测 | github-ips.json 的 URL |
| `HOSTS_FILE` | `/etc/hosts` | hosts 文件路径 |

## 依赖

- Bash 3.2+
- curl
- python3（仅云端扫描需要）
- sudo 权限（本地配置 hosts 需要）

## 手动触发云端扫描

在 GitHub Actions 页面手动运行 `CDN IP Scan` workflow。

## 许可证

MIT