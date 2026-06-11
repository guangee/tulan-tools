#!/usr/bin/env bash
# Docker Engine 静态包安装（bin 索引 / 上游）

set -euo pipefail

TULAN_DOCKER_REGISTRY_MIRROR="${TULAN_DOCKER_REGISTRY_MIRROR:-https://hub.coding-space.cn}"
TULAN_DOCKER_BINARIES=(
  docker dockerd containerd runc ctr
  docker-init docker-proxy containerd-shim containerd-shim-runc-v2
)

tulan_docker_cellar_root() {
  echo "$(tulan_get_home)/cellar/docker/${1}"
}

tulan_docker_require_linux() {
  if [[ "$(uname -s | tr '[:upper:]' '[:lower:]')" != "linux" ]]; then
    tulan_error "Docker Engine 静态包仅支持 Linux"
    return 1
  fi
}

tulan_docker_latest_version() {
  python3 - <<'PY'
import re
import urllib.request

url = "https://download.docker.com/linux/static/stable/x86_64/"
req = urllib.request.Request(url, headers={"User-Agent": "tulan-tools"})
with urllib.request.urlopen(req, timeout=60) as resp:
    html = resp.read().decode()
vers = []
for v in re.findall(r"docker-(\d+\.\d+\.\d+)\.tgz", html):
    if v not in vers:
        vers.append(v)
if not vers:
    raise SystemExit(1)
print(vers[-1])
PY
}

tulan_docker_recent_versions() {
  python3 - <<'PY'
import re
import urllib.request

url = "https://download.docker.com/linux/static/stable/x86_64/"
req = urllib.request.Request(url, headers={"User-Agent": "tulan-tools"})
with urllib.request.urlopen(req, timeout=60) as resp:
    html = resp.read().decode()
vers = []
for v in re.findall(r"docker-(\d+\.\d+\.\d+)\.tgz", html):
    if v not in vers:
        vers.append(v)
print(" ".join(vers[-8:]))
PY
}

tulan_docker_upstream_url() {
  local version="$1"
  local platform_key

  platform_key="$(tulan_manifest_platform_key)"
  case "$platform_key" in
    linux-amd64)
      echo "https://download.docker.com/linux/static/stable/x86_64/docker-${version}.tgz"
      ;;
    linux-arm64)
      echo "https://download.docker.com/linux/static/stable/aarch64/docker-${version}.tgz"
      ;;
    *)
      tulan_error "Docker 静态包不支持平台: ${platform_key}"
      return 1
      ;;
  esac
}

tulan_docker_link_binaries() {
  local version="$1" docker_dir="$2"
  local home bin_dir name link

  home="$(tulan_get_home)"
  bin_dir="${home}/bin"
  mkdir -p "$bin_dir"

  for name in "${TULAN_DOCKER_BINARIES[@]}"; do
    if [[ -f "${docker_dir}/${name}" ]]; then
      link="${bin_dir}/${name}"
      ln -sf "../cellar/docker/${version}/docker/${name}" "$link"
    fi
  done
}

tulan_docker_register() {
  local version="$1" docker_dir="$2" source="${3:-upstream}"

  python3 - "$version" "$docker_dir" "$source" "$(tulan_binary_registry_path)" <<'PY'
import json, sys, time
from pathlib import Path

version, docker_dir, source, reg_path = sys.argv[1:5]
reg = Path(reg_path)
reg.parent.mkdir(parents=True, exist_ok=True)
data = json.loads(reg.read_text()) if reg.exists() else {}
entry = data.setdefault("docker", {"install_name": "docker", "active": "", "versions": {}})
entry["install_name"] = "docker"
entry["versions"][version] = {
    "source": source,
    "installed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "docker_root": docker_dir,
}
entry["active"] = version
reg.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY
}

tulan_docker_activate() {
  local version="$1"
  local docker_dir

  docker_dir="$(python3 - "$version" "$(tulan_binary_registry_path)" <<'PY'
import json, sys
from pathlib import Path

version, reg_path = sys.argv[1:3]
data = json.loads(Path(reg_path).read_text())
entry = data.get("docker", {})
info = entry.get("versions", {}).get(version)
if not info:
    sys.exit(1)
print(info.get("docker_root", ""))
PY
)" || {
    tulan_error "版本未安装: docker ${version}"
    return 1
  }

  if [[ ! -x "${docker_dir}/docker" ]]; then
    tulan_error "Docker 安装损坏: ${docker_dir}"
    return 1
  fi

  tulan_docker_link_binaries "$version" "$docker_dir"

  python3 - "$version" "$(tulan_binary_registry_path)" <<'PY'
