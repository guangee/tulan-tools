#!/usr/bin/env bash
# Rancher v2.8.5 单机安装脚本（Docker 方式）
# 用法:
#   sudo bash install.sh
#
# 可选变量:
#   CERT_OUT=/etc/certs
#   K8S_SITE_DOMAIN=k8s.local.example.com
#   RANCHER_IMAGE=rancher/rancher:v2.8.5
#   REGISTRY_MIRROR=https://hub.local.tulan.wang
#   RANCHER_DATA=/opt/rancher-data
#   HTTP_PORT_MAP=8080:80
#   HTTPS_PORT_MAP=8443:443
set -euo pipefail

CERT_OUT="${CERT_OUT:-/etc/certs}"
RANCHER_IMAGE="${RANCHER_IMAGE:-rancher/rancher:v2.8.5}"
REGISTRY_MIRROR="${REGISTRY_MIRROR:-https://hub.local.tulan.wang}"
RANCHER_DATA="${RANCHER_DATA:-/opt/rancher-data}"
HTTP_PORT_MAP="${HTTP_PORT_MAP:-8080:80}"
HTTPS_PORT_MAP="${HTTPS_PORT_MAP:-8443:443}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "请使用 root 执行：sudo bash $0"
    exit 1
  fi
}

load_site_config() {
  if [[ -f "${CERT_OUT}/site.env" ]]; then
    # shellcheck source=/dev/null
    source "${CERT_OUT}/site.env"
  fi
  K8S_SITE_DOMAIN="${K8S_SITE_DOMAIN:-k8s.local.tulan.wang}"

  if [[ ! -f "${CERT_OUT}/${K8S_SITE_DOMAIN}.crt" && -f "${CERT_OUT}/k8s.local.tulan.wang.crt" ]]; then
    K8S_SITE_DOMAIN="k8s.local.tulan.wang"
  fi
}

prepare_rancher_files() {
  load_site_config
  mkdir -p "${RANCHER_DATA}"

  if [[ -n "${K8S_REGISTRIES_TEMPLATE:-}" && -f "${K8S_REGISTRIES_TEMPLATE}" ]]; then
    cp "${K8S_REGISTRIES_TEMPLATE}" "${CERT_OUT}/registries.yaml"
    if [[ -n "${REGISTRY_MIRROR:-}" ]]; then
      sed -i "s#https://hub.coding-space.cn#${REGISTRY_MIRROR}#g" "${CERT_OUT}/registries.yaml" 2>/dev/null || \
        sed -i '' "s#https://hub.coding-space.cn#${REGISTRY_MIRROR}#g" "${CERT_OUT}/registries.yaml" 2>/dev/null || true
    fi
  else
    cat > "${CERT_OUT}/registries.yaml" <<EOF
mirrors:
  docker.io:
    endpoint:
      - "${REGISTRY_MIRROR}"
EOF
  fi

  [[ -f "${CERT_OUT}/${K8S_SITE_DOMAIN}.crt" ]] || { echo "缺少证书: ${CERT_OUT}/${K8S_SITE_DOMAIN}.crt（请先 brew k8s ca）"; exit 1; }
  [[ -f "${CERT_OUT}/${K8S_SITE_DOMAIN}.key" ]] || { echo "缺少私钥: ${CERT_OUT}/${K8S_SITE_DOMAIN}.key"; exit 1; }
  [[ -f "${CERT_OUT}/ca.crt" ]] || { echo "缺少 CA 证书: ${CERT_OUT}/ca.crt"; exit 1; }
}

main() {
  require_root

  log "确保 Docker 服务可用"
  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker

  prepare_rancher_files

  log "删除同名旧容器（如果存在）"
  docker rm -f rancher >/dev/null 2>&1 || true

  log "拉取镜像 ${RANCHER_IMAGE}"
  docker pull "${RANCHER_IMAGE}"

  log "启动 Rancher（站点: ${K8S_SITE_DOMAIN}）"
  docker run -d --name rancher --restart=unless-stopped \
    -p "${HTTP_PORT_MAP}" -p "${HTTPS_PORT_MAP}" \
    -v "${RANCHER_DATA}:/var/lib/rancher" \
    -v "${CERT_OUT}/registries.yaml:/etc/rancher/k3s/registries.yaml:ro" \
    -v "${CERT_OUT}/${K8S_SITE_DOMAIN}.crt:/etc/rancher/ssl/cert.pem:ro" \
    -v "${CERT_OUT}/${K8S_SITE_DOMAIN}.key:/etc/rancher/ssl/key.pem:ro" \
    -v "${CERT_OUT}/ca.crt:/etc/rancher/ssl/cacerts.pem:ro" \
    --privileged \
    "${RANCHER_IMAGE}"

  log "当前容器状态："
  docker ps --filter name=rancher
  log "完成。请通过 https://${K8S_SITE_DOMAIN} 访问（按端口映射调整端口）。"
}

main "$@"
