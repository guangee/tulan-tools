#!/usr/bin/env bash
# Docker Engine 静态包安装（bin 索引 / 上游）

set -euo pipefail

TULAN_DOCKER_REGISTRY_MIRROR="${TULAN_DOCKER_REGISTRY_MIRROR:-https://hub.coding-space.cn}"
TULAN_DOCKER_DAEMON_PATH="${TULAN_DOCKER_DAEMON_PATH:-/etc/docker/daemon.json}"
TULAN_DOCKER_BACKUP_DIR="${TULAN_DOCKER_BACKUP_DIR:-$(tulan_get_home)/state/docker-backup}"
TULAN_DOCKER_STATE_FILE="${TULAN_DOCKER_STATE_FILE:-$(tulan_get_home)/state/docker-config.json}"
TULAN_DOCKER_LOG_DRIVER="${TULAN_DOCKER_LOG_DRIVER:-json-file}"
TULAN_DOCKER_LOG_MAX_SIZE="${TULAN_DOCKER_LOG_MAX_SIZE:-10m}"
TULAN_DOCKER_LOG_MAX_FILE="${TULAN_DOCKER_LOG_MAX_FILE:-3}"
TULAN_DOCKER_LOG_COMPRESS="${TULAN_DOCKER_LOG_COMPRESS:-true}"
TULAN_DOCKER_DEFAULTS_FILE="${TULAN_DOCKER_DEFAULTS_FILE:-$(tulan_get_home)/config/docker.daemon.defaults.json}"
TULAN_DOCKER_BINARIES=(
  docker dockerd containerd runc ctr
  docker-init docker-proxy containerd-shim containerd-shim-runc-v2
)

tulan_docker_cellar_root() {
  echo "$(tulan_get_home)/cellar/docker/${1}"
}

tulan_docker_require_linux() {
  if [[ "$(uname -s | tr '[:upper:]' '[:lower:]')" != "linux" ]]; then
    tulan_error "Docker Engine 静态包仅支持 Linux"
    return 1
  fi
}

tulan_docker_latest_version() {
  tulan_python docker latest
}

tulan_docker_recent_versions() {
  tulan_python docker recent
}

tulan_docker_upstream_url() {
  local version="$1"
  local platform_key

  platform_key="$(tulan_manifest_platform_key)"
  case "$platform_key" in
    linux-amd64)
      echo "https://download.docker.com/linux/static/stable/x86_64/docker-${version}.tgz"
      ;;
    linux-arm64)
      echo "https://download.docker.com/linux/static/stable/aarch64/docker-${version}.tgz"
      ;;
    *)
      tulan_error "Docker 静态包不支持平台: ${platform_key}"
      return 1
      ;;
  esac
}

tulan_docker_link_binaries() {
  local version="$1" docker_dir="$2"
  local home bin_dir name link

  home="$(tulan_get_home)"
  bin_dir="${home}/bin"
  mkdir -p "$bin_dir"

  for name in "${TULAN_DOCKER_BINARIES[@]}"; do
    if [[ -f "${docker_dir}/${name}" ]]; then
      link="${bin_dir}/${name}"
      ln -sf "../cellar/docker/${version}/docker/${name}" "$link"
    fi
  done
}

tulan_docker_register() {
  local version="$1" docker_dir="$2" source="${3:-upstream}"

  tulan_python docker register \
    --version "$version" \
    --docker-dir "$docker_dir" \
    --source "$source" \
    --reg-path "$(tulan_binary_registry_path)"
}

tulan_docker_activate() {
  local version="$1"
  local docker_dir

  docker_dir="$(tulan_python docker docker-root \
    --version "$version" \
    --reg-path "$(tulan_binary_registry_path)")" || {
    tulan_error "版本未安装: docker ${version}"
    return 1
  }

  if [[ ! -x "${docker_dir}/docker" ]]; then
    tulan_error "Docker 安装损坏: ${docker_dir}"
    return 1
  fi

  tulan_docker_link_binaries "$version" "$docker_dir"

  tulan_python registry activate \
    --tool docker \
    --version "$version" \
    --reg-path "$(tulan_binary_registry_path)"

  tulan_log "已切换 docker -> ${version}"
}

