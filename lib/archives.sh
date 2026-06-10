#!/usr/bin/env bash
# 从 bin 分支下载 tar.gz 归档（JDK / Maven / Node）

set -euo pipefail

tulan_manifest_tool_version() {
  local tool="$1"
  local manifest
  manifest="$(tulan_resolve_manifest)" || return 1
  tulan_manifest_read "$manifest" "print(data['tools']['${tool}'].get('version', ''))"
}

tulan_manifest_tool_has_platform_path() {
  local tool="$1"
  local manifest platform_key path

  manifest="$(tulan_resolve_manifest)" || return 1
  platform_key="$(tulan_manifest_platform_key)"
  path="$(tulan_manifest_read "$manifest" "
tool = data['tools'].get('${tool}', {})
print(tool.get('paths', {}).get('${platform_key}', ''))
" 2>/dev/null || echo "")"
  [[ -n "$path" ]]
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

  tulan_log "下载归档 ${tool} ${version} (${platform_key})"
  tulan_debug "归档路径: ${path}"

  if ! tulan_download_binary_file "$repo" "$branch" "$path" "$dest" "$proxy"; then
    tulan_error "下载失败: ${tool}"
    tulan_error "  blob: $(tulan_binary_blob_url "$repo" "$branch" "$path")"
    tulan_error "  media: $(tulan_binary_media_url "$repo" "$branch" "$path")"
    return 1
  fi

  if [[ "$verify" == true ]] && [[ -n "$sha256" ]]; then
    local actual
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
  fi
}
