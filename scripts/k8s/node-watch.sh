#!/usr/bin/env bash
# 持续监控 Rancher 节点：服务状态、镜像拉取、join/报错摘要
#
# 用法:
#   brew k8s node-watch
#   brew k8s node-watch -i 3

set -euo pipefail

NODE_WATCH_INTERVAL="${NODE_WATCH_INTERVAL:-5}"
NODE_WATCH_ONCE="${NODE_WATCH_ONCE:-false}"
NODE_WATCH_JOURNAL_LINES="${NODE_WATCH_JOURNAL_LINES:-6}"

have_cmd() {
  command -v "$1" &>/dev/null
}

unit_state() {
  local unit="$1"
  if ! systemctl cat "${unit}.service" &>/dev/null 2>&1; then
    echo "-"
    return 0
  fi
  systemctl is-active "${unit}" 2>/dev/null || echo "inactive"
}

detect_role_label() {
  if systemctl cat rke2-server.service &>/dev/null 2>&1 || systemctl cat k3s.service &>/dev/null 2>&1; then
    echo "master"
  elif systemctl cat rke2-agent.service &>/dev/null 2>&1 || systemctl cat k3s-agent.service &>/dev/null 2>&1; then
    echo "worker"
  else
    echo "unknown"
  fi
}

pick_crictl() {
  local p
  for p in /var/lib/rancher/rke2/bin/crictl /var/lib/rancher/k3s/data/current/bin/crictl crictl; do
    [[ -x "$p" ]] || have_cmd "$p" || continue
    echo "$p"
    return 0
  done
  return 1
}

pick_containerd_sock() {
  local sock
  for sock in \
    /run/rancher/rke2/agent/containerd/containerd.sock \
    /run/rancher/rke2/containerd/containerd.sock \
    /run/k3s/containerd/containerd.sock \
    /run/containerd/containerd.sock; do
    [[ -S "$sock" ]] && { echo "$sock"; return 0; }
  done
  return 1
}

count_crictl_images() {
  local crictl sock n
  crictl="$(pick_crictl || true)"
  sock="$(pick_containerd_sock || true)"
  [[ -n "$crictl" && -n "$sock" ]] || { echo "0"; return 0; }
  n="$("$crictl" --runtime-endpoint "unix://${sock}" images -q 2>/dev/null | wc -l | tr -d ' ')"
  echo "${n:-0}"
}

count_crictl_running() {
  local crictl sock n
  crictl="$(pick_crictl || true)"
  sock="$(pick_containerd_sock || true)"
  [[ -n "$crictl" && -n "$sock" ]] || { echo "0"; return 0; }
  n="$("$crictl" --runtime-endpoint "unix://${sock}" ps -q 2>/dev/null | wc -l | tr -d ' ')"
  echo "${n:-0}"
}

recent_journal() {
  local unit="$1" lines="${2:-$NODE_WATCH_JOURNAL_LINES}"
  systemctl cat "${unit}.service" &>/dev/null 2>&1 || return 0
  journalctl -u "${unit}.service" --since "2 min ago" --no-pager 2>/dev/null \
    | grep -iE 'pull|extract|staging|image|error|failed|join|9345|6443|applyinator|ready|running' \
    | tail -n "$lines" \
    | sed 's/^/    /' || true
}

health_summary() {
  local sa srv ag failed=0 has_runtime=false
  sa="$(unit_state rancher-system-agent)"
  srv="$(server_runtime_state)"
  ag="$(agent_runtime_state)"
  [[ "$srv" != "-" ]] && has_runtime=true
  [[ "$ag" != "-" ]] && has_runtime=true

  for s in "$sa" "$srv" "$ag"; do
    [[ "$s" == "-" ]] && continue
    [[ "$s" == "failed" || "$s" == "inactive" ]] && failed=$((failed + 1))
  done

  if [[ "$has_runtime" == false && "$sa" == "-" ]]; then
    echo "NO_SERVICES"
  elif [[ "$failed" -gt 0 ]]; then
    echo "DEGRADED"
  elif [[ "$srv" == "activating" || "$ag" == "activating" || "$sa" == "activating" ]]; then
    echo "STARTING"
  elif [[ "$srv" == "active" || "$ag" == "active" ]]; then
    echo "OK"
  elif [[ "$sa" == "active" ]]; then
    echo "WATCH"
  else
    echo "WATCH"
  fi
}

