#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# 节点注册 URL 与命令
tulan_k8s_resolve_lan_ip() {
  tulan_k8s_load_rancher_config
  if [[ -z "${K8S_SITE_IP:-}" ]]; then
    tulan_k8s_load_site_config
  fi
  if [[ -n "${K8S_REGISTER_IP:-}" ]]; then
    echo "$K8S_REGISTER_IP"
    return 0
  fi
  if [[ -n "${K8S_SITE_IP:-}" ]]; then
    echo "$K8S_SITE_IP"
    return 0
  fi
  tulan_k8s_detect_lan_ip
}

tulan_k8s_rancher_https_host_port() {
  tulan_k8s_host_port_from_map "${HTTPS_PORT_MAP:-${TULAN_K8S_HTTPS_PORT}}"
}

tulan_k8s_build_rancher_url() {
  local host="$1" port="${2:-}"
  [[ -n "$port" ]] || port="$(tulan_k8s_rancher_https_host_port)"
  echo "https://${host}:${port}"
}

tulan_k8s_rancher_kubeconfig() {
  echo "/etc/rancher/k3s/k3s.yaml"
}

tulan_k8s_rancher_read_server_url() {
  local container="${CONTAINER_NAME:-${TULAN_K8S_CONTAINER}}" kc url
  if ! command -v docker &>/dev/null; then
    return 1
  fi
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$container"; then
    return 1
  fi
  kc="$(tulan_k8s_rancher_kubeconfig)"
  url="$(docker exec "$container" kubectl get settings.management.cattle.io server-url \
    -o jsonpath='{.value}' --kubeconfig "$kc" 2>/dev/null || true)"
  if [[ -z "$url" ]]; then
    url="$(docker exec "$container" kubectl get setting server-url \
      -o jsonpath='{.value}' --kubeconfig "$kc" 2>/dev/null || true)"
  fi
  [[ -n "$url" ]] && echo "$url"
}

tulan_k8s_rancher_set_server_url() {
  local url="$1" container="${CONTAINER_NAME:-${TULAN_K8S_CONTAINER}}" kc patch
  kc="$(tulan_k8s_rancher_kubeconfig)"
  patch="$(printf '{"value":"%s"}' "$url")"
  docker exec "$container" kubectl patch settings.management.cattle.io server-url \
    --type merge -p "$patch" --kubeconfig "$kc"
}

tulan_k8s_register_url_bundle() {
  local lan_ip domain https_port lan_url public_url current_url

  tulan_k8s_require_rancher_config || return 1

  domain="${K8S_SITE_DOMAIN:-}"
  https_port="$(tulan_k8s_rancher_https_host_port)"
  lan_ip="$(tulan_k8s_resolve_lan_ip)" || {
    tulan_error "无法检测局域网 IP，请使用 --ip 指定"
    return 1
  }

  lan_url="$(tulan_k8s_build_rancher_url "$lan_ip" "$https_port")"
  public_url="$(tulan_k8s_build_rancher_url "$domain" "$https_port")"
  current_url="$(tulan_k8s_rancher_read_server_url 2>/dev/null || true)"

  REGISTER_URL_LAN_IP="$lan_ip"
  REGISTER_URL_DOMAIN="$domain"
  REGISTER_URL_HTTPS_PORT="$https_port"
  REGISTER_URL_LAN="$lan_url"
  REGISTER_URL_PUBLIC="$public_url"
  REGISTER_URL_CURRENT="${current_url:-}"
  export REGISTER_URL_LAN_IP REGISTER_URL_DOMAIN REGISTER_URL_HTTPS_PORT
  export REGISTER_URL_LAN REGISTER_URL_PUBLIC REGISTER_URL_CURRENT
}

