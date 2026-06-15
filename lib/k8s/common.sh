#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# 基础工具：路径、网络、配置加载
tulan_k8s_dir() {
  echo "$TULAN_K8S_DIR"
}

tulan_k8s_require_linux() {
  if [[ "$(uname -s | tr '[:upper:]' '[:lower:]')" != "linux" ]]; then
    tulan_error "K8s/Rancher 部署目前仅支持 Linux"
    return 1
  fi
}

tulan_k8s_require_docker() {
  if ! command -v docker &>/dev/null; then
    tulan_error "需要 Docker，请先执行: brew install docker"
    return 1
  fi
}

tulan_k8s_is_private_ip() {
  local ip="$1"
  [[ "$ip" =~ ^10\. ]] && return 0
  [[ "$ip" =~ ^192\.168\. ]] && return 0
  [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
  return 1
}

tulan_k8s_detect_lan_ip() {
  local ip addr

  if command -v ip &>/dev/null; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')"
    if [[ -n "$ip" ]] && tulan_k8s_is_private_ip "$ip"; then
      echo "$ip"
      return 0
    fi

    while read -r addr; do
      if tulan_k8s_is_private_ip "$addr"; then
        echo "$addr"
        return 0
      fi
    done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
  fi

  if command -v hostname &>/dev/null; then
    for ip in $(hostname -I 2>/dev/null); do
      if tulan_k8s_is_private_ip "$ip"; then
        echo "$ip"
        return 0
      fi
    done
  fi

  return 1
}

tulan_k8s_site_env_path() {
  echo "${TULAN_K8S_CERT_OUT}/site.env"
}

tulan_k8s_rancher_env_path() {
  echo "${TULAN_K8S_CERT_OUT}/rancher.env"
}

tulan_k8s_load_rancher_config() {
  local env_file
  env_file="$(tulan_k8s_rancher_env_path)"
  if [[ -f "$env_file" ]]; then
    # shellcheck source=/dev/null
    source "$env_file"
  fi
}

tulan_k8s_load_site_config() {
  local env_file
  env_file="$(tulan_k8s_site_env_path)"
  if [[ -f "$env_file" ]]; then
    # shellcheck source=/dev/null
    source "$env_file"
  fi
  K8S_SITE_DOMAIN="${K8S_SITE_DOMAIN:-${TULAN_K8S_SITE_DOMAIN}}"
  export K8S_SITE_DOMAIN K8S_SITE_IP
}

tulan_k8s_validate_domain() {
  local domain="$1"
  if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
    tulan_error "无效域名: ${domain}"
    return 1
  fi
}
