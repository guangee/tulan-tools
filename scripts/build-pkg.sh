#!/usr/bin/env bash
# 构建单个私有软件包（packages/ 下的包）为 deb/rpm

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TULAN_HOME="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${TULAN_HOME}/lib/common.sh"

PKG_NAME=""
OUTPUT_FORMAT="all"
BUILD_DIR="${TULAN_HOME}/dist/packages"

usage() {
  cat <<EOF
将 packages/ 下的私有软件包构建为 deb/rpm

用法:
  ./scripts/build-pkg.sh <包名> [选项]

选项:
  --format FMT    deb | rpm | all，默认 all
  -h, --help      显示帮助

示例:
  ./scripts/build-pkg.sh example-tool --format deb
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --format) OUTPUT_FORMAT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) tulan_error "未知参数: $1"; usage; exit 1 ;;
    *) PKG_NAME="$1"; shift ;;
  esac
done

if [[ -z "$PKG_NAME" ]]; then
  usage
  exit 1
fi

main() {
  local pkg_dir="${TULAN_HOME}/packages/${PKG_NAME}"
  if [[ ! -d "$pkg_dir" ]]; then
    tulan_error "包不存在: ${PKG_NAME}"
    exit 1
  fi

  # shellcheck source=../lib/package.sh
  source "${TULAN_HOME}/lib/package.sh"

  local version desc
  version="$(tulan_pkg_read_manifest "$pkg_dir" "version" 2>/dev/null || echo "0.0.0")"
  desc="$(tulan_pkg_read_manifest "$pkg_dir" "description" 2>/dev/null || echo "")"

  tulan_log "构建包: ${PKG_NAME} v${version}"

  local stage="${BUILD_DIR}/stage-${PKG_NAME}"
  rm -rf "$stage"
  mkdir -p "${stage}/opt/tulan-tools/packages/${PKG_NAME}"
  mkdir -p "${stage}/opt/tulan-tools/bin"
  mkdir -p "${stage}/usr/local/bin"

  cp -a "${pkg_dir}/." "${stage}/opt/tulan-tools/packages/${PKG_NAME}/"

  # 链接 bin 到全局路径
  if [[ -d "${pkg_dir}/bin" ]]; then
    for bin_file in "${pkg_dir}/bin"/*; do
      [[ -f "$bin_file" ]] || continue
      local name
      name="$(basename "$bin_file")"
      cp "$bin_file" "${stage}/usr/local/bin/${name}"
      chmod +x "${stage}/usr/local/bin/${name}"
    done
  fi

  mkdir -p "$BUILD_DIR"

  build_one() {
    local fmt="$1"
    if ! command -v fpm &>/dev/null; then
      tulan_error "需要 fpm: gem install fpm"
      exit 1
    fi

    fpm -s dir -t "$fmt" \
      -n "$PKG_NAME" \
      -v "$version" \
      --description "$desc" \
      --license "Private" \
      --maintainer "tulan <you@example.com>" \
      -C "$stage" \
      -p "${BUILD_DIR}/${PKG_NAME}_${version}.${fmt}" \
      opt/=/opt \
      usr/local/bin/=/usr/local/bin

    tulan_log "已生成: ${BUILD_DIR}/${PKG_NAME}_${version}.${fmt}"
  }

  case "$OUTPUT_FORMAT" in
    deb) build_one "deb" ;;
    rpm) build_one "rpm" ;;
    all)
      build_one "deb"
      build_one "rpm"
      ;;
  esac
}

main "$@"
