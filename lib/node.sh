#!/usr/bin/env bash
# Node.js 安装与版本切换

set -euo pipefail

# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# 支持的 Node 主版本（供外部脚本引用）
# shellcheck disable=SC2034
TULAN_NODE_MAJORS=(16 18 20 22 24)

tulan_node_state_path() {
  echo "$(tulan_get_home)/state/node.json"
}

tulan_node_tool_name() {
  echo "node-${1}"
}

tulan_node_major_for_tool() {
  case "$1" in
    node-16|node16|n16|16) echo "16" ;;
    node-18|node18|n18|18) echo "18" ;;
    node-20|node20|n20|20) echo "20" ;;
    node-22|node22|n22|22) echo "22" ;;
    node-24|node24|n24|24) echo "24" ;;
    *) echo "" ;;
  esac
}

tulan_node_platform_suffix() {
  local platform arch
  case "$(uname -s)" in
    Linux) platform="linux" ;;
    Darwin) platform="darwin" ;;
    *) tulan_error "Node.js 不支持: $(uname -s)"; return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) arch="x64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) tulan_error "Node.js 不支持架构: $(uname -m)"; return 1 ;;
  esac
  echo "${platform}-${arch}"
}

tulan_node_cellar_root() {
  local major="$1" version="$2"
  echo "$(tulan_get_home)/cellar/$(tulan_node_tool_name "$major")/${version}"
}

tulan_node_latest_version() {
  local major="$1"
  python3 - "$major" <<'PY'
import json, sys, urllib.request

major = sys.argv[1]
req = urllib.request.Request(
    "https://nodejs.org/dist/index.json",
    headers={"User-Agent": "tulan-tools"},
)
with urllib.request.urlopen(req, timeout=60) as resp:
    data = json.load(resp)
prefix = f"v{major}."
for item in data:
    version = item.get("version", "")
    if version.startswith(prefix):
        print(version)
        break
else:
    sys.exit(1)
PY
}

tulan_node_save_state() {
  local major="$1" version="$2" node_home="$3"
  tulan_python runtime save-node \
    --major "$major" \
    --version "$version" \
    --node-home "$node_home" \
    --state-path "$(tulan_node_state_path)"
}

tulan_node_register() {
  local major="$1" version="$2" node_home="$3" activate="${4:-true}" source="${5:-nodejs.org}"
  local tool extra_json
  tool="$(tulan_node_tool_name "$major")"
  extra_json="$(EXTRA_NODE_HOME="$node_home" EXTRA_MAJOR="$major" python3 -c \
    'import json,os; print(json.dumps({"node_home":os.environ["EXTRA_NODE_HOME"],"major":os.environ["EXTRA_MAJOR"]}))')"
  tulan_python registry register \
    --tool "$tool" \
    --version "$version" \
    --install-name "$tool" \
    --source "$source" \
    --activate "$activate" \
    --reg-path "$(tulan_binary_registry_path)" \
    --extra-json "$extra_json"
}

tulan_node_activate() {
  local major="$1"
  local tool version node_home cellar_root node_bin

  tool="$(tulan_node_tool_name "$major")"
  version="$(tulan_python registry active-version --tool "$tool" --reg-path "$(tulan_binary_registry_path)")"

  if [[ -z "$version" ]]; then
    tulan_error "未安装 Node.js ${major}"
    tulan_error "  请先运行: brew install node-${major}"
    return 1
  fi

  node_home="$(tulan_python registry version-field \
    --tool "$tool" --version "$version" --field node_home \
    --reg-path "$(tulan_binary_registry_path)")"

  if [[ -z "$node_home" ]] || [[ ! -d "$node_home" ]]; then
    cellar_root="$(tulan_node_cellar_root "$major" "$version")"
    node_bin="$(find "$cellar_root" -type f -name node -path '*/bin/node' 2>/dev/null | head -1)"
    if [[ -n "$node_bin" ]]; then
      node_home="$(cd "$(dirname "$node_bin")/.." && pwd)"
    fi
  fi

  if [[ -z "$node_home" ]] || [[ ! -x "${node_home}/bin/node" ]]; then
    tulan_error "无法定位 NODE_HOME: node-${major} ${version}"
    return 1
  fi

  tulan_node_save_state "$major" "$version" "$node_home"
  tulan_node_link_bin "$node_home"
  tulan_runtime_configure
  tulan_log "已切换 Node.js ${major}: ${node_home}"
  echo ""
  echo "  NODE_HOME=${node_home}"
  echo "  验证: node -v && npm -v"
  tulan_runtime_hint
}

tulan_node_install_archive() {
  local major="$1" version="$2" archive="$3" source="${4:-upstream}"
  local cellar_root node_bin node_home

  if ! command -v tar &>/dev/null; then
    tulan_error "安装 Node.js 需要 tar"
    return 1
  fi

  cellar_root="$(tulan_node_cellar_root "$major" "$version")"
  mkdir -p "$cellar_root"
  tulan_verbose_step "解压 Node.js 归档"
  tar -xzf "$archive" -C "$cellar_root"

  node_bin="$(find "$cellar_root" -type f -name node -path '*/bin/node' 2>/dev/null | head -1)"
  [[ -n "$node_bin" ]] || { tulan_error "解压后未找到 node 可执行文件"; return 1; }
  node_home="$(cd "$(dirname "$node_bin")/.." && pwd)"

  tulan_verbose_step "注册并激活 Node.js ${major}"
  tulan_node_register "$major" "$version" "$node_home" "true" "$source"
  tulan_node_activate "$major"
  tulan_log "  已安装: ${cellar_root}（${source}）"
}

