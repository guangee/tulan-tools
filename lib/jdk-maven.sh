#!/usr/bin/env bash
# OpenJDK 与 Maven 安装、JAVA_HOME 切换

set -euo pipefail

# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

tulan_java_state_path() {
  echo "$(tulan_get_home)/state/java.json"
}

tulan_openjdk_tool_name() {
  echo "openjdk-${1}"
}

tulan_openjdk_major_for_tool() {
  case "$1" in
    openjdk-8|jdk8|java8|8)     echo "8" ;;
    openjdk-11|jdk11|java11|11) echo "11" ;;
    openjdk-17|jdk17|java17|17) echo "17" ;;
    *) echo "" ;;
  esac
}

tulan_is_maven_tool() {
  case "$1" in
    maven|mvn) return 0 ;;
    *) return 1 ;;
  esac
}

tulan_jdk_adoptium_os() {
  case "$(uname -s)" in
    Linux) echo "linux" ;;
    Darwin) echo "mac" ;;
    *) tulan_error "OpenJDK 不支持: $(uname -s)"; return 1 ;;
  esac
}

tulan_jdk_adoptium_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x64" ;;
    aarch64|arm64) echo "aarch64" ;;
    *) tulan_error "OpenJDK 不支持架构: $(uname -m)"; return 1 ;;
  esac
}

tulan_openjdk_cellar_root() {
  local major="$1" version="$2"
  echo "$(tulan_get_home)/cellar/$(tulan_openjdk_tool_name "$major")/${version}"
}

tulan_maven_cellar_root() {
  local version="$1"
  echo "$(tulan_get_home)/cellar/maven/${version}"
}

tulan_java_save_state() {
  local major="$1" version="$2" java_home="$3"
  python3 - "$major" "$version" "$java_home" "$(tulan_java_state_path)" <<'PY'
import json, sys
from pathlib import Path

major, version, java_home, state_path = sys.argv[1:5]
state = Path(state_path)
state.parent.mkdir(parents=True, exist_ok=True)
data = json.loads(state.read_text()) if state.exists() else {"active_major": "", "java_home": "", "runtimes": {}}
data["active_major"] = major
data["java_home"] = java_home
data["runtimes"][major] = {"version": version, "java_home": java_home}
state.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY
}

tulan_java_activate() {
  local major="$1"
  local tool version java_home cellar_root

  tool="$(tulan_openjdk_tool_name "$major")"
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
    tulan_error "未安装 OpenJDK ${major}"
    tulan_error "  请先运行: brew install openjdk-${major}"
    return 1
  fi

  java_home="$(python3 - "$tool" "$version" "$(tulan_binary_registry_path)" <<'PY'
import json, sys
from pathlib import Path
tool, version, reg_path = sys.argv[1:4]
data = json.loads(Path(reg_path).read_text())
entry = data.get(tool, {}).get("versions", {}).get(version, {})
print(entry.get("java_home", ""))
PY
)"

  if [[ -z "$java_home" ]] || [[ ! -d "$java_home" ]]; then
    local java_bin
    cellar_root="$(tulan_openjdk_cellar_root "$major" "$version")"
    java_bin="$(find "$cellar_root" -type f -name java -path '*/bin/java' 2>/dev/null | head -1)"
    if [[ -n "$java_bin" ]]; then
      java_home="$(cd "$(dirname "$java_bin")/.." && pwd)"
    fi
  fi

  if [[ -z "$java_home" ]] || [[ ! -x "${java_home}/bin/java" ]]; then
    tulan_error "无法定位 JAVA_HOME: openjdk-${major} ${version}"
    return 1
  fi

  tulan_java_save_state "$major" "$version" "$java_home"
  tulan_java_link_bin "$java_home"
  tulan_runtime_configure
  tulan_log "已切换 Java ${major}: ${java_home}"
  echo ""
  echo "  JAVA_HOME=${java_home}"
  echo "  验证: java -version"
  tulan_runtime_hint
}

