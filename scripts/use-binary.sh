#!/usr/bin/env bash
# 切换二进制工具激活版本（类似 brew switch）

set -euo pipefail

_SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${_SCRIPT_ROOT}/lib/common.sh"
# shellcheck source=../lib/binaries.sh
source "${_SCRIPT_ROOT}/lib/binaries.sh"

usage() {
  cat <<EOF
用法: brew use <工具> <版本>

切换已安装二进制工具的激活版本（更新 bin/ 下的符号链接）。

示例:
  brew use kubectl v1.32.0
  brew use docker-compose v5.1.4
  brew list --binaries --installed   # 查看已装版本
EOF
}

main() {
  local tool version canonical

  if [[ $# -lt 2 ]] || [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    usage
    exit 1
  fi

  canonical="$(tulan_binary_canonical_name "$1")"
  version="$2"

  if [[ -z "$canonical" ]]; then
    tulan_error "未知工具: $1（可选: kubectl, docker-compose, mc）"
    exit 1
  fi

  tulan_binary_activate "$canonical" "$version"
}

main "$@"
