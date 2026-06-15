#!/usr/bin/env bash
# 系统 DNS 探测与修复（按 OS / 网络栈自动选择配置方式）

set -euo pipefail

TULAN_DNS_SERVERS_FILE="${TULAN_DNS_SERVERS_FILE:-$(tulan_get_home)/config/dns.servers.cn}"
TULAN_DNS_ENV="${TULAN_DNS_ENV:-$(tulan_get_home)/state/dns.env}"
TULAN_DNS_PRIMARY_COUNT="${TULAN_DNS_PRIMARY_COUNT:-2}"

tulan_dns_require_linux() {
  if [[ "$(uname -s | tr '[:upper:]' '[:lower:]')" != "linux" ]]; then
    tulan_error "DNS 修复目前仅支持 Linux"
    return 1
  fi
}

tulan_dns_default_servers() {
  if [[ -n "${TULAN_DNS_SERVERS:-}" ]]; then
    echo "$TULAN_DNS_SERVERS"
    return 0
  fi

  local servers=() line
  if [[ -f "$TULAN_DNS_SERVERS_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"
      line="${line// /}"
      [[ -n "$line" ]] && servers+=("$line")
    done < "$TULAN_DNS_SERVERS_FILE"
  fi

  if [[ ${#servers[@]} -eq 0 ]]; then
    servers=(223.5.5.5 223.6.6.6 119.29.29.29 1.12.12.12 114.114.114.114 8.8.8.8 1.1.1.1)
  fi
  echo "${servers[*]}"
}

tulan_dns_load_default_servers() {
  local -n _dest=$1
  read -r -a _dest <<< "$(tulan_dns_default_servers)"
}

tulan_dns_probe_servers() {
  local servers=("$@")
  python3 - "${servers[@]}" <<'PY'
import random
import socket
import struct
import sys
import time


def build_query(qname: str) -> bytes:
    tid = random.randint(0, 0xFFFF)
    header = struct.pack("!HHHHHH", tid, 0x0100, 1, 0, 0, 0)
    parts = qname.strip(".").split(".")
    body = b"".join(bytes([len(p)]) + p.encode() for p in parts) + b"\x00"
    body += struct.pack("!HH", 1, 1)
    return header + body


def probe(server: str, timeout: float = 2.0):
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(timeout)
        payload = build_query("www.aliyun.com")
        t0 = time.perf_counter()
        sock.sendto(payload, (server, 53))
        sock.recvfrom(512)
        ms = (time.perf_counter() - t0) * 1000.0
        sock.close()
        return ms
    except OSError:
        return None


results = []
for server in sys.argv[1:]:
    ms = probe(server)
    if ms is not None:
        results.append((ms, server))

results.sort(key=lambda item: item[0])
for ms, server in results:
    print(f"{ms:.2f}\t{server}")
PY
}

tulan_dns_rank_servers() {
  local servers=("$@")
  local probed=() _ ms host

  while IFS=$'\t' read -r ms host; do
    [[ -n "$host" ]] && probed+=("$host")
  done < <(tulan_dns_probe_servers "${servers[@]}")

  if [[ ${#probed[@]} -eq 0 ]]; then
    tulan_error "所有 DNS 服务器均不可达"
    return 1
  fi

  printf '%s\n' "${probed[@]}"
}

tulan_dns_show_probe() {
  local servers=("$@")
  if [[ ${#servers[@]} -eq 0 ]]; then
    tulan_dns_load_default_servers servers
  fi

  tulan_log "探测 DNS 服务器（${#servers[@]} 个，UDP/53）..."
  local count=0
  while IFS=$'\t' read -r ms host; do
    [[ -n "$host" ]] || continue
    printf '  %8.2f ms  %s\n' "$ms" "$host"
    count=$((count + 1))
  done < <(tulan_dns_probe_servers "${servers[@]}")

  if (( count == 0 )); then
    tulan_error "无可用 DNS 响应"
    return 1
  fi
}

tulan_dns_read_resolv_nameservers() {
  local f="${1:-/etc/resolv.conf}"
  [[ -f "$f" ]] || return 1
  awk '/^nameserver[[:space:]]+/ {print $2}' "$f" 2>/dev/null
}

tulan_dns_default_iface() {
  ip -4 route show default 2>/dev/null | awk 'NR==1 {print $5}'
}

tulan_dns_detect_backend() {
  TULAN_DNS_BACKEND=""
  if systemctl is-active systemd-resolved &>/dev/null; then
    TULAN_DNS_BACKEND="systemd-resolved"
  elif command -v nmcli &>/dev/null && systemctl is-active NetworkManager &>/dev/null 2>&1; then
    TULAN_DNS_BACKEND="networkmanager"
  elif compgen -G "/etc/netplan/*.yaml" >/dev/null 2>&1 || compgen -G "/etc/netplan/*.yml" >/dev/null 2>&1; then
    TULAN_DNS_BACKEND="netplan"
  else
    TULAN_DNS_BACKEND="resolv.conf"
  fi
  export TULAN_DNS_BACKEND
}

tulan_dns_resolv_is_broken() {
  local ns broken=false
  while IFS= read -r ns; do
    [[ -z "$ns" ]] && continue
    case "$ns" in
      127.0.0.1|127.0.0.53|[::1]|0.0.0.0)
        broken=true
        ;;
    esac
  done < <(tulan_dns_read_resolv_nameservers 2>/dev/null || true)

  if [[ "$broken" == true ]]; then
    local count
    count="$(tulan_dns_read_resolv_nameservers 2>/dev/null | wc -l | tr -d ' ')"
    [[ "${count:-0}" -le 2 ]]
    return $?
  fi
  return 1
}

tulan_dns_show_status() {
  tulan_dns_require_linux || return 1
  tulan_dns_detect_backend

  echo "DNS 状态"
  echo "────────────────────────────────────"
  echo "  管理后端: ${TULAN_DNS_BACKEND}"
  echo "  默认网卡: $(tulan_dns_default_iface 2>/dev/null || echo 未知)"

  if [[ -L /etc/resolv.conf ]]; then
    echo "  resolv.conf: 符号链接 → $(readlink -f /etc/resolv.conf 2>/dev/null || readlink /etc/resolv.conf)"
  else
    echo "  resolv.conf: 普通文件"
  fi

  echo "  当前 nameserver:"
  local ns
  local any=false
  while IFS= read -r ns; do
    [[ -z "$ns" ]] && continue
    any=true
    case "$ns" in
      127.0.0.1|127.0.0.53|[::1])
        echo "    ! ${ns}  （本地 stub，若无法解析需修复）"
        ;;
      *)
        echo "    ${ns}"
        ;;
    esac
  done < <(tulan_dns_read_resolv_nameservers 2>/dev/null || true)
  [[ "$any" == false ]] && echo "    (无)"

  if command -v resolvectl &>/dev/null && systemctl is-active systemd-resolved &>/dev/null; then
    echo ""
    echo "  resolvectl status（摘要）:"
    resolvectl status 2>/dev/null | sed -n '1,20p' | sed 's/^/    /' || true
  fi

  if [[ -f "$TULAN_DNS_ENV" ]]; then
    echo ""
    echo "  上次修复记录: ${TULAN_DNS_ENV}"
    sed 's/^/    /' "$TULAN_DNS_ENV"
  fi

  if tulan_dns_resolv_is_broken; then
    echo ""
    echo "  诊断: 检测到异常本地 DNS（如 [::1] / 127.0.0.53 且无有效上游），建议 brew dns fix"
  fi
}

tulan_dns_write_env() {
  local primary="$1"
  local backend="$2"
  mkdir -p "$(dirname "$TULAN_DNS_ENV")"
  cat > "$TULAN_DNS_ENV" <<EOF
# brew dns fix 写入
UPDATED_AT=$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')
BACKEND=${backend}
DNS_SERVERS=${primary}
EOF
}

tulan_dns_apply_systemd_resolved() {
  local -a servers=("$@")
  local dropin_dir="/etc/systemd/resolved.conf.d"
  local dropin="${dropin_dir}/tulan-dns.conf"
  local iface

  mkdir -p "$dropin_dir"
  cat > "$dropin" <<EOF
# 由 brew dns fix 写入
[Resolve]
DNS=${servers[*]}
FallbackDNS=${servers[2]:-114.114.114.114} ${servers[3]:-1.1.1.1}
DNSStubListener=yes
EOF
  tulan_log "已写入 ${dropin}"

  systemctl restart systemd-resolved
  iface="$(tulan_dns_default_iface || true)"
  if [[ -n "$iface" ]] && command -v resolvectl &>/dev/null; then
    resolvectl dns "$iface" "${servers[@]}"
    resolvectl domain "$iface" "~."
  fi
}

tulan_dns_apply_networkmanager() {
  local -a servers=("$@")
  local conn device
  device="$(tulan_dns_default_iface || true)"
  conn="$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | awk -F: -v dev="$device" '$2==dev {print $1; exit}')"
  [[ -z "$conn" ]] && conn="$(nmcli -t -f NAME con show --active 2>/dev/null | head -n1)"
  [[ -n "$conn" ]] || { tulan_error "未找到 NetworkManager 活动连接"; return 1; }

  tulan_log "NetworkManager 连接: ${conn}"
  nmcli con mod "$conn" ipv4.dns "${servers[*]}"
  nmcli con mod "$conn" ipv4.ignore-auto-dns yes
  nmcli con mod "$conn" ipv6.dns "${servers[*]}"
  nmcli con mod "$conn" ipv6.ignore-auto-dns yes
  nmcli con up "$conn"
}

tulan_dns_apply_resolv_conf() {
  local -a servers=("$@")
  local f="/etc/resolv.conf"
  local backup ts

  if lsattr "$f" 2>/dev/null | grep -q '\si'; then
    tulan_error "${f} 被 chattr +i 保护，请先: chattr -i ${f}"
    return 1
  fi

  if [[ -L "$f" ]]; then
    tulan_log "${f} 为符号链接，尝试改用 systemd-resolved"
    if systemctl is-enabled systemd-resolved &>/dev/null; then
      systemctl start systemd-resolved 2>/dev/null || true
      tulan_dns_apply_systemd_resolved "${servers[@]}"
      return 0
    fi
    rm -f "$f"
  fi

  ts="$(date +%Y%m%d%H%M%S)"
  backup="${f}.bak.${ts}"
  cp -a "$f" "$backup" 2>/dev/null || true
  {
    echo "# 由 brew dns fix 写入 $(date -Iseconds 2>/dev/null || date)"
    local s
    for s in "${servers[@]}"; do
      echo "nameserver ${s}"
    done
    echo "options timeout:2 attempts:2 rotate"
  } > "$f"
}

tulan_dns_apply_netplan() {
  local -a servers=("$@")
  tulan_log "检测到 netplan，优先尝试 NetworkManager / systemd-resolved"
  if systemctl is-active NetworkManager &>/dev/null 2>&1 && command -v nmcli &>/dev/null; then
    tulan_dns_apply_networkmanager "${servers[@]}"
    return 0
  fi
  if systemctl is-active systemd-resolved &>/dev/null; then
    tulan_dns_apply_systemd_resolved "${servers[@]}"
    return 0
  fi
  tulan_dns_apply_resolv_conf "${servers[@]}"
}

tulan_dns_verify() {
  local target="${1:-www.aliyun.com}"
  tulan_log "验证解析 ${target} ..."
  if command -v getent &>/dev/null; then
    getent hosts "$target" >/dev/null && { tulan_log "getent hosts ${target} OK"; return 0; }
  fi
  if command -v python3 &>/dev/null; then
    python3 - "$target" <<'PY'
import socket, sys
socket.getaddrinfo(sys.argv[1], 443)
print("OK")
PY
    return 0
  fi
  tulan_log "无法自动验证（缺少 getent/python3）"
  return 0
}

tulan_dns_fix() {
  local skip_probe="${1:-false}"
  local -a custom=() ranked=() primary=() servers=()

  tulan_dns_require_linux || return 1
  tulan_require_privilege || return 1

  if [[ ${#TULAN_DNS_CUSTOM_SERVERS[@]} -gt 0 ]]; then
    servers=("${TULAN_DNS_CUSTOM_SERVERS[@]}")
  else
    tulan_dns_load_default_servers servers
  fi

  if [[ "$skip_probe" == true ]]; then
    ranked=("${servers[@]}")
  else
    tulan_log "测速选择最快 DNS..."
    mapfile -t ranked < <(tulan_dns_rank_servers "${servers[@]}")
  fi

  primary=("${ranked[@]:0:TULAN_DNS_PRIMARY_COUNT}")
  tulan_log "将使用: ${primary[*]}"

  tulan_dns_detect_backend
  tulan_log "配置后端: ${TULAN_DNS_BACKEND}"

  case "$TULAN_DNS_BACKEND" in
    systemd-resolved) tulan_dns_apply_systemd_resolved "${primary[@]}" ;;
    networkmanager) tulan_dns_apply_networkmanager "${primary[@]}" ;;
    netplan) tulan_dns_apply_netplan "${primary[@]}" ;;
    *) tulan_dns_apply_resolv_conf "${primary[@]}" ;;
  esac

  tulan_dns_write_env "${primary[*]}" "$TULAN_DNS_BACKEND"
  tulan_dns_verify www.aliyun.com || tulan_log "验证未通过，请检查网络或手动 nslookup"
  tulan_log "DNS 已修复（${TULAN_DNS_BACKEND}）"
  tulan_dns_show_status
}
