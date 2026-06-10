#!/usr/bin/env bash
# tulan-tools 安装脚本
# 用法: curl -fsSL <repo>/install.sh | bash
#   或: ./install.sh [--repo URL] [--branch BRANCH] [--home DIR]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

REPO_URL=""
BRANCH="master"
INSTALL_HOME="${TULAN_TOOLS_DEFAULT_HOME}"
SKIP_DEPS=false
LOCAL_INSTALL=false

usage() {
  cat <<EOF
tulan-tools 安装脚本

用法:
  ./install.sh [选项]

选项:
  --repo URL      Git 仓库地址（远程安装时必填）
  --branch NAME   分支名，默认 master
  --home DIR      安装目录，默认 ~/.tulan-tools
  --local         从当前目录安装（开发模式）
  --skip-deps     跳过系统依赖安装
  -h, --help      显示帮助

示例:
  # 从 Git 仓库安装
  ./install.sh --repo git@github.com:guangee/tulan-tools.git

  # 本地开发安装
  ./install.sh --local

  # 远程一键安装
  curl -fsSL https://raw.githubusercontent.com/guangee/tulan-tools/master/install.sh | bash -s -- \
    --repo git@github.com:guangee/tulan-tools.git
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO_URL="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --home) INSTALL_HOME="$2"; shift 2 ;;
    --local) LOCAL_INSTALL=true; shift ;;
    --skip-deps) SKIP_DEPS=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) tulan_error "未知参数: $1"; usage; exit 1 ;;
  esac
done

main() {
  tulan_log "开始安装 tulan-tools"
  tulan_log "目标系统: $(tulan_detect_os) / $(tulan_detect_pkg_manager)"

  if [[ "$SKIP_DEPS" == false ]]; then
    tulan_log "安装系统依赖..."
    tulan_install_system_deps
  fi

  if [[ "$LOCAL_INSTALL" == true ]]; then
    tulan_log "本地安装模式: ${SCRIPT_DIR} -> ${INSTALL_HOME}"
    if [[ "${SCRIPT_DIR}" != "${INSTALL_HOME}" ]]; then
      mkdir -p "${INSTALL_HOME}"
      rsync -a --exclude='.git' "${SCRIPT_DIR}/" "${INSTALL_HOME}/"
    fi
  else
    if [[ -z "$REPO_URL" ]]; then
      tulan_error "请指定 --repo 或使用 --local 模式"
      exit 1
    fi
    tulan_git_sync "$REPO_URL" "$INSTALL_HOME" "$BRANCH"
  fi

  # 确保脚本可执行
  chmod +x "${INSTALL_HOME}/bin/"* 2>/dev/null || true
  chmod +x "${INSTALL_HOME}/scripts/"* 2>/dev/null || true
  chmod +x "${INSTALL_HOME}/packages/"*/*.sh 2>/dev/null || true

  # 配置 shell
  tulan_log "配置 shell 环境..."
  tulan_inject_shell_config "${HOME}/.bashrc" "${INSTALL_HOME}"
  tulan_inject_shell_config "${HOME}/.zshrc" "${INSTALL_HOME}"

  # 记录安装信息
  cat > "${INSTALL_HOME}/.install-info" <<EOF
INSTALL_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
INSTALL_HOME=${INSTALL_HOME}
REPO_URL=${REPO_URL:-local}
BRANCH=${BRANCH}
OS=$(tulan_detect_os)
EOF

  tulan_log "安装完成!"
  echo ""
  echo "  安装目录: ${INSTALL_HOME}"
  echo "  可用命令: tulan-update, tulan-install-pkg, tulan-list-pkgs"
  echo ""
  echo "  请运行以下命令使配置生效:"
  echo "    source ~/.bashrc   # 或 source ~/.zshrc"
  echo ""
}

main "$@"
