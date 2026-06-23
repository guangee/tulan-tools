#!/usr/bin/env bash
# 从 GitHub bin 分支公开链接下载二进制（客户端无需 git-lfs）

set -euo pipefail

TULAN_MANIFEST_PATH="${TULAN_MANIFEST_PATH:-}"
TULAN_MANIFEST_TTL="${TULAN_MANIFEST_TTL:-86400}"
TULAN_MANIFEST_DEFAULT_REPO="${TULAN_GITHUB_REPO:-guangee/tulan-tools}"
TULAN_MANIFEST_DEFAULT_BRANCH="bin"
TULAN_MANIFEST_DEFAULT_FILE="binaries.manifest.json"
TULAN_RANCHER_VERSIONS_FILE="k8s.rancher.versions.json"
TULAN_MANIFEST_PROXY_DEFAULT="https://gh.coding-space.cn/"
TULAN_OFFICIAL_GITHUB_REPO="${TULAN_OFFICIAL_GITHUB_REPO:-guangee/tulan-tools}"

tulan_bin_source_init() {
  if [[ -n "${TULAN_BIN_SOURCE:-}" ]]; then
    return 0
  fi

  if [[ -n "${TULAN_MANIFEST_URL:-}" ]]; then
    export TULAN_BIN_SOURCE="custom"
    return 0
  fi

  # 二进制与 manifest 始终从官方 GitHub bin 分支经代理获取，不随 git clone 源（如 GitLab 镜像）变化
  export TULAN_BIN_SOURCE="github_official"
}

tulan_bin_official_github_repo() {
  if [[ -n "${TULAN_GITHUB_REPO:-}" ]]; then
    local normalized
    if normalized="$(tulan_normalize_github_repo "${TULAN_GITHUB_REPO}" 2>/dev/null)"; then
      echo "$normalized"
      return 0
    fi
    echo "${TULAN_GITHUB_REPO}"
    return 0
  fi
  echo "${TULAN_MANIFEST_DEFAULT_REPO}"
}

tulan_bin_uses_git_host() {
  false
}

tulan_bin_effective_github_repo() {
  tulan_bin_official_github_repo
}

# 构建 bin 分支文件 URL（始终官方 GitHub raw）
tulan_bin_branch_file_url() {
  local branch="$1" file="$2" repo
  repo="$(tulan_bin_official_github_repo)"
  echo "https://raw.githubusercontent.com/${repo}/${branch}/${file}"
}

tulan_manifest_cache_path() {
  echo "$(tulan_get_home)/state/binaries.manifest.json"
}

tulan_manifest_cache_ts_path() {
  echo "$(tulan_get_home)/state/manifest-fetched-at"
}

# 推断 manifest / 二进制仓库（官方 GitHub，不随 clone 源变化）
tulan_manifest_default_repo() {
  tulan_bin_official_github_repo
}