tulan_k8s_print_register_url() {
  local mode="${1:-lan}" format="${2:-text}"

  tulan_k8s_register_url_bundle || return 1

  case "$format" in
    url)
      if [[ "$mode" == "public" || "$mode" == "domain" ]]; then
        echo "$REGISTER_URL_PUBLIC"
      else
        echo "$REGISTER_URL_LAN"
      fi
      ;;
    json)
      printf '{"lan_ip":"%s","domain":"%s","https_port":%s,"lan_url":"%s","public_url":"%s"' \
        "$REGISTER_URL_LAN_IP" "$REGISTER_URL_DOMAIN" "$REGISTER_URL_HTTPS_PORT" \
        "$REGISTER_URL_LAN" "$REGISTER_URL_PUBLIC"
      if [[ -n "$REGISTER_URL_CURRENT" ]]; then
        printf ',"rancher_server_url":"%s"' "$REGISTER_URL_CURRENT"
      fi
      echo '}'
      ;;
    *)
      echo "Rancher 节点注册地址"
      echo "────────────────────────────────────"
      echo "  内网（推荐）: ${REGISTER_URL_LAN}"
      echo "  外网/域名:    ${REGISTER_URL_PUBLIC}"
      if [[ -n "$REGISTER_URL_CURRENT" ]]; then
        echo "  Rancher 当前 server-url: ${REGISTER_URL_CURRENT}"
        if [[ "$REGISTER_URL_CURRENT" == "$REGISTER_URL_LAN" ]]; then
          echo ""
          echo "  说明: server-url 已是内网，但 UI 注册命令可能仍显示外网域名"
          echo "        （token 创建时写入，或 UI 使用浏览器访问域名生成）。"
          echo "        请执行: brew k8s register-command  获取替换后的内网注册命令"
        elif [[ "$REGISTER_URL_CURRENT" != "$REGISTER_URL_LAN" ]]; then
          echo ""
          echo "  提示: server-url 与内网地址不一致。"
          echo "        可执行: brew k8s register-url --set -y"
        fi
      fi
      echo ""
      echo "  获取内网注册命令: brew k8s register-command"
      echo "  自签证书集群请优先使用 register-command 输出的 insecure 命令。"
      if [[ "$mode" == "lan" || "$mode" == "internal" ]]; then
        echo ""
        echo "  内网 URL（可复制）: ${REGISTER_URL_LAN}"
      fi
      ;;
  esac
}

tulan_k8s_rancher_kubectl() {
  local container="${CONTAINER_NAME:-${TULAN_K8S_CONTAINER}}" kc
  kc="$(tulan_k8s_rancher_kubeconfig)"
  docker exec "$container" kubectl "$@" --kubeconfig "$kc"
}

tulan_k8s_confirm_refresh_registration_tokens() {
  local cluster="$1"
  if [[ "${TULAN_K8S_REGISTER_SET_YES:-false}" == true ]]; then
    return 0
  fi
  echo ""
  echo "将删除 ClusterRegistrationToken 并由 Rancher 重建（注册命令会重新生成）"
  if [[ -n "$cluster" ]]; then
    echo "  目标集群: ${cluster}"
  else
    echo "  目标: 全部集群"
  fi
  echo ""
  read -r -p "确认刷新? [y/N]: " confirm
  [[ "$confirm" =~ ^[yY]$ ]]
}

tulan_k8s_cluster_display_json() {
  tulan_k8s_rancher_kubectl get clusters.management.cattle.io -o json 2>/dev/null \
    | tulan_python k8s cluster-display 2>/dev/null || echo "{}"
}

tulan_k8s_list_registration_clusters() {
  local json="${1:-}" display_json
  if [[ -z "$json" ]]; then
    json="$(tulan_k8s_rancher_kubectl get clusterregistrationtokens.management.cattle.io -A -o json 2>/dev/null)" || return 1
  fi
  display_json="$(tulan_k8s_cluster_display_json)"
  printf '%s' "$json" | tulan_python k8s list-tokens --display-json "$display_json"
}

