#!/usr/bin/env bash
# tulan-tools 公共函数库

set -euo pipefail

TULAN_TOOLS_MARKER="# >>> tulan-tools >>>"
TULAN_TOOLS_MARKER_END="# <<< tulan-tools <<<"
TULAN_TOOLS_DEFAULT_HOME="${HOME}/.tulan-tools"
TULAN_TOOLS_DEFAULT_REPO="${TULAN_TOOLS_DEFAULT_REPO:-}"

# 检测操作系统类型: debian | ubuntu | centos | rhel | unknown
tulan_detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    local id="${ID:-unknown}"
    local id_like="${ID_LIKE:-}"

    case "$id" in
      debian) echo "debian" ;;
      ubuntu) echo "ubuntu" ;;
      centos|rhel|rocky|almalinux|fedora)
        if [[ "$id" == "fedora" ]]; then
          echo "fedora"
        else
          echo "centos"
        fi
        ;;
      *)
        if [[ "$id_like" == *"debian"* ]]; then
          echo "debian"
        elif [[ "$id_like" == *"rhel"* ]] || [[ "$id_like" == *"fedora"* ]]; then
          echo "centos"
        else
          echo "unknown"
        fi
        ;;
    esac
  else
    echo "unknown"
  fi
}

# 检测包管理器: apt | yum | dnf | unknown
tulan_detect_pkg_manager() {
  local os
  os="$(tulan_detect_os)"

  case "$os" in
    debian|ubuntu)
      if command -v apt-get &>/dev/null; then
        echo "apt"
      else
        echo "unknown"
      fi
      ;;
    centos|fedora)
      if command -v dnf &>/dev/null; then
        echo "dnf"
      elif command -v yum &>/dev/null; then
        echo "yum"
      else
        echo "unknown"
      fi
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

# 安装系统依赖
tulan_install_system_deps() {
  local pkg_manager
  pkg_manager="$(tulan_detect_pkg_manager)"

  local deps=(git curl)

  case "$pkg_manager" in
    apt)
      sudo apt-get update -qq
      sudo apt-get install -y "${deps[@]}"
      ;;
    yum)
      sudo yum install -y "${deps[@]}"
      ;;
    dnf)
      sudo dnf install -y "${deps[@]}"
      ;;
    *)
      echo "警告: 无法识别包管理器，请手动安装: ${deps[*]}" >&2
      ;;
  esac
}

# 获取 tulan-tools 根目录（固定为 ~/.tulan-tools）
tulan_get_home() {
  echo "${TULAN_TOOLS_HOME:-${TULAN_TOOLS_DEFAULT_HOME}}"
}

# 清理旧版本遗留在仓库根目录的状态文件
tulan_cleanup_legacy_files() {
  local home
  home="$(tulan_get_home)"
  rm -f "${home}/.install-info" "${home}/.last-update-check"
}

# 生成 shell 配置片段
tulan_shell_snippet() {
  local home="$1"
  cat <<EOF
${TULAN_TOOLS_MARKER}
# tulan-tools - 自动配置，请勿手动修改此区块
export TULAN_TOOLS_HOME="${home}"
export PATH="\${TULAN_TOOLS_HOME}/bin:\${PATH}"

# 加载自定义函数和别名
if [[ -f "\${TULAN_TOOLS_HOME}/lib/aliases.sh" ]]; then
  source "\${TULAN_TOOLS_HOME}/lib/aliases.sh"
fi

# 启动时检查更新（每天最多一次）
if [[ -f "\${TULAN_TOOLS_HOME}/scripts/update.sh" ]]; then
  "\${TULAN_TOOLS_HOME}/scripts/update.sh" --check-on-start 2>/dev/null || true
fi
${TULAN_TOOLS_MARKER_END}
EOF
}

# 向 rc 文件注入配置
tulan_inject_shell_config() {
  local rc_file="$1"
  local home="$2"

  if [[ ! -f "$rc_file" ]]; then
    touch "$rc_file"
  fi

  if grep -qF "${TULAN_TOOLS_MARKER}" "$rc_file" 2>/dev/null; then
    # 已存在，更新区块
    local tmp
    tmp="$(mktemp)"
    awk -v marker="${TULAN_TOOLS_MARKER}" -v end="${TULAN_TOOLS_MARKER_END}" '
      $0 ~ marker { skip=1; next }
      $0 ~ end { skip=0; next }
      !skip { print }
    ' "$rc_file" > "$tmp"
    mv "$tmp" "$rc_file"
  fi

  tulan_shell_snippet "$home" >> "$rc_file"
  echo "已配置: $rc_file"
}

# 从 rc 文件移除配置
tulan_remove_shell_config() {
  local rc_file="$1"

  if [[ ! -f "$rc_file" ]]; then
    return 0
  fi

  if grep -qF "${TULAN_TOOLS_MARKER}" "$rc_file" 2>/dev/null; then
    local tmp
    tmp="$(mktemp)"
    awk -v marker="${TULAN_TOOLS_MARKER}" -v end="${TULAN_TOOLS_MARKER_END}" '
      $0 ~ marker { skip=1; next }
      $0 ~ end { skip=0; next }
      !skip { print }
    ' "$rc_file" > "$tmp"
    mv "$tmp" "$rc_file"
    echo "已移除: $rc_file"
  fi
}

# 克隆或更新 git 仓库
tulan_git_sync() {
  local repo_url="$1"
  local target_dir="$2"
  local branch="${3:-master}"

  if [[ -d "${target_dir}/.git" ]]; then
    echo "更新仓库: ${target_dir}"
    git -C "${target_dir}" fetch origin
    git -C "${target_dir}" checkout "${branch}" 2>/dev/null || git -C "${target_dir}" checkout -b "${branch}" "origin/${branch}"
    git -C "${target_dir}" pull --ff-only origin "${branch}" || {
      echo "警告: 无法 fast-forward 更新，请手动处理冲突" >&2
      return 1
    }
  else
    echo "克隆仓库: ${repo_url} -> ${target_dir}"
    mkdir -p "$(dirname "${target_dir}")"
    git clone --branch "${branch}" --depth 1 "${repo_url}" "${target_dir}" 2>/dev/null || \
      git clone "${repo_url}" "${target_dir}"
  fi
}

# 日志
tulan_log() {
  echo "[tulan-tools] $*"
}

tulan_debug() {
  [[ "${TULAN_DEBUG:-}" == true ]] || return 0
  echo "[tulan-tools:debug] $*" >&2
}

tulan_error() {
  echo "[tulan-tools] 错误: $*" >&2
}
