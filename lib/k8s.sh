#!/usr/bin/env bash
# Rancher / K8s 单机部署脚本路径与公共函数

set -euo pipefail

TULAN_K8S_DIR="${TULAN_K8S_DIR:-$(tulan_get_home)/scripts/k8s}"
TULAN_K8S_CERT_OUT="${TULAN_K8S_CERT_OUT:-/etc/certs}"
TULAN_K8S_SITE_DOMAIN="${TULAN_K8S_SITE_DOMAIN:-k8s.local.tulan.wang}"
TULAN_K8S_RANCHER_DATA="${TULAN_K8S_RANCHER_DATA:-/opt/rancher-data}"
TULAN_K8S_RANCHER_IMAGE="${TULAN_K8S_RANCHER_IMAGE:-rancher/rancher:v2.8.5}"
TULAN_K8S_REGISTRY_MIRROR="${TULAN_K8S_REGISTRY_MIRROR:-${TULAN_DOCKER_REGISTRY_MIRROR:-https://hub.coding-space.cn}}"
TULAN_K8S_CONTAINER="${TULAN_K8S_CONTAINER:-rancher}"
TULAN_K8S_HTTP_PORT="${TULAN_K8S_HTTP_PORT:-8080:80}"
TULAN_K8S_HTTPS_PORT="${TULAN_K8S_HTTPS_PORT:-8443:443}"

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

