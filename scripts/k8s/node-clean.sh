#!/usr/bin/env bash
# 清理 Rancher 节点本地注册数据（system-agent + rke2/k3s），便于重新注册
#
# 用法（在待清理的 node 节点上执行）:
#   sudo brew k8s node-clean
#   sudo brew k8s node-clean -y
#   sudo brew k8s node-clean --keep-server -y   # Server 主机兼节点
#
# 不会清理: Rancher Server 容器、/opt/rancher-data、/etc/certs
# 完整清理（含 Server）请用: brew k8s clean

set -euo pipefail

NODE_CLEAN_YES="${TULAN_K8S_NODE_CLEAN_YES:-false}"
NODE_CLEAN_KEEP_SERVER="${TULAN_K8S_NODE_CLEAN_KEEP_SERVER:-false}"
RANCHER_DATA="${RANCHER_DATA:-/opt/rancher-data}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "请使用 root 执行：sudo brew k8s node-clean"
    exit 1
  fi
}

require_linux() {
  if [[ "$(uname -s | tr '[:upper:]' '[:lower:]')" != "linux" ]]; then
    echo "node-clean 仅支持 Linux 节点"
    exit 1
  fi
}

detect_rancher_server_containers() {
  local name
  if ! command -v docker &>/dev/null; then
    return 0
  fi
  while read -r name; do
    [[ -n "$name" ]] || continue
    if docker inspect -f '{{.Config.Image}}' "$name" 2>/dev/null | grep -qi 'rancher/rancher'; then
      echo "$name"
    fi
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null || true)
}

guard_rancher_server() {
  local names name
  names="$(detect_rancher_server_containers)"
  [[ -n "$names" ]] || return 0

  if [[ "$NODE_CLEAN_KEEP_SERVER" == true ]]; then
    log "检测到 Rancher Server 容器（--keep-server）:"
    while read -r name; do
      [[ -n "$name" ]] || continue
      log "  保留: ${name}"
    done <<< "$names"
    log "仅清理本机 node agent/rke2；Server 数据目录 ${RANCHER_DATA} 不会删除"
    return 0
  fi

  name="$(printf '%s\n' "$names" | head -n 1)"
  echo "错误: 检测到 Rancher Server 容器「${name}」。"
  echo "node-clean 默认用于纯 worker/bootstrap 节点。"
  echo ""
  echo "若本机同时作为集群节点（Server + node），请使用:"
  echo "  brew k8s node-clean --keep-server -y"
  echo ""
  echo "若需完整清理含 Rancher Server，请使用: brew k8s clean"
  exit 1
}

confirm_clean() {
  if [[ "$NODE_CLEAN_YES" == true ]]; then
    return 0
  fi
  echo ""
  echo "将清理本机 Rancher 节点注册数据（system-agent / rke2 / k3s）"
  echo "────────────────────────────────────"
  echo "  停止并卸载: rancher-system-agent, rke2-*, k3s-*"
  echo "  删除目录:   /etc/rancher, /var/lib/rancher（主机）, kubelet/CNI 等"
  if [[ "$NODE_CLEAN_KEEP_SERVER" == true ]]; then
    echo "  保留:       Rancher Server 容器、${RANCHER_DATA}、Docker 服务、/etc/certs"
  else
    echo "  保留:       Docker 服务、/etc/certs、Rancher Server 数据（若有独立目录）"
  fi
  echo ""
  echo "  清理后请在 Rancher UI 删除失败节点，再执行新的注册命令。"
  echo ""
  read -r -p "确认清理本机节点? [y/N]: " confirm
  [[ "$confirm" =~ ^[yY]$ ]]
}

stop_services() {
  log "停止节点 Agent / K8s 运行时服务"
  for svc in rancher-system-agent rke2-server rke2-agent k3s k3s-agent kubelet; do
    systemctl stop "${svc}" 2>/dev/null || true
    systemctl disable "${svc}" 2>/dev/null || true
  done
}

