#!/usr/bin/env bash
# 修改已部署 Rancher 的 HTTP/HTTPS 端口映射（重建容器，保留数据与证书）
#
# 用法:
#   sudo bash ports.sh
#
# 环境变量（通常由 brew k8s ports 传入）:
#   HTTP_PORT_MAP=8080:80
#   HTTPS_PORT_MAP=9443:443
#   其余同 upgrade.sh，默认从 rancher.env 或运行中容器读取

set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-rancher}"
HTTP_PORT_MAP="${HTTP_PORT_MAP:-8080:80}"
HTTPS_PORT_MAP="${HTTPS_PORT_MAP:-8443:443}"
CERT_OUT="${CERT_OUT:-/etc/certs}"
RANCHER_DATA="${RANCHER_DATA:-/opt/rancher-data}"
RANCHER_IMAGE="${RANCHER_IMAGE:-rancher/rancher:v2.8.5}"
REGISTRY_MIRROR="${REGISTRY_MIRROR:-https://hub.local.tulan.wang}"

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
  command -v docker >/dev/null 2>&1 || { echo "未检测到 docker 命令。"; exit 1; }
}

load_rancher_config() {
  if [[ -f "${CERT_OUT}/rancher.env" ]]; then
    # shellcheck source=/dev/null
    source "${CERT_OUT}/rancher.env"
  fi
  K8S_SITE_DOMAIN="${K8S_SITE_DOMAIN:-k8s.local.tulan.wang}"
  CONTAINER_NAME="${CONTAINER_NAME:-rancher}"
  RANCHER_DATA="${RANCHER_DATA:-/opt/rancher-data}"
  RANCHER_IMAGE="${RANCHER_IMAGE:-rancher/rancher:v2.8.5}"
  REGISTRY_MIRROR="${REGISTRY_MIRROR:-https://hub.local.tulan.wang}"
}

update_rancher_env() {
  local ts installed_at
  ts="$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')"
  installed_at="${INSTALLED_AT:-$ts}"
  cat > "${CERT_OUT}/rancher.env" <<EOF
# brew k8s install 写入，upgrade/ports 读取
K8S_SITE_DOMAIN=${K8S_SITE_DOMAIN}
K8S_SITE_IP=${K8S_SITE_IP:-}
CERT_OUT=${CERT_OUT}
RANCHER_IMAGE=${RANCHER_IMAGE}
RANCHER_DATA=${RANCHER_DATA}
CONTAINER_NAME=${CONTAINER_NAME}
HTTP_PORT_MAP=${HTTP_PORT_MAP}
HTTPS_PORT_MAP=${HTTPS_PORT_MAP}
REGISTRY_MIRROR=${REGISTRY_MIRROR}
INSTALLED_AT=${installed_at}
UPDATED_AT=${ts}
EOF
  chmod 644 "${CERT_OUT}/rancher.env"
}

check_files() {
  [[ -f "${CERT_OUT}/${K8S_SITE_DOMAIN}.crt" ]] || { echo "缺少证书: ${CERT_OUT}/${K8S_SITE_DOMAIN}.crt"; exit 1; }
  [[ -f "${CERT_OUT}/${K8S_SITE_DOMAIN}.key" ]] || { echo "缺少私钥: ${CERT_OUT}/${K8S_SITE_DOMAIN}.key"; exit 1; }
  [[ -f "${CERT_OUT}/ca.crt" ]] || { echo "缺少 CA 证书: ${CERT_OUT}/ca.crt"; exit 1; }
  [[ -f "${CERT_OUT}/registries.yaml" ]] || { echo "缺少镜像源配置: ${CERT_OUT}/registries.yaml"; exit 1; }
}

main() {
  require_root
  require_docker
  load_rancher_config
  check_files

  log "修改端口映射: HTTP ${HTTP_PORT_MAP}, HTTPS ${HTTPS_PORT_MAP}"
  log "沿用镜像: ${RANCHER_IMAGE}，证书: ${K8S_SITE_DOMAIN}"

  if docker ps -a --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}"; then
    RANCHER_IMAGE="$(docker inspect -f '{{.Config.Image}}' "${CONTAINER_NAME}" 2>/dev/null || echo "${RANCHER_IMAGE}")"
    log "停止并删除旧容器 ${CONTAINER_NAME}"
    docker rm -f "${CONTAINER_NAME}" >/dev/null
  else
    log "未发现旧容器 ${CONTAINER_NAME}，将直接创建"
  fi

  log "以新端口启动容器 ${CONTAINER_NAME}"
  docker run -d --name "${CONTAINER_NAME}" --restart=unless-stopped \
    -p "${HTTP_PORT_MAP}" -p "${HTTPS_PORT_MAP}" \
    -v "${RANCHER_DATA}:/var/lib/rancher" \
    -v "${CERT_OUT}/registries.yaml:/etc/rancher/k3s/registries.yaml:ro" \
    -v "${CERT_OUT}/${K8S_SITE_DOMAIN}.crt:/etc/rancher/ssl/cert.pem:ro" \
    -v "${CERT_OUT}/${K8S_SITE_DOMAIN}.key:/etc/rancher/ssl/key.pem:ro" \
    -v "${CERT_OUT}/ca.crt:/etc/rancher/ssl/cacerts.pem:ro" \
    --privileged \
    "${RANCHER_IMAGE}" >/dev/null

  update_rancher_env

  log "端口修改完成，当前容器状态："
  docker ps --filter "name=${CONTAINER_NAME}"
  log "请通过 https://${K8S_SITE_DOMAIN}:${HTTPS_PORT_MAP%%:*} 访问"
}

main "$@"
