#!/usr/bin/env bash
# Linux 防火墙（firewalld / ufw / iptables / nftables）

set -euo pipefail

TULAN_FIREWALL_STATE_FILE="${TULAN_FIREWALL_STATE_FILE:-$(tulan_get_home)/state/firewall.json}"
TULAN_IPTABLES_CHAIN="${TULAN_IPTABLES_CHAIN:-TULAN-ALLOW}"
TULAN_NFT_TABLE="${TULAN_NFT_TABLE:-tulan_tools}"
TULAN_NFT_CHAIN="${TULAN_NFT_CHAIN:-input}"

tulan_firewall_require_linux() {
  if [[ "$(uname -s | tr '[:upper:]' '[:lower:]')" != "linux" ]]; then
    tulan_error "防火墙配置目前仅支持 Linux"
    return 1
  fi
}

tulan_firewall_has_firewalld() {
  command -v firewall-cmd &>/dev/null
}

tulan_firewall_firewalld_active() {
  tulan_firewall_has_firewalld || return 1
  tulan_as_root firewall-cmd --state 2>/dev/null | grep -qi running
}

tulan_firewall_has_ufw() {
  command -v ufw &>/dev/null
}

tulan_firewall_ufw_active() {
  tulan_firewall_has_ufw || return 1
  tulan_as_root ufw status 2>/dev/null | grep -qiE 'Status:[[:space:]]*active'
}

tulan_firewall_has_iptables() {
  command -v iptables &>/dev/null
}

tulan_firewall_has_ip6tables() {
  command -v ip6tables &>/dev/null
}

tulan_firewall_has_nft() {
  command -v nft &>/dev/null
}

tulan_firewall_nft_in_use() {
  tulan_firewall_has_nft || return 1
  local ruleset
  ruleset="$(tulan_as_root nft list ruleset 2>/dev/null | grep -v '^$' || true)"
  [[ -n "$ruleset" ]]
}

tulan_firewall_list_backends() {
  if tulan_firewall_firewalld_active; then
    echo firewalld
  fi
  if tulan_firewall_ufw_active; then
    echo ufw
  fi
  if tulan_firewall_has_iptables; then
    echo iptables
  fi
  if tulan_firewall_has_nft; then
    echo nftables
  fi
}

