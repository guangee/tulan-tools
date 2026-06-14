#!/usr/bin/env bash
# 防火墙端口开放/关闭（firewalld / ufw / iptables / nftables）

set -euo pipefail

_SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${_SCRIPT_ROOT}/lib/common.sh"
# shellcheck source=../lib/firewall.sh
source "${_SCRIPT_ROOT}/lib/firewall.sh"

ACTION="status"
PORT_SPEC=""
ASSUME_YES=false
RESTART_DOCKER=false

usage() {
  cat <<EOF
用法: brew firewall [子命令] [选项]

子命令:
  status            查看防火墙与端口状态（默认）
  open <port>       开放端口（默认 tcp，如 8080 或 8080/udp）
  close <port>      关闭端口
  disable           关闭全部防火墙（firewalld / ufw / iptables / nftables）
  enable            重新启用防火墙
  off               同 disable

选项:
  --restart-docker  操作完成后重启 Docker（disable 时常用）
  -y, --yes         跳过确认（disable 时）
  -h, --help        显示帮助

说明:
  自动检测并兼容 firewalld（CentOS/RHEL）、ufw（Debian/Ubuntu）、
  iptables、nftables；disable 会依次关闭所有可用组件
  需要 root 或 sudo
  状态记录: $(tulan_get_home)/state/firewall.json

示例:
  brew firewall status
  brew firewall open 8080
  brew firewall open 8443/tcp
  brew firewall close 8080
  brew firewall disable --restart-docker -y
  brew help firewall
EOF
}

confirm_disable() {
  if [[ "$ASSUME_YES" == true ]]; then
    return 0
  fi
  echo ""
  echo "将关闭全部防火墙组件（firewalld / ufw / iptables / nftables）。"
  [[ "$RESTART_DOCKER" == true ]] && echo "并将重启 Docker 服务使网络规则生效。"
  echo ""
  read -r -p "确认继续? [y/N]: " confirm
  [[ "$confirm" =~ ^[yY]$ ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    status) ACTION="status"; shift ;;
    open|allow) ACTION="open"; shift ;;
    close|deny|block) ACTION="close"; shift ;;
    disable|off|stop) ACTION="disable"; shift ;;
    enable|start|on) ACTION="enable"; shift ;;
    -h|--help|help) usage; exit 0 ;;
    --restart-docker) RESTART_DOCKER=true; shift ;;
    -y|--yes) ASSUME_YES=true; shift ;;
    *)
      if [[ "$ACTION" == "open" || "$ACTION" == "close" ]] && [[ -z "$PORT_SPEC" ]]; then
        PORT_SPEC="$1"
        shift
      else
        tulan_error "未知参数: $1"
        usage
        exit 1
      fi
      ;;
  esac
done

main() {
  case "$ACTION" in
    status)
      tulan_firewall_require_linux || exit 1
      tulan_firewall_show_status
      ;;
    open)
      [[ -n "$PORT_SPEC" ]] || { tulan_error "请指定端口，如: brew firewall open 8080"; exit 1; }
      tulan_firewall_open_port "$PORT_SPEC"
      [[ "$RESTART_DOCKER" == true ]] && tulan_firewall_restart_docker
      ;;
    close)
      [[ -n "$PORT_SPEC" ]] || { tulan_error "请指定端口，如: brew firewall close 8080"; exit 1; }
      tulan_firewall_close_port "$PORT_SPEC"
      [[ "$RESTART_DOCKER" == true ]] && tulan_firewall_restart_docker
      ;;
    disable)
      confirm_disable || { tulan_log "已取消"; exit 0; }
      tulan_firewall_disable_all
      if [[ "$RESTART_DOCKER" == true ]]; then
        tulan_firewall_restart_docker
      else
        tulan_log "提示: 防火墙变更后如需 Docker 网络生效，可执行: brew firewall disable --restart-docker"
      fi
      ;;
    enable)
      tulan_firewall_enable_all
      [[ "$RESTART_DOCKER" == true ]] && tulan_firewall_restart_docker
      ;;
    *)
      tulan_error "未知子命令: ${ACTION}"
      usage
      exit 1
      ;;
  esac
}

main "$@"
