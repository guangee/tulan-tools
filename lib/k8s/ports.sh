#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# 端口与部署配置解析
tulan_k8s_host_port_from_map() {
  local map="${1:-}"
  [[ -n "$map" ]] || return 1
  echo "${map%%:*}"
}

tulan_k8s_validate_port() {
  local port="$1"
  if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    tulan_error "无效端口: ${port}（有效范围 1-65535）"
    return 1
  fi
}

tulan_k8s_set_http_port() {
  local port="$1"
  tulan_k8s_validate_port "$port" || return 1
  export HTTP_PORT_MAP="${port}:80"
}

tulan_k8s_set_https_port() {
  local port="$1"
  tulan_k8s_validate_port "$port" || return 1
  export HTTPS_PORT_MAP="${port}:443"
}

tulan_k8s_port_in_use() {
  local port="$1"
  if command -v ss &>/dev/null; then
    ss -ltn "sport = :${port}" 2>/dev/null | grep -q ":${port}" && return 0
  elif command -v netstat &>/dev/null; then
    netstat -ltn 2>/dev/null | grep -q ":${port} " && return 0
  fi
  return 1
}

tulan_k8s_warn_port_conflict() {
  local port="$1" current_port="${2:-}"
  [[ -n "$current_port" && "$port" == "$current_port" ]] && return 0
  if tulan_k8s_port_in_use "$port"; then
    tulan_log "警告: 端口 ${port} 可能已被占用"
  fi
}

tulan_k8s_detect_container_config() {
  local name="${CONTAINER_NAME:-${TULAN_K8S_CONTAINER}}"
  local cert_src http_host https_host data_dir

  if ! command -v docker &>/dev/null; then
    return 1
  fi
  if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -Fxq "$name"; then
    return 1
  fi

  CONTAINER_NAME="$name"
  RANCHER_IMAGE="$(docker inspect -f '{{.Config.Image}}' "$name" 2>/dev/null || true)"
  data_dir="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/rancher"}}{{.Source}}{{end}}{{end}}' "$name" 2>/dev/null || true)"
  [[ -n "$data_dir" ]] && RANCHER_DATA="$data_dir"

  cert_src="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/rancher/ssl/cert.pem"}}{{.Source}}{{end}}{{end}}' "$name" 2>/dev/null || true)"
  if [[ -n "$cert_src" ]]; then
    K8S_SITE_DOMAIN="$(basename "$cert_src" .crt)"
    CERT_OUT="$(dirname "$cert_src")"
  fi

  http_host="$(docker port "$name" 80/tcp 2>/dev/null | head -n1 | sed 's/.*://')"
  https_host="$(docker port "$name" 443/tcp 2>/dev/null | head -n1 | sed 's/.*://')"
  [[ -n "$http_host" ]] && HTTP_PORT_MAP="${http_host}:80"
  [[ -n "$https_host" ]] && HTTPS_PORT_MAP="${https_host}:443"

  export CONTAINER_NAME RANCHER_IMAGE RANCHER_DATA HTTP_PORT_MAP HTTPS_PORT_MAP K8S_SITE_DOMAIN CERT_OUT
  return 0
}

