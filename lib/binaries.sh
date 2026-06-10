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
    local tmp
    tmp="$(mktemp)"
    curl -fsSL "${TULAN_MANIFEST_URL}" -o "$tmp"
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

  dest="${install_dir}/${install_name}"
  url="$(tulan_binary_media_url "$repo" "$branch" "$path")"

  tulan_log "下载 ${tool} ${version} (${platform_key})"
  tulan_log "  来源: ${url}"

  mkdir -p "$install_dir"
  if ! curl -fsSL "$url" -o "${dest}.tmp"; then
    tulan_log "media URL 失败，尝试 GitHub API..."
    url="$(tulan_binary_api_url "$repo" "$branch" "$path")"
    curl -fsSL "$url" -o "${dest}.tmp"
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