tulan_openjdk_fetch_asset() {
  local major="$1"
  local os arch
  os="$(tulan_jdk_adoptium_os)"
  arch="$(tulan_jdk_adoptium_arch)"

  python3 - "$major" "$os" "$arch" <<'PY'
import json, sys, urllib.request

major, os_name, arch = sys.argv[1:4]
url = (
    f"https://api.adoptium.net/v3/assets/latest/{major}/hotspot"
    f"?architecture={arch}&image_type=jdk&os={os_name}"
)
req = urllib.request.Request(url, headers={"User-Agent": "tulan-tools"})
with urllib.request.urlopen(req, timeout=60) as resp:
    data = json.load(resp)
if not data:
    sys.exit(1)
asset = data[0]
version = asset.get("version", {}).get("semver") or asset.get("version", {}).get("openjdk_version", "")
link = asset.get("binary", {}).get("package", {}).get("link", "")
if not link or not version:
    sys.exit(2)
print(version)
print(link)
PY
}

tulan_openjdk_register() {
  local major="$1" version="$2" java_home="$3" activate="${4:-true}" source="${5:-adoptium}"
  local tool
  tool="$(tulan_openjdk_tool_name "$major")"
  python3 - "$tool" "$version" "$java_home" "$activate" "$source" "$(tulan_binary_registry_path)" <<'PY'
import json, sys, time
from pathlib import Path

tool, version, java_home, activate, source, reg_path = sys.argv[1:7]
reg = Path(reg_path)
reg.parent.mkdir(parents=True, exist_ok=True)
data = json.loads(reg.read_text()) if reg.exists() else {}
entry = data.setdefault(tool, {"install_name": tool, "active": "", "versions": {}})
entry["install_name"] = tool
entry["versions"][version] = {
    "source": source,
    "installed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "java_home": java_home,
    "major": tool.replace("openjdk-", ""),
}
if activate == "true":
    entry["active"] = version
reg.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY
}

tulan_openjdk_install_archive() {
  local major="$1" version="$2" archive="$3" source="${4:-upstream}"
  local cellar_root java_bin java_home

  if ! command -v tar &>/dev/null; then
    tulan_error "安装 OpenJDK 需要 tar"
    return 1
  fi

  cellar_root="$(tulan_openjdk_cellar_root "$major" "$version")"
  mkdir -p "$cellar_root"
  tar -xzf "$archive" -C "$cellar_root"

  java_bin="$(find "$cellar_root" -type f -name java -path '*/bin/java' 2>/dev/null | head -1)"
  [[ -n "$java_bin" ]] || { tulan_error "解压后未找到 java 可执行文件"; return 1; }
  java_home="$(cd "$(dirname "$java_bin")/.." && pwd)"

  tulan_openjdk_register "$major" "$version" "$java_home" "true" "$source"
  tulan_java_activate "$major"
  tulan_log "  已安装: ${cellar_root}（${source}）"
}

tulan_install_openjdk_from_bin() {
  local major="$1"
  local dry_run="${2:-false}"
  local verify="${3:-true}"
  local tool version tmp

  tool="$(tulan_openjdk_tool_name "$major")"
  version="$(tulan_manifest_tool_version "$tool")"
  [[ -n "$version" ]] || { tulan_error "bin 索引无 OpenJDK ${major} 版本"; return 1; }

  tulan_log "安装 OpenJDK ${major} ${version}（bin 索引）"

  if [[ "$dry_run" == true ]]; then
    tulan_log "[dry-run] ${tool} ${version}"
    return 0
  fi

  tmp="$(mktemp)"
  if ! tulan_download_archive_from_github "$tool" "$tmp" "$verify"; then
    rm -f "$tmp"
    return 1
  fi
  tulan_openjdk_install_archive "$major" "$version" "$tmp" "github"
  rm -f "$tmp"
}

tulan_install_openjdk() {
  local major="$1"
  local _requested_version="${2:-}"
  local dry_run="${3:-false}"
  local asset_info version download_url tmp

  if ! command -v tar &>/dev/null; then
    tulan_error "安装 OpenJDK 需要 tar"
    return 1
  fi

  tulan_log "安装 OpenJDK ${major}（Eclipse Temurin / Adoptium 上游）"
  asset_info="$(tulan_openjdk_fetch_asset "$major")" || {
    tulan_error "无法获取 OpenJDK ${major} 下载信息"
    return 1
  }
  version="$(echo "$asset_info" | sed -n '1p')"
  download_url="$(echo "$asset_info" | sed -n '2p')"

  tulan_debug "版本: ${version}"
  tulan_debug "URL: ${download_url}"

  if [[ "$dry_run" == true ]]; then
    tulan_log "[dry-run] openjdk-${major} ${version}"
    return 0
  fi

  tmp="$(mktemp)"
  curl -fSL "$download_url" -o "$tmp"
  tulan_openjdk_install_archive "$major" "$version" "$tmp" "upstream"
  rm -f "$tmp"
}

