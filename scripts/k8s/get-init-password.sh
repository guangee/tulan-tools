#!/usr/bin/env bash
# 从 Rancher 容器日志中提取初始密码（Bootstrap Password）
# 用法:
#   sudo bash get-init-password.sh
#
# 可选变量:
#   CONTAINER_NAME=rancher
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-rancher}"

if ! command -v docker >/dev/null 2>&1; then
  echo "未检测到 docker 命令。"
  exit 1
fi

if ! docker ps -a --format '{{.Names}}' | grep -Fxq "${CONTAINER_NAME}"; then
  echo "未找到容器: ${CONTAINER_NAME}"
  exit 1
fi

password_line="$(
  docker logs "${CONTAINER_NAME}" 2>&1 \
    | sed -n 's/.*Bootstrap Password:[[:space:]]*//p' \
    | tail -n 1
)"

if [[ -n "${password_line}" ]]; then
  echo "初始密码（Bootstrap Password）：${password_line}"
  exit 0
fi

echo "未在日志中找到 Bootstrap Password。"
echo "可尝试："
echo "1) 先确认 Rancher 已完成启动：docker logs ${CONTAINER_NAME} | tail -n 100"
echo "2) 若日志已滚动丢失，可进入容器重置管理员密码："
echo "   docker exec -it ${CONTAINER_NAME} reset-password"
exit 2
