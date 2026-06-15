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
# shellcheck source=../../lib/k8s.sh
source "${_SCRIPT_ROOT}/lib/k8s.sh"

KUBECONFIG_CLUSTER="${KUBECONFIG_CLUSTER:-}"
KUBECONFIG_OUTPUT="${KUBECONFIG_OUTPUT:-}"
KUBECONFIG_LIST="${KUBECONFIG_LIST:-false}"
KUBECONFIG_RANCHER_URL="${KUBECONFIG_RANCHER_URL:-}"
KUBECONFIG_TIMEOUT="${KUBECONFIG_TIMEOUT:-30}"
KUBECONFIG_VERBOSE="${KUBECONFIG_VERBOSE:-false}"
KUBECONFIG_USE_PUBLIC="${KUBECONFIG_USE_PUBLIC:-false}"
KUBECONFIG_LAN_URL="${KUBECONFIG_LAN_URL:-}"
KUBECONFIG_PUBLIC_URL="${KUBECONFIG_PUBLIC_URL:-}"
KUBECONFIG_CURRENT_URL="${KUBECONFIG_CURRENT_URL:-}"

usage() {
  cat <<'EOF'
用法: brew k8s kubeconfig [选项]

在 Rancher Server 主机上获取指定集群的 kubeconfig 内容（需 Rancher 容器运行中）。

选项:
  --list              列出所有集群（ID / 显示名 / 状态）
  -c, --cluster <名>  集群名：UI 显示名、c-m-xxx 或 local（必填，除非 --list）
  -o, --output <path> 写入文件（默认输出到 stdout）
  --url <url>         Rancher API 地址（默认用内网 IP，见 register-url）
  --public            使用域名/外网地址（默认走内网 IP）
  --timeout <秒>      单步操作超时（默认 30）
  -v, --verbose       输出步骤与认证尝试细节（默认静默，仅报错或写入提示）
  -h, --help          显示帮助

示例:
  brew k8s kubeconfig --list
  brew k8s kubeconfig -c prod -o ~/.kube/config
  brew k8s kubeconfig -c prod -v

说明:
  - 下游集群通过 Rancher /v3/clusters/{id}?action=generateKubeconfig 获取
  - local 集群直接导出容器内 /etc/rancher/k3s/k3s.yaml
  - 默认通过内网 IP 调用 Rancher API，并将 kubeconfig 中 server 地址替换为内网
  - 使用域名请加 --public
EOF
}

log_verbose() {
  [[ "$KUBECONFIG_VERBOSE" == true ]] || return 0
  tulan_log "[kubeconfig] $*"
}

log_result() {
  tulan_log "[kubeconfig] $*"
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
      --public)
        KUBECONFIG_USE_PUBLIC=true
        shift
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
  if [[ "${KUBECONFIG_USE_PUBLIC}" == true && -n "${KUBECONFIG_PUBLIC_URL:-}" ]]; then
    echo "$KUBECONFIG_PUBLIC_URL"
    return 0
  fi
  if [[ -n "${KUBECONFIG_LAN_URL:-}" ]]; then
    echo "$KUBECONFIG_LAN_URL"
    return 0
  fi
  local domain="${K8S_SITE_DOMAIN:-}" port="${HTTPS_PORT_MAP%%:*}" url
  if [[ -n "$domain" && -n "$port" ]]; then
    echo "https://${domain}:${port}"
    return 0
  fi
  url="$(tulan_k8s_rancher_read_server_url 2>/dev/null || true)"
  [[ -n "$url" ]] && echo "$url"
}

resolve_url_bundle() {
  local lan_ip domain https_port
  tulan_k8s_load_rancher_config 2>/dev/null || true
  if [[ -z "${K8S_SITE_DOMAIN:-}" ]]; then
    tulan_k8s_load_site_config 2>/dev/null || true
  fi
  domain="${K8S_SITE_DOMAIN:-}"
  https_port="$(tulan_k8s_rancher_https_host_port 2>/dev/null || echo "${HTTPS_PORT_MAP%%:*}")"
  lan_ip="$(tulan_k8s_resolve_lan_ip 2>/dev/null || true)"
  if [[ -n "$lan_ip" && -n "$https_port" ]]; then
    KUBECONFIG_LAN_URL="$(tulan_k8s_build_rancher_url "$lan_ip" "$https_port")"
  fi
  if [[ -n "$domain" && -n "$https_port" ]]; then
    KUBECONFIG_PUBLIC_URL="$(tulan_k8s_build_rancher_url "$domain" "$https_port")"
  fi
  KUBECONFIG_CURRENT_URL="$(tulan_k8s_rancher_read_server_url 2>/dev/null || true)"
}

