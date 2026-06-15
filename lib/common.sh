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

# Java / Node 运行时（~/.tulan-tools/state/env.sh）
if [[ -f "\${TULAN_TOOLS_HOME}/state/env.sh" ]]; then
  source "\${TULAN_TOOLS_HOME}/state/env.sh"
fi

# 国内镜像环境变量（brew mirrors 写入）
if [[ -f "\${TULAN_TOOLS_HOME}/state/mirrors.env" ]]; then
  source "\${TULAN_TOOLS_HOME}/state/mirrors.env"
fi

# 东八区时间环境（brew time 写入）
if [[ -f "\${TULAN_TOOLS_HOME}/state/time.env" ]]; then
  source "\${TULAN_TOOLS_HOME}/state/time.env"
fi

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

# 从 git remote URL 提取 owner/repo（兼容代理前缀 URL）
tulan_normalize_github_repo() {
  local remote="${1:-}"
  local owner repo _rest

  [[ -n "$remote" ]] || return 1
  remote="${remote%.git}"

  if [[ "$remote" == git@github.com:* ]]; then
    echo "${remote#git@github.com:}"
    return 0
  fi

  if [[ "$remote" == ssh://git@github.com/* ]]; then
    remote="${remote#ssh://git@github.com/}"
    IFS='/' read -r owner repo _rest <<< "$remote"
    [[ -n "$owner" && -n "$repo" ]] || return 1
    echo "${owner}/${repo}"
    return 0
  fi

  # 兼容 https://proxy/https://github.com/owner/repo 等形式
  if [[ "$remote" == *github.com/* ]]; then
    remote="${remote#*github.com/}"
    IFS='/' read -r owner repo _rest <<< "$remote"
    [[ -n "$owner" && -n "$repo" ]] || return 1
    echo "${owner}/${repo}"
    return 0
  fi

  if [[ "$remote" == */* && "$remote" != *://* ]]; then
    echo "$remote"
    return 0
  fi

  return 1
}

TULAN_OFFICIAL_GITHUB_REPO="${TULAN_OFFICIAL_GITHUB_REPO:-guangee/tulan-tools}"

# 当前安装目录的 git origin URL
tulan_git_origin_url() {
  local home
  home="$(tulan_get_home 2>/dev/null || echo "${TULAN_TOOLS_DEFAULT_HOME}")"
  git -C "$home" remote get-url origin 2>/dev/null || true
}

# 是否为官方 GitHub 源（github.com + guangee/tulan-tools）
tulan_is_official_github_origin() {
  local url repo
  url="$(tulan_git_origin_url)"
  [[ -n "$url" ]] || return 1
  [[ "$url" == *github.com* ]] || return 1
  repo="$(tulan_normalize_github_repo "$url" 2>/dev/null || true)"
  [[ "$repo" == "$TULAN_OFFICIAL_GITHUB_REPO" ]]
}

# 从 origin 解析 GitLab/Gitea 等（非 github.com）的 raw 下载基址与项目路径
# 输出: base=<url> project=<path>（project 可含子组，如 group/sub/tulan-tools）
tulan_git_host_project_from_remote() {
  local remote="${1:-$(tulan_git_origin_url)}"
  [[ -n "$remote" ]] || return 1
  [[ "$remote" == *github.com* ]] && return 1

  python3 - "$remote" <<'PY'
import os, sys
from urllib.parse import urlparse

remote = sys.argv[1].strip()
if not remote:
    sys.exit(1)

override_base = os.environ.get("TULAN_GIT_REMOTE_BASE", "").rstrip("/")

if remote.startswith("git@") and ":" in remote:
    hostpart, path = remote.split(":", 1)
    host = hostpart[4:]
    path = path.removesuffix(".git")
    base = override_base or f"https://{host}"
elif "://" in remote:
    p = urlparse(remote)
    if not p.netloc:
        sys.exit(1)
    path = p.path.strip("/").removesuffix(".git")
    base = override_base or f"{p.scheme}://{p.netloc}"
else:
    sys.exit(1)

if not path:
    sys.exit(1)

print(f"base={base}")
print(f"project={path}")
PY
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
  echo "[tulan-tools] $*" >&2
}

tulan_debug() {
  [[ "${TULAN_DEBUG:-}" == true ]] || return 0
  echo "[tulan-tools:debug] $*" >&2
}

tulan_verbose_init() {
  export TULAN_VERBOSE_EPOCH="${TULAN_VERBOSE_EPOCH:-$(date +%s)}"
  export TULAN_VERBOSE_STEP=0
}

tulan_verbose_elapsed() {
  local now
  now="$(date +%s)"
  echo $((now - ${TULAN_VERBOSE_EPOCH:-now}))
}

tulan_verbose() {
  [[ "${TULAN_VERBOSE:-}" == true ]] || return 0
  echo "[tulan-tools:verbose] [+$(tulan_verbose_elapsed)s] $*" >&2
}

tulan_verbose_step() {
  [[ "${TULAN_VERBOSE:-}" == true ]] || return 0
  TULAN_VERBOSE_STEP=$((TULAN_VERBOSE_STEP + 1))
  export TULAN_VERBOSE_STEP
  echo "[tulan-tools:verbose] [+$(tulan_verbose_elapsed)s] 步骤 ${TULAN_VERBOSE_STEP}: $*" >&2
}

tulan_error() {
  echo "[tulan-tools] 错误: $*" >&2
}

# 是否具备 root 权限（root 用户或 sudo 可用）
tulan_can_privilege() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] && return 0
  command -v sudo &>/dev/null
}

tulan_require_privilege() {
  if ! tulan_can_privilege; then
    tulan_error "需要 root 或 sudo 权限"
    return 1
  fi
}

# 以 root 执行命令（已是 root 则直接执行）
tulan_as_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}
