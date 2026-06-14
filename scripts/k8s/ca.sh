#!/usr/bin/env bash
# 生成自签 CA 与 Rancher 站点证书
#
# 用法:
#   sudo bash ca.sh
#
# 环境变量（通常由 brew k8s ca 交互传入）:
#   CERT_OUT=/etc/certs
#   K8S_SITE_DOMAIN=k8s.local.example.com
#   K8S_SITE_IP=192.168.1.100
set -euo pipefail

CERT_OUT="${CERT_OUT:-/etc/certs}"
K8S_SITE_DOMAIN="${K8S_SITE_DOMAIN:-k8s.local.tulan.wang}"
K8S_SITE_IP="${K8S_SITE_IP:-}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "请使用 root 执行：sudo bash $0"
    exit 1
  fi
}

validate_domain() {
  if [[ ! "$K8S_SITE_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
    echo "无效域名: ${K8S_SITE_DOMAIN}"
    exit 1
  fi
}

write_site_env() {
  cat > "${CERT_OUT}/site.env" <<EOF
# 由 brew k8s ca 生成，install 等脚本会读取
K8S_SITE_DOMAIN=${K8S_SITE_DOMAIN}
K8S_SITE_IP=${K8S_SITE_IP}
EOF
  chmod 644 "${CERT_OUT}/site.env"
}

main() {
  require_root
  validate_domain

  mkdir -p "${CERT_OUT}"
  cd "${CERT_OUT}"

  log "生成 CA（域名: ${K8S_SITE_DOMAIN}）"
  [[ -n "$K8S_SITE_IP" ]] && log "SAN IP: ${K8S_SITE_IP}"

  openssl genrsa -out ca.key 4096

  openssl req -x509 -new -nodes -sha512 -days 3650 \
    -subj "/C=CN/ST=Beijing/L=Beijing/O=tulan/OU=Personal/CN=tulan.wang" \
    -key ca.key \
    -out ca.crt

  openssl genrsa -out "${K8S_SITE_DOMAIN}.key" 4096

  openssl req -sha512 -new \
    -subj "/C=CN/ST=Zhengzhou/L=Zhengzhou/O=tulan/OU=Personal/CN=${K8S_SITE_DOMAIN}" \
    -key "${K8S_SITE_DOMAIN}.key" \
    -out "${K8S_SITE_DOMAIN}.csr"

  cat > v3.ext <<-EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1=${K8S_SITE_DOMAIN}
EOF

  if [[ -n "$K8S_SITE_IP" ]]; then
    echo "IP.1 = ${K8S_SITE_IP}" >> v3.ext
  fi

  openssl x509 -req -sha512 -days 36500 \
    -extfile v3.ext \
    -CA ca.crt -CAkey ca.key -CAcreateserial \
    -in "${K8S_SITE_DOMAIN}.csr" \
    -out "${K8S_SITE_DOMAIN}.crt"

  openssl x509 -inform PEM -in "${K8S_SITE_DOMAIN}.crt" -out "${K8S_SITE_DOMAIN}.cert"

  cp ca.crt /usr/local/share/ca-certificates/tulan-ca.crt
  update-ca-certificates

  chmod 600 "${K8S_SITE_DOMAIN}.key"
  chmod 644 ca.crt "${K8S_SITE_DOMAIN}.crt" "${K8S_SITE_DOMAIN}.cert"

  write_site_env

  log "证书已写入 ${CERT_OUT}/"
  log "  CA:   ca.crt / ca.key"
  log "  站点: ${K8S_SITE_DOMAIN}.crt / ${K8S_SITE_DOMAIN}.key"
  log "  配置: site.env"
  log "请将 ${K8S_SITE_DOMAIN} 解析到本机（hosts 或 DNS）后执行 brew k8s install"
}

main "$@"