# 构建 manifest 远程 raw URL
tulan_manifest_remote_url() {
  local repo="${1:-$(tulan_manifest_default_repo)}"
  local branch="${2:-${TULAN_MANIFEST_DEFAULT_BRANCH}}"
  local file="${3:-${TULAN_MANIFEST_DEFAULT_FILE}}"
  tulan_bin_branch_file_url "$branch" "$file"
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
    url="$(tulan_bin_branch_file_url "${TULAN_MANIFEST_DEFAULT_BRANCH}" "${TULAN_MANIFEST_DEFAULT_FILE}")"
  fi

  proxy="$(tulan_manifest_proxy)"
  mkdir -p "$(dirname "$cache")"

  tulan_bin_source_init
  tulan_debug "bin 源: ${TULAN_BIN_SOURCE:-github_official}（官方 GitHub）"
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

tulan_rancher_versions_cache_path() {
  echo "$(tulan_get_home)/state/${TULAN_RANCHER_VERSIONS_FILE}"
}

tulan_rancher_versions_cache_ts_path() {
  echo "$(tulan_get_home)/state/rancher-versions-fetched-at"
}

tulan_rancher_versions_remote_url() {
  local branch="${TULAN_MANIFEST_DEFAULT_BRANCH}"
  tulan_bin_branch_file_url "$branch" "${TULAN_RANCHER_VERSIONS_FILE}"
}

tulan_rancher_versions_cache_expired() {
  local ts_file now last
  ts_file="$(tulan_rancher_versions_cache_ts_path)"
  [[ -f "$ts_file" ]] || return 0
  last="$(cat "$ts_file")"
  now="$(date +%s)"
  (( now - last >= TULAN_MANIFEST_TTL ))
}

# 从 bin 分支拉取 Rancher 可升级版本列表
tulan_rancher_versions_refresh() {
  local force="${1:-false}"
  local cache proxy url repo

  cache="$(tulan_rancher_versions_cache_path)"
  repo="$(tulan_manifest_default_repo)"

  if [[ "$force" != true ]] && [[ -f "$cache" ]] && ! tulan_rancher_versions_cache_expired; then
    return 0
  fi

  url="$(tulan_rancher_versions_remote_url)"
  proxy="$(tulan_manifest_proxy)"
  mkdir -p "$(dirname "$cache")"

  if [[ -n "$proxy" ]]; then
    tulan_log "刷新 Rancher 版本索引: $(tulan_proxy_url "$url" "$proxy")"
  else
    tulan_log "刷新 Rancher 版本索引: ${url}"
  fi

  if ! tulan_curl_download "$url" "${cache}.tmp" "$proxy"; then
    [[ -f "$cache" ]] && { tulan_log "使用本地缓存 Rancher 版本列表"; return 0; }
    tulan_log "Rancher 版本索引不可用（可稍后 brew update 重试）"
    return 0
  fi

  mv "${cache}.tmp" "$cache"
  date +%s > "$(tulan_rancher_versions_cache_ts_path)"
  tulan_log "Rancher 版本已缓存: ${cache}"
}

# 解析 manifest JSON（类型化 API，见 lib/tulan_tools/manifest.py）
tulan_manifest_branch() {
  tulan_python manifest branch "$1"
}

tulan_manifest_github_proxy() {
  tulan_python manifest github-proxy "$1" 2>/dev/null || true
}

tulan_manifest_tool_version() {
  tulan_python manifest tool-version "$1" "$2"
}

# 自动 resolve manifest 后读取工具版本（单参数便捷接口）
tulan_manifest_resolved_tool_version() {
  local tool="$1" manifest
  manifest="$(tulan_resolve_manifest)" || return 1
  tulan_manifest_tool_version "$manifest" "$tool"
}

tulan_manifest_tool_install_name() {
  tulan_python manifest tool-install-name "$1" "$2"
}

tulan_manifest_tool_platform_path() {
  tulan_python manifest tool-path "$1" "$2" "$3"
}

tulan_manifest_tool_platform_sha256() {
  tulan_python manifest tool-sha256 "$1" "$2" "$3" 2>/dev/null || true
}

tulan_manifest_tool_index_version() {
  local manifest="$1" tool="$2" ver path platform_key
  platform_key="$(tulan_manifest_platform_key)"
  ver="$(tulan_manifest_tool_version "$manifest" "$tool" 2>/dev/null || true)"
  path="$(tulan_manifest_tool_platform_path "$manifest" "$tool" "$platform_key" 2>/dev/null || true)"
  if [[ -z "$path" || -z "$ver" || "$ver" == "上游最新" ]]; then
    echo "待同步"
  else
    echo "$ver"
  fi
}

tulan_manifest_get_repo() {
  local manifest="$1"
  local repo
  repo="$(tulan_json_get "$manifest" "repository" "")"
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

# 下载 bin 分支二进制：GitHub blob 代理 → media → API
tulan_download_binary_file() {
  local repo="$1" branch="$2" path="$3" dest="$4" proxy="$5"
  local blob media api

  tulan_verbose_step "下载 ${path}"

  blob="$(tulan_binary_blob_url "$repo" "$branch" "$path")"
  media="$(tulan_binary_media_url "$repo" "$branch" "$path")"

  if [[ -n "$proxy" ]]; then
    tulan_debug "blob 代理: $(tulan_proxy_url "$blob" "$proxy")"
    tulan_verbose "尝试 blob 代理"
    if tulan_curl_download "$blob" "$dest" "$proxy"; then
      tulan_verbose "blob 代理下载成功"
      return 0
    fi
    tulan_debug "blob 代理未成功，尝试 media 直连"
    tulan_verbose "blob 代理失败，改试 media 直连"
  fi

  tulan_debug "media 直连: ${media}"
  tulan_verbose "尝试 media 直连"
  if tulan_curl_download "$media" "$dest" ""; then
    tulan_verbose "media 直连下载成功"
    return 0
  fi

  tulan_log "media 失败，尝试 GitHub API..."
  api="$(tulan_binary_api_url "$repo" "$branch" "$path")" || return 1
  tulan_debug "API 直连: ${api}"
  tulan_verbose_step "尝试 GitHub API"
  tulan_curl_download "$api" "$dest" ""
}

# manifest / 二进制下载默认经 GitHub 代理（与 clone 源无关）
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
    from_manifest="$(tulan_manifest_github_proxy "$manifest")"
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

tulan_fetch_url() {
  local url="$1" dest="$2"
  local dl_start dl_end dl_secs size

  mkdir -p "$(dirname "$dest")"
  if [[ "${TULAN_VERBOSE:-}" == true ]]; then
    tulan_verbose_step "下载文件"
    tulan_verbose "URL: ${url}"
    dl_start="$(date +%s)"
    curl -fSL --progress-bar "$url" -o "$dest" || return 1
    dl_end="$(date +%s)"
    dl_secs=$((dl_end - dl_start))
    size="$(wc -c < "$dest" | tr -d ' ')"
    tulan_verbose "下载完成 (+${dl_secs}s): ${size} bytes"
    return 0
  fi

  curl -fsSL "$url" -o "$dest"
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
    local dl_start dl_end dl_secs size

    tulan_debug "${label}: ${target}"

    if [[ "${TULAN_VERBOSE:-}" == true ]]; then
      tulan_verbose_step "curl 下载 (${label})"
      tulan_verbose "URL: ${target}"
      dl_start="$(date +%s)"
      if curl -fSL --progress-bar "$target" -o "$dest"; then
        dl_end="$(date +%s)"
        dl_secs=$((dl_end - dl_start))
        size="$(wc -c < "$dest" | tr -d ' ')"
        tulan_verbose "下载完成 (+${dl_secs}s): ${size} bytes -> ${dest}"
        return 0
      fi
      tulan_verbose "curl ${label} 失败"
      return 1
    fi

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
  tulan_python github contents-url --repo "$repo" --branch "$branch" --path "$path"
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

# ── Cellar 多版本管理（类似 Homebrew）────────────────────────

tulan_binary_canonical_name() {
  case "$1" in
    compose|docker-compose)      echo "docker-compose" ;;
    docker|docker-engine|dockerd) echo "docker" ;;
    mc|minio)                    echo "mc" ;;
    kubectl|k8s)                 echo "kubectl" ;;
    go|golang)                   echo "go" ;;
    maven|mvn)                   echo "maven" ;;
    openjdk-8|jdk8|java8)        echo "openjdk-8" ;;
    openjdk-11|jdk11|java11)     echo "openjdk-11" ;;
    openjdk-17|jdk17|java17)     echo "openjdk-17" ;;
    node-16|node16|n16)           echo "node-16" ;;
    node-18|node18|n18)           echo "node-18" ;;
    node-20|node20|n20)           echo "node-20" ;;
    node-22|node22|n22)           echo "node-22" ;;
    node-24|node24|n24)           echo "node-24" ;;
    *) echo "" ;;
  esac
}

