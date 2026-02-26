$ErrorActionPreference = "Stop"

# ── 交互式模式选择 ────────────────────────────────────────────────────────────
$Mode = ""     # "" = download
$Target = ""
Write-Host ""
Write-Host "选择运行模式："
Write-Host "  1) download  下载离线安装包（默认）"
Write-Host "  2) install   安装 Claude Code"
Write-Host "  3) update    更新 Claude Code"
Write-Host ""
$modeChoice = Read-Host "输入选项 [1/2/3]"
switch ($modeChoice) {
    "2" { $Mode = "install" }
    "3" { $Mode = "update" }
    default { $Mode = "" }
}

if ($Mode -eq "install") {
    Write-Host ""
    Write-Host "选择安装目标："
    Write-Host "  1) 默认（不指定 Target，默认通道）"
    Write-Host "  2) latest"
    Write-Host "  3) stable"
    Write-Host "  4) 指定版本号（如 1.0.33）"
    Write-Host ""
    $targetChoice = Read-Host "输入选项 [1/2/3/4]"
    switch ($targetChoice) {
        "2" { $Target = "latest" }
        "3" { $Target = "stable" }
        "4" {
            $Target = Read-Host "输入版本号（如 1.0.33）"
            if ($Target -notmatch '^\d+\.\d+\.\d+(-[^\s]+)?$') {
                Write-Error "版本号格式不正确（示例: 1.0.33）"
                exit 1
            }
        }
        default { $Target = "" }
    }
}

