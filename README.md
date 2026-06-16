# GoToGitHub

GitHub IP 扫描与 hosts 配置工具。

自动扫描 GitHub CDN IP，找到可用节点，配置 `/etc/hosts` 文件。

## 功能

- 并发扫描 GitHub CDN IP 地址
- 验证 IP 返回真实 GitHub 页面内容
- **多域名组独立优化**：不同用途的域名（网页浏览、raw 文件下载、归档下载、静态资源）分别使用各自最优 IP
- 自动配置 `/etc/hosts` 文件
- 支持定时任务（每 3 小时）

## 快速开始

```bash
git clone https://github.com/cgartlab/goto-github.git
cd goto-github

# 扫描并配置（包括下载加速）
sudo ./bin/goto-github.sh run

# 查看各域名组分配状态
sudo ./bin/goto-github.sh status

# 安装定时任务
sudo ./bin/goto-github.sh install
```

## 命令

| 命令 | 说明 |
|------|------|
| `goto-github run` | 扫描 IP 并更新 hosts |
| `goto-github status` | 查看当前状态 |
| `goto-github install` | 安装定时任务 |
| `goto-github uninstall` | 卸载所有组件 |

## 原理

1. 从 GitHub CDN IP 池中并发扫描，验证 HTTP 响应状态和内容大小（>100KB）
2. 从有效 IP 中为每个域名组（核心网页、raw 下载、归档下载、静态资源）分别筛选最优 IP
3. 将各组最优 IP 写入 `/etc/hosts` 文件（不同组可能使用不同 IP）
4. DNS 专属域名（api.github.com 等）保持正常 DNS 解析，不写入 hosts

## 域名组

| 组 | 域名 | 用途 |
|----|------|------|
| CORE | github.com, www.github.com, ... | 核心网页浏览 |
| RAW | raw.githubusercontent.com | raw 文件下载 |
| CODELOAD | codeload.github.com | 仓库归档下载 (tar.gz/zip) |
| OBJECTS | objects.githubusercontent.com | Release 附件 / LFS |
| ASSETS | github.githubassets.com, avatars.githubusercontent.com | 静态资源 |

## 依赖

- Bash 3.2+
- curl
- python3（可选，用于 IP 段展开）
- sudo 权限

## 许可证

MIT
