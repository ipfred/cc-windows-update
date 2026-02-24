param(
    [Parameter(Position=0)]
    [ValidatePattern('^(stable|latest|\d+\.\d+\.\d+(-[^\s]+)?)$')]
    [string]$Target = "latest"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── 32 位检查 ──────────────────────────────────────────────────────────────────
if (-not [Environment]::Is64BitProcess) {
    Write-Error "Claude Code 不支持 32 位 Windows。"
    exit 1
}

# ── 代理选择 ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "请选择代理类型："
Write-Host "  1) HTTP 代理（默认）"
Write-Host "  2) 不使用代理"
Write-Host ""
$typeChoice = Read-Host "输入选项 [1/2]"

$curlProxy = @()
if ($typeChoice -ne "2") {
    $portInput = Read-Host "输入代理端口 [默认: 7897]"
    if ([string]::IsNullOrWhiteSpace($portInput)) { $portInput = "7897" }
    $proxyUri = "http://127.0.0.1:$portInput"
    Write-Host "使用代理: $proxyUri"
    $curlProxy = @("--proxy", $proxyUri)
} else {
    Write-Host "不使用代理，直接连接。"
}

# ── 平台 & 下载目录 ────────────────────────────────────────────────────────────
$platform = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "win32-arm64" } else { "win32-x64" }
$dlDir = "$env:USERPROFILE\.claude\downloads"
New-Item -ItemType Directory -Force -Path $dlDir | Out-Null

# ── 从最新 install.ps1 解析 GCS_BUCKET ────────────────────────────────────────
Write-Host ""
Write-Host "获取最新安装脚本..."
$installScript = curl.exe -s -L @curlProxy "https://claude.ai/install.ps1"
if ($LASTEXITCODE -ne 0) {
    Write-Error "获取 install.ps1 失败（退出码 $LASTEXITCODE）"
    exit 1
}

$bucketMatch = [regex]::Match($installScript, '\$GCS_BUCKET\s*=\s*"([^"]+)"')
if (-not $bucketMatch.Success) {
    # 输出前 300 字符帮助排查实际返回内容
    $preview = if ($installScript.Length -gt 300) { $installScript.Substring(0, 300) } else { $installScript }
    Write-Host "---- install.ps1 返回内容预览 ----"
    Write-Host $preview
    Write-Host "----------------------------------"
    Write-Error "无法从 install.ps1 解析 GCS_BUCKET，脚本格式可能已变更"
    exit 1
}
$GCS_BUCKET = $bucketMatch.Groups[1].Value

# ── 获取最新版本号 ─────────────────────────────────────────────────────────────
$latestVersion = (curl.exe -s @curlProxy "$GCS_BUCKET/latest").Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($latestVersion)) {
    Write-Error "获取最新版本号失败"
    exit 1
}
Write-Host "最新版本: $latestVersion"

# ── 检查已安装的 claude ────────────────────────────────────────────────────────
$existingClaudePath = $null
$currentVersion = $null

$claudeCmd = Get-Command claude.exe -ErrorAction SilentlyContinue
if ($claudeCmd) {
    $foundPath = $claudeCmd.Source

    # 先读版本号，供后续提示使用
    try {
        $versionOutput = & $foundPath --version 2>&1 | Out-String
        $versionMatch = [regex]::Match($versionOutput, '(\d+\.\d+\.\d+\S*)')
        if ($versionMatch.Success) { $currentVersion = $versionMatch.Groups[1].Value }
    } catch {}

    $versionLabel = if ($currentVersion) { $currentVersion } else { "未知版本" }

    if ($foundPath -match '\\WinGet\\') {
        # winget 安装不做文件替换，走原始 install 命令
        Write-Host "检测到 winget 安装版本（$versionLabel），跳过直接替换，将使用官方 install 方式安装。"
    } else {
        Write-Host "已安装位置: $foundPath"
        Write-Host "当前版本: $versionLabel"
        $existingClaudePath = $foundPath
    }

    if ($currentVersion -eq $latestVersion) {
        Write-Host ""
        Write-Host "已是最新版本（$latestVersion），无需更新。"
        exit 0
    }

    if ($currentVersion) {
        Write-Host "需要更新: $currentVersion -> $latestVersion"
    }
} else {
    Write-Host "未找到已安装的 claude.exe，将执行全新安装。"
}