tulan_install_node_from_bin() {
  local major="$1"
  local dry_run="${2:-false}"
  local verify="${3:-true}"
  local tool version tmp

  tool="$(tulan_node_tool_name "$major")"
  version="$(tulan_manifest_tool_version "$tool")"
  [[ -n "$version" ]] || { tulan_error "bin 索引无 Node.js ${major} 版本"; return 1; }

  tulan_verbose_step "从 bin 索引安装 Node.js ${major}"
  tulan_log "安装 Node.js ${major} ${version}（bin 索引）"

  if [[ "$dry_run" == true ]]; then
    tulan_log "[dry-run] ${tool} ${version}"
    return 0
  fi

  tmp="$(mktemp)"
  if ! tulan_download_archive_from_github "$tool" "$tmp" "$verify"; then
    rm -f "$tmp"
    return 1
  fi
  tulan_node_install_archive "$major" "$version" "$tmp" "github"
  rm -f "$tmp"
}

tulan_install_node() {
  local major="$1"
  local requested_version="${2:-}"
  local dry_run="${3:-false}"
  local version suffix url tmp

  if ! command -v tar &>/dev/null; then
    tulan_error "安装 Node.js 需要 tar"
    return 1
  fi

  if [[ -n "$requested_version" ]] && [[ "$requested_version" != v* ]]; then
    requested_version="v${requested_version}"
  fi

  version="${requested_version:-$(tulan_node_latest_version "$major")}"
  [[ -n "$version" ]] || { tulan_error "无法获取 Node.js ${major} 最新版本"; return 1; }

  suffix="$(tulan_node_platform_suffix)"
  url="https://nodejs.org/dist/${version}/node-${version}-${suffix}.tar.gz"

  tulan_log "安装 Node.js ${major} -> ${version}（nodejs.org 上游, ${suffix}）"
  tulan_debug "URL: ${url}"

  if [[ "$dry_run" == true ]]; then
    tulan_log "[dry-run] node-${major} ${version}"
    return 0
  fi

  tmp="$(mktemp)"
  tulan_fetch_url "$url" "$tmp"
  tulan_node_install_archive "$major" "$version" "$tmp" "upstream"
  rm -f "$tmp"
}

tulan_node_show_versions() {
  local major="$1"
  local tool upstream

  tool="$(tulan_node_tool_name "$major")"

  local index_ver
  index_ver="$(tulan_manifest_index_version_display "$tool" 2>/dev/null || echo "待同步")"

  echo "Node.js ${major}"
  echo "────────────────────────────────────"
  echo "  bin 索引版本（brew install 默认）: ${index_ver}"

  upstream="$(tulan_node_latest_version "$major" 2>/dev/null || echo "")"
  if [[ -n "$upstream" ]]; then
    echo "  上游最新: ${upstream}"
  fi

  if [[ -f "$(tulan_binary_registry_path)" ]]; then
    local installed_text node_home_cur active_major_cur
    installed_text="$(tulan_python registry versions-display --tool "$tool" --reg-path "$(tulan_binary_registry_path)")"
    if [[ -n "$installed_text" ]]; then
      echo "  本地已装: ${installed_text}"
    else
      echo "  本地已装: (无)"
    fi
    active_major_cur="$(tulan_python runtime state-field "$(tulan_node_state_path)" active_major 2>/dev/null || true)"
    node_home_cur="$(tulan_python runtime state-field "$(tulan_node_state_path)" node_home 2>/dev/null || true)"
    if [[ -n "$active_major_cur" ]]; then
      echo "  NODE_HOME 当前: Node ${active_major_cur} -> ${node_home_cur}"
    else
      echo "  NODE_HOME 当前: (未设置)"
    fi
  else
    echo "  本地已装: (无)"
    echo "  NODE_HOME 当前: (未设置)"
  fi

  echo ""
  echo "  安装: brew install node-${major}"
  echo "  切换: brew use node ${major}"
}

tulan_node_uninstall() {
  local major="$1" version="${2:-}"
  local tool home reg active_major

  tool="$(tulan_node_tool_name "$major")"
  home="$(tulan_get_home)"
  reg="$(tulan_binary_registry_path)"

  if [[ ! -f "$reg" ]]; then
    tulan_error "未安装: ${tool}"
    return 1
  fi

  if [[ -n "$version" ]] && [[ "$version" != v* ]]; then
    version="v${version}"
  fi

  tulan_binary_uninstall "$tool" "$version" || return 1

  active_major="$(tulan_python runtime state-field "$(tulan_node_state_path)" active_major 2>/dev/null || true)"
  if [[ "$active_major" == "$major" ]]; then
    tulan_node_unlink_bin
    rm -f "$(tulan_node_state_path)"
    tulan_runtime_configure
    tulan_log "已清除 Node 环境（曾使用 Node ${major}）"
  fi

  tulan_log "已卸载: ${tool}${version:+ ${version}}"
}

tulan_node_list() {
  local manifest="${1:-${TULAN_MANIFEST_PATH:-}}"
  tulan_archive_tools_list "$manifest" "node"
}
