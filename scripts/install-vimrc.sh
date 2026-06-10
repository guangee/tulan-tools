#!/usr/bin/env bash
# 安装 vim、vimrc 配置，并将 vim 设为系统默认编辑器

set -euo pipefail

_SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${_SCRIPT_ROOT}/lib/common.sh"

VIMRC_REPO="${TULAN_VIMRC_REPO:-https://git.tulan.wang/github/vimrc.git}"
VIM_RUNTIME="${TULAN_VIM_RUNTIME:-${HOME}/.vim_runtime}"
VIM_EDITOR_MARKER="# >>> tulan-vim-editor >>>"
VIM_EDITOR_MARKER_END="# <<< tulan-vim-editor <<<"

CONFIGURE_ONLY=false
SKIP_VIMRC=false
REFRESH_REPO=false
SKIP_EDITOR=false
ACTION="install"

usage() {
  cat <<EOF
用法: brew vim [install|configure|fetch] [选项]

子命令:
  install       安装 vim、vimrc，并配置默认编辑器（默认）
  configure     仅配置 EDITOR/VISUAL、git core.editor、系统 editor
  fetch         仅克隆/更新 vimrc 仓库

选项:
  --refresh           强制重新克隆 ~/.vim_runtime
  --configure-only    同 configure 子命令
  --skip-vimrc        跳过 vimrc 安装，仅安装 vim 与编辑器配置
  --skip-editor       跳过默认编辑器配置
  --repo URL          vimrc 仓库地址
  --runtime DIR       vimrc 安装目录，默认 ~/.vim_runtime
  --debug             显示详细信息
  -h, --help          显示帮助

说明:
  vimrc 仓库: ${VIMRC_REPO}
  运行时目录: ${VIM_RUNTIME}
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    install) ACTION="install"; shift ;;
    configure) ACTION="configure"; CONFIGURE_ONLY=true; shift ;;
    fetch) ACTION="fetch"; SKIP_VIMRC=false; shift ;;
    --configure-only) CONFIGURE_ONLY=true; shift ;;
    --skip-vimrc) SKIP_VIMRC=true; shift ;;
    --skip-editor) SKIP_EDITOR=true; shift ;;
    --refresh) REFRESH_REPO=true; shift ;;
    --repo) VIMRC_REPO="$2"; shift 2 ;;
    --runtime) VIM_RUNTIME="$2"; shift 2 ;;
    --debug) export TULAN_DEBUG=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) tulan_error "未知参数: $1"; usage; exit 1 ;;
    *) tulan_error "未知参数: $1"; usage; exit 1 ;;
  esac
done

require_git() {
  if ! command -v git &>/dev/null; then
    tulan_error "需要 git，请先安装"
    exit 1
  fi
}

require_sudo_if_needed() {
  if command -v vim &>/dev/null; then
    return 0
  fi
  if ! command -v sudo &>/dev/null; then
    tulan_error "安装 vim 需要 sudo 权限"
    exit 1
  fi
  if ! sudo -n true 2>/dev/null; then
    tulan_log "安装 vim 需要 root 权限，请输入 sudo 密码..."
    sudo -v
  fi
}

install_vim_package() {
  if command -v vim &>/dev/null; then
    tulan_log "vim 已安装: $(vim --version | head -1)"
    return 0
  fi

  local pkg_manager
  pkg_manager="$(tulan_detect_pkg_manager)"

  tulan_log "未检测到 vim，正在安装..."

  case "$pkg_manager" in
    apt)
      sudo apt-get update -qq
      sudo apt-get install -y vim
      ;;
    yum)
      sudo yum install -y vim
      ;;
    dnf)
      sudo dnf install -y vim
      ;;
    *)
      if [[ "$(uname -s)" == "Darwin" ]]; then
        if command -v brew &>/dev/null; then
          brew install vim
        elif [[ -x /usr/bin/vim ]]; then
          tulan_log "使用系统自带 vim: /usr/bin/vim"
          return 0
        else
          tulan_error "请手动安装 vim（推荐: brew install vim）"
          return 1
        fi
      else
        tulan_error "无法识别包管理器，请手动安装 vim"
        return 1
      fi
      ;;
  esac

  tulan_log "vim 安装完成: $(vim --version | head -1)"
}

vim_editor_snippet() {
  cat <<EOF
${VIM_EDITOR_MARKER}
# brew vim — 默认文本编辑器
export EDITOR=vim
export VISUAL=vim
${VIM_EDITOR_MARKER_END}
EOF
}

