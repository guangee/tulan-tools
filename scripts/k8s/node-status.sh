#!/usr/bin/env bash
# 在 Rancher 管理的 Linux 节点上查看注册 / Agent 状态
#
# 用法（在节点上执行）:
#   brew k8s node-status
#   sudo bash node-status.sh
#
# 新版 Rancher 自定义集群常见组件:
#   rancher-system-agent  → 与 Rancher Server 通信、下发配置
#   rke2-agent / k3s-agent → 实际 Kubernetes 运行时

set -euo pipefail

NODE_STATUS_VERBOSE="${NODE_STATUS_VERBOSE:-false}"

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

systemd_unit_state() {
  local unit="$1" state enabled
  if ! systemctl cat "$unit" &>/dev/null; then
    return 2
  fi
  state="$(systemctl is-active "$unit" 2>/dev/null || true)"
  enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  echo "${state}:${enabled}"
  return 0
}

show_systemd() {
  local unit="$1" label="${2:-$1}" info state enabled
  info="$(systemd_unit_state "$unit" || true)"
  if [[ -z "$info" ]]; then
    return 2
  fi
  state="${info%%:*}"
  enabled="${info#*:}"
  case "$state" in
    active) ok "${label}: running (enabled=${enabled})" ;;
    failed|inactive)
      fail "${label}: ${state} (enabled=${enabled})"
      systemctl status "$unit" --no-pager -l 2>/dev/null | tail -n 4 | sed 's/^/      /' || true
      ;;
    *) warn "${label}: ${state} (enabled=${enabled})" ;;
  esac
  return 0
}

show_journal_tail() {
  local unit="$1" lines="${2:-8}"
  if systemctl list-units --all --type=service --no-legend "$unit" &>/dev/null \
    || systemctl cat "$unit" &>/dev/null 2>&1; then
    note "最近日志 (${unit}):"
    journalctl -u "$unit" -n "$lines" --no-pager 2>/dev/null | sed 's/^/      /' || true
  fi
}

read_yaml_value() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  grep -E "^[[:space:]]*${key}:" "$file" 2>/dev/null | head -n1 | sed -E "s/^[[:space:]]*${key}:[[:space:]]*//" | tr -d "'\""
}

detect_runtime() {
  RUNTIME=""
  if show_systemd "rancher-system-agent.service" "rancher-system-agent" 2>/dev/null; then
    RUNTIME="system-agent"
  fi
  if show_systemd "rke2-agent.service" "rke2-agent" 2>/dev/null; then
    RUNTIME="${RUNTIME:+$RUNTIME+}rke2-agent"
  elif show_systemd "rke2-server.service" "rke2-server" 2>/dev/null; then
    RUNTIME="${RUNTIME:+$RUNTIME+}rke2-server"
  fi
  if show_systemd "k3s-agent.service" "k3s-agent" 2>/dev/null; then
    RUNTIME="${RUNTIME:+$RUNTIME+}k3s-agent"
  elif show_systemd "k3s.service" "k3s" 2>/dev/null; then
    RUNTIME="${RUNTIME:+$RUNTIME+}k3s"
  fi
  if [[ -z "$RUNTIME" ]] && have_cmd docker && docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'rancher-agent'; then
    RUNTIME="docker-rancher-agent"
    ok "rancher-agent 容器: running"
  fi
}

show_agent_config() {
  local f server token
  for f in /etc/rancher/agent/config.yaml /etc/rancher/agent/config; do
    [[ -f "$f" ]] || continue
    note "Agent 配置: ${f}"
    server="$(read_yaml_value "$f" "server" || read_yaml_value "$f" "url" || true)"
    [[ -n "$server" ]] && note "  server: ${server}"
    if [[ "$NODE_STATUS_VERBOSE" == true ]]; then
      grep -E '^(server|url|token|node-name|address|internal-address):' "$f" 2>/dev/null \
        | sed 's/^/    /' || true
    fi
    return 0
  done
  return 1
}