# ── 32 位检查（仅 install / update 模式）─────────────────────────────────────
if ($Mode -ne "" -and -not [Environment]::Is64BitProcess) {
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
$proxyUri = ""
if ($typeChoice -ne "2") {
    $portInput = Read-Host "输入代理端口 [默认: 7897]"
    if ([string]::IsNullOrWhiteSpace($portInput)) { $portInput = "7897" }
    $proxyUri = "http://127.0.0.1:$portInput"
    $curlProxy = @("--proxy", $proxyUri)
    Write-Host "使用代理: $proxyUri"
}
else {
    Write-Host "不使用代理，直接连接。"
}

# ── 从官方 install.ps1 动态解析 GCS_BUCKET ────────────────────────────────────
Write-Host ""
Write-Host "获取最新安装脚本..."
$installScript = curl.exe -s -L @curlProxy "https://claude.ai/install.ps1"
if ($LASTEXITCODE -ne 0) {
    Write-Error "获取 install.ps1 失败（退出码 $LASTEXITCODE）"
    exit 1
}

$bucketMatch = [regex]::Match($installScript, '\$GCS_BUCKET\s*=\s*"([^"]+)"')
if (-not $bucketMatch.Success) {
    $preview = if ($installScript.Length -gt 300) { $installScript.Substring(0, 300) } else { $installScript }
    Write-Host "---- install.ps1 返回内容预览 ----"
    Write-Host $preview
    Write-Host "----------------------------------"
    Write-Error "无法从 install.ps1 解析 GCS_BUCKET，脚本格式可能已变更"
    exit 1
}
$GCS_BUCKET = $bucketMatch.Groups[1].Value

# ── 下载或复用已缓存的 claude 二进制 ──────────────────────────────────────────
function Get-ClaudeBinary {
    param(
        [string]   $BinaryPath,
        [string]   $DownloadUrl,
        [string]   $Checksum,
        [string]   $Label,
        [string[]] $Proxy
    )
    if (Test-Path $BinaryPath) {
        Write-Host "发现已缓存文件，校验中..."
        $cached = (Get-FileHash -Path $BinaryPath -Algorithm SHA256).Hash.ToLower()
        if ($cached -eq $Checksum) {
            Write-Host "校验通过，跳过下载。"
            return
        }
        Write-Host "缓存文件校验不匹配，重新下载..."
        Remove-Item -Force $BinaryPath
    }
    Write-Host "下载 $Label..."
    Write-Host "下载地址: $DownloadUrl"
    curl.exe @Proxy --progress-bar -L -o $BinaryPath $DownloadUrl
    if ($LASTEXITCODE -ne 0) {
        if (Test-Path $BinaryPath) { Remove-Item -Force $BinaryPath }
        Write-Error "下载失败"; exit 1
    }
    Write-Host ""
    Write-Host "校验文件完整性..."
    $actual = (Get-FileHash -Path $BinaryPath -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $Checksum) {
        Remove-Item -Force $BinaryPath
        Write-Error "校验失败（期望: $Checksum  实际: $actual）"; exit 1
    }
    Write-Host "校验通过"
}

# ── 清理残留 .old 文件（未被进程占用的）──────────────────────────────────────
function Remove-OldBackups {
    param([string]$BasePath)
    $dir  = Split-Path $BasePath -Parent
    $name = Split-Path $BasePath -Leaf
    Get-ChildItem -Path $dir -Filter "$name.old" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $dir -Filter "$name.*.old" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# ── mv+cp 替换（允许对运行中 exe 重命名）──────────────────────────────────────
function Replace-Binary {
    param([string]$TargetPath, [string]$SourcePath)
    $bakPath = "$TargetPath.old"
    if (Test-Path $bakPath) {
        $bakPath = "$TargetPath.$(Get-Date -Format 'yyyyMMdd_HHmmss').old"
    }
    try {
        Move-Item -Force $TargetPath $bakPath
        Copy-Item -Force $SourcePath $TargetPath
        Remove-Item -Force $bakPath -ErrorAction SilentlyContinue
    }
    catch {
        if (-not (Test-Path $TargetPath) -and (Test-Path $bakPath)) {
            Move-Item -Force $bakPath $TargetPath
            Write-Host "已回滚到旧版本。"
        }
        Write-Error "替换失败: $_"; exit 1
    }
}

# ════════════════════════════════════════════════════════════════════════════════
if ($Mode -eq "") {
# ════ 下载模式 ════════════════════════════════════════════════════════════════

    # ── 选择目标平台 ──────────────────────────────────────────────────────────
    $platforms = @(
        [pscustomobject]@{ Id = 1; Name = "linux-x64";       Label = "Linux x64 (glibc)";         IsWin = $false }
        [pscustomobject]@{ Id = 2; Name = "linux-arm64";     Label = "Linux ARM64 (glibc)";        IsWin = $false }
        [pscustomobject]@{ Id = 3; Name = "linux-x64-musl";  Label = "Linux x64 (musl/Alpine)";   IsWin = $false }
        [pscustomobject]@{ Id = 4; Name = "linux-arm64-musl";Label = "Linux ARM64 (musl/Alpine)"; IsWin = $false }
        [pscustomobject]@{ Id = 5; Name = "darwin-x64";      Label = "macOS x64 (Intel)";         IsWin = $false }
        [pscustomobject]@{ Id = 6; Name = "darwin-arm64";    Label = "macOS ARM64 (Apple Silicon)";IsWin = $false }
        [pscustomobject]@{ Id = 7; Name = "win32-x64";       Label = "Windows x64";               IsWin = $true  }
        [pscustomobject]@{ Id = 8; Name = "win32-arm64";     Label = "Windows ARM64";              IsWin = $true  }
    )

    Write-Host ""
    Write-Host "选择目标平台："
    foreach ($p in $platforms) {
        Write-Host ("  " + $p.Id + ") " + $p.Name.PadRight(22) + " " + $p.Label)
    }
    Write-Host ""
    $platformInput = Read-Host "输入选项 [1-8]"
    $platformId = 0
    if (-not [int]::TryParse($platformInput, [ref]$platformId)) {
        Write-Error "请输入 1-8 之间的数字"; exit 1
    }
    $selPlatform = $platforms | Where-Object { $_.Id -eq $platformId }
    if (-not $selPlatform) { Write-Error "无效的选项"; exit 1 }

    # ── 选择版本通道 ───────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "选择版本通道："
    Write-Host "  1) latest（最新版，默认）"
    Write-Host "  2) stable（稳定版）"
    Write-Host "  3) 输入指定版本号"
    Write-Host ""
    $channelChoice = Read-Host "输入选项 [1/2/3]"
    $channel = ""
    switch ($channelChoice) {
        "2" { $channel = "stable" }
        "3" {
            $channel = Read-Host "输入版本号（如 1.0.33）"
            if ($channel -notmatch '^\d+\.\d+\.\d+') {
                Write-Error "版本号格式不正确"; exit 1
            }
        }
        default { $channel = "latest" }
    }

    # ── 解析版本号 ─────────────────────────────────────────────────────────────
    $version = ""
    if ($channel -match '^\d+\.\d+\.\d+') {
        $version = $channel
    }
    else {
        $version = (curl.exe -s @curlProxy "$GCS_BUCKET/$channel").Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($version)) {
            Write-Error "获取 $channel 版本号失败"; exit 1
        }
    }
    Write-Host "版本: $version"

    # ── 获取 manifest & checksum ──────────────────────────────────────────────
    Write-Host ""
    Write-Host "获取版本清单..."
    $manifestJson = curl.exe -s @curlProxy "$GCS_BUCKET/$version/manifest.json"
    if ($LASTEXITCODE -ne 0) { Write-Error "获取 manifest.json 失败"; exit 1 }
    $manifest  = $manifestJson | ConvertFrom-Json
    $platProp  = $manifest.platforms.PSObject.Properties[$selPlatform.Name]
    if (-not $platProp) { Write-Error "平台 $($selPlatform.Name) 未在 manifest 中找到"; exit 1 }
    $checksum  = $platProp.Value.checksum

    # ── 下载或复用缓存（当前目录）─────────────────────────────────────────────
    $ext        = if ($selPlatform.IsWin) { ".exe" } else { "" }
    $remoteBin  = if ($selPlatform.IsWin) { "claude.exe" } else { "claude" }
    $binaryName = "claude-$version-$($selPlatform.Name)$ext"
    $outputPath = Join-Path (Get-Location) $binaryName
    $downloadUrl= "$GCS_BUCKET/$version/$($selPlatform.Name)/$remoteBin"
    Write-Host "保存目录: $(Get-Location)"
    Get-ClaudeBinary -BinaryPath $outputPath -DownloadUrl $downloadUrl `
        -Checksum $checksum -Label $binaryName -Proxy $curlProxy

    $fileSizeMB = [math]::Round((Get-Item $outputPath).Length / 1MB, 1)

    # ── 离线安装提示 ───────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    Write-Host " 文件已下载: $binaryName  ($fileSizeMB MB)"
    Write-Host " 保存位置:   $outputPath"
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    Write-Host ""
    Write-Host " 离线安装方法："
    Write-Host ""
    if ($selPlatform.IsWin) {
        Write-Host "   1. 将 $binaryName 复制到目标 Windows 机器"
        Write-Host "   2. 在 PowerShell 中运行："
        Write-Host "        New-Item -ItemType Directory -Force `"`$env:USERPROFILE\.local\bin`""
        Write-Host "        Copy-Item .\$binaryName `"`$env:USERPROFILE\.local\bin\claude.exe`""
    }
    else {
        Write-Host "   1. 将 $binaryName 上传到目标服务器（如 /tmp/）"
        Write-Host "   2. 复制到可执行目录："
        Write-Host "        mkdir -p ~/.local/bin"
        Write-Host "        cp /tmp/$binaryName ~/.local/bin/claude"
        Write-Host "        chmod +x ~/.local/bin/claude"
    }
    Write-Host ""
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

}
elseif ($Mode -eq "update") {
# ════ 更新模式 ════════════════════════════════════════════════════════════════

    # ── 检查已安装的 claude ────────────────────────────────────────────────────
    $claudeCmd = Get-Command claude.exe -ErrorAction SilentlyContinue
    if (-not $claudeCmd) {
        Write-Error "未找到已安装的 claude.exe，请重新运行脚本并选择 install 模式。"
        exit 1
    }

    $foundPath = $claudeCmd.Source
    if ($foundPath -match '\\WinGet\\') {
        Write-Host "检测到 winget 安装版本，请使用 winget 更新："
        Write-Host "  winget upgrade --id Anthropic.Claude"
        exit 0
    }

    $currentVersion = $null
    try {
        $versionOutput = & $foundPath --version 2>&1 | Out-String
        $versionMatch  = [regex]::Match($versionOutput, '(\d+\.\d+\.\d+\S*)')
        if ($versionMatch.Success) { $currentVersion = $versionMatch.Groups[1].Value }
    }
    catch {}

    Write-Host "已安装位置: $foundPath"
    Write-Host "当前版本: $(if ($currentVersion) { $currentVersion } else { '未知' })"

    # ── 获取最新版本号 ─────────────────────────────────────────────────────────
    $latestVersion = (curl.exe -s @curlProxy "$GCS_BUCKET/latest").Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($latestVersion)) {
        Write-Error "获取最新版本号失败"; exit 1
    }
    Write-Host "最新版本: $latestVersion"

    if ($currentVersion -eq $latestVersion) {
        Write-Host ""
        Write-Host "已是最新版本（$latestVersion），无需更新。"
        exit 0
    }
    if ($currentVersion) { Write-Host "需要更新: $currentVersion -> $latestVersion" }

    # ── 平台 & 下载目录 ────────────────────────────────────────────────────────
    $platform = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "win32-arm64" } else { "win32-x64" }
    $dlDir    = "$env:USERPROFILE\.claude\downloads"
    New-Item -ItemType Directory -Force -Path $dlDir | Out-Null
    Write-Host "下载目录: $dlDir"

    # ── 获取 manifest & checksum ──────────────────────────────────────────────
    Write-Host ""
    Write-Host "获取版本清单..."
    $manifestJson = curl.exe -s @curlProxy "$GCS_BUCKET/$latestVersion/manifest.json"
    if ($LASTEXITCODE -ne 0) { Write-Error "获取 manifest.json 失败"; exit 1 }
    $manifest  = $manifestJson | ConvertFrom-Json
    $platProp  = $manifest.platforms.PSObject.Properties[$platform]
    if (-not $platProp) { Write-Error "平台 $platform 未在 manifest 中找到"; exit 1 }
    $checksum  = $platProp.Value.checksum

    # ── 下载或复用缓存 ─────────────────────────────────────────────────────────
    $binaryPath  = "$dlDir\claude-$latestVersion-$platform.exe"
    $downloadUrl = "$GCS_BUCKET/$latestVersion/$platform/claude.exe"
    Get-ClaudeBinary -BinaryPath $binaryPath -DownloadUrl $downloadUrl `
        -Checksum $checksum -Label "claude.exe ($latestVersion / $platform)" `
        -Proxy $curlProxy

    # ── 清理残留备份并替换 ─────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "替换: $foundPath"
    Remove-OldBackups -BasePath $foundPath
    Replace-Binary -TargetPath $foundPath -SourcePath $binaryPath

    Write-Host ""
    $updatePrefix = if ($currentVersion) { "$currentVersion -> " } else { "" }
    Write-Host "更新完成：${updatePrefix}$latestVersion"
    Remove-Item -Force $binaryPath -ErrorAction SilentlyContinue

}
elseif ($Mode -eq "install") {
# ════ 安装模式 ════════════════════════════════════════════════════════════════

    # ── 平台 & 下载目录 ────────────────────────────────────────────────────────
    $platform = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "win32-arm64" } else { "win32-x64" }
    $dlDir    = "$env:USERPROFILE\.claude\downloads"
    New-Item -ItemType Directory -Force -Path $dlDir | Out-Null
    Write-Host "下载目录: $dlDir"

    # ── 获取最新版本号 ─────────────────────────────────────────────────────────
    $latestVersion = (curl.exe -s @curlProxy "$GCS_BUCKET/latest").Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($latestVersion)) {
        Write-Error "获取最新版本号失败"; exit 1
    }
    Write-Host "最新版本: $latestVersion"

    # ── 检查是否已安装 ─────────────────────────────────────────────────────────
    $existingPath   = $null
    $currentVersion = $null
    $claudeCmd = Get-Command claude.exe -ErrorAction SilentlyContinue
    if ($claudeCmd) {
        $foundPath = $claudeCmd.Source
        try {
            $versionOutput = & $foundPath --version 2>&1 | Out-String
            $versionMatch  = [regex]::Match($versionOutput, '(\d+\.\d+\.\d+\S*)')
            if ($versionMatch.Success) { $currentVersion = $versionMatch.Groups[1].Value }
        }
        catch {}

        $versionLabel = if ($currentVersion) { $currentVersion } else { "未知版本" }

        if ($foundPath -match '\\WinGet\\') {
            Write-Host "检测到 winget 安装版本（$versionLabel）"
            if ($currentVersion -eq $latestVersion) {
                Write-Host "已是最新版本（$latestVersion），无需操作。"
            }
            else {
                Write-Host "如需更新请使用 winget：  winget upgrade --id Anthropic.Claude"
            }
            exit 0
        }

        Write-Host "已安装位置: $foundPath"
        Write-Host "当前版本: $versionLabel"

        if ($currentVersion -eq $latestVersion) {
            Write-Host ""
            Write-Host "已是最新版本（$latestVersion），无需操作。"
            exit 0
        }

        $existingPath = $foundPath
        if ($currentVersion) { Write-Host "需要更新: $currentVersion -> $latestVersion" }
    }
    else {
        Write-Host "未检测到已安装的 claude.exe，将执行全新安装。"
    }

    # ── 获取 manifest & checksum ──────────────────────────────────────────────
    Write-Host ""
    Write-Host "获取版本清单..."
    $manifestJson = curl.exe -s @curlProxy "$GCS_BUCKET/$latestVersion/manifest.json"
    if ($LASTEXITCODE -ne 0) { Write-Error "获取 manifest.json 失败"; exit 1 }
    $manifest  = $manifestJson | ConvertFrom-Json
    $platProp  = $manifest.platforms.PSObject.Properties[$platform]
    if (-not $platProp) { Write-Error "平台 $platform 未在 manifest 中找到"; exit 1 }
    $checksum  = $platProp.Value.checksum

    # ── 下载或复用缓存 ─────────────────────────────────────────────────────────
    $binaryPath  = "$dlDir\claude-$latestVersion-$platform.exe"
    $downloadUrl = "$GCS_BUCKET/$latestVersion/$platform/claude.exe"
    Get-ClaudeBinary -BinaryPath $binaryPath -DownloadUrl $downloadUrl `
        -Checksum $checksum -Label "claude.exe ($latestVersion / $platform)" `
        -Proxy $curlProxy

    # ── 已安装：替换；未安装：运行 install 命令 ───────────────────────────────
    if ($existingPath) {
        Write-Host ""
        Write-Host "替换: $existingPath"
        Remove-OldBackups -BasePath $existingPath
        Replace-Binary -TargetPath $existingPath -SourcePath $binaryPath

        Write-Host ""
        $updatePrefix = if ($currentVersion) { "$currentVersion -> " } else { "" }
        Write-Host "更新完成：${updatePrefix}$latestVersion"
        Remove-Item -Force $binaryPath -ErrorAction SilentlyContinue
    }
    else {
        if ($curlProxy.Count -gt 0) {
            $env:HTTP_PROXY  = $proxyUri
            $env:HTTPS_PROXY = $proxyUri
        }
        Write-Host ""
        Write-Host "正在安装 Claude Code..."
        $installOk = $false
        try {
            if ($Target) { & $binaryPath install $Target } else { & $binaryPath install }
            if ($LASTEXITCODE -eq 0) { $installOk = $true }
        }
        catch {
            Write-Host "install 命令异常: $_"
        }

        if (-not $installOk) {
            $fallbackDir  = "$env:USERPROFILE\.local\bin"
            $fallbackPath = "$fallbackDir\claude.exe"
            Write-Host ""
            Write-Host "原生 install 命令失败，通过 copy 方式安装到 $fallbackPath"
            try {
                New-Item -ItemType Directory -Force -Path $fallbackDir | Out-Null
                Copy-Item -Force $binaryPath $fallbackPath
                Write-Host "复制完成。"
                Write-Host "请确认 $fallbackDir 已加入 PATH，否则请手动添加："
                Write-Host "  [Environment]::SetEnvironmentVariable('PATH', `$env:PATH + ';$fallbackDir', 'User')"
            }
            catch {
                Write-Error "回退复制也失败: $_"
            }
        }
        else {
            Write-Host ""
            Write-Host "安装完成：$latestVersion"
        }
        Start-Sleep -Seconds 1
        Remove-Item -Force $binaryPath -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "✅️完成！(如果存在已打开的 claude 终端，请重新打开使用)"
Write-Host ""

