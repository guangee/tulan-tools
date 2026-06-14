#!/usr/bin/env bash
# 清理自签 CA 与站点证书（不清理 Rancher 容器与数据）
#
# 用法:
#   sudo bash ca-clean.sh
#
# 环境变量:
#   CERT_OUT=/etc/certs
#   K8S_CLEAN_DOMAINS="domain1 domain2" | __ca_only__
#   K8S_CLEAN_INCLUDE_CA=true   同时清理 CA（选「全部」时由 brew 传入）
set -euo pipefail

CERT_OUT="${CERT_OUT:-/etc/certs}"
K8S_CLEAN_DOMAINS="${K8S_CLEAN_DOMAINS:-}"
K8S_CLEAN_INCLUDE_CA="${K8S_CLEAN_INCLUDE_CA:-false}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "请使用 root 执行：sudo bash $0"
    exit 1
  fi
}

list_cert_domains() {
  local f domain
  for f in "${CERT_OUT}"/*.crt; do
    [[ -f "$f" ]] || continue
    domain="$(basename "$f" .crt)"
    [[ "$domain" == "ca" ]] && continue
    echo "$domain"
  done
}

has_ca_files() {
  [[ -f "${CERT_OUT}/ca.crt" || -f "${CERT_OUT}/ca.key" ]]
}

remove_site_files() {
  local domain="$1"
  rm -f \
    "${CERT_OUT}/${domain}.key" \
    "${CERT_OUT}/${domain}.crt" \
    "${CERT_OUT}/${domain}.csr" \
    "${CERT_OUT}/${domain}.cert"
}

remove_ca_files() {
  rm -f "${CERT_OUT}/ca.key" "${CERT_OUT}/ca.crt" "${CERT_OUT}/ca.srl"
  rm -f "${CERT_OUT}/v3.ext"

  if [[ -f /usr/local/share/ca-certificates/tulan-ca.crt ]]; then
    rm -f /usr/local/share/ca-certificates/tulan-ca.crt
    update-ca-certificates 2>/dev/null || true
    log "已从系统信任链移除 tulan CA"
  fi
}

maybe_remove_site_env() {
  local domain="$1" env_domain="" rancher_domain=""
  [[ -f "${CERT_OUT}/site.env" ]] || true
  if [[ -f "${CERT_OUT}/site.env" ]]; then
    # shellcheck source=/dev/null
    source "${CERT_OUT}/site.env"
    env_domain="${K8S_SITE_DOMAIN:-}"
    if [[ "$domain" == "$env_domain" ]]; then
      rm -f "${CERT_OUT}/site.env"
      log "已移除 site.env"
    fi
  fi
  if [[ -f "${CERT_OUT}/rancher.env" ]]; then
    # shellcheck source=/dev/null
    source "${CERT_OUT}/rancher.env"
    rancher_domain="${K8S_SITE_DOMAIN:-}"
    if [[ "$domain" == "$rancher_domain" ]]; then
      rm -f "${CERT_OUT}/rancher.env"
      log "已移除 rancher.env（部署记录）"
    fi
  fi
}

clean_domains() {
  local domain
  for domain in "$@"; do
    log "清理站点证书: ${domain}"
    remove_site_files "$domain"
    maybe_remove_site_env "$domain"
  done
}

main() {
  require_root

  if [[ -z "$K8S_CLEAN_DOMAINS" ]]; then
    echo "未指定要清理的域名，请通过 brew k8s ca-clean 交互选择"
    exit 1
  fi

  log "清理证书目录: ${CERT_OUT}"

  if [[ "$K8S_CLEAN_DOMAINS" == "__ca_only__" ]]; then
    if has_ca_files; then
      log "清理 CA"
      remove_ca_files
    else
      log "未发现 CA 文件"
    fi
    log "证书清理完成"
    exit 0
  fi

  # shellcheck disable=SC2086
  clean_domains ${K8S_CLEAN_DOMAINS}

  if [[ "$K8S_CLEAN_INCLUDE_CA" == true ]]; then
    log "清理 CA"
    remove_ca_files
    rm -f "${CERT_OUT}/site.env" "${CERT_OUT}/rancher.env"
  else
    # 若无剩余站点证书，一并清理 CA
    if [[ -z "$(list_cert_domains)" ]] && has_ca_files; then
      log "已无站点证书，一并清理 CA"
      remove_ca_files
      rm -f "${CERT_OUT}/site.env" "${CERT_OUT}/rancher.env"
    fi
  fi

  log "证书清理完成。如需重装请执行: brew k8s ca"
}

main "$@"
