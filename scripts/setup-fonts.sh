#!/usr/bin/env bash
# 安装中文字体并配置 fontconfig，确保常见汉字可正常显示

set -euo pipefail

_SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${_SCRIPT_ROOT}/lib/common.sh"
# shellcheck source=../lib/fonts.sh
source "${_SCRIPT_ROOT}/lib/fonts.sh"

TULAN_HOME="$(tulan_get_home)"
ACTION="install"
INSTALL_PKGS=true
CONFIGURE_LOCALE=true
MINIMAL=false
USER_MODE=false

usage() {
  cat <<EOF
用法: brew fonts [install|configure|status|test] [选项]

子命令:
  install       安装中文字体包、locale 与 fontconfig（默认）
  configure     仅写入 fontconfig 并刷新缓存（不装系统包）
  status        查看 locale 与中文字体状态
  test          测试中文渲染与字体匹配

选项:
  --minimal         仅安装 Noto CJK（跳过文泉驿等补充字体）
  --no-locale       不配置 zh_CN.UTF-8 locale
  --user            仅写入用户级 fontconfig（~/.config/fontconfig/，无需 sudo 写系统）
  --skip-install    同 configure，不安装系统字体包
  --debug           显示调试信息
  -h, --help        显示帮助

说明:
  fontconfig 模板: ${TULAN_HOME}/config/fonts.cn.conf
  默认字体: Noto Sans/Serif/Mono CJK SC + 文泉驿微米黑/正黑
  install 需要 sudo（系统级安装）

示例:
  brew fonts                         # 完整安装与配置
  brew fonts status                  # 查看当前状态
  brew fonts configure --user        # 仅用户级 fontconfig
  brew fonts install --minimal       # 最小安装（Noto CJK）
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    install) ACTION="install"; shift ;;
    configure) ACTION="configure"; INSTALL_PKGS=false; shift ;;
    status) ACTION="status"; shift ;;
    test) ACTION="test"; shift ;;
    --minimal) MINIMAL=true; shift ;;
    --no-locale) CONFIGURE_LOCALE=false; shift ;;
    --user) USER_MODE=true; shift ;;
    --skip-install) INSTALL_PKGS=false; shift ;;
    --debug) export TULAN_DEBUG=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) tulan_error "未知参数: $1"; usage; exit 1 ;;
    *) tulan_error "未知参数: $1"; usage; exit 1 ;;
  esac
done

main() {
  case "$ACTION" in
    status)
      tulan_fonts_show_status
      ;;
    test)
      tulan_fonts_test_render
      ;;
    install|configure)
      if [[ "$USER_MODE" != true && "$INSTALL_PKGS" == true ]]; then
        tulan_fonts_require_sudo || exit 1
      fi
      tulan_fonts_setup "$INSTALL_PKGS" "$CONFIGURE_LOCALE" "$MINIMAL" "$USER_MODE"
      ;;
    *)
      tulan_error "未知子命令: ${ACTION}"
      usage
      exit 1
      ;;
  esac
}

main
