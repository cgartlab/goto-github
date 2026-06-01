# GoToGitHub

GitHub IP 扫描与 hosts 配置工具。

自动扫描 GitHub CDN IP，找到可用节点，配置 `/etc/hosts` 文件。

## 功能

- 并发扫描 GitHub CDN IP 地址
- 验证 IP 返回真实 GitHub 页面内容
- 自动配置 `/etc/hosts` 文件
- 支持定时任务（每 3 小时）

## 快速开始

```bash
git clone https://github.com/cgartlab/goto-github.git
cd goto-github

# 扫描并配置
sudo ./bin/goto-github.sh run

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

1. 从 GitHub CDN IP 池中并发扫描
2. 验证 HTTP 响应状态和内容大小（>100KB）
3. 选择响应最快的 IP
4. 写入 `/etc/hosts` 文件

## 依赖

- Bash 3.2+
- curl
- python3（可选，用于 IP 段展开）
- sudo 权限

## 许可证

MIT