tulan_k8s_resolve_deploy_config() {
  tulan_k8s_load_rancher_config
  if [[ -z "${K8S_SITE_DOMAIN:-}" ]]; then
    tulan_k8s_load_site_config
  fi
  if [[ -n "${K8S_SITE_DOMAIN:-}" ]] \
    && [[ -f "${TULAN_K8S_CERT_OUT}/${K8S_SITE_DOMAIN}.crt" ]] \
    && [[ -f "${TULAN_K8S_CERT_OUT}/${K8S_SITE_DOMAIN}.key" ]]; then
    export K8S_SITE_DOMAIN K8S_SITE_IP
    export RANCHER_DATA="${RANCHER_DATA:-${TULAN_K8S_RANCHER_DATA}}"
    export CONTAINER_NAME="${CONTAINER_NAME:-${TULAN_K8S_CONTAINER}}"
    export HTTP_PORT_MAP="${HTTP_PORT_MAP:-${TULAN_K8S_HTTP_PORT}}"
    export HTTPS_PORT_MAP="${HTTPS_PORT_MAP:-${TULAN_K8S_HTTPS_PORT}}"
    export RANCHER_IMAGE="${RANCHER_IMAGE:-${TULAN_K8S_RANCHER_IMAGE}}"
    export REGISTRY_MIRROR="${REGISTRY_MIRROR:-${TULAN_K8S_REGISTRY_MIRROR}}"
    export CERT_OUT="${CERT_OUT:-${TULAN_K8S_CERT_OUT}}"
    return 0
  fi

  if tulan_k8s_detect_container_config; then
    [[ -f "${CERT_OUT:-${TULAN_K8S_CERT_OUT}}/${K8S_SITE_DOMAIN}.crt" ]] \
      || [[ -f "${TULAN_K8S_CERT_OUT}/${K8S_SITE_DOMAIN}.crt" ]] || {
      tulan_error "无法从容器推断有效证书: ${K8S_SITE_DOMAIN}"
      return 1
    }
    CERT_OUT="${CERT_OUT:-${TULAN_K8S_CERT_OUT}}"
    export CERT_OUT K8S_SITE_DOMAIN RANCHER_DATA CONTAINER_NAME HTTP_PORT_MAP HTTPS_PORT_MAP RANCHER_IMAGE
    return 0
  fi

  tulan_error "未找到 Rancher 部署记录（$(tulan_k8s_rancher_env_path)）或运行中的容器"
  tulan_log "请先执行 brew k8s install，或确认容器 ${TULAN_K8S_CONTAINER} 存在"
  return 1
}
tulan_k8s_prompt_ports() {
  local mode="${1:-install}"
  local default_http default_https http_port https_port input
  local need_https=true need_http=true
  local cur_http cur_https

  if [[ "$mode" == "change" ]]; then
    [[ "${K8S_PORTS_CLI_HTTPS:-false}" == true ]] && need_https=false
    [[ "${K8S_PORTS_CLI_HTTP:-false}" == true ]] && need_http=false
  else
    [[ -n "${HTTPS_PORT_MAP:-}" ]] && need_https=false
    [[ -n "${HTTP_PORT_MAP:-}" ]] && need_http=false
  fi

  if [[ "$need_https" == false && "$need_http" == false ]]; then
    if [[ "$mode" == "change" ]]; then
      local cur_http cur_https old_http old_https
      old_http="$(tulan_k8s_host_port_from_map "${K8S_OLD_HTTP_PORT_MAP:-}")"
      old_https="$(tulan_k8s_host_port_from_map "${K8S_OLD_HTTPS_PORT_MAP:-}")"
      cur_http="$(tulan_k8s_host_port_from_map "${HTTP_PORT_MAP:-}")"
      cur_https="$(tulan_k8s_host_port_from_map "${HTTPS_PORT_MAP:-}")"
      if [[ "${cur_http}" == "${old_http}" && "${cur_https}" == "${old_https}" ]]; then
        tulan_log "端口未变化，无需重建容器"
        return 1
      fi
    fi
    return 0
  fi

  if [[ "$mode" == "change" ]]; then
    :
  else
    tulan_k8s_load_rancher_config
  fi

  default_http="$(tulan_k8s_host_port_from_map "${HTTP_PORT_MAP:-${TULAN_K8S_HTTP_PORT}}")"
  default_https="$(tulan_k8s_host_port_from_map "${HTTPS_PORT_MAP:-${TULAN_K8S_HTTPS_PORT}}")"
  cur_http="$default_http"
  cur_https="$default_https"

  echo ""
  if [[ "$mode" == "change" ]]; then
    echo "修改 Rancher 端口（宿主机 → 容器）"
    echo "────────────────────────────────────"
    echo "  当前 HTTP:  ${cur_http} → 80"
    echo "  当前 HTTPS: ${cur_https} → 443"
  else
    echo "Rancher 端口映射（宿主机 → 容器）"
    echo "────────────────────────────────────"
    echo "  HTTP  默认: ${default_http} → 80"
    echo "  HTTPS 默认: ${default_https} → 443"
  fi
  echo ""

  if [[ "$need_https" == true ]]; then
    read -r -p "HTTPS 宿主机端口 [${default_https}]: " input
    https_port="${input:-$default_https}"
    tulan_k8s_validate_port "$https_port" || return 1
    export HTTPS_PORT_MAP="${https_port}:443"
  else
    https_port="$(tulan_k8s_host_port_from_map "$HTTPS_PORT_MAP")"
  fi

  if [[ "$need_http" == true ]]; then
    read -r -p "HTTP 宿主机端口 [${default_http}]: " input
    http_port="${input:-$default_http}"
    tulan_k8s_validate_port "$http_port" || return 1
    export HTTP_PORT_MAP="${http_port}:80"
  else
    http_port="$(tulan_k8s_host_port_from_map "$HTTP_PORT_MAP")"
  fi

  tulan_k8s_warn_port_conflict "$https_port" "$cur_https"
  tulan_k8s_warn_port_conflict "$http_port" "$cur_http"

  echo ""
  echo "  HTTP:  ${HTTP_PORT_MAP}"
  echo "  HTTPS: ${HTTPS_PORT_MAP}"
  echo ""

  if [[ "$mode" == "change" ]] \
    && [[ "${HTTP_PORT_MAP}" == "${cur_http}:80" ]] \
    && [[ "${HTTPS_PORT_MAP}" == "${cur_https}:443" ]]; then
    tulan_log "端口未变化，无需重建容器"
    return 1
  fi
}

tulan_k8s_confirm_change_ports() {
  local old_http old_https new_http new_https

  if [[ "${TULAN_K8S_PORTS_YES:-false}" == true ]]; then
    return 0
  fi

  old_http="$(tulan_k8s_host_port_from_map "${K8S_OLD_HTTP_PORT_MAP:-}")"
  old_https="$(tulan_k8s_host_port_from_map "${K8S_OLD_HTTPS_PORT_MAP:-}")"
  new_http="$(tulan_k8s_host_port_from_map "${HTTP_PORT_MAP:-}")"
  new_https="$(tulan_k8s_host_port_from_map "${HTTPS_PORT_MAP:-}")"

  echo ""
  echo "将重建 Rancher 容器以应用新端口（数据与证书不变，会有短暂中断）"
  echo "────────────────────────────────────"
  echo "  HTTP:  ${old_http} → ${new_http}"
  echo "  HTTPS: ${old_https} → ${new_https}"
  echo ""
  read -r -p "确认修改? [y/N]: " confirm
  [[ "$confirm" =~ ^[yY]$ ]] || { tulan_log "已取消"; return 1; }
}

tulan_k8s_prompt_install_ports() {
  tulan_k8s_prompt_ports install
}
