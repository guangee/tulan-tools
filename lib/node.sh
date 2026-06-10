#!/usr/bin/env bash
# Node.js 安装与版本切换

set -euo pipefail

# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

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
  python3 - "$major" "$version" "$node_home" "$(tulan_node_state_path)" <<'PY'
import json, sys
from pathlib import Path

major, version, node_home, state_path = sys.argv[1:5]
state = Path(state_path)
state.parent.mkdir(parents=True, exist_ok=True)
data = json.loads(state.read_text()) if state.exists() else {"active_major": "", "node_home": "", "runtimes": {}}
data["active_major"] = major
data["node_home"] = node_home
data["runtimes"][major] = {"version": version, "node_home": node_home}
state.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY
}

tulan_node_register() {
  local major="$1" version="$2" node_home="$3" activate="${4:-true}" source="${5:-nodejs.org}"
  local tool
  tool="$(tulan_node_tool_name "$major")"
  python3 - "$tool" "$version" "$node_home" "$activate" "$source" "$(tulan_binary_registry_path)" <<'PY'
import json, sys, time
from pathlib import Path

tool, version, node_home, activate, source, reg_path = sys.argv[1:7]
reg = Path(reg_path)
reg.parent.mkdir(parents=True, exist_ok=True)
data = json.loads(reg.read_text()) if reg.exists() else {}
entry = data.setdefault(tool, {"install_name": tool, "active": "", "versions": {}})
entry["install_name"] = tool
entry["versions"][version] = {
    "source": source,
    "installed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "node_home": node_home,
    "major": tool.replace("node-", ""),
}
if activate == "true":
    entry["active"] = version
reg.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY
}

tulan_node_activate() {
  local major="$1"
  local tool version node_home cellar_root node_bin

  tool="$(tulan_node_tool_name "$major")"
  version="$(python3 - "$tool" "$(tulan_binary_registry_path)" <<'PY'
import json, sys
from pathlib import Path
tool, reg_path = sys.argv[1:3]
data = json.loads(Path(reg_path).read_text()) if Path(reg_path).exists() else {}
entry = data.get(tool, {})
print(entry.get("active", "") or "")
PY
)"

  if [[ -z "$version" ]]; then
    tulan_error "未安装 Node.js ${major}"
    tulan_error "  请先运行: brew install node-${major}"
    return 1
  fi

  node_home="$(python3 - "$tool" "$version" "$(tulan_binary_registry_path)" <<'PY'
import json, sys
from pathlib import Path
tool, version, reg_path = sys.argv[1:4]
data = json.loads(Path(reg_path).read_text())
entry = data.get(tool, {}).get("versions", {}).get(version, {})
print(entry.get("node_home", ""))
PY
)"

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
  tar -xzf "$archive" -C "$cellar_root"

  node_bin="$(find "$cellar_root" -type f -name node -path '*/bin/node' 2>/dev/null | head -1)"
  [[ -n "$node_bin" ]] || { tulan_error "解压后未找到 node 可执行文件"; return 1; }
  node_home="$(cd "$(dirname "$node_bin")/.." && pwd)"

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
  curl -fSL "$url" -o "$tmp"
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
    python3 - "$tool" "$(tulan_binary_registry_path)" "$(tulan_node_state_path)" <<'PY'
import json, sys
from pathlib import Path

tool, reg_path, state_path = sys.argv[1:4]
data = json.loads(Path(reg_path).read_text())
entry = data.get(tool, {})
active = entry.get("active", "")
versions = sorted(entry.get("versions", {}).keys())
state = json.loads(Path(state_path).read_text()) if Path(state_path).exists() else {}
active_major = state.get("active_major", "")
if versions:
    text = ", ".join(f"{v}{'*' if v == active else ''}" for v in versions)
    print(f"  本地已装: {text}")
else:
    print("  本地已装: (无)")
if active_major:
    print(f"  NODE_HOME 当前: Node {active_major} -> {state.get('node_home', '')}")
else:
    print("  NODE_HOME 当前: (未设置)")
PY
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

  python3 - "$tool" "$version" "$reg" "$home" <<'PY'
import json, shutil, sys
from pathlib import Path

tool, version, reg_path, home = sys.argv[1:5]
reg = Path(reg_path)
home = Path(home)
data = json.loads(reg.read_text())
entry = data.get(tool)
if not entry:
    sys.exit(2)
remove = [version] if version else list(entry.get("versions", {}).keys())
for ver in remove:
    cellar = home / "cellar" / tool / ver
    if cellar.exists():
        shutil.rmtree(cellar)
    entry.get("versions", {}).pop(ver, None)
if not entry.get("versions"):
    data.pop(tool, None)
else:
    entry["active"] = sorted(entry["versions"].keys())[-1]
reg.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY
  local rc=$?
  if [[ $rc -eq 2 ]]; then
    tulan_error "未安装: ${tool}"
    return 1
  fi

  active_major="$(python3 - "$(tulan_node_state_path)" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
if p.exists():
    print(json.loads(p.read_text()).get("active_major", ""))
PY
)"
  if [[ "$active_major" == "$major" ]]; then
    tulan_node_unlink_bin
    rm -f "$(tulan_node_state_path)"
    tulan_runtime_configure
    tulan_log "已清除 Node 环境（曾使用 Node ${major}）"
  fi

  tulan_log "已卸载: ${tool}${version:+ ${version}}"
}

tulan_node_list() {
  local reg state active_major node_home major tool ver_text

  reg="$(tulan_binary_registry_path)"
  state="$(tulan_node_state_path)"

  echo "Node.js（bin 索引 / 上游）:"
  echo "────────────────────────────────────"

  for major in "${TULAN_NODE_MAJORS[@]}"; do
    local index_ver
    tool="$(tulan_node_tool_name "$major")"
    index_ver="$(tulan_manifest_index_version_display "$tool" 2>/dev/null || echo "待同步")"
    ver_text=""
    if [[ -f "$reg" ]]; then
      ver_text="$(python3 - "$tool" "$reg" <<'PY'
import json, sys
from pathlib import Path
tool, reg_path = sys.argv[1:3]
data = json.loads(Path(reg_path).read_text())
entry = data.get(tool, {})
active = entry.get("active", "")
versions = sorted(entry.get("versions", {}).keys())
if versions:
    print(", ".join(f"{v}{'*' if v == active else ''}" for v in versions))
PY
)"
    fi
    if [[ -n "$ver_text" ]]; then
      printf "  %-18s 最新:%-16s 已装:[%s]\n" "node-${major}" "$index_ver" "$ver_text"
    else
      printf "  %-18s 最新:%-16s 未安装\n" "node-${major}" "$index_ver"
    fi
  done

  if [[ -f "$state" ]]; then
    active_major="$(python3 - "$state" <<'PY'
import json, sys
from pathlib import Path
print(json.loads(Path(sys.argv[1]).read_text()).get("active_major", ""))
PY
)"
    node_home="$(python3 - "$state" <<'PY'
import json, sys
from pathlib import Path
print(json.loads(Path(sys.argv[1]).read_text()).get("node_home", ""))
PY
)"
    [[ -n "$active_major" ]] && echo "  NODE_HOME 当前: Node ${active_major} -> ${node_home}"
  fi
}
