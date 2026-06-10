#!/usr/bin/env bash
# tulan-tools 软件包管理

set -euo pipefail

TULAN_PKG_DIR="$(tulan_get_home)/packages"
TULAN_PKG_STATE_DIR="${HOME}/.tulan-tools/state/packages"

# 读取 manifest.json 字段
tulan_pkg_read_manifest() {
  local pkg_dir="$1"
  local field="$2"
  local manifest="${pkg_dir}/manifest.json"

  if [[ ! -f "$manifest" ]]; then
    tulan_error "缺少 manifest.json: ${pkg_dir}"
    return 1
  fi

  # 使用 python3 或 jq 解析 JSON
  if command -v python3 &>/dev/null; then
    python3 -c "
import json, sys
with open('${manifest}') as f:
    data = json.load(f)
print(data.get('${field}', ''))
" 2>/dev/null
  elif command -v jq &>/dev/null; then
    jq -r ".${field} // empty" "$manifest"
  else
    tulan_error "需要 python3 或 jq 来解析 manifest.json"
    return 1
  fi
}

# 判断私有包是否存在
tulan_pkg_exists() {
  local pkg_name="$1"
  [[ -n "$pkg_name" ]] || return 1
  [[ "$pkg_name" == _* ]] && return 1
  [[ -d "${TULAN_PKG_DIR}/${pkg_name}" ]] && [[ -f "${TULAN_PKG_DIR}/${pkg_name}/manifest.json" ]]
}

tulan_pkg_show_versions() {
  local pkg_name="$1"
  local pkg_dir version desc installed_ver

  if ! tulan_pkg_exists "$pkg_name"; then
    tulan_error "未知软件包: ${pkg_name}"
    return 1
  fi

  pkg_dir="${TULAN_PKG_DIR}/${pkg_name}"
  version="$(tulan_pkg_read_manifest "$pkg_dir" "version" 2>/dev/null || echo "?")"
  desc="$(tulan_pkg_read_manifest "$pkg_dir" "description" 2>/dev/null || echo "")"
  installed_ver=""
  if tulan_pkg_is_installed "$pkg_name"; then
    # shellcheck source=/dev/null
    source "${TULAN_PKG_STATE_DIR}/${pkg_name}.installed"
    installed_ver="${VERSION:-?}"
  fi

  echo "软件包: ${pkg_name}"
  [[ -n "$desc" ]] && echo "说明: ${desc}"
  echo "────────────────────────────────────"
  echo "  可用版本: v${version}"
  if [[ -n "$installed_ver" ]]; then
    echo "  已安装:   v${installed_ver}"
  else
    echo "  已安装:   (无)"
  fi
  echo ""
  echo "  安装: tulan install ${pkg_name}"
}

