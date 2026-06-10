#!/usr/bin/env bash
# 安装二进制工具（Cellar 多版本，类似 Homebrew）

set -euo pipefail

_SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${_SCRIPT_ROOT}/lib/common.sh"
# shellcheck source=../lib/binaries.sh
source "${_SCRIPT_ROOT}/lib/binaries.sh"
# shellcheck source=../lib/jdk-maven.sh
source "${_SCRIPT_ROOT}/lib/jdk-maven.sh"
# shellcheck source=../lib/node.sh
source "${_SCRIPT_ROOT}/lib/node.sh"

INSTALL_DIR="$(tulan_get_home)/bin"
TOOL_ARGS=()
SOURCE="github"
DRY_RUN=false
VERIFY_CHECKSUM=true
REQUESTED_VERSION=""

usage() {
  cat <<EOF
安装二进制工具: kubectl, docker-compose, mc, openjdk, maven, node

用法:
  brew install <工具> [工具...] [选项]

请先 brew list 查看可用工具，再按需安装（默认安装索引最新版）。

选项:
  --source SRC        源: github（默认，bin 索引最新）| upstream（官方最新）
  --version VER       指定版本（通常需 --source upstream）
  --no-verify         跳过 SHA256 校验
  --proxy URL         GitHub 代理前缀
  --no-proxy          禁用代理
  --refresh-manifest  强制刷新 bin 分支索引
  --debug             显示下载 URL
  --dry-run           仅显示信息
  -h, --help          显示帮助

示例:
  brew install kubectl
  brew install kubectl mc
  brew install openjdk-11 maven node-20
  brew install kubectl --version v1.32.0 --source upstream
  brew use java 11
  brew use node 20
  brew versions kubectl
EOF
}

log()  { echo "[install] $*" >&2; }
err()  { echo "[install] 错误: $*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) SOURCE="$2"; shift 2 ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --tool) TOOL_ARGS+=("$2"); shift 2 ;;
    --version) REQUESTED_VERSION="$2"; shift 2 ;;
    --no-verify) VERIFY_CHECKSUM=false; shift ;;
    --proxy) export TULAN_GITHUB_PROXY="$2"; shift 2 ;;
    --no-proxy) export TULAN_GITHUB_PROXY_DISABLED=true; shift ;;
    --refresh-manifest) export TULAN_MANIFEST_FORCE_REFRESH=true; shift ;;
    --debug) export TULAN_DEBUG=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --force)
      err "--force 仅用于私有软件包: brew install <包名> --force"
      exit 1
      ;;
    --*) err "未知参数: $1"; usage; exit 1 ;;
    *)
      TOOL_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ ${#TOOL_ARGS[@]} -eq 0 ]]; then
  err "请指定要安装的工具"
  echo "" >&2
  echo "  先运行: brew list" >&2
  echo "  再安装: brew install kubectl" >&2
  echo "  查版本: brew versions kubectl" >&2
  exit 1
fi

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

download_to_tmp() {
  local url="$1" tmp="$2" checksum_url="${3:-}"

  if [[ "$DRY_RUN" == true ]]; then
    log "[dry-run] $url -> $tmp"
    return 0
  fi

  curl -fsSL "$url" -o "$tmp"

  if [[ "$VERIFY_CHECKSUM" == true ]] && [[ -n "$checksum_url" ]]; then
    local expected actual
    expected="$(curl -fsSL "$checksum_url" | awk '{print $1}')"
    if command -v sha256sum &>/dev/null; then
      actual="$(sha256sum "$tmp" | awk '{print $1}')"
    else
      actual="$(shasum -a 256 "$tmp" | awk '{print $1}')"
    fi
    if [[ -n "$expected" ]] && [[ "$expected" != "$actual" ]]; then
      rm -f "$tmp"
      err "SHA256 校验失败"; exit 1
    fi
    log "SHA256 校验通过"
  fi
}

install_compose_upstream() {
  local platform arch suffix version url checksum_url tool install_name tmp
  platform="$(detect_platform)"
  arch="$(detect_arch)"
  tool="docker-compose"
  install_name="docker-compose"
  case "${platform}-${arch}" in
    linux-amd64)   suffix="linux-x86_64" ;;
    linux-arm64)   suffix="linux-aarch64" ;;
    darwin-amd64)  suffix="darwin-x86_64" ;;
    darwin-arm64)  suffix="darwin-aarch64" ;;
    *) err "docker-compose 不支持: ${platform}/${arch}"; exit 1 ;;
  esac
  version="${REQUESTED_VERSION:-$(github_latest_version docker/compose)}"
  url="https://github.com/docker/compose/releases/download/${version}/docker-compose-${suffix}"
  checksum_url="https://github.com/docker/compose/releases/download/${version}/docker-compose-${suffix}.sha256"
  log "docker-compose ${version} (${platform}/${arch})"
  [[ "$DRY_RUN" == true ]] && return 0
  tmp="$(mktemp)"
  download_to_tmp "$url" "$tmp" "$checksum_url"
  tulan_binary_finish_install "$tool" "$version" "$install_name" "upstream" "$tmp"
}