server_runtime_state() {
  if systemctl cat rke2-server.service &>/dev/null 2>&1; then
    unit_state rke2-server
    return 0
  fi
  if systemctl cat k3s.service &>/dev/null 2>&1; then
    unit_state k3s
    return 0
  fi
  echo "-"
}

agent_runtime_state() {
  if systemctl cat rke2-agent.service &>/dev/null 2>&1; then
    unit_state rke2-agent
    return 0
  fi
  if systemctl cat k3s-agent.service &>/dev/null 2>&1; then
    unit_state k3s-agent
    return 0
  fi
  echo "-"
}

render_snapshot() {
  local ts role health imgs pods srv ag
  ts="$(date '+%F %T')"
  role="$(detect_role_label)"
  health="$(health_summary)"
  imgs="$(count_crictl_images)"
  pods="$(count_crictl_running)"
  srv="$(server_runtime_state)"
  ag="$(agent_runtime_state)"

  printf '\n'
  echo "════════════════════════════════════════════════════════════"
  echo "  Rancher 节点监控  ${ts}  $(hostname 2>/dev/null || echo unknown)"
  echo "  角色: ${role}    健康: ${health}    镜像: ${imgs}    运行中容器: ${pods}"
  echo "────────────────────────────────────────────────────────────"
  printf '  %-24s %s\n' "rancher-system-agent" "$(unit_state rancher-system-agent)"
  printf '  %-24s %s\n' "rke2-server / k3s" "$srv"
  printf '  %-24s %s\n' "rke2-agent / k3s-agent" "$ag"

  if have_cmd ss; then
    local conn
    conn="$(ss -H -tn state established 2>/dev/null | grep -cE ':443|:9345|:6443' || true)"
    printf '  %-24s %s\n' "出站连接(443/9345/6443)" "${conn:-0}"
  fi

  echo "────────────────────────────────────────────────────────────"
  echo "  最近 rancher-system-agent:"
  recent_journal rancher-system-agent
  if systemctl cat rke2-agent.service &>/dev/null 2>&1; then
    echo "  最近 rke2-agent:"
    recent_journal rke2-agent
  elif systemctl cat rke2-server.service &>/dev/null 2>&1; then
    echo "  最近 rke2-server:"
    recent_journal rke2-server
  fi

  case "$health" in
    OK) echo "  ▶ 节点服务正常；UI 中应为 Active 或即将 Active" ;;
    STARTING) echo "  ▶ 正在启动/拉镜像，请继续观察" ;;
    DEGRADED) echo "  ▶ 有服务异常，详见上方日志；可: brew k8s node-restart ${role} -y" ;;
    NO_SERVICES) echo "  ▶ 未检测到 Rancher 节点服务（可能尚未注册）" ;;
    *) echo "  ▶ 观察中…" ;;
  esac
  echo "════════════════════════════════════════════════════════════"
}

usage() {
  cat <<'EOF'
用法: brew k8s node-watch [选项]

持续刷新节点状态：systemd 服务、containerd 镜像数、拉取/join 日志摘要。

选项:
  -i, --interval <秒>   刷新间隔（默认 5）
  --once                只显示一次（不循环）
  -h, --help            显示帮助

示例:
  brew k8s node-watch              # 持续监控（Ctrl+C 退出）
  brew k8s node-watch -i 3
  brew k8s node-watch --once

配合:
  brew k8s node-restart master -y
  brew k8s node-restart worker -y
  brew k8s node-pull -f            # 只看 agent 拉取日志
  brew k8s node-ports              # 6443/9345 端口与安全组/防火墙线索
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--interval)
        NODE_WATCH_INTERVAL="${2:-5}"
        shift 2
        ;;
      --once)
        NODE_WATCH_ONCE=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "未知参数: $1" >&2
        usage
        exit 1
        ;;
    esac
  done
}

main() {
  if [[ "$(uname -s | tr '[:upper:]' '[:lower:]')" != "linux" ]]; then
    echo "此命令需在 Linux 节点上执行"
    exit 1
  fi

  parse_args "$@"

  if [[ "$NODE_WATCH_ONCE" == true ]]; then
    render_snapshot
    exit 0
  fi

  echo "开始监控（每 ${NODE_WATCH_INTERVAL}s 刷新，Ctrl+C 退出）"
  while true; do
    render_snapshot
    sleep "$NODE_WATCH_INTERVAL"
  done
}

main "$@"
