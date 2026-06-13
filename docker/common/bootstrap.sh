#!/usr/bin/env bash
# 在容器内安装 tulan-tools 并验证 brew time / brew mirrors

set -euo pipefail

TULAN_SRC="${TULAN_SRC:-/src/tulan-tools}"
INSTALL_HOME="${HOME}/.tulan-tools"

_log() { echo "[docker-bootstrap] $*"; }
_die() { echo "[docker-bootstrap] 错误: $*" >&2; exit 1; }

detect_family() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    echo "${ID:-unknown}"
    return 0
  fi
  echo "unknown"
}

install_base_deps() {
  local family
  family="$(detect_family)"
  _log "检测到系统: ${family}"

  case "$family" in
    ubuntu|debian)
      apt-get update -qq
      apt-get install -y --no-install-recommends \
        git curl rsync ca-certificates sudo tzdata \
        python3 python3-pip \
        chrony systemd \
        iproute2
      ;;
    centos|rhel|rocky|almalinux)
      if command -v yum &>/dev/null; then
        yum install -y epel-release || true
        yum install -y \
          git curl rsync ca-certificates sudo tzdata \
          python3 python3-pip \
          chrony \
          iproute
      fi
      ;;
    *)
      _die "不支持的容器系统: ${family}"
      ;;
  esac
}

install_tulan_tools() {
  [[ -d "$TULAN_SRC" ]] || _die "缺少源码目录: ${TULAN_SRC}"
  _log "安装 tulan-tools: ${TULAN_SRC} -> ${INSTALL_HOME}"
  bash "${TULAN_SRC}/install.sh" --local --skip-deps
  export TULAN_TOOLS_HOME="${INSTALL_HOME}"
  export PATH="${INSTALL_HOME}/bin:${PATH}"
}

load_shell_env() {
  if [[ -f "${HOME}/.bashrc" ]]; then
    # shellcheck source=/dev/null
    source "${HOME}/.bashrc" || true
  fi
  if [[ -f "${INSTALL_HOME}/state/mirrors.env" ]]; then
    # shellcheck source=/dev/null
    source "${INSTALL_HOME}/state/mirrors.env"
  fi
}

verify_mirrors() {
  _log "验证 brew mirrors..."
  brew mirrors
  brew mirrors status

  [[ -f "${HOME}/.pip/pip.conf" ]] || _die "pip 配置未生成"
  [[ -f "${HOME}/.npmrc" ]] || _die "npm 配置未生成"
  [[ -f "${INSTALL_HOME}/state/mirrors.env" ]] || _die "Go 镜像 env 未生成"

  grep -q 'mirrors.aliyun.com' "${HOME}/.pip/pip.conf" || _die "pip 镜像地址不正确"
  grep -q 'npmmirror.com' "${HOME}/.npmrc" || _die "npm 镜像地址不正确"
  grep -q 'GOPROXY=' "${INSTALL_HOME}/state/mirrors.env" || _die "GOPROXY 未配置"

  if command -v npm &>/dev/null; then
    npm config get registry | grep -q 'npmmirror.com' || _die "npm registry 未生效"
  else
    _log "npm 未安装，跳过 registry 运行时验证（配置文件已写入）"
  fi
  if command -v go &>/dev/null; then
    go env GOPROXY | grep -q 'goproxy.cn' || _die "go GOPROXY 未生效"
  else
    _log "go 未安装，跳过 GOPROXY 运行时验证（mirrors.env 已写入）"
  fi
}

verify_time() {
  _log "验证 brew time probe..."
  brew time probe

  _log "验证 brew time install..."
  brew time

  if brew time status 2>/dev/null | grep -qiE 'Asia/Shanghai|CST|\+0800'; then
    _log "时区验证通过（timedatectl）"
  elif readlink -f /etc/localtime 2>/dev/null | grep -q 'Asia/Shanghai'; then
    _log "时区验证通过（/etc/localtime）"
  elif [[ "$(date +%Z 2>/dev/null)" == "CST" ]]; then
    _log "时区验证通过（date）"
  else
    _die "时区未设为东八区"
  fi

  _log "时间配置验证通过"
}

main() {
  install_base_deps
  install_tulan_tools
  load_shell_env
  verify_mirrors
  verify_time
  _log "全部验证通过 ✓"
}

main "$@"
