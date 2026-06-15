#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# 脚本执行与部署环境
tulan_k8s_require_rancher_config() {
  tulan_k8s_resolve_deploy_config || return 1
  [[ -f "${CERT_OUT:-${TULAN_K8S_CERT_OUT}}/ca.crt" ]] || {
    tulan_error "缺少 CA 证书: ${CERT_OUT:-${TULAN_K8S_CERT_OUT}}/ca.crt"
    return 1
  }
  export K8S_SITE_DOMAIN K8S_SITE_IP CERT_OUT
  export RANCHER_DATA CONTAINER_NAME HTTP_PORT_MAP HTTPS_PORT_MAP RANCHER_IMAGE REGISTRY_MIRROR
}
tulan_k8s_export_env() {
  # 调用方显式传入的变量优先于 rancher.env（避免 ports/install 新端口被旧配置覆盖）
  local env_cert_out="${CERT_OUT:-}"
  local env_domain="${K8S_SITE_DOMAIN:-}"
  local env_site_ip="${K8S_SITE_IP:-}"
  local env_data="${RANCHER_DATA:-}"
  local env_container="${CONTAINER_NAME:-}"
  local env_mirror="${REGISTRY_MIRROR:-}"
  local env_image="${RANCHER_IMAGE:-}"
  local env_http="${HTTP_PORT_MAP:-}"
  local env_https="${HTTPS_PORT_MAP:-}"
  local env_upgrade="${RANCHER_UPGRADE_IMAGE:-}"
  local env_installed_at="${INSTALLED_AT:-}"

  tulan_k8s_load_rancher_config
  if [[ -z "${K8S_SITE_DOMAIN:-}" ]]; then
    tulan_k8s_load_site_config
  fi

  export CERT_OUT="${env_cert_out:-${CERT_OUT:-$TULAN_K8S_CERT_OUT}}"
  export K8S_SITE_DOMAIN="${env_domain:-${K8S_SITE_DOMAIN:-}}"
  export K8S_SITE_IP="${env_site_ip:-${K8S_SITE_IP:-}}"
  export RANCHER_DATA="${env_data:-${RANCHER_DATA:-$TULAN_K8S_RANCHER_DATA}}"
  export RANCHER_IMAGE="${env_image:-${RANCHER_IMAGE:-$TULAN_K8S_RANCHER_IMAGE}}"
  export REGISTRY_MIRROR="${env_mirror:-${REGISTRY_MIRROR:-$TULAN_K8S_REGISTRY_MIRROR}}"
  export CONTAINER_NAME="${env_container:-${CONTAINER_NAME:-$TULAN_K8S_CONTAINER}}"
  export HTTP_PORT_MAP="${env_http:-${HTTP_PORT_MAP:-$TULAN_K8S_HTTP_PORT}}"
  export HTTPS_PORT_MAP="${env_https:-${HTTPS_PORT_MAP:-$TULAN_K8S_HTTPS_PORT}}"
  export RANCHER_UPGRADE_IMAGE="${env_upgrade:-${RANCHER_UPGRADE_IMAGE:-}}"
  export INSTALLED_AT="${env_installed_at:-${INSTALLED_AT:-}}"
  export K8S_REGISTRIES_TEMPLATE
  K8S_REGISTRIES_TEMPLATE="$(tulan_get_home)/config/k8s.registries.yaml"
}

tulan_k8s_script_path() {
  local name="$1"
  local path
  path="$(tulan_k8s_dir)/${name}"
  if [[ ! -f "$path" ]]; then
    tulan_error "缺少 K8s 脚本: ${path}"
    tulan_log "请先 brew update 或确认 scripts/k8s 目录存在"
    return 1
  fi
  echo "$path"
}

tulan_k8s_run() {
  local script="$1"
  shift
  local path
  tulan_k8s_require_linux || return 1
  path="$(tulan_k8s_script_path "$script")" || return 1
  tulan_k8s_export_env
  tulan_log "执行: ${script} $*"
  # sudo 默认不保留环境变量，显式传入部署配置（尤其端口映射）
  tulan_as_root env \
    CERT_OUT="${CERT_OUT}" \
    K8S_SITE_DOMAIN="${K8S_SITE_DOMAIN:-}" \
    K8S_SITE_IP="${K8S_SITE_IP:-}" \
    RANCHER_DATA="${RANCHER_DATA}" \
    RANCHER_IMAGE="${RANCHER_IMAGE}" \
    CONTAINER_NAME="${CONTAINER_NAME}" \
    HTTP_PORT_MAP="${HTTP_PORT_MAP}" \
    HTTPS_PORT_MAP="${HTTPS_PORT_MAP}" \
    REGISTRY_MIRROR="${REGISTRY_MIRROR}" \
    INSTALLED_AT="${INSTALLED_AT:-}" \
    RANCHER_UPGRADE_IMAGE="${RANCHER_UPGRADE_IMAGE:-}" \
    K8S_REGISTRIES_TEMPLATE="${K8S_REGISTRIES_TEMPLATE:-}" \
    bash "$path" "$@"
}

tulan_k8s_run_user() {
  local script="$1"
  shift
  local path
  path="$(tulan_k8s_script_path "$script")" || return 1
  tulan_k8s_export_env
  tulan_log "执行: ${script} $*"
  bash "$path" "$@"
}
