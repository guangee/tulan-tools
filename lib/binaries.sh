#!/usr/bin/env bash
# 从 GitHub bin 分支公开链接下载二进制（客户端无需 git-lfs）

set -euo pipefail

TULAN_MANIFEST_PATH="${TULAN_MANIFEST_PATH:-}"
TULAN_MANIFEST_TTL="${TULAN_MANIFEST_TTL:-86400}"
TULAN_MANIFEST_DEFAULT_REPO="${TULAN_GITHUB_REPO:-guangee/tulan-tools}"
TULAN_MANIFEST_DEFAULT_BRANCH="bin"
TULAN_MANIFEST_DEFAULT_FILE="binaries.manifest.json"
TULAN_MANIFEST_PROXY_DEFAULT="https://gh.coding-space.cn/"

tulan_manifest_cache_path() {
  echo "$(tulan_get_home)/state/binaries.manifest.json"
}

tulan_manifest_cache_ts_path() {
  echo "$(tulan_get_home)/state/manifest-fetched-at"
}

# 推断默认仓库地址（owner/repo）
tulan_manifest_default_repo() {
  local home remote normalized

  if [[ -n "${TULAN_GITHUB_REPO:-}" ]]; then
    if normalized="$(tulan_normalize_github_repo "${TULAN_GITHUB_REPO}")"; then
      echo "$normalized"
      return 0
    fi
    echo "${TULAN_GITHUB_REPO}"
    return 0
  fi

  home="$(tulan_get_home)"
  if git -C "$home" remote get-url origin &>/dev/null; then
    remote="$(git -C "$home" remote get-url origin)"
    if normalized="$(tulan_normalize_github_repo "$remote")"; then
      echo "$normalized"
      return 0
    fi
  fi

  echo "${TULAN_MANIFEST_DEFAULT_REPO}"
}

# 构建 manifest 远程 raw URL
tulan_manifest_remote_url() {
  local repo="${1:-$(tulan_manifest_default_repo)}"
  local branch="${2:-${TULAN_MANIFEST_DEFAULT_BRANCH}}"
  local file="${3:-${TULAN_MANIFEST_DEFAULT_FILE}}"
  echo "https://raw.githubusercontent.com/${repo}/${branch}/${file}"
}

tulan_manifest_cache_expired() {
  local ts_file now last
  ts_file="$(tulan_manifest_cache_ts_path)"
  [[ -f "$ts_file" ]] || return 0
  last="$(cat "$ts_file")"
  now="$(date +%s)"
  (( now - last >= TULAN_MANIFEST_TTL ))
}

# 从 bin 分支拉取 manifest 到本地缓存
tulan_manifest_refresh() {
  local force="${1:-false}"
  local cache proxy url repo

  cache="$(tulan_manifest_cache_path)"
  repo="$(tulan_manifest_default_repo)"

  if [[ "$force" != true ]] && [[ -f "$cache" ]] && ! tulan_manifest_cache_expired; then
    return 0
  fi

  if [[ -n "${TULAN_MANIFEST_URL:-}" ]]; then
    url="${TULAN_MANIFEST_URL}"
  else
    url="$(tulan_manifest_remote_url "$repo")"
  fi

  proxy="$(tulan_manifest_proxy)"
  mkdir -p "$(dirname "$cache")"

  tulan_debug "manifest 仓库: ${repo}"
  tulan_debug "manifest 分支: ${TULAN_MANIFEST_DEFAULT_BRANCH}"
  tulan_debug "manifest 直连: ${url}"
  if [[ -n "$proxy" ]]; then
    tulan_debug "manifest 代理前缀: ${proxy}"
    tulan_debug "manifest 代理 URL: $(tulan_proxy_url "$url" "$proxy")"
  fi
  tulan_debug "manifest 缓存: ${cache}"

  if [[ -n "$proxy" ]]; then
    tulan_log "刷新二进制索引: $(tulan_proxy_url "$url" "$proxy")"
  else
    tulan_log "刷新二进制索引: ${url}"
  fi
  if ! tulan_curl_download "$url" "${cache}.tmp" "$proxy"; then
    [[ -f "$cache" ]] && { tulan_log "使用本地缓存 manifest"; return 0; }
    tulan_error "无法获取 binaries.manifest.json"
    tulan_error "  直连: ${url}"
    if [[ -n "$proxy" ]]; then
      tulan_error "  代理: $(tulan_proxy_url "$url" "$proxy")"
    fi
    return 1
  fi

  mv "${cache}.tmp" "$cache"
  date +%s > "$(tulan_manifest_cache_ts_path)"
  tulan_log "索引已缓存: ${cache}"
}

