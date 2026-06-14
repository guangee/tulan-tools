#!/usr/bin/env bash
set -euo pipefail

# 用法:
#   bash sync-registries.sh -f nodes.txt
#   bash sync-registries.sh -f nodes.txt -u root -p 22
#   bash sync-registries.sh -f nodes.txt --no-restart
#
# nodes.txt 每行一个节点（支持 IP/域名，允许 user@host 格式）:
#   192.168.20.101
#   root@192.168.20.102
#   node3.example.com
#
# 可通过环境变量传递代理参数，例如:
#   export SSH_COMMON_ARGS='-o ProxyCommand="nc -x 127.0.0.1:7890 %h %p"'

NODES_FILE=""
SSH_USER="root"
SSH_PORT="22"
LOCAL_FILE="/etc/certs/registries.yaml"
REMOTE_FILE="/etc/rancher/rke2/registries.yaml"
RESTART_SERVICE="yes"
SSH_COMMON_ARGS="${SSH_COMMON_ARGS:-}"

usage() {
  cat <<'EOF'
同步 /etc/certs/registries.yaml 到所有节点

参数:
  -f, --file <path>       节点清单文件（必填）
  -u, --user <name>       SSH 用户名（默认: root）
  -p, --port <port>       SSH 端口（默认: 22）
  -l, --local <path>      本地 registries.yaml 路径（默认: /etc/certs/registries.yaml）
  -r, --remote <path>     远程目标路径（默认: /etc/rancher/rke2/registries.yaml）
      --no-restart        不重启远程服务
  -h, --help              查看帮助

环境变量:
  SSH_COMMON_ARGS         额外 SSH 参数（例如代理、跳板机配置）

示例:
  bash sync-registries.sh -f nodes.txt
  SSH_COMMON_ARGS='-o ProxyJump=bastion' bash sync-registries.sh -f nodes.txt
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--file)
        NODES_FILE="${2:-}"
        shift 2
        ;;
      -u|--user)
        SSH_USER="${2:-}"
        shift 2
        ;;
      -p|--port)
        SSH_PORT="${2:-}"
        shift 2
        ;;
      -l|--local)
        LOCAL_FILE="${2:-}"
        shift 2
        ;;
      -r|--remote)
        REMOTE_FILE="${2:-}"
        shift 2
        ;;
      --no-restart)
        RESTART_SERVICE="no"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "未知参数: $1"
        usage
        exit 1
        ;;
    esac
  done
}

validate() {
  [[ -n "${NODES_FILE}" ]] || { echo "必须指定节点文件: -f nodes.txt"; exit 1; }
  [[ -f "${NODES_FILE}" ]] || { echo "节点文件不存在: ${NODES_FILE}"; exit 1; }
  [[ -f "${LOCAL_FILE}" ]] || { echo "本地文件不存在: ${LOCAL_FILE}"; exit 1; }
}

restart_remote_service() {
  local host="$1"
  local remote_cmd='if sudo systemctl status rke2-agent >/dev/null 2>&1; then sudo systemctl restart rke2-agent; elif sudo systemctl status k3s-agent >/dev/null 2>&1; then sudo systemctl restart k3s-agent; elif sudo systemctl status k3s >/dev/null 2>&1; then sudo systemctl restart k3s; elif sudo systemctl status rke2-server >/dev/null 2>&1; then sudo systemctl restart rke2-server; else echo "未检测到 rke2/k3s 服务，跳过重启"; fi'
  ssh -n -p "${SSH_PORT}" ${SSH_COMMON_ARGS} "${host}" "${remote_cmd}" < /dev/null
}

sync_one() {
  local raw="$1"
  local node host
  node="$(echo "${raw}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "${node}" || "${node}" == \#* ]] && return 0

  if [[ "${node}" == *"@"* ]]; then
    host="${node}"
  else
    host="${SSH_USER}@${node}"
  fi

  log "同步到 ${host}"
  ssh -n -p "${SSH_PORT}" ${SSH_COMMON_ARGS} "${host}" "sudo mkdir -p \"$(dirname "${REMOTE_FILE}")\"" < /dev/null
  scp -P "${SSH_PORT}" ${SSH_COMMON_ARGS} "${LOCAL_FILE}" "${host}:/tmp/registries.yaml" < /dev/null
  ssh -n -p "${SSH_PORT}" ${SSH_COMMON_ARGS} "${host}" "sudo mv /tmp/registries.yaml \"${REMOTE_FILE}\" && sudo chmod 0644 \"${REMOTE_FILE}\"" < /dev/null

  if [[ "${RESTART_SERVICE}" == "yes" ]]; then
    log "重启服务 ${host}"
    restart_remote_service "${host}"
  fi

  log "完成 ${host}"
}

main() {
  parse_args "$@"
  validate

  while IFS= read -r line || [[ -n "${line}" ]]; do
    sync_one "${line}"
  done < "${NODES_FILE}"

  log "全部节点同步完成"
}

main "$@"
