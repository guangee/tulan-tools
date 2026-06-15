#!/usr/bin/env bash
# 重启 Rancher 集群节点上的 RKE2/k3s 与可选 system-agent
#
# 用法:
#   brew k8s node-restart master
#   brew k8s node-restart worker
#   brew k8s node-restart auto

set -euo pipefail

NODE_RESTART_ROLE="${NODE_RESTART_ROLE:-auto}"
NODE_RESTART_WITH_AGENT="${NODE_RESTART_WITH_AGENT:-false}"
NODE_RESTART_ASSUME_YES="${NODE_RESTART_ASSUME_YES:-false}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

warn() {
  log "警告: $*"
}

have_unit() {
  systemctl cat "${1}.service" &>/dev/null 2>&1
}

unit_active() {
  systemctl is-active --quiet "$1" 2>/dev/null
}

detect_role() {
  if [[ "$NODE_RESTART_ROLE" != "auto" ]]; then
    echo "$NODE_RESTART_ROLE"
    return 0
  fi
  if have_unit rke2-server || have_unit k3s; then
    echo "master"
    return 0
  fi
  if have_unit rke2-agent || have_unit k3s-agent; then
    echo "worker"
    return 0
  fi
  echo "unknown"
}

guard_rancher_server_on_worker() {
  local role="$1"
  [[ "$role" != "worker" ]] && return 0
  if ! command -v docker &>/dev/null; then
    return 0
  fi
  local name
  while read -r name; do
    [[ -n "$name" ]] || continue
    if docker inspect -f '{{.Config.Image}}' "$name" 2>/dev/null | grep -qi 'rancher/rancher'; then
      warn "本机有 Rancher Server 容器「${name}」，worker 重启不会动 Docker Rancher"
      warn "若需重启 Rancher: docker restart ${name}"
    fi
  done < <(docker ps -a --format '{{.Names}}' 2>/dev/null || true)
}

confirm_restart() {
  local role="$1"
  if [[ "$NODE_RESTART_ASSUME_YES" == true ]]; then
    return 0
  fi
  echo ""
  echo "将重启本机 ${role} 节点相关服务"
  echo "────────────────────────────────────"
  case "$role" in
    master)
      echo "  rke2-server / k3s（若存在）"
      ;;
    worker)
      echo "  rke2-agent / k3s-agent（若存在）"
      ;;
    *)
      echo "  自动检测到的 rke2/k3s 服务"
      ;;
  esac
  [[ "$NODE_RESTART_WITH_AGENT" == true ]] && echo "  rancher-system-agent"
  echo ""
  read -r -p "确认继续? [y/N]: " confirm
  [[ "$confirm" =~ ^[yY]$ ]]
}

restart_unit() {
  local unit="$1"
  if ! have_unit "$unit"; then
    return 0
  fi
  log "重启 ${unit}.service ..."
  systemctl restart "${unit}.service"
  sleep 1
  if unit_active "$unit"; then
    log "  ✓ ${unit} 已 active"
  else
    warn "${unit} 状态: $(systemctl is-active "${unit}" 2>/dev/null || echo unknown)"
    systemctl status "${unit}.service" --no-pager -l 2>/dev/null | tail -n 5 | sed 's/^/    /' || true
  fi
}

restart_master() {
  if have_unit rke2-server; then
    restart_unit rke2-server
  elif have_unit k3s; then
    restart_unit k3s
  else
    warn "未找到 rke2-server / k3s 服务"
    return 1
  fi
}

restart_worker() {
  local restarted=false
  if have_unit rke2-agent; then
    restart_unit rke2-agent
    restarted=true
  elif have_unit k3s-agent; then
    restart_unit k3s-agent
    restarted=true
  fi
  if [[ "$restarted" == false ]]; then
    warn "未找到 rke2-agent / k3s-agent 服务"
    return 1
  fi
}

restart_system_agent() {
  if have_unit rancher-system-agent; then
    restart_unit rancher-system-agent
  else
    log "无 rancher-system-agent，跳过"
  fi
}

usage() {
  cat <<'EOF'
用法: brew k8s node-restart <master|worker|auto> [选项]

重启 Rancher 管理节点上的 K8s 运行时（非 Docker 版 Rancher Server 容器）。

角色:
  master    重启 rke2-server 或 k3s（control plane）
  worker    重启 rke2-agent 或 k3s-agent
  auto      自动检测（默认）

选项:
  --with-agent   同时重启 rancher-system-agent
  -y, --yes      跳过确认
  -h, --help     显示帮助

示例:
  brew k8s node-restart master -y
  brew k8s node-restart worker -y
  brew k8s node-restart worker --with-agent -y
  brew k8s node-restart auto -y

重启后建议: brew k8s node-watch
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      master|server|control-plane|cp)
        NODE_RESTART_ROLE=master
        shift
        ;;
      worker|agent|node)
        NODE_RESTART_ROLE=worker
        shift
        ;;
      auto|detect)
        NODE_RESTART_ROLE=auto
        shift
        ;;
      --with-agent)
        NODE_RESTART_WITH_AGENT=true
        shift
        ;;
      -y|--yes)
        NODE_RESTART_ASSUME_YES=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "未知参数: $1" >&2
        usage
        exit 1
        ;;
    esac
  done
}

main() {
  if [[ "$(uname -s | tr '[:upper:]' '[:lower:]')" != "linux" ]]; then
    echo "此命令需在 Linux 节点上执行"
    exit 1
  fi
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "请使用 root 或 sudo 执行" >&2
    exit 1
  fi

  parse_args "$@"

  local role
  role="$(detect_role)"
  if [[ "$role" == "unknown" ]]; then
    echo "无法识别节点角色，请指定 master 或 worker" >&2
    exit 1
  fi

  guard_rancher_server_on_worker "$role"
  confirm_restart "$role" || { log "已取消"; exit 0; }

  log "节点角色: ${role}（$(hostname 2>/dev/null || echo unknown)）"

  case "$role" in
    master) restart_master ;;
    worker) restart_worker ;;
    auto)
      if have_unit rke2-server || have_unit k3s; then
        restart_master
      else
        restart_worker
      fi
      ;;
  esac

  if [[ "$NODE_RESTART_WITH_AGENT" == true ]]; then
    restart_system_agent
  fi

  log "重启完成。监控: brew k8s node-watch"
}

main "$@"
