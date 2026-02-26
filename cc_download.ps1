$ErrorActionPreference = "Stop"

# Interactive mode selection
$Mode = ""     # "" = download
$Target = ""
Write-Host ""
Write-Host "Select run mode:"
Write-Host "  1) download  Download offline package (default)"
Write-Host "  2) install    Claude Code"
Write-Host "  3) update     Update Claude Code"
Write-Host ""
$modeChoice = Read-Host "Enter choice [1/2/3]"
switch ($modeChoice) {
    "2" { $Mode = "install" }
    "3" { $Mode = "update" }
    default { $Mode = "" }
}

if ($Mode -eq "install") {
    Write-Host ""
    Write-Host "Select install target:"
    Write-Host "  1) default (no target, default channel)"
    Write-Host "  2) latest"
    Write-Host "  3) stable"
    Write-Host "  4) specific version (e.g. 1.0.33)"
    Write-Host ""
    $targetChoice = Read-Host "Enter choice [1/2/3/4]"
    switch ($targetChoice) {
        "2" { $Target = "latest" }
        "3" { $Target = "stable" }
        "4" {
            $Target = Read-Host "Enter version (e.g. 1.0.33)"
            if ($Target -notmatch '^\d+\.\d+\.\d+(-[^\s]+)?$') {
                Write-Error "Invalid version format (example: 1.0.33)"
                exit 1
            }
        }
        default { $Target = "" }
    }
}

# 32-bit check (install / update only)
if ($Mode -ne "" -and -not [Environment]::Is64BitProcess) {
    Write-Error "Claude Code does not support 32-bit Windows."
    exit 1
}

# Proxy selection
Write-Host ""
Write-Host "Select proxy type:"
Write-Host "  1) HTTP proxy (default)"
Write-Host "  2) No proxy"
Write-Host ""
$typeChoice = Read-Host "Enter choice [1/2]"

$curlProxy = @()
$proxyUri = ""
if ($typeChoice -ne "2") {
    $portInput = Read-Host "Enter proxy port [default: 7897]"
    if ([string]::IsNullOrWhiteSpace($portInput)) { $portInput = "7897" }
    $proxyUri = "http://127.0.0.1:$portInput"
    $curlProxy = @("--proxy", $proxyUri)
    Write-Host "Using proxy: $proxyUri"
}
else {
    Write-Host "Using direct connection (no proxy)."
}

# Resolve GCS_BUCKET dynamically from official install.ps1
Write-Host ""
Write-Host "Fetching latest install script..."
$installScript = curl.exe -s -L @curlProxy "https://claude.ai/install.ps1"
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to fetch install.ps1 (exit code $LASTEXITCODE)"
    exit 1
}

$bucketMatch = [regex]::Match($installScript, '\$GCS_BUCKET\s*=\s*"([^"]+)"')
if (-not $bucketMatch.Success) {
    $preview = if ($installScript.Length -gt 300) { $installScript.Substring(0, 300) } else { $installScript }
    Write-Host "---- install.ps1 preview ----"
    Write-Host $preview
    Write-Host "----------------------------------"
    Write-Error "Unable to parse GCS_BUCKET from install.ps1; script format may have changed"
    exit 1
}
$GCS_BUCKET = $bucketMatch.Groups[1].Value

# Download Claude binary (or reuse cached file)
function Get-ClaudeBinary {
    param(
        [string]   $BinaryPath,
        [string]   $DownloadUrl,
        [string]   $Checksum,
        [string]   $Label,
        [string[]] $Proxy
    )
    if (Test-Path $BinaryPath) {
        Write-Host "Found cached file, verifying checksum..."
        $cached = (Get-FileHash -Path $BinaryPath -Algorithm SHA256).Hash.ToLower()
        if ($cached -eq $Checksum) {
            Write-Host "Checksum OK, skip download."
            return
        }
        Write-Host "Cached file checksum mismatch, re-downloading..."
        Remove-Item -Force $BinaryPath
    }
    Write-Host "Downloading $Label..."
    Write-Host "URL: $DownloadUrl"
    curl.exe @Proxy --progress-bar -L -o $BinaryPath $DownloadUrl
    if ($LASTEXITCODE -ne 0) {
        if (Test-Path $BinaryPath) { Remove-Item -Force $BinaryPath }
        Write-Error "Download failed"; exit 1
    }
    Write-Host ""
    Write-Host "Verifying checksum..."
    $actual = (Get-FileHash -Path $BinaryPath -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $Checksum) {
        Remove-Item -Force $BinaryPath
        Write-Error "Checksum mismatch (expected: $Checksum  actual: $actual)"; exit 1
    }
    Write-Host "Checksum OK"
}

