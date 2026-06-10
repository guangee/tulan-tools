#!/usr/bin/env bash
# tulan-tools 安装脚本
# 用法: curl -fsSL <url>/install.sh | bash
#   或: ./install.sh [--repo URL] [--branch BRANCH] [--home DIR]

set -euo pipefail

_log() { echo "[tulan-tools] $*"; }
_err() { echo "[tulan-tools] 错误: $*" >&2; }

REPO_URL=""
DEFAULT_REPO="${TULAN_TOOLS_DEFAULT_REPO:-https://github.com/guangee/tulan-tools.git}"
BRANCH="master"
INSTALL_HOME="${HOME}/.tulan-tools"
SKIP_DEPS=false
LOCAL_INSTALL=false

usage() {
  cat <<EOF
tulan-tools 安装脚本

用法:
  ./install.sh [选项]

选项:
  --repo URL      Git 仓库地址（默认 guangee/tulan-tools）
  --branch NAME   分支名，默认 master
  --local         从当前目录同步到 ~/.tulan-tools（开发用）
  --skip-deps     跳过系统依赖安装
  -h, --help      显示帮助

示例:
  ./install.sh --local

  # 远程一键安装（支持 GitHub 代理）
  curl -fsSL https://gh.coding-space.cn/https://raw.githubusercontent.com/guangee/tulan-tools/master/install.sh | bash
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) REPO_URL="$2"; shift 2 ;;
      --branch) BRANCH="$2"; shift 2 ;;
      --local) LOCAL_INSTALL=true; shift ;;
      --skip-deps) SKIP_DEPS=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) _err "未知参数: $1"; usage; exit 1 ;;
    esac
  done
}

# 安全获取脚本目录（兼容 curl | bash 管道执行）
get_script_dir() {
  local src="${BASH_SOURCE[0]:-}"
  if [[ -n "$src" && -f "$src" ]]; then
    cd "$(dirname "$src")" && pwd
  else
    echo ""
  fi
}

# 远程管道安装时内联安装 git/curl
bootstrap_install_deps() {
  if command -v git &>/dev/null && command -v curl &>/dev/null; then
    return 0
  fi
  _log "安装依赖: git curl"
  if command -v apt-get &>/dev/null; then
    sudo apt-get update -qq
    sudo apt-get install -y git curl
  elif command -v dnf &>/dev/null; then
    sudo dnf install -y git curl
  elif command -v yum &>/dev/null; then
    sudo yum install -y git curl
  else
    _err "请先安装 git 和 curl"
    exit 1
  fi
}

# curl | bash 时没有本地 lib，先克隆仓库再转本地安装
bootstrap_remote_install() {
  [[ -z "$REPO_URL" ]] && REPO_URL="$DEFAULT_REPO"

  _log "远程安装模式，正在克隆仓库..."
  _log "  仓库: ${REPO_URL}"
  _log "  分支: ${BRANCH}"
  _log "  目录: ${INSTALL_HOME}"

  if [[ "$SKIP_DEPS" == false ]]; then
    bootstrap_install_deps
  fi

  if [[ -d "${INSTALL_HOME}/.git" ]]; then
    git -C "${INSTALL_HOME}" fetch origin
    git -C "${INSTALL_HOME}" checkout "${BRANCH}" 2>/dev/null || true
    git -C "${INSTALL_HOME}" pull --ff-only origin "${BRANCH}"
  else
    rm -rf "${INSTALL_HOME}"
    git clone --branch "${BRANCH}" --depth 1 "${REPO_URL}" "${INSTALL_HOME}"
  fi

  exec bash "${INSTALL_HOME}/install.sh" --local --skip-deps
}

parse_args "$@"

SCRIPT_DIR="$(get_script_dir)"

# 无本地 lib 且非 --local → 远程引导安装
if [[ "$LOCAL_INSTALL" != true ]] && [[ ! -f "${SCRIPT_DIR}/lib/common.sh" ]]; then
  bootstrap_remote_install
fi

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

main() {
  tulan_cleanup_legacy_files

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
      REPO_URL="$DEFAULT_REPO"
      tulan_log "使用默认仓库: ${REPO_URL}"
    fi
    tulan_git_sync "$REPO_URL" "$INSTALL_HOME" "$BRANCH"
  fi

  chmod +x "${INSTALL_HOME}/bin/"* 2>/dev/null || true
  chmod +x "${INSTALL_HOME}/scripts/"* 2>/dev/null || true
  chmod +x "${INSTALL_HOME}/packages/"*/*.sh 2>/dev/null || true

  tulan_log "配置 shell 环境..."
  tulan_inject_shell_config "${HOME}/.bashrc" "${INSTALL_HOME}"
  tulan_inject_shell_config "${HOME}/.zshrc" "${INSTALL_HOME}"

  mkdir -p "${INSTALL_HOME}/state"
  rm -f "${INSTALL_HOME}/.install-info"
  cat > "${INSTALL_HOME}/state/install-info" <<EOF
INSTALL_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
INSTALL_HOME=${INSTALL_HOME}
REPO_URL=${REPO_URL:-local}
BRANCH=${BRANCH}
OS=$(tulan_detect_os)
EOF

  tulan_log "安装完成!"
  echo ""
  echo "  安装目录: ${INSTALL_HOME}"
  echo "  可用命令: tulan update, tulan download, tulan docker, tulan conda, tulan list"
  echo ""
  echo "  请运行以下命令使配置生效:"
  echo "    source ~/.bashrc   # 或 source ~/.zshrc"
  echo ""
}

main
