#!/usr/bin/env bash
# 从 GitHub bin 分支公开链接下载二进制（客户端无需 git-lfs）

set -euo pipefail

TULAN_MANIFEST_PATH="${TULAN_MANIFEST_PATH:-}"

tulan_manifest_default_path() {
  local home
  home="$(tulan_get_home)"
  echo "${home}/config/binaries.manifest.json"
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
  repo="$(tulan_manifest_read "$manifest" "print(data.get('repository', '') or '')")"
  if [[ -n "$repo" ]]; then
    echo "$repo"
    return 0
  fi
  if [[ -n "${TULAN_GITHUB_REPO:-}" ]]; then
    echo "${TULAN_GITHUB_REPO}"
    return 0
  fi
  # 从 git remote 自动推断
  local home remote
  home="$(tulan_get_home)"
  if git -C "$home" remote get-url origin &>/dev/null; then
    remote="$(git -C "$home" remote get-url origin)"
    remote="${remote%.git}"
    remote="${remote#git@github.com:}"
    remote="${remote#https://github.com/}"
    if [[ "$remote" == */* ]]; then
      echo "$remote"
      return 0
    fi
  fi
  return 1
}

# 构建 GitHub LFS 公开下载 URL（无需 git-lfs 客户端）
# 格式: https://media.githubusercontent.com/media/{owner}/{repo}/{ref}/{path}
tulan_binary_media_url() {
  local repo="$1" branch="$2" path="$3"
  echo "https://media.githubusercontent.com/media/${repo}/${branch}/${path}"
}

# 获取 GitHub 加速代理前缀（manifest / 环境变量）
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
    tulan_manifest_read "$manifest" "print(data.get('github_proxy', '') or '')" 2>/dev/null || true
  fi
}

# 为 GitHub URL 套上代理前缀
# 示例: https://gh.coding-space.cn/https://media.githubusercontent.com/...
tulan_proxy_url() {
  local url="$1"
  local proxy="${2:-}"
  if [[ -z "$proxy" ]]; then
    echo "$url"
  else
    echo "${proxy%/}/${url}"
  fi
}

# 下载 URL，代理失败时自动回退直连
tulan_curl_download() {
  local url="$1"
  local dest="$2"
  local proxy="${3:-}"

  local proxied
  proxied="$(tulan_proxy_url "$url" "$proxy")"

  if [[ -n "$proxy" ]] && [[ "$proxied" != "$url" ]]; then
    if curl -fsSL "$proxied" -o "$dest"; then
      return 0
    fi
    tulan_log "代理下载失败，尝试直连..."
  fi

  curl -fsSL "$url" -o "$dest"
}

# 备用：通过 GitHub API 获取 download_url
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
  local manifest=""

  if [[ -n "${TULAN_MANIFEST_URL:-}" ]]; then
    local tmp proxy
    tmp="$(mktemp)"
    proxy="$(tulan_get_github_proxy "")"
    tulan_curl_download "${TULAN_MANIFEST_URL}" "$tmp" "$proxy"
    echo "$tmp"
    return 0
  fi

  if [[ -n "$TULAN_MANIFEST_PATH" ]] && [[ -f "$TULAN_MANIFEST_PATH" ]]; then
    echo "$TULAN_MANIFEST_PATH"
    return 0
  fi

  local default
  default="$(tulan_manifest_default_path)"
  if [[ -f "$default" ]]; then
    echo "$default"
    return 0
  fi

  return 1
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

  local manifest repo branch platform_key path version install_name sha256 dest url

  manifest="$(tulan_resolve_manifest)" || {
    tulan_error "未找到 binaries.manifest.json，请设置 TULAN_MANIFEST_URL 或先运行 sync workflow"
    return 1
  }

  repo="$(tulan_manifest_get_repo "$manifest")" || {
    tulan_error "无法确定 GitHub 仓库，请设置 manifest.repository 或 TULAN_GITHUB_REPO"
    return 1
  }

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

  local proxy
  dest="${install_dir}/${install_name}"
  url="$(tulan_binary_media_url "$repo" "$branch" "$path")"
  proxy="$(tulan_get_github_proxy "$manifest")"

  tulan_log "下载 ${tool} ${version} (${platform_key})"
  if [[ -n "$proxy" ]]; then
    tulan_log "  代理: ${proxy}"
  fi
  tulan_log "  来源: ${url}"

  mkdir -p "$install_dir"
  if ! tulan_curl_download "$url" "${dest}.tmp" "$proxy"; then
    tulan_log "media URL 失败，尝试 GitHub API..."
    url="$(tulan_binary_api_url "$repo" "$branch" "$path")"
    tulan_curl_download "$url" "${dest}.tmp" "$proxy"
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

# 列出可下载的二进制工具及安装状态
tulan_binaries_list() {
  local manifest bin_dir installed_only="${1:-false}"
  local updated_at missing

  manifest="$(tulan_resolve_manifest)" || {
    tulan_error "未找到 binaries.manifest.json"
    return 1
  }

  bin_dir="$(tulan_get_home)/bin"

  if [[ "$installed_only" == true ]]; then
    echo "已安装二进制工具:"
  else
    echo "二进制工具（tulan-download-binaries 安装）:"
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
    [[ -z "$name" ]] && continue
    [[ -x "${bin_dir}/${name}" ]] || missing=$((missing + 1))
  done < <(tulan_manifest_read "$manifest" "
for t in data.get('tools', {}).values():
    print(t.get('install_name', ''))
")

  if [[ "$missing" -gt 0 ]]; then
    echo ""
    echo "提示: 运行 tulan-download-binaries 安装上述工具"
    updated_at="$(tulan_manifest_read "$manifest" "print(data.get('updated_at', '') or '')")"
    if [[ -z "$updated_at" ]]; then
      echo "      manifest 版本待同步，也可先用: tulan-download-binaries --source upstream"
      echo "      维护者请在 GitHub Actions 手动运行 Sync Binaries"
    fi
  fi
}