run_uninstall_scripts() {
  log "执行官方卸载脚本（若存在）"
  [[ -x /usr/local/bin/rancher-system-agent-uninstall.sh ]] \
    && /usr/local/bin/rancher-system-agent-uninstall.sh || true
  [[ -x /usr/local/bin/rke2-killall.sh ]] && /usr/local/bin/rke2-killall.sh || true
  [[ -x /usr/local/bin/rke2-uninstall.sh ]] && /usr/local/bin/rke2-uninstall.sh || true
  [[ -x /usr/local/bin/k3s-killall.sh ]] && /usr/local/bin/k3s-killall.sh || true
  [[ -x /usr/local/bin/k3s-uninstall.sh ]] && /usr/local/bin/k3s-uninstall.sh || true
}

remove_docker_agents() {
  local name
  if ! command -v docker &>/dev/null; then
    return 0
  fi
  log "删除 rancher-agent 等旧版容器（如有）"
  while read -r name; do
    [[ -n "$name" ]] || continue
    docker rm -f "$name" 2>/dev/null || true
  done < <(docker ps -aq --filter name=rancher-agent --filter name=cattle-agent 2>/dev/null || true)
}

cleanup_mounts() {
  log "卸载 K8s 相关挂载"
  while read -r mnt; do
    umount -lf "${mnt}" 2>/dev/null || true
  done < <(mount | awk '/rke2|k3s|kubelet|containerd\/.*pods|cni/ {print $3}' | sort -r)
}

cleanup_network() {
  log "清理 CNI 网卡"
  ip link del cni0 2>/dev/null || true
  ip link del flannel.1 2>/dev/null || true
  ip link del flannel-v6.1 2>/dev/null || true
  ip link del kube-ipvs0 2>/dev/null || true
}

cleanup_iptables() {
  log "清理 KUBE/CNI 相关 iptables 链"
  local table chain
  for table in nat filter mangle raw; do
    iptables -t "${table}" -S 2>/dev/null | awk '/KUBE-|CALI-|CILIUM|FLANNEL/ {print $2}' | sort -u \
      | while read -r chain; do
          [[ -n "$chain" ]] || continue
          iptables -t "${table}" -F "${chain}" 2>/dev/null || true
          iptables -t "${table}" -X "${chain}" 2>/dev/null || true
        done
    ip6tables -t "${table}" -S 2>/dev/null | awk '/KUBE-|CALI-|CILIUM|FLANNEL/ {print $2}' | sort -u \
      | while read -r chain; do
          [[ -n "$chain" ]] || continue
          ip6tables -t "${table}" -F "${chain}" 2>/dev/null || true
          ip6tables -t "${table}" -X "${chain}" 2>/dev/null || true
        done
  done
}

remove_data_dirs() {
  log "删除节点注册与运行时数据目录（主机路径，不含 ${RANCHER_DATA}）"
  rm -rf /etc/rancher
  rm -rf /var/lib/rancher
  rm -rf /var/lib/kubelet
  rm -rf /var/lib/cni
  rm -rf /etc/cni
  rm -rf /opt/cni
  rm -rf /run/flannel
  rm -rf /var/log/containers
  rm -rf /var/log/pods
}

main() {
  require_linux
  require_root
  guard_rancher_server
  confirm_clean || { log "已取消"; exit 0; }

  stop_services
  run_uninstall_scripts
  remove_docker_agents
  cleanup_mounts
  cleanup_network
  cleanup_iptables
  remove_data_dirs

  log "节点清理完成"
  log "下一步:"
  log "  1. 在 Rancher UI 删除该失败节点（若仍存在）"
  log "  2. brew k8s register-command --format command -c <集群名>"
  log "  3. 在节点上执行注册命令"
  if [[ "$NODE_CLEAN_KEEP_SERVER" == true ]]; then
    log "  Rancher Server 容器未受影响，可继续访问 UI"
  fi
  log "建议 reboot 后再注册（可选）"
}

main "$@"