tulan_maven_latest_version() {
  python3 - <<'PY'
import re, sys, urllib.request

url = "https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/maven-metadata.xml"
req = urllib.request.Request(url, headers={"User-Agent": "tulan-tools"})
with urllib.request.urlopen(req, timeout=30) as resp:
    text = resp.read().decode()

def is_stable(v):
    return not re.search(r"(alpha|beta|rc|snapshot)", v, re.I)

m = re.search(r"<release>([^<]+)</release>", text)
if m and is_stable(m.group(1)) and m.group(1).startswith("3."):
    print(m.group(1))
    sys.exit(0)

versions = re.findall(r"<version>([^<]+)</version>", text)
stable = [v for v in versions if re.match(r"^3\.\d+\.\d+$", v)]
if stable:
    print(stable[-1])
    sys.exit(0)
sys.exit(1)
PY
}

tulan_maven_install_archive() {
  local version="$1" archive="$2" source="${3:-upstream}"
  local cellar_root mvn_home

  if ! command -v tar &>/dev/null; then
    tulan_error "安装 Maven 需要 tar"
    return 1
  fi

  cellar_root="$(tulan_maven_cellar_root "$version")"
  mkdir -p "$cellar_root"
  tar -xzf "$archive" -C "$cellar_root"

  mvn_home="${cellar_root}/apache-maven-${version}"
  [[ -x "${mvn_home}/bin/mvn" ]] || { tulan_error "Maven 解压异常: ${mvn_home}"; return 1; }

  mkdir -p "$(tulan_get_home)/bin"
  ln -sf "../cellar/maven/${version}/apache-maven-${version}/bin/mvn" "$(tulan_get_home)/bin/mvn"

  python3 - "$version" "$mvn_home" "$source" "$(tulan_binary_registry_path)" <<'PY'
import json, sys, time
from pathlib import Path

version, mvn_home, source, reg_path = sys.argv[1:5]
reg = Path(reg_path)
reg.parent.mkdir(parents=True, exist_ok=True)
data = json.loads(reg.read_text()) if reg.exists() else {}
entry = data.setdefault("maven", {"install_name": "mvn", "active": "", "versions": {}})
entry["install_name"] = "mvn"
entry["versions"][version] = {
    "source": source,
    "installed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "maven_home": mvn_home,
}
entry["active"] = version
reg.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY

  tulan_log "  已安装: ${mvn_home}（${source}）"
  tulan_log "  已链接: $(tulan_get_home)/bin/mvn"
}

tulan_install_maven_from_bin() {
  local dry_run="${1:-false}"
  local verify="${2:-true}"
  local version tmp

  version="$(tulan_manifest_tool_version "maven")"
  [[ -n "$version" ]] || { tulan_error "bin 索引无 Maven 版本"; return 1; }

  tulan_log "安装 Maven ${version}（bin 索引）"

  if [[ "$dry_run" == true ]]; then
    tulan_log "[dry-run] maven ${version}"
    return 0
  fi

  tmp="$(mktemp)"
  if ! tulan_download_archive_from_github "maven" "$tmp" "$verify"; then
    rm -f "$tmp"
    return 1
  fi
  tulan_maven_install_archive "$version" "$tmp" "github"
  rm -f "$tmp"
}

tulan_install_maven() {
  local requested_version="${1:-}"
  local dry_run="${2:-false}"
  local version url tmp

  version="${requested_version:-$(tulan_maven_latest_version)}"
  [[ -n "$version" ]] || { tulan_error "无法获取 Maven 最新版本"; return 1; }

  url="https://dlcdn.apache.org/maven/maven-3/${version}/binaries/apache-maven-${version}-bin.tar.gz"
  tulan_log "安装 Maven ${version}（Apache 上游）"
  tulan_debug "URL: ${url}"

  if [[ "$dry_run" == true ]]; then
    tulan_log "[dry-run] maven ${version}"
    return 0
  fi

  tmp="$(mktemp)"
  if ! curl -fSL "$url" -o "$tmp"; then
    url="https://archive.apache.org/dist/maven/maven-3/${version}/binaries/apache-maven-${version}-bin.tar.gz"
    tulan_log "尝试镜像: ${url}"
    curl -fSL "$url" -o "$tmp"
  fi
  tulan_maven_install_archive "$version" "$tmp" "upstream"
  rm -f "$tmp"
}

