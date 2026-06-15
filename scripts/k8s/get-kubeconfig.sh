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
  --url <url>         Rancher API 地址（默认用内网 register-url）
  -h, --help          显示帮助

示例:
  brew k8s kubeconfig --list
  brew k8s kubeconfig -c prod
  brew k8s kubeconfig -c c-m-abcdef -o ~/kube/prod.yaml
  brew k8s kubeconfig -c local -o ~/kube/local.yaml

说明:
  - 下游集群通过 Rancher /v3/clusters/{id}?action=generateKubeconfig 获取
  - local 集群直接导出容器内 /etc/rancher/k3s/k3s.yaml
  - 认证使用 Rancher 内置 k3s admin token（无需单独创建 API Key）
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

rancher_kubectl() {
  local container="${CONTAINER_NAME:-${TULAN_K8S_CONTAINER:-rancher}}"
  local kc="/etc/rancher/k3s/k3s.yaml"
  docker exec "$container" kubectl --kubeconfig "$kc" "$@"
}

rancher_admin_token() {
  local container="${CONTAINER_NAME:-${TULAN_K8S_CONTAINER:-rancher}}"
  local kc="/etc/rancher/k3s/k3s.yaml" token
  token="$(docker exec "$container" kubectl config view --kubeconfig "$kc" \
    -o jsonpath='{.users[0].user.token}' 2>/dev/null || true)"
  [[ -n "$token" ]] || {
    echo "无法读取 Rancher 内置 k3s admin token" >&2
    return 1
  }
  echo "$token"
}

rancher_local_kubeconfig() {
  local container="${CONTAINER_NAME:-${TULAN_K8S_CONTAINER:-rancher}}"
  docker exec "$container" cat /etc/rancher/k3s/k3s.yaml
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

main() {
  parse_args "$@"

  local container="${CONTAINER_NAME:-${TULAN_K8S_CONTAINER:-rancher}}"
  local clusters_json token rancher_url config try_url

  if ! command -v docker &>/dev/null; then
    echo "需要 Docker" >&2
    exit 1
  fi
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

  token="$(rancher_admin_token)" || exit 1
  rancher_url="$(pick_rancher_api_url)" || {
    echo "无法确定 Rancher API 地址，请使用 --url https://..." >&2
    exit 1
  }

  config=""
  for try_url in "$rancher_url"; do
    [[ -n "$try_url" ]] || continue
    if config="$(printf '%s' "$clusters_json" | tulan_python k8s kubeconfig \
      --cluster "$KUBECONFIG_CLUSTER" \
      --rancher-url "$try_url" \
      --token "$token" 2>/dev/null)"; then
      break
    fi
  done

  if [[ -z "$config" ]]; then
    printf '%s' "$clusters_json" | tulan_python k8s kubeconfig \
      --cluster "$KUBECONFIG_CLUSTER" \
      --rancher-url "$rancher_url" \
      --token "$token" || exit 1
  fi

  write_output "$config"
}

main "$@"
