#!/usr/bin/env bash
# Go 安装、版本切换与国内模块代理配置

set -euo pipefail

# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
# shellcheck source=mirrors.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/mirrors.sh"

TULAN_GO_TOOL="go"

tulan_go_state_path() {
  echo "$(tulan_get_home)/state/go.json"
}

tulan_go_cellar_root() {
  local version="$1"
  echo "$(tulan_get_home)/cellar/${TULAN_GO_TOOL}/${version}"
}

tulan_go_platform_key() {
  tulan_manifest_platform_key
}

tulan_go_normalize_version() {
  local version="$1"
  if [[ -z "$version" ]]; then
    echo ""
    return 0
  fi
  if [[ "$version" == go* ]]; then
    echo "$version"
  else
    echo "go${version}"
  fi
}

tulan_go_latest_version() {
  tulan_python upstream go-latest 2>/dev/null || true
}

tulan_go_list_versions() {
  local count="${1:-20}"
  tulan_python upstream go-list --count "$count" 2>/dev/null || true
}

tulan_go_save_state() {
  local version="$1" go_root="$2"
  tulan_python runtime save-go \
    --version "$version" \
    --go-root "$go_root" \
    --state-path "$(tulan_go_state_path)"
}

tulan_go_register() {
  local version="$1" go_root="$2" activate="${3:-true}" source="${4:-go.dev}"
  local extra_json
  extra_json="$(EXTRA_GO_ROOT="$go_root" python3 -c \
    'import json,os; print(json.dumps({"go_root":os.environ["EXTRA_GO_ROOT"]}))')"
  tulan_python registry register \
    --tool "$TULAN_GO_TOOL" \
    --version "$version" \
    --install-name "$TULAN_GO_TOOL" \
    --source "$source" \
    --activate "$activate" \
    --reg-path "$(tulan_binary_registry_path)" \
    --extra-json "$extra_json"
}

tulan_go_link_bin() {
  local go_root="$1"
  tulan_link_tool_bin "$go_root" go gofmt
}

tulan_go_unlink_bin() {
  local cmd
  for cmd in go gofmt; do
    rm -f "$(tulan_get_home)/bin/${cmd}"
  done
}

tulan_go_resolve_root() {
  local version="$1"
  local go_root reg
  reg="$(tulan_binary_registry_path)"

  go_root="$(tulan_python registry version-field \
    --tool "$TULAN_GO_TOOL" --version "$version" --field go_root \
    --reg-path "$reg" 2>/dev/null || true)"

  if [[ -n "$go_root" ]] && [[ -x "${go_root}/bin/go" ]]; then
    echo "$go_root"
    return 0
  fi

  go_root="$(find "$(tulan_go_cellar_root "$version")" -type f -name go -path '*/bin/go' 2>/dev/null | head -1 || true)"
  if [[ -n "$go_root" ]]; then
    echo "$(cd "$(dirname "$go_root")/.." && pwd)"
    return 0
  fi
  return 1
}

tulan_go_activate() {
  local version="${1:-}"
  local reg active go_root

  reg="$(tulan_binary_registry_path)"
  if [[ -z "$version" ]]; then
    version="$(tulan_python registry active-version --tool "$TULAN_GO_TOOL" --reg-path "$reg" 2>/dev/null || true)"
  fi
  version="$(tulan_go_normalize_version "$version")"
  [[ -n "$version" ]] || { tulan_error "未安装 Go"; return 1; }

  if ! go_root="$(tulan_go_resolve_root "$version")"; then
    tulan_error "无法定位 GOROOT: ${version}"
    return 1
  fi

  tulan_go_save_state "$version" "$go_root"
  tulan_python registry activate \
    --tool "$TULAN_GO_TOOL" \
    --version "$version" \
    --reg-path "$reg"
  tulan_go_link_bin "$go_root"
  tulan_runtime_configure
  tulan_mirrors_configure_go

  tulan_log "已切换 Go -> ${version}"
  echo ""
  echo "  GOROOT=${go_root}"
  echo "  验证: go version"
  tulan_runtime_hint
}

