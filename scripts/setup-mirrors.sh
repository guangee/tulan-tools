#!/usr/bin/env bash
# 配置国内镜像：系统软件源（Debian/Ubuntu/CentOS）+ pip / npm / Go

set -euo pipefail

_SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${_SCRIPT_ROOT}/lib/common.sh"
# shellcheck source=../lib/env.sh
source "${_SCRIPT_ROOT}/lib/env.sh"
# shellcheck source=../lib/repo-mirror.sh
source "${_SCRIPT_ROOT}/lib/repo-mirror.sh"
# shellcheck source=../lib/mirrors.sh
source "${_SCRIPT_ROOT}/lib/mirrors.sh"

TULAN_HOME="$(tulan_get_home)"
ACTION="install"
DO_PIP=false
DO_NPM=false
DO_GO=false
DO_REPO=false
SCOPE_SET=false

usage() {
  cat <<EOF
用法: brew mirrors [install|configure|restore|status] [选项]

子命令:
  install       配置国内镜像（默认 pip + npm + Go）
  configure     同 install
  restore       还原为原版镜像/默认配置
  status        查看当前镜像配置

选项:
  --repo          系统软件源（Debian / Ubuntu / CentOS，需 sudo）
  --pip           pip 阿里云 PyPI
  --npm           npm npmmirror
  --go            Go goproxy.cn
  --all           全部（系统源 + pip + npm + Go）
  --debug         显示调试信息
  -h, --help      显示帮助

说明:
  系统源备份: ${TULAN_HOME}/state/repo-backup/
  restore --repo  优先从备份还原；无备份则写入官方默认源
  支持系统: Debian、Ubuntu、CentOS（apt / yum / dnf）

示例:
  brew mirrors --repo                  # 仅切换系统软件源到国内
  brew mirrors --all                   # 系统源 + pip + npm + Go
  brew mirrors restore --repo          # 还原系统软件源
  brew mirrors restore --all           # 还原全部
  brew mirrors status
EOF
}

set_scope() {
  local kind="$1"
  case "$kind" in
    pip) DO_PIP=true ;;
    npm) DO_NPM=true ;;
    go) DO_GO=true ;;
    repo) DO_REPO=true ;;
    all)
      DO_PIP=true
      DO_NPM=true
      DO_GO=true
      DO_REPO=true
      ;;
  esac
  SCOPE_SET=true
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    install|configure) ACTION="install"; shift ;;
    restore|reset) ACTION="restore"; shift ;;
    status) ACTION="status"; shift ;;
    --repo) set_scope repo; shift ;;
    --pip) set_scope pip; shift ;;
    --npm) set_scope npm; shift ;;
    --go) set_scope go; shift ;;
    --all) set_scope all; shift ;;
    --debug) export TULAN_DEBUG=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) tulan_error "未知参数: $1"; usage; exit 1 ;;
    *) tulan_error "未知参数: $1"; usage; exit 1 ;;
  esac
done

# 未指定范围时：install 默认 pip+npm+go；restore 需显式指定
if [[ "$SCOPE_SET" != true ]]; then
  case "$ACTION" in
    install|configure)
      DO_PIP=true
      DO_NPM=true
      DO_GO=true
      ;;
    restore)
      tulan_error "请指定还原范围，例如: --repo、--pip、--all"
      usage
      exit 1
      ;;
  esac
fi

main() {
  case "$ACTION" in
    status)
      tulan_mirrors_show_status
      ;;
    install|configure)
      if [[ "$DO_REPO" == true ]]; then
        tulan_require_privilege || exit 1
      fi
      tulan_mirrors_setup "$DO_PIP" "$DO_NPM" "$DO_GO" "$DO_REPO"
      ;;
    restore)
      if [[ "$DO_REPO" == true ]]; then
        tulan_require_privilege || exit 1
      fi
      tulan_mirrors_restore "$DO_PIP" "$DO_NPM" "$DO_GO" "$DO_REPO"
      ;;
    *)
      tulan_error "未知子命令: ${ACTION}"
      usage
      exit 1
      ;;
  esac
}

main
