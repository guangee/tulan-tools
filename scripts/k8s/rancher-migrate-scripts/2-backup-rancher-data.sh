#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
用法:
  sudo bash 2-backup-rancher-data.sh

说明:
  固定备份容器 rancher，并停止后执行一致性备份。
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

CONTAINER_NAME="rancher"
BACKUP_DIR="/opt/rancher-backups"

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -eq 0 ]] || die "该脚本不接收参数，直接执行即可"

[[ "${EUID}" -eq 0 ]] || die "请用 root 执行"
command -v docker >/dev/null 2>&1 || die "缺少 docker"

docker ps -a --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}" || die "容器不存在: ${CONTAINER_NAME}"

ts="$(date '+%Y%m%d-%H%M%S')"
work_dir="${BACKUP_DIR}/${CONTAINER_NAME}-${ts}"
tar_file="${work_dir}/rancher-var-lib-rancher.tar.gz"

mkdir -p "${work_dir}"

echo "[1/5] 保存容器元信息 -> ${work_dir}/container-inspect.json"
docker inspect "${CONTAINER_NAME}" > "${work_dir}/container-inspect.json"

if [[ "$(docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}")" == "true" ]]; then
  echo "[2/5] 停止容器 ${CONTAINER_NAME}（确保备份一致性）"
  docker stop "${CONTAINER_NAME}" >/dev/null
else
  echo "[2/5] 容器已停止，跳过"
fi

echo "[3/5] 导出 /var/lib/rancher -> ${tar_file}"
docker run --rm --volumes-from "${CONTAINER_NAME}" \
  -v "${work_dir}:/backup" \
  alpine:3.20 \
  sh -c 'tar czf /backup/rancher-var-lib-rancher.tar.gz -C / var/lib/rancher'

echo "[4/5] 校验备份文件"
test -s "${tar_file}" || die "备份文件为空: ${tar_file}"
ls -lh "${tar_file}"

echo "[5/5] 生成恢复参考"
cat > "${work_dir}/restore-note.txt" <<EOF
恢复参考:
1) mkdir -p /opt/rancher-data
2) tar xzf ${tar_file} -C /tmp
3) cp -a /tmp/var/lib/rancher/. /opt/rancher-data/
4) 用 -v /opt/rancher-data:/var/lib/rancher 方式重启 Rancher
EOF

echo
echo "备份完成: ${work_dir}"
echo "注意: 原容器当前保持停止状态，请在验证新容器方案后再决定是否启动旧容器。"
