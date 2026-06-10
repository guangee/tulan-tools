#!/usr/bin/env bash
# 安装 Miniconda，配置阿里云 conda/pip 源，并初始化 bash/zsh

set -euo pipefail

_SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${_SCRIPT_ROOT}/lib/common.sh"

TULAN_HOME="$(tulan_get_home)"
CONDA_PREFIX="${TULAN_CONDA_PREFIX:-${HOME}/miniconda3}"
CONDA_MIRROR_BASE="${TULAN_CONDA_MIRROR_BASE:-https://mirrors.aliyun.com/anaconda/miniconda}"
CONDA_OFFICIAL_BASE="${TULAN_CONDA_OFFICIAL_BASE:-https://repo.anaconda.com/miniconda}"
CONDARC_TEMPLATE="${TULAN_HOME}/config/condarc.aliyun.yaml"
PIP_TEMPLATE="${TULAN_HOME}/config/pip.aliyun.conf"
INSTALLER_CACHE_DIR="${TULAN_HOME}/state/miniconda"
INSTALLER_PATH=""

CONFIGURE_ONLY=false
SKIP_INSTALL=false
REFRESH_INSTALLER=false
FORCE_INSTALL=false
USE_MIRROR=true
ACTION="install"

usage() {
  cat <<EOF
用法: tulan conda [install|configure|fetch] [选项]

子命令:
  install       安装 Miniconda 并配置镜像与 shell（默认）
  configure     仅配置 conda/pip 阿里云源与 shell 环境
  fetch         仅下载安装包到本地缓存

选项:
  --prefix PATH       安装目录，默认 ~/miniconda3
  --refresh-installer 强制重新下载安装包
  --no-mirror         从官方 repo.anaconda.com 下载安装包
  --force             已存在时强制重装
  --debug             显示详细 URL
  -h, --help          显示帮助

说明:
  安装包缓存: ${INSTALLER_CACHE_DIR}/
  conda 源: ~/.condarc（阿里云）
  pip 源: ~/.pip/pip.conf（阿里云）
  shell: conda init bash / zsh → ~/.bashrc、~/.zshrc
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    install) ACTION="install"; shift ;;
    configure) ACTION="configure"; CONFIGURE_ONLY=true; shift ;;
    fetch) ACTION="fetch"; SKIP_INSTALL=true; shift ;;
    --configure-only) CONFIGURE_ONLY=true; shift ;;
    --skip-install) SKIP_INSTALL=true; shift ;;
    --prefix) CONDA_PREFIX="$2"; shift 2 ;;
    --refresh-installer) REFRESH_INSTALLER=true; shift ;;
    --no-mirror) USE_MIRROR=false; shift ;;
    --force) FORCE_INSTALL=true; shift ;;
    --debug) export TULAN_DEBUG=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) tulan_error "未知参数: $1"; usage; exit 1 ;;
    *) tulan_error "未知参数: $1"; usage; exit 1 ;;
  esac
done

miniconda_platform() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "${os}-${arch}" in
    Linux-x86_64)        echo "Linux-x86_64" ;;
    Linux-aarch64|Linux-arm64) echo "Linux-aarch64" ;;
    Darwin-x86_64)       echo "MacOSX-x86_64" ;;
    Darwin-arm64)        echo "MacOSX-arm64" ;;
    *)
      tulan_error "不支持的平台: ${os}/${arch}"
      return 1
      ;;
  esac
}

miniconda_installer_name() {
  echo "Miniconda3-latest-$(miniconda_platform).sh"
}

miniconda_download_url() {
  local name="$1"
  if [[ "$USE_MIRROR" == true ]]; then
    echo "${CONDA_MIRROR_BASE%/}/${name}"
  else
    echo "${CONDA_OFFICIAL_BASE%/}/${name}"
  fi
}

fetch_installer() {
  local name dest url fallback

  name="$(miniconda_installer_name)"
  dest="${INSTALLER_CACHE_DIR}/${name}"
  url="$(miniconda_download_url "$name")"
  mkdir -p "$INSTALLER_CACHE_DIR"

  if [[ -f "$dest" ]] && [[ "$REFRESH_INSTALLER" != true ]]; then
    tulan_log "使用已缓存的安装包: ${dest}"
    INSTALLER_PATH="$dest"
    return 0
  fi

  tulan_log "下载 Miniconda 安装包"
  tulan_debug "URL: ${url}"
  tulan_debug "保存: ${dest}"

  if curl -fSL "$url" -o "${dest}.tmp"; then
    chmod +x "${dest}.tmp"
    mv "${dest}.tmp" "$dest"
    tulan_log "安装包已保存: ${dest}"
    INSTALLER_PATH="$dest"
    return 0
  fi

  if [[ "$USE_MIRROR" == true ]]; then
    tulan_log "阿里云下载失败，尝试官方源..."
    fallback="${CONDA_OFFICIAL_BASE%/}/${name}"
    tulan_debug "fallback: ${fallback}"
    curl -fSL "$fallback" -o "${dest}.tmp"
    chmod +x "${dest}.tmp"
    mv "${dest}.tmp" "$dest"
    tulan_log "安装包已保存: ${dest}"
    INSTALLER_PATH="$dest"
    return 0
  fi

  tulan_error "下载失败: ${url}"
  return 1
}

