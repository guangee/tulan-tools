#!/usr/bin/env bash
# 获取 Rancher 指定下游集群的 kubeconfig
#
# 用法:
#   brew k8s kubeconfig --list
#   brew k8s kubeconfig -c mycluster
#   brew k8s kubeconfig -c mycluster -o ~/.kube/mycluster.yaml

set -euo pipefail

_SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../lib/common.sh
source "${_SCRIPT_ROOT}/lib/common.sh"

KUBECONFIG_CLUSTER="${KUBECONFIG_CLUSTER:-}"
KUBECONFIG_OUTPUT="${KUBECONFIG_OUTPUT:-}"
KUBECONFIG_LIST="${KUBECONFIG_LIST:-false}"
KUBECONFIG_RANCHER_URL="${KUBECONFIG_RANCHER_URL:-}"
KUBECONFIG_TIMEOUT="${KUBECONFIG_TIMEOUT:-30}"
KUBECONFIG_VERBOSE="${KUBECONFIG_VERBOSE:-false}"

usage() {
  cat <<'EOF'
用法: brew k8s kubeconfig [选项]

在 Rancher Server 主机上获取指定集群的 kubeconfig 内容（需 Rancher 容器运行中）。

选项:
  --list              列出所有集群（ID / 显示名 / 状态）
  -c, --cluster <名>  集群名：UI 显示名、c-m-xxx 或 local（必填，除非 --list）
  -o, --output <path> 写入文件（默认输出到 stdout）
  --url <url>         Rancher API 地址（默认从 rancher.env / server-url 读取）
  --timeout <秒>      单步操作超时（默认 30）
  -v, --verbose       显示详细尝试过程
  -h, --help          显示帮助

示例:
  brew k8s kubeconfig --list
  brew k8s kubeconfig -c prod -o ~/.kube/config
  brew k8s kubeconfig -c prod -v

说明:
  - 下游集群通过 Rancher /v3/clusters/{id}?action=generateKubeconfig 获取
  - local 集群直接导出容器内 /etc/rancher/k3s/k3s.yaml
  - 认证优先 client 证书，其次 token；各 HTTP 请求均有超时
EOF
}

log_step() {
  tulan_log "[kubeconfig] $*"
}

log_verbose() {
  [[ "$KUBECONFIG_VERBOSE" == true ]] && tulan_log "[kubeconfig]   $*" || true
}

run_timeout() {
  local secs="$1"
  shift
  if command -v timeout &>/dev/null; then
    timeout --kill-after=5 "$secs" "$@"
  else
    "$@"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --list)
        KUBECONFIG_LIST=true
        shift
        ;;
      -c|--cluster)
        KUBECONFIG_CLUSTER="${2:-}"
        shift 2
        ;;
      -o|--output)
        KUBECONFIG_OUTPUT="${2:-}"
        shift 2
        ;;
      --url)
        KUBECONFIG_RANCHER_URL="${2:-}"
        shift 2
        ;;
      --timeout)
        KUBECONFIG_TIMEOUT="${2:-30}"
        shift 2
        ;;
      -v|--verbose)
        KUBECONFIG_VERBOSE=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "未知参数: $1（brew k8s kubeconfig -h 查看帮助）" >&2
        exit 1
        ;;
    esac
  done
}

rancher_container() {
  echo "${CONTAINER_NAME:-${TULAN_K8S_CONTAINER:-rancher}}"
}

rancher_kubectl() {
  local container
  container="$(rancher_container)"
  run_timeout "$KUBECONFIG_TIMEOUT" docker exec "$container" kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml "$@"
}

rancher_local_kubeconfig() {
  run_timeout "$KUBECONFIG_TIMEOUT" docker exec "$(rancher_container)" cat /etc/rancher/k3s/k3s.yaml
}