tulan_openjdk_show_versions() {
  local major="$1"
  local tool upstream
  tool="$(tulan_openjdk_tool_name "$major")"

  local index_ver
  index_ver="$(tulan_manifest_index_version_display "$tool" 2>/dev/null || echo "待同步")"

  echo "OpenJDK ${major}（Eclipse Temurin）"
  echo "────────────────────────────────────"
  echo "  bin 索引版本（brew install 默认）: ${index_ver}"

  upstream="$(tulan_openjdk_fetch_asset "$major" 2>/dev/null | sed -n '1p' || echo "")"
  if [[ -n "$upstream" ]]; then
    echo "  上游最新: ${upstream}"
  fi

  if [[ -f "$(tulan_binary_registry_path)" ]]; then
    python3 - "$tool" "$(tulan_binary_registry_path)" "$(tulan_java_state_path)" <<'PY'
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
    print(f"  JAVA_HOME 当前: Java {active_major} -> {state.get('java_home', '')}")
else:
    print("  JAVA_HOME 当前: (未设置)")
PY
  else
    echo "  本地已装: (无)"
    echo "  JAVA_HOME 当前: (未设置)"
  fi

  echo ""
  echo "  安装: brew install openjdk-${major}"
  echo "  切换: brew use java ${major}"
}

tulan_maven_show_versions() {
  local latest installed
  latest="$(tulan_maven_latest_version 2>/dev/null || echo "")"

  local index_ver
  index_ver="$(tulan_manifest_index_version_display "maven" 2>/dev/null || echo "待同步")"

  echo "Maven"
  echo "────────────────────────────────────"
  echo "  bin 索引版本（brew install 默认）: ${index_ver}"
  if tulan_manifest_tool_has_platform_path "maven" 2>/dev/null; then
    echo "  bin 下载地址:"
    tulan_archive_log_download_urls "maven" 2>&1 | sed 's/^\[tulan-tools\] /    /'
  elif [[ "$index_ver" == "待同步" ]]; then
    echo "  提示: brew install maven --refresh-manifest  刷新 bin 索引"
    echo "  bin 归档（已同步时）: linux-amd64/archives/apache-maven-bin.tar.gz"
    echo "  media: https://media.githubusercontent.com/media/guangee/tulan-tools/bin/linux-amd64/archives/apache-maven-bin.tar.gz"
    echo "  代理: https://gh.coding-space.cn/https://media.githubusercontent.com/media/guangee/tulan-tools/bin/linux-amd64/archives/apache-maven-bin.tar.gz"
  fi
  [[ -n "$latest" ]] && echo "  上游最新: ${latest}"

  if [[ -f "$(tulan_binary_registry_path)" ]]; then
    installed="$(python3 - "$(tulan_binary_registry_path)" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text())
entry = data.get("maven", {})
active = entry.get("active", "")
versions = sorted(entry.get("versions", {}).keys())
if versions:
    print(", ".join(f"{v}{'*' if v == active else ''}" for v in versions))
PY
)"
    [[ -n "$installed" ]] && echo "  本地已装: ${installed}" || echo "  本地已装: (无)"
  else
    echo "  本地已装: (无)"
  fi
  echo ""
  echo "  安装: brew install maven"
}

tulan_openjdk_uninstall() {
  local major="$1" version="${2:-}"
  local tool home reg active_major

  tool="$(tulan_openjdk_tool_name "$major")"
  home="$(tulan_get_home)"
  reg="$(tulan_binary_registry_path)"

  if [[ ! -f "$reg" ]]; then
    tulan_error "未安装: ${tool}"
    return 1
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

  active_major="$(python3 - "$(tulan_java_state_path)" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
if p.exists():
    print(json.loads(p.read_text()).get("active_major", ""))
PY
)"
  if [[ "$active_major" == "$major" ]]; then
    tulan_java_unlink_bin
    rm -f "$(tulan_java_state_path)"
    tulan_runtime_configure
    tulan_log "已清除 Java 环境（曾使用 Java ${major}）"
  fi

  tulan_log "已卸载: ${tool}${version:+ ${version}}"
}

