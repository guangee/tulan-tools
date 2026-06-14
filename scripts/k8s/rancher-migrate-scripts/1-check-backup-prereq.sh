#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
用法:
  sudo bash 1-check-backup-prereq.sh

说明:
  仅做预检查，不会停止容器或修改任何数据。
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

CONTAINER_NAME="rancher"
BACKUP_DIR="/opt/rancher-backups"
DATA_DIR="/opt/rancher-data"

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 0 ]] || die "该脚本不接收参数，直接执行即可"

[[ "${EUID}" -eq 0 ]] || die "请用 root 执行"

require_cmd docker
require_cmd tar
require_cmd df

docker ps -a --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}" || die "容器不存在: ${CONTAINER_NAME}"

echo "== 预检查结果 =="
echo "容器名: ${CONTAINER_NAME}"
echo "备份目录: ${BACKUP_DIR}"
echo "数据目录: ${DATA_DIR}"
echo

echo "[1/5] 容器状态"
docker inspect -f 'running={{.State.Running}} image={{.Config.Image}}' "${CONTAINER_NAME}"
echo

echo "[2/5] 校验容器内是否存在 /var/lib/rancher"
docker exec "${CONTAINER_NAME}" sh -c 'test -d /var/lib/rancher' \
  && echo "OK: /var/lib/rancher 存在" \
  || die "容器内不存在 /var/lib/rancher"
echo

echo "[3/5] 预估数据体积"
docker exec "${CONTAINER_NAME}" sh -c 'du -sh /var/lib/rancher 2>/dev/null || true'
echo

echo "[4/5] 宿主机磁盘余量"
df -h "$(dirname "${BACKUP_DIR}")"
df -h "$(dirname "${DATA_DIR}")"
echo

echo "[5/5] 目录可创建性"
mkdir -p "${BACKUP_DIR}" "${DATA_DIR}"
echo "OK: 目录可用"
echo
echo "预检查完成：满足执行备份条件。"