pick_rancher_api_url() {
  if [[ -n "$KUBECONFIG_RANCHER_URL" ]]; then
    echo "$KUBECONFIG_RANCHER_URL"
    return 0
  fi
  local domain="${K8S_SITE_DOMAIN:-}" port="${HTTPS_PORT_MAP%%:*}" url
  if [[ -n "$domain" && -n "$port" ]]; then
    echo "https://${domain}:${port}"
    return 0
  fi
  url="$(rancher_kubectl get settings.management.cattle.io server-url \
    -o jsonpath='{.value}' 2>/dev/null || rancher_kubectl get setting server-url \
    -o jsonpath='{.value}' 2>/dev/null || true)"
  [[ -n "$url" ]] && echo "$url"
}

write_output() {
  local content="$1"
  if [[ -n "$KUBECONFIG_OUTPUT" ]]; then
    mkdir -p "$(dirname "$KUBECONFIG_OUTPUT")"
    printf '%s' "$content" >"$KUBECONFIG_OUTPUT"
    chmod 600 "$KUBECONFIG_OUTPUT" 2>/dev/null || true
    log_step "已写入: ${KUBECONFIG_OUTPUT}"
    return 0
  fi
  printf '%s' "$content"
}

# 容器内调用 Norman API；CURL_MAX/KUBECONFIG_VERBOSE 由宿主机传入
rancher_fetch_in_container() {
  local cluster_id="$1"
  local container curl_max verbose_flag
  container="$(rancher_container)"
  curl_max=$((KUBECONFIG_TIMEOUT < 15 ? KUBECONFIG_TIMEOUT : 12))
  verbose_flag=0
  [[ "$KUBECONFIG_VERBOSE" == true ]] && verbose_flag=1

  run_timeout "$((KUBECONFIG_TIMEOUT + 10))" docker exec \
    -e "CLUSTER_ID=${cluster_id}" \
    -e "CURL_CONNECT=3" \
    -e "CURL_MAX=${curl_max}" \
    -e "VERBOSE=${verbose_flag}" \
    "$container" sh -s <<'EOS'
CLUSTER_ID="${CLUSTER_ID:?}"
KCFG=/etc/rancher/k3s/k3s.yaml
export KUBECONFIG="$KCFG"
CURL_CONNECT="${CURL_CONNECT:-3}"
CURL_MAX="${CURL_MAX:-10}"
VERBOSE="${VERBOSE:-0}"

vlog() { [ "$VERBOSE" = 1 ] && echo "[kubeconfig/in-container] $*" >&2 || true; }

post_api() {
  base="$1"
  shift
  curl -sfk --connect-timeout "$CURL_CONNECT" --max-time "$CURL_MAX" -X POST \
    -H "Content-Type: application/json" \
    -d '{}' \
    "$@" \
    "${base}/v3/clusters/${CLUSTER_ID}?action=generateKubeconfig"
}

# 1) client 证书（新版 k3s 默认，优先 http 避免 TLS 握手卡住）
for crt in \
  /var/lib/rancher/k3s/server/tls/client-admin.crt \
  /var/lib/rancher/k3s/server/tls/client-kube-apiserver.crt; do
  key="${crt%.crt}.key"
  [ -f "$crt" ] || continue
  [ -f "$key" ] || continue
  for base in http://127.0.0.1 http://localhost; do
    vlog "尝试 client-cert ${crt} @ ${base}"
    if resp="$(post_api "$base" --cert "$crt" --key "$key" 2>/dev/null || true)" && [ -n "$resp" ]; then
      printf '%s' "$resp"
      exit 0
    fi
  done
done

# 2) kubeconfig 内静态 token
token="$(kubectl config view --minify --raw -o jsonpath='{.users[0].user.token}' 2>/dev/null || true)"
if [ -n "$token" ]; then
  for base in http://127.0.0.1 http://localhost; do
    vlog "尝试 bearer token @ ${base}"
    if resp="$(post_api "$base" -H "Authorization: Bearer ${token}" 2>/dev/null || true)" && [ -n "$resp" ]; then
      printf '%s' "$resp"
      exit 0
    fi
  done
fi

# 3) 动态 token（仅试常见 SA，单次超时 5s）
if command -v timeout >/dev/null 2>&1; then
  KUBE_TOKEN_CMD="timeout 5 kubectl create token"
else
  KUBE_TOKEN_CMD="kubectl create token"
fi
for sa in cattle-admin default; do
  for ns in cattle-system kube-system; do
    vlog "尝试 create token ${sa}@${ns}"
    token="$($KUBE_TOKEN_CMD "$sa" -n "$ns" --duration=10m 2>/dev/null || true)"
    [ -n "$token" ] || continue
    for base in http://127.0.0.1; do
      if resp="$(post_api "$base" -H "Authorization: Bearer ${token}" 2>/dev/null || true)" && [ -n "$resp" ]; then
        printf '%s' "$resp"
        exit 0
      fi
    done
  done
done

vlog "容器内 API 均未成功"
exit 1
EOS
}