# Remove stale .old backup files
function Remove-OldBackups {
    param([string]$BasePath)
    $dir  = Split-Path $BasePath -Parent
    $name = Split-Path $BasePath -Leaf
    Get-ChildItem -Path $dir -Filter "$name.old" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $dir -Filter "$name.*.old" -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# Replace binary via move+copy (works even when old exe is running)
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
            Write-Host "Rolled back to previous version."
        }
        Write-Error "Replace failed: $_"; exit 1
    }
}

# ===== Main flow =====
if ($Mode -eq "") {
# ---- Download mode ----

    # Select target platform
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
    Write-Host "Select target platform:"
    foreach ($p in $platforms) {
        Write-Host ("  " + $p.Id + ") " + $p.Name.PadRight(22) + " " + $p.Label)
    }
    Write-Host ""
    $platformInput = Read-Host "Enter choice [1-8]"
    $platformId = 0
    if (-not [int]::TryParse($platformInput, [ref]$platformId)) {
        Write-Error "Please enter a number between 1 and 8"; exit 1
    }
    $selPlatform = $platforms | Where-Object { $_.Id -eq $platformId }
    if (-not $selPlatform) { Write-Error "Invalid selection"; exit 1 }

    # Select version channel
    Write-Host ""
    Write-Host "Select version channel:"
    Write-Host "  1) latest"
    Write-Host "  2) stable"
    Write-Host "  3) specific version"
    Write-Host ""
    $channelChoice = Read-Host "Enter choice [1/2/3]"
    $channel = ""
    switch ($channelChoice) {
        "2" { $channel = "stable" }
        "3" {
            $channel = Read-Host "Enter version (e.g. 1.0.33)"
            if ($channel -notmatch '^\d+\.\d+\.\d+') {
                Write-Error "Invalid version format"; exit 1
            }
        }
        default { $channel = "latest" }
    }

    # Resolve version number
    $version = ""
    if ($channel -match '^\d+\.\d+\.\d+') {
        $version = $channel
    }
    else {
        $version = (curl.exe -s @curlProxy "$GCS_BUCKET/$channel").Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($version)) {
            Write-Error "Failed to resolve version for channel: $channel"; exit 1
        }
    }
    Write-Host "Version: $version"

    # Fetch manifest and checksum
    Write-Host ""
    Write-Host "Fetching version manifest..."
    $manifestJson = curl.exe -s @curlProxy "$GCS_BUCKET/$version/manifest.json"
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to fetch manifest.json"; exit 1 }
    $manifest  = $manifestJson | ConvertFrom-Json
    $platProp  = $manifest.platforms.PSObject.Properties[$selPlatform.Name]
    if (-not $platProp) { Write-Error "Platform $($selPlatform.Name) not found in manifest"; exit 1 }
    $checksum  = $platProp.Value.checksum

    # Download/reuse cached binary in current directory
    $ext        = if ($selPlatform.IsWin) { ".exe" } else { "" }
    $remoteBin  = if ($selPlatform.IsWin) { "claude.exe" } else { "claude" }
    $binaryName = "claude-$version-$($selPlatform.Name)$ext"
    $outputPath = Join-Path (Get-Location) $binaryName
    $downloadUrl= "$GCS_BUCKET/$version/$($selPlatform.Name)/$remoteBin"
    Write-Host "Output directory: $(Get-Location)"
    Get-ClaudeBinary -BinaryPath $outputPath -DownloadUrl $downloadUrl `
        -Checksum $checksum -Label $binaryName -Proxy $curlProxy

    $fileSizeMB = [math]::Round((Get-Item $outputPath).Length / 1MB, 1)

    # Offline install hint
    Write-Host ""
    Write-Host "=============================================================="
    Write-Host "Downloaded file: $binaryName ($fileSizeMB MB)"
    Write-Host "Saved to:        $outputPath"
    Write-Host "=============================================================="
    Write-Host "Offline install instructions:"
    Write-Host ""
    if ($selPlatform.IsWin) {
        Write-Host "  1. Copy $binaryName to the target Windows machine"
        Write-Host "  2. Run in PowerShell:"
        Write-Host "        New-Item -ItemType Directory -Force `"`$env:USERPROFILE\.local\bin`""
        Write-Host "        Copy-Item .\$binaryName `"`$env:USERPROFILE\.local\bin\claude.exe`""
    }
    else {
        Write-Host "  1. Upload $binaryName to target host (for example: /tmp/)"
        Write-Host "  2. Copy into executable path:"
        Write-Host "        mkdir -p ~/.local/bin"
        Write-Host "        cp /tmp/$binaryName ~/.local/bin/claude"
        Write-Host "        chmod +x ~/.local/bin/claude"
    }
    Write-Host ""
    Write-Host "=============================================================="

}
elseif ($Mode -eq "update") {
# ---- Update mode ----

    # Check installed claude
    $claudeCmd = Get-Command claude.exe -ErrorAction SilentlyContinue
    if (-not $claudeCmd) {
        Write-Error "No installed claude.exe found. Re-run script and choose install mode."
        exit 1
    }

    $foundPath = $claudeCmd.Source
    if ($foundPath -match '\\WinGet\\') {
        Write-Host "Detected winget-managed install. Please update with:"
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

    Write-Host "Installed path: $foundPath"
    Write-Host "Current version: $(if ($currentVersion) { $currentVersion } else { 'unknown' })"

    # Get latest version
    $latestVersion = (curl.exe -s @curlProxy "$GCS_BUCKET/latest").Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($latestVersion)) {
        Write-Error "Failed to fetch latest version"; exit 1
    }
    Write-Host "Latest version: $latestVersion"

    if ($currentVersion -eq $latestVersion) {
        Write-Host "Already up to date ($latestVersion)."
        exit 0
    }
    if ($currentVersion) { Write-Host "Update needed: $currentVersion -> $latestVersion" }

    # Platform and download directory
    $platform = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "win32-arm64" } else { "win32-x64" }
    $dlDir    = "$env:USERPROFILE\.claude\downloads"
    New-Item -ItemType Directory -Force -Path $dlDir | Out-Null
    Write-Host "Download directory: $dlDir"

    # Fetch manifest and checksum
    Write-Host ""
    Write-Host "Fetching version manifest..."
    $manifestJson = curl.exe -s @curlProxy "$GCS_BUCKET/$latestVersion/manifest.json"
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to fetch manifest.json"; exit 1 }
    $manifest  = $manifestJson | ConvertFrom-Json
    $platProp  = $manifest.platforms.PSObject.Properties[$platform]
    if (-not $platProp) { Write-Error "Platform $platform not found in manifest"; exit 1 }
    $checksum  = $platProp.Value.checksum

    # Download/reuse cached binary
    $binaryPath  = "$dlDir\claude-$latestVersion-$platform.exe"
    $downloadUrl = "$GCS_BUCKET/$latestVersion/$platform/claude.exe"
    Get-ClaudeBinary -BinaryPath $binaryPath -DownloadUrl $downloadUrl `
        -Checksum $checksum -Label "claude.exe ($latestVersion / $platform)" `
        -Proxy $curlProxy

    # Replace existing binary
    Write-Host ""
    Write-Host "Replacing: $foundPath"
    Remove-OldBackups -BasePath $foundPath
    Replace-Binary -TargetPath $foundPath -SourcePath $binaryPath

    Write-Host ""
    $updatePrefix = if ($currentVersion) { "$currentVersion -> " } else { "" }
    Write-Host "Update complete: ${updatePrefix}$latestVersion"
    Remove-Item -Force $binaryPath -ErrorAction SilentlyContinue

}
elseif ($Mode -eq "install") {
# ---- Install mode ----

    # Platform and download directory
    $platform = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "win32-arm64" } else { "win32-x64" }
    $dlDir    = "$env:USERPROFILE\.claude\downloads"
    New-Item -ItemType Directory -Force -Path $dlDir | Out-Null
    Write-Host "Download directory: $dlDir"

    # Get latest version
    $latestVersion = (curl.exe -s @curlProxy "$GCS_BUCKET/latest").Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($latestVersion)) {
        Write-Error "Failed to fetch latest version"; exit 1
    }
    Write-Host "Latest version: $latestVersion"

    # Check existing install
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

        $versionLabel = if ($currentVersion) { $currentVersion } else { "" }

        if ($foundPath -match '\\WinGet\\') {
            Write-Host "Detected winget-managed install ($versionLabel)"
            if ($currentVersion -eq $latestVersion) {
                Write-Host "Already up to date ($latestVersion)."
            }
            else {
                Write-Host "Use winget to update: winget upgrade --id Anthropic.Claude"
            }
            exit 0
        }

        Write-Host "Installed path: $foundPath"
        Write-Host "Current version: $versionLabel"

        if ($currentVersion -eq $latestVersion) {
            Write-Host "Already up to date ($latestVersion)."
            exit 0
        }

        $existingPath = $foundPath
        if ($currentVersion) { Write-Host "Update needed: $currentVersion -> $latestVersion" }
    }
    else {
        Write-Host "No existing claude.exe found, fresh install will be performed."
    }

    # Fetch manifest and checksum
    Write-Host ""
    Write-Host "Fetching version manifest..."
    $manifestJson = curl.exe -s @curlProxy "$GCS_BUCKET/$latestVersion/manifest.json"
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to fetch manifest.json"; exit 1 }
    $manifest  = $manifestJson | ConvertFrom-Json
    $platProp  = $manifest.platforms.PSObject.Properties[$platform]
    if (-not $platProp) { Write-Error "Platform $platform not found in manifest"; exit 1 }
    $checksum  = $platProp.Value.checksum

    # Download/reuse cached binary
    $binaryPath  = "$dlDir\claude-$latestVersion-$platform.exe"
    $downloadUrl = "$GCS_BUCKET/$latestVersion/$platform/claude.exe"
    Get-ClaudeBinary -BinaryPath $binaryPath -DownloadUrl $downloadUrl `
        -Checksum $checksum -Label "claude.exe ($latestVersion / $platform)" `
        -Proxy $curlProxy

    # Installed: replace in place; not installed: run install command
    if ($existingPath) {
        Write-Host ""
        Write-Host "Replacing: $existingPath"
        Remove-OldBackups -BasePath $existingPath
        Replace-Binary -TargetPath $existingPath -SourcePath $binaryPath

        Write-Host ""
        $updatePrefix = if ($currentVersion) { "$currentVersion -> " } else { "" }
        Write-Host "Update complete: ${updatePrefix}$latestVersion"
        Remove-Item -Force $binaryPath -ErrorAction SilentlyContinue
    }
    else {
        if ($curlProxy.Count -gt 0) {
            $env:HTTP_PROXY  = $proxyUri
            $env:HTTPS_PROXY = $proxyUri
        }
        Write-Host ""
        Write-Host "Installing Claude Code..."
        $installOk = $false
        try {
            if ($Target) { & $binaryPath install $Target } else { & $binaryPath install }
            if ($LASTEXITCODE -eq 0) { $installOk = $true }
        }
        catch {
            Write-Host "Native install command error: $_"
        }

        if (-not $installOk) {
            $fallbackDir  = "$env:USERPROFILE\.local\bin"
            $fallbackPath = "$fallbackDir\claude.exe"
            Write-Host ""
            Write-Host "Native install failed; fallback copy to $fallbackPath"
            try {
                New-Item -ItemType Directory -Force -Path $fallbackDir | Out-Null
                Copy-Item -Force $binaryPath $fallbackPath
                Write-Host "Copy complete."
                Write-Host "Ensure $fallbackDir is in PATH, or run:"
                Write-Host "  [Environment]::SetEnvironmentVariable('PATH', `$env:PATH + ';$fallbackDir', 'User')"
            }
            catch {
                Write-Error "Fallback copy also failed: $_"
            }
        }
        else {
            Write-Host "Install complete: $latestVersion"
        }
        Start-Sleep -Seconds 1
        Remove-Item -Force $binaryPath -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "Done! (If a Claude terminal is open, reopen it before use.)"
Write-Host ""