tulan_firewall_primary_backend() {
  if tulan_firewall_firewalld_active; then
    echo firewalld
    return 0
  fi
  if tulan_firewall_ufw_active; then
    echo ufw
    return 0
  fi
  if tulan_firewall_has_iptables; then
    echo iptables
    return 0
  fi
  if tulan_firewall_has_nft; then
    echo nftables
    return 0
  fi
  if tulan_firewall_has_ufw; then
    echo ufw
    return 0
  fi
  if tulan_firewall_has_firewalld; then
    echo firewalld
    return 0
  fi
  echo none
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

tulan_firewall_iptables_open() {
  local port="$1" proto="$2" cmd chain comment
  chain="$TULAN_IPTABLES_CHAIN"
  comment="tulan-tools-${port}-${proto}"

  for cmd in iptables ip6tables; do
    command -v "$cmd" &>/dev/null || continue
    tulan_as_root "$cmd" -N "$chain" 2>/dev/null || true
    tulan_as_root "$cmd" -C INPUT -j "$chain" 2>/dev/null \
      || tulan_as_root "$cmd" -I INPUT 1 -j "$chain"
    if tulan_as_root "$cmd" -C "$chain" -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; then
      continue
    fi
    tulan_as_root "$cmd" -A "$chain" -p "$proto" --dport "$port" \
      -m comment --comment "$comment" -j ACCEPT
  done
}

tulan_firewall_iptables_close() {
  local port="$1" proto="$2" cmd chain
  chain="$TULAN_IPTABLES_CHAIN"

  for cmd in iptables ip6tables; do
    command -v "$cmd" &>/dev/null || continue
    while tulan_as_root "$cmd" -C "$chain" -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null; do
      tulan_as_root "$cmd" -D "$chain" -p "$proto" --dport "$port" -j ACCEPT
    done
  done
}

tulan_firewall_iptables_disable() {
  local cmd tbl chain
  for cmd in iptables ip6tables; do
    command -v "$cmd" &>/dev/null || continue
    tulan_log "${cmd}: 清空规则并设为 ACCEPT"
    for tbl in filter nat mangle raw; do
      tulan_as_root "$cmd" -t "$tbl" -F 2>/dev/null || true
      tulan_as_root "$cmd" -t "$tbl" -X 2>/dev/null || true
    done
    tulan_as_root "$cmd" -P INPUT ACCEPT 2>/dev/null || true
    tulan_as_root "$cmd" -P FORWARD ACCEPT 2>/dev/null || true
    tulan_as_root "$cmd" -P OUTPUT ACCEPT 2>/dev/null || true
  done
}

tulan_firewall_nft_ensure_chain() {
  tulan_as_root nft list table "inet ${TULAN_NFT_TABLE}" &>/dev/null \
    || tulan_as_root nft add table "inet ${TULAN_NFT_TABLE}"
  tulan_as_root nft list chain "inet ${TULAN_NFT_TABLE}" "${TULAN_NFT_CHAIN}" &>/dev/null \
    || tulan_as_root nft add chain "inet ${TULAN_NFT_TABLE}" "${TULAN_NFT_CHAIN}" \
      '{ type filter hook input priority 0; policy accept; }'
}

tulan_firewall_nft_open() {
  local port="$1" proto="$2" handle
  tulan_firewall_nft_ensure_chain
  if tulan_as_root nft list chain "inet ${TULAN_NFT_TABLE}" "${TULAN_NFT_CHAIN}" 2>/dev/null \
    | grep -q "tulan-tools-${port}-${proto}"; then
    return 0
  fi
  tulan_as_root nft add rule "inet ${TULAN_NFT_TABLE}" "${TULAN_NFT_CHAIN}" \
    "$proto" dport "$port" accept comment "\"tulan-tools-${port}-${proto}\""
}

tulan_firewall_nft_close() {
  local port="$1" proto="$2" handle
  tulan_as_root nft list chain "inet ${TULAN_NFT_TABLE}" "${TULAN_NFT_CHAIN}" -a 2>/dev/null \
    | grep "tulan-tools-${port}-${proto}" | awk '{print $NF}' | while read -r handle; do
      [[ -n "$handle" ]] || continue
      tulan_as_root nft delete rule "inet ${TULAN_NFT_TABLE}" "${TULAN_NFT_CHAIN}" handle "$handle" 2>/dev/null || true
    done
}

tulan_firewall_nft_disable() {
  tulan_firewall_has_nft || return 0
  tulan_log "nftables: 清空 tulan_tools 表"
  tulan_as_root nft delete table "inet ${TULAN_NFT_TABLE}" 2>/dev/null || true
  if tulan_firewall_nft_in_use; then
    tulan_log "nftables: flush ruleset（系统存在 nft 规则）"
    tulan_as_root nft flush ruleset 2>/dev/null || true
  fi
}

tulan_firewall_open_port() {
  local port_spec="$1" backend port proto
  port_spec="$(tulan_firewall_parse_port_spec "$port_spec")" || return 1
  port="${port_spec%/*}"
  proto="${port_spec#*/}"
  backend="$(tulan_firewall_primary_backend)"

  tulan_firewall_require_linux || return 1
  tulan_require_privilege || return 1

  case "$backend" in
    ufw)
      tulan_log "ufw 开放 ${port_spec}"
      tulan_as_root ufw allow "${port}/${proto}"
      ;;
    firewalld)
      tulan_log "firewalld 开放 ${port_spec}"
      tulan_as_root firewall-cmd --permanent --add-port="${port}/${proto}"
      tulan_as_root firewall-cmd --reload
      ;;
    iptables)
      tulan_log "iptables 开放 ${port_spec}"
      tulan_firewall_iptables_open "$port" "$proto"
      ;;
    nftables)
      tulan_log "nftables 开放 ${port_spec}"
      tulan_firewall_nft_open "$port" "$proto"
      ;;
    none)
      if tulan_firewall_has_iptables; then
        tulan_log "iptables 开放 ${port_spec}"
        tulan_firewall_iptables_open "$port" "$proto"
        backend=iptables
      elif tulan_firewall_has_nft; then
        tulan_log "nftables 开放 ${port_spec}"
        tulan_firewall_nft_open "$port" "$proto"
        backend=nftables
      else
        tulan_error "未检测到可用的防火墙工具（ufw / firewalld / iptables / nft）"
        return 1
      fi
      ;;
  esac

  tulan_firewall_save_state "$backend" false open "$port_spec"
}

tulan_firewall_close_port() {
  local port_spec="$1" backend port proto
  port_spec="$(tulan_firewall_parse_port_spec "$port_spec")" || return 1
  port="${port_spec%/*}"
  proto="${port_spec#*/}"
  backend="$(tulan_firewall_primary_backend)"

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
    iptables)
      tulan_log "iptables 关闭 ${port_spec}"
      tulan_firewall_iptables_close "$port" "$proto"
      ;;
    nftables)
      tulan_log "nftables 关闭 ${port_spec}"
      tulan_firewall_nft_close "$port" "$proto"
      ;;
    none)
      tulan_firewall_iptables_close "$port" "$proto" 2>/dev/null || true
      tulan_firewall_nft_close "$port" "$proto" 2>/dev/null || true
      backend=iptables
      ;;
  esac

  tulan_firewall_save_state "$backend" false close "$port_spec"
}

