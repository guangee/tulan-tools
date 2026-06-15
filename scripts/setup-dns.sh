#!/usr/bin/env bash
# 自动探测并修复系统 DNS（按 OS / 网络栈选择配置方式）

set -euo pipefail

_SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${_SCRIPT_ROOT}/lib/common.sh"
# shellcheck source=../lib/dns.sh
source "${_SCRIPT_ROOT}/lib/dns.sh"

ACTION="fix"
SKIP_PROBE=false
ASSUME_YES=false
TULAN_DNS_CUSTOM_SERVERS=()

usage() {
  cat <<EOF
用法: brew dns [fix|status|probe] [选项]

子命令:
  fix       测速并修复 DNS（默认，需 root/sudo）
  status    查看当前 DNS 与诊断
  probe     仅测速公共 DNS，不修改系统

选项:
  --servers IP ...   指定 DNS 列表（否则用 config/dns.servers.cn）
  --no-probe         不测速，按列表顺序取前 2 个
  -y, --yes          fix 时跳过确认
  -h, --help         显示帮助

说明:
  自动识别 systemd-resolved / NetworkManager / netplan / resolv.conf
  默认测速选用最快 2 个国内/公共权威 DNS（阿里、DNSPod、114、Google、Cloudflare 等）
  可修复 [::1]:53、127.0.0.53 等无效本地 DNS 导致的解析失败
  修复记录: ~/.tulan-tools/state/dns.env

示例:
  brew dns fix                       # 节点上推荐：测速 + 自动修复
  brew dns fix -y
  brew dns status
  brew dns probe
  brew dns fix --servers 223.5.5.5 223.6.6.6 --no-probe -y
  brew k8s fix-dns                   # 同 fix（在 K8s 节点上用）
EOF
}

confirm_fix() {
  if [[ "$ASSUME_YES" == true ]]; then
    return 0
  fi
  echo ""
  echo "将修改系统 DNS 配置（自动识别 NetworkManager / systemd-resolved 等）。"
  read -r -p "确认继续? [y/N]: " confirm
  [[ "$confirm" =~ ^[yY]$ ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    fix|install|configure) ACTION="fix"; shift ;;
    status) ACTION="status"; shift ;;
    probe) ACTION="probe"; shift ;;
    --servers)
      shift
      while [[ $# -gt 0 && "$1" != --* && "$1" != -* ]]; do
        TULAN_DNS_CUSTOM_SERVERS+=("$1")
        shift
      done
      ;;
    --no-probe) SKIP_PROBE=true; shift ;;
    -y|--yes) ASSUME_YES=true; shift ;;
    -h|--help|help) usage; exit 0 ;;
    *)
      tulan_error "未知参数: $1"
      usage
      exit 1
      ;;
  esac
done

case "$ACTION" in
  status)
    tulan_dns_show_status
    ;;
  probe)
    tulan_dns_require_linux || exit 1
    if [[ ${#TULAN_DNS_CUSTOM_SERVERS[@]} -gt 0 ]]; then
      tulan_dns_show_probe "${TULAN_DNS_CUSTOM_SERVERS[@]}"
    else
      local -a servers=()
      tulan_dns_load_default_servers servers
      tulan_dns_show_probe "${servers[@]}"
    fi
    ;;
  fix)
    confirm_fix || { tulan_log "已取消"; exit 0; }
    export TULAN_DNS_CUSTOM_SERVERS
    tulan_dns_fix "$SKIP_PROBE"
    ;;
esac