import json, sys
from pathlib import Path

version, reg_path = sys.argv[1:3]
reg = Path(reg_path)
data = json.loads(reg.read_text())
if version not in data.get("docker", {}).get("versions", {}):
    sys.exit(1)
data["docker"]["active"] = version
reg.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY

  tulan_log "已切换 docker -> ${version}"
}

tulan_docker_install_archive() {
  local version="$1" archive="$2" source="${3:-upstream}"
  local cellar_root docker_dir

  if ! command -v tar &>/dev/null; then
    tulan_error "安装 Docker 需要 tar"
    return 1
  fi

  cellar_root="$(tulan_docker_cellar_root "$version")"
  mkdir -p "$cellar_root"
  tulan_verbose_step "解压 Docker 静态包"
  tar -xzf "$archive" -C "$cellar_root"

  docker_dir="${cellar_root}/docker"
  if [[ ! -x "${docker_dir}/docker" ]] || [[ ! -x "${docker_dir}/dockerd" ]]; then
    tulan_error "Docker 解压异常: ${docker_dir}"
    return 1
  fi

  tulan_docker_register "$version" "$docker_dir" "$source"
  tulan_docker_link_binaries "$version" "$docker_dir"
  tulan_log "  已安装: ${docker_dir}（${source}）"
  tulan_log "  已链接: $(tulan_get_home)/bin/docker (+ dockerd, containerd, runc ...)"
  tulan_docker_post_install
}

tulan_docker_post_install() {
  tulan_log "启动守护进程: sudo dockerd"
  tulan_log "验证: docker version（需 dockerd 已运行）"
  if command -v sudo &>/dev/null; then
    tulan_docker_configure_registry "$TULAN_DOCKER_REGISTRY_MIRROR" || true
  else
    tulan_log "配置镜像加速需 sudo，可设置 TULAN_DOCKER_REGISTRY_MIRROR 后重装"
  fi
}

tulan_docker_configure_registry() {
  local mirror="$1"
  local tmp

  if ! command -v sudo &>/dev/null; then
    tulan_error "配置 registry 镜像需要 sudo"
    return 1
  fi

  tmp="$(mktemp)"
  python3 - "$mirror" <<'PY' > "$tmp"
import json
import sys
from pathlib import Path

mirror = sys.argv[1]
path = Path("/etc/docker/daemon.json")
data = {}
if path.exists():
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError:
        data = {}

mirrors = list(data.get("registry-mirrors") or [])
if mirror not in mirrors:
    mirrors.insert(0, mirror)
data["registry-mirrors"] = mirrors
print(json.dumps(data, indent=2, ensure_ascii=False))
PY

  sudo mkdir -p /etc/docker
  sudo cp "$tmp" /etc/docker/daemon.json
  rm -f "$tmp"
  tulan_log "已写入 /etc/docker/daemon.json（registry: ${mirror}）"

  if command -v systemctl &>/dev/null; then
    if systemctl is-active docker &>/dev/null 2>&1; then
      sudo systemctl restart docker || true
    fi
  fi
}

tulan_install_docker_from_bin() {
  local dry_run="${1:-false}"
  local verify="${2:-true}"
  local version tmp

  tulan_docker_require_linux || return 1
  version="$(tulan_manifest_tool_version "docker")"
  [[ -n "$version" ]] || { tulan_error "bin 索引无 Docker 版本"; return 1; }

  tulan_log "安装 Docker ${version}（bin 索引）"

  if [[ "$dry_run" == true ]]; then
    tulan_log "[dry-run] docker ${version}"
    return 0
  fi

  tmp="$(mktemp)"
  if ! tulan_download_archive_from_github "docker" "$tmp" "$verify"; then
    rm -f "$tmp"
    return 1
  fi
  tulan_docker_install_archive "$version" "$tmp" "github"
  rm -f "$tmp"
}

