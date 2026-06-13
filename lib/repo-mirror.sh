#!/usr/bin/env bash
# Debian / Ubuntu / CentOS 系统软件源国内镜像与还原

set -euo pipefail

TULAN_REPO_MIRROR_BASE="${TULAN_REPO_MIRROR_BASE:-https://mirrors.aliyun.com}"
TULAN_REPO_BACKUP_DIR="${TULAN_REPO_BACKUP_DIR:-$(tulan_get_home)/state/repo-backup}"
TULAN_REPO_STATE_FILE="${TULAN_REPO_STATE_FILE:-$(tulan_get_home)/state/repo-mirror.json}"

tulan_repo_mirror_require_linux() {
  if [[ "$(uname -s | tr '[:upper:]' '[:lower:]')" != "linux" ]]; then
    tulan_error "系统软件源镜像目前仅支持 Linux"
    return 1
  fi
}

tulan_repo_mirror_latest_backup() {
  local latest="${TULAN_REPO_BACKUP_DIR}/latest"
  [[ -f "$latest" ]] || return 1
  local stamp
  stamp="$(tr -d '[:space:]' < "$latest")"
  [[ -n "$stamp" && -d "${TULAN_REPO_BACKUP_DIR}/${stamp}" ]] || return 1
  echo "${TULAN_REPO_BACKUP_DIR}/${stamp}"
}

tulan_repo_mirror_save_state() {
  local mode="$1"
  mkdir -p "$(dirname "$TULAN_REPO_STATE_FILE")"
  python3 - "$mode" "$TULAN_REPO_STATE_FILE" "$(tulan_detect_os)" "$(tulan_detect_pkg_manager)" <<'PY'
import json, sys, time
from pathlib import Path

mode, path, os_id, pkg_mgr = sys.argv[1:5]
data = {
    "mode": mode,
    "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "os": os_id,
    "pkg_manager": pkg_mgr,
}
Path(path).write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY
}

tulan_repo_mirror_backup() {
  local stamp target pkg_manager
  pkg_manager="$(tulan_detect_pkg_manager)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  target="${TULAN_REPO_BACKUP_DIR}/${stamp}"
  mkdir -p "$target"

  tulan_require_privilege || return 1
  tulan_log "备份系统软件源到 ${target}..."

  case "$pkg_manager" in
    apt)
      tulan_as_root cp -a /etc/apt/sources.list "${target}/sources.list" 2>/dev/null || true
      if [[ -d /etc/apt/sources.list.d ]]; then
        tulan_as_root cp -a /etc/apt/sources.list.d "${target}/sources.list.d"
      fi
      ;;
    dnf|yum)
      if [[ -d /etc/yum.repos.d ]]; then
        tulan_as_root cp -a /etc/yum.repos.d "${target}/yum.repos.d"
      fi
      ;;
    *)
      tulan_error "不支持的包管理器: ${pkg_manager}"
      return 1
      ;;
  esac

  echo "$stamp" > "${TULAN_REPO_BACKUP_DIR}/latest"
  tulan_repo_mirror_save_state "backup"
  tulan_log "备份完成: ${stamp}"
}