tulan_docker_install_archive() {
  local version="$1" archive="$2" source="${3:-upstream}"
  local cellar_root docker_dir

  if ! command -v tar &>/dev/null; then
    tulan_error "安装 Docker 需要 tar"
    return 1
  fi

  cellar_root="$(tulan_docker_cellar_root "$version")"
  mkdir -p "$cellar_root"
  tulan_verbose_step "解压 Docker 静态包"
  tar -xzf "$archive" -C "$cellar_root"

  docker_dir="${cellar_root}/docker"
  if [[ ! -x "${docker_dir}/docker" ]] || [[ ! -x "${docker_dir}/dockerd" ]]; then
    tulan_error "Docker 解压异常: ${docker_dir}"
    return 1
  fi

  tulan_docker_register "$version" "$docker_dir" "$source"
  tulan_docker_link_binaries "$version" "$docker_dir"
  tulan_log "  已安装: ${docker_dir}（${source}）"
  tulan_log "  已链接: $(tulan_get_home)/bin/docker (+ dockerd, containerd, runc ...)"
  tulan_docker_post_install
}

tulan_docker_post_install() {
  tulan_log "启动守护进程: sudo dockerd"
  tulan_log "验证: docker version（需 dockerd 已运行）"
  tulan_log "完整守护进程配置: brew docker configure"
  if command -v sudo &>/dev/null; then
    tulan_docker_configure_registry "$TULAN_DOCKER_REGISTRY_MIRROR" || true
  else
    tulan_log "配置 daemon.json 需 sudo，可执行: brew docker configure"
  fi
}

tulan_docker_load_defaults() {
  if [[ -f "$TULAN_DOCKER_DEFAULTS_FILE" ]]; then
    tulan_python docker load-defaults "$TULAN_DOCKER_DEFAULTS_FILE"
  fi
}

tulan_docker_backup_daemon() {
  local stamp target
  tulan_require_privilege || return 1
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  target="${TULAN_DOCKER_BACKUP_DIR}/${stamp}"
  mkdir -p "$target"
  if tulan_as_root test -f "$TULAN_DOCKER_DAEMON_PATH"; then
    tulan_as_root cp -a "$TULAN_DOCKER_DAEMON_PATH" "${target}/daemon.json"
    echo "$stamp" > "${TULAN_DOCKER_BACKUP_DIR}/latest"
    tulan_log "已备份 daemon.json -> ${target}/daemon.json"
  else
    tulan_log "未发现现有 ${TULAN_DOCKER_DAEMON_PATH}，跳过备份"
  fi
}

tulan_docker_latest_backup() {
  local latest="${TULAN_DOCKER_BACKUP_DIR}/latest"
  [[ -f "$latest" ]] || return 1
  local stamp
  stamp="$(tr -d '[:space:]' < "$latest")"
  [[ -n "$stamp" && -f "${TULAN_DOCKER_BACKUP_DIR}/${stamp}/daemon.json" ]] || return 1
  echo "${TULAN_DOCKER_BACKUP_DIR}/${stamp}/daemon.json"
}

tulan_docker_save_state() {
  local mirror="$1" log_driver="$2" log_max_size="$3" log_max_file="$4" log_compress="$5"
  mkdir -p "$(dirname "$TULAN_DOCKER_STATE_FILE")"
  tulan_python docker save-state \
    --mirror "$mirror" \
    --log-driver "$log_driver" \
    --log-max-size "$log_max_size" \
    --log-max-file "$log_max_file" \
    --log-compress "$log_compress" \
    --state-path "$TULAN_DOCKER_STATE_FILE" \
    --daemon-path "$TULAN_DOCKER_DAEMON_PATH"
}

tulan_docker_build_daemon_json() {
  local mirror="$1" log_driver="$2" log_max_size="$3" log_max_file="$4" log_compress="$5"
  tulan_python docker build-daemon \
    --mirror "$mirror" \
    --log-driver "$log_driver" \
    --log-max-size "$log_max_size" \
    --log-max-file "$log_max_file" \
    --log-compress "$log_compress" \
    --daemon-path "$TULAN_DOCKER_DAEMON_PATH"
}