# 列出可用包
tulan_pkg_list_available() {
  echo "私有软件包:"
  echo "────────────────────────────────────"

  if [[ ! -d "$TULAN_PKG_DIR" ]]; then
    echo "  (无)"
    return 0
  fi

  for pkg_dir in "${TULAN_PKG_DIR}"/*/; do
    [[ -d "$pkg_dir" ]] || continue
    local name version desc
    name="$(basename "$pkg_dir")"
    [[ "$name" == _* ]] && continue
    version="$(tulan_pkg_read_manifest "$pkg_dir" "version" 2>/dev/null || echo "?")"
    desc="$(tulan_pkg_read_manifest "$pkg_dir" "description" 2>/dev/null || echo "")"
    printf "  %-20s v%-10s %s\n" "$name" "$version" "$desc"
  done
  echo ""
  echo "  安装: tulan install <包名>    版本: tulan versions <包名>"
}

# 列出已安装包
tulan_pkg_list_installed() {
  echo "已安装软件包:"
  echo "────────────────────────────────────"

  if [[ ! -d "$TULAN_PKG_STATE_DIR" ]]; then
    echo "  (无)"
    return 0
  fi

  for state_file in "${TULAN_PKG_STATE_DIR}"/*.installed; do
    [[ -f "$state_file" ]] || continue
    local name
    name="$(basename "$state_file" .installed)"
    # shellcheck source=/dev/null
    source "$state_file"
    printf "  %-20s v%-10s 安装于 %s\n" "$name" "${VERSION:-?}" "${INSTALLED_AT:-?}"
  done
}

# 检查包是否已安装
tulan_pkg_is_installed() {
  local pkg_name="$1"
  [[ -f "${TULAN_PKG_STATE_DIR}/${pkg_name}.installed" ]]
}

# 安装软件包
tulan_pkg_install() {
  local pkg_name="$1"
  local force="${2:-false}"
  local req_version="${3:-}"

  local pkg_dir="${TULAN_PKG_DIR}/${pkg_name}"

  if [[ ! -d "$pkg_dir" ]]; then
    tulan_error "软件包不存在: ${pkg_name}"
    tulan_pkg_list_available
    return 1
  fi

  local version
  version="$(tulan_pkg_read_manifest "$pkg_dir" "version")"

  if [[ -n "$req_version" ]] && [[ "$version" != "$req_version" ]]; then
    tulan_error "版本不匹配: 需要 ${req_version}, 可用 ${version}"
    return 1
  fi

  if tulan_pkg_is_installed "$pkg_name" && [[ "$force" != true ]]; then
    tulan_log "软件包已安装: ${pkg_name} v${version} (使用 --force 强制重装)"
    return 0
  fi

  tulan_log "安装软件包: ${pkg_name} v${version}"

  # 安装系统依赖
  local deps
  deps="$(tulan_pkg_read_manifest "$pkg_dir" "dependencies" 2>/dev/null || echo "[]")"
  if [[ -n "$deps" ]] && [[ "$deps" != "[]" ]]; then
    tulan_pkg_install_deps "$deps"
  fi

  # 执行包安装脚本
  local install_script="${pkg_dir}/install.sh"
  if [[ -f "$install_script" ]]; then
    chmod +x "$install_script"
    TULAN_PKG_NAME="$pkg_name" TULAN_PKG_VERSION="$version" TULAN_PKG_DIR="$pkg_dir" \
      bash "$install_script"
  fi

  # 链接 bin 文件
  local bin_dir="${pkg_dir}/bin"
  if [[ -d "$bin_dir" ]]; then
    mkdir -p "$(tulan_get_home)/bin"
    for bin_file in "${bin_dir}"/*; do
      [[ -f "$bin_file" ]] || continue
      local link_name
      link_name="$(basename "$bin_file")"
      ln -sf "$bin_file" "$(tulan_get_home)/bin/${link_name}"
      tulan_log "  链接命令: ${link_name}"
    done
  fi

  # 记录安装状态
  mkdir -p "$TULAN_PKG_STATE_DIR"
  cat > "${TULAN_PKG_STATE_DIR}/${pkg_name}.installed" <<EOF
PKG_NAME=${pkg_name}
VERSION=${version}
INSTALLED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PKG_DIR=${pkg_dir}
EOF

  tulan_log "安装完成: ${pkg_name} v${version}"
}

# 卸载软件包
tulan_pkg_uninstall() {
  local pkg_name="$1"
  local pkg_dir="${TULAN_PKG_DIR}/${pkg_name}"
  local state_file="${TULAN_PKG_STATE_DIR}/${pkg_name}.installed"

  if ! tulan_pkg_is_installed "$pkg_name"; then
    tulan_error "软件包未安装: ${pkg_name}"
    return 1
  fi

  tulan_log "卸载软件包: ${pkg_name}"

  # 执行卸载脚本
  local uninstall_script="${pkg_dir}/uninstall.sh"
  if [[ -f "$uninstall_script" ]]; then
    chmod +x "$uninstall_script"
    bash "$uninstall_script"
  fi

  # 移除 bin 链接
  local bin_dir="${pkg_dir}/bin"
  if [[ -d "$bin_dir" ]]; then
    for bin_file in "${bin_dir}"/*; do
      [[ -f "$bin_file" ]] || continue
      local link_name
      link_name="$(basename "$bin_file")"
      rm -f "$(tulan_get_home)/bin/${link_name}"
    done
  fi

  rm -f "$state_file"
  tulan_log "卸载完成: ${pkg_name}"
}

# 安装系统依赖（从 manifest dependencies 数组）
tulan_pkg_install_deps() {
  local deps_json="$1"
  local pkg_manager
  pkg_manager="$(tulan_detect_pkg_manager)"

  local deps
  if command -v python3 &>/dev/null; then
    deps="$(python3 -c "
import json
for d in json.loads('''${deps_json}'''):
    print(d)
" 2>/dev/null)"
  else
    return 0
  fi

  [[ -n "$deps" ]] || return 0

  tulan_log "安装依赖: $(echo "$deps" | tr '\n' ' ')"

  case "$pkg_manager" in
    apt)
      sudo apt-get install -y $deps
      ;;
    yum|dnf)
      sudo "${pkg_manager}" install -y $deps
      ;;
    *)
      tulan_error "请手动安装依赖: $deps"
      ;;
  esac
}
