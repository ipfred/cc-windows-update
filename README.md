# cc-windows-update

> One-line install & update [Claude Code](https://docs.anthropic.com/en/docs/claude-code) on Windows — with proxy support and progress bar.

在 Windows 上一行命令安装和更新 Claude Code，支持代理、显示下载进度，告别黑屏等待。

## Quick Start

打开 PowerShell，粘贴运行：

```powershell
irm https://raw.githubusercontent.com/ipfred/cc-windows-update/master/cc_update.ps1 | iex
```

就这么简单。脚本会引导你完成代理配置、下载、校验、安装的全部流程。

## Pain Points / 解决了什么问题

官方安装命令 `irm https://claude.ai/install.ps1 | iex` 在国内网络环境下体验很差：

| | 官方脚本 | cc-windows-update |
|---|---|---|
| **代理** | `$env:HTTP_PROXY` 设了也不生效 | 交互式配置，curl `--proxy` 直连生效 |
| **进度** | 没有任何输出，不知道卡没卡 | curl 进度条，实时显示速度和进度 |
| **速度** | PowerShell 内置下载，慢 | curl.exe 下载，更快 |
| **更新** | `claude update` 同样没代理没进度 | 安装和更新统一流程，体验一致 |
| **校验** | 无 | SHA256 校验，确保文件完整 |

## Features

- **Proxy Support** — 交互式选择 HTTP 代理或直连，自定义端口（默认 7897，兼容 Clash / v2rayN 等）
- **Progress Bar** — 基于 curl 的实时进度条，下载状态一目了然
- **Smart Update** — 自动检测已安装版本，已是最新则跳过，需要更新则直接替换
- **Integrity Check** — SHA256 校验，下载损坏立即报错
- **Winget Compatible** — 自动识别 winget 安装的版本并正确处理
- **Fallback Install** — 官方 install 命令失败时，自动回退到复制安装

## Usage

### 一行命令（推荐）

```powershell
irm https://raw.githubusercontent.com/ipfred/cc-windows-update/master/cc_update.ps1 | iex
```

### 手动下载运行

```powershell
# 安装或更新到最新版本
.\cc_update.ps1

# 安装指定版本
.\cc_update.ps1 1.0.33

# 安装 stable 通道
.\cc_update.ps1 stable

# 安装 latest 通道 不加参数 默认 latest通道
.\cc_update.ps1 latest
```

### 交互流程

```
请选择代理类型：
  1) HTTP 代理（默认）
  2) 不使用代理

输入选项 [1/2]: 1
输入代理端口 [默认: 7897]: 7897
使用代理: http://127.0.0.1:7897

最新版本: 1.0.33
下载 claude.exe (1.0.33 / win32-x64)...
下载地址: https://storage.googleapis.com/.../claude.exe
######################################## 100.0%
校验通过
更新完成：1.0.32 -> 1.0.33
```

## Requirements

- Windows 10/11（64 位）
- PowerShell 5.1+
- curl.exe（Windows 10 1803+ 自带）

## FAQ

<details>
<summary><b>遇到执行策略限制怎么办？</b></summary>

```powershell
powershell -ExecutionPolicy Bypass -File .\cc_update.ps1
```

</details>

<details>
<summary><b>代理端口填什么？</b></summary>

填写你本地代理客户端的 HTTP 端口：

| 客户端 | 默认端口 |
|--------|---------|
| Clash Verge | 7897 |
| v2rayN | 10809 |
| Shadowsocks | 1080 |

</details>

<details>
<summary><b>安装后找不到 claude 命令？</b></summary>

如果脚本回退到复制安装，需要手动将目录加入 PATH：

```powershell
[Environment]::SetEnvironmentVariable('PATH', $env:PATH + ';' + "$env:USERPROFILE\.local\bin", 'User')
```

重新打开终端生效。

</details>

## How It Works

```
获取 install.ps1 → 解析 GCS 存储桶地址
        ↓
  查询最新版本号
        ↓
 检测本地已安装版本 → 已是最新？→ 退出
        ↓
  下载 manifest.json → 提取 SHA256
        ↓
 curl 下载二进制文件（带进度条）
        ↓
    SHA256 校验
        ↓
 已安装？→ 替换文件
 未安装？→ 执行 install（失败则回退复制）
```

## License

MIT

## Star History

如果这个脚本帮到了你，欢迎点个 Star 支持一下。