rewrite_kubeconfig_lan() {
  local config="$1"
  if [[ "${KUBECONFIG_USE_PUBLIC}" == true || -z "${KUBECONFIG_LAN_URL:-}" ]]; then
    printf '%s' "$config"
    return 0
  fi
  log_verbose "将 kubeconfig server 地址替换为内网: ${KUBECONFIG_LAN_URL}"
  printf '%s' "$config" | tulan_python k8s rewrite-kubeconfig \
    --lan "$KUBECONFIG_LAN_URL" \
    --public "${KUBECONFIG_PUBLIC_URL:-}" \
    --current "${KUBECONFIG_CURRENT_URL:-}" \
    --domain "${K8S_SITE_DOMAIN:-}" \
    --port "$(tulan_k8s_rancher_https_host_port 2>/dev/null || echo "${HTTPS_PORT_MAP%%:*}")"
}

write_output() {
  local content="$1"
  if [[ -z "$content" ]] || ! grep -q 'apiVersion' <<<"$content"; then
    tulan_error "kubeconfig 内容无效，未写入文件"
    return 1
  fi
  if [[ -n "$KUBECONFIG_OUTPUT" ]]; then
    mkdir -p "$(dirname "$KUBECONFIG_OUTPUT")"
    printf '%s' "$content" >"$KUBECONFIG_OUTPUT"
    chmod 600 "$KUBECONFIG_OUTPUT" 2>/dev/null || true
    log_result "已写入: ${KUBECONFIG_OUTPUT}"
    return 0
  fi
  printf '%s' "$content"
}

# 从管理集群 Secret 直接读取下游 kubeconfig（不经过 Norman API）
fetch_kubeconfig_from_secret() {
  local cluster_id="$1"
  local container secret data_key out
  container="$(rancher_container)"

  for secret in kubeconfig full-kubeconfig cluster-kubeconfig; do
    for data_key in config value kubeconfig; do
      out="$(run_timeout "$KUBECONFIG_TIMEOUT" docker exec "$container" kubectl get secret "$secret" \
        -n "$cluster_id" -o "jsonpath={.data.${data_key}}" 2>/dev/null | base64 -d 2>/dev/null || true)"
      if [[ -n "$out" ]] && grep -q 'apiVersion' <<<"$out"; then
        log_verbose "从 secret ${cluster_id}/${secret} 读取成功"
        printf '%s' "$out"
        return 0
      fi
    done
  done
  return 1
}

# 获取 Rancher /v3 API 可用的 Bearer token（k3s client 证书不能用于 Norman API）
rancher_bearer_token() {
  local container
  container="$(rancher_container)"
  run_timeout 25 docker exec "$container" sh -s <<'EOS'
KCFG=/etc/rancher/k3s/k3s.yaml
export KUBECONFIG="$KCFG"

try_token() {
  token="$1"
  [ -n "$token" ] || return 1
  printf '%s' "$token"
  exit 0
}

token="$(kubectl config view --minify --raw -o jsonpath='{.users[0].user.token}' 2>/dev/null || true)"
try_token "$token" || true

if command -v timeout >/dev/null 2>&1; then
  KTC="timeout 8 kubectl create token"
else
  KTC="kubectl create token"
fi
for sa in cattle-admin default admin; do
  for ns in cattle-global-admin cattle-system kube-system; do
    token="$($KTC "$sa" -n "$ns" --duration=30m 2>/dev/null || true)"
    try_token "$token" || true
  done
done

for sa_secret in $(kubectl get sa -n kube-system -o jsonpath='{range .items[*]}{.secrets[0].name}{"\n"}{end}' 2>/dev/null); do
  [ -n "$sa_secret" ] || continue
  token="$(kubectl get secret -n kube-system "$sa_secret" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  try_token "$token" || true
done
exit 1
EOS
}

# 容器内调用 Norman API（Bearer token）
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

