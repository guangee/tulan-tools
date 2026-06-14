#!/usr/bin/env bash
CERT_OUT="${CERT_OUT:-/etc/certs}"

mkdir -p "${CERT_OUT}"
cd "${CERT_OUT}"

openssl genrsa -out ca.key 4096

openssl req -x509 -new -nodes -sha512 -days 3650 \
  -subj "/C=CN/ST=Beijing/L=Beijing/O=tulan/OU=Personal/CN=tulan.wang" \
  -key ca.key \
  -out ca.crt

openssl genrsa -out k8s.local.tulan.wang.key 4096

openssl req -sha512 -new \
  -subj "/C=CN/ST=Zhengzhou/L=Zhengzhou/O=tulan/OU=Personal/CN=k8s.local.tulan.wang" \
  -key k8s.local.tulan.wang.key \
  -out k8s.local.tulan.wang.csr

cat > v3.ext <<-EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1=k8s.local.tulan.wang

IP.1 = 192.168.20.250
EOF

openssl x509 -req -sha512 -days 36500 \
  -extfile v3.ext \
  -CA ca.crt -CAkey ca.key -CAcreateserial \
  -in k8s.local.tulan.wang.csr \
  -out k8s.local.tulan.wang.crt

# 与旧脚本兼容的副本（PEM）；Rancher 挂载使用下面的 .crt / .key / ca.crt
openssl x509 -inform PEM -in k8s.local.tulan.wang.crt -out k8s.local.tulan.wang.cert

cp ca.crt /usr/local/share/ca-certificates/tulan-ca.crt
update-ca-certificates

chmod 600 k8s.local.tulan.wang.key
chmod 644 ca.crt k8s.local.tulan.wang.crt k8s.local.tulan.wang.cert