tulan_binary_registry_path() {
  echo "$(tulan_get_home)/state/binaries/registry.json"
}

tulan_binary_cellar_file() {
  local tool="$1" version="$2" install_name="$3"
  echo "$(tulan_get_home)/cellar/${tool}/${version}/${install_name}"
}

tulan_binary_bin_link() {
  local install_name="$1"
  echo "$(tulan_get_home)/bin/${install_name}"
}

tulan_binary_register() {
  local tool="$1" version="$2" install_name="$3" source="$4" activate="${5:-true}"
  tulan_python registry register \
    --tool "$tool" \
    --version "$version" \
    --install-name "$install_name" \
    --source "$source" \
    --activate "$activate" \
    --reg-path "$(tulan_binary_registry_path)"
}

tulan_binary_activate() {
  local tool="$1" version="$2"
  local install_name cellar_file link_path rel target home
  home="$(tulan_get_home)"

  install_name="$(tulan_python registry install-name --tool "$tool" --reg-path "$(tulan_binary_registry_path)")"
  cellar_file="$(tulan_binary_cellar_file "$tool" "$version" "$install_name")"
  if [[ ! -f "$cellar_file" ]]; then
    tulan_error "版本未安装: ${tool} ${version}"
    tulan_error "  路径: ${cellar_file}"
    return 1
  fi

  link_path="$(tulan_binary_bin_link "$install_name")"
  rel="../cellar/${tool}/${version}/${install_name}"
  mkdir -p "$(dirname "$link_path")"
  ln -sf "$rel" "$link_path"

  tulan_python registry activate \
    --tool "$tool" \
    --version "$version" \
    --reg-path "$(tulan_binary_registry_path)"

  tulan_log "已切换 ${install_name} -> ${version}"
}