tulan_docker_apply_daemon_config() {
  local mirror="${1:-$TULAN_DOCKER_REGISTRY_MIRROR}"
  local log_driver="${2:-$TULAN_DOCKER_LOG_DRIVER}"
  local log_max_size="${3:-$TULAN_DOCKER_LOG_MAX_SIZE}"
  local log_max_file="${4:-$TULAN_DOCKER_LOG_MAX_FILE}"
  local log_compress="${5:-$TULAN_DOCKER_LOG_COMPRESS}"
  local tmp json

  tulan_docker_require_linux || return 1
  tulan_require_privilege || return 1

  tmp="$(mktemp)"
  json="$(tulan_docker_build_daemon_json "$mirror" "$log_driver" "$log_max_size" "$log_max_file" "$log_compress")"
  printf '%s\n' "$json" > "$tmp"

  tulan_as_root mkdir -p "$(dirname "$TULAN_DOCKER_DAEMON_PATH")"
  tulan_as_root cp "$tmp" "$TULAN_DOCKER_DAEMON_PATH"
  rm -f "$tmp"

  tulan_docker_save_state "$mirror" "$log_driver" "$log_max_size" "$log_max_file" "$log_compress"
  tulan_log "已写入 ${TULAN_DOCKER_DAEMON_PATH}"
  tulan_docker_try_restart
}

tulan_docker_try_restart() {
  if command -v systemctl &>/dev/null && systemctl list-units --type=service 2>/dev/null | grep -q '\bdocker\.service'; then
    if tulan_as_root systemctl is-active docker &>/dev/null; then
      tulan_as_root systemctl restart docker && tulan_log "已重启 docker 服务" && return 0
    fi
  fi
  if pgrep dockerd >/dev/null 2>&1; then
    tulan_log "检测到 dockerd 进程，请手动重启使配置生效:"
    tulan_log "  sudo systemctl restart docker   # 若使用 systemd"
    tulan_log "  或 sudo pkill dockerd && sudo dockerd &   # 静态安装"
  else
    tulan_log "dockerd 未运行，下次启动时生效"
  fi
}

tulan_docker_prompt_config() {
  local mirror log_driver log_max_size log_max_file compress_input

  if [[ -n "${DOCKER_REGISTRY_MIRROR:-}" ]]; then
    export TULAN_DOCKER_REGISTRY_MIRROR="$DOCKER_REGISTRY_MIRROR"
  fi
  if [[ -n "${DOCKER_LOG_DRIVER:-}" ]]; then
    export TULAN_DOCKER_LOG_DRIVER="$DOCKER_LOG_DRIVER"
  fi
  if [[ -n "${DOCKER_LOG_MAX_SIZE:-}" ]]; then
    export TULAN_DOCKER_LOG_MAX_SIZE="$DOCKER_LOG_MAX_SIZE"
  fi
  if [[ -n "${DOCKER_LOG_MAX_FILE:-}" ]]; then
    export TULAN_DOCKER_LOG_MAX_FILE="$DOCKER_LOG_MAX_FILE"
  fi
  if [[ -n "${DOCKER_LOG_COMPRESS:-}" ]]; then
    export TULAN_DOCKER_LOG_COMPRESS="$DOCKER_LOG_COMPRESS"
  fi

  if [[ "${DOCKER_SKIP_PROMPT:-false}" == true ]]; then
    return 0
  fi

  if [[ -n "${DOCKER_REGISTRY_MIRROR:-}${DOCKER_LOG_DRIVER:-}${DOCKER_LOG_MAX_SIZE:-}${DOCKER_LOG_MAX_FILE:-}" ]]; then
    return 0
  fi

  echo ""
  echo "Docker 守护进程配置"
  echo "────────────────────────────────────"
  echo "  配置文件: ${TULAN_DOCKER_DAEMON_PATH}"
  echo ""

  read -r -p "镜像加速地址 [${TULAN_DOCKER_REGISTRY_MIRROR}]: " mirror
  mirror="${mirror:-$TULAN_DOCKER_REGISTRY_MIRROR}"

  read -r -p "日志驱动 (json-file/local) [${TULAN_DOCKER_LOG_DRIVER}]: " log_driver
  log_driver="${log_driver:-$TULAN_DOCKER_LOG_DRIVER}"

  read -r -p "单日志文件大小 [${TULAN_DOCKER_LOG_MAX_SIZE}]: " log_max_size
  log_max_size="${log_max_size:-$TULAN_DOCKER_LOG_MAX_SIZE}"

  read -r -p "日志保留份数 [${TULAN_DOCKER_LOG_MAX_FILE}]: " log_max_file
  log_max_file="${log_max_file:-$TULAN_DOCKER_LOG_MAX_FILE}"

  if [[ "$log_driver" == "json-file" ]]; then
    read -r -p "压缩轮转日志? [Y/n]: " compress_input
    compress_input="${compress_input:-Y}"
    if [[ "$compress_input" =~ ^[yY]$ ]]; then
      log_compress=true
    else
      log_compress=false
    fi
  else
    log_compress="${TULAN_DOCKER_LOG_COMPRESS}"
  fi

  export TULAN_DOCKER_REGISTRY_MIRROR="$mirror"
  export TULAN_DOCKER_LOG_DRIVER="$log_driver"
  export TULAN_DOCKER_LOG_MAX_SIZE="$log_max_size"
  export TULAN_DOCKER_LOG_MAX_FILE="$log_max_file"
  export TULAN_DOCKER_LOG_COMPRESS="$log_compress"

  echo ""
  echo "  镜像加速: ${TULAN_DOCKER_REGISTRY_MIRROR}"
  echo "  日志驱动: ${TULAN_DOCKER_LOG_DRIVER}"
  echo "  单文件:   ${TULAN_DOCKER_LOG_MAX_SIZE}  保留: ${TULAN_DOCKER_LOG_MAX_FILE} 份"
  [[ "$log_driver" == "json-file" ]] && echo "  压缩:     ${TULAN_DOCKER_LOG_COMPRESS}"
  echo ""
}

