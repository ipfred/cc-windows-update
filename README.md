# cc-windows-update

Windows 上安装和更新 [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 的 PowerShell 脚本，解决官方安装方式的代理和进度显示问题。

## 为什么需要这个脚本

官方安装命令：

```powershell
irm https://claude.ai/install.ps1 | iex
```

存在以下问题：

| 问题 | 官方脚本 | 本脚本 |
|------|---------|--------|
| 代理支持 | PowerShell 中设置的代理（如 `$env:HTTP_PROXY`）不生效 | 交互式选择代理，通过 curl 原生 `--proxy` 参数传递 |
| 下载进度 | 无任何进度显示，无法判断是否卡住 | curl 进度条实时显示下载速度和进度 |
| 下载速度 | 使用 PowerShell 内置下载，速度较慢 | 使用 curl.exe 下载，速度更快 |
| 更新体验 | `claude update` 同样无代理、无进度 | 统一的安装/更新流程，体验一致 |

## 功能特性

- **代理支持** - 交互式选择 HTTP 代理或直连，自定义代理端口（默认 7897）
- **下载进度可视化** - 基于 curl 的进度条，实时显示下载状态
- **自动版本检测** - 对比本地与远程版本，已是最新则跳过
- **SHA256 校验** - 下载完成后自动校验文件完整性
- **智能安装/更新** - 已安装则直接替换二进制文件，未安装则执行全新安装
- **winget 兼容** - 检测 winget 安装的版本并正确处理
- **安装兜底机制** - 官方 install 命令失败时，自动回退到复制安装方式

## 使用方法

### 安装或更新到最新版本

```powershell
.\cc_update.ps1
```

### 安装指定版本

```powershell
.\cc_update.ps1 1.0.33
```

### 安装 stable 通道

```powershell
.\cc_update.ps1 stable
```

运行后脚本会交互式引导：

```
请选择代理类型：
  1) HTTP 代理（默认）
  2) 不使用代理

输入选项 [1/2]: 1
输入代理端口 [默认: 7897]: 7897
```

之后自动完成下载、校验、安装/更新全流程。

## 前置要求

- **Windows 10/11**（64 位）
- **PowerShell 5.1+**
- **curl.exe**（Windows 10 1803+ 自带）

## 工作原理

1. 从 `https://claude.ai/install.ps1` 解析最新的 GCS 存储桶地址
2. 从存储桶获取最新版本号
3. 检测本地已安装的 claude.exe 及其版本
4. 如已是最新版本则退出，否则继续
5. 获取 manifest.json 并提取目标平台的 SHA256 校验值
6. 使用 curl.exe 通过代理下载二进制文件（带进度条）
7. 校验 SHA256 完整性
8. 已安装则替换文件，未安装则执行 install 命令（失败时回退到复制安装）

## 常见问题

### 执行策略限制

如果遇到 PowerShell 执行策略限制，可以临时绕过：

```powershell
powershell -ExecutionPolicy Bypass -File .\cc_update.ps1
```

### 代理端口怎么填

填写你本地代理客户端（如 Clash、v2rayN 等）的 HTTP 代理端口，常见默认端口：

| 客户端 | 默认端口 |
|--------|---------|
| Clash Verge | 7897 |
| v2rayN | 10809 |
| Shadowsocks | 1080 |

### 安装后找不到 claude 命令

如果脚本回退到复制安装方式，需要手动将安装目录加入 PATH：

```powershell
[Environment]::SetEnvironmentVariable('PATH', $env:PATH + ';' + "$env:USERPROFILE\.local\bin", 'User')
```

然后重新打开终端生效。

## License

MIT
