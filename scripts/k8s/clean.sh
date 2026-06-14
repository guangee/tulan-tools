#!/usr/bin/env bash
# Rancher/K8s 清理脚本（Docker 方式）
# 用法:
#   sudo bash clean.sh
#
# 可选变量:
#   RANCHER_DATA=/opt/rancher-data
set -euo pipefail

RANCHER_DATA="${RANCHER_DATA:-/opt/rancher-data}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "请使用 root 执行：sudo bash $0"
    exit 1
  fi
}

main() {
  require_root

  log "停止常见 K8s/Rancher 相关服务"
  for svc in \
    rancher-system-agent rke2-server rke2-agent \
    k3s k3s-agent kubelet containerd docker; do
    systemctl stop "${svc}" 2>/dev/null || true
  done

  log "执行可能存在的卸载脚本"
  [[ -x /usr/local/bin/rancher-system-agent-uninstall.sh ]] && /usr/local/bin/rancher-system-agent-uninstall.sh || true
  [[ -x /usr/local/bin/rke2-uninstall.sh ]] && /usr/local/bin/rke2-uninstall.sh || true
  [[ -x /usr/local/bin/rke2-killall.sh ]] && /usr/local/bin/rke2-killall.sh || true
  [[ -x /usr/local/bin/k3s-uninstall.sh ]] && /usr/local/bin/k3s-uninstall.sh || true
  [[ -x /usr/local/bin/k3s-killall.sh ]] && /usr/local/bin/k3s-killall.sh || true

  log "删除 Rancher/K8s 相关容器"
  mapfile -t containers < <(docker ps -aq --filter name=rancher --filter name=cattle --filter name=rke2 --filter name=k3s 2>/dev/null || true)
  if [[ "${#containers[@]}" -gt 0 ]]; then
    docker rm -f "${containers[@]}" || true
  fi

  log "结束残留进程"
  pkill -9 -f 'rancher|rke2|k3s|kubelet|containerd|etcd' 2>/dev/null || true

  log "卸载残留挂载点"
  while read -r mnt; do
    umount -lf "${mnt}" 2>/dev/null || true
  done < <(mount | awk '/rke2|k3s|kubelet|containerd|pods|cni/ {print $3}' | sort -r)

  log "清理 CNI 相关网卡"
  ip link del cni0 2>/dev/null || true
  ip link del flannel.1 2>/dev/null || true
  ip link del flannel-v6.1 2>/dev/null || true
  ip link del kube-ipvs0 2>/dev/null || true

  log "清理 KUBE/CNI/FELIX 相关 iptables 链"
  for table in nat filter mangle raw; do
    iptables -t "${table}" -S 2>/dev/null | awk '/KUBE-|CALI-|CILIUM|FLANNEL/ {print $2}' | sort -u | while read -r chain; do
      iptables -t "${table}" -F "${chain}" 2>/dev/null || true
      iptables -t "${table}" -X "${chain}" 2>/dev/null || true
    done
    ip6tables -t "${table}" -S 2>/dev/null | awk '/KUBE-|CALI-|CILIUM|FLANNEL/ {print $2}' | sort -u | while read -r chain; do
      ip6tables -t "${table}" -F "${chain}" 2>/dev/null || true
      ip6tables -t "${table}" -X "${chain}" 2>/dev/null || true
    done
  done

  log "删除 K8s/Rancher 数据目录"
  rm -rf /etc/rancher
  rm -rf /var/lib/rancher
  rm -rf /var/lib/rancher-data
  rm -rf "${RANCHER_DATA}"
  rm -rf /var/lib/kubelet
  rm -rf /var/lib/cni
  rm -rf /var/lib/etcd
  rm -rf /etc/cni
  rm -rf /opt/cni
  rm -rf /run/flannel
  rm -rf /var/log/containers
  rm -rf /var/log/pods

  log "清理完成。建议执行 reboot 后再安装 Rancher。"
}

main "$@"
