#!/usr/bin/env bash
# 在 Rancher 节点上查看镜像拉取进度、registry 连通性与相关网络活动
#
# 用法:
#   brew k8s node-pull
#   brew k8s node-pull -f          # 持续跟踪 agent 拉取日志
#   brew k8s node-pull --since 5m  # 只看最近 5 分钟

set -euo pipefail

NODE_PULL_FOLLOW="${NODE_PULL_FOLLOW:-false}"
NODE_PULL_SINCE="${NODE_PULL_SINCE:-10m}"
NODE_PULL_JOURNAL_LINES="${NODE_PULL_JOURNAL_LINES:-40}"

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
      -f|--follow)
        NODE_PULL_FOLLOW=true
        shift
        ;;
      --since)
        NODE_PULL_SINCE="${2:-10m}"
        shift 2
        ;;
      -n|--lines)
        NODE_PULL_JOURNAL_LINES="${2:-40}"
        shift 2
        ;;
      -h|--help)
        cat <<'EOF'
用法: brew k8s node-pull [选项]

在 Rancher 管理的 Linux 节点上查看:
  - rancher-system-agent 是否在拉镜像 / 执行 plan
  - registry 网络是否可达
  - 当前到镜像仓库的 TCP 连接

选项:
  -f, --follow       持续跟踪 agent 日志（Ctrl+C 退出）
  --since <时间>     journal 时间范围（默认 10m，如 5m、1h）
  -n, --lines <N>    非 follow 模式显示最近 N 行相关日志（默认 40）
  -h, --help         显示帮助

示例:
  brew k8s node-pull
  brew k8s node-pull --since 5m
  brew k8s node-pull -f
EOF
        exit 0
        ;;
      *)
        echo "未知参数: $1（brew k8s node-pull -h 查看帮助）" >&2
        exit 1
        ;;
    esac
  done
}

unit_active() {
  systemctl is-active --quiet "$1" 2>/dev/null
}

show_service_activity() {
  section "Agent / 运行时服务"
  local u active=0
  for u in rancher-system-agent rke2-server rke2-agent k3s k3s-agent; do
    if systemctl cat "${u}.service" &>/dev/null 2>&1; then
      if unit_active "${u}"; then
        ok "${u}: running"
        active=$((active + 1))
      else
        state="$(systemctl is-active "${u}" 2>/dev/null || echo unknown)"
        fail "${u}: ${state}"
      fi
    fi
  done
  if (( active == 0 )); then
    warn "未发现 active 的 agent/rke2/k3s 服务（可能尚未注册或已停止）"
  fi
}

collect_registry_hosts() {
  local f line host hosts=()
  for f in \
    /etc/rancher/agent/registries.yaml \
    /etc/rancher/rke2/registries.yaml \
    /etc/rancher/k3s/registries.yaml; do
    [[ -f "$f" ]] || continue
    note "registry 配置: ${f}"
    while IFS= read -r line; do
      line="${line#"${line%%[![:space:]]*}"}"
      [[ "$line" =~ ^-[[:space:]]*\"?(https?://[^\"]+)\"? ]] || continue
      host="${BASH_REMATCH[1]}"
      host="${host%/}"
      hosts+=("$host")
      note "  endpoint: ${host}"
    done < "$f"
  done
  REGISTRY_HOSTS=("${hosts[@]}")
}

probe_registry() {
  section "Registry 网络探测"
  collect_registry_hosts
  if ((${#REGISTRY_HOSTS[@]} == 0)); then
    warn "未找到 registries.yaml，尝试探测常见镜像源"
    REGISTRY_HOSTS=(
      "https://hub.coding-space.cn"
      "https://registry-1.docker.io"
    )
  fi
  local base host code
  for base in "${REGISTRY_HOSTS[@]}"; do
    host="${base#https://}"
    host="${host#http://}"
    host="${host%%/*}"
    note "探测 ${base}/v2/ ..."
    if have_cmd curl; then
      code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 \
        -k "${base}/v2/" 2>/dev/null || echo "000")"
      case "$code" in
        200|401) ok "${base} 可达 (HTTP ${code})" ;;
        000) fail "${base} 不可达（超时/DNS/拒绝连接）" ;;
        *) warn "${base} 响应 HTTP ${code}" ;;
      esac
    else
      warn "未安装 curl，跳过 ${base}"
    fi
  done
}

show_rancher_server_reachability() {
  section "Rancher Server 连通性"
  local f server host port
  server=""
  for f in /etc/rancher/agent/config.yaml /etc/rancher/agent/config; do
    [[ -f "$f" ]] || continue
    server="$(grep -E '^[[:space:]]*(server|url):' "$f" 2>/dev/null | head -n1 \
      | sed -E 's/^[[:space:]]*(server|url):[[:space:]]*//' | tr -d "'\"")"
    [[ -n "$server" ]] && break
  done
  if [[ -z "$server" ]]; then
    warn "未找到 agent server 地址（/etc/rancher/agent/config.yaml）"
    return 0
  fi
  note "agent server: ${server}"
  if have_cmd curl; then
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 \
      -k "${server%/}/" 2>/dev/null || echo "000")"
    case "$code" in
      200) ok "Rancher Server 可达 (HTTP ${code})" ;;
      000) fail "Rancher Server 不可达" ;;
      *) ok "Rancher Server 有响应 (HTTP ${code})" ;;
    esac
  fi
  host="${server#https://}"
  host="${host#http://}"
  host="${host%%/*}"
  port="${host##*:}"
  host="${host%%:*}"
  [[ "$port" == "$host" ]] && port="443"
  RANCHER_PROBE_HOST="$host"
  RANCHER_PROBE_PORT="$port"
  export RANCHER_PROBE_HOST RANCHER_PROBE_PORT
}