tulan_go_install_archive() {
  local version="$1" archive="$2" source="${3:-go.dev}"
  local cellar_root go_bin go_root

  if ! command -v tar &>/dev/null; then
    tulan_error "安装 Go 需要 tar"
    return 1
  fi

  cellar_root="$(tulan_go_cellar_root "$version")"
  mkdir -p "$cellar_root"
  tulan_verbose_step "解压 Go 归档"
  tar -xzf "$archive" -C "$cellar_root"

  go_bin="$(find "$cellar_root" -type f -name go -path '*/bin/go' 2>/dev/null | head -1)"
  [[ -n "$go_bin" ]] || { tulan_error "解压后未找到 go 可执行文件"; return 1; }
  go_root="$(cd "$(dirname "$go_bin")/.." && pwd)"

  tulan_verbose_step "注册并激活 Go ${version}"
  tulan_go_register "$version" "$go_root" "true" "$source"
  tulan_go_activate "$version"
  tulan_log "  已安装: ${cellar_root}（${source}）"
}

tulan_go_download_upstream() {
  local version="$1" dest="$2" verify="${3:-true}"
  local platform_key url sha256 filename alt_url

  platform_key="$(tulan_go_platform_key)"
  mapfile -t _go_dl < <(tulan_python upstream go-download-url "$version" "$platform_key")
  url="${_go_dl[0]:-}"
  sha256="${_go_dl[1]:-}"
  [[ -n "$url" ]] || { tulan_error "无法解析 Go 下载地址: ${version}"; return 1; }

  tulan_log "下载 ${version} (${platform_key})"
  tulan_debug "URL: ${url}"

  if ! tulan_fetch_url "$url" "$dest"; then
    alt_url="${url//golang.google.cn/go.dev}"
    if [[ "$alt_url" != "$url" ]]; then
      tulan_log "国内镜像失败，尝试 go.dev..."
      tulan_debug "备用 URL: ${alt_url}"
      tulan_fetch_url "$alt_url" "$dest" || return 1
    else
      return 1
    fi
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
      tulan_error "SHA256 校验失败: ${version}"
      return 1
    fi
    tulan_log "  SHA256 校验通过"
  fi
}

tulan_install_go_from_bin() {
  local dry_run="${1:-false}"
  local verify="${2:-true}"
  local version tmp

  version="$(tulan_manifest_resolved_tool_version "$TULAN_GO_TOOL")"
  [[ -n "$version" ]] || { tulan_error "bin 索引无 Go 版本"; return 1; }
  version="$(tulan_go_normalize_version "$version")"

  tulan_log "安装 Go ${version}（bin 索引）"
  if [[ "$dry_run" == true ]]; then
    tulan_log "[dry-run] go ${version}"
    return 0
  fi

  tmp="$(mktemp)"
  if ! tulan_download_archive_from_github "$TULAN_GO_TOOL" "$tmp" "$verify"; then
    rm -f "$tmp"
    return 1
  fi
  tulan_go_install_archive "$version" "$tmp" "github"
  rm -f "$tmp"
  tulan_mirrors_configure_go
}

