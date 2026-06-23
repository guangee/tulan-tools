#!/usr/bin/env bash
# 切换二进制工具激活版本（类似 brew switch）

set -euo pipefail

_SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${_SCRIPT_ROOT}/lib/common.sh"
# shellcheck source=../lib/binaries.sh
source "${_SCRIPT_ROOT}/lib/binaries.sh"
# shellcheck source=../lib/jdk-maven.sh
source "${_SCRIPT_ROOT}/lib/jdk-maven.sh"
# shellcheck source=../lib/node.sh
source "${_SCRIPT_ROOT}/lib/node.sh"
# shellcheck source=../lib/docker.sh
source "${_SCRIPT_ROOT}/lib/docker.sh"
# shellcheck source=../lib/go.sh
source "${_SCRIPT_ROOT}/lib/go.sh"

usage() {
  cat <<EOF
用法: brew use <工具> <版本>

切换已安装二进制工具的激活版本（更新 bin/ 下的符号链接）。
Java / Node 切换会更新 ~/.bashrc / ~/.zshrc 中的环境变量。

示例:
  brew use kubectl v1.32.0
  brew use docker-compose v5.1.4
  brew use java 11
  brew use node 20
  brew use node 22
  brew use go go1.22.5
  brew list --binaries --installed   # 查看已装版本
EOF
}

main() {
  local tool version canonical major

  if [[ $# -lt 2 ]] || [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    usage
    exit 1
  fi

  tool="$1"
  version="$2"

  if [[ "$tool" == java ]] || [[ "$tool" == openjdk ]]; then
    major="$(tulan_openjdk_major_for_tool "$version")"
    if [[ -z "$major" ]]; then
      tulan_error "请指定 Java 主版本: brew use java 8|11|17"
      exit 1
    fi
    tulan_java_activate "$major"
    exit 0
  fi

  canonical="$(tulan_binary_canonical_name "$tool")"
  major="$(tulan_openjdk_major_for_tool "$canonical")"
  if [[ -n "$major" ]]; then
    tulan_java_activate "$major"
    exit 0
  fi

  if [[ "$tool" == node ]] || [[ "$tool" == nodejs ]]; then
    major="$(tulan_node_major_for_tool "$version")"
    if [[ -z "$major" ]]; then
      tulan_error "请指定 Node 主版本: brew use node 16|18|20|22|24"
      exit 1
    fi
    tulan_node_activate "$major"
    exit 0
  fi

  major="$(tulan_node_major_for_tool "$canonical")"
  if [[ -n "$major" ]]; then
    tulan_node_activate "$major"
    exit 0
  fi

  if [[ "$canonical" == docker ]]; then
    tulan_docker_activate "$version"
    exit 0
  fi

  if [[ "$canonical" == go ]]; then
    version="$(tulan_go_normalize_version "$version")"
    tulan_go_activate "$version"
    exit 0
  fi

  if [[ -z "$canonical" ]]; then
    tulan_error "未知工具: $tool（可选: kubectl, docker-compose, mc, docker, java, maven, node, go）"
    exit 1
  fi

  tulan_binary_activate "$canonical" "$version"
}

main "$@"