install_mc_upstream() {
  local platform arch suffix version asset url checksum_url tool install_name tmp
  platform="$(detect_platform)"
  arch="$(detect_arch)"
  tool="mc"
  install_name="mc"
  case "${platform}-${arch}" in
    linux-amd64)   suffix="linux-amd64" ;;
    linux-arm64)   suffix="linux-arm64" ;;
    darwin-amd64)  suffix="darwin-amd64" ;;
    darwin-arm64)  suffix="darwin-arm64" ;;
    *) err "mc 不支持: ${platform}/${arch}"; exit 1 ;;
  esac
  version="${REQUESTED_VERSION:-$(github_latest_version minio/mc)}"
  asset="mc.${suffix}.${version}"
  url="https://github.com/minio/mc/releases/download/${version}/${asset}"
  checksum_url="https://github.com/minio/mc/releases/download/${version}/${asset}.sha256sum"
  log "mc ${version} (${platform}/${arch})"
  [[ "$DRY_RUN" == true ]] && return 0
  tmp="$(mktemp)"
  download_to_tmp "$url" "$tmp" "$checksum_url"
  tulan_binary_finish_install "$tool" "$version" "$install_name" "upstream" "$tmp"
}

install_kubectl_upstream() {
  local platform arch version base_url tool install_name tmp
  platform="$(detect_platform)"
  arch="$(detect_arch)"
  tool="kubectl"
  install_name="kubectl"
  version="${REQUESTED_VERSION:-$(curl -fsSL https://dl.k8s.io/release/stable.txt)}"
  base_url="https://dl.k8s.io/release/${version}/bin/${platform}/${arch}"
  log "kubectl ${version} (${platform}/${arch})"
  [[ "$DRY_RUN" == true ]] && return 0
  tmp="$(mktemp)"
  download_to_tmp "${base_url}/kubectl" "$tmp" "${base_url}/kubectl.sha256"
  tulan_binary_finish_install "$tool" "$version" "$install_name" "upstream" "$tmp"
}

install_from_github() {
  local tool="$1"
  local verify="true"
  [[ "$VERIFY_CHECKSUM" == false ]] && verify="false"

  if [[ -n "$REQUESTED_VERSION" ]]; then
    export TULAN_BINARY_REQUESTED_VERSION="$REQUESTED_VERSION"
  fi

  if [[ "$DRY_RUN" == true ]]; then
    local manifest repo branch platform_key path proxy install_name
    manifest="$(tulan_resolve_manifest)"
    repo="$(tulan_manifest_get_repo "$manifest")"
    branch="$(tulan_manifest_read "$manifest" "print(data.get('branch', 'bin'))")"
    platform_key="$(tulan_manifest_platform_key)"
    path="$(tulan_manifest_read "$manifest" "print(data['tools']['${tool}']['paths']['${platform_key}'])")"
    proxy="$(tulan_get_github_proxy "$manifest")"
    install_name="$(tulan_manifest_read "$manifest" "print(data['tools']['${tool}'].get('install_name','${tool}'))")"
    if [[ -n "$proxy" ]]; then
      log "[dry-run] blob 代理: $(tulan_proxy_url "$(tulan_binary_blob_url "$repo" "$branch" "$path")" "$proxy")"
    fi
    log "[dry-run] cellar: $(tulan_binary_cellar_file "$tool" "VERSION" "$install_name")"
    return 0
  fi

  tulan_download_from_github "$tool" "$verify"
}

run_tool() {
  local raw="$1" canonical major
  canonical="$(tulan_binary_canonical_name "$raw")"

  major="$(tulan_openjdk_major_for_tool "${canonical:-$raw}")"
  if [[ -n "$major" ]]; then
    if ! command -v python3 &>/dev/null; then
      err "安装 OpenJDK 需要 python3"
      exit 1
    fi
    tulan_install_openjdk "$major" "$REQUESTED_VERSION" "$DRY_RUN"
    return
  fi

  if tulan_is_maven_tool "$raw" || [[ "$canonical" == maven ]]; then
    tulan_install_maven "$REQUESTED_VERSION" "$DRY_RUN"
    return
  fi

  major="$(tulan_node_major_for_tool "${canonical:-$raw}")"
  if [[ -n "$major" ]]; then
    if ! command -v python3 &>/dev/null; then
      err "安装 Node.js 需要 python3"
      exit 1
    fi
    tulan_install_node "$major" "$REQUESTED_VERSION" "$DRY_RUN"
    return
  fi

  if [[ -z "$canonical" ]]; then
    err "未知工具: ${raw}（运行 brew list 查看）"
    exit 1
  fi

  case "$SOURCE" in
    github)
      install_from_github "$canonical"
      ;;
    upstream)
      case "$canonical" in
        docker-compose) install_compose_upstream ;;
        mc)             install_mc_upstream ;;
        kubectl)        install_kubectl_upstream ;;
      esac
      ;;
    *)
      err "未知源: $SOURCE"; exit 1
      ;;
  esac
}

main() {
  local tool

  if ! command -v curl &>/dev/null; then
    err "需要 curl"; exit 1
  fi

  log "安装源: ${SOURCE}（默认安装最新版）"
  log "平台: $(detect_platform)/$(detect_arch)"

  if [[ "${TULAN_MANIFEST_FORCE_REFRESH:-}" == true ]] && [[ "$SOURCE" == "github" ]]; then
    tulan_manifest_refresh true || exit 1
    unset TULAN_MANIFEST_FORCE_REFRESH
    echo "" >&2
  fi

  echo "" >&2

  for tool in "${TOOL_ARGS[@]}"; do
    run_tool "$tool"
    echo "" >&2
  done

  if [[ "$DRY_RUN" == false ]]; then
    log "完成！命令入口: ${INSTALL_DIR}"
  fi
}

main "$@"