tulan_binary_finish_install() {
  local tool="$1" version="$2" install_name="$3" source="$4" tmp_file="$5"
  local cellar_file

  cellar_file="$(tulan_binary_cellar_file "$tool" "$version" "$install_name")"
  mkdir -p "$(dirname "$cellar_file")"
  mv "$tmp_file" "$cellar_file"
  chmod +x "$cellar_file"
  tulan_binary_register "$tool" "$version" "$install_name" "$source" "true"
  tulan_binary_activate "$tool" "$version"
  tulan_log "  已安装: ${cellar_file}"
  tulan_log "  已链接: $(tulan_binary_bin_link "$install_name")"
}

tulan_binary_uninstall() {
  local tool="$1" version="${2:-}"
  local home reg

  home="$(tulan_get_home)"
  reg="$(tulan_binary_registry_path)"

  if [[ ! -f "$reg" ]]; then
    tulan_error "未安装二进制: ${tool}"
    return 1
  fi

  tulan_python registry uninstall \
    --tool "$tool" \
    --version "$version" \
    --reg-path "$reg" \
    --home "$home"
  local rc=$?
  if [[ $rc -eq 2 ]]; then
    tulan_error "未安装: ${tool}"
    return 1
  fi
  tulan_log "已卸载: ${tool}${version:+ ${version}}"
}

tulan_download_from_github() {
  local tool="$1"
  local verify="${2:-true}"

  local manifest repo branch platform_key path version install_name sha256 cellar_tmp proxy

  manifest="$(tulan_resolve_manifest)" || return 1

  repo="$(tulan_manifest_get_repo "$manifest")"
  branch="$(tulan_manifest_branch "$manifest")"
  platform_key="$(tulan_manifest_platform_key)"

  path="$(tulan_manifest_tool_platform_path "$manifest" "$tool" "$platform_key")" || {
    tulan_error "工具 ${tool} 不支持平台 ${platform_key}"
    return 1
  }

  if [[ -z "$path" ]]; then
    tulan_error "工具 ${tool} 在 ${platform_key} 上无可用路径"
    return 1
  fi

  version="$(tulan_manifest_tool_version "$manifest" "$tool")"
  install_name="$(tulan_manifest_tool_install_name "$manifest" "$tool")"
  sha256="$(tulan_manifest_tool_platform_sha256 "$manifest" "$tool" "$platform_key")"

  if [[ -n "${TULAN_BINARY_REQUESTED_VERSION:-}" ]] \
      && [[ "${TULAN_BINARY_REQUESTED_VERSION}" != "$version" ]]; then
    tulan_error "bin 索引版本为 ${version}，指定 ${TULAN_BINARY_REQUESTED_VERSION}"
    tulan_error "请使用: brew install ${tool} --version ${TULAN_BINARY_REQUESTED_VERSION} --source upstream"
    return 1
  fi

  [[ -n "$version" ]] || version="latest"
  proxy="$(tulan_get_github_proxy "$manifest")"
  cellar_tmp="$(tulan_binary_cellar_file "$tool" "$version" "$install_name").tmp"

  tulan_log "下载 ${tool} ${version} (${platform_key})"
  tulan_debug "二进制路径: ${path}"

  if ! tulan_download_binary_file "$repo" "$branch" "$path" "$cellar_tmp" "$proxy"; then
    tulan_error "下载失败: ${tool}"
    tulan_error "  blob: $(tulan_binary_blob_url "$repo" "$branch" "$path")"
    tulan_error "  media: $(tulan_binary_media_url "$repo" "$branch" "$path")"
    if [[ -n "$proxy" ]]; then
      tulan_error "  代理: $(tulan_proxy_url "$(tulan_binary_blob_url "$repo" "$branch" "$path")" "$proxy")"
    fi
    return 1
  fi

  if [[ "$verify" == true ]] && [[ -n "$sha256" ]]; then
    local actual
    if command -v sha256sum &>/dev/null; then
      actual="$(sha256sum "$cellar_tmp" | awk '{print $1}')"
    else
      actual="$(shasum -a 256 "$cellar_tmp" | awk '{print $1}')"
    fi
    if [[ "$sha256" != "$actual" ]]; then
      rm -f "$cellar_tmp"
      tulan_error "SHA256 校验失败: ${tool}"
      return 1
    fi
    tulan_log "  SHA256 校验通过"
  fi

  tulan_binary_finish_install "$tool" "$version" "$install_name" "github" "$cellar_tmp"
}

