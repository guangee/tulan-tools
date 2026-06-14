#!/usr/bin/env bash
# zsh 历史指令提示（Oh My Zsh + zsh-autosuggestions）

set -euo pipefail

_SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${_SCRIPT_ROOT}/lib/common.sh"
# shellcheck source=../lib/zsh.sh
source "${_SCRIPT_ROOT}/lib/zsh.sh"

ACTION="configure"

usage() {
  cat <<EOF
用法: brew zsh [子命令] [选项]

子命令:
  configure         安装 zsh-autosuggestions 并写入 ~/.zshrc plugins（默认）
  install           同 configure
  status            查看 zsh / Oh My Zsh / 插件状态

选项:
  --repo URL        插件仓库，默认 ${TULAN_ZSH_AUTOSUGGESTIONS_REPO}
  --debug           显示调试信息
  -h, --help        显示帮助

说明:
  仅当检测到 zsh + Oh My Zsh 已配置时才执行（否则跳过，不报错）
  插件安装路径: \${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions

示例:
  brew zsh
  brew zsh status
  brew help zsh
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    configure|install|setup|autosuggestions) ACTION="configure"; shift ;;
    status) ACTION="status"; shift ;;
    --repo)
      [[ $# -ge 2 ]] || { tulan_error "缺少 --repo 参数"; exit 1; }
      export TULAN_ZSH_AUTOSUGGESTIONS_REPO="$2"
      shift 2
      ;;
    --debug) export TULAN_DEBUG=true; shift ;;
    -h|--help|help) usage; exit 0 ;;
    *)
      tulan_error "未知参数: $1"
      usage
      exit 1
      ;;
  esac
done

main() {
  case "$ACTION" in
    configure)
      tulan_zsh_configure_autosuggestions
      ;;
    status)
      tulan_zsh_show_status
      ;;
    *)
      tulan_error "未知子命令: ${ACTION}"
      usage
      exit 1
      ;;
  esac
}

main "$@"