obtain_token() {
  token="$(kubectl config view --minify --raw -o jsonpath='{.users[0].user.token}' 2>/dev/null || true)"
  [ -n "$token" ] && { vlog "使用 kubeconfig 静态 token"; echo "$token"; return 0; }
  if command -v timeout >/dev/null 2>&1; then
    KTC="timeout 8 kubectl create token"
  else
    KTC="kubectl create token"
  fi
  for sa in cattle-admin default admin; do
    for ns in cattle-global-admin cattle-system kube-system; do
      token="$($KTC "$sa" -n "$ns" --duration=30m 2>/dev/null || true)"
      if [ -n "$token" ]; then
        vlog "使用 create token ${sa}@${ns}"
        echo "$token"
        return 0
      fi
    done
  done
  return 1
}

token="$(obtain_token 2>/dev/null || true)"
[ -n "$token" ] || { vlog "无法获取 Bearer token"; exit 1; }

for base in http://127.0.0.1 https://127.0.0.1 http://localhost https://localhost; do
  vlog "Norman API Bearer @ ${base}"
  if resp="$(post_api "$base" -H "Authorization: Bearer ${token}" 2>/dev/null || true)" && [ -n "$resp" ]; then
    printf '%s' "$resp"
    exit 0
  fi
done

vlog "容器内 Norman API 未成功"
exit 1
EOS
}

fetch_downstream_kubeconfig() {
  local cluster_id="$1" rancher_url="$2"
  local clusters_json="$3" resp token mgmt_kc py_timeout

  log_verbose "步骤 3/5: 从集群 Secret 读取（${cluster_id}）"
  if resp="$(fetch_kubeconfig_from_secret "$cluster_id" 2>/dev/null || true)" && [[ -n "$resp" ]]; then
    printf '%s' "$resp"
    return 0
  fi
  log_verbose "集群 Secret 未找到，尝试 Norman API"

  log_verbose "步骤 4/5: 容器内 Norman API（Bearer，超时 ${KUBECONFIG_TIMEOUT}s）"
  if resp="$(rancher_fetch_in_container "$cluster_id" 2>/dev/null || true)" && [[ -n "$resp" ]]; then
    log_verbose "容器内 API 成功"
    printf '%s' "$resp" | tulan_python k8s extract-config
    return 0
  fi
  log_verbose "容器内 API 未成功，改走宿主机 API"

  log_verbose "步骤 5/5: 宿主机 Norman API（${rancher_url}，Bearer token）"
  token="$(rancher_bearer_token 2>/dev/null || true)"
  if [[ -z "$token" ]]; then
    tulan_error "无法获取 Rancher API Bearer token（k3s client 证书不能用于 /v3 API）"
    return 1
  fi
  py_timeout="$KUBECONFIG_TIMEOUT"
  printf '%s' "$clusters_json" | tulan_python k8s kubeconfig \
    --cluster "$KUBECONFIG_CLUSTER" \
    --rancher-url "$rancher_url" \
    --token "$token" \
    --timeout "$py_timeout"
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

  log_verbose "步骤 1/5: 读取集群列表（容器 ${container}）"
  clusters_json="$(rancher_kubectl get clusters.management.cattle.io -o json 2>/dev/null)" || {
    tulan_error "无法读取集群列表（请确认 Rancher 已就绪；可用 -v 查看详情）"
    exit 1
  }
  log_verbose "集群列表已读取"

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
    log_verbose "导出 local 集群 k3s.yaml"
    config="$(rancher_local_kubeconfig)"
    write_output "$config"
    exit 0
  fi

  log_verbose "步骤 2/5: 解析集群名「${KUBECONFIG_CLUSTER}」"
  resolve_url_bundle
  cluster_id="$(printf '%s' "$clusters_json" | tulan_python k8s resolve-cluster --cluster "$KUBECONFIG_CLUSTER")"
  log_verbose "匹配到集群 ID: ${cluster_id}"

  rancher_url="$(pick_rancher_api_url)" || {
    tulan_error "无法确定 Rancher API 地址，请使用 --url https://..."
    exit 1
  }
  if [[ "${KUBECONFIG_USE_PUBLIC}" == true ]]; then
    log_verbose "Rancher API（外网/域名）: ${rancher_url}"
  else
    log_verbose "Rancher API（内网）: ${rancher_url}"
    [[ -n "${KUBECONFIG_PUBLIC_URL:-}" ]] && log_verbose "外网/域名（未使用）: ${KUBECONFIG_PUBLIC_URL}"
  fi

  config="$(fetch_downstream_kubeconfig "$cluster_id" "$rancher_url" "$clusters_json")" || exit 1
  config="$(rewrite_kubeconfig_lan "$config")" || exit 1
  write_output "$config" || exit 1
}

main "$@"