tulan_docker_show_config_status() {
  local backup

  echo "Docker 守护进程配置"
  echo "────────────────────────────────────"
  echo "  daemon.json: ${TULAN_DOCKER_DAEMON_PATH}"
  echo "  状态记录:    ${TULAN_DOCKER_STATE_FILE}"
  echo "  备份目录:    ${TULAN_DOCKER_BACKUP_DIR}"
  echo ""

  if [[ -f "$TULAN_DOCKER_STATE_FILE" ]]; then
    tulan_python docker show-state "$TULAN_DOCKER_STATE_FILE"
    echo ""
  fi

  if tulan_as_root test -f "$TULAN_DOCKER_DAEMON_PATH" 2>/dev/null \
    || [[ -f "$TULAN_DOCKER_DAEMON_PATH" ]]; then
    echo "  当前 daemon.json:"
    if [[ -r "$TULAN_DOCKER_DAEMON_PATH" ]]; then
      sed 's/^/    /' "$TULAN_DOCKER_DAEMON_PATH"
    else
      tulan_as_root cat "$TULAN_DOCKER_DAEMON_PATH" 2>/dev/null | sed 's/^/    /' || echo "    (无法读取，需 sudo)"
    fi
  else
    echo "  当前 daemon.json: (不存在)"
  fi

  backup="$(tulan_docker_latest_backup 2>/dev/null || true)"
  if [[ -n "$backup" ]]; then
    echo ""
    echo "  最近备份: ${backup}"
  fi
}

tulan_docker_restore_daemon() {
  local backup
  backup="$(tulan_docker_latest_backup)" || {
    tulan_error "无可用备份（${TULAN_DOCKER_BACKUP_DIR}）"
    return 1
  }
  tulan_require_privilege || return 1
  tulan_as_root mkdir -p "$(dirname "$TULAN_DOCKER_DAEMON_PATH")"
  tulan_as_root cp -a "$backup" "$TULAN_DOCKER_DAEMON_PATH"
  tulan_log "已从备份还原 ${TULAN_DOCKER_DAEMON_PATH}"
  tulan_docker_try_restart
}