tulan_repo_mirror_enable_disabled_repos() {
  local pkg_manager f
  pkg_manager="$(tulan_detect_pkg_manager)"
  case "$pkg_manager" in
    apt)
      for f in /etc/apt/sources.list.d/*.list.tulan-disabled; do
        [[ -e "$f" ]] || continue
        tulan_as_root mv "$f" "${f%.tulan-disabled}"
      done
      ;;
    dnf|yum)
      tulan_as_root rm -f /etc/yum.repos.d/tulan-tools.repo
      for f in /etc/yum.repos.d/*.repo.tulan-disabled; do
        [[ -e "$f" ]] || continue
        tulan_as_root mv "$f" "${f%.tulan-disabled}"
      done
      ;;
  esac
}

tulan_repo_mirror_apply_apt() {
  local mode="$1"
  local tmp
  tmp="$(mktemp)"

  python3 - "$mode" "$TULAN_REPO_MIRROR_BASE" <<'PY' > "$tmp"
import sys
from pathlib import Path

mode, mirror_base = sys.argv[1:3]
mirror_base = mirror_base.rstrip("/")

data = {}
if Path("/etc/os-release").exists():
    for line in Path("/etc/os-release").read_text().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            data[k] = v.strip().strip('"')

os_id = data.get("ID", "")
codename = data.get("VERSION_CODENAME", "")
version_id = data.get("VERSION_ID", "")

if not codename:
    mapping = {
        ("debian", "12"): "bookworm",
        ("debian", "11"): "bullseye",
        ("ubuntu", "24.04"): "noble",
        ("ubuntu", "22.04"): "jammy",
        ("ubuntu", "20.04"): "focal",
        ("ubuntu", "26.04"): "resolute",  # 预留，运行时以 VERSION_CODENAME 为准
    }
    codename = mapping.get((os_id, version_id), "")

if not codename:
    raise SystemExit(f"无法识别系统代号: {os_id} {version_id}")

lines = []
if os_id == "debian":
    if mode == "cn":
        lines = [
            f"deb {mirror_base}/debian/ {codename} main contrib non-free non-free-firmware",
            f"deb {mirror_base}/debian/ {codename}-updates main contrib non-free non-free-firmware",
            f"deb {mirror_base}/debian-security {codename}-security main contrib non-free non-free-firmware",
        ]
    else:
        lines = [
            f"deb http://deb.debian.org/debian {codename} main contrib non-free non-free-firmware",
            f"deb http://deb.debian.org/debian {codename}-updates main contrib non-free non-free-firmware",
            f"deb http://security.debian.org/debian-security {codename}-security main contrib non-free non-free-firmware",
        ]
elif os_id == "ubuntu":
    if mode == "cn":
        base = f"{mirror_base}/ubuntu/"
        lines = [
            f"deb {base} {codename} main restricted universe multiverse",
            f"deb {base} {codename}-updates main restricted universe multiverse",
            f"deb {base} {codename}-backports main restricted universe multiverse",
            f"deb {base} {codename}-security main restricted universe multiverse",
        ]
    else:
        lines = [
            f"deb http://archive.ubuntu.com/ubuntu/ {codename} main restricted universe multiverse",
            f"deb http://archive.ubuntu.com/ubuntu/ {codename}-updates main restricted universe multiverse",
            f"deb http://archive.ubuntu.com/ubuntu/ {codename}-backports main restricted universe multiverse",
            f"deb http://security.ubuntu.com/ubuntu {codename}-security main restricted universe multiverse",
        ]
else:
    raise SystemExit(f"不支持的 apt 系统: {os_id}")

print("# tulan-tools 自动生成 — 系统软件源")
print("# mode:", mode)
print("\n".join(lines))
print()
PY

  tulan_as_root cp "$tmp" /etc/apt/sources.list
  rm -f "$tmp"

  if [[ "$mode" == "cn" ]]; then
    local f base
    for f in /etc/apt/sources.list.d/*.list; do
      [[ -e "$f" ]] || continue
      base="$(basename "$f")"
      [[ "$base" == "tulan-tools-"* ]] && continue
      tulan_as_root mv "$f" "${f}.tulan-disabled"
    done
  else
    tulan_repo_mirror_enable_disabled_repos
  fi

  tulan_as_root apt-get clean 2>/dev/null || true
  tulan_as_root apt-get update -qq 2>/dev/null || tulan_as_root apt-get update
}

tulan_repo_mirror_apply_yum() {
  local mode="$1"
  local tmp repo_dir="/etc/yum.repos.d"

  tmp="$(mktemp)"
  python3 - "$mode" "$TULAN_REPO_MIRROR_BASE" <<'PY' > "$tmp"
import sys
from pathlib import Path

mode, mirror_base = sys.argv[1:3]
mirror_base = mirror_base.rstrip("/")

data = {}
if Path("/etc/os-release").exists():
    for line in Path("/etc/os-release").read_text().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            data[k] = v.strip().strip('"')

os_id = data.get("ID", "")
version_id = data.get("VERSION_ID", "")

def centos7_repo(mode):
    if mode == "cn":
        base = f"{mirror_base}/centos-vault/$releasever"
    else:
        base = "http://vault.centos.org/$releasever"
    repos = {
        "base": f"{base}/os/$basearch/",
        "updates": f"{base}/updates/$basearch/",
        "extras": f"{base}/extras/$basearch/",
    }
    out = ["# tulan-tools 自动生成 — CentOS 软件源", f"# mode: {mode}", ""]
    for name, url in repos.items():
        out.extend([
            f"[{name}]",
            f"name=CentOS-$releasever - {name.title()}",
            f"baseurl={url}",
            "gpgcheck=1",
            "enabled=1",
            "gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7",
            "",
        ])
    return "\n".join(out)

def centos_stream_repo(mode):
    if mode == "cn":
        base = f"{mirror_base}/centos/$stream/$basearch"
    else:
        base = "http://mirror.centos.org/$contentdir/$stream/$basearch"
    out = ["# tulan-tools 自动生成", f"# mode: {mode}", ""]
    for name, path in [("baseos", "os"), ("appstream", "AppStream"), ("extras", "extras")]:
        out.extend([
            f"[{name}]",
            f"name=CentOS - {name}",
            f"baseurl={base}/{path}/",
            "gpgcheck=1",
            "enabled=1",
            "",
        ])
    return "\n".join(out)

if os_id == "centos" and version_id.startswith("7"):
    print(centos7_repo(mode))
elif os_id in {"centos", "rocky", "almalinux", "rhel"}:
    print(centos_stream_repo(mode))
else:
    raise SystemExit(f"不支持的 yum 系统: {os_id} {version_id}")
PY

  local f
  for f in "${repo_dir}"/*.repo; do
    [[ -e "$f" ]] || continue
    [[ "$(basename "$f")" == tulan-tools-* ]] && continue
    tulan_as_root mv "$f" "${f}.tulan-disabled"
  done

  tulan_as_root cp "$tmp" "${repo_dir}/tulan-tools.repo"
  rm -f "$tmp"
  tulan_as_root yum clean all 2>/dev/null || tulan_as_root dnf clean all 2>/dev/null || true
}

tulan_repo_mirror_configure_cn() {
  local os pkg_manager

  tulan_repo_mirror_require_linux || return 1
  tulan_require_privilege || return 1

  os="$(tulan_detect_os)"
  pkg_manager="$(tulan_detect_pkg_manager)"

  if ! tulan_repo_mirror_latest_backup &>/dev/null; then
    tulan_repo_mirror_backup
  fi

  tulan_log "配置 ${os} 国内软件源（${TULAN_REPO_MIRROR_BASE}）..."
  case "$pkg_manager" in
    apt)
      tulan_repo_mirror_apply_apt "cn"
      ;;
    dnf|yum)
      tulan_repo_mirror_apply_yum "cn"
      ;;
    *)
      tulan_error "当前系统不支持软件源镜像: ${os} / ${pkg_manager}"
      return 1
      ;;
  esac

  tulan_repo_mirror_save_state "cn"
  tulan_log "国内软件源配置完成"
}

tulan_repo_mirror_restore_from_backup() {
  local backup pkg_manager
  backup="$(tulan_repo_mirror_latest_backup)" || return 1
  pkg_manager="$(tulan_detect_pkg_manager)"

  tulan_log "从备份还原软件源: ${backup}..."
  case "$pkg_manager" in
    apt)
      [[ -f "${backup}/sources.list" ]] && tulan_as_root cp -a "${backup}/sources.list" /etc/apt/sources.list
      if [[ -d "${backup}/sources.list.d" ]]; then
        tulan_as_root rm -rf /etc/apt/sources.list.d
        tulan_as_root cp -a "${backup}/sources.list.d" /etc/apt/sources.list.d
      fi
      local f
      for f in /etc/apt/sources.list.d/*.list.tulan-disabled; do
        [[ -e "$f" ]] || continue
        tulan_as_root mv "$f" "${f%.tulan-disabled}"
      done
      tulan_as_root apt-get update -qq 2>/dev/null || tulan_as_root apt-get update
      ;;
    dnf|yum)
      if [[ -d "${backup}/yum.repos.d" ]]; then
        tulan_as_root rm -rf /etc/yum.repos.d
        tulan_as_root cp -a "${backup}/yum.repos.d" /etc/yum.repos.d
      fi
      tulan_as_root yum clean all 2>/dev/null || tulan_as_root dnf clean all 2>/dev/null || true
      ;;
  esac
  tulan_repo_mirror_save_state "restored"
  return 0
}

tulan_repo_mirror_restore_official() {
  local os pkg_manager

  os="$(tulan_detect_os)"
  pkg_manager="$(tulan_detect_pkg_manager)"

  tulan_log "还原为官方原版软件源..."
  tulan_repo_mirror_enable_disabled_repos
  case "$pkg_manager" in
    apt)
      tulan_repo_mirror_apply_apt "official"
      ;;
    dnf|yum)
      if [[ -f /etc/yum.repos.d/tulan-tools.repo ]] || ! ls /etc/yum.repos.d/*.repo &>/dev/null; then
        tulan_repo_mirror_apply_yum "official"
      fi
      tulan_as_root yum clean all 2>/dev/null || tulan_as_root dnf clean all 2>/dev/null || true
      ;;
    *)
      tulan_error "不支持的包管理器: ${pkg_manager}"
      return 1
      ;;
  esac
  tulan_repo_mirror_save_state "official"
}

tulan_repo_mirror_restore() {
  tulan_repo_mirror_require_linux || return 1
  tulan_require_privilege || return 1

  if tulan_repo_mirror_restore_from_backup; then
    tulan_log "已从备份还原原版软件源"
    return 0
  fi

  tulan_log "未找到备份，写入官方默认源..."
  tulan_repo_mirror_restore_official
}

tulan_repo_mirror_show_status() {
  local os pkg_manager mode="unknown"

  echo "系统软件源:"
  if [[ -f "$TULAN_REPO_STATE_FILE" ]]; then
    mode="$(python3 - "$TULAN_REPO_STATE_FILE" <<'PY' 2>/dev/null || echo unknown
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
if p.exists():
    print(json.loads(p.read_text()).get("mode", "unknown"))
PY
)"
  fi

  os="$(tulan_detect_os)"
  pkg_manager="$(tulan_detect_pkg_manager)"
  echo "  系统: ${os} / ${pkg_manager}"
  echo "  模式: ${mode}（cn=国内镜像, official=官方, restored=已还原, backup=仅备份）"

  if backup="$(tulan_repo_mirror_latest_backup 2>/dev/null)"; then
    echo "  备份: ${backup}"
  else
    echo "  备份: (无)"
  fi

  echo ""
  case "$pkg_manager" in
    apt)
      echo "  /etc/apt/sources.list（前 6 行）:"
      head -n 6 /etc/apt/sources.list 2>/dev/null | sed 's/^/    /' || echo "    (不可读)"
      ;;
    dnf|yum)
      echo "  活跃 repo:"
      ls -1 /etc/yum.repos.d/*.repo 2>/dev/null | sed 's/^/    /' || echo "    (无)"
      ;;
    *)
      echo "  (不支持)"
      ;;
  esac
}
