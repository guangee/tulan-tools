#!/usr/bin/env bash
# 列出二进制工具和私有软件包

set -euo pipefail

_SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${_SCRIPT_ROOT}/lib/common.sh"
# shellcheck source=../lib/binaries.sh
source "${_SCRIPT_ROOT}/lib/binaries.sh"
# shellcheck source=../lib/package.sh
source "${_SCRIPT_ROOT}/lib/package.sh"
# shellcheck source=../lib/archives.sh
source "${_SCRIPT_ROOT}/lib/archives.sh"
# shellcheck source=../lib/jdk-maven.sh
source "${_SCRIPT_ROOT}/lib/jdk-maven.sh"
# shellcheck source=../lib/node.sh
source "${_SCRIPT_ROOT}/lib/node.sh"

usage() {
  cat <<EOF
用法: brew list [选项]

选项:
  --installed   仅显示已安装项
  --binaries    仅显示二进制工具
  --pkgs        仅显示私有软件包
  -h, --help    显示帮助

安装前请先 list 查看，再 brew install <名称>，brew versions <名称> 查版本。
EOF
}

tulan_list_prepare_manifest() {
  if [[ -n "${TULAN_MANIFEST_PATH:-}" ]] && [[ -f "$TULAN_MANIFEST_PATH" ]]; then
    return 0
  fi
  TULAN_MANIFEST_PATH="$(tulan_resolve_manifest)" || return 1
  export TULAN_MANIFEST_PATH
}

main() {
  local mode="all"
  local manifest=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --installed) mode="installed"; shift ;;
      --binaries)  mode="binaries"; shift ;;
      --pkgs)      mode="pkgs"; shift ;;
      -h|--help)   usage; exit 0 ;;
      *) echo "未知参数: $1" >&2; usage; exit 1 ;;
    esac
  done

  case "$mode" in
    all)
      tulan_list_prepare_manifest || exit 1
      manifest="$TULAN_MANIFEST_PATH"
      echo "可安装项（默认 brew install 安装最新版）:"
      echo ""
      tulan_binaries_list false "$manifest"
      echo ""
      tulan_archive_tools_list "$manifest"
      echo ""
      tulan_pkg_list_available
      ;;
    installed)
      tulan_list_prepare_manifest || exit 1
      manifest="$TULAN_MANIFEST_PATH"
      tulan_binaries_list true "$manifest"
      echo ""
      tulan_pkg_list_installed
      ;;
    binaries)
      tulan_list_prepare_manifest || exit 1
      manifest="$TULAN_MANIFEST_PATH"
      tulan_binaries_list false "$manifest"
      echo ""
      tulan_archive_tools_list "$manifest"
      ;;
    pkgs)
      tulan_pkg_list_available
      ;;
  esac
}

main "$@"