show_rke2_config() {
  local f server token
  shopt -s nullglob
  local files=(/etc/rancher/rke2/config.yaml /etc/rancher/rke2/config.yaml.d/*.yaml)
  shopt -u nullglob
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    note "RKE2 配置: ${f}"
    server="$(read_yaml_value "$f" "server" || true)"
    [[ -n "$server" ]] && note "  server: ${server}  (join 地址)"
    token="$(read_yaml_value "$f" "token" || true)"
    [[ -n "$token" && "$NODE_STATUS_VERBOSE" == true ]] && note "  token: (已配置)"
    return 0
  done
  return 1
}

show_k3s_config() {
  local f="/etc/rancher/k3s/config.yaml"
  if [[ -f "$f" ]]; then
    note "k3s 配置: ${f}"
    grep -E '^(server|token|node-name):' "$f" 2>/dev/null | sed 's/^/    /' || true
    return 0
  fi
  return 1
}

pick_crictl() {
  local p
  for p in /var/lib/rancher/rke2/bin/crictl /var/lib/rancher/k3s/data/current/bin/crictl crictl; do
    if [[ -x "$p" ]] || command -v "$p" &>/dev/null; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

show_crictl_pods() {
  local crictl sock
  crictl="$(pick_crictl || true)"
  [[ -n "$crictl" ]] || return 1

  for sock in \
    /run/k3s/containerd/containerd.sock \
    /run/rancher/rke2/agent/containerd/containerd.sock \
    /run/containerd/containerd.sock; do
    [[ -S "$sock" ]] || continue
    note "容器运行时 (${sock}):"
    CRICONTAINERD="$sock" "$crictl" --runtime-endpoint "unix://${sock}" \
      ps 2>/dev/null | head -n 15 | sed 's/^/    /' || warn "crictl ps 失败"
    return 0
  done
  return 1
}

pick_kubectl() {
  local p kc
  for p in /var/lib/rancher/rke2/bin/kubectl /var/lib/rancher/k3s/data/current/bin/kubectl kubectl; do
    if [[ -x "$p" ]] || command -v "$p" &>/dev/null; then
      for kc in /etc/rancher/rke2/rke2.yaml /etc/rancher/k3s/k3s.yaml; do
        [[ -f "$kc" ]] && { echo "${p} ${kc}"; return 0; }
      done
      echo "$p"
      return 0
    fi
  done
  return 1
}

show_kubectl_node() {
  local pair kubectl kubeconfig node
  pair="$(pick_kubectl || true)"
  [[ -n "$pair" ]] || return 1
  kubectl="${pair%% *}"
  kubeconfig="${pair#* }"
  [[ "$kubeconfig" == "$kubectl" ]] && kubeconfig=""

  if [[ -n "$kubeconfig" && -f "$kubeconfig" ]]; then
    node="$("$kubectl" --kubeconfig "$kubeconfig" get nodes -o wide 2>/dev/null || true)"
  else
    node="$("$kubectl" get nodes -o wide 2>/dev/null || true)"
  fi
  [[ -n "$node" ]] || return 1
  note "集群节点 (kubectl get nodes):"
  echo "$node" | sed 's/^/    /'
}

summarize_registration() {
  local ok_count=0 issues=()

  if systemctl is-active --quiet rancher-system-agent 2>/dev/null; then
    ok_count=$((ok_count + 1))
  elif systemctl list-unit-files rancher-system-agent.service &>/dev/null 2>&1; then
    issues+=("rancher-system-agent 未运行")
  fi

  if systemctl is-active --quiet rke2-agent 2>/dev/null \
    || systemctl is-active --quiet rke2-server 2>/dev/null \
    || systemctl is-active --quiet k3s-agent 2>/dev/null \
    || systemctl is-active --quiet k3s 2>/dev/null; then
    ok_count=$((ok_count + 1))
  elif [[ "$RUNTIME" == *rke2* || "$RUNTIME" == *k3s* ]]; then
    issues+=("K8s 运行时服务未 active")
  fi

  section "注册状态摘要"
  note "主机名: $(hostname -f 2>/dev/null || hostname)"
  note "检测到: ${RUNTIME:-未识别 Rancher/K8s 组件}"

  if [[ ${#issues[@]} -eq 0 && -n "$RUNTIME" ]]; then
    ok "节点 Agent 服务看起来正常；请在 Rancher UI「集群 → 节点」确认状态为 Active"
  elif [[ -z "$RUNTIME" ]]; then
    warn "未检测到 rancher-system-agent / rke2 / k3s 服务"
    note "若尚未执行注册命令，请先在节点运行 brew k8s register-command 获取的安装命令"
  else
    for i in "${issues[@]}"; do
      fail "$i"
    done
    note "排查: journalctl -u rancher-system-agent -n 100 --no-pager"
    note "      journalctl -u rke2-agent -n 100 --no-pager"
  fi
}

main() {
  if [[ "$(uname -s | tr '[:upper:]' '[:lower:]')" != "linux" ]]; then
    echo "此命令需在 Linux 节点上执行"
    exit 1
  fi

  section "Rancher 节点注册状态 — $(hostname 2>/dev/null || echo unknown)"
  note "说明: 新版自定义集群 = rancher-system-agent + rke2-agent/k3s-agent"

  section "Systemd 服务"
  detect_runtime
  if [[ -z "$RUNTIME" ]]; then
    warn "未发现常见 Rancher 节点服务（可能尚未注册或已卸载）"
  fi

  section "配置文件"
  show_agent_config || note "  (无 /etc/rancher/agent/config.yaml)"
  show_rke2_config || true
  show_k3s_config || true

  section "容器 / Pod"
  show_crictl_pods || note "  (crictl 不可用或无 containerd socket)"

  section "Kubernetes 节点"
  show_kubectl_node || note "  (本机无 kubectl 或尚无 kubeconfig；worker 节点通常正常)"

  if [[ "$NODE_STATUS_VERBOSE" == true ]]; then
    section "服务日志"
    show_journal_tail "rancher-system-agent.service" 10
    show_journal_tail "rke2-agent.service" 10
    show_journal_tail "k3s-agent.service" 10
  fi

  summarize_registration
}

main "$@"
