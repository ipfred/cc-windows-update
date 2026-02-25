#!/bin/bash

set -e

# ── 参数解析 ──────────────────────────────────────────────────────────────────
MODE="${1:-}"      # "" = 下载离线包 | install | update
TARGET="${2:-}"    # stable | latest | x.y.z  （install 模式可用）

print_usage() {
    echo "用法: $0 [install|update] [stable|latest|VERSION]"
    echo ""
    echo "  （无参数）           下载离线安装包到当前目录（支持跨平台）"
    echo "  install              安装 Claude Code 到当前系统"
    echo "  install stable       安装 stable 通道"
    echo "  install 1.0.33       安装指定版本"
    echo "  update               更新已安装的 Claude Code 到最新版本"
}

case "$MODE" in
    ""|install|update) ;;
    -h|--help) print_usage; exit 0 ;;
    *) echo "无效命令: $MODE" >&2; echo "" >&2; print_usage >&2; exit 1 ;;
esac

if [[ -n "$TARGET" ]] && [[ "$MODE" == "install" ]] && \
   [[ ! "$TARGET" =~ ^(stable|latest|[0-9]+\.[0-9]+\.[0-9]+(-[^[:space:]]+)?)$ ]]; then
    echo "Target 必须是 stable、latest 或版本号（如 1.0.33）" >&2
    exit 1
fi

# ── 代理选择 ──────────────────────────────────────────────────────────────────
echo ""
echo "请选择代理类型："
echo "  1) HTTP 代理（默认）"
echo "  2) 不使用代理"
echo ""
read -r -p "输入选项 [1/2]: " type_choice

PROXY_URL=""
CURL_PROXY_ARGS=()

if [[ "$type_choice" != "2" ]]; then
    read -r -p "输入代理端口 [默认: 7897]: " port_input
    port_input="${port_input:-7897}"
    PROXY_URL="http://127.0.0.1:$port_input"
    CURL_PROXY_ARGS=(--proxy "$PROXY_URL")
    export http_proxy="$PROXY_URL" https_proxy="$PROXY_URL"
    export HTTP_PROXY="$PROXY_URL" HTTPS_PROXY="$PROXY_URL"
    echo "使用代理: $PROXY_URL"
else
    echo "不使用代理，直接连接。"
fi

# ── 检测下载工具 ──────────────────────────────────────────────────────────────
DOWNLOADER=""
if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
else
    echo "需要 curl 或 wget，但均未安装" >&2; exit 1
fi

HAS_JQ=false
command -v jq >/dev/null 2>&1 && HAS_JQ=true

# ── 下载函数（静默，输出到 stdout）───────────────────────────────────────────
download_quiet() {
    if [ "$DOWNLOADER" = "curl" ]; then
        curl -fsSL "${CURL_PROXY_ARGS[@]}" "$1"
    else
        wget -q -O - "$1"
    fi
}

# ── 下载函数（带进度条，写入文件）────────────────────────────────────────────
download_with_progress() {
    local url="$1" output="$2"
    if [ "$DOWNLOADER" = "curl" ]; then
        curl -fL --progress-bar "${CURL_PROXY_ARGS[@]}" -o "$output" "$url"
    else
        wget --progress=bar:force -O "$output" "$url"
    fi
}

# ── SHA256 校验（依宿主 OS 选择工具）─────────────────────────────────────────
sha256_file() {
    case "$(uname -s)" in
        Darwin) shasum -a 256 "$1" | cut -d' ' -f1 ;;
        *)      sha256sum "$1" | cut -d' ' -f1 ;;
    esac
}

