#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
用法:
  sudo bash 3-generate-new-run-script.sh

说明:
  固定读取旧容器 rancher，生成新容器 k8s 的启动脚本（映射 /opt/rancher-data）。
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

CONTAINER_NAME="rancher"
NEW_NAME="k8s"
DATA_DIR="/opt/rancher-data"
OUTPUT="/etc/certs/rancher-migrate-scripts/run-k8s.sh"

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 0 ]] || die "该脚本不接收参数，直接执行即可"

[[ "${EUID}" -eq 0 ]] || die "请用 root 执行"
command -v docker >/dev/null 2>&1 || die "缺少 docker"

docker ps -a --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}" || die "容器不存在: ${CONTAINER_NAME}"

IMAGE="$(docker inspect -f '{{.Config.Image}}' "${CONTAINER_NAME}")"

HTTP_MAP="$(docker port "${CONTAINER_NAME}" 80/tcp 2>/dev/null | head -n 1 || true)"
HTTPS_MAP="$(docker port "${CONTAINER_NAME}" 443/tcp 2>/dev/null | head -n 1 || true)"

HTTP_PORT="8080:80"
HTTPS_PORT="8443:443"

if [[ -n "${HTTP_MAP}" ]]; then
  host_port="${HTTP_MAP##*:}"
  HTTP_PORT="${host_port}:80"
fi
if [[ -n "${HTTPS_MAP}" ]]; then
  host_port="${HTTPS_MAP##*:}"
  HTTPS_PORT="${host_port}:443"
fi

CERT_SRC="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/rancher/ssl/cert.pem"}}{{.Source}}{{end}}{{end}}' "${CONTAINER_NAME}")"
KEY_SRC="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/rancher/ssl/key.pem"}}{{.Source}}{{end}}{{end}}' "${CONTAINER_NAME}")"
CA_SRC="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/rancher/ssl/cacerts.pem"}}{{.Source}}{{end}}{{end}}' "${CONTAINER_NAME}")"

mkdir -p "$(dirname "${OUTPUT}")" "${DATA_DIR}"

cat > "${OUTPUT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

docker rm -f "${NEW_NAME}" >/dev/null 2>&1 || true
docker run -d --name "${NEW_NAME}" --restart=unless-stopped \\
  -p "${HTTP_PORT}" -p "${HTTPS_PORT}" \\
  -v "${DATA_DIR}:/var/lib/rancher" \\
EOF

if [[ -n "${CERT_SRC}" ]]; then
  echo "  -v \"${CERT_SRC}:/etc/rancher/ssl/cert.pem:ro\" \\" >> "${OUTPUT}"
fi
if [[ -n "${KEY_SRC}" ]]; then
  echo "  -v \"${KEY_SRC}:/etc/rancher/ssl/key.pem:ro\" \\" >> "${OUTPUT}"
fi
if [[ -n "${CA_SRC}" ]]; then
  echo "  -v \"${CA_SRC}:/etc/rancher/ssl/cacerts.pem:ro\" \\" >> "${OUTPUT}"
fi

cat >> "${OUTPUT}" <<EOF
  --privileged \\
  "${IMAGE}"
EOF

chmod +x "${OUTPUT}"

echo "启动脚本已生成: ${OUTPUT}"
echo "镜像: ${IMAGE}"
echo "端口: ${HTTP_PORT}, ${HTTPS_PORT}"
echo "数据目录: ${DATA_DIR}"