tulan_k8s_list_usable_cert_domains() {
  local domain
  while read -r domain; do
    [[ -f "${TULAN_K8S_CERT_OUT}/${domain}.crt" && -f "${TULAN_K8S_CERT_OUT}/${domain}.key" ]] && echo "$domain"
  done < <(tulan_k8s_list_cert_domains)
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

tulan_k8s_list_cert_domains() {
  local cert_out="${1:-${TULAN_K8S_CERT_OUT}}" f domain
  [[ -d "$cert_out" ]] || return 0
  for f in "${cert_out}"/*.crt; do
    [[ -f "$f" ]] || continue
    domain="$(basename "$f" .crt)"
    [[ "$domain" == "ca" ]] && continue
    echo "$domain"
  done
}

tulan_k8s_has_ca_files() {
  [[ -f "${TULAN_K8S_CERT_OUT}/ca.crt" || -f "${TULAN_K8S_CERT_OUT}/ca.key" ]]
}

tulan_k8s_domain_has_cert_files() {
  local domain="$1"
  [[ -f "${TULAN_K8S_CERT_OUT}/${domain}.crt" \
    || -f "${TULAN_K8S_CERT_OUT}/${domain}.key" \
    || -f "${TULAN_K8S_CERT_OUT}/${domain}.csr" \
    || -f "${TULAN_K8S_CERT_OUT}/${domain}.cert" ]]
}

tulan_k8s_prompt_ca_clean() {
  local -a domains=()
  local domain choice i env_domain clean_all=false

  if [[ -n "${K8S_CLEAN_DOMAINS:-}" ]]; then
    return 0
  fi
  if [[ -n "${K8S_SITE_DOMAIN:-}" ]]; then
    if ! tulan_k8s_domain_has_cert_files "$K8S_SITE_DOMAIN"; then
      tulan_error "未找到域名证书: ${K8S_SITE_DOMAIN}（${TULAN_K8S_CERT_OUT}）"
      return 1
    fi
    export K8S_CLEAN_DOMAINS="$K8S_SITE_DOMAIN"
    return 0
  fi

  mapfile -t domains < <(tulan_k8s_list_cert_domains)

  if [[ ${#domains[@]} -eq 0 ]] && ! tulan_k8s_has_ca_files; then
    tulan_error "未发现可清理的证书（${TULAN_K8S_CERT_OUT}）"
    return 1
  fi

  env_domain=""
  if [[ -f "$(tulan_k8s_site_env_path)" ]]; then
    # shellcheck source=/dev/null
    source "$(tulan_k8s_site_env_path)"
    env_domain="${K8S_SITE_DOMAIN:-}"
  fi

  echo ""
  echo "可清理的域名证书（${TULAN_K8S_CERT_OUT}）"
  echo "────────────────────────────────────"
  if tulan_k8s_has_ca_files; then
    echo "  [CA] ca.crt / ca.key"
  fi
  if [[ ${#domains[@]} -eq 0 ]]; then
    echo "  (无站点域名证书，仅 CA)"
  else
    for i in "${!domains[@]}"; do
      active=""
      [[ -n "$env_domain" && "${domains[$i]}" == "$env_domain" ]] && active=" ← 当前 site.env"
      echo "  [$((i + 1))] ${domains[$i]}${active}"
    done
    echo "  [a] 全部"
  fi
  echo ""

  if [[ ${#domains[@]} -eq 0 ]]; then
    read -r -p "确认清理 CA? [y/N]: " choice
    [[ "$choice" =~ ^[yY]$ ]] || { tulan_log "已取消"; return 1; }
    export K8S_CLEAN_DOMAINS="__ca_only__"
    return 0
  fi

  read -r -p "请选择要清理的域名 [1-${#domains[@]}/a]: " choice
  choice="${choice// /}"

  if [[ "$choice" == "a" || "$choice" == "A" ]]; then
    clean_all=true
    K8S_CLEAN_DOMAINS="${domains[*]}"
  elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#domains[@]} )); then
    K8S_CLEAN_DOMAINS="${domains[$((choice - 1))]}"
  elif tulan_k8s_domain_has_cert_files "$choice"; then
    K8S_CLEAN_DOMAINS="$choice"
  else
    tulan_error "无效选择: ${choice}"
    return 1
  fi

  export K8S_CLEAN_DOMAINS
  if [[ "$clean_all" == true ]]; then
    export K8S_CLEAN_INCLUDE_CA=true
  fi
}

tulan_k8s_will_clean_ca() {
  local -a all_domains=() d found

  [[ "${K8S_CLEAN_INCLUDE_CA:-false}" == true ]] && return 0
  [[ "${K8S_CLEAN_DOMAINS:-}" == "__ca_only__" ]] && return 0

  mapfile -t all_domains < <(tulan_k8s_list_cert_domains)
  [[ ${#all_domains[@]} -gt 0 ]] || return 1

  for d in "${all_domains[@]}"; do
    found=false
    for x in ${K8S_CLEAN_DOMAINS:-}; do
      [[ "$d" == "$x" ]] && found=true
    done
    [[ "$found" == false ]] && return 1
  done
  return 0
}

tulan_k8s_confirm_ca_clean() {
  local domain env_domain show_ca=false

  if [[ "${TULAN_K8S_CA_CLEAN_YES:-false}" == true ]]; then
    return 0
  fi

  tulan_k8s_will_clean_ca && show_ca=true

  echo ""
  echo "将清理以下证书（目录: ${TULAN_K8S_CERT_OUT}）"
  echo "────────────────────────────────────"

  if [[ "${K8S_CLEAN_DOMAINS:-}" == "__ca_only__" ]]; then
    echo "  CA: ca.crt / ca.key"
  else
    for domain in ${K8S_CLEAN_DOMAINS:-}; do
      echo "  站点: ${domain} (.crt / .key / .csr / .cert)"
    done
    env_domain=""
    if [[ -f "$(tulan_k8s_site_env_path)" ]]; then
      # shellcheck source=/dev/null
      source "$(tulan_k8s_site_env_path)"
      env_domain="${K8S_SITE_DOMAIN:-}"
      for domain in ${K8S_CLEAN_DOMAINS:-}; do
        [[ "$domain" == "$env_domain" ]] && echo "  配置: site.env"
      done
    fi
    if [[ -f "$(tulan_k8s_rancher_env_path)" ]]; then
      # shellcheck source=/dev/null
      source "$(tulan_k8s_rancher_env_path)"
      env_domain="${K8S_SITE_DOMAIN:-}"
      for domain in ${K8S_CLEAN_DOMAINS:-}; do
        [[ "$domain" == "$env_domain" ]] && echo "  配置: rancher.env（部署记录）"
      done
    fi
    [[ "$show_ca" == true ]] && tulan_k8s_has_ca_files && echo "  CA: ca.crt / ca.key"
  fi

  if [[ "$show_ca" == true ]] && tulan_k8s_has_ca_files; then
    echo "  系统信任链: tulan-ca.crt"
  fi

  echo ""
  echo "（不会删除 Rancher 容器与数据，完整清理请用 brew k8s clean）"
  echo ""
  read -r -p "确认清理? [y/N]: " confirm
  [[ "$confirm" =~ ^[yY]$ ]] || { tulan_log "已取消"; return 1; }
}

tulan_k8s_resolve_site_ip_for_domain() {
  local domain="$1" ip=""
  if [[ -f "$(tulan_k8s_site_env_path)" ]]; then
    # shellcheck source=/dev/null
    source "$(tulan_k8s_site_env_path)"
    [[ "${K8S_SITE_DOMAIN:-}" == "$domain" ]] && ip="${K8S_SITE_IP:-}"
  fi
  echo "${ip:-$(tulan_k8s_detect_lan_ip 2>/dev/null || true)}"
}

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

tulan_k8s_prompt_install_ports() {
  local default_http default_https http_port https_port input

  if [[ -n "${HTTP_PORT_MAP:-}" && -n "${HTTPS_PORT_MAP:-}" ]]; then
    return 0
  fi

  tulan_k8s_load_rancher_config
  default_http="$(tulan_k8s_host_port_from_map "${HTTP_PORT_MAP:-${TULAN_K8S_HTTP_PORT}}")"
  default_https="$(tulan_k8s_host_port_from_map "${HTTPS_PORT_MAP:-${TULAN_K8S_HTTPS_PORT}}")"

  echo ""
  echo "Rancher 端口映射（宿主机 → 容器）"
  echo "────────────────────────────────────"
  echo "  HTTP  默认: ${default_http} → 80"
  echo "  HTTPS 默认: ${default_https} → 443"
  echo ""

  read -r -p "HTTPS 宿主机端口 [${default_https}]: " input
  https_port="${input:-$default_https}"
  tulan_k8s_validate_port "$https_port" || return 1

  read -r -p "HTTP 宿主机端口 [${default_http}]: " input
  http_port="${input:-$default_http}"
  tulan_k8s_validate_port "$http_port" || return 1

  if tulan_k8s_port_in_use "$https_port"; then
    tulan_log "警告: 端口 ${https_port} 可能已被占用"
  fi
  if tulan_k8s_port_in_use "$http_port"; then
    tulan_log "警告: 端口 ${http_port} 可能已被占用"
  fi

  export HTTP_PORT_MAP="${http_port}:80"
  export HTTPS_PORT_MAP="${https_port}:443"

  echo ""
  echo "  HTTP:  ${HTTP_PORT_MAP}"
  echo "  HTTPS: ${HTTPS_PORT_MAP}"
  echo ""
}

tulan_k8s_prompt_install_cert() {
  local -a domains=()
  local deployed_domain="" choice i default_idx domain

  if [[ -n "${K8S_SITE_DOMAIN:-}" ]]; then
    tulan_k8s_validate_domain "$K8S_SITE_DOMAIN" || return 1
    if [[ ! -f "${TULAN_K8S_CERT_OUT}/${K8S_SITE_DOMAIN}.crt" ]] \
      || [[ ! -f "${TULAN_K8S_CERT_OUT}/${K8S_SITE_DOMAIN}.key" ]]; then
      tulan_error "缺少证书: ${K8S_SITE_DOMAIN}（${TULAN_K8S_CERT_OUT}）"
      return 1
    fi
    K8S_SITE_IP="$(tulan_k8s_resolve_site_ip_for_domain "$K8S_SITE_DOMAIN")"
    export K8S_SITE_DOMAIN K8S_SITE_IP
    return 0
  fi

  mapfile -t domains < <(tulan_k8s_list_usable_cert_domains)
  if [[ ${#domains[@]} -eq 0 ]]; then
    tulan_error "未发现可用证书，请先执行: brew k8s ca"
    return 1
  fi

  deployed_domain=""
  tulan_k8s_load_rancher_config
  deployed_domain="${K8S_SITE_DOMAIN:-}"

  if [[ ${#domains[@]} -eq 1 ]]; then
    domain="${domains[0]}"
    echo ""
    echo "Rancher 安装 — 使用证书: ${domain}"
    echo "  目录: ${TULAN_K8S_CERT_OUT}"
    echo ""
  else
    echo ""
    echo "可用证书（${TULAN_K8S_CERT_OUT}）"
    echo "────────────────────────────────────"
    default_idx=1
    for i in "${!domains[@]}"; do
      active=""
      if [[ -n "$deployed_domain" && "${domains[$i]}" == "$deployed_domain" ]]; then
        active=" ← 上次部署"
        default_idx=$((i + 1))
      fi
      echo "  [$((i + 1))] ${domains[$i]}${active}"
    done
    echo ""
    read -r -p "请选择 Rancher 使用的证书 [1-${#domains[@]}] (默认 ${default_idx}): " choice
    choice="${choice:-$default_idx}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#domains[@]} )); then
      domain="${domains[$((choice - 1))]}"
    elif [[ -f "${TULAN_K8S_CERT_OUT}/${choice}.crt" && -f "${TULAN_K8S_CERT_OUT}/${choice}.key" ]]; then
      domain="$choice"
    else
      tulan_error "无效选择: ${choice}"
      return 1
    fi
    echo ""
    echo "  已选: ${domain}"
    echo ""
  fi

  export K8S_SITE_DOMAIN="$domain"
  export K8S_SITE_IP
  K8S_SITE_IP="$(tulan_k8s_resolve_site_ip_for_domain "$domain")"
}

tulan_k8s_require_rancher_config() {
  tulan_k8s_load_rancher_config
  if [[ -z "${K8S_SITE_DOMAIN:-}" ]]; then
    tulan_k8s_load_site_config
  fi
  if [[ -z "${K8S_SITE_DOMAIN:-}" ]]; then
    tulan_error "未找到 Rancher 部署记录（$(tulan_k8s_rancher_env_path)）"
    tulan_log "请先执行 brew k8s install 并选择证书"
    return 1
  fi
  if [[ ! -f "${TULAN_K8S_CERT_OUT}/${K8S_SITE_DOMAIN}.crt" ]] \
    || [[ ! -f "${TULAN_K8S_CERT_OUT}/${K8S_SITE_DOMAIN}.key" ]]; then
    tulan_error "部署记录中的证书不存在: ${K8S_SITE_DOMAIN}"
    return 1
  fi
  [[ -f "${TULAN_K8S_CERT_OUT}/ca.crt" ]] || {
    tulan_error "缺少 CA 证书: ${TULAN_K8S_CERT_OUT}/ca.crt"
    return 1
  }
  export K8S_SITE_DOMAIN K8S_SITE_IP
  export RANCHER_DATA="${RANCHER_DATA:-${TULAN_K8S_RANCHER_DATA}}"
  export CONTAINER_NAME="${CONTAINER_NAME:-${TULAN_K8S_CONTAINER}}"
  export HTTP_PORT_MAP="${HTTP_PORT_MAP:-${TULAN_K8S_HTTP_PORT}}"
  export HTTPS_PORT_MAP="${HTTPS_PORT_MAP:-${TULAN_K8S_HTTPS_PORT}}"
}

tulan_k8s_prompt_ca_params() {
  local lan_ip default_domain domain

  if [[ -n "${K8S_SITE_DOMAIN:-}" ]]; then
    tulan_k8s_validate_domain "$K8S_SITE_DOMAIN" || return 1
    if [[ -z "${K8S_SITE_IP:-}" ]]; then
      K8S_SITE_IP="$(tulan_k8s_detect_lan_ip 2>/dev/null || true)"
    fi
    export K8S_SITE_DOMAIN K8S_SITE_IP
    return 0
  fi

  lan_ip="$(tulan_k8s_detect_lan_ip 2>/dev/null || true)"
  default_domain="${TULAN_K8S_SITE_DOMAIN}"

  echo ""
  echo "Rancher HTTPS 证书配置"
  echo "────────────────────────────────────"
  if [[ -n "$lan_ip" ]]; then
    echo "  检测到局域网 IP: ${lan_ip}"
  else
    echo "  未检测到局域网 IP，证书 SAN 将不含 IP 项"
  fi
  echo ""
  read -r -p "请输入证书域名 [${default_domain}]: " domain
  domain="${domain:-$default_domain}"
  tulan_k8s_validate_domain "$domain" || return 1

  export K8S_SITE_DOMAIN="$domain"
  export K8S_SITE_IP="$lan_ip"
  echo ""
  echo "  域名: ${K8S_SITE_DOMAIN}"
  [[ -n "$K8S_SITE_IP" ]] && echo "  IP:   ${K8S_SITE_IP}"
  echo ""
}

tulan_k8s_export_env() {
  if [[ -n "${K8S_SITE_DOMAIN:-}" ]]; then
    export K8S_SITE_DOMAIN K8S_SITE_IP
  else
    tulan_k8s_load_rancher_config
    if [[ -z "${K8S_SITE_DOMAIN:-}" ]]; then
      tulan_k8s_load_site_config
    fi
  fi
  export CERT_OUT="$TULAN_K8S_CERT_OUT"
  export RANCHER_DATA="$TULAN_K8S_RANCHER_DATA"
  export RANCHER_IMAGE="$TULAN_K8S_RANCHER_IMAGE"
  export REGISTRY_MIRROR="$TULAN_K8S_REGISTRY_MIRROR"
  export CONTAINER_NAME="${CONTAINER_NAME:-$TULAN_K8S_CONTAINER}"
  export HTTP_PORT_MAP="${HTTP_PORT_MAP:-$TULAN_K8S_HTTP_PORT}"
  export HTTPS_PORT_MAP="${HTTPS_PORT_MAP:-$TULAN_K8S_HTTPS_PORT}"
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
  tulan_as_root bash "$path" "$@"
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

tulan_k8s_show_status() {
  tulan_k8s_require_linux || return 1
  tulan_k8s_require_docker || return 1

  echo "Rancher / K8s 状态"
  echo "────────────────────────────────────"
  echo "  脚本目录: $(tulan_k8s_dir)"
  echo "  证书目录: ${TULAN_K8S_CERT_OUT}"
  tulan_k8s_load_rancher_config
  if [[ -f "$(tulan_k8s_rancher_env_path)" ]]; then
    echo "  部署证书: ${K8S_SITE_DOMAIN}"
    [[ -n "${K8S_SITE_IP:-}" ]] && echo "  证书 IP:   ${K8S_SITE_IP}"
    [[ -n "${RANCHER_IMAGE:-}" ]] && echo "  已装镜像: ${RANCHER_IMAGE}"
    [[ -n "${HTTP_PORT_MAP:-}" ]] && echo "  HTTP 端口:  ${HTTP_PORT_MAP}"
    [[ -n "${HTTPS_PORT_MAP:-}" ]] && echo "  HTTPS 端口: ${HTTPS_PORT_MAP}"
    [[ -n "${INSTALLED_AT:-}" ]] && echo "  安装时间: ${INSTALLED_AT}"
  else
    tulan_k8s_load_site_config
    if [[ -f "$(tulan_k8s_site_env_path)" ]]; then
      echo "  最近证书: ${K8S_SITE_DOMAIN}（未 install，见 site.env）"
      [[ -n "${K8S_SITE_IP:-}" ]] && echo "  证书 IP:   ${K8S_SITE_IP}"
    else
      echo "  部署证书: (未安装，请先 brew k8s ca && brew k8s install)"
    fi
  fi
  echo "  数据目录: ${TULAN_K8S_RANCHER_DATA}"
  echo "  镜像:     ${TULAN_K8S_RANCHER_IMAGE}"
  echo "  镜像源:   ${TULAN_K8S_REGISTRY_MIRROR}"
  echo ""

  if docker ps -a --filter "name=${TULAN_K8S_CONTAINER}" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | grep -q .; then
    docker ps -a --filter "name=${TULAN_K8S_CONTAINER}" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
  else
    echo "  容器 ${TULAN_K8S_CONTAINER}: 未运行"
  fi
}