# 解析 JSON 字段（依赖 python3）
tulan_manifest_read() {
  local manifest="$1" expr="$2"
  python3 -c "
import json, sys
with open('${manifest}') as f:
    data = json.load(f)
${expr}
"
}

tulan_manifest_get_repo() {
  local manifest="$1"
  local repo
  repo="$(tulan_manifest_read "$manifest" "print(data.get('repository', '') or '')" 2>/dev/null || true)"
  if [[ -n "$repo" ]]; then
    echo "$repo"
  else
    tulan_manifest_default_repo
  fi
}

tulan_binary_media_url() {
  local repo="$1" branch="$2" path="$3"
  echo "https://media.githubusercontent.com/media/${repo}/${branch}/${path}"
}

# gh-proxy 兼容的 blob 页面 URL（优先走代理）
tulan_binary_blob_url() {
  local repo="$1" branch="$2" path="$3"
  echo "https://github.com/${repo}/blob/${branch}/${path}"
}

# 下载 bin 分支二进制：blob 代理 → media 直连 → GitHub API
tulan_download_binary_file() {
  local repo="$1" branch="$2" path="$3" dest="$4" proxy="$5"
  local blob media api

  blob="$(tulan_binary_blob_url "$repo" "$branch" "$path")"
  media="$(tulan_binary_media_url "$repo" "$branch" "$path")"

  if [[ -n "$proxy" ]]; then
    tulan_debug "blob 代理: $(tulan_proxy_url "$blob" "$proxy")"
    if tulan_curl_download "$blob" "$dest" "$proxy"; then
      return 0
    fi
    tulan_debug "blob 代理未成功，尝试 media 直连"
  fi

  tulan_debug "media 直连: ${media}"
  if tulan_curl_download "$media" "$dest" ""; then
    return 0
  fi

  tulan_log "media 失败，尝试 GitHub API..."
  api="$(tulan_binary_api_url "$repo" "$branch" "$path")" || return 1
  tulan_debug "API 直连: ${api}"
  tulan_curl_download "$api" "$dest" ""
}

# manifest 刷新专用代理（默认 gh.coding-space.cn）
tulan_manifest_proxy() {
  if [[ "${TULAN_GITHUB_PROXY_DISABLED:-}" == "true" ]] \
      || [[ "${TULAN_MANIFEST_PROXY_DISABLED:-}" == "true" ]]; then
    return 0
  fi

  if [[ -n "${TULAN_MANIFEST_PROXY:-}" ]]; then
    echo "${TULAN_MANIFEST_PROXY%/}/"
    return 0
  fi

  if [[ -n "${TULAN_GITHUB_PROXY:-}" ]]; then
    echo "${TULAN_GITHUB_PROXY%/}/"
    return 0
  fi

  echo "${TULAN_MANIFEST_PROXY_DEFAULT}"
}

