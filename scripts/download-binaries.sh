#!/usr/bin/env bash
# 自动下载最新版 docker-compose、minio client (mc)、kubectl 二进制文件

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TULAN_HOME="$(cd "${SCRIPT_DIR}/.." && pwd)"

INSTALL_DIR="${TULAN_TOOLS_HOME:-${TULAN_HOME}}/bin"
TOOLS="all"
DRY_RUN=false
VERIFY_CHECKSUM=true

usage() {
  cat <<EOF
自动下载最新二进制: docker-compose, minio client (mc), kubectl

用法:
  ./scripts/download-binaries.sh [选项]

选项:
  --install-dir DIR   安装目录，默认 \${TULAN_TOOLS_HOME}/bin
  --tool NAME         仅下载指定工具: compose | mc | kubectl | all
  --no-verify         跳过 SHA256 校验
  --dry-run           仅显示下载信息，不实际下载
  -h, --help          显示帮助

示例:
  ./scripts/download-binaries.sh
  ./scripts/download-binaries.sh --tool kubectl --install-dir ~/.local/bin
  ./scripts/download-binaries.sh --tool mc
EOF
}

log()  { echo "[download] $*"; }
err()  { echo "[download] 错误: $*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --tool) TOOLS="$2"; shift 2 ;;
    --no-verify) VERIFY_CHECKSUM=false; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "未知参数: $1"; usage; exit 1 ;;
  esac
done

# 检测操作系统: linux | darwin
detect_platform() {
  local os
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$os" in
    linux) echo "linux" ;;
    darwin) echo "darwin" ;;
    *) err "不支持的操作系统: $os"; exit 1 ;;
  esac
}

# 检测架构: amd64 | arm64
detect_arch() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) err "不支持的架构: $arch"; exit 1 ;;
  esac
}

# 从 GitHub releases/latest 获取版本号
github_latest_version() {
  local repo="$1"
  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
    | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4
}

# 下载文件，可选校验 SHA256
download_file() {
  local url="$1"
  local dest="$2"
  local checksum_url="${3:-}"

  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] $url -> $dest"
    return 0
  fi

  mkdir -p "$(dirname "$dest")"
  curl -fsSL "$url" -o "${dest}.tmp"

  if [[ "$VERIFY_CHECKSUM" == true ]] && [[ -n "$checksum_url" ]]; then
    local expected actual checksum_content
    checksum_content="$(curl -fsSL "$checksum_url")"
    # 兼容 "hash  filename" 和纯 hash 两种格式
    expected="$(echo "$checksum_content" | awk '{print $1}')"
    if command -v sha256sum &>/dev/null; then
      actual="$(sha256sum "${dest}.tmp" | awk '{print $1}')"
    elif command -v shasum &>/dev/null; then
      actual="$(shasum -a 256 "${dest}.tmp" | awk '{print $1}')"
    else
      log "警告: 未找到 sha256sum/shasum，跳过校验"
      expected=""
    fi
    if [[ -n "$expected" ]] && [[ "$expected" != "$actual" ]]; then
      rm -f "${dest}.tmp"
      err "SHA256 校验失败: $dest"
      err "  期望: $expected"
      err "  实际: $actual"
      exit 1
    fi
    log "SHA256 校验通过"
  fi

  mv "${dest}.tmp" "$dest"
  chmod +x "$dest"
  log "已安装: $dest"
}

# docker-compose 平台后缀映射
compose_platform_suffix() {
  local platform="$1" arch="$2"
  case "${platform}-${arch}" in
    linux-amd64)   echo "linux-x86_64" ;;
    linux-arm64)   echo "linux-aarch64" ;;
    darwin-amd64)  echo "darwin-x86_64" ;;
    darwin-arm64)  echo "darwin-aarch64" ;;
    *) err "docker-compose 不支持: ${platform}/${arch}"; exit 1 ;;
  esac
}

download_compose() {
  local platform arch suffix version url checksum_url
  platform="$(detect_platform)"
  arch="$(detect_arch)"
  suffix="$(compose_platform_suffix "$platform" "$arch")"

  log "获取 docker-compose 最新版本..."
  version="$(github_latest_version "docker/compose")"
  [[ -n "$version" ]] || { err "无法获取 docker-compose 版本"; exit 1; }

  url="https://github.com/docker/compose/releases/download/${version}/docker-compose-${suffix}"
  checksum_url="https://github.com/docker/compose/releases/download/${version}/docker-compose-${suffix}.sha256"
  log "docker-compose ${version} (${platform}/${arch})"

  download_file "$url" "${INSTALL_DIR}/docker-compose" "$checksum_url"
}

# mc 平台后缀映射
mc_platform_suffix() {
  local platform="$1" arch="$2"
  case "${platform}-${arch}" in
    linux-amd64)   echo "linux-amd64" ;;
    linux-arm64)   echo "linux-arm64" ;;
    darwin-amd64)  echo "darwin-amd64" ;;
    darwin-arm64)  echo "darwin-arm64" ;;
    *) err "minio client 不支持: ${platform}/${arch}"; exit 1 ;;
  esac
}

download_mc() {
  local platform arch suffix version asset_name url checksum_url
  platform="$(detect_platform)"
  arch="$(detect_arch)"
  suffix="$(mc_platform_suffix "$platform" "$arch")"

  log "获取 minio client (mc) 最新版本..."
  version="$(github_latest_version "minio/mc")"
  [[ -n "$version" ]] || { err "无法获取 mc 版本"; exit 1; }

  # 新版命名: mc.linux-amd64.RELEASE.2025-08-13T08-35-41Z
  asset_name="mc.${suffix}.${version}"
  url="https://github.com/minio/mc/releases/download/${version}/${asset_name}"
  checksum_url="https://github.com/minio/mc/releases/download/${version}/${asset_name}.sha256sum"
  log "mc ${version} (${platform}/${arch})"

  download_file "$url" "${INSTALL_DIR}/mc" "$checksum_url"
}

download_kubectl() {
  local platform arch version base_url url checksum_url
  platform="$(detect_platform)"
  arch="$(detect_arch)"

  log "获取 kubectl 最新版本..."
  version="$(curl -fsSL "https://dl.k8s.io/release/stable.txt")"
  [[ -n "$version" ]] || { err "无法获取 kubectl 版本"; exit 1; }

  base_url="https://dl.k8s.io/release/${version}/bin/${platform}/${arch}"
  url="${base_url}/kubectl"
  checksum_url="${base_url}/kubectl.sha256"

  log "kubectl ${version} (${platform}/${arch})"

  download_file "$url" "${INSTALL_DIR}/kubectl" "$checksum_url"
}

main() {
  if ! command -v curl &>/dev/null; then
    err "需要 curl，请先安装"
    exit 1
  fi

  local platform arch
  platform="$(detect_platform)"
  arch="$(detect_arch)"

  log "平台: ${platform}/${arch}"
  log "安装目录: ${INSTALL_DIR}"
  echo ""

  case "$TOOLS" in
    compose|docker-compose)
      download_compose
      ;;
    mc|minio)
      download_mc
      ;;
    kubectl|k8s)
      download_kubectl
      ;;
    all)
      download_compose
      echo ""
      download_mc
      echo ""
      download_kubectl
      ;;
    *)
      err "未知工具: ${TOOLS}（可选: compose, mc, kubectl, all）"
      exit 1
      ;;
  esac

  echo ""
  if [[ "$DRY_RUN" == false ]]; then
    log "全部完成！确保 ${INSTALL_DIR} 在 PATH 中:"
    echo "  export PATH=\"${INSTALL_DIR}:\$PATH\""
  fi
}

main "$@"