# ── 获取 manifest & checksum ──────────────────────────────────────────────────
Write-Host ""
Write-Host "获取版本清单..."
$manifestJson = curl.exe -s @curlProxy "$GCS_BUCKET/$latestVersion/manifest.json"
if ($LASTEXITCODE -ne 0) {
    Write-Error "获取 manifest.json 失败"
    exit 1
}

$manifest = $manifestJson | ConvertFrom-Json
$checksum = $manifest.platforms.$platform.checksum
if (-not $checksum) {
    Write-Error "平台 $platform 未在 manifest 中找到"
    exit 1
}

# ── 下载 claude.exe ────────────────────────────────────────────────────────────
$binaryPath = "$dlDir\claude-$latestVersion-$platform.exe"
$downloadUrl = "$GCS_BUCKET/$latestVersion/$platform/claude.exe"

Write-Host "下载 claude.exe ($latestVersion / $platform)..."
Write-Host "下载地址: $downloadUrl"
curl.exe @curlProxy --progress-bar -L -o $binaryPath $downloadUrl
if ($LASTEXITCODE -ne 0) {
    if (Test-Path $binaryPath) { Remove-Item -Force $binaryPath }
    Write-Error "下载失败"
    exit 1
}

# ── 校验 SHA256 ────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "校验文件完整性..."
$actualChecksum = (Get-FileHash -Path $binaryPath -Algorithm SHA256).Hash.ToLower()
if ($actualChecksum -ne $checksum) {
    Remove-Item -Force $binaryPath
    Write-Error "校验失败（期望: $checksum  实际: $actualChecksum）"
    exit 1
}
Write-Host "校验通过"

# ── 安装 / 更新 ────────────────────────────────────────────────────────────────
Write-Host ""
try {
    if ($existingClaudePath) {
        # 已安装：直接替换可执行文件
        Write-Host "替换: $existingClaudePath"
        Copy-Item -Force $binaryPath $existingClaudePath
        Write-Host ""
        if ($currentVersion) {
            Write-Host "更新完成：$currentVersion -> $latestVersion"
        } else {
            Write-Host "更新完成：$latestVersion"
        }
    } else {
        # 全新安装：运行 install 命令完成 PATH 和 shell 集成
        # 将代理写入环境变量，让子进程 claude.exe 能继承并使用
        if ($curlProxy.Count -gt 0) {
            $env:HTTP_PROXY  = $proxyUri
            $env:HTTPS_PROXY = $proxyUri
        }
        Write-Host "正在安装 Claude Code..."
        $installOk = $false
        try {
            if ($Target) {
                & $binaryPath install $Target
            } else {
                & $binaryPath install
            }
            if ($LASTEXITCODE -eq 0) { $installOk = $true }
        } catch {
            Write-Host "install 命令异常: $_"
        }

        if (-not $installOk) {
            # 兜底：直接复制到当前用户的 .local\bin 目录
            $fallbackDir  = "$env:USERPROFILE\.local\bin"
            $fallbackPath = "$fallbackDir\claude.exe"
            Write-Host ""
            Write-Host "原生install 命令失败，通过copy方式安装 $fallbackPath"
            try {
                New-Item -ItemType Directory -Force -Path $fallbackDir | Out-Null
                Copy-Item -Force $binaryPath $fallbackPath
                Write-Host "复制完成。"
                Write-Host "请确认 $fallbackDir 已加入 PATH，否则请手动添加："
                Write-Host "  [Environment]::SetEnvironmentVariable('PATH', `$env:PATH + ';$fallbackDir', 'User')"
            } catch {
                Write-Error "回退复制也失败: $_"
            }
        } else {
            Write-Host ""
            Write-Host "安装完成：$latestVersion"
        }
    }
} finally {
    Start-Sleep -Seconds 1
    # if (Test-Path $binaryPath) {
    #     try { Remove-Item -Force $binaryPath } catch {
    #         Write-Warning "临时文件无法删除，请手动清理: $binaryPath"
    #     }
    # }
}