tulan_get_github_proxy() {
  local manifest="${1:-}"

  if [[ "${TULAN_GITHUB_PROXY_DISABLED:-}" == "true" ]]; then
    return 0
  fi

  if [[ -n "${TULAN_GITHUB_PROXY:-}" ]]; then
    echo "${TULAN_GITHUB_PROXY}"
    return 0
  fi

  if [[ -n "$manifest" ]] && [[ -f "$manifest" ]]; then
    local from_manifest
    from_manifest="$(tulan_manifest_read "$manifest" "print(data.get('github_proxy', '') or '')" 2>/dev/null || true)"
    if [[ -n "$from_manifest" ]]; then
      echo "$from_manifest"
      return 0
    fi
  fi

  echo "${TULAN_MANIFEST_PROXY_DEFAULT}"
}

tulan_proxy_url() {
  local url="$1"
  local proxy="${2:-}"
  if [[ -z "$proxy" ]]; then
    echo "$url"
  else
    echo "${proxy%/}/${url}"
  fi
}

tulan_curl_download() {
  local url="$1"
  local dest="$2"
  local proxy="${3:-}"
  local proxied err_file curl_err

  proxied="$(tulan_proxy_url "$url" "$proxy")"
  err_file="$(mktemp)"

  _tulan_curl_try() {
    local target="$1"
    local label="$2"
    tulan_debug "${label}: ${target}"
    if curl -fsSL "$target" -o "$dest" 2>"$err_file"; then
      return 0
    fi
    curl_err="$(tr '\n' ' ' < "$err_file" 2>/dev/null | sed 's/  */ /g')"
    tulan_debug "${label} 失败: ${curl_err}"
    return 1
  }

  if [[ -n "$proxy" ]] && [[ "$proxied" != "$url" ]]; then
    if _tulan_curl_try "$proxied" "代理"; then
      rm -f "$err_file"
      return 0
    fi
    tulan_debug "代理下载失败，尝试直连..."
  fi

  if _tulan_curl_try "$url" "直连"; then
    rm -f "$err_file"
    return 0
  fi

  rm -f "$err_file"
  return 1
}

tulan_binary_api_url() {
  local repo="$1" branch="$2" path="$3"
  python3 -c "
import json, urllib.request
url = 'https://api.github.com/repos/${repo}/contents/${path}?ref=${branch}'
req = urllib.request.Request(url, headers={'Accept': 'application/vnd.github+json'})
with urllib.request.urlopen(req) as r:
    data = json.load(r)
print(data.get('download_url', ''))
"
}

tulan_resolve_manifest() {
  local force="${TULAN_MANIFEST_FORCE_REFRESH:-false}"

  if [[ -n "${TULAN_MANIFEST_URL:-}" ]]; then
    local tmp proxy
    tmp="$(mktemp)"
    proxy="$(tulan_manifest_proxy)"
    tulan_curl_download "${TULAN_MANIFEST_URL}" "$tmp" "$proxy"
    echo "$tmp"
    return 0
  fi

  if [[ -n "$TULAN_MANIFEST_PATH" ]] && [[ -f "$TULAN_MANIFEST_PATH" ]]; then
    echo "$TULAN_MANIFEST_PATH"
    return 0
  fi

  tulan_manifest_refresh "$force" || return 1
  echo "$(tulan_manifest_cache_path)"
}

tulan_manifest_platform_key() {
  local platform arch
  platform="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) tulan_error "不支持的架构: $arch"; return 1 ;;
  esac
  case "$platform" in
    linux|darwin) echo "${platform}-${arch}" ;;
    *) tulan_error "不支持的操作系统: $platform"; return 1 ;;
  esac
}