tulan_install_docker_upstream() {
  local requested_version="${1:-}"
  local dry_run="${2:-false}"
  local version url tmp

  tulan_docker_require_linux || return 1
  version="${requested_version:-$(tulan_docker_latest_version)}"
  [[ -n "$version" ]] || { tulan_error "无法获取 Docker 最新版本"; return 1; }

  url="$(tulan_docker_upstream_url "$version")"
  tulan_log "安装 Docker ${version}（上游静态包）"
  tulan_debug "URL: ${url}"

  if [[ "$dry_run" == true ]]; then
    tulan_log "[dry-run] docker ${version}"
    return 0
  fi

  tmp="$(mktemp)"
  tulan_fetch_url "$url" "$tmp"
  tulan_verbose_step "安装 Docker ${version}"
  tulan_docker_install_archive "$version" "$tmp" "upstream"
  rm -f "$tmp"
}

tulan_docker_show_versions() {
  local index_ver upstream_latest recent installed

  index_ver="$(tulan_manifest_index_version_display "docker" 2>/dev/null || echo "待同步")"
  upstream_latest="$(tulan_docker_latest_version 2>/dev/null || echo "")"
  recent="$(tulan_docker_recent_versions 2>/dev/null || echo "")"

  echo "Docker Engine（静态包）"
  echo "────────────────────────────────────"
  echo "  bin 索引版本（brew install 默认）: ${index_ver}"
  if [[ -n "$upstream_latest" ]]; then
    echo "  上游最新版本: ${upstream_latest}"
  fi
  if [[ -n "$recent" ]]; then
    echo "  上游近期版本: ${recent}"
  fi

  if [[ -f "$(tulan_binary_registry_path)" ]]; then
    installed="$(python3 - "$(tulan_binary_registry_path)" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text())
entry = data.get("docker", {})
active = entry.get("active", "")
versions = sorted(entry.get("versions", {}).keys())
if versions:
    print(", ".join(f"{v}{'*' if v == active else ''}" for v in versions))
PY
)"
    if [[ -n "$installed" ]]; then
      echo "  本地已装（* 当前）: ${installed}"
    else
      echo "  本地已装: (无)"
    fi
  else
    echo "  本地已装: (无)"
  fi

  echo ""
  echo "  安装最新: brew install docker"
  echo "  指定版本: brew install docker --version <VER> --source upstream"
  echo "  切换版本: brew use docker <VER>"
  echo "  启动守护进程: sudo dockerd"
}

tulan_docker_uninstall() {
  local version="${1:-}"
  local home reg

  home="$(tulan_get_home)"
  reg="$(tulan_binary_registry_path)"

  if [[ ! -f "$reg" ]]; then
    tulan_error "未安装: docker"
    return 1
  fi

  python3 - "$version" "$reg" "$home" <<'PY'
import json, shutil, sys
from pathlib import Path

version, reg_path, home = sys.argv[1:4]
reg = Path(reg_path)
home = Path(home)
data = json.loads(reg.read_text())
entry = data.get("docker")
if not entry:
    sys.exit(2)

bin_names = [
    "docker", "dockerd", "containerd", "runc", "ctr",
    "docker-init", "docker-proxy", "containerd-shim", "containerd-shim-runc-v2",
]
versions = list(entry.get("versions", {}).keys())
remove = [version] if version else versions
for ver in remove:
    cellar = home / "cellar" / "docker" / ver
    if cellar.exists():
        shutil.rmtree(cellar)
    entry.get("versions", {}).pop(ver, None)

remaining = list(entry.get("versions", {}).keys())
if version and version != entry.get("active"):
    pass
elif remaining:
    entry["active"] = sorted(remaining)[-1]
    ver = entry["active"]
    docker_root = Path(entry["versions"][ver]["docker_root"])
    for name in bin_names:
        if (docker_root / name).exists():
            link = home / "bin" / name
            link.parent.mkdir(parents=True, exist_ok=True)
            if link.exists() or link.is_symlink():
                link.unlink()
            link.symlink_to(f"../cellar/docker/{ver}/docker/{name}")
else:
    entry["active"] = ""
    for name in bin_names:
        link = home / "bin" / name
        if link.exists() or link.is_symlink():
            link.unlink()
    if not entry.get("versions"):
        data.pop("docker", None)

reg.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY

  local rc=$?
  if [[ $rc -eq 2 ]]; then
    tulan_error "未安装: docker"
    return 1
  fi
  tulan_log "已卸载: docker${version:+ ${version}}"
}
