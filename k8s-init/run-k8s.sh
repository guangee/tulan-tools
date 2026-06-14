#!/usr/bin/env bash
set -euo pipefail

docker rm -f "k8s" >/dev/null 2>&1 || true
docker run -d --name "k8s" --restart=unless-stopped \
  -p "8080:80" -p "8443:443" \
  -v "/opt/rancher-data:/var/lib/rancher" \
  -v "/etc/certs/k8s.local.tulan.wang.cert:/etc/rancher/ssl/cert.pem:ro" \
  -v "/etc/certs/k8s.local.tulan.wang.key:/etc/rancher/ssl/key.pem:ro" \
  -v "/etc/certs/ca.crt:/etc/rancher/ssl/cacerts.pem:ro" \
  --privileged \
  "rancher/rancher:v2.5.17"
