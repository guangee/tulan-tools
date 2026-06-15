#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# 证书：生成、清理、安装选择
tulan_k8s_list_usable_cert_domains() {
  local domain
  while read -r domain; do
    [[ -f "${TULAN_K8S_CERT_OUT}/${domain}.crt" && -f "${TULAN_K8S_CERT_OUT}/${domain}.key" ]] && echo "$domain"
  done < <(tulan_k8s_list_cert_domains)
}
tulan_k8s_list_cert_domains() {
  local cert_out="${TULAN_K8S_CERT_OUT}" f domain
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
