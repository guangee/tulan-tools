#!/usr/bin/env bash
# 获取 Rancher 指定下游集群的 kubeconfig
#
# 用法:
#   brew k8s kubeconfig --list
#   brew k8s kubeconfig -c mycluster
#   brew k8s kubeconfig -c mycluster -o ~/.kube/mycluster.yaml

set -euo pipefail

KUBECONFIG_CLUSTER="${KUBECONFIG_CLUSTER:-}"
KUBECONFIG_OUTPUT="${KUBECONFIG_OUTPUT:-}"
KUBECONFIG_LIST="${KUBECONFIG_LIST:-false}"
KUBECONFIG_RANCHER_URL="${KUBECONFIG_RANCHER_URL:-}"

usage() {
  cat <<'EOF'
用法: brew k8s kubeconfig [选项]

在 Rancher Server 主机上获取指定集群的 kubeconfig 内容（需 Rancher 容器运行中）。

选项:
  --list              列出所有集群（ID / 显示名 / 状态）
  -c, --cluster <名>  集群名：UI 显示名、c-m-xxx 或 local（必填，除非 --list）
  -o, --output <path> 写入文件（默认输出到 stdout）
  --url <url>         Rancher API 地址（默认从 rancher.env / server-url 读取）
  -h, --help          显示帮助

示例:
  brew k8s kubeconfig --list
  brew k8s kubeconfig -c prod
  brew k8s kubeconfig -c c-m-abcdef -o ~/kube/prod.yaml
  brew k8s kubeconfig -c local -o ~/kube/local.yaml

说明:
  - 下游集群通过 Rancher /v3/clusters/{id}?action=generateKubeconfig 获取
  - local 集群直接导出容器内 /etc/rancher/k3s/k3s.yaml
  - 认证优先使用 k3s.yaml 中的 client 证书（新版 k3s 默认无 token）
EOF
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
  docker exec "$container" kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml "$@"
}

rancher_local_kubeconfig() {
  docker exec "$(rancher_container)" cat /etc/rancher/k3s/k3s.yaml
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
    echo "已写入: ${KUBECONFIG_OUTPUT}" >&2
    return 0
  fi
  printf '%s' "$content"
}

# 在 Rancher 容器内调用 Norman API（优先 localhost，适配无 token 的 client 证书 kubeconfig）
rancher_fetch_in_container() {
  local cluster_id="$1"
  local container
  container="$(rancher_container)"
  docker exec "$container" sh -s "$cluster_id" <<'EOS'
set -e
CLUSTER_ID="$1"
KCFG=/etc/rancher/k3s/k3s.yaml
export KUBECONFIG="$KCFG"

post_api() {
  base="$1"
  shift
  curl -sfk -X POST \
    -H "Content-Type: application/json" \
    -d '{}' \
    "$@" \
    "${base}/v3/clusters/${CLUSTER_ID}?action=generateKubeconfig"
}

try_bearer() {
  token="$1"
  base="$2"
  [ -n "$token" ] || return 1
  post_api "$base" -H "Authorization: Bearer ${token}"
}

# 1) kubeconfig 内 token（旧版 k3s）
token="$(kubectl config view --minify --raw -o jsonpath='{.users[0].user.token}' 2>/dev/null || true)"

# 2) kubectl create token（新版 k3s 无静态 token 时）
if [ -z "$token" ]; then
  for sa in default cattle-admin admin; do
    for ns in kube-system cattle-system cattle-global-admin; do
      token="$(kubectl create token "$sa" -n "$ns" --duration=15m 2>/dev/null || true)"
      [ -n "$token" ] && break 2
    done
  done
fi

for base in http://127.0.0.1 https://127.0.0.1 http://localhost https://localhost; do
  if [ -n "$token" ]; then
    if resp="$(try_bearer "$token" "$base" 2>/dev/null || true)" && [ -n "$resp" ]; then
      printf '%s' "$resp"
      exit 0
    fi
  fi
done

# 3) k3s admin 客户端证书（新版默认）
for base in http://127.0.0.1 https://127.0.0.1; do
  for crt in \
    /var/lib/rancher/k3s/server/tls/client-admin.crt \
    /var/lib/rancher/k3s/server/tls/client-kube-apiserver.crt; do
    key="${crt%.crt}.key"
    [ -f "$crt" ] || continue
    [ -f "$key" ] || continue
    if resp="$(post_api "$base" --cert "$crt" --key "$key" 2>/dev/null || true)" && [ -n "$resp" ]; then
      printf '%s' "$resp"
      exit 0
    fi
  done
done

exit 1
EOS
}

fetch_downstream_kubeconfig() {
  local cluster_id="$1" rancher_url="$2"
  local clusters_json="$3" resp mgmt_kc tmp

  if resp="$(rancher_fetch_in_container "$cluster_id" 2>/dev/null || true)" && [[ -n "$resp" ]]; then
    printf '%s' "$resp" | tulan_python k8s extract-config
    return 0
  fi

  mgmt_kc="$(mktemp)"
  rancher_local_kubeconfig >"$mgmt_kc"

  printf '%s' "$clusters_json" | tulan_python k8s kubeconfig \
    --cluster "$KUBECONFIG_CLUSTER" \
    --rancher-url "$rancher_url" \
    --mgmt-kubeconfig-file "$mgmt_kc"
  rm -f "$mgmt_kc"
}

main() {
  parse_args "$@"

  local container clusters_json cluster_id rancher_url config

  if ! command -v docker &>/dev/null; then
    echo "需要 Docker" >&2
    exit 1
  fi
  container="$(rancher_container)"
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$container"; then
    echo "Rancher 容器未运行: ${container}" >&2
    exit 1
  fi

  clusters_json="$(rancher_kubectl get clusters.management.cattle.io -o json 2>/dev/null)" || {
    echo "无法读取集群列表（请确认 Rancher 已就绪）" >&2
    exit 1
  }

  if [[ "$KUBECONFIG_LIST" == true ]]; then
    echo "Rancher 集群列表"
    echo "────────────────────────────────────"
    printf '%s' "$clusters_json" | tulan_python k8s list-clusters
    exit 0
  fi

  [[ -n "$KUBECONFIG_CLUSTER" ]] || {
    echo "请指定集群: brew k8s kubeconfig -c <名>  或  brew k8s kubeconfig --list" >&2
    exit 1
  }

  if [[ "$KUBECONFIG_CLUSTER" == "local" ]]; then
    config="$(rancher_local_kubeconfig)"
    write_output "$config"
    exit 0
  fi

  rancher_url="$(pick_rancher_api_url)" || {
    echo "无法确定 Rancher API 地址，请使用 --url https://..." >&2
    exit 1
  }

  cluster_id="$(printf '%s' "$clusters_json" | tulan_python k8s resolve-cluster --cluster "$KUBECONFIG_CLUSTER")"

  config="$(fetch_downstream_kubeconfig "$cluster_id" "$rancher_url" "$clusters_json")"
  write_output "$config"
}

main "$@"
