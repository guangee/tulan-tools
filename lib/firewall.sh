#!/usr/bin/env bash
# Linux 防火墙（ufw / firewalld）端口管理

set -euo pipefail

TULAN_FIREWALL_STATE_FILE="${TULAN_FIREWALL_STATE_FILE:-$(tulan_get_home)/state/firewall.json}"

tulan_firewall_require_linux() {
  if [[ "$(uname -s | tr '[:upper:]' '[:lower:]')" != "linux" ]]; then
    tulan_error "防火墙配置目前仅支持 Linux"
    return 1
  fi
}

tulan_firewall_detect_backend() {
  if command -v firewall-cmd &>/dev/null; then
    if tulan_as_root firewall-cmd --state &>/dev/null 2>&1; then
      echo "firewalld"
      return 0
    fi
    if systemctl is-enabled firewalld &>/dev/null 2>&1 \
      || systemctl is-active firewalld &>/dev/null 2>&1; then
      echo "firewalld"
      return 0
    fi
  fi
  if command -v ufw &>/dev/null; then
    echo "ufw"
    return 0
  fi
  echo "none"
}

tulan_firewall_parse_port_spec() {
  local spec="$1" port proto
  if [[ "$spec" =~ ^([0-9]+)/(tcp|udp)$ ]]; then
    port="${BASH_REMATCH[1]}"
    proto="${BASH_REMATCH[2]}"
  elif [[ "$spec" =~ ^[0-9]+$ ]]; then
    port="$spec"
    proto="tcp"
  else
    tulan_error "无效端口格式: ${spec}（示例: 8080 或 8080/tcp）"
    return 1
  fi
  if (( port < 1 || port > 65535 )); then
    tulan_error "端口超出范围: ${port}"
    return 1
  fi
  echo "${port}/${proto}"
}

tulan_firewall_save_state() {
  local backend="$1" disabled="$2" action="${3:-}" port_spec="${4:-}"
  mkdir -p "$(dirname "$TULAN_FIREWALL_STATE_FILE")"
  python3 - "$backend" "$disabled" "$action" "$port_spec" "$TULAN_FIREWALL_STATE_FILE" <<'PY'
import json, sys, time
from pathlib import Path

backend, disabled, action, port_spec, path = sys.argv[1:6]
p = Path(path)
data = json.loads(p.read_text()) if p.exists() else {
    "backend": backend,
    "disabled": False,
    "ports": [],
    "updated_at": "",
}

data["backend"] = backend
data["disabled"] = disabled == "true"
data["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

if action == "open" and port_spec:
    port, proto = port_spec.split("/", 1)
    entry = {"port": int(port), "proto": proto}
    ports = [x for x in data.get("ports", []) if not (x["port"] == entry["port"] and x["proto"] == entry["proto"])]
    ports.append(entry)
    data["ports"] = sorted(ports, key=lambda x: (x["port"], x["proto"]))
elif action == "close" and port_spec:
    port, proto = port_spec.split("/", 1)
    data["ports"] = [
        x for x in data.get("ports", [])
        if not (x["port"] == int(port) and x["proto"] == proto)
    ]
elif action == "disable":
    data["disabled"] = True
elif action == "enable":
    data["disabled"] = False

p.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY
}

tulan_firewall_open_port() {
  local port_spec="$1" backend port proto
  port_spec="$(tulan_firewall_parse_port_spec "$port_spec")" || return 1
  port="${port_spec%/*}"
  proto="${port_spec#*/}"
  backend="$(tulan_firewall_detect_backend)"

  tulan_firewall_require_linux || return 1
  tulan_require_privilege || return 1

  case "$backend" in
    ufw)
      tulan_log "ufw 开放 ${port_spec}"
      tulan_as_root ufw allow "${port}/${proto}"
      tulan_as_root ufw status numbered 2>/dev/null | grep -E "${port}/${proto}" || true
      ;;
    firewalld)
      tulan_log "firewalld 开放 ${port_spec}"
      tulan_as_root firewall-cmd --permanent --add-port="${port}/${proto}"
      tulan_as_root firewall-cmd --reload
      ;;
    none)
      tulan_error "未检测到 ufw 或 firewalld，无法自动开放端口"
      return 1
      ;;
  esac

  tulan_firewall_save_state "$backend" false open "$port_spec"
}

