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
TULAN_K8S_UPGRADE_DEFAULT="${TULAN_K8S_UPGRADE_DEFAULT:-rancher/rancher:v2.13.3}"

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

tulan_k8s_warn_port_conflict() {
  local port="$1" current_port="${2:-}"
  [[ -n "$current_port" && "$port" == "$current_port" ]] && return 0
  if tulan_k8s_port_in_use "$port"; then
    tulan_log "警告: 端口 ${port} 可能已被占用"
  fi
}

tulan_k8s_detect_container_config() {
  local name="${1:-${CONTAINER_NAME:-${TULAN_K8S_CONTAINER}}}"
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
  tulan_k8s_resolve_deploy_config || return 1
  [[ -f "${CERT_OUT:-${TULAN_K8S_CERT_OUT}}/ca.crt" ]] || {
    tulan_error "缺少 CA 证书: ${CERT_OUT:-${TULAN_K8S_CERT_OUT}}/ca.crt"
    return 1
  }
  export K8S_SITE_DOMAIN K8S_SITE_IP CERT_OUT
  export RANCHER_DATA CONTAINER_NAME HTTP_PORT_MAP HTTPS_PORT_MAP RANCHER_IMAGE REGISTRY_MIRROR
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

tulan_k8s_versions_cache_path() {
  echo "$(tulan_get_home)/state/k8s.rancher.versions.json"
}

tulan_k8s_versions_file() {
  local cache fallback
  cache="$(tulan_k8s_versions_cache_path)"
  if [[ -f "$cache" ]]; then
    echo "$cache"
    return 0
  fi
  fallback="${TULAN_K8S_VERSIONS_FILE:-$(tulan_get_home)/config/k8s.rancher.versions}"
  if [[ -f "$fallback" ]]; then
    echo "$fallback"
    return 0
  fi
  json_fallback="$(tulan_get_home)/config/k8s.rancher.versions.json"
  if [[ -f "$json_fallback" ]]; then
    echo "$json_fallback"
    return 0
  fi
  echo "$cache"
}

tulan_k8s_read_versions_from_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    return 1
  fi
  if [[ "$f" == *.json ]]; then
    python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as fh:
    data = json.load(fh)
for tag in data.get('tags') or []:
    print(tag)
" "$f"
    return 0
  fi
  local line tag
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line// /}"
    [[ -n "$line" ]] || continue
    tag="$(tulan_k8s_normalize_version_tag "$line")"
    echo "$tag"
  done < "$f"
}

tulan_k8s_normalize_version_tag() {
  local tag="$1"
  tag="${tag#rancher/rancher:}"
  tag="${tag#rancher/rancher/}"
  [[ "$tag" == v* ]] || tag="v${tag}"
  echo "$tag"
}

tulan_k8s_image_from_tag() {
  local tag
  tag="$(tulan_k8s_normalize_version_tag "$1")"
  echo "rancher/rancher:${tag}"
}

tulan_k8s_tag_from_image() {
  local image="${1:-}"
  image="${image##*:}"
  tulan_k8s_normalize_version_tag "${image:-unknown}"
}

tulan_k8s_list_upgrade_versions() {
  local f
  f="$(tulan_k8s_versions_file)"
  if [[ -f "$f" ]]; then
    tulan_k8s_read_versions_from_file "$f"
    return 0
  fi
  tulan_k8s_tag_from_image "${TULAN_K8S_UPGRADE_DEFAULT}"
}

tulan_k8s_resolve_current_image() {
  local image=""
  tulan_k8s_load_rancher_config
  image="${RANCHER_IMAGE:-}"
  if [[ -z "$image" ]] && command -v docker &>/dev/null; then
    image="$(docker inspect -f '{{.Config.Image}}' "${CONTAINER_NAME:-${TULAN_K8S_CONTAINER}}" 2>/dev/null || true)"
  fi
  echo "${image:-unknown}"
}

