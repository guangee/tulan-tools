#!/usr/bin/env bash
# Rancher / K8s 单机部署脚本路径与公共函数

set -euo pipefail

TULAN_K8S_DIR="${TULAN_K8S_DIR:-$(tulan_get_home)/k8s-init}"
TULAN_K8S_CERT_OUT="${TULAN_K8S_CERT_OUT:-/etc/certs}"
TULAN_K8S_RANCHER_DATA="${TULAN_K8S_RANCHER_DATA:-/opt/rancher-data}"
TULAN_K8S_RANCHER_IMAGE="${TULAN_K8S_RANCHER_IMAGE:-rancher/rancher:v2.8.5}"
TULAN_K8S_REGISTRY_MIRROR="${TULAN_K8S_REGISTRY_MIRROR:-${TULAN_DOCKER_REGISTRY_MIRROR:-https://hub.coding-space.cn}}"
TULAN_K8S_CONTAINER="${TULAN_K8S_CONTAINER:-rancher}"
TULAN_K8S_HTTP_PORT="${TULAN_K8S_HTTP_PORT:-8080:80}"
TULAN_K8S_HTTPS_PORT="${TULAN_K8S_HTTPS_PORT:-8443:443}"

tulan_k8s_dir() {
  echo "$TULAN_K8S_DIR"
}

tulan_k8s_require_linux() {
  if [[ "$(uname -s | tr '[:upper:]' '[:lower:]')" != "linux" ]]; then
    tulan_error "K8s/Rancher 部署目前仅支持 Linux"
    return 1
  fi
}

tulan_k8s_require_docker() {
  if ! command -v docker &>/dev/null; then
    tulan_error "需要 Docker，请先执行: brew install docker"
    return 1
  fi
}

tulan_k8s_export_env() {
  export CERT_OUT="$TULAN_K8S_CERT_OUT"
  export RANCHER_DATA="$TULAN_K8S_RANCHER_DATA"
  export RANCHER_IMAGE="$TULAN_K8S_RANCHER_IMAGE"
  export REGISTRY_MIRROR="$TULAN_K8S_REGISTRY_MIRROR"
  export CONTAINER_NAME="$TULAN_K8S_CONTAINER"
  export HTTP_PORT_MAP="$TULAN_K8S_HTTP_PORT"
  export HTTPS_PORT_MAP="$TULAN_K8S_HTTPS_PORT"
  export K8S_REGISTRIES_TEMPLATE
  K8S_REGISTRIES_TEMPLATE="$(tulan_get_home)/config/k8s.registries.yaml"
}

tulan_k8s_script_path() {
  local name="$1"
  local path
  path="$(tulan_k8s_dir)/${name}"
  if [[ ! -f "$path" ]]; then
    tulan_error "缺少 K8s 脚本: ${path}"
    tulan_log "请先 brew update 或确认 k8s-init 目录存在"
    return 1
  fi
  echo "$path"
}

tulan_k8s_run() {
  local script="$1"
  shift
  local path
  tulan_k8s_require_linux || return 1
  path="$(tulan_k8s_script_path "$script")" || return 1
  tulan_k8s_export_env
  tulan_log "执行: ${script} $*"
  tulan_as_root bash "$path" "$@"
}

tulan_k8s_run_user() {
  local script="$1"
  shift
  local path
  path="$(tulan_k8s_script_path "$script")" || return 1
  tulan_k8s_export_env
  tulan_log "执行: ${script} $*"
  bash "$path" "$@"
}

tulan_k8s_show_status() {
  tulan_k8s_require_linux || return 1
  tulan_k8s_require_docker || return 1

  echo "Rancher / K8s 状态"
  echo "────────────────────────────────────"
  echo "  脚本目录: $(tulan_k8s_dir)"
  echo "  证书目录: ${TULAN_K8S_CERT_OUT}"
  echo "  数据目录: ${TULAN_K8S_RANCHER_DATA}"
  echo "  镜像:     ${TULAN_K8S_RANCHER_IMAGE}"
  echo "  镜像源:   ${TULAN_K8S_REGISTRY_MIRROR}"
  echo ""

  if docker ps -a --filter "name=${TULAN_K8S_CONTAINER}" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null | grep -q .; then
    docker ps -a --filter "name=${TULAN_K8S_CONTAINER}" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
  else
    echo "  容器 ${TULAN_K8S_CONTAINER}: 未运行"
  fi
}
