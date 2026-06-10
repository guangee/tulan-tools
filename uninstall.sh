#!/usr/bin/env bash
# tulan-tools 卸载脚本

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

REMOVE_DIR=false
INSTALL_HOME=""

usage() {
  cat <<EOF
tulan-tools 卸载脚本

用法:
  ./uninstall.sh [选项]

选项:
  --home DIR      安装目录，默认自动检测
  --remove-dir    同时删除安装目录
  -h, --help      显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --home) INSTALL_HOME="$2"; shift 2 ;;
    --remove-dir) REMOVE_DIR=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) tulan_error "未知参数: $1"; usage; exit 1 ;;
  esac
done

main() {
  if [[ -z "$INSTALL_HOME" ]]; then
    INSTALL_HOME="$(tulan_get_home)"
  fi

  tulan_log "卸载 tulan-tools (目录: ${INSTALL_HOME})"

  tulan_remove_shell_config "${HOME}/.bashrc"
  tulan_remove_shell_config "${HOME}/.zshrc"

  if [[ "$REMOVE_DIR" == true ]] && [[ -d "$INSTALL_HOME" ]]; then
    rm -rf "$INSTALL_HOME"
    tulan_log "已删除目录: ${INSTALL_HOME}"
  fi

  tulan_log "卸载完成"
  echo "  请运行: source ~/.bashrc  或  source ~/.zshrc"
}

main "$@"