tulan_k8s_prompt_upgrade_image() {
  local -a versions=()
  local current_image current_tag choice i target_image target_tag default_idx=1

  if [[ -n "${RANCHER_UPGRADE_IMAGE:-}" ]]; then
    return 0
  fi

  mapfile -t versions < <(tulan_k8s_list_upgrade_versions)
  if [[ ${#versions[@]} -eq 0 ]]; then
    export RANCHER_UPGRADE_IMAGE="${TULAN_K8S_UPGRADE_DEFAULT}"
    return 0
  fi

  current_image="$(tulan_k8s_resolve_current_image)"
  current_tag="$(tulan_k8s_tag_from_image "$current_image")"

  echo ""
  echo "Rancher 升级"
  echo "────────────────────────────────────"
  echo "  当前版本: ${current_image}"
  echo ""
  echo "  可选升级版本:"
  for i in "${!versions[@]}"; do
    if [[ "$i" -eq 0 ]]; then
      echo "  [$((i + 1))] ${versions[$i]}  (推荐)"
    elif [[ "${versions[$i]}" == "$current_tag" ]]; then
      echo "  [$((i + 1))] ${versions[$i]}  ← 当前"
    else
      echo "  [$((i + 1))] ${versions[$i]}"
    fi
  done
  echo "  也可直接输入版本号（如 v2.10.0 或 rancher/rancher:v2.10.0）"
  echo ""
  echo "  版本列表: $(tulan_k8s_versions_file)"
  echo "  更新列表: brew update（随 bin 索引同步）"
  echo ""
  read -r -p "请选择升级目标 [1-${#versions[@]}] (默认 ${default_idx}): " choice
  choice="${choice:-$default_idx}"

  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#versions[@]} )); then
    target_tag="${versions[$((choice - 1))]}"
    target_image="$(tulan_k8s_image_from_tag "$target_tag")"
  elif [[ "$choice" == rancher/rancher:* ]]; then
    target_image="$choice"
    target_tag="$(tulan_k8s_tag_from_image "$target_image")"
  elif [[ -n "$choice" ]]; then
    target_tag="$(tulan_k8s_normalize_version_tag "$choice")"
    target_image="$(tulan_k8s_image_from_tag "$target_tag")"
  else
    tulan_error "无效选择: ${choice}"
    return 1
  fi

  if [[ "$target_tag" == "$current_tag" ]]; then
    tulan_log "目标版本与当前相同，将重新部署该版本"
  fi

  export RANCHER_UPGRADE_IMAGE="$target_image"
  echo ""
  echo "  升级目标: ${RANCHER_UPGRADE_IMAGE}"
  echo ""
}

tulan_k8s_export_env() {
  tulan_k8s_load_rancher_config
  if [[ -z "${K8S_SITE_DOMAIN:-}" ]]; then
    tulan_k8s_load_site_config
  fi
  export CERT_OUT="${CERT_OUT:-$TULAN_K8S_CERT_OUT}"
  export K8S_SITE_DOMAIN="${K8S_SITE_DOMAIN:-}"
  export K8S_SITE_IP="${K8S_SITE_IP:-}"
  export RANCHER_DATA="${RANCHER_DATA:-$TULAN_K8S_RANCHER_DATA}"
  export RANCHER_IMAGE="${RANCHER_IMAGE:-$TULAN_K8S_RANCHER_IMAGE}"
  export REGISTRY_MIRROR="${REGISTRY_MIRROR:-$TULAN_K8S_REGISTRY_MIRROR}"
  export CONTAINER_NAME="${CONTAINER_NAME:-$TULAN_K8S_CONTAINER}"
  export HTTP_PORT_MAP="${HTTP_PORT_MAP:-$TULAN_K8S_HTTP_PORT}"
  export HTTPS_PORT_MAP="${HTTPS_PORT_MAP:-$TULAN_K8S_HTTPS_PORT}"
  export INSTALLED_AT="${INSTALLED_AT:-}"
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