inject_editor_to_rc() {
  local rc_file="$1"

  [[ -f "$rc_file" ]] || touch "$rc_file"

  if grep -qF "${VIM_EDITOR_MARKER}" "$rc_file" 2>/dev/null; then
    local tmp
    tmp="$(mktemp)"
    awk -v marker="${VIM_EDITOR_MARKER}" -v end="${VIM_EDITOR_MARKER_END}" '
      $0 ~ marker { skip=1; next }
      $0 ~ end { skip=0; next }
      !skip { print }
    ' "$rc_file" > "$tmp"
    mv "$tmp" "$rc_file"
  fi

  vim_editor_snippet >> "$rc_file"
  tulan_log "已配置编辑器环境变量: ${rc_file}"
}

configure_git_editor() {
  if ! command -v git &>/dev/null; then
    tulan_log "未安装 git，跳过 core.editor 配置"
    return 0
  fi

  git config --global core.editor vim
  tulan_log "已设置 git core.editor=vim"
  tulan_debug "当前值: $(git config --global --get core.editor 2>/dev/null || echo '')"
}

configure_system_editor() {
  local vim_path

  vim_path="$(command -v vim || true)"
  [[ -n "$vim_path" ]] || return 0

  if command -v update-alternatives &>/dev/null; then
    if sudo -n true 2>/dev/null || sudo -v 2>/dev/null; then
      sudo update-alternatives --install /usr/bin/editor editor "$vim_path" 50 2>/dev/null || true
      if sudo update-alternatives --set editor "$vim_path" 2>/dev/null; then
        tulan_log "已设置系统默认 editor: ${vim_path}"
      else
        tulan_log "update-alternatives 未切换 editor（可能需手动选择）"
      fi
    else
      tulan_log "跳过系统 editor 配置（需要 sudo）"
    fi
  fi
}

configure_default_editor() {
  inject_editor_to_rc "${HOME}/.bashrc"
  inject_editor_to_rc "${HOME}/.zshrc"
  configure_git_editor
  configure_system_editor
}

fetch_vimrc_repo() {
  require_git

  if [[ -d "${VIM_RUNTIME}/.git" ]] && [[ "$REFRESH_REPO" != true ]]; then
    tulan_log "更新 vimrc 仓库: ${VIM_RUNTIME}"
    git -C "$VIM_RUNTIME" pull --ff-only
    return 0
  fi

  if [[ "$REFRESH_REPO" == true ]] && [[ -d "$VIM_RUNTIME" ]]; then
    tulan_log "强制重新克隆，删除: ${VIM_RUNTIME}"
    rm -rf "$VIM_RUNTIME"
  fi

  tulan_log "克隆 vimrc 仓库"
  tulan_debug "repo: ${VIMRC_REPO}"
  tulan_debug "dest: ${VIM_RUNTIME}"
  git clone --depth=1 "$VIMRC_REPO" "$VIM_RUNTIME"
  tulan_log "vimrc 仓库就绪: ${VIM_RUNTIME}"
}

install_vimrc_config() {
  local installer="${VIM_RUNTIME}/install_basic_vimrc.sh"

  if [[ ! -f "$installer" ]]; then
    tulan_error "未找到安装脚本: ${installer}"
    return 1
  fi

  tulan_log "执行 vimrc 安装脚本..."
  sh "$installer"
  tulan_log "vimrc 配置完成"
}

main() {
  case "$ACTION" in
    fetch)
      fetch_vimrc_repo
      exit 0
      ;;
    configure)
      install_vim_package
      configure_default_editor
      tulan_log "默认编辑器配置完成"
      echo ""
      echo "  EDITOR/VISUAL: vim（~/.bashrc、~/.zshrc）"
      echo "  git merge/editor: vim（git config --global core.editor）"
      echo ""
      echo "  请执行: source ~/.bashrc  或  source ~/.zshrc"
      exit 0
      ;;
    install)
      if [[ "$CONFIGURE_ONLY" == true ]]; then
        install_vim_package
        configure_default_editor
        exit 0
      fi
      ;;
  esac

  require_sudo_if_needed
  install_vim_package

  if [[ "$SKIP_VIMRC" != true ]]; then
    fetch_vimrc_repo
    install_vimrc_config
  fi

  if [[ "$SKIP_EDITOR" != true ]]; then
    configure_default_editor
  fi

  tulan_log "vim 环境就绪"
  echo ""
  echo "  vimrc: ${VIM_RUNTIME}"
  echo "  默认编辑器: vim"
  echo "  git core.editor: vim"
  echo ""
  echo "  请执行: source ~/.bashrc  或  source ~/.zshrc"
}

main "$@"
