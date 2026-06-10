#!/usr/bin/env bash
# 从 bin 分支下载 tar.gz 归档（JDK / Maven / Node）

set -euo pipefail

tulan_manifest_tool_version() {
  local tool="$1"
  local manifest
  manifest="$(tulan_resolve_manifest)" || return 1
  tulan_manifest_read "$manifest" "print(data['tools']['${tool}'].get('version', ''))"
}

tulan_manifest_tool_platform_path() {
  local tool="$1"
  local manifest platform_key path

  manifest="$(tulan_resolve_manifest)" || return 1
  platform_key="$(tulan_manifest_platform_key)"
  path="$(tulan_manifest_read "$manifest" "
tool = data['tools'].get('${tool}', {})
print(tool.get('paths', {}).get('${platform_key}', ''))
" 2>/dev/null || echo "")"
  echo "$path"
}

tulan_manifest_tool_has_platform_path() {
  local path
  path="$(tulan_manifest_tool_platform_path "$1")"
  [[ -n "$path" ]]
}

tulan_manifest_index_version_display() {
  local tool="$1"
  local version path

  version="$(tulan_manifest_tool_version "$tool" 2>/dev/null || echo "")"
  path="$(tulan_manifest_tool_platform_path "$tool" 2>/dev/null || echo "")"

  if [[ -z "$path" ]] || [[ "$version" == "上游最新" ]] || [[ -z "$version" ]]; then
    echo "待同步"
    return 0
  fi
  echo "$version"
}

tulan_manifest_ensure_archive_path() {
  local tool="$1"

  if tulan_manifest_tool_has_platform_path "$tool"; then
    return 0
  fi

  tulan_verbose_step "刷新 bin 索引（缺少 ${tool} 归档路径）"
  tulan_log "索引中无 ${tool} 的 bin 归档路径，尝试刷新 manifest..."
  tulan_manifest_refresh true || return 1
  tulan_manifest_tool_has_platform_path "$tool"
}

tulan_archive_log_download_urls() {
  local tool="$1"
  local manifest repo branch platform_key path proxy

  path="$(tulan_manifest_tool_platform_path "$tool" 2>/dev/null || echo "")"
  [[ -n "$path" ]] || return 0

  manifest="$(tulan_resolve_manifest)" || return 0
  repo="$(tulan_manifest_get_repo "$manifest")"
  branch="$(tulan_manifest_read "$manifest" "print(data.get('branch', 'bin'))")"
  platform_key="$(tulan_manifest_platform_key)"
  proxy="$(tulan_get_github_proxy "$manifest")"

  tulan_log "bin 归档路径: ${path} (${platform_key})"
  if [[ -n "$proxy" ]]; then
    tulan_log "  blob 代理: $(tulan_proxy_url "$(tulan_binary_blob_url "$repo" "$branch" "$path")" "$proxy")"
  fi
  tulan_log "  media 直连: $(tulan_binary_media_url "$repo" "$branch" "$path")"
}

tulan_download_archive_from_github() {
  local tool="$1" dest="$2" verify="${3:-true}"

  local manifest repo branch platform_key path version sha256 proxy

  manifest="$(tulan_resolve_manifest)" || return 1

  repo="$(tulan_manifest_get_repo "$manifest")"
  branch="$(tulan_manifest_read "$manifest" "print(data.get('branch', 'bin'))")"
  platform_key="$(tulan_manifest_platform_key)"

  path="$(tulan_manifest_read "$manifest" "
tool = data['tools'].get('${tool}')
if not tool:
    sys.exit(1)
print(tool.get('paths', {}).get('${platform_key}', ''))
")" || {
    tulan_error "工具 ${tool} 不支持平台 ${platform_key}"
    return 1
  }

  if [[ -z "$path" ]]; then
    tulan_error "工具 ${tool} 在 ${platform_key} 上无 bin 归档"
    return 1
  fi

  version="$(tulan_manifest_read "$manifest" "print(data['tools']['${tool}'].get('version', ''))")"
  sha256="$(tulan_manifest_read "$manifest" "
print(data['tools']['${tool}'].get('sha256', {}).get('${platform_key}', ''))
" 2>/dev/null || echo "")"

  if [[ -n "${TULAN_BINARY_REQUESTED_VERSION:-}" ]] \
      && [[ "${TULAN_BINARY_REQUESTED_VERSION}" != "$version" ]]; then
    tulan_error "bin 索引版本为 ${version}，指定 ${TULAN_BINARY_REQUESTED_VERSION}"
    tulan_error "请使用: brew install ${tool} --version ${TULAN_BINARY_REQUESTED_VERSION} --source upstream"
    return 1
  fi

  [[ -n "$version" ]] || version="latest"
  proxy="$(tulan_get_github_proxy "$manifest")"

  tulan_verbose_step "下载归档 ${tool} ${version} (${platform_key})"
  tulan_log "下载归档 ${tool} ${version} (${platform_key})"
  tulan_debug "归档路径: ${path}"
  if [[ "${TULAN_VERBOSE:-}" == true ]]; then
    tulan_verbose "仓库: ${repo}  分支: ${branch}"
    tulan_verbose "归档路径: ${path}"
    tulan_verbose "索引版本: ${version}"
    [[ -n "$sha256" ]] && tulan_verbose "期望 SHA256: ${sha256}"
    tulan_archive_log_download_urls "$tool" 2>/dev/null || true
  fi

  if ! tulan_download_binary_file "$repo" "$branch" "$path" "$dest" "$proxy"; then
    tulan_error "下载失败: ${tool}"
    tulan_error "  blob: $(tulan_binary_blob_url "$repo" "$branch" "$path")"
    tulan_error "  media: $(tulan_binary_media_url "$repo" "$branch" "$path")"
    return 1
  fi

  if [[ "$verify" == true ]] && [[ -n "$sha256" ]]; then
    local actual
    tulan_verbose_step "SHA256 校验"
    if command -v sha256sum &>/dev/null; then
      actual="$(sha256sum "$dest" | awk '{print $1}')"
    else
      actual="$(shasum -a 256 "$dest" | awk '{print $1}')"
    fi
    if [[ "$sha256" != "$actual" ]]; then
      rm -f "$dest"
      tulan_error "SHA256 校验失败: ${tool}"
      return 1
    fi
    tulan_log "  SHA256 校验通过"
    tulan_verbose "SHA256 校验通过: ${actual}"
  elif [[ "${TULAN_VERBOSE:-}" == true ]] && [[ -z "$sha256" ]]; then
    tulan_verbose "跳过 SHA256 校验（索引未记录）"
  fi
}
