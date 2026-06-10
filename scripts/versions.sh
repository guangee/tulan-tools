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
# shellcheck source=../lib/jdk-maven.sh
source "${_SCRIPT_ROOT}/lib/jdk-maven.sh"

usage() {
  cat <<EOF
用法: brew versions <名称>

查看二进制工具或私有软件包的版本信息。

示例:
  brew versions kubectl
  brew versions openjdk-11
  brew versions java
  brew versions maven
  brew versions my-tool
  brew list                 # 查看所有可安装项
EOF
}

main() {
  local name="${1:-}"
  local canonical

  if [[ -z "$name" ]] || [[ "$name" == "-h" ]] || [[ "$name" == "--help" ]]; then
    usage
    exit 1
  fi

  if [[ "$name" == java ]] || [[ "$name" == openjdk ]]; then
    for major in 8 11 17; do
      tulan_openjdk_show_versions "$major"
      echo ""
    done
    exit 0
  fi

  canonical="$(tulan_binary_canonical_name "$name")"
  major="$(tulan_openjdk_major_for_tool "$canonical")"
  if [[ -n "$major" ]]; then
    tulan_openjdk_show_versions "$major"
    exit 0
  fi

  if [[ "$canonical" == maven ]]; then
    tulan_maven_show_versions
    exit 0
  fi

  if [[ -n "$canonical" ]]; then
    tulan_binary_show_versions "$canonical"
    exit 0
  fi

  if tulan_pkg_exists "$name"; then
    tulan_pkg_show_versions "$name"
    exit 0
  fi

  tulan_error "未知名称: ${name}"
  echo "  运行 brew list 查看可用项" >&2
  exit 1
}

main "$@"
