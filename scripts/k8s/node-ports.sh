#!/usr/bin/env bash
# Rancher / RKE2 节点端口连通性排查（worker → master、本机监听、防火墙线索）
#
# 用法:
#   brew k8s node-ports
#   brew k8s node-ports --host 10.0.0.12
#   brew k8s node-ports --timeout 5

set -euo pipefail

NODE_PORTS_HOST="${NODE_PORTS_HOST:-}"
NODE_PORTS_TIMEOUT="${NODE_PORTS_TIMEOUT:-3}"

section() {
  echo ""
  echo "$1"
  echo "────────────────────────────────────"
}

note() {
  printf '  %s\n' "$*"
}

ok() {
  note "✓ $*"
}

warn() {
  note "! $*"
}

fail() {
  note "✗ $*"
}

have_cmd() {
  command -v "$1" &>/dev/null
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host)
        NODE_PORTS_HOST="${2:-}"
        shift 2
        ;;
      --timeout)
        NODE_PORTS_TIMEOUT="${2:-3}"
        shift 2
        ;;
      -h|--help)
        cat <<'EOF'
用法: brew k8s node-ports [选项]

在 Rancher 管理的 Linux 节点上检查 RKE2/k3s 关键端口:
  - 本机是否在监听 6443 / 9345（master）
  - 到 control plane 的 TCP 连通性（worker → server）
  - 到 Rancher Server 的 HTTPS 连通性
  - 主机防火墙线索（ufw / firewalld / iptables）

选项:
  --host <ip>       指定 control plane 地址（默认从 rke2/k3s/agent 配置读取）
  --timeout <秒>    TCP 探测超时（默认 3）
  -h, --help        显示帮助

示例:
  brew k8s node-ports
  brew k8s node-ports --host 10.0.0.12
  brew k8s node-ports --timeout 5

常见根因（端口不通时）:
  1. 云安全组 / VPC 网络 ACL 未放行 6443、9345
  2. 主机防火墙 ufw / firewalld / iptables
  3. control plane 服务未运行（rke2-server / k3s）
  4. server 配置地址错误（用了不可达 IP 或外网域名）
EOF
        exit 0
        ;;
      *)
        echo "未知参数: $1（brew k8s node-ports -h 查看帮助）" >&2
        exit 1
        ;;
    esac
  done
}

read_yaml_value() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  grep -E "^[[:space:]]*${key}:" "$file" 2>/dev/null | head -n1 \
    | sed -E "s/^[[:space:]]*${key}:[[:space:]]*//" | tr -d "'\""
}

strip_url_host() {
  local raw="$1" host port
  raw="${raw#https://}"
  raw="${raw#http://}"
  raw="${raw%%/*}"
  host="${raw%%:*}"
  port="${raw##*:}"
  [[ "$port" == "$host" ]] && port=""
  printf '%s\n%s\n' "$host" "$port"
}

detect_role() {
  if systemctl cat rke2-server.service &>/dev/null 2>&1 \
    || systemctl cat k3s.service &>/dev/null 2>&1; then
    echo "master"
    return 0
  fi
  if systemctl cat rke2-agent.service &>/dev/null 2>&1 \
    || systemctl cat k3s-agent.service &>/dev/null 2>&1; then
    echo "worker"
    return 0
  fi
  echo "unknown"
}

