#!/usr/bin/env bash
# 清理自签 CA 与站点证书（不清理 Rancher 容器与数据）
#
# 用法:
#   sudo bash ca-clean.sh
#
# 环境变量:
#   CERT_OUT=/etc/certs
set -euo pipefail

CERT_OUT="${CERT_OUT:-/etc/certs}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "请使用 root 执行：sudo bash $0"
    exit 1
  fi
}

load_domain() {
  local domain=""
  if [[ -f "${CERT_OUT}/site.env" ]]; then
    # shellcheck source=/dev/null
    source "${CERT_OUT}/site.env"
    domain="${K8S_SITE_DOMAIN:-}"
  fi
  echo "${domain:-k8s.local.tulan.wang}"
}

remove_site_files() {
  local domain="$1"
  rm -f \
    "${CERT_OUT}/${domain}.key" \
    "${CERT_OUT}/${domain}.crt" \
    "${CERT_OUT}/${domain}.csr" \
    "${CERT_OUT}/${domain}.cert"
}

main() {
  require_root

  local domain
  domain="$(load_domain)"

  log "清理证书目录: ${CERT_OUT}"
  log "站点域名: ${domain}"

  rm -f "${CERT_OUT}/ca.key" "${CERT_OUT}/ca.crt" "${CERT_OUT}/ca.srl"
  rm -f "${CERT_OUT}/v3.ext" "${CERT_OUT}/site.env"
  remove_site_files "$domain"

  # 兼容旧版默认域名
  if [[ "$domain" != "k8s.local.tulan.wang" ]]; then
    remove_site_files "k8s.local.tulan.wang"
  fi

  if [[ -f /usr/local/share/ca-certificates/tulan-ca.crt ]]; then
    rm -f /usr/local/share/ca-certificates/tulan-ca.crt
    update-ca-certificates 2>/dev/null || true
    log "已从系统信任链移除 tulan CA"
  fi

  log "证书清理完成。如需重装请执行: brew k8s ca"
}

main "$@"
