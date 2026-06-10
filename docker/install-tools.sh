#!/usr/bin/env bash
# 在 Docker 镜像构建时安装常用二进制工具（仅 Linux）

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/tulan-tools/bin}"
ARCH="${TARGETARCH:-amd64}"

log() { echo "[install-tools] $*"; }

map_arch() {
  case "$ARCH" in
    amd64)  echo "amd64" ;;
    arm64)  echo "arm64" ;;
    *) log "不支持的架构: $ARCH"; exit 1 ;;
  esac
}

github_latest_version() {
  curl -fsSL "https://api.github.com/repos/$1/releases/latest" \
    | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4
}

verify_sha256() {
  local file="$1" expected="$2"
  local actual
  actual="$(sha256sum "$file" | awk '{print $1}')"
  if [[ "$expected" != "$actual" ]]; then
    log "SHA256 校验失败: $file"
    exit 1
  fi
}

download() {
  local url="$1" dest="$2" checksum_url="${3:-}"
  curl -fsSL "$url" -o "$dest"
  if [[ -n "$checksum_url" ]]; then
    local expected
    expected="$(curl -fsSL "$checksum_url" | awk '{print $1}')"
    verify_sha256 "$dest" "$expected"
  fi
  chmod +x "$dest"
  log "已安装: $dest"
}

install_kubectl() {
  local arch version base_url
  arch="$(map_arch)"
  version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  base_url="https://dl.k8s.io/release/${version}/bin/linux/${arch}"
  log "kubectl ${version} (linux/${arch})"
  download "${base_url}/kubectl" "${INSTALL_DIR}/kubectl" "${base_url}/kubectl.sha256"
}

install_compose() {
  local arch suffix version
  arch="$(map_arch)"
  case "$arch" in
    amd64) suffix="linux-x86_64" ;;
    arm64) suffix="linux-aarch64" ;;
  esac
  version="$(github_latest_version docker/compose)"
  log "docker-compose ${version} (linux/${arch})"
  download \
    "https://github.com/docker/compose/releases/download/${version}/docker-compose-${suffix}" \
    "${INSTALL_DIR}/docker-compose" \
    "https://github.com/docker/compose/releases/download/${version}/docker-compose-${suffix}.sha256"
}

install_mc() {
  local arch suffix version asset
  arch="$(map_arch)"
  case "$arch" in
    amd64) suffix="linux-amd64" ;;
    arm64) suffix="linux-arm64" ;;
  esac
  version="$(github_latest_version minio/mc)"
  asset="mc.${suffix}.${version}"
  log "mc ${version} (linux/${arch})"
  download \
    "https://github.com/minio/mc/releases/download/${version}/${asset}" \
    "${INSTALL_DIR}/mc" \
    "https://github.com/minio/mc/releases/download/${version}/${asset}.sha256sum"
}

main() {
  mkdir -p "$INSTALL_DIR"
  install_kubectl
  install_compose
  install_mc
  log "全部工具安装完成"
  ls -lh "$INSTALL_DIR"
}

main "$@"
