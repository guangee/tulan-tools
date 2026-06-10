#!/usr/bin/env bash
# 构建并推送 tulan-binaries 镜像到 Docker Hub

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMAGE_NAME="${TULAN_DOCKER_IMAGE:-tulan/binaries}"
IMAGE_TAG="${TULAN_DOCKER_TAG:-latest}"
PLATFORMS="${TULAN_DOCKER_PLATFORMS:-linux/amd64,linux/arm64}"
PUSH=false
LOAD_LOCAL=false

usage() {
  cat <<EOF
构建 tulan-binaries Docker 镜像

用法:
  ./docker/build.sh [选项]

选项:
  --image NAME      镜像名，默认 tulan/binaries
  --tag TAG         标签，默认 latest
  --platforms LIST  目标平台，默认 linux/amd64,linux/arm64
  --push            构建后推送到 Docker Hub
  --load            仅构建当前平台并加载到本地（开发用）
  -h, --help        显示帮助

环境变量:
  TULAN_DOCKER_IMAGE   镜像名
  TULAN_DOCKER_TAG     标签

示例:
  # 本地构建（当前架构）
  ./docker/build.sh --load

  # 多平台构建并推送
  docker login
  ./docker/build.sh --push --image yourname/tulan-binaries --tag v1.0.0
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE_NAME="$2"; shift 2 ;;
    --tag) IMAGE_TAG="$2"; shift 2 ;;
    --platforms) PLATFORMS="$2"; shift 2 ;;
    --push) PUSH=true; shift ;;
    --load) LOAD_LOCAL=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

main() {
  if ! command -v docker &>/dev/null; then
    echo "错误: 需要 Docker" >&2
    exit 1
  fi

  cd "$PROJECT_ROOT"

  if [[ "$LOAD_LOCAL" == true ]]; then
    echo "本地构建: ${FULL_IMAGE}"
    docker build -f docker/Dockerfile -t "${FULL_IMAGE}" .
    echo "完成: ${FULL_IMAGE}"
    return 0
  fi

  if ! docker buildx version &>/dev/null; then
    echo "错误: 多平台构建需要 docker buildx" >&2
    exit 1
  fi

  local builder="tulan-buildx"
  if ! docker buildx inspect "$builder" &>/dev/null; then
    docker buildx create --name "$builder" --use
  else
    docker buildx use "$builder"
  fi

  local args=(
    build
    --platform "${PLATFORMS}"
    -f docker/Dockerfile
    -t "${FULL_IMAGE}"
  )

  if [[ "$PUSH" == true ]]; then
    args+=(--push)
    echo "构建并推送: ${FULL_IMAGE} (${PLATFORMS})"
  else
    args+=(--load)
    echo "构建（单平台加载）: ${FULL_IMAGE}"
  fi

  docker buildx "${args[@]}" .
  echo "完成: ${FULL_IMAGE}"
}

main "$@"