# ── 简单 JSON 解析（jq 不存在时）─────────────────────────────────────────────
get_checksum_from_manifest() {
    local json platform
    json=$(echo "$1" | tr -d '\n\r\t' | sed 's/ \+/ /g')
    platform="$2"
    if [[ $json =~ \"$platform\"[^}]*\"checksum\"[[:space:]]*:[[:space:]]*\"([a-f0-9]{64})\" ]]; then
        echo "${BASH_REMATCH[1]}"; return 0
    fi
    return 1
}

# ── 检测 manifest checksum（通用）────────────────────────────────────────────
fetch_checksum() {
    local manifest_json="$1" plat="$2" cs
    if [ "$HAS_JQ" = true ]; then
        cs=$(echo "$manifest_json" | jq -r ".platforms[\"$plat\"].checksum // empty")
    else
        cs=$(get_checksum_from_manifest "$manifest_json" "$plat")
    fi
    if [ -z "$cs" ] || [[ ! "$cs" =~ ^[a-f0-9]{64}$ ]]; then
        echo "平台 $plat 未在 manifest 中找到" >&2; exit 1
    fi
    echo "$cs"
}

# ── 下载或复用已缓存的 claude 二进制 ──────────────────────────────────────────
ensure_binary() {
    local binary_path="$1" download_url="$2" checksum="$3" label="$4"
    if [ -f "$binary_path" ]; then
        echo "发现已缓存文件，校验中..."
        local cached
        cached=$(sha256_file "$binary_path")
        if [ "$cached" = "$checksum" ]; then
            echo "校验通过，跳过下载。"
            return 0
        fi
        echo "缓存文件校验不匹配，重新下载..."
        rm -f "$binary_path"
    fi
    echo "下载 $label..."
    echo "下载地址: $download_url"
    if ! download_with_progress "$download_url" "$binary_path"; then
        rm -f "$binary_path"; echo "下载失败" >&2; return 1
    fi
    echo ""
    echo "校验文件完整性..."
    local actual
    actual=$(sha256_file "$binary_path")
    if [ "$actual" != "$checksum" ]; then
        rm -f "$binary_path"
        echo "校验失败（期望: $checksum  实际: $actual）" >&2; return 1
    fi
    echo "校验通过"
}

# ── 检测当前平台（官方逻辑）──────────────────────────────────────────────────
detect_platform() {
    local os arch platform
    case "$(uname -s)" in
        Darwin) os="darwin" ;;
        Linux)  os="linux"  ;;
        *) echo "不支持的操作系统: $(uname -s)" >&2; exit 1 ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)  arch="x64"   ;;
        arm64|aarch64) arch="arm64" ;;
        *) echo "不支持的架构: $(uname -m)" >&2; exit 1 ;;
    esac
    # macOS Rosetta 2
    if [ "$os" = "darwin" ] && [ "$arch" = "x64" ]; then
        [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = "1" ] && arch="arm64"
    fi
    # Linux musl
    if [ "$os" = "linux" ]; then
        if [ -f /lib/libc.musl-x86_64.so.1 ] || [ -f /lib/libc.musl-aarch64.so.1 ] || \
           ldd /bin/ls 2>&1 | grep -q musl; then
            platform="linux-${arch}-musl"
        else
            platform="linux-${arch}"
        fi
    else
        platform="${os}-${arch}"
    fi
    echo "$platform"
}

# ── 从官方 install.sh 动态解析 GCS_BUCKET ────────────────────────────────────
echo ""
echo "获取最新安装脚本..."
install_script=$(download_quiet "https://claude.ai/install.sh")

