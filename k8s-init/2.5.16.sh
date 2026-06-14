#!/usr/bin/env bash
# Rancher v2.5.16 数据迁移脚本（容器内数据 -> 宿主机目录映射）
# 目标：
# 1) 备份旧容器内 /var/lib/rancher
# 2) 以同版本 v2.5.16 重新启动，并挂载宿主机数据目录
#
# 使用方式（建议 root）：
#   sudo bash 2.5.16.sh
#   sudo bash 2.5.16.sh --check-only
#
# 可选环境变量：
#   OLD_CONTAINER_NAME=rancher-old
#   NEW_CONTAINER_NAME=rancher
#   RANCHER_IMAGE=rancher/rancher:v2.5.16
#   RANCHER_DATA=/opt/rancher-data
#   BACKUP_DIR=/opt/rancher-backups
#   HTTP_PORT_MAP=8080:80
#   HTTPS_PORT_MAP=8443:443
#   CERT_PEM=/etc/certs/k8s.guanweiming.com.cert
#   KEY_PEM=/etc/certs/k8s.guanweiming.com.key
#   CACERTS_PEM=/etc/certs/ca.crt
set -euo pipefail

CHECK_ONLY=false
OLD_CONTAINER_NAME="${OLD_CONTAINER_NAME:-rancher-old}"
NEW_CONTAINER_NAME="${NEW_CONTAINER_NAME:-rancher}"
RANCHER_IMAGE="${RANCHER_IMAGE:-rancher/rancher:v2.5.16}"
RANCHER_DATA="${RANCHER_DATA:-/opt/rancher-data}"
BACKUP_DIR="${BACKUP_DIR:-/opt/rancher-backups}"
HTTP_PORT_MAP="${HTTP_PORT_MAP:-8080:80}"
HTTPS_PORT_MAP="${HTTPS_PORT_MAP:-8443:443}"
CERT_PEM="${CERT_PEM:-/etc/certs/k8s.guanweiming.com.cert}"
KEY_PEM="${KEY_PEM:-/etc/certs/k8s.guanweiming.com.key}"
CACERTS_PEM="${CACERTS_PEM:-/etc/certs/ca.crt}"

timestamp="$(date '+%Y%m%d-%H%M%S')"
work_dir="${BACKUP_DIR}/${timestamp}"
tar_file="${work_dir}/rancher-var-lib-rancher.tar.gz"

usage() {
  cat <<EOF
用法:
  sudo bash $0 [--check-only]

选项:
  --check-only   仅做预检查，不执行停机、备份和重启动作
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "请使用 root 执行：sudo bash $0"
  fi
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "缺少命令: ${cmd}"
}

check_files() {
  [[ -f "${CERT_PEM}" ]] || die "证书不存在: ${CERT_PEM}"
  [[ -f "${KEY_PEM}" ]] || die "私钥不存在: ${KEY_PEM}"
  [[ -f "${CACERTS_PEM}" ]] || die "CA 证书不存在: ${CACERTS_PEM}"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check-only)
        CHECK_ONLY=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "未知参数: $1（可用: --check-only）"
        ;;
    esac
  done
}

resolve_source_container() {
  if docker ps -a --format '{{.Names}}' | grep -Fxq "${NEW_CONTAINER_NAME}"; then
    SRC_CONTAINER="${NEW_CONTAINER_NAME}"
    return
  fi
  if docker ps -a --format '{{.Names}}' | grep -Fxq "${OLD_CONTAINER_NAME}"; then
    SRC_CONTAINER="${OLD_CONTAINER_NAME}"
    return
  fi
  die "未找到旧 Rancher 容器（尝试了 ${NEW_CONTAINER_NAME} 和 ${OLD_CONTAINER_NAME}）"
}

backup_container_metadata() {
  mkdir -p "${work_dir}"
  log "备份容器元信息到 ${work_dir}"
  docker inspect "${SRC_CONTAINER}" > "${work_dir}/container-inspect.json"
}