tulan_firewall_close_port() {
  local port_spec="$1" backend port proto
  port_spec="$(tulan_firewall_parse_port_spec "$port_spec")" || return 1
  port="${port_spec%/*}"
  proto="${port_spec#*/}"
  backend="$(tulan_firewall_detect_backend)"

  tulan_firewall_require_linux || return 1
  tulan_require_privilege || return 1

  case "$backend" in
    ufw)
      tulan_log "ufw 关闭 ${port_spec}"
      while tulan_as_root ufw status numbered 2>/dev/null | grep -qE "${port}/${proto}"; do
        local rule_num
        rule_num="$(tulan_as_root ufw status numbered 2>/dev/null | grep -E "${port}/${proto}" | head -1 | sed -n 's/^\[[[:space:]]*\([0-9]\+\)\].*/\1/p')"
        [[ -n "$rule_num" ]] || break
        tulan_as_root ufw --force delete "$rule_num"
      done
      ;;
    firewalld)
      tulan_log "firewalld 关闭 ${port_spec}"
      tulan_as_root firewall-cmd --permanent --remove-port="${port}/${proto}" 2>/dev/null || true
      tulan_as_root firewall-cmd --reload
      ;;
    none)
      tulan_error "未检测到 ufw 或 firewalld"
      return 1
      ;;
  esac

  tulan_firewall_save_state "$backend" false close "$port_spec"
}

tulan_firewall_disable_all() {
  local backend
  backend="$(tulan_firewall_detect_backend)"

  tulan_firewall_require_linux || return 1
  tulan_require_privilege || return 1

  case "$backend" in
    ufw)
      tulan_log "关闭 ufw 防火墙"
      tulan_as_root ufw --force disable
      ;;
    firewalld)
      tulan_log "停止并禁用 firewalld"
      tulan_as_root systemctl stop firewalld 2>/dev/null || true
      tulan_as_root systemctl disable firewalld 2>/dev/null || true
      ;;
    none)
      tulan_log "未检测到 ufw / firewalld，无可关闭的防火墙服务"
      return 0
      ;;
  esac

  tulan_firewall_save_state "$backend" true disable
}

tulan_firewall_enable_all() {
  local backend
  backend="$(tulan_firewall_detect_backend)"

  tulan_firewall_require_linux || return 1
  tulan_require_privilege || return 1

  case "$backend" in
    ufw)
      tulan_log "启用 ufw 防火墙"
      tulan_as_root ufw --force enable
      ;;
    firewalld)
      tulan_log "启用 firewalld"
      tulan_as_root systemctl enable firewalld 2>/dev/null || true
      tulan_as_root systemctl start firewalld 2>/dev/null || true
      ;;
    none)
      tulan_error "未检测到 ufw 或 firewalld"
      return 1
      ;;
  esac

  tulan_firewall_save_state "$backend" false enable
}

tulan_firewall_restart_docker() {
  if command -v systemctl &>/dev/null \
    && systemctl list-unit-files 2>/dev/null | grep -q '^docker\.service'; then
    tulan_log "重启 docker 服务"
    tulan_as_root systemctl restart docker
    return 0
  fi
  if command -v docker &>/dev/null && pgrep dockerd >/dev/null 2>&1; then
    tulan_log "重启 dockerd 进程"
    tulan_as_root pkill dockerd 2>/dev/null || true
    sleep 2
    if command -v dockerd &>/dev/null; then
      tulan_log "请手动执行: sudo dockerd &"
    fi
    return 0
  fi
  tulan_log "未检测到运行中的 Docker，跳过重启"
}

tulan_firewall_show_status() {
  local backend
  backend="$(tulan_firewall_detect_backend)"

  echo "防火墙状态"
  echo "────────────────────────────────────"
  echo "  后端:       ${backend}"

  case "$backend" in
    ufw)
      echo "  ufw 状态:"
      if tulan_can_privilege; then
        tulan_as_root ufw status verbose 2>/dev/null | sed 's/^/    /' || echo "    (无法读取)"
      else
        echo "    (需要 sudo 查看详情)"
      fi
      ;;
    firewalld)
      echo "  firewalld:"
      if tulan_can_privilege; then
        tulan_as_root firewall-cmd --state 2>/dev/null | sed 's/^/    状态: /' || echo "    状态: 未知"
        echo "    开放端口:"
        tulan_as_root firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | sed 's/^/      /' || true
      else
        echo "    (需要 sudo 查看详情)"
      fi
      ;;
    none)
      echo "  未检测到 ufw / firewalld"
      ;;
  esac

  if [[ -f "$TULAN_FIREWALL_STATE_FILE" ]]; then
    echo ""
    python3 - "$TULAN_FIREWALL_STATE_FILE" <<'PY'
import json, sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
print("  tulan-tools 记录:")
print(f"    防火墙已关闭: {'是' if data.get('disabled') else '否'}")
ports = data.get("ports") or []
if ports:
    text = ", ".join(f"{p['port']}/{p['proto']}" for p in ports)
    print(f"    已开放端口: {text}")
else:
    print("    已开放端口: (无记录)")
print(f"    更新时间: {data.get('updated_at', '-')}")
PY
  fi
}