install_miniconda() {
  local installer="$1"

  if [[ -x "${CONDA_PREFIX}/bin/conda" ]] && [[ "$FORCE_INSTALL" != true ]]; then
    tulan_log "检测到已有 Miniconda: ${CONDA_PREFIX}"
    return 0
  fi

  if [[ -d "$CONDA_PREFIX" ]] && [[ "$FORCE_INSTALL" == true ]]; then
    tulan_log "强制重装，删除旧目录: ${CONDA_PREFIX}"
    rm -rf "$CONDA_PREFIX"
  fi

  tulan_log "安装 Miniconda 到: ${CONDA_PREFIX}"
  tulan_debug "执行: bash ${installer} -b -p ${CONDA_PREFIX}"
  bash "$installer" -b -p "$CONDA_PREFIX"
  tulan_log "Miniconda 安装完成"
}

configure_condarc() {
  if [[ ! -f "$CONDARC_TEMPLATE" ]]; then
    tulan_error "缺少配置模板: ${CONDARC_TEMPLATE}"
    return 1
  fi

  cp "$CONDARC_TEMPLATE" "${HOME}/.condarc"
  tulan_log "已配置 conda 源: ${HOME}/.condarc（阿里云）"

  if [[ -x "${CONDA_PREFIX}/bin/conda" ]]; then
    "${CONDA_PREFIX}/bin/conda" config --show channels &>/dev/null || true
  fi
}

configure_pip_mirror() {
  local pip_dir="${HOME}/.pip"
  mkdir -p "$pip_dir"

  if [[ ! -f "$PIP_TEMPLATE" ]]; then
    tulan_error "缺少配置模板: ${PIP_TEMPLATE}"
    return 1
  fi

  cp "$PIP_TEMPLATE" "${pip_dir}/pip.conf"
  tulan_log "已配置 pip 源: ${pip_dir}/pip.conf（阿里云）"

  if [[ -d "$CONDA_PREFIX" ]]; then
    cp "$PIP_TEMPLATE" "${CONDA_PREFIX}/pip.conf"
    tulan_debug "已同步: ${CONDA_PREFIX}/pip.conf"
  fi
}

configure_shell() {
  local conda_bin="${CONDA_PREFIX}/bin/conda"
  local rc

  if [[ ! -x "$conda_bin" ]]; then
    tulan_error "未找到 conda: ${conda_bin}"
    return 1
  fi

  for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
    [[ -f "$rc" ]] || touch "$rc"
  done

  tulan_log "初始化 shell 环境（bash / zsh）"
  "$conda_bin" init bash >/dev/null
  "$conda_bin" init zsh >/dev/null
  tulan_log "已写入 ~/.bashrc 与 ~/.zshrc（conda initialize 区块）"
}

verify_conda() {
  if [[ -x "${CONDA_PREFIX}/bin/conda" ]]; then
    tulan_log "Conda 版本: $("${CONDA_PREFIX}/bin/conda" --version)"
    tulan_log "Python 版本: $("${CONDA_PREFIX}/bin/python" --version 2>&1)"
  fi
}

main() {
  local installer=""

  case "$ACTION" in
    fetch)
      fetch_installer
      exit 0
      ;;
    configure)
      configure_condarc
      configure_pip_mirror
      configure_shell
      verify_conda
      tulan_log "配置完成，请执行: source ~/.bashrc 或 source ~/.zshrc"
      exit 0
      ;;
    install)
      if [[ "$CONFIGURE_ONLY" == true ]]; then
        configure_condarc
        configure_pip_mirror
        configure_shell
        verify_conda
        exit 0
      fi
      ;;
  esac

  if [[ "$SKIP_INSTALL" != true ]]; then
    fetch_installer
    install_miniconda "$INSTALLER_PATH"
  elif [[ -x "${CONDA_PREFIX}/bin/conda" ]]; then
    :
  else
    tulan_error "未安装 Miniconda，请先运行: tulan conda install"
    exit 1
  fi

  configure_condarc
  configure_pip_mirror
  configure_shell
  verify_conda

  tulan_log "Miniconda 环境就绪"
  echo ""
  echo "  安装目录: ${CONDA_PREFIX}"
  echo "  conda 源: 阿里云（~/.condarc）"
  echo "  pip 源: 阿里云（~/.pip/pip.conf）"
  echo "  shell: ~/.bashrc、~/.zshrc 已配置"
  echo ""
  echo "  请执行: source ~/.bashrc  或  source ~/.zshrc"
}

main "$@"
