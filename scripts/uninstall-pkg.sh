#!/usr/bin/env bash
# 卸载 tulan-tools 私有软件包

set -euo pipefail

_SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${_SCRIPT_ROOT}/lib/common.sh"
# shellcheck source=../lib/package.sh
source "${_SCRIPT_ROOT}/lib/package.sh"

usage() {
  echo "用法: tulan uninstall <包名>"
}

main() {
  if [[ -z "${1:-}" ]] || [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    usage
    exit 1
  fi

  tulan_pkg_uninstall "$1"
}

main "$@"
