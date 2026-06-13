#!/usr/bin/env bash
# 配置系统时区（东八区）与国内 NTP 源（自动测速选最快）

set -euo pipefail

_SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${_SCRIPT_ROOT}/lib/common.sh"
# shellcheck source=../lib/time.sh
source "${_SCRIPT_ROOT}/lib/time.sh"

TULAN_HOME="$(tulan_get_home)"
TIMEZONE="${TULAN_TIME_DEFAULT_TIMEZONE}"
SKIP_PROBE=false
ACTION="install"
CUSTOM_SERVERS=()

usage() {
  cat <<EOF
用法: brew time [install|configure|probe|now|shell|status] [选项]

子命令:
  install       探测国内 NTP、配置东八区时区并同步（默认）
  configure     同 install（仅重新配置，不安装系统包除非缺失）
  shell         仅配置 shell 东八区显示（date 自动 +0800 格式，无需 sudo）
  probe         仅探测 NTP 服务器延迟，不修改系统
  now           显示东八区当前时间
  status        显示当前时区与 NTP 状态

选项:
  --timezone ZONE     时区，默认 Asia/Shanghai（东八区）
  --servers HOST ...  指定 NTP 服务器（空格分隔多个需引号）
  --no-probe          不测速，按配置顺序使用 NTP 源
  --debug             显示调试信息
  -h, --help          显示帮助

说明:
  默认 NTP 列表: ${TULAN_HOME}/config/ntp.servers.cn
  环境变量 TULAN_NTP_SERVERS 可覆盖默认列表（空格分隔）
  需要 sudo 权限（install/configure）

示例:
  brew time                          # 测速 + 东八区 + NTP 同步
  brew time now                      # 显示东八区当前时间
  brew time shell                    # 仅让 date 自动显示 +0800（无需 sudo）
  brew time probe                    # 查看各 NTP 延迟
  brew time status                   # 查看当前状态
  brew time --servers ntp.aliyun.com cn.ntp.org.cn
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    install) ACTION="install"; shift ;;
    configure) ACTION="configure"; shift ;;
    shell) ACTION="shell"; shift ;;
    probe) ACTION="probe"; shift ;;
    now) ACTION="now"; shift ;;
    status) ACTION="status"; shift ;;
    --timezone)
      TIMEZONE="$2"
      shift 2
      ;;
    --servers)
      shift
      while [[ $# -gt 0 && "$1" != --* ]]; do
        CUSTOM_SERVERS+=("$1")
        shift
      done
      ;;
    --no-probe) SKIP_PROBE=true; shift ;;
    --debug) export TULAN_DEBUG=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) tulan_error "未知参数: $1"; usage; exit 1 ;;
    *) tulan_error "未知参数: $1"; usage; exit 1 ;;
  esac
done

main() {
  local servers=()

  if [[ ${#CUSTOM_SERVERS[@]} -gt 0 ]]; then
    servers=("${CUSTOM_SERVERS[@]}")
  else
    read -r -a servers <<< "$(tulan_time_default_servers)"
  fi

  case "$ACTION" in
    probe)
      tulan_time_show_probe "${servers[@]}"
      ;;
    now)
      tulan_time_show_now
      ;;
    shell)
      tulan_time_apply_shell
      ;;
    status)
      tulan_time_show_status
      ;;
    install|configure)
      tulan_time_setup "$TIMEZONE" "$SKIP_PROBE" "${servers[@]}"
      ;;
    *)
      tulan_error "未知子命令: ${ACTION}"
      usage
      exit 1
      ;;
  esac
}

main