tulan_binary_upstream_latest() {
  local tool="$1"
  case "$tool" in
    kubectl)
      curl -fsSL --connect-timeout 10 --max-time 20 https://dl.k8s.io/release/stable.txt 2>/dev/null || echo ""
      ;;
    docker-compose)
      curl -fsSL --connect-timeout 10 --max-time 20 "https://api.github.com/repos/docker/compose/releases/latest" 2>/dev/null \
        | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4 || echo ""
      ;;
    mc)
      curl -fsSL --connect-timeout 10 --max-time 20 "https://api.github.com/repos/minio/mc/releases/latest" 2>/dev/null \
        | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4 || echo ""
      ;;
    *) echo "" ;;
  esac
}

tulan_binary_upstream_recent() {
  local tool="$1"
  case "$tool" in
    kubectl)
      curl -fsSL --connect-timeout 10 --max-time 20 "https://dl.k8s.io/release?mode=text" 2>/dev/null \
        | grep -E '^v[0-9]' | tail -8 | tr '\n' ' '
      ;;
    docker-compose)
      curl -fsSL --connect-timeout 10 --max-time 20 "https://api.github.com/repos/docker/compose/releases?per_page=8" 2>/dev/null \
        | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4 | tr '\n' ' '
      ;;
    mc)
      curl -fsSL --connect-timeout 10 --max-time 20 "https://api.github.com/repos/minio/mc/releases?per_page=8" 2>/dev/null \
        | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4 | tr '\n' ' '
      ;;
    *) echo "" ;;
  esac
}

tulan_binary_show_versions() {
  local tool="$1"
  local manifest index_ver upstream_latest recent installed

  manifest="$(tulan_resolve_manifest)" || return 1

  index_ver="$(tulan_manifest_tool_index_version "$manifest" "$tool" 2>/dev/null || echo "待同步")"
  upstream_latest="$(tulan_binary_upstream_latest "$tool")"
  recent="$(tulan_binary_upstream_recent "$tool")"

  echo "二进制工具: ${tool}"
  echo "────────────────────────────────────"
  echo "  bin 索引版本（brew install 默认）: ${index_ver}"
  if [[ -n "$upstream_latest" ]]; then
    echo "  上游最新版本: ${upstream_latest}"
  fi
  if [[ -n "$recent" ]]; then
    echo "  上游近期版本: ${recent}"
  fi

  if [[ -f "$(tulan_binary_registry_path)" ]]; then
    installed="$(tulan_python registry versions-display --tool "$tool" --reg-path "$(tulan_binary_registry_path)" 2>/dev/null || true)"
    if [[ -n "$installed" ]]; then
      echo "  本地已装（* 当前）: ${installed}"
    else
      echo "  本地已装: (无)"
    fi
  else
    echo "  本地已装: (无)"
  fi

  echo ""
  echo "  安装最新: brew install ${tool}"
  echo "  指定版本: brew install ${tool} --version <VER> --source upstream"
  echo "  切换版本: brew use ${tool} <VER>"
}

tulan_binaries_list() {
  local installed_only="${1:-false}"
  local manifest="${2:-}"

  if [[ -z "$manifest" ]]; then
    manifest="$(tulan_resolve_manifest)" || return 1
  fi

  if [[ "$installed_only" == true ]]; then
    echo "已安装二进制工具:"
  else
    echo "二进制工具:"
  fi
  echo "────────────────────────────────────"

  tulan_python registry list "$manifest" \
    --reg-path "$(tulan_binary_registry_path)" \
    --bin-dir "$(tulan_get_home)/bin" \
    --installed-only "$installed_only"

  if [[ "$installed_only" == true ]]; then
    return 0
  fi

  echo ""
  echo "  安装: brew install <工具>    版本: brew versions <工具>"
  echo "  * 为当前激活版本              切换: brew use <工具> <版本>"
}
