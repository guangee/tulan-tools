#!/usr/bin/env bash
# 卸载二进制工具或私有软件包

set -euo pipefail

_SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${_SCRIPT_ROOT}/lib/common.sh"
# shellcheck source=../lib/binaries.sh
source "${_SCRIPT_ROOT}/lib/binaries.sh"
# shellcheck source=../lib/package.sh
source "${_SCRIPT_ROOT}/lib/package.sh"

usage() {
  cat <<EOF
用法: tulan uninstall <名称> [选项]

卸载二进制工具（kubectl / docker-compose / mc）或私有软件包。

选项:
  --version VER   仅卸载二进制工具的指定版本
  -h, --help      显示帮助

示例:
  tulan uninstall kubectl
  tulan uninstall kubectl --version v1.31.0
  tulan uninstall my-tool
EOF
}

main() {
  local name="" version="" canonical

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) version="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) tulan_error "未知参数: $1"; usage; exit 1 ;;
      *)
        if [[ -z "$name" ]]; then
          name="$1"
        else
          tulan_error "多余参数: $1"; usage; exit 1
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$name" ]]; then
    usage
    exit 1
  fi

  canonical="$(tulan_binary_canonical_name "$name")"
  if [[ -n "$canonical" ]]; then
    tulan_binary_uninstall "$canonical" "$version"
    exit 0
  fi

  if [[ -n "$version" ]]; then
    tulan_error "--version 仅适用于二进制工具"
    exit 1
  fi

  tulan_pkg_uninstall "$name"
}

main "$@"
