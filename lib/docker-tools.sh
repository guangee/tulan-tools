#!/usr/bin/env bash
# Docker 工具容器管理

set -euo pipefail

tulan_docker_load_config() {
  local home
  home="$(tulan_get_home)"

  # 优先级: 环境变量 > .env > 默认值
  if [[ -f "${home}/.env" ]]; then
    # shellcheck source=/dev/null
    set -a
    source "${home}/.env"
    set +a
  elif [[ -f "${home}/docker-compose.yml" ]] && [[ -f "$(dirname "${home}")/.env" ]]; then
    :
  fi

  export TULAN_DOCKER_IMAGE="${TULAN_DOCKER_IMAGE:-tulan/binaries}"
  export TULAN_DOCKER_TAG="${TULAN_DOCKER_TAG:-latest}"
  export TULAN_DOCKER_CONTAINER="${TULAN_DOCKER_CONTAINER:-tulan-binaries}"
}

tulan_docker_full_image() {
  tulan_docker_load_config
  echo "${TULAN_DOCKER_IMAGE}:${TULAN_DOCKER_TAG}"
}

tulan_docker_compose_file() {
  local home
  home="$(tulan_get_home)"
  echo "${home}/docker-compose.yml"
}

tulan_docker_is_running() {
  tulan_docker_load_config
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "${TULAN_DOCKER_CONTAINER}"
}

tulan_docker_start() {
  tulan_docker_load_config

  if ! command -v docker &>/dev/null; then
    tulan_error "需要安装 Docker"
    return 1
  fi

  local compose_file
  compose_file="$(tulan_docker_compose_file)"

  if [[ ! -f "$compose_file" ]]; then
    tulan_error "未找到 docker-compose.yml: ${compose_file}"
    return 1
  fi

  if tulan_docker_is_running; then
    tulan_log "容器已在运行: ${TULAN_DOCKER_CONTAINER}"
    return 0
  fi

  tulan_log "启动容器: $(tulan_docker_full_image)"

  local env_file
  env_file="$(tulan_get_home)/.env"
  if [[ -f "$env_file" ]]; then
    docker compose -f "$compose_file" --env-file "$env_file" up -d
  else
    docker compose -f "$compose_file" up -d
  fi

  tulan_log "容器已启动，Apache: http://localhost:${TULAN_APACHE_PORT:-18080}"
}

tulan_docker_stop() {
  tulan_docker_load_config
  local compose_file
  compose_file="$(tulan_docker_compose_file)"

  docker compose -f "$compose_file" down 2>/dev/null || true
  tulan_log "容器已停止"
}

tulan_docker_exec() {
  local tool="$1"
  shift

  tulan_docker_load_config

  if ! command -v docker &>/dev/null; then
    tulan_error "需要安装 Docker"
    return 1
  fi

  if tulan_docker_is_running; then
    docker exec -it -w /workspace "${TULAN_DOCKER_CONTAINER}" "$tool" "$@"
  else
    # 容器未运行时，使用一次性 run
    tulan_log "容器未运行，使用 docker run --rm"
    docker run --rm -it \
      -v "${HOME}/.kube:/root/.kube:ro" \
      -v "${HOME}/.mc:/root/.mc" \
      -v "$(pwd):/workspace" \
      -w /workspace \
      "$(tulan_docker_full_image)" \
      "$tool" "$@"
  fi
}
