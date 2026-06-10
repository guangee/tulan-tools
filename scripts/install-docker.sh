#!/usr/bin/env bash
# 使用官方 get.docker.com 脚本安装 Docker，默认阿里云镜像加速

set -euo pipefail

_SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${_SCRIPT_ROOT}/lib/common.sh"

TULAN_HOME="$(tulan_get_home)"
DOCKER_SCRIPT_URL="${TULAN_DOCKER_SCRIPT_URL:-https://get.docker.com}"
DOCKER_SCRIPT_CACHE="${TULAN_HOME}/state/docker/get-docker.sh"
DOCKER_PKG_MIRROR="${TULAN_DOCKER_PKG_MIRROR:-Aliyun}"
DOCKER_REGISTRY_MIRROR="${TULAN_DOCKER_REGISTRY_MIRROR:-https://hub.coding-space.cn}"

CONFIGURE_ONLY=false
SKIP_INSTALL=false
REFRESH_SCRIPT=false
USE_PKG_MIRROR=true
ACTION="install"

usage() {
  cat <<EOF
用法: tulan docker [install|configure|fetch] [选项]

子命令:
  install       安装 Docker 并配置镜像加速（默认）
  configure     仅配置 registry 镜像加速
  fetch         仅下载官方安装脚本到本地缓存

选项:
  --refresh-script    强制重新下载官方安装脚本
  --no-mirror         不使用阿里云软件源（直连 Docker 官方源）
  --mirror NAME       安装脚本软件源镜像，默认 Aliyun
  --registry URL      registry 镜像地址，默认 https://hub.coding-space.cn
  --debug             显示详细 URL
  -h, --help          显示帮助

说明:
  官方脚本缓存: ${DOCKER_SCRIPT_CACHE}
  安装使用阿里云 Docker CE 源；安装完成后写入 /etc/docker/daemon.json
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    install) ACTION="install"; shift ;;
    configure) ACTION="configure"; CONFIGURE_ONLY=true; shift ;;
    fetch) ACTION="fetch"; SKIP_INSTALL=true; shift ;;
    --configure-only) CONFIGURE_ONLY=true; shift ;;
    --skip-install) SKIP_INSTALL=true; shift ;;
    --refresh-script) REFRESH_SCRIPT=true; shift ;;
    --no-mirror) USE_PKG_MIRROR=false; shift ;;
    --mirror) DOCKER_PKG_MIRROR="$2"; shift 2 ;;
    --registry) DOCKER_REGISTRY_MIRROR="$2"; shift 2 ;;
    --debug) export TULAN_DEBUG=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) tulan_error "未知参数: $1"; usage; exit 1 ;;
    *) tulan_error "未知参数: $1"; usage; exit 1 ;;
  esac
done

require_linux() {
  local os
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  if [[ "$os" != "linux" ]]; then
    tulan_error "Docker 安装脚本仅支持 Linux"
    exit 1
  fi
}

require_sudo() {
  if ! command -v sudo &>/dev/null; then
    tulan_error "需要 sudo 权限"
    exit 1
  fi
  if ! sudo -n true 2>/dev/null; then
    tulan_log "需要 root 权限，请输入 sudo 密码..."
    sudo -v
  fi
}

fetch_docker_script() {
  local cache_dir
  cache_dir="$(dirname "$DOCKER_SCRIPT_CACHE")"
  mkdir -p "$cache_dir"

  if [[ -f "$DOCKER_SCRIPT_CACHE" ]] && [[ "$REFRESH_SCRIPT" != true ]]; then
    tulan_log "使用已缓存的安装脚本: ${DOCKER_SCRIPT_CACHE}"
    return 0
  fi

  tulan_log "下载官方 Docker 安装脚本"
  tulan_debug "URL: ${DOCKER_SCRIPT_URL}"
  tulan_debug "保存: ${DOCKER_SCRIPT_CACHE}"

  if ! curl -fsSL "$DOCKER_SCRIPT_URL" -o "${DOCKER_SCRIPT_CACHE}.tmp"; then
    tulan_error "下载失败: ${DOCKER_SCRIPT_URL}"
    return 1
  fi

  chmod +x "${DOCKER_SCRIPT_CACHE}.tmp"
  mv "${DOCKER_SCRIPT_CACHE}.tmp" "$DOCKER_SCRIPT_CACHE"
  tulan_log "脚本已保存: ${DOCKER_SCRIPT_CACHE}"
}

