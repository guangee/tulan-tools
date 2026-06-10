#!/usr/bin/env bash
# 下载二进制工具
# 默认从 GitHub bin 分支公开链接下载（无需 git-lfs）
# 也可从上游官方源直接下载（--source upstream）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TULAN_HOME="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${TULAN_HOME}/lib/common.sh"
# shellcheck source=../lib/binaries.sh
source "${TULAN_HOME}/lib/binaries.sh"

INSTALL_DIR="${TULAN_TOOLS_HOME:-${TULAN_HOME}}/bin"
TOOLS="all"
SOURCE="github"
DRY_RUN=false
VERIFY_CHECKSUM=true

usage() {
  cat <<EOF
下载二进制: docker-compose, minio client (mc), kubectl

用法:
  ./scripts/download-binaries.sh [选项]

选项:
  --source SRC        下载源: github（默认）| upstream
  --install-dir DIR   安装目录，默认 \${TULAN_TOOLS_HOME}/bin
  --tool NAME         仅下载: compose | mc | kubectl | all
  --no-verify         跳过 SHA256 校验
  --dry-run           仅显示信息
  -h, --help          显示帮助

GitHub 模式（默认，无需 git-lfs）:
  读取 config/binaries.manifest.json 中的文件路径，
  通过 media.githubusercontent.com 公开链接直接下载。

  环境变量:
    TULAN_GITHUB_REPO     仓库地址，如 yourname/tulan-tools
    TULAN_MANIFEST_URL    远程 manifest 地址（覆盖本地文件）

示例:
  ./scripts/download-binaries.sh
  ./scripts/download-binaries.sh --tool kubectl
  TULAN_GITHUB_REPO=yourname/tulan-tools ./scripts/download-binaries.sh
  ./scripts/download-binaries.sh --source upstream
EOF
}

log()  { echo "[download] $*"; }
err()  { echo "[download] 错误: $*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) SOURCE="$2"; shift 2 ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --tool) TOOLS="$2"; shift 2 ;;
    --no-verify) VERIFY_CHECKSUM=false; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "未知参数: $1"; usage; exit 1 ;;
  esac
done

detect_platform() {
  uname -s | tr '[:upper:]' '[:lower:]'
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) err "不支持的架构: $(uname -m)"; exit 1 ;;
  esac
}

github_latest_version() {
  curl -fsSL "https://api.github.com/repos/$1/releases/latest" \
    | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4
}

download_file() {
  local url="$1" dest="$2" checksum_url="${3:-}"

  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] $url -> $dest"
    return 0
  fi

  mkdir -p "$(dirname "$dest")"
  curl -fsSL "$url" -o "${dest}.tmp"

  if [[ "$VERIFY_CHECKSUM" == true ]] && [[ -n "$checksum_url" ]]; then
    local expected actual
    expected="$(curl -fsSL "$checksum_url" | awk '{print $1}')"
    if command -v sha256sum &>/dev/null; then
      actual="$(sha256sum "${dest}.tmp" | awk '{print $1}')"
    else
      actual="$(shasum -a 256 "${dest}.tmp" | awk '{print $1}')"
    fi
    if [[ -n "$expected" ]] && [[ "$expected" != "$actual" ]]; then
      rm -f "${dest}.tmp"
      err "SHA256 校验失败: $dest"; exit 1
    fi
    log "SHA256 校验通过"
  fi

  mv "${dest}.tmp" "$dest"
  chmod +x "$dest"
  log "已安装: $dest"
}

# ── 上游官方源下载 ──────────────────────────────────────────

download_compose_upstream() {
  local platform arch suffix version url checksum_url
  platform="$(detect_platform)"
  arch="$(detect_arch)"
  case "${platform}-${arch}" in
    linux-amd64)   suffix="linux-x86_64" ;;
    linux-arm64)   suffix="linux-aarch64" ;;
    darwin-amd64)  suffix="darwin-x86_64" ;;
    darwin-arm64)  suffix="darwin-aarch64" ;;
    *) err "docker-compose 不支持: ${platform}/${arch}"; exit 1 ;;
  esac
  version="$(github_latest_version docker/compose)"
  url="https://github.com/docker/compose/releases/download/${version}/docker-compose-${suffix}"
  checksum_url="https://github.com/docker/compose/releases/download/${version}/docker-compose-${suffix}.sha256"
  log "docker-compose ${version} (${platform}/${arch})"
  download_file "$url" "${INSTALL_DIR}/docker-compose" "$checksum_url"
}

