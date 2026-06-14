#!/usr/bin/env bash
# Rancher 升级脚本（Docker 方式）
# 用法:
#   sudo bash upgrade.sh
#
# 可选变量:
#   RANCHER_IMAGE=rancher/rancher:v2.9.0
#   CONTAINER_NAME=rancher
#   HTTP_PORT_MAP=8080:80
#   HTTPS_PORT_MAP=8443:443
#   CERT_OUT=/etc/certs
#   RANCHER_DATA=/opt/rancher-data

set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-rancher}"
RANCHER_IMAGE="${RANCHER_IMAGE:-rancher/rancher:v2.13.3}"
HTTP_PORT_MAP="${HTTP_PORT_MAP:-8080:80}"
HTTPS_PORT_MAP="${HTTPS_PORT_MAP:-8443:443}"
CERT_OUT="${CERT_OUT:-/etc/certs}"
RANCHER_DATA="${RANCHER_DATA:-/opt/rancher-data}"

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
  [[ -f "${CERT_OUT}/k8s.local.tulan.wang.crt" ]] || { echo "缺少证书: ${CERT_OUT}/k8s.local.tulan.wang.crt"; exit 1; }
  [[ -f "${CERT_OUT}/k8s.local.tulan.wang.key" ]] || { echo "缺少私钥: ${CERT_OUT}/k8s.local.tulan.wang.key"; exit 1; }
  [[ -f "${CERT_OUT}/ca.crt" ]] || { echo "缺少 CA 证书: ${CERT_OUT}/ca.crt"; exit 1; }
  [[ -f "${CERT_OUT}/registries.yaml" ]] || { echo "缺少镜像源配置: ${CERT_OUT}/registries.yaml"; exit 1; }
}

main() {
  require_root
  require_docker
  check_files

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
    -v "${CERT_OUT}/k8s.local.tulan.wang.crt:/etc/rancher/ssl/cert.pem:ro" \
    -v "${CERT_OUT}/k8s.local.tulan.wang.key:/etc/rancher/ssl/key.pem:ro" \
    -v "${CERT_OUT}/ca.crt:/etc/rancher/ssl/cacerts.pem:ro" \
    --privileged \
    "${RANCHER_IMAGE}" >/dev/null

  log "升级命令已执行完成，当前容器状态："
  docker ps --filter "name=${CONTAINER_NAME}"
  log "可继续查看启动日志: docker logs -f ${CONTAINER_NAME}"
}

main "$@"
