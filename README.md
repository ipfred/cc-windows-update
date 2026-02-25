# cc-download

> Download, install & update [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with proxy support and progress bar — on Windows, Linux and macOS.

在 Windows / Linux / macOS 上安装和更新 Claude Code，支持代理、显示下载进度，并支持下载离线安装包上传到无网络的服务器。

## Quick Start

**Windows**（PowerShell）：

```powershell
irm https://raw.githubusercontent.com/ipfred/cc-download/master/cc_download.ps1 | iex
```

**Linux / macOS**（bash）：

```bash
curl -fsSL https://raw.githubusercontent.com/ipfred/cc-download/master/cc_download.sh | bash -s install
```

脚本会引导你完成代理配置、下载、校验、安装的全部流程。

![alt text](151e26054dccef0bc718714b877a3685.png)

## Pain Points / 解决了什么问题

- Claude Code 不支持 npm 方式下载更新，官方脚本在 Windows 上只能开 tun 模式使用
- 官方脚本更新没有进度且下载很慢，每次不知道是卡死了还是在下载
- 在没有公网的服务器上无法直接安装，需要手动下载再传输

| | 官方脚本 | cc-download |
|---|---|---|
| **平台** | Windows / Linux / macOS 各一套 | 统一体验，ps1 + sh 覆盖全平台 |
| **代理** | 设了环境变量也不一定生效 | 交互式配置，curl `--proxy` 直连生效 |
| **进度** | 没有任何输出，不知道卡没卡 | curl 进度条，实时显示速度和进度 |
| **离线** | 不支持 | 下载任意平台安装包，上传服务器离线安装 |
| **校验** | 无 | SHA256 校验，确保文件完整 |

## ⭐ Features 亮点

- **Proxy Support** — 交互式选择 HTTP 代理或直连，自定义端口（默认 7897，兼容 Clash / v2rayN 等）
- **Progress Bar** — 基于 curl 的实时进度条，下载状态一目了然
- **Offline Download** — 下载任意平台的安装包到本地，用于上传服务器离线安装
- **Cross-platform** — `cc_download.ps1` 覆盖 Windows，`cc_download.sh` 覆盖 Linux / macOS
- **Smart Update** — 检测已安装版本，已是最新则跳过，需要更新则直接替换
- **Integrity Check** — SHA256 校验，下载损坏立即报错
- **Winget Compatible** — 自动识别 winget 安装的版本并正确处理
- **Fallback Install** — 官方 install 命令失败时，自动回退到复制安装

## Usage

### 命令说明

```
cc_download[.ps1|.sh]               # 下载离线安装包到当前目录（支持选择任意平台）
cc_download[.ps1|.sh] install       # 安装 Claude Code 到当前系统
cc_download[.ps1|.sh] install stable   # 安装 stable 通道
cc_download[.ps1|.sh] install 1.0.33   # 安装指定版本
cc_download[.ps1|.sh] update       # 更新已安装的 Claude Code 到最新版本
```

---

### Windows

**一行命令（推荐）：**

```powershell
# 安装
irm https://raw.githubusercontent.com/ipfred/cc-download/master/cc_download.ps1 | iex

# 下载离线包（需先下载脚本）
.\cc_download.ps1
```

**手动下载脚本后运行：**

```powershell
# 下载离线安装包（选择目标平台和版本）
.\cc_download.ps1

# 安装到当前系统
.\cc_download.ps1 install

# 更新已安装版本
.\cc_download.ps1 update

# 安装指定通道 / 版本
.\cc_download.ps1 install stable
.\cc_download.ps1 install 1.0.33
```

---

### Linux / macOS

```bash
# 安装
bash cc_download.sh install

# 更新
bash cc_download.sh update

# 下载离线安装包（选择目标平台和版本）
bash cc_download.sh

# 安装指定通道 / 版本
bash cc_download.sh install stable
bash cc_download.sh install 1.0.33
```

---

### 交互流程示例

**install / update 模式：**

```
请选择代理类型：
  1) HTTP 代理（默认）
  2) 不使用代理

输入选项 [1/2]: 1
输入代理端口 [默认: 7897]: 7897
使用代理: http://127.0.0.1:7897

最新版本: 1.0.33
当前版本: 1.0.32
需要更新: 1.0.32 -> 1.0.33

下载 claude (1.0.33 / linux-x64)...
######################################## 100.0%
校验通过
更新完成：1.0.32 -> 1.0.33

✅ 完成！
```

**下载模式（无参数）：**

```
选择目标平台：
  1) linux-x64          Linux x64 (glibc)
  2) linux-arm64        Linux ARM64 (glibc)
  3) linux-x64-musl     Linux x64 (musl/Alpine)
  4) linux-arm64-musl   Linux ARM64 (musl/Alpine)
  5) darwin-x64         macOS x64 (Intel)
  6) darwin-arm64       macOS ARM64 (Apple Silicon)
  7) win32-x64          Windows x64
  8) win32-arm64        Windows ARM64

输入选项 [1-8]: 1

选择版本通道：
  1) latest（最新版，默认）
  2) stable（稳定版）
  3) 输入指定版本号

输入选项 [1/2/3]: 1
版本: 1.0.33

下载 claude-1.0.33-linux-x64...
######################################## 100.0%
校验通过

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
 文件已下载: claude-1.0.33-linux-x64  (58341 KB)
 保存位置:   /Users/you/claude-1.0.33-linux-x64
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

 离线安装方法：

   1. 将 claude-1.0.33-linux-x64 上传到目标服务器（如 /tmp/）
   2. 授予执行权限并安装：
        chmod +x /tmp/claude-1.0.33-linux-x64 && /tmp/claude-1.0.33-linux-x64 install
```

## Requirements

**Windows：**
- Windows 10/11（64 位）
- PowerShell 5.1+
- curl.exe（Windows 10 1803+ 自带）

**Linux / macOS：**
- bash
- curl 或 wget

## FAQ

<details>
<summary><b>Windows 遇到执行策略限制怎么办？</b></summary>

```powershell
powershell -ExecutionPolicy Bypass -File .\cc_download.ps1 install
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

如果脚本回退到复制安装，需要手动将目录加入 PATH。

**Windows：**
```powershell
[Environment]::SetEnvironmentVariable('PATH', $env:PATH + ';' + "$env:USERPROFILE\.local\bin", 'User')
```

**Linux / macOS：**
```bash
echo 'export PATH="$PATH:$HOME/.local/bin"' >> ~/.bashrc
source ~/.bashrc
```

重新打开终端生效。

</details>

<details>
<summary><b>如何查看目标机器的平台？</b></summary>

在目标机器上运行以下命令，对照结果选择对应平台。

**Windows（PowerShell）：**

```powershell
$env:PROCESSOR_ARCHITECTURE
```

| 输出 | 选择平台 |
|------|---------|
| `AMD64` | `win32-x64` |
| `ARM64` | `win32-arm64` |

---

**Linux：**

```bash
# 第一步：查看 CPU 架构
uname -m

# 第二步：判断是否为 musl 系统（Alpine 等）
ldd /bin/ls 2>&1 | grep -q musl && echo "musl" || echo "glibc"
```

| `uname -m` | libc | 选择平台 |
|-----------|------|---------|
| `x86_64` | glibc | `linux-x64` |
| `aarch64` | glibc | `linux-arm64` |
| `x86_64` | musl | `linux-x64-musl` |
| `aarch64` | musl | `linux-arm64-musl` |

---

**macOS：**

```bash
# 第一步：查看 CPU 架构
uname -m

# 第二步：如果第一步输出 x86_64，检查是否在 Rosetta 2 下运行
sysctl -n sysctl.proc_translated 2>/dev/null
```

| `uname -m` | `proc_translated` | 选择平台 |
|-----------|-------------------|---------|
| `arm64` | — | `darwin-arm64` |
| `x86_64` | 空 / `0` | `darwin-x64` |
| `x86_64` | `1`（Rosetta） | `darwin-arm64` |

> Apple Silicon Mac 上用 Rosetta 启动的终端会显示 `x86_64`，但实际应下载 `darwin-arm64`。

</details>

<details>
<summary><b>如何在无网络的服务器上安装？</b></summary>

1. 在有网络的机器上运行脚本（无参数进入下载模式），选择目标服务器的平台和版本
2. 将下载好的文件上传到服务器
3. 在服务器上执行：

```bash
chmod +x /tmp/claude-1.0.33-linux-x64
/tmp/claude-1.0.33-linux-x64 install
```

</details>

## How It Works

```
获取 install.ps1 / install.sh → 解析 GCS 存储桶地址
              ↓
        ┌─────┴──────┐
    无参数          install / update
   下载模式              ↓
        ↓         查询最新版本号
  选择目标平台           ↓
  选择版本通道    检测本地已安装版本
        ↓         已是最新？→ 退出
  查询版本号             ↓
        └─────┬──────┘
              ↓
     下载 manifest.json → 提取 SHA256
              ↓
      curl 下载二进制（带进度条）
              ↓
          SHA256 校验
              ↓
     ┌────────┴────────┐
  下载模式          install / update
  存到当前目录      install → 执行 binary install
  打印离线指引      update  → 替换已安装文件
```

## License

MIT

## Star History

如果这个脚本帮到了你，欢迎点个 Star 支持一下。