download_mc_upstream() {
  local platform arch suffix version asset url checksum_url
  platform="$(detect_platform)"
  arch="$(detect_arch)"
  case "${platform}-${arch}" in
    linux-amd64)   suffix="linux-amd64" ;;
    linux-arm64)   suffix="linux-arm64" ;;
    darwin-amd64)  suffix="darwin-amd64" ;;
    darwin-arm64)  suffix="darwin-arm64" ;;
    *) err "mc 不支持: ${platform}/${arch}"; exit 1 ;;
  esac
  version="$(github_latest_version minio/mc)"
  asset="mc.${suffix}.${version}"
  url="https://github.com/minio/mc/releases/download/${version}/${asset}"
  checksum_url="https://github.com/minio/mc/releases/download/${version}/${asset}.sha256sum"
  log "mc ${version} (${platform}/${arch})"
  download_file "$url" "${INSTALL_DIR}/mc" "$checksum_url"
}

download_kubectl_upstream() {
  local platform arch version base_url
  platform="$(detect_platform)"
  arch="$(detect_arch)"
  version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  base_url="https://dl.k8s.io/release/${version}/bin/${platform}/${arch}"
  log "kubectl ${version} (${platform}/${arch})"
  download_file "${base_url}/kubectl" "${INSTALL_DIR}/kubectl" "${base_url}/kubectl.sha256"
}

# ── GitHub bin 分支下载 ─────────────────────────────────────

download_from_github() {
  local tool="$1"
  local verify="true"
  [[ "$VERIFY_CHECKSUM" == false ]] && verify="false"

  if [[ "$DRY_RUN" == true ]]; then
    local manifest repo branch platform_key path url
    manifest="$(tulan_resolve_manifest)"
    repo="$(tulan_manifest_get_repo "$manifest")"
    branch="$(tulan_manifest_read "$manifest" "print(data.get('branch', 'bin'))")"
    platform_key="$(tulan_manifest_platform_key)"
    path="$(tulan_manifest_read "$manifest" "print(data['tools']['${tool}']['paths']['${platform_key}'])")"
    url="$(tulan_binary_media_url "$repo" "$branch" "$path")"
    log "[dry-run] $url -> ${INSTALL_DIR}/$(tulan_manifest_read "$manifest" "print(data['tools']['${tool}'].get('install_name','${tool}'))")"
    return 0
  fi

  tulan_download_from_github "$tool" "$INSTALL_DIR" "$verify"
}

run_tool() {
  local tool="$1"
  case "$SOURCE" in
    github)
      case "$tool" in
        compose|docker-compose) download_from_github "docker-compose" ;;
        mc|minio)               download_from_github "mc" ;;
        kubectl|k8s)            download_from_github "kubectl" ;;
      esac
      ;;
    upstream)
      case "$tool" in
        compose|docker-compose) download_compose_upstream ;;
        mc|minio)               download_mc_upstream ;;
        kubectl|k8s)            download_kubectl_upstream ;;
      esac
      ;;
    *)
      err "未知下载源: $SOURCE（可选: github, upstream）"; exit 1
      ;;
  esac
}

main() {
  if ! command -v curl &>/dev/null; then
    err "需要 curl"; exit 1
  fi

  log "下载源: ${SOURCE}"
  log "平台: $(detect_platform)/$(detect_arch)"
  log "安装目录: ${INSTALL_DIR}"
  echo ""

  case "$TOOLS" in
    compose|docker-compose) run_tool compose ;;
    mc|minio)               run_tool mc ;;
    kubectl|k8s)            run_tool kubectl ;;
    all)
      run_tool compose; echo ""
      run_tool mc; echo ""
      run_tool kubectl
      ;;
    *) err "未知工具: $TOOLS"; exit 1 ;;
  esac

  echo ""
  if [[ "$DRY_RUN" == false ]]; then
    log "完成！确保 ${INSTALL_DIR} 在 PATH 中"
  fi
}

main "$@"