stop_old_container() {
  if [[ "$(docker inspect -f '{{.State.Running}}' "${SRC_CONTAINER}")" == "true" ]]; then
    log "停止旧容器 ${SRC_CONTAINER}（进入维护窗口）"
    docker stop "${SRC_CONTAINER}" >/dev/null
  else
    log "旧容器 ${SRC_CONTAINER} 已停止，跳过 stop"
  fi
}

backup_and_extract_data() {
  local extract_dir="${work_dir}/extract"
  mkdir -p "${RANCHER_DATA}"
  chmod 700 "${RANCHER_DATA}" || true

  log "从 ${SRC_CONTAINER} 打包 /var/lib/rancher -> ${tar_file}"
  docker run --rm --volumes-from "${SRC_CONTAINER}" \
    -v "${work_dir}:/backup" \
    alpine:3.20 \
    sh -c 'tar czf /backup/rancher-var-lib-rancher.tar.gz -C / var/lib/rancher'

  log "解压到临时目录并同步到 ${RANCHER_DATA}"
  rm -rf "${extract_dir}"
  mkdir -p "${extract_dir}"
  tar xzf "${tar_file}" -C "${extract_dir}"
  rm -rf "${RANCHER_DATA:?}/"*
  cp -a "${extract_dir}/var/lib/rancher/." "${RANCHER_DATA}/"
}

remove_name_conflict() {
  if docker ps -a --format '{{.Names}}' | grep -Fxq "${NEW_CONTAINER_NAME}"; then
    log "删除同名容器 ${NEW_CONTAINER_NAME}"
    docker rm "${NEW_CONTAINER_NAME}" >/dev/null
  fi
}

start_new_container() {
  log "拉取镜像 ${RANCHER_IMAGE}"
  docker pull "${RANCHER_IMAGE}" >/dev/null

  log "以数据目录映射方式启动新容器 ${NEW_CONTAINER_NAME}"
  docker run -d --name "${NEW_CONTAINER_NAME}" --restart=unless-stopped \
    -p "${HTTP_PORT_MAP}" -p "${HTTPS_PORT_MAP}" \
    -v "${RANCHER_DATA}:/var/lib/rancher" \
    -v "${CERT_PEM}:/etc/rancher/ssl/cert.pem:ro" \
    -v "${KEY_PEM}:/etc/rancher/ssl/key.pem:ro" \
    -v "${CACERTS_PEM}:/etc/rancher/ssl/cacerts.pem:ro" \
    --privileged \
    "${RANCHER_IMAGE}" >/dev/null
}

show_status() {
  log "当前容器状态："
  docker ps --filter "name=${NEW_CONTAINER_NAME}" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
  log "数据目录：${RANCHER_DATA}"
  log "备份目录：${work_dir}"
}

rollback_hint() {
  cat <<EOF

回滚说明（如启动异常）：
1) docker rm -f ${NEW_CONTAINER_NAME}
2) docker start ${SRC_CONTAINER}

EOF
}

main() {
  parse_args "$@"
  require_root
  require_cmd docker
  require_cmd tar
  check_files
  resolve_source_container

  log "源容器：${SRC_CONTAINER}"
  log "目标容器：${NEW_CONTAINER_NAME}"
  log "目标镜像：${RANCHER_IMAGE}"
  log "数据目录：${RANCHER_DATA}"
  log "备份目录：${work_dir}"
  log "端口映射：${HTTP_PORT_MAP}, ${HTTPS_PORT_MAP}"

  if [[ "${CHECK_ONLY}" == "true" ]]; then
    log "预检查通过。当前为 --check-only 模式，不会执行任何变更。"
    exit 0
  fi

  backup_container_metadata
  stop_old_container
  backup_and_extract_data
  remove_name_conflict
  start_new_container
  show_status
  rollback_hint
}

main "$@"
