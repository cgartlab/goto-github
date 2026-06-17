# GoToGitHub

[![Lint](https://github.com/cgartlab/goto-github/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/cgartlab/goto-github/actions)
[![MIT License](https://img.shields.io/github/license/cgartlab/goto-github?style=flat-square)](https://github.com/cgartlab/goto-github/blob/main/LICENSE)

GitHub 访问加速工具。实时从社区维护的 hosts 源获取 GitHub 域名映射，写入本地 `/etc/hosts`，无需本地扫描。

## 一键安装

**macOS / Linux (Git Bash):**

```bash
# 方式一：原始链接（推荐，如果可访问）
curl -sfL https://raw.githubusercontent.com/cgartlab/goto-github/main/install.sh | bash

# 方式二：jsDelivr 镜像（国内推荐）
curl -sfL https://cdn.jsdelivr.net/gh/cgartlab/goto-github@main/install.sh | bash

# 方式三：ghproxy 镜像
curl -sfL https://ghproxy.com/https://raw.githubusercontent.com/cgartlab/goto-github/main/install.sh | bash
```

**Windows PowerShell:**

```powershell
# 方式一：bootstrap.ps1 一键安装（推荐）
irm https://raw.githubusercontent.com/cgartlab/goto-github/main/bootstrap.ps1 | iex

# 方式二：jsDelivr 镜像（国内推荐）
irm https://cdn.jsdelivr.net/gh/cgartlab/goto-github@main/bootstrap.ps1 | iex

# 方式三：-OutFile fallback（备用）
irm https://raw.githubusercontent.com/cgartlab/goto-github/main/install.ps1 -OutFile "$env:TEMP\install.ps1"; & "$env:TEMP\install.ps1"
```

**说明**：安装脚本会自动尝试多个镜像源，如果某个源失败会自动切换到下一个。

## 一句话说明

**Bash (macOS / Linux / Git Bash):**
```bash
sudo ./fetch.sh              # 拉取 → 写入 hosts → 刷新 DNS
./fetch.sh --status         # 查看当前状态（无需 sudo）
sudo ./fetch.sh --restore   # 移除 goto-github 条目
```

**PowerShell (Windows):**
```powershell
.\goto-github.ps1           # 交互菜单（需管理员权限修改 hosts）
.\goto-github.ps1 --pwsh status  # JSON 状态（脚本用）
```

## 手动使用

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

| 平台 | 依赖 |
|------|------|
| macOS / Linux | Bash 3.2+、curl |
| Windows | PowerShell 5.1+（原生，无需 Git Bash） |

所有平台均需要管理员权限（写入 hosts）。

## 平台

- **macOS / Linux**: 使用 Bash 脚本
- **Windows**: 使用 PowerShell 原生实现

## Windows 说明

Windows 用户使用 PowerShell 原生实现，无需 Git Bash：

```powershell
# 安装
irm https://raw.githubusercontent.com/cgartlab/goto-github/main/bootstrap.ps1 | iex

# 使用
.\goto-github.ps1           # 交互菜单
.\goto-github.ps1 --pwsh status  # JSON 状态（脚本用）
.\goto-github.ps1 --pwsh auto    # 一键加速
.\goto-github.ps1 --pwsh restore # 恢复 hosts
```

**注意**：修改 hosts 文件需要管理员权限，脚本会自动请求提升。

## 许可证

MIT