GCS_BUCKET=""
[[ "$install_script" =~ GCS_BUCKET=\"([^\"]+)\" ]] && GCS_BUCKET="${BASH_REMATCH[1]}"

if [[ -z "$GCS_BUCKET" ]]; then
    echo "---- install.sh 内容预览 ----"
    echo "${install_script:0:300}"
    echo "-----------------------------"
    echo "无法解析 GCS_BUCKET，脚本格式可能已变更" >&2; exit 1
fi

# ════════════════════════════════════════════════════════════════════════════════
if [[ -z "$MODE" ]]; then
# ════ 下载模式（无参数）══════════════════════════════════════════════════════

    # ── 选择目标平台 ──────────────────────────────────────────────────────────
    echo ""
    echo "选择目标平台："
    echo "  1) linux-x64          Linux x64 (glibc)"
    echo "  2) linux-arm64        Linux ARM64 (glibc)"
    echo "  3) linux-x64-musl     Linux x64 (musl/Alpine)"
    echo "  4) linux-arm64-musl   Linux ARM64 (musl/Alpine)"
    echo "  5) darwin-x64         macOS x64 (Intel)"
    echo "  6) darwin-arm64       macOS ARM64 (Apple Silicon)"
    echo "  7) win32-x64          Windows x64"
    echo "  8) win32-arm64        Windows ARM64"
    echo ""
    read -r -p "输入选项 [1-8]: " platform_choice

    IS_WIN=false
    case "$platform_choice" in
        1) PLATFORM="linux-x64"        ;;
        2) PLATFORM="linux-arm64"      ;;
        3) PLATFORM="linux-x64-musl"   ;;
        4) PLATFORM="linux-arm64-musl" ;;
        5) PLATFORM="darwin-x64"       ;;
        6) PLATFORM="darwin-arm64"     ;;
        7) PLATFORM="win32-x64";   IS_WIN=true ;;
        8) PLATFORM="win32-arm64"; IS_WIN=true ;;
        *) echo "无效的选项" >&2; exit 1 ;;
    esac

    # ── 选择版本通道 ───────────────────────────────────────────────────────────
    echo ""
    echo "选择版本通道："
    echo "  1) latest（最新版，默认）"
    echo "  2) stable（稳定版）"
    echo "  3) 输入指定版本号"
    echo ""
    read -r -p "输入选项 [1/2/3]: " channel_choice
    channel=""
    case "$channel_choice" in
        2) channel="stable" ;;
        3)
            read -r -p "输入版本号（如 1.0.33）: " channel
            [[ ! "$channel" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] && \
                { echo "版本号格式不正确" >&2; exit 1; }
            ;;
        *) channel="latest" ;;
    esac

    # ── 解析版本号 ─────────────────────────────────────────────────────────────
    if [[ "$channel" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        VERSION="$channel"
    else
        VERSION=$(download_quiet "$GCS_BUCKET/$channel" | tr -d '[:space:]')
        [[ -z "$VERSION" ]] && { echo "获取 $channel 版本号失败" >&2; exit 1; }
    fi
    echo "版本: $VERSION"

    # ── 获取 manifest & checksum ──────────────────────────────────────────────
    echo ""
    echo "获取版本清单..."
    manifest_json=$(download_quiet "$GCS_BUCKET/$VERSION/manifest.json")
    [[ -z "$manifest_json" ]] && { echo "获取 manifest.json 失败" >&2; exit 1; }
    checksum=$(fetch_checksum "$manifest_json" "$PLATFORM")

    # ── 下载或复用缓存（当前目录）─────────────────────────────────────────────
    EXT=""; REMOTE_BIN="claude"
    [ "$IS_WIN" = "true" ] && { EXT=".exe"; REMOTE_BIN="claude.exe"; }

    binary_name="claude-$VERSION-$PLATFORM$EXT"
    output_path="$(pwd)/$binary_name"
    download_url="$GCS_BUCKET/$VERSION/$PLATFORM/$REMOTE_BIN"
    echo "保存目录: $(pwd)"
    ensure_binary "$output_path" "$download_url" "$checksum" "$binary_name" || exit 1
    [ "$IS_WIN" = "false" ] && chmod +x "$output_path"

    file_size_kb=$(( $(wc -c < "$output_path") / 1024 ))

    # ── 离线安装提示 ───────────────────────────────────────────────────────────
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo " 文件已下载: $binary_name  (${file_size_kb} KB)"
    echo " 保存位置:   $output_path"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo " 离线安装方法："
    echo ""
    if [ "$IS_WIN" = "true" ]; then
        echo "   1. 将 $binary_name 复制到目标 Windows 机器"
        echo "   2. 在 PowerShell 或 CMD 中运行："
        echo "        .\\$binary_name install"
        echo ""
        echo "   可选：指定通道"
        echo "        .\\$binary_name install stable"
        echo "        .\\$binary_name install latest"
    else
        echo "   1. 将 $binary_name 上传到目标服务器（如 /tmp/）"
        echo "   2. 授予执行权限并安装："
        echo "        chmod +x /tmp/$binary_name && /tmp/$binary_name install"
        echo ""
        echo "   可选：指定通道"
        echo "        /tmp/$binary_name install stable"
        echo "        /tmp/$binary_name install latest"
    fi
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

elif [[ "$MODE" == "update" ]]; then
# ════ 更新模式 ════════════════════════════════════════════════════════════════

    # ── 检查已安装的 claude ────────────────────────────────────────────────────
    if ! command -v claude >/dev/null 2>&1; then
        echo "未找到已安装的 claude，请先运行: bash $0 install" >&2; exit 1
    fi

    found_path=$(command -v claude)
    current_version=""
    version_output=$(claude --version 2>&1 || true)
    [[ "$version_output" =~ ([0-9]+\.[0-9]+\.[0-9]+[^[:space:]]*) ]] && \
        current_version="${BASH_REMATCH[1]}"

    echo "已安装位置: $found_path"
    echo "当前版本: ${current_version:-未知}"

    # ── 获取最新版本号 ─────────────────────────────────────────────────────────
    latest_version=$(download_quiet "$GCS_BUCKET/latest" | tr -d '[:space:]')
    [[ -z "$latest_version" ]] && { echo "获取最新版本号失败" >&2; exit 1; }
    echo "最新版本: $latest_version"

    if [[ "$current_version" == "$latest_version" ]]; then
        echo ""
        echo "已是最新版本（$latest_version），无需更新。"
        exit 0
    fi
    [[ -n "$current_version" ]] && echo "需要更新: $current_version -> $latest_version"

    # ── 检测平台 & 下载目录 ────────────────────────────────────────────────────
    platform=$(detect_platform)
    DOWNLOAD_DIR="$HOME/.claude/downloads"
    mkdir -p "$DOWNLOAD_DIR"
    echo "下载目录: $DOWNLOAD_DIR"

    # ── 获取 manifest & checksum ──────────────────────────────────────────────
    echo ""
    echo "获取版本清单..."
    manifest_json=$(download_quiet "$GCS_BUCKET/$latest_version/manifest.json")
    [[ -z "$manifest_json" ]] && { echo "获取 manifest.json 失败" >&2; exit 1; }
    checksum=$(fetch_checksum "$manifest_json" "$platform")

    # ── 下载或复用缓存 ─────────────────────────────────────────────────────────
    binary_path="$DOWNLOAD_DIR/claude-$latest_version-$platform"
    download_url="$GCS_BUCKET/$latest_version/$platform/claude"
    ensure_binary "$binary_path" "$download_url" "$checksum" \
                  "claude ($latest_version / $platform)" || exit 1
    chmod +x "$binary_path"

    # ── 替换二进制 ─────────────────────────────────────────────────────────────
    # 直接 cp -f 覆写正在运行的文件会触发 ETXTBSY（Text file busy）。
    # Unix 允许对运行中的文件重命名（mv 只改目录项，不动 inode），
    # 策略：先 mv 旧文件腾出路径，再 cp 写入新文件。
    echo ""
    echo "替换: $found_path"
    bak_path="${found_path}.old"
    rm -f "$bak_path" 2>/dev/null || true
    if ! mv "$found_path" "$bak_path"; then
        echo "重命名旧文件失败" >&2; exit 1
    fi
    if cp -f "$binary_path" "$found_path"; then
        # 尝试清理备份（进程仍在运行则删除失败，下次更新时再清理，不影响结果）
        rm -f "$bak_path" 2>/dev/null || true
    else
        # 复制失败，回滚
        mv "$bak_path" "$found_path"
        echo "替换失败，已回滚到旧版本。" >&2; exit 1
    fi
    echo ""
    echo "更新完成：${current_version:+$current_version -> }$latest_version"

elif [[ "$MODE" == "install" ]]; then
# ════ 安装模式 ════════════════════════════════════════════════════════════════

    # ── 检测平台 & 下载目录 ────────────────────────────────────────────────────
    platform=$(detect_platform)
    DOWNLOAD_DIR="$HOME/.claude/downloads"
    mkdir -p "$DOWNLOAD_DIR"
    echo "下载目录: $DOWNLOAD_DIR"

    # ── 获取最新版本号 ─────────────────────────────────────────────────────────
    latest_version=$(download_quiet "$GCS_BUCKET/latest" | tr -d '[:space:]')
    [[ -z "$latest_version" ]] && { echo "获取最新版本号失败" >&2; exit 1; }
    echo "最新版本: $latest_version"

    # ── 获取 manifest & checksum ──────────────────────────────────────────────
    echo ""
    echo "获取版本清单..."
    manifest_json=$(download_quiet "$GCS_BUCKET/$latest_version/manifest.json")
    [[ -z "$manifest_json" ]] && { echo "获取 manifest.json 失败" >&2; exit 1; }
    checksum=$(fetch_checksum "$manifest_json" "$platform")

    # ── 下载或复用缓存 ─────────────────────────────────────────────────────────
    binary_path="$DOWNLOAD_DIR/claude-$latest_version-$platform"
    download_url="$GCS_BUCKET/$latest_version/$platform/claude"
    ensure_binary "$binary_path" "$download_url" "$checksum" \
                  "claude ($latest_version / $platform)" || exit 1
    chmod +x "$binary_path"

    # ── 运行官方 install 命令 ──────────────────────────────────────────────────
    echo ""
    echo "正在安装 Claude Code..."
    install_ok=false
    if "$binary_path" install ${TARGET:+"$TARGET"}; then
        install_ok=true
    fi

    if [ "$install_ok" != "true" ]; then
        # 回退：复制到 ~/.local/bin
        fallback_dir="$HOME/.local/bin"
        fallback_path="$fallback_dir/claude"
        echo ""
        echo "install 命令失败，回退安装到 $fallback_path"
        mkdir -p "$fallback_dir"
        if cp -f "$binary_path" "$fallback_path"; then
            echo "复制完成。"
            echo "请确认 $fallback_dir 已加入 PATH，否则请手动添加："
            echo "  export PATH=\"\$PATH:$fallback_dir\""
        else
            echo "回退复制也失败" >&2
        fi
    else
        echo ""
        echo "安装完成：$latest_version"
    fi

    # rm -f "$binary_path"
fi

echo ""
echo "✅ 完成！"
echo ""
