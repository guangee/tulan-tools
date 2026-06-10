#!/usr/bin/env bash
# 查看工具/软件包可用版本

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
用法: tulan versions <名称>

查看二进制工具或私有软件包的版本信息。

示例:
  tulan versions kubectl
  tulan versions docker-compose
  tulan versions my-tool
  tulan list                 # 查看所有可安装项
EOF
}

main() {
  local name="${1:-}"
  local canonical

  if [[ -z "$name" ]] || [[ "$name" == "-h" ]] || [[ "$name" == "--help" ]]; then
    usage
    exit 1
  fi

  canonical="$(tulan_binary_canonical_name "$name")"
  if [[ -n "$canonical" ]]; then
    tulan_binary_show_versions "$canonical"
    exit 0
  fi

  if tulan_pkg_exists "$name"; then
    tulan_pkg_show_versions "$name"
    exit 0
  fi

  tulan_error "未知名称: ${name}"
  echo "  运行 tulan list 查看可用项" >&2
  exit 1
}

main "$@"