show_outbound_connections() {
  section "镜像相关出站连接"
  local hosts=() h host port pattern
  hosts=("${REGISTRY_HOSTS[@]}")
  [[ -n "${RANCHER_PROBE_HOST:-}" ]] && hosts+=("${RANCHER_PROBE_HOST}:${RANCHER_PROBE_PORT:-443}")
  if ((${#hosts[@]} == 0)); then
    note "(无 registry 配置，跳过)"
    return 0
  fi
  if ! have_cmd ss; then
    warn "未安装 ss，跳过连接查看"
    return 0
  fi
  local found=0
  for h in "${hosts[@]}"; do
    if [[ "$h" == *:* ]]; then
      host="${h%%:*}"
      port="${h##*:}"
    else
      host="${h#https://}"
      host="${host#http://}"
      host="${host%%/*}"
      port="${host##*:}"
      host="${host%%:*}"
      [[ "$port" == "$host" ]] && port="443"
    fi
    pattern=":${port}"
    if ss -H -tn state established 2>/dev/null | grep -q "${host}${pattern}\|${host}.*${pattern}"; then
      ok "到 ${host}:${port} 有 ESTABLISHED 连接（可能正在传输）"
      ss -H -tnp state established 2>/dev/null | grep "${host}" | head -n 5 | sed 's/^/    /' || true
      found=1
    fi
  done
  if (( found == 0 )); then
    note "当前无到 registry/Rancher 的 ESTABLISHED 连接"
    note "（空闲或 DNS 解析失败时常见；若 agent 在重试则稍后再看）"
  fi
}

show_pull_journal() {
  section "镜像拉取 / plan 日志（rancher-system-agent，最近 ${NODE_PULL_SINCE}）"
  if ! systemctl cat rancher-system-agent.service &>/dev/null 2>&1; then
    warn "无 rancher-system-agent 服务"
    return 0
  fi
  if [[ "$NODE_PULL_FOLLOW" == true ]]; then
    note "跟踪模式（Ctrl+C 退出），过滤 Pull/Extract/staging/plan/error ..."
    journalctl -u rancher-system-agent -f --no-pager 2>/dev/null \
      | grep --line-buffered -iE 'pull|extract|staging|plan|image|registry|endpoint|error|applyinator' || true
    exit 0
  fi
  local lines
  lines="$(journalctl -u rancher-system-agent --since "$NODE_PULL_SINCE" --no-pager 2>/dev/null \
    | grep -iE 'pull|extract|staging|plan|image|registry|endpoint|error|applyinator|failed' \
    | tail -n "$NODE_PULL_JOURNAL_LINES" || true)"
  if [[ -z "$lines" ]]; then
    note "最近 ${NODE_PULL_SINCE} 无拉取相关日志"
    note "查看全部: journalctl -u rancher-system-agent --since ${NODE_PULL_SINCE} -n 50"
    return 0
  fi
  echo "$lines" | sed 's/^/  /'

  if echo "$lines" | tail -n 3 | grep -qiE 'pulling image|extracting image|staging'; then
    ok "检测到近期拉取活动"
  elif echo "$lines" | tail -n 5 | grep -qiE 'failed|error|all endpoints failed'; then
    fail "近期拉取失败（见上方 error 行）"
  else
    note "近期无明确「正在拉取」日志（可能 idle 或等待 plan）"
  fi
}

show_containerd_activity() {
  section "containerd 镜像（若 RKE2/k3s 已部分安装）"
  local crictl sock
  crictl=""
  for crictl in /var/lib/rancher/rke2/bin/crictl /var/lib/rancher/k3s/data/current/bin/crictl crictl; do
    [[ -x "$crictl" ]] || have_cmd "$crictl" || continue
    for sock in \
      /run/rancher/rke2/agent/containerd/containerd.sock \
      /run/k3s/containerd/containerd.sock \
      /run/containerd/containerd.sock; do
      [[ -S "$sock" ]] || continue
      note "crictl images (${sock}):"
      CRICONTAINERD="$sock" "$crictl" --runtime-endpoint "unix://${sock}" images 2>/dev/null \
        | head -n 20 | sed 's/^/    /' || warn "crictl images 失败"
      note "crictl ps:"
      CRICONTAINERD="$sock" "$crictl" --runtime-endpoint "unix://${sock}" ps 2>/dev/null \
        | head -n 10 | sed 's/^/    /' || true
      return 0
    done
  done
  note "(containerd 尚未就绪或无 crictl)"
}

summarize() {
  section "简要结论"
  note "持续跟踪拉取: brew k8s node-pull -f"
  note "看 agent 全量日志: journalctl -u rancher-system-agent -f"
  note "看已拉镜像: brew k8s images"
}

main() {
  if [[ "$(uname -s | tr '[:upper:]' '[:lower:]')" != "linux" ]]; then
    echo "此命令需在 Linux 节点上执行"
    exit 1
  fi

  parse_args "$@"

  section "节点镜像拉取 / 网络 — $(hostname 2>/dev/null || echo unknown)"
  note "时间范围: ${NODE_PULL_SINCE}（--since 可改）"

  show_service_activity
  show_rancher_server_reachability
  probe_registry
  show_outbound_connections
  show_pull_journal
  show_containerd_activity
  summarize
}

main "$@"