fetch_downstream_kubeconfig() {
  local cluster_id="$1" rancher_url="$2"
  local clusters_json="$3" resp mgmt_kc py_timeout

  log_step "步骤 3/4: 容器内 Rancher API 获取 kubeconfig（集群 ${cluster_id}，超时 ${KUBECONFIG_TIMEOUT}s）"
  if resp="$(rancher_fetch_in_container "$cluster_id" 2>/dev/null || true)" && [[ -n "$resp" ]]; then
    log_step "容器内 API 成功，解析 config 字段"
    printf '%s' "$resp" | tulan_python k8s extract-config
    return 0
  fi
  log_verbose "容器内 API 未成功，改走宿主机 API"

  log_step "步骤 4/4: 宿主机 API 获取（${rancher_url}，client 证书认证）"
  mgmt_kc="$(mktemp)"
  rancher_local_kubeconfig >"$mgmt_kc"
  py_timeout="$KUBECONFIG_TIMEOUT"

  printf '%s' "$clusters_json" | tulan_python k8s kubeconfig \
    --cluster "$KUBECONFIG_CLUSTER" \
    --rancher-url "$rancher_url" \
    --mgmt-kubeconfig-file "$mgmt_kc" \
    --timeout "$py_timeout"
  rm -f "$mgmt_kc"
}

main() {
  parse_args "$@"
  [[ "${NODE_STATUS_VERBOSE:-false}" == true ]] && KUBECONFIG_VERBOSE=true

  local container clusters_json cluster_id rancher_url config

  if ! command -v docker &>/dev/null; then
    tulan_error "需要 Docker"
    exit 1
  fi
  container="$(rancher_container)"
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$container"; then
    tulan_error "Rancher 容器未运行: ${container}"
    exit 1
  fi

  log_step "步骤 1/4: 读取集群列表（容器 ${container}）"
  clusters_json="$(rancher_kubectl get clusters.management.cattle.io -o json 2>/dev/null)" || {
    tulan_error "无法读取集群列表（请确认 Rancher 已就绪；可用 -v 查看详情）"
    exit 1
  }
  log_step "集群列表已读取"

  if [[ "$KUBECONFIG_LIST" == true ]]; then
    echo "Rancher 集群列表"
    echo "────────────────────────────────────"
    printf '%s' "$clusters_json" | tulan_python k8s list-clusters
    exit 0
  fi

  [[ -n "$KUBECONFIG_CLUSTER" ]] || {
    tulan_error "请指定集群: brew k8s kubeconfig -c <名>  或  brew k8s kubeconfig --list"
    exit 1
  }

  if [[ "$KUBECONFIG_CLUSTER" == "local" ]]; then
    log_step "导出 local 集群 k3s.yaml"
    config="$(rancher_local_kubeconfig)"
    write_output "$config"
    exit 0
  fi

  log_step "步骤 2/4: 解析集群名「${KUBECONFIG_CLUSTER}」"
  cluster_id="$(printf '%s' "$clusters_json" | tulan_python k8s resolve-cluster --cluster "$KUBECONFIG_CLUSTER")"
  log_step "匹配到集群 ID: ${cluster_id}"

  rancher_url="$(pick_rancher_api_url)" || {
    tulan_error "无法确定 Rancher API 地址，请使用 --url https://..."
    exit 1
  }
  log_verbose "Rancher API: ${rancher_url}"

  config="$(fetch_downstream_kubeconfig "$cluster_id" "$rancher_url" "$clusters_json")"
  write_output "$config"
}

main "$@"
