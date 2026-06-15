#!/usr/bin/env bash
# Rancher 升级脚本（Docker 方式）
# 用法:
#   sudo bash upgrade.sh
#
# 可选变量:
#   RANCHER_IMAGE=rancher/rancher:v2.9.0   升级目标镜像（未指定时用脚本默认）
#   HTTP_PORT_MAP / HTTPS_PORT_MAP         未指定时从 rancher.env 读取
#   CERT_OUT=/etc/certs
#   RANCHER_DATA=/opt/rancher-data

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-config.sh
source "${_SCRIPT_DIR}/lib-config.sh"

# 升级目标镜像（与 rancher.env 中记录的旧版本无关）
RANCHER_UPGRADE_IMAGE="${RANCHER_UPGRADE_IMAGE:-rancher/rancher:v2.13.3}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "请使用 root 执行：sudo bash $0"
    exit 1
  fi
}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "未检测到 docker 命令。"
    exit 1
  fi
}

check_files() {
  [[ -f "${CERT_OUT}/rancher.env" || -f "${CERT_OUT}/site.env" ]] || {
    echo "缺少部署记录: ${CERT_OUT}/rancher.env（请先 brew k8s install）"
    exit 1
  }
  [[ -f "${CERT_OUT}/${K8S_SITE_DOMAIN}.crt" ]] || { echo "缺少证书: ${CERT_OUT}/${K8S_SITE_DOMAIN}.crt"; exit 1; }
  [[ -f "${CERT_OUT}/${K8S_SITE_DOMAIN}.key" ]] || { echo "缺少私钥: ${CERT_OUT}/${K8S_SITE_DOMAIN}.key"; exit 1; }
  [[ -f "${CERT_OUT}/ca.crt" ]] || { echo "缺少 CA 证书: ${CERT_OUT}/ca.crt"; exit 1; }
  [[ -f "${CERT_OUT}/registries.yaml" ]] || { echo "缺少镜像源配置: ${CERT_OUT}/registries.yaml"; exit 1; }
}

main() {
  require_root
  require_docker

  # 先从 rancher.env 加载证书/端口等；升级目标镜像单独指定
  unset RANCHER_IMAGE
  k8s_load_rancher_config
  RANCHER_IMAGE="${RANCHER_UPGRADE_IMAGE}"

  check_files

  log "使用部署证书: ${K8S_SITE_DOMAIN}（来自 rancher.env）"
  log "端口映射: ${HTTP_PORT_MAP}, ${HTTPS_PORT_MAP}"
  log "目标镜像: ${RANCHER_IMAGE}"
  log "拉取新镜像"
  docker pull "${RANCHER_IMAGE}"

  if docker ps -a --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}"; then
    log "停止并删除旧容器 ${CONTAINER_NAME}"
    docker rm -f "${CONTAINER_NAME}" >/dev/null
  else
    log "未发现旧容器 ${CONTAINER_NAME}，将直接创建"
  fi

  log "启动新版本容器 ${CONTAINER_NAME}"
  docker run -d --name "${CONTAINER_NAME}" --restart=unless-stopped \
    -p "${HTTP_PORT_MAP}" -p "${HTTPS_PORT_MAP}" \
    -v "${RANCHER_DATA}:/var/lib/rancher" \
    -v "${CERT_OUT}/registries.yaml:/etc/rancher/k3s/registries.yaml:ro" \
    -v "${CERT_OUT}/${K8S_SITE_DOMAIN}.crt:/etc/rancher/ssl/cert.pem:ro" \
    -v "${CERT_OUT}/${K8S_SITE_DOMAIN}.key:/etc/rancher/ssl/key.pem:ro" \
    -v "${CERT_OUT}/ca.crt:/etc/rancher/ssl/cacerts.pem:ro" \
    --privileged \
    "${RANCHER_IMAGE}" >/dev/null

  k8s_write_rancher_env

  log "升级命令已执行完成，当前容器状态："
  docker ps --filter "name=${CONTAINER_NAME}"
  log "可继续查看启动日志: docker logs -f ${CONTAINER_NAME}"
}

main "$@"
