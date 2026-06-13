#!/usr/bin/env bash
# 系统时区与 NTP 同步（国内源测速 + 东八区）

set -euo pipefail

TULAN_TIME_DEFAULT_TIMEZONE="${TULAN_TIME_DEFAULT_TIMEZONE:-Asia/Shanghai}"
TULAN_TIME_SERVERS_FILE="${TULAN_TIME_SERVERS_FILE:-$(tulan_get_home)/config/ntp.servers.cn}"

# 读取默认 NTP 服务器列表（环境变量 TULAN_NTP_SERVERS 空格分隔可覆盖）
tulan_time_default_servers() {
  if [[ -n "${TULAN_NTP_SERVERS:-}" ]]; then
    echo "$TULAN_NTP_SERVERS"
    return 0
  fi

  local servers=() line
  if [[ -f "$TULAN_TIME_SERVERS_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      line="${line// /}"
      [[ -n "$line" ]] && servers+=("$line")
    done < "$TULAN_TIME_SERVERS_FILE"
  fi

  if [[ ${#servers[@]} -eq 0 ]]; then
    servers=(ntp.aliyun.com cn.ntp.org.cn ntp.ntsc.ac.cn time1.cloud.tencent.com)
  fi
  echo "${servers[*]}"
}

tulan_time_require_linux() {
  if [[ "$(uname -s | tr '[:upper:]' '[:lower:]')" != "linux" ]]; then
    tulan_error "系统时间同步目前仅支持 Linux"
    return 1
  fi
}

tulan_time_require_sudo() {
  if ! command -v sudo &>/dev/null; then
    tulan_error "配置系统时间需要 sudo"
    return 1
  fi
}

# 探测 NTP 服务器响应延迟（毫秒），输出按延迟升序：毫秒<TAB>主机
tulan_time_probe_servers() {
  local servers=("$@")
  [[ ${#servers[@]} -gt 0 ]] || servers=($(tulan_time_default_servers))

  python3 - "${servers[@]}" <<'PY'
import socket
import sys
import time

def probe(host: str, timeout: float = 2.0):
    try:
        addr = socket.gethostbyname(host)
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(timeout)
        msg = b"\x1b" + 47 * b"\0"
        t0 = time.perf_counter()
        sock.sendto(msg, (addr, 123))
        sock.recvfrom(1024)
        elapsed_ms = (time.perf_counter() - t0) * 1000.0
        sock.close()
        return elapsed_ms
    except OSError:
        return None

results = []
for host in sys.argv[1:]:
    ms = probe(host)
    if ms is not None:
        results.append((ms, host))

results.sort(key=lambda item: item[0])
for ms, host in results:
    print(f"{ms:.2f}\t{host}")
PY
}

tulan_time_rank_servers() {
  local servers=("$@")
  local probed=() line host

  while IFS=$'\t' read -r _ host; do
    [[ -n "$host" ]] && probed+=("$host")
  done < <(tulan_time_probe_servers "${servers[@]}")

  if [[ ${#probed[@]} -eq 0 ]]; then
    tulan_error "所有 NTP 服务器均不可达"
    return 1
  fi

  printf '%s\n' "${probed[@]}"
}

tulan_time_show_probe() {
  local servers=("$@")
  [[ ${#servers[@]} -gt 0 ]] || servers=($(tulan_time_default_servers))

  tulan_log "探测 NTP 服务器（${#servers[@]} 个）..."
  local count=0 line ms host
  while IFS=$'\t' read -r ms host; do
    count=$((count + 1))
    printf "  %2d. %-28s %8.2f ms\n" "$count" "$host" "$ms"
  done < <(tulan_time_probe_servers "${servers[@]}")

  if [[ "$count" -eq 0 ]]; then
    tulan_error "无可用 NTP 服务器"
    return 1
  fi
}

tulan_time_chrony_unit() {
  if systemctl list-unit-files chrony.service &>/dev/null 2>&1; then
    echo "chrony"
    return 0
  fi
  if systemctl list-unit-files chronyd.service &>/dev/null 2>&1; then
    echo "chronyd"
    return 0
  fi
  echo ""
}

tulan_time_chrony_conf_path() {
  if [[ -f /etc/chrony/chrony.conf ]]; then
    echo "/etc/chrony/chrony.conf"
  elif [[ -f /etc/chrony.conf ]]; then
    echo "/etc/chrony.conf"
  else
    echo "/etc/chrony/chrony.conf"
  fi
}

tulan_time_chrony_dropin_dir() {
  local base
  base="$(tulan_time_chrony_conf_path)"
  if [[ "$base" == "/etc/chrony/chrony.conf" ]]; then
    echo "/etc/chrony/conf.d"
  else
    echo "/etc/chrony.d"
  fi
}

tulan_time_install_chrony() {
  local pkg_manager
  pkg_manager="$(tulan_detect_pkg_manager)"

  case "$pkg_manager" in
    apt)
      sudo apt-get update -qq
      sudo apt-get install -y chrony
      ;;
    dnf)
      sudo dnf install -y chrony
      ;;
    yum)
      sudo yum install -y chrony
      ;;
    *)
      tulan_error "无法识别包管理器，请手动安装 chrony"
      return 1
      ;;
  esac
}

tulan_time_configure_timezone() {
  local timezone="${1:-$TULAN_TIME_DEFAULT_TIMEZONE}"

  if command -v timedatectl &>/dev/null; then
    sudo timedatectl set-timezone "$timezone"
    tulan_log "时区已设为 ${timezone}"
    return 0
  fi

  if [[ -f "/usr/share/zoneinfo/${timezone}" ]]; then
    sudo ln -sf "/usr/share/zoneinfo/${timezone}" /etc/localtime
    tulan_log "时区已设为 ${timezone}（/etc/localtime）"
    return 0
  fi

  tulan_error "无法设置时区: ${timezone}"
  return 1
}

tulan_time_write_chrony_config() {
  local dropin servers=("$@") primary conf_path

  [[ ${#servers[@]} -gt 0 ]] || return 1
  primary="${servers[0]}"
  conf_path="$(tulan_time_chrony_conf_path)"
  dropin="$(tulan_time_chrony_dropin_dir)/tulan-tools.conf"

  sudo mkdir -p "$(dirname "$dropin")"

  {
    echo "# tulan-tools 自动生成 — 国内 NTP 测速结果"
    echo "# 最快: ${primary}"
    echo "server ${primary} iburst prefer"
    local i
    for ((i = 1; i < ${#servers[@]}; i++)); do
      echo "server ${servers[$i]} iburst"
    done
    echo "makestep 1.0 3"
  } | sudo tee "$dropin" >/dev/null

  if [[ "$conf_path" == "/etc/chrony.conf" ]]; then
    if ! sudo grep -qF "include ${dropin}" "$conf_path" 2>/dev/null; then
      echo "include ${dropin}" | sudo tee -a "$conf_path" >/dev/null
    fi
  fi

  tulan_log "已写入 ${dropin}（首选: ${primary}）"
}

tulan_time_write_timesyncd_config() {
  local servers=("$@")
  local primary ntp_list fallback_list tmp i

  [[ ${#servers[@]} -gt 0 ]] || return 1
  primary="${servers[0]}"

  ntp_list="$primary"
  fallback_list=""
  for ((i = 1; i < ${#servers[@]} && i < 4; i++)); do
    fallback_list+="${servers[$i]} "
  done
  fallback_list="${fallback_list%" "}"

  tmp="$(mktemp)"
  python3 - "$primary" "$fallback_list" <<'PY' > "$tmp"
import sys
from pathlib import Path

primary, fallback = sys.argv[1:3]
path = Path("/etc/systemd/timesyncd.conf")
lines = []
if path.exists():
    lines = path.read_text().splitlines()

out = []
in_time = False
done_ntp = False
done_fallback = False

for line in lines:
    stripped = line.strip()
    if stripped == "[Time]":
        in_time = True
        out.append(line)
        continue
    if in_time and stripped.startswith("[") and stripped.endswith("]"):
        if not done_ntp:
            out.append(f"NTP={primary}")
            done_ntp = True
        if fallback and not done_fallback:
            out.append(f"FallbackNTP={fallback}")
            done_fallback = True
        in_time = False
        out.append(line)
        continue
    if in_time and stripped.startswith("NTP="):
        out.append(f"NTP={primary}")
        done_ntp = True
        continue
    if in_time and stripped.startswith("FallbackNTP="):
        if fallback:
            out.append(f"FallbackNTP={fallback}")
        done_fallback = True
        continue
    out.append(line)

if not any(line.strip() == "[Time]" for line in out):
    out.append("[Time]")
    in_time = True

if not done_ntp:
    out.append(f"NTP={primary}")
if fallback and not done_fallback:
    out.append(f"FallbackNTP={fallback}")

path.parent.mkdir(parents=True, exist_ok=True)
print("\n".join(out).rstrip() + "\n")
PY

  sudo cp "$tmp" /etc/systemd/timesyncd.conf
  rm -f "$tmp"
  tulan_log "已写入 /etc/systemd/timesyncd.conf（首选: ${primary}）"
}

tulan_time_enable_ntp() {
  if command -v timedatectl &>/dev/null; then
    sudo timedatectl set-ntp true
  fi
}

tulan_time_restart_sync_service() {
  local unit

  unit="$(tulan_time_chrony_unit)"
  if [[ -n "$unit" ]]; then
    sudo systemctl enable "$unit" 2>/dev/null || true
    sudo systemctl restart "$unit"
    tulan_log "已重启 ${unit}"
    return 0
  fi

  if systemctl list-unit-files systemd-timesyncd.service &>/dev/null 2>&1; then
    sudo systemctl enable systemd-timesyncd 2>/dev/null || true
    sudo systemctl restart systemd-timesyncd
    tulan_log "已重启 systemd-timesyncd"
    return 0
  fi

  tulan_error "未找到 chrony 或 systemd-timesyncd 服务"
  return 1
}

tulan_time_force_sync() {
  local unit waited

  unit="$(tulan_time_chrony_unit)"
  if [[ -n "$unit" ]] && command -v chronyc &>/dev/null; then
    sudo chronyc -a makestep 2>/dev/null || true
    for waited in 1 2 3 4 5; do
      if chronyc tracking 2>/dev/null | grep -q "Leap status.*Normal"; then
        return 0
      fi
      sleep 1
    done
    sudo chronyc -a burst 2>/dev/null || true
    return 0
  fi

  if command -v timedatectl &>/dev/null; then
    sudo timedatectl set-ntp true
  fi
}

tulan_time_show_status() {
  echo "系统时间状态"
  echo "────────────────────────────────────"

  if command -v timedatectl &>/dev/null; then
    timedatectl status 2>/dev/null || true
  else
    echo "  本地时间: $(date)"
    echo "  时区: $(date +%Z) ($(readlink -f /etc/localtime 2>/dev/null || echo unknown))"
  fi

  echo ""
  if command -v chronyc &>/dev/null; then
    echo "chrony 跟踪:"
    chronyc tracking 2>/dev/null | sed 's/^/  /' || echo "  (不可用)"
    echo ""
    echo "chrony 源:"
    chronyc sources -v 2>/dev/null | sed 's/^/  /' || echo "  (不可用)"
  elif command -v timedatectl &>/dev/null; then
    echo "timesyncd:"
    timedatectl timesync-status 2>/dev/null | sed 's/^/  /' || echo "  (不可用)"
  fi
}

tulan_time_setup() {
  local timezone="${1:-$TULAN_TIME_DEFAULT_TIMEZONE}"
  local skip_probe="${2:-false}"
  shift 2 2>/dev/null || true
  local servers=("$@")
  local ranked=() use_timesyncd=false

  tulan_time_require_linux || return 1
  tulan_time_require_sudo || return 1

  [[ ${#servers[@]} -gt 0 ]] || servers=($(tulan_time_default_servers))

  if [[ "$skip_probe" != true ]]; then
    tulan_time_show_probe "${servers[@]}" || return 1
    mapfile -t ranked < <(tulan_time_rank_servers "${servers[@]}")
  else
    ranked=("${servers[@]}")
    tulan_log "跳过测速，按配置顺序使用 NTP 源"
  fi

  tulan_log "配置时区 ${timezone}（东八区）..."
  tulan_time_configure_timezone "$timezone"

  if ! command -v chronyd &>/dev/null && ! command -v chronyc &>/dev/null; then
    tulan_log "安装 chrony..."
    tulan_time_install_chrony || use_timesyncd=true
  fi

  if [[ "$use_timesyncd" != true ]]; then
    tulan_time_write_chrony_config "${ranked[@]}"
  else
    tulan_log "回退到 systemd-timesyncd..."
    tulan_time_write_timesyncd_config "${ranked[@]}"
  fi

  tulan_time_enable_ntp
  tulan_time_restart_sync_service || return 1
  tulan_time_force_sync

  echo ""
  tulan_log "时间同步完成，当前: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  tulan_time_show_status
}