detect_control_plane_host() {
  local f server host

  if [[ -n "$NODE_PORTS_HOST" ]]; then
    echo "$NODE_PORTS_HOST"
    return 0
  fi

  shopt -s nullglob
  local files=(/etc/rancher/rke2/config.yaml /etc/rancher/rke2/config.yaml.d/*.yaml)
  shopt -u nullglob
  for f in "${files[@]}"; do
    server="$(read_yaml_value "$f" "server" || true)"
    [[ -n "$server" ]] || continue
    host="$(strip_url_host "$server" | head -n1)"
    [[ -n "$host" ]] && { echo "$host"; return 0; }
  done

  for f in /etc/rancher/k3s/config.yaml; do
    server="$(read_yaml_value "$f" "server" || true)"
    [[ -n "$server" ]] || continue
    host="$(strip_url_host "$server" | head -n1)"
    [[ -n "$host" ]] && { echo "$host"; return 0; }
  done

  return 1
}

detect_rancher_server_host() {
  local f server host
  for f in /etc/rancher/agent/config.yaml /etc/rancher/agent/config; do
    server="$(read_yaml_value "$f" "server" || read_yaml_value "$f" "url" || true)"
    [[ -n "$server" ]] || continue
    host="$(strip_url_host "$server" | head -n1)"
    [[ -n "$host" ]] && { echo "$host"; return 0; }
  done
  return 1
}

tcp_probe() {
  local host="$1" port="$2" timeout="${3:-$NODE_PORTS_TIMEOUT}"
  if have_cmd nc; then
    nc -z -w "$timeout" "$host" "$port" 2>/dev/null
    return $?
  fi
  timeout "$timeout" bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null
}

ping_probe() {
  local host="$1"
  if ! have_cmd ping; then
    return 2
  fi
  ping -c 1 -W "${NODE_PORTS_TIMEOUT}" "$host" &>/dev/null
}

local_listen_check() {
  local port="$1" line
  if ! have_cmd ss; then
    warn "未安装 ss，跳过本机监听检查"
    return 2
  fi
  line="$(ss -lnt "sport = :${port}" 2>/dev/null | tail -n +2 | head -n1 || true)"
  if [[ -n "$line" ]]; then
    ok "本机监听 :${port}"
    return 0
  fi
  fail "本机未监听 :${port}"
  return 1
}

probe_remote_port() {
  local host="$1" port="$2" label="$3" rc=0
  if tcp_probe "$host" "$port"; then
    ok "${label} ${host}:${port} TCP 可达"
    return 0
  fi
  fail "${label} ${host}:${port} TCP 不可达（超时/拒绝）"
  return 1
}

show_local_listeners() {
  section "本机监听（control plane）"
  local any_fail=0
  local_listen_check 9345 || any_fail=1
  local_listen_check 6443 || any_fail=1
  if have_cmd ss; then
    note "详情:"
    ss -lntp 2>/dev/null | grep -E ':6443|:9345' | sed 's/^/    /' || note "    (无 6443/9345 监听)"
  fi
  return "$any_fail"
}

show_remote_probes() {
  local host="$1" any_fail=0 ping_ok=0
  section "到 control plane 的连通性（${host}）"

  if ping_probe "$host"; then
    ok "ICMP ping ${host} 可达"
    ping_ok=1
  else
    warn "ICMP ping ${host} 不可达（部分云环境禁 ping，不一定代表 TCP 不通）"
  fi

  probe_remote_port "$host" 9345 "RKE2 supervisor" || any_fail=1
  probe_remote_port "$host" 6443 "Kubernetes API" || any_fail=1
  probe_remote_port "$host" 10250 "kubelet" || warn "kubelet 10250 不可达（部分集群可忽略）"

  if [[ "$ping_ok" -eq 1 && "$any_fail" -eq 1 ]]; then
    warn "ping 通但 TCP 端口不通 → 优先查云安全组 / 主机防火墙，而非路由问题"
  fi
  return "$any_fail"
}

show_rancher_server_probe() {
  local host port any_fail=0
  host="$(detect_rancher_server_host || true)"
  [[ -n "$host" ]] || return 0

  section "到 Rancher Server 的连通性"
  port="$(strip_url_host "$(read_yaml_value /etc/rancher/agent/config.yaml server 2>/dev/null || true)" | tail -n1)"
  [[ -n "$port" ]] || port="443"

  if probe_remote_port "$host" "$port" "Rancher HTTPS"; then
    if have_cmd curl; then
      local code
      code="$(curl -sS -o /dev/null -w '%{http_code}' -k --connect-timeout "$NODE_PORTS_TIMEOUT" \
        --max-time "$((NODE_PORTS_TIMEOUT * 2))" "https://${host}:${port}/" 2>/dev/null || echo "000")"
      case "$code" in
        200|301|302|401|403|404) ok "HTTPS 响应 HTTP ${code}" ;;
        000) warn "HTTPS 请求失败（TCP 通但 TLS/证书可能有问题）" ;;
        *) ok "HTTPS 响应 HTTP ${code}" ;;
      esac
    fi
    return 0
  fi
  any_fail=1
  return "$any_fail"
}

show_firewall_hints() {
  section "主机防火墙线索"
  local found=0

  if have_cmd ufw && ufw status 2>/dev/null | grep -qi active; then
    found=1
    warn "ufw 已启用:"
    ufw status numbered 2>/dev/null | sed 's/^/    /' | head -n 15 || true
    note "放行示例: sudo ufw allow 9345/tcp && sudo ufw allow 6443/tcp"
  fi

  if have_cmd firewall-cmd && firewall-cmd --state 2>/dev/null | grep -qi running; then
    found=1
    warn "firewalld 运行中:"
    firewall-cmd --list-ports 2>/dev/null | sed 's/^/    ports: /' || true
    note "放行示例: sudo firewall-cmd --permanent --add-port=6443/tcp --add-port=9345/tcp && sudo firewall-cmd --reload"
  fi

  if have_cmd iptables; then
    local drops
    drops="$(iptables -L INPUT -n -v 2>/dev/null | grep -ciE 'DROP|REJECT' || true)"
    if [[ "${drops:-0}" -gt 0 ]]; then
      found=1
      warn "iptables INPUT 链含 DROP/REJECT 规则（${drops} 条），请人工核对"
      iptables -L INPUT -n -v 2>/dev/null | head -n 12 | sed 's/^/    /' || true
    fi
  fi

  if [[ "$found" -eq 0 ]]; then
    note "未检测到活跃的 ufw / firewalld；若端口仍不通，请查云安全组或上游网络 ACL"
  fi
}

show_services() {
  section "相关服务"
  local u state
  for u in rke2-server rke2-agent k3s k3s-agent rancher-system-agent; do
    systemctl cat "${u}.service" &>/dev/null 2>&1 || continue
    state="$(systemctl is-active "${u}" 2>/dev/null || echo unknown)"
    case "$state" in
      active) ok "${u}: ${state}" ;;
      *) fail "${u}: ${state}" ;;
    esac
  done
}

show_hints() {
  local cp_fail="${1:-0}" listen_fail="${2:-0}"
  section "排查建议"
  if [[ "$cp_fail" -ne 0 || "$listen_fail" -ne 0 ]]; then
    note "1. 云安全组 / VPC ACL：入站放行 TCP 9345、6443（worker→master）；节点间 Calico 常用 179/TCP"
    note "2. 主机防火墙：ufw / firewalld / iptables 是否拦截上述端口"
    note "3. control plane：master 上 rke2-server 是否 active，ss 是否监听 *:6443 *:9345"
    note "4. 配置地址：/etc/rancher/rke2/config.yaml 的 server 是否为 worker 可达的内网 IP"
    note "5. 连通但 join 仍失败：brew k8s node-status -v / brew k8s node-pull -f"
  else
    ok "关键端口探测通过；若 UI 仍卡住，查镜像拉取: brew k8s node-pull"
  fi
  note "持续观察: brew k8s node-watch -i 3"
}

main() {
  if [[ "$(uname -s | tr '[:upper:]' '[:lower:]')" != "linux" ]]; then
    echo "此命令需在 Linux 节点上执行" >&2
    exit 1
  fi

  parse_args "$@"

  local role cp_host listen_fail=0 cp_fail=0 rancher_fail=0
  role="$(detect_role)"

  section "RKE2 端口排查 — $(hostname 2>/dev/null || echo unknown)"
  note "角色: ${role}  探测超时: ${NODE_PORTS_TIMEOUT}s"

  show_services

  if [[ "$role" == "master" ]]; then
    show_local_listeners || listen_fail=1
    if have_cmd curl; then
      section "本机 API 探活"
      if curl -k -sS --connect-timeout "$NODE_PORTS_TIMEOUT" --max-time "$((NODE_PORTS_TIMEOUT * 2))" \
        https://127.0.0.1:6443/readyz &>/dev/null; then
        ok "https://127.0.0.1:6443/readyz 可达"
      else
        fail "https://127.0.0.1:6443/readyz 失败（apiserver 可能未就绪）"
        listen_fail=1
      fi
    fi
  fi

  cp_host="$(detect_control_plane_host || true)"
  if [[ -n "$cp_host" ]]; then
    if [[ "$role" == "master" && "$cp_host" =~ ^127\. ]] \
      || ip -4 addr show 2>/dev/null | grep -q "inet ${cp_host}/"; then
      note "control plane 地址: ${cp_host}（本机或回环，跳过远程探测）"
    else
      show_remote_probes "$cp_host" || cp_fail=1
    fi
  else
    warn "未从配置读取 control plane 地址（可 --host 指定）"
    if [[ "$role" == "worker" ]]; then
      cp_fail=1
    fi
  fi

  show_rancher_server_probe || rancher_fail=1
  show_firewall_hints
  show_hints "$cp_fail" "$listen_fail"

  if [[ "$cp_fail" -ne 0 || "$listen_fail" -ne 0 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"