tulan_maven_uninstall() {
  local version="${1:-}"
  local home reg

  home="$(tulan_get_home)"
  reg="$(tulan_binary_registry_path)"

  if [[ ! -f "$reg" ]]; then
    tulan_error "未安装: maven"
    return 1
  fi

  python3 - "$version" "$reg" "$home" <<'PY'
import json, shutil, sys
from pathlib import Path

version, reg_path, home = sys.argv[1:4]
reg = Path(reg_path)
home = Path(home)
data = json.loads(reg.read_text())
entry = data.get("maven")
if not entry:
    sys.exit(2)
remove = [version] if version else list(entry.get("versions", {}).keys())
for ver in remove:
    cellar = home / "cellar" / "maven" / ver
    if cellar.exists():
        shutil.rmtree(cellar)
    entry.get("versions", {}).pop(ver, None)
link = home / "bin" / "mvn"
if not entry.get("versions"):
    data.pop("maven", None)
    if link.exists() or link.is_symlink():
        link.unlink()
else:
    entry["active"] = sorted(entry["versions"].keys())[-1]
    ver = entry["active"]
    mvn_home = entry["versions"][ver].get("maven_home", "")
    if mvn_home:
        rel = f"../cellar/maven/{ver}/apache-maven-{ver}/bin/mvn"
        link.parent.mkdir(parents=True, exist_ok=True)
        if link.exists() or link.is_symlink():
            link.unlink()
        link.symlink_to(rel)
reg.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY
  local rc=$?
  if [[ $rc -eq 2 ]]; then
    tulan_error "未安装: maven"
    return 1
  fi
  tulan_log "已卸载: maven${version:+ ${version}}"
}

tulan_jdk_maven_list() {
  local reg state active_major java_home
  reg="$(tulan_binary_registry_path)"
  state="$(tulan_java_state_path)"

  echo "Java / Maven（bin 索引 / 上游）:"
  echo "────────────────────────────────────"

  for major in 8 11 17; do
    local tool index_ver ver_text
    tool="$(tulan_openjdk_tool_name "$major")"
    index_ver="$(tulan_manifest_index_version_display "$tool" 2>/dev/null || echo "待同步")"
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
    if [[ -n "${ver_text:-}" ]]; then
      printf "  %-18s 最新:%-16s 已装:[%s]\n" "openjdk-${major}" "$index_ver" "$ver_text"
    else
      printf "  %-18s 最新:%-16s 未安装\n" "openjdk-${major}" "$index_ver"
    fi
  done

  if [[ -f "$state" ]]; then
    active_major="$(python3 - "$state" <<'PY'
import json, sys
from pathlib import Path
print(json.loads(Path(sys.argv[1]).read_text()).get("active_major", ""))
PY
)"
    java_home="$(python3 - "$state" <<'PY'
import json, sys
from pathlib import Path
print(json.loads(Path(sys.argv[1]).read_text()).get("java_home", ""))
PY
)"
    [[ -n "$active_major" ]] && echo "  JAVA_HOME 当前: Java ${active_major} -> ${java_home}"
  fi

  if [[ -f "$reg" ]]; then
    local mvn_text
    mvn_text="$(python3 - "$reg" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text())
entry = data.get("maven", {})
active = entry.get("active", "")
versions = sorted(entry.get("versions", {}).keys())
if versions:
    print(", ".join(f"{v}{'*' if v == active else ''}" for v in versions))
PY
)"
    local mvn_index
    mvn_index="$(tulan_manifest_index_version_display "maven" 2>/dev/null || echo "待同步")"
    if [[ -n "${mvn_text:-}" ]]; then
      printf "  %-18s 最新:%-16s 已装:[%s]\n" "maven" "$mvn_index" "$mvn_text"
    else
      printf "  %-18s 最新:%-16s 未安装\n" "maven" "$mvn_index"
    fi
  else
    printf "  %-18s 最新:%-16s 未安装\n" "maven" "$(tulan_manifest_index_version_display "maven" 2>/dev/null || echo "待同步")"
  fi
}