tulan_firewall_disable_all() {
  local disabled_any=false

  tulan_firewall_require_linux || return 1
  tulan_require_privilege || return 1

  if tulan_firewall_has_firewalld; then
    if tulan_firewall_firewalld_active || systemctl is-enabled firewalld &>/dev/null 2>&1; then
      tulan_log "停止并禁用 firewalld"
      tulan_as_root systemctl stop firewalld 2>/dev/null || true
      tulan_as_root systemctl disable firewalld 2>/dev/null || true
      disabled_any=true
    fi
  fi

  if tulan_firewall_has_ufw; then
    if tulan_firewall_ufw_active || tulan_as_root ufw status 2>/dev/null | grep -qi installed; then
      tulan_log "关闭 ufw"
      tulan_as_root ufw --force disable 2>/dev/null || true
      disabled_any=true
    fi
  fi

  if tulan_firewall_has_iptables; then
    tulan_firewall_iptables_disable
    disabled_any=true
  fi

  if tulan_firewall_has_nft; then
    tulan_firewall_nft_disable
    disabled_any=true
  fi

  if [[ "$disabled_any" == false ]]; then
    tulan_log "未检测到可关闭的防火墙组件"
  fi

  tulan_firewall_save_state "$(tulan_firewall_primary_backend)" true disable
}

tulan_firewall_enable_all() {
  local backend os
  backend="$(tulan_firewall_primary_backend)"
  os="$(tulan_detect_os 2>/dev/null || echo unknown)"

  tulan_firewall_require_linux || return 1
  tulan_require_privilege || return 1

  if tulan_firewall_has_firewalld && [[ "$backend" == firewalld || "$os" == centos ]]; then
    tulan_log "启用 firewalld"
    tulan_as_root systemctl enable firewalld 2>/dev/null || true
    tulan_as_root systemctl start firewalld 2>/dev/null || true
    backend=firewalld
  elif tulan_firewall_has_ufw; then
    tulan_log "启用 ufw"
    tulan_as_root ufw --force enable
    backend=ufw
  else
    tulan_error "未检测到 ufw 或 firewalld，无法自动启用"
    tulan_log "iptables/nftables 需手动恢复策略与规则"
    return 1
  fi

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
    tulan_log "请手动执行: sudo dockerd &"
    return 0
  fi
  tulan_log "未检测到运行中的 Docker，跳过重启"
}

tulan_firewall_show_component_status() {
  local os
  os="$(tulan_detect_os 2>/dev/null || echo unknown)"
  echo "  系统:       ${os} ($(tulan_detect_pkg_manager 2>/dev/null || echo unknown))"

  echo "  firewalld:  $(if tulan_firewall_has_firewalld; then if tulan_firewall_firewalld_active; then echo "已安装 (运行中)"; else echo "已安装 (未运行)"; fi; else echo "未安装"; fi)"

  if tulan_firewall_has_ufw; then
    if tulan_can_privilege; then
      echo "  ufw:        $(tulan_as_root ufw status 2>/dev/null | head -1 || echo "未知")"
    else
      echo "  ufw:        已安装 (需要 sudo 查看状态)"
    fi
  else
    echo "  ufw:        未安装"
  fi

  echo "  iptables:   $(tulan_firewall_has_iptables && echo "可用" || echo "不可用")"
  echo "  nftables:   $(tulan_firewall_has_nft && echo "可用" || echo "不可用")"

  if tulan_can_privilege && tulan_firewall_has_iptables; then
    echo "  iptables INPUT 策略: $(tulan_as_root iptables -L INPUT -n 2>/dev/null | head -1 || echo "-")"
    echo "  tulan 链 (${TULAN_IPTABLES_CHAIN}):"
    tulan_as_root iptables -L "$TULAN_IPTABLES_CHAIN" -n --line-numbers 2>/dev/null | sed 's/^/    /' \
      || echo "    (无)"
  fi

  if tulan_can_privilege && tulan_firewall_has_nft; then
    echo "  nft tulan_tools:"
    tulan_as_root nft list table "inet ${TULAN_NFT_TABLE}" 2>/dev/null | sed 's/^/    /' \
      || echo "    (无)"
  fi
}

tulan_firewall_show_status() {
  local backend backends=()
  backend="$(tulan_firewall_primary_backend)"
  mapfile -t backends < <(tulan_firewall_list_backends | awk '!seen[$0]++')

  echo "防火墙状态"
  echo "────────────────────────────────────"
  echo "  当前后端:   ${backend}"
  if [[ ${#backends[@]} -gt 0 ]]; then
    echo "  可用后端:   ${backends[*]}"
  fi
  echo ""

  tulan_firewall_show_component_status

  case "$backend" in
    firewalld)
      if tulan_can_privilege; then
        echo ""
        echo "  firewalld 端口:"
        tulan_as_root firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | sed 's/^/    /' || true
      fi
      ;;
    ufw)
      if tulan_can_privilege; then
        echo ""
        echo "  ufw 规则:"
        tulan_as_root ufw status numbered 2>/dev/null | sed 's/^/    /' || true
      fi
      ;;
  esac

  if [[ -f "$TULAN_FIREWALL_STATE_FILE" ]]; then
    echo ""
    python3 - "$TULAN_FIREWALL_STATE_FILE" <<'PY'
import json, sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
print("  tulan-tools 记录:")
print(f"    最近后端: {data.get('backend', '-')}")
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
