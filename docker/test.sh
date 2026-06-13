#!/usr/bin/env bash
# 构建并测试各发行版 Docker 镜像

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v docker &>/dev/null; then
  echo "错误: 未找到 docker 命令" >&2
  exit 1
fi

declare -A IMAGES=(
  [ubuntu-22.04]="docker/ubuntu/22.04/Dockerfile"
  [ubuntu-24.04]="docker/ubuntu/24.04/Dockerfile"
  [ubuntu-26.04]="docker/ubuntu/26.04/Dockerfile"
  [debian-12]="docker/debian/12/Dockerfile"
  [centos-7.8]="docker/centos/7.8/Dockerfile"
  [centos-7.9]="docker/centos/7.9/Dockerfile"
)

TARGET="${1:-all}"
FAILED=0
PASSED=0

run_one() {
  local name="$1" dockerfile="$2"
  local tag="tulan-tools-test:${name}"

  echo ""
  echo "════════════════════════════════════════"
  echo "构建并测试: ${name}"
  echo "  Dockerfile: ${dockerfile}"
  echo "════════════════════════════════════════"

  if ! docker build -f "$dockerfile" -t "$tag" . ; then
    echo "✗ 构建失败: ${name}" >&2
    FAILED=$((FAILED + 1))
    return 1
  fi

  if docker run --rm --cap-add SYS_TIME "$tag"; then
    echo "✓ 测试通过: ${name}"
    PASSED=$((PASSED + 1))
  else
    echo "✗ 测试失败: ${name}" >&2
    FAILED=$((FAILED + 1))
    return 1
  fi
}

if [[ "$TARGET" == "all" ]]; then
  for name in "${!IMAGES[@]}"; do
    run_one "$name" "${IMAGES[$name]}" || true
  done
elif [[ -n "${IMAGES[$TARGET]+x}" ]]; then
  run_one "$TARGET" "${IMAGES[$TARGET]}"
else
  echo "未知目标: ${TARGET}" >&2
  echo "可用: all ${!IMAGES[*]}" >&2
  exit 1
fi

echo ""
echo "结果: 通过 ${PASSED}，失败 ${FAILED}"
[[ "$FAILED" -eq 0 ]]