tulan_k8s_refresh_registration_tokens() {
  local cluster="${1:-}" json
  tulan_k8s_confirm_refresh_registration_tokens "$cluster" || {
    tulan_log "已取消"
    return 1
  }

  json="$(tulan_k8s_rancher_kubectl get clusterregistrationtokens.management.cattle.io -A -o json 2>/dev/null)" || {
    tulan_error "无法读取 ClusterRegistrationToken"
    return 1
  }

  local display_json
  display_json="$(tulan_k8s_cluster_display_json)"

  local ns name count=0
  while IFS=$'\t' read -r ns name; do
    [[ -n "$ns" && -n "$name" ]] || continue
    tulan_log "删除 token: ${ns}/${name}"
    tulan_k8s_rancher_kubectl delete clusterregistrationtoken "$name" -n "$ns" --wait=false
    count=$((count + 1))
  done < <(
    printf '%s' "$json" | tulan_python k8s tokens-delete \
      --cluster "$cluster" \
      --display-json "$display_json"
  )

  if (( count == 0 )); then
    tulan_error "未找到匹配的 ClusterRegistrationToken${cluster:+（过滤: ${cluster}）}"
    tulan_log "当前 Rancher 中可用的 registration token："
    tulan_k8s_list_registration_clusters "$json" || true
    tulan_log "可省略 -c 查看全部；UI 显示名（如 prod）与内部 ID（c-m-xxx）均可用于 -c"
    return 1
  fi

  tulan_log "等待 Rancher 重建 token（最多 60s）..."
  local i
  for i in $(seq 1 30); do
    if tulan_k8s_rancher_kubectl get clusterregistrationtokens.management.cattle.io -A \
      -o jsonpath='{range .items[*]}{.status.nodeCommand}{.status.insecureNodeCommand}{.status.command}{end}' 2>/dev/null \
      | grep -q 'https\?://'; then
      tulan_log "token 已重建"
      return 0
    fi
    sleep 2
  done
  tulan_log "等待超时，仍将尝试读取现有 token"
}

tulan_k8s_print_register_command() {
  local cluster="${1:-}" refresh="${2:-false}" format="${3:-text}" json rc

  tulan_k8s_require_linux || return 1
  tulan_k8s_require_docker || return 1
  tulan_k8s_register_url_bundle || return 1

  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "${CONTAINER_NAME:-${TULAN_K8S_CONTAINER}}"; then
    tulan_error "Rancher 容器未运行"
    return 1
  fi

  if [[ "$refresh" == true ]]; then
    tulan_k8s_refresh_registration_tokens "$cluster" || return 1
  fi

  json="$(tulan_k8s_rancher_kubectl get clusterregistrationtokens.management.cattle.io -A -o json 2>/dev/null)" || {
    tulan_error "无法读取 ClusterRegistrationToken（请确认 Rancher 已就绪）"
    return 1
  }

  local display_json
  display_json="$(tulan_k8s_cluster_display_json)"

  printf '%s' "$json" | tulan_python k8s register-command \
    --display-json "$display_json" \
    --cluster "$cluster" \
    --lan "$REGISTER_URL_LAN" \
    --public "$REGISTER_URL_PUBLIC" \
    --current "$REGISTER_URL_CURRENT" \
    --domain "$REGISTER_URL_DOMAIN" \
    --port "$REGISTER_URL_HTTPS_PORT" \
    --extra-from "${K8S_REGISTER_EXTRA_FROM_URL:-}" \
    --format "$format"
  rc=$?
  if (( rc == 2 )); then
    tulan_error "未找到 ClusterRegistrationToken${cluster:+（过滤: ${cluster}）}"
    tulan_log "当前 Rancher 中可用的 registration token："
    tulan_k8s_list_registration_clusters "$json" || true
    tulan_log "请使用: brew k8s register-command -c <集群名>  （UI 显示名或 c-m-xxx 均可）"
    return 1
  fi
  return "$rc"
}

tulan_k8s_confirm_set_register_url() {
  local url="$1"
  if [[ "${TULAN_K8S_REGISTER_SET_YES:-false}" == true ]]; then
    return 0
  fi
  echo ""
  echo "将 Rancher server-url 设置为内网地址（影响新节点注册命令）"
  echo "────────────────────────────────────"
  echo "  ${url}"
  echo ""
  read -r -p "确认修改? [y/N]: " confirm
  [[ "$confirm" =~ ^[yY]$ ]]
}

tulan_k8s_set_register_url() {
  local url
  tulan_k8s_require_linux || return 1
  tulan_k8s_require_docker || return 1
  tulan_k8s_register_url_bundle || return 1
  url="$REGISTER_URL_LAN"
  tulan_k8s_confirm_set_register_url "$url" || { tulan_log "已取消"; return 1; }
  tulan_k8s_rancher_set_server_url "$url" || {
    tulan_error "设置 server-url 失败（请确认 Rancher 容器已就绪）"
    return 1
  }
  tulan_log "已将 Rancher server-url 设置为: ${url}"
  tulan_log "请执行 brew k8s register-command 获取内网注册命令（UI 中 token 可能仍显示外网域名）"
}
