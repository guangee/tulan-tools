#!/usr/bin/env bash
# 统一安装：二进制工具 + 私有软件包

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
用法: brew install <名称> [名称...] [选项]

安装二进制工具（kubectl、docker-compose、mc、openjdk、maven、node）或私有软件包。
请先 brew list 查看可用项，默认安装最新版本。

选项:
  --source SRC      二进制源: github（默认）| upstream
  --version VER     指定版本
  --force           强制重装（仅私有包）
  --refresh-manifest  刷新 bin 索引（仅二进制）
  --no-verify       跳过 SHA256（仅二进制）
  --no-proxy        禁用代理（仅二进制）
  --debug           调试输出
  --verbose         详细下载过程（URL、curl 进度、校验）
  -h, --help        显示帮助

示例:
  brew list
  brew install kubectl
  brew install kubectl mc
  brew install openjdk-11 maven node-20
  brew use java 11
  brew use node 20
  brew install my-tool
  brew versions kubectl
EOF
}

main() {
  local args=()
  local name force=false version=""
  local binary_targets=()
  local pkg_targets=()
  local has_binary_flags=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source|--proxy|--install-dir)
        has_binary_flags=true
        args+=("$1" "$2")
        shift 2
        ;;
      --version)
        has_binary_flags=true
        version="$2"
        args+=("$1" "$2")
        shift 2
        ;;
      --no-verify|--no-proxy|--refresh-manifest|--debug|--verbose|--dry-run)
        has_binary_flags=true
        args+=("$1")
        shift
        ;;
      --force) force=true; shift ;;
      -h|--help) usage; exit 0 ;;
      --tool)
        binary_targets+=("$2")
        shift 2
        ;;
      --*)
        tulan_error "未知参数: $1"
        usage
        exit 1
        ;;
      *)
        canonical="$(tulan_binary_canonical_name "$1")"
        if [[ -n "$canonical" ]]; then
          binary_targets+=("$canonical")
        elif tulan_pkg_exists "$1"; then
          pkg_targets+=("$1")
        else
          tulan_error "未知安装项: $1"
          echo "  运行 brew list 查看可用工具和软件包" >&2
          exit 1
        fi
        shift
        ;;
    esac
  done

  if [[ ${#binary_targets[@]} -eq 0 && ${#pkg_targets[@]} -eq 0 ]]; then
    tulan_error "请指定要安装的名称"
    echo "" >&2
    echo "  brew list              # 查看全部" >&2
    echo "  brew install kubectl   # 安装工具" >&2
    echo "  brew versions kubectl  # 查看版本" >&2
    exit 1
  fi

  if [[ ${#binary_targets[@]} -gt 0 ]]; then
    local bin_script="${_SCRIPT_ROOT}/scripts/install-binaries.sh"
    local bin_args=("${args[@]}")
    local t
    for t in "${binary_targets[@]}"; do
      bin_args+=("$t")
    done
    "$bin_script" "${bin_args[@]}"
  fi

  if [[ ${#pkg_targets[@]} -gt 0 ]]; then
    if [[ "$has_binary_flags" == true ]]; then
      tulan_log "忽略二进制专用参数，安装私有包..."
    fi
    for name in "${pkg_targets[@]}"; do
      tulan_pkg_install "$name" "$force" "$version"
    done
  fi
}

main "$@"