tulan_install_go() {
  local requested_version="${1:-}"
  local dry_run="${2:-false}"
  local upgrade="${3:-false}"
  local verify="${4:-true}"
  local version active tmp

  if ! command -v tar &>/dev/null; then
    tulan_error "安装 Go 需要 tar"
    return 1
  fi

  requested_version="$(tulan_go_normalize_version "$requested_version")"

  if [[ "$upgrade" == true ]] && [[ -z "$requested_version" ]]; then
    active="$(tulan_python registry active-version --tool "$TULAN_GO_TOOL" \
      --reg-path "$(tulan_binary_registry_path)" 2>/dev/null || true)"
    version="$(tulan_go_latest_version)"
    [[ -n "$version" ]] || { tulan_error "无法获取 Go 最新稳定版"; return 1; }
    if [[ -n "$active" ]] && [[ "$active" == "$version" ]]; then
      tulan_log "Go 已是最新稳定版: ${version}"
      tulan_go_activate "$version"
      return 0
    fi
    if [[ -n "$active" ]]; then
      tulan_log "升级 Go: ${active} -> ${version}"
    fi
  else
    version="${requested_version:-$(tulan_go_latest_version)}"
    [[ -n "$version" ]] || { tulan_error "无法获取 Go 最新稳定版"; return 1; }
  fi

  tulan_log "安装 Go -> ${version}（go.dev 上游, $(tulan_go_platform_key)）"

  if [[ "$dry_run" == true ]]; then
    tulan_log "[dry-run] go ${version}"
    return 0
  fi

  tmp="$(mktemp)"
  if ! tulan_go_download_upstream "$version" "$tmp" "$verify"; then
    rm -f "$tmp"
    return 1
  fi
  tulan_go_install_archive "$version" "$tmp" "upstream"
  rm -f "$tmp"
  tulan_mirrors_configure_go
}

tulan_go_show_versions() {
  local upstream recent installed active go_root_cur

  echo "Go"
  echo "────────────────────────────────────"

  index_ver="$(tulan_manifest_index_version_display "$TULAN_GO_TOOL" 2>/dev/null || echo "待同步")"
  echo "  bin 索引版本（brew install --source github）: ${index_ver}"

  upstream="$(tulan_go_latest_version 2>/dev/null || echo "")"
  if [[ -n "$upstream" ]]; then
    echo "  上游最新稳定版: ${upstream}"
  fi

  recent="$(tulan_go_list_versions 12 2>/dev/null | tr '\n' ' ')"
  if [[ -n "$recent" ]]; then
    echo "  可安装稳定版（近期）: ${recent}"
  fi

  if [[ -f "$(tulan_binary_registry_path)" ]]; then
    installed="$(tulan_python registry versions-display --tool "$TULAN_GO_TOOL" \
      --reg-path "$(tulan_binary_registry_path)" 2>/dev/null || true)"
    if [[ -n "$installed" ]]; then
      echo "  本地已装（* 当前）: ${installed}"
    else
      echo "  本地已装: (无)"
    fi
    active="$(tulan_python registry active-version --tool "$TULAN_GO_TOOL" \
      --reg-path "$(tulan_binary_registry_path)" 2>/dev/null || true)"
    go_root_cur="$(tulan_python runtime state-field "$(tulan_go_state_path)" go_root 2>/dev/null || true)"
    if [[ -n "$active" ]]; then
      echo "  GOROOT 当前: ${active} -> ${go_root_cur:-未知}"
    else
      echo "  GOROOT 当前: (未设置)"
    fi
  else
    echo "  本地已装: (无)"
    echo "  GOROOT 当前: (未设置)"
  fi

  echo ""
  echo "  安装最新: brew install go"
  echo "  升级最新: brew install go --upgrade"
  echo "  指定版本: brew install go --version go1.22.5"
  echo "  切换版本: brew use go go1.22.5"
}

tulan_go_uninstall() {
  local version="${1:-}"
  local home reg active

  home="$(tulan_get_home)"
  reg="$(tulan_binary_registry_path)"
  version="$(tulan_go_normalize_version "$version")"

  if [[ ! -f "$reg" ]]; then
    tulan_error "未安装: go"
    return 1
  fi

  tulan_binary_uninstall "$TULAN_GO_TOOL" "$version" || return 1

  active="$(tulan_python runtime state-field "$(tulan_go_state_path)" version 2>/dev/null || true)"
  if [[ -z "$version" ]] || [[ "$active" == "$version" ]]; then
    tulan_go_unlink_bin
    rm -f "$(tulan_go_state_path)"
    tulan_runtime_configure
    tulan_log "已清除 Go 环境"
  fi

  tulan_log "已卸载: go${version:+ ${version}}"
}