tulan_docker_configure_registry() {
  local mirror="$1"
  tulan_docker_load_defaults 2>/dev/null | while read -r line; do eval "$line"; done || true
  tulan_docker_apply_daemon_config "$mirror" \
    "${TULAN_DOCKER_LOG_DRIVER}" \
    "${TULAN_DOCKER_LOG_MAX_SIZE}" \
    "${TULAN_DOCKER_LOG_MAX_FILE}" \
    "${TULAN_DOCKER_LOG_COMPRESS}" || return 1
}

tulan_install_docker_from_bin() {
  local dry_run="${1:-false}"
  local verify="${2:-true}"
  local version tmp

  tulan_docker_require_linux || return 1
  version="$(tulan_manifest_tool_version "docker")"
  [[ -n "$version" ]] || { tulan_error "bin 索引无 Docker 版本"; return 1; }

  tulan_log "安装 Docker ${version}（bin 索引）"

  if [[ "$dry_run" == true ]]; then
    tulan_log "[dry-run] docker ${version}"
    return 0
  fi

  tmp="$(mktemp)"
  if ! tulan_download_archive_from_github "docker" "$tmp" "$verify"; then
    rm -f "$tmp"
    return 1
  fi
  tulan_docker_install_archive "$version" "$tmp" "github"
  rm -f "$tmp"
}

tulan_install_docker_upstream() {
  local requested_version="${1:-}"
  local dry_run="${2:-false}"
  local version url tmp

  tulan_docker_require_linux || return 1
  version="${requested_version:-$(tulan_docker_latest_version)}"
  [[ -n "$version" ]] || { tulan_error "无法获取 Docker 最新版本"; return 1; }

  url="$(tulan_docker_upstream_url "$version")"
  tulan_log "安装 Docker ${version}（上游静态包）"
  tulan_debug "URL: ${url}"

  if [[ "$dry_run" == true ]]; then
    tulan_log "[dry-run] docker ${version}"
    return 0
  fi

  tmp="$(mktemp)"
  tulan_fetch_url "$url" "$tmp"
  tulan_verbose_step "安装 Docker ${version}"
  tulan_docker_install_archive "$version" "$tmp" "upstream"
  rm -f "$tmp"
}

tulan_docker_show_versions() {
  local index_ver upstream_latest recent installed

  index_ver="$(tulan_manifest_index_version_display "docker" 2>/dev/null || echo "待同步")"
  upstream_latest="$(tulan_docker_latest_version 2>/dev/null || echo "")"
  recent="$(tulan_docker_recent_versions 2>/dev/null || echo "")"

  echo "Docker Engine（静态包）"
  echo "────────────────────────────────────"
  echo "  bin 索引版本（brew install 默认）: ${index_ver}"
  if [[ -n "$upstream_latest" ]]; then
    echo "  上游最新版本: ${upstream_latest}"
  fi
  if [[ -n "$recent" ]]; then
    echo "  上游近期版本: ${recent}"
  fi

  if [[ -f "$(tulan_binary_registry_path)" ]]; then
    installed="$(tulan_python registry versions-display --tool docker --reg-path "$(tulan_binary_registry_path)" 2>/dev/null || true)"
    if [[ -n "$installed" ]]; then
      echo "  本地已装（* 当前）: ${installed}"
    else
      echo "  本地已装: (无)"
    fi
  else
    echo "  本地已装: (无)"
  fi

  echo ""
  echo "  安装最新: brew install docker"
  echo "  指定版本: brew install docker --version <VER> --source upstream"
  echo "  切换版本: brew use docker <VER>"
  echo "  启动守护进程: sudo dockerd"
}

tulan_docker_uninstall() {
  local version="${1:-}"
  local home reg

  home="$(tulan_get_home)"
  reg="$(tulan_binary_registry_path)"

  if [[ ! -f "$reg" ]]; then
    tulan_error "未安装: docker"
    return 1
  fi

  tulan_python docker uninstall \
    --version "$version" \
    --reg-path "$reg" \
    --home "$home"

  local rc=$?
  if [[ $rc -eq 2 ]]; then
    tulan_error "未安装: docker"
    return 1
  fi
  tulan_log "已卸载: docker${version:+ ${version}}"
}