run_docker_install() {
  local args=()

  if [[ "$USE_PKG_MIRROR" == true ]]; then
    args+=(--mirror "$DOCKER_PKG_MIRROR")
    tulan_log "使用软件源镜像: ${DOCKER_PKG_MIRROR}"
  else
    tulan_log "使用 Docker 官方软件源"
  fi

  tulan_log "执行官方安装脚本..."
  tulan_debug "命令: bash ${DOCKER_SCRIPT_CACHE} ${args[*]}"
  sudo bash "$DOCKER_SCRIPT_CACHE" "${args[@]}"
}

configure_registry_mirror() {
  local mirror="$1"
  local tmp
  tmp="$(mktemp)"

  tulan_log "配置 Docker registry 镜像: ${mirror}"

  python3 - "$mirror" <<'PY' > "$tmp"
import json
import sys
from pathlib import Path

mirror = sys.argv[1]
path = Path("/etc/docker/daemon.json")
data = {}
if path.exists():
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError:
        data = {}

mirrors = list(data.get("registry-mirrors") or [])
if mirror not in mirrors:
    mirrors.insert(0, mirror)
data["registry-mirrors"] = mirrors
print(json.dumps(data, indent=2, ensure_ascii=False))
PY

  sudo mkdir -p /etc/docker
  sudo cp "$tmp" /etc/docker/daemon.json
  rm -f "$tmp"
  tulan_log "已写入 /etc/docker/daemon.json"
}

restart_docker() {
  if command -v systemctl &>/dev/null; then
    sudo systemctl daemon-reload
    if systemctl is-active docker &>/dev/null; then
      sudo systemctl restart docker
    else
      sudo systemctl enable docker 2>/dev/null || true
      sudo systemctl start docker
    fi
    tulan_log "Docker 服务已启动"
  else
    tulan_log "未检测到 systemctl，请手动重启 Docker"
  fi
}

verify_docker() {
  if command -v docker &>/dev/null; then
    tulan_log "Docker 版本: $(docker --version 2>/dev/null || sudo docker --version)"
  fi
}

main() {
  require_linux

  case "$ACTION" in
    fetch)
      fetch_docker_script
      exit 0
      ;;
    configure)
      require_sudo
      configure_registry_mirror "$DOCKER_REGISTRY_MIRROR"
      restart_docker
      verify_docker
      tulan_log "registry 镜像配置完成"
      exit 0
      ;;
    install)
      if [[ "$CONFIGURE_ONLY" == true ]]; then
        require_sudo
        configure_registry_mirror "$DOCKER_REGISTRY_MIRROR"
        restart_docker
        verify_docker
        exit 0
      fi
      ;;
  esac

  require_sudo
  fetch_docker_script

  if [[ "$SKIP_INSTALL" != true ]]; then
    run_docker_install
  fi

  configure_registry_mirror "$DOCKER_REGISTRY_MIRROR"
  restart_docker
  verify_docker

  tulan_log "Docker 安装完成"
  echo ""
  echo "  软件源: $([[ "$USE_PKG_MIRROR" == true ]] && echo "${DOCKER_PKG_MIRROR} 镜像" || echo "官方源")"
  echo "  镜像加速: ${DOCKER_REGISTRY_MIRROR}"
  echo "  安装脚本: ${DOCKER_SCRIPT_CACHE}"
}

main "$@"
