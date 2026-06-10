#!/usr/bin/env bash
# 构建 deb/rpm 系统安装包
# 将 tulan-tools 打包为原生 Linux 包，便于批量部署

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TULAN_HOME="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${TULAN_HOME}/lib/common.sh"

VERSION="0.1.0"
PKG_NAME="tulan-tools"
BUILD_DIR="${TULAN_HOME}/dist"
INSTALL_PREFIX="/opt/tulan-tools"
OUTPUT_FORMAT="all"

usage() {
  cat <<EOF
构建 tulan-tools 系统安装包 (deb/rpm)

用法:
  ./scripts/build-package.sh [选项]

选项:
  --version V     包版本号，默认 0.1.0
  --format FMT    输出格式: deb | rpm | all，默认 all
  --prefix PATH   安装前缀，默认 /opt/tulan-tools
  -h, --help      显示帮助

依赖:
  - fpm (推荐): gem install fpm
  - 或原生工具: dpkg-deb (deb), rpmbuild (rpm)

示例:
  ./scripts/build-package.sh --version 1.0.0 --format deb
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --format) OUTPUT_FORMAT="$2"; shift 2 ;;
    --prefix) INSTALL_PREFIX="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) tulan_error "未知参数: $1"; usage; exit 1 ;;
  esac
done

build_staging() {
  local stage="${BUILD_DIR}/stage"
  rm -rf "$stage"
  mkdir -p "${stage}${INSTALL_PREFIX}"
  mkdir -p "${stage}/usr/local/bin"

  rsync -a \
    --exclude='.git' \
    --exclude='dist' \
    --exclude='.idea' \
    --exclude='*.iml' \
    "${TULAN_HOME}/" "${stage}${INSTALL_PREFIX}/"

  # 系统级安装脚本
  cat > "${stage}${INSTALL_PREFIX}/postinstall.sh" <<'POSTINSTALL'
#!/usr/bin/env bash
INSTALL_PREFIX="__INSTALL_PREFIX__"
for rc in /etc/skel/.bashrc /etc/skel/.zshrc; do
  if [[ -f "$rc" ]] && ! grep -qF "tulan-tools" "$rc" 2>/dev/null; then
    cat >> "$rc" <<RC

# tulan-tools system install
export TULAN_TOOLS_HOME="${INSTALL_PREFIX}"
export PATH="\${TULAN_TOOLS_HOME}/bin:\${PATH}"
RC
  fi
done
POSTINSTALL
  sed -i.bak "s|__INSTALL_PREFIX__|${INSTALL_PREFIX}|g" "${stage}${INSTALL_PREFIX}/postinstall.sh"
  rm -f "${stage}${INSTALL_PREFIX}/postinstall.sh.bak"

  # 全局命令入口
  cat > "${stage}/usr/local/bin/tulan-tools" <<WRAPPER
#!/usr/bin/env bash
export TULAN_TOOLS_HOME="${INSTALL_PREFIX}"
exec "\${TULAN_TOOLS_HOME}/install.sh" "\$@"
WRAPPER
  chmod +x "${stage}/usr/local/bin/tulan-tools"
  chmod +x "${stage}${INSTALL_PREFIX}/postinstall.sh"

  echo "$stage"
}

build_with_fpm() {
  local stage="$1"
  local format="$2"

  mkdir -p "${BUILD_DIR}"

  fpm -s dir -t "$format" \
    -n "$PKG_NAME" \
    -v "$VERSION" \
    --description "tulan-tools: 个人开发工具集，类似 oh-my-zsh" \
    --url "https://github.com/your-org/tulan-tools" \
    --license "Private" \
    --maintainer "tulan <you@example.com>" \
    --after-install "${stage}${INSTALL_PREFIX}/postinstall.sh" \
    -C "$stage" \
    -p "${BUILD_DIR}/${PKG_NAME}_${VERSION}_${format}.${format}" \
    "${INSTALL_PREFIX}"=/ \
    usr/local/bin/tulan-tools=/usr/local/bin/tulan-tools

  tulan_log "已生成: ${BUILD_DIR}/${PKG_NAME}_${VERSION}_${format}.${format}"
}

build_deb_native() {
  local stage="$1"
  local deb_dir="${BUILD_DIR}/deb-build"
  rm -rf "$deb_dir"
  mkdir -p "${deb_dir}/DEBIAN"

  cp -a "${stage}/." "${deb_dir}/"
  rm -rf "${deb_dir}${INSTALL_PREFIX}/postinstall.sh"

  cat > "${deb_dir}/DEBIAN/control" <<EOF
Package: ${PKG_NAME}
Version: ${VERSION}
Section: utils
Priority: optional
Architecture: all
Maintainer: tulan <you@example.com>
Description: tulan-tools personal development toolkit
EOF

  cat > "${deb_dir}/DEBIAN/postinst" <<POSTINST
#!/bin/sh
${INSTALL_PREFIX}/postinstall.sh
POSTINST
  chmod 755 "${deb_dir}/DEBIAN/postinst"

  mkdir -p "$BUILD_DIR"
  dpkg-deb --build "$deb_dir" "${BUILD_DIR}/${PKG_NAME}_${VERSION}_all.deb"
  tulan_log "已生成: ${BUILD_DIR}/${PKG_NAME}_${VERSION}_all.deb"
}

build_rpm_native() {
  local stage="$1"
  tulan_log "RPM 原生构建需要 rpmbuild 环境，推荐使用 fpm"
  tulan_log "安装 fpm: gem install fpm"
  return 1
}

main() {
  tulan_log "构建 ${PKG_NAME} v${VERSION}"
  local stage
  stage="$(build_staging)"

  build_formats() {
    local fmt="$1"
    if command -v fpm &>/dev/null; then
      build_with_fpm "$stage" "$fmt"
    elif [[ "$fmt" == "deb" ]] && command -v dpkg-deb &>/dev/null; then
      build_deb_native "$stage"
    else
      tulan_error "无法构建 ${fmt} 包，请安装 fpm: gem install fpm"
      return 1
    fi
  }

  case "$OUTPUT_FORMAT" in
    deb) build_formats "deb" ;;
    rpm) build_formats "rpm" ;;
    all)
      build_formats "deb"
      build_formats "rpm"
      ;;
    *)
      tulan_error "未知格式: ${OUTPUT_FORMAT}"
      exit 1
      ;;
  esac

  tulan_log "构建完成，输出目录: ${BUILD_DIR}"
}

main "$@"
