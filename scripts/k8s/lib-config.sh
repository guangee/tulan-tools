#!/usr/bin/env bash
# Rancher 部署配置加载（install / upgrade / ports 共用）
#
# 优先级：调用方传入的环境变量 > rancher.env > site.env > 默认值

k8s_load_rancher_config() {
  local env_cert_out="${CERT_OUT:-}"
  local env_http="${HTTP_PORT_MAP:-}"
  local env_https="${HTTPS_PORT_MAP:-}"
  local env_domain="${K8S_SITE_DOMAIN:-}"
  local env_site_ip="${K8S_SITE_IP:-}"
  local env_data="${RANCHER_DATA:-}"
  local env_container="${CONTAINER_NAME:-}"
  local env_mirror="${REGISTRY_MIRROR:-}"
  local env_image="${RANCHER_IMAGE:-}"
  local env_installed_at="${INSTALLED_AT:-}"

  CERT_OUT="${env_cert_out:-/etc/certs}"

  if [[ -f "${CERT_OUT}/rancher.env" ]]; then
    # shellcheck source=/dev/null
    source "${CERT_OUT}/rancher.env"
  elif [[ -f "${CERT_OUT}/site.env" ]]; then
    # shellcheck source=/dev/null
    source "${CERT_OUT}/site.env"
  fi

  CERT_OUT="${env_cert_out:-${CERT_OUT:-/etc/certs}}"
  K8S_SITE_DOMAIN="${env_domain:-${K8S_SITE_DOMAIN:-k8s.local.tulan.wang}}"
  K8S_SITE_IP="${env_site_ip:-${K8S_SITE_IP:-}}"
  CONTAINER_NAME="${env_container:-${CONTAINER_NAME:-rancher}}"
  RANCHER_DATA="${env_data:-${RANCHER_DATA:-/opt/rancher-data}}"
  REGISTRY_MIRROR="${env_mirror:-${REGISTRY_MIRROR:-https://hub.local.tulan.wang}}"
  HTTP_PORT_MAP="${env_http:-${HTTP_PORT_MAP:-8080:80}}"
  HTTPS_PORT_MAP="${env_https:-${HTTPS_PORT_MAP:-8443:443}}"
  RANCHER_IMAGE="${env_image:-${RANCHER_IMAGE:-rancher/rancher:v2.8.5}}"
  INSTALLED_AT="${env_installed_at:-${INSTALLED_AT:-}}"

  if [[ ! -f "${CERT_OUT}/${K8S_SITE_DOMAIN}.crt" && -f "${CERT_OUT}/k8s.local.tulan.wang.crt" ]]; then
    K8S_SITE_DOMAIN="k8s.local.tulan.wang"
  fi
}

k8s_write_rancher_env() {
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