tulan_download_from_github() {
  local tool="$1"
  local install_dir="$2"
  local verify="${3:-true}"

  local manifest repo branch platform_key path version install_name sha256 dest url proxy

  manifest="$(tulan_resolve_manifest)" || return 1

  repo="$(tulan_manifest_get_repo "$manifest")"
  branch="$(tulan_manifest_read "$manifest" "print(data.get('branch', 'bin'))")"
  platform_key="$(tulan_manifest_platform_key)"

  path="$(tulan_manifest_read "$manifest" "
tool = data['tools'].get('${tool}')
if not tool:
    sys.exit(1)
print(tool['paths'].get('${platform_key}', ''))
")" || {
    tulan_error "工具 ${tool} 不支持平台 ${platform_key}"
    return 1
  }

  if [[ -z "$path" ]]; then
    tulan_error "工具 ${tool} 在 ${platform_key} 上无可用路径"
    return 1
  fi

  version="$(tulan_manifest_read "$manifest" "print(data['tools']['${tool}'].get('version', ''))")"
  install_name="$(tulan_manifest_read "$manifest" "print(data['tools']['${tool}'].get('install_name', '${tool}'))")"
  sha256="$(tulan_manifest_read "$manifest" "
print(data['tools']['${tool}'].get('sha256', {}).get('${platform_key}', ''))
" 2>/dev/null || echo "")"

  dest="${install_dir}/${install_name}"
  proxy="$(tulan_get_github_proxy "$manifest")"

  tulan_log "下载 ${tool} ${version} (${platform_key})"
  tulan_debug "二进制路径: ${path}"

  mkdir -p "$install_dir"
  if ! tulan_download_binary_file "$repo" "$branch" "$path" "${dest}.tmp" "$proxy"; then
    tulan_error "下载失败: ${tool}"
    tulan_error "  blob: $(tulan_binary_blob_url "$repo" "$branch" "$path")"
    tulan_error "  media: $(tulan_binary_media_url "$repo" "$branch" "$path")"
    return 1
  fi

  if [[ "$verify" == true ]] && [[ -n "$sha256" ]]; then
    local actual
    if command -v sha256sum &>/dev/null; then
      actual="$(sha256sum "${dest}.tmp" | awk '{print $1}')"
    else
      actual="$(shasum -a 256 "${dest}.tmp" | awk '{print $1}')"
    fi
    if [[ "$sha256" != "$actual" ]]; then
      rm -f "${dest}.tmp"
      tulan_error "SHA256 校验失败: ${tool}"
      return 1
    fi
    tulan_log "  SHA256 校验通过"
  fi

  mv "${dest}.tmp" "$dest"
  chmod +x "$dest"
  tulan_log "  已安装: ${dest}"
}

tulan_binaries_list() {
  local manifest bin_dir installed_only="${1:-false}"
  local missing

  manifest="$(tulan_resolve_manifest)" || return 1
  bin_dir="$(tulan_get_home)/bin"

  if [[ "$installed_only" == true ]]; then
    echo "已安装二进制工具:"
  else
    echo "二进制工具（tulan download 安装）:"
  fi
  echo "────────────────────────────────────"

  python3 -c "
import json, os
installed_only = '${installed_only}' == 'true'
with open('${manifest}') as f:
    data = json.load(f)
bin_dir = '${bin_dir}'
found = False
for name, tool in data.get('tools', {}).items():
    install_name = tool.get('install_name', name)
    version = tool.get('version', '') or '待同步'
    path = os.path.join(bin_dir, install_name)
    installed = os.path.isfile(path) and os.access(path, os.X_OK)
    if installed_only and not installed:
        continue
    found = True
    status = '已安装' if installed else '未安装'
    print(f'  {install_name:20s} {version:<12} {status}')
if not found:
    print('  (无)' if installed_only else '  (manifest 中无工具定义)')
"

  [[ "$installed_only" == true ]] && return 0

  missing=0
  while IFS= read -r name; do
    [[ -z "$name" ]] || [[ -x "${bin_dir}/${name}" ]] || missing=$((missing + 1))
  done < <(tulan_manifest_read "$manifest" "
for t in data.get('tools', {}).values():
    print(t.get('install_name', ''))
")

  if [[ "$missing" -gt 0 ]]; then
    echo ""
    echo "提示: 运行 tulan download 安装上述工具"
  fi
}
