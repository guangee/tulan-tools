#!/usr/bin/env bash
# Rancher 管理员密码：查看 Bootstrap / 重置 / 设置指定密码
#
# 用法:
#   brew k8s password
#   brew k8s password --set 'YourPassword'
#   brew k8s password --reset
#
# 可选变量:
#   CONTAINER_NAME=rancher
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-rancher}"
PASSWORD_ACTION="${PASSWORD_ACTION:-get}"
PASSWORD_VALUE="${PASSWORD_VALUE:-}"
PASSWORD_ASSUME_YES="${PASSWORD_ASSUME_YES:-false}"

usage() {
  cat <<EOF
用法: brew k8s password [选项]

  无参数              从容器日志读取 Bootstrap 初始密码
  --set <密码>        将 Rancher 管理员密码设为指定值（docker reset-password）
  --reset             交互式重置管理员密码（随机或手动输入，在容器内）
  -y, --yes           --set 时跳过确认
  -h, --help          显示帮助

说明:
  --set 通过容器内 reset-password 写入，适用于已初始化、需修改 admin 密码的场景。
  首次安装仍建议先用日志中的 Bootstrap Password 登录并完成向导。
  若管理员被删，可: docker exec -it ${CONTAINER_NAME} ensure-default-admin

示例:
  brew k8s password
  brew k8s password --set 'MySecurePass123' -y
  brew k8s password --reset
EOF
}

require_docker_container() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "未检测到 docker 命令。"
    exit 1
  fi
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "${CONTAINER_NAME}"; then
    if [[ "${EUID:-$(id -u)}" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
      if ! sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "${CONTAINER_NAME}"; then
        echo "Rancher 容器未运行: ${CONTAINER_NAME}"
        exit 1
      fi
      return 0
    fi
    echo "Rancher 容器未运行: ${CONTAINER_NAME}"
    exit 1
  fi
}

has_tty() {
  [[ -t 0 && -t 1 ]]
}

# 交互式 docker 必须保留 TTY；普通 sudo 会断开终端导致 reset-password 不等待输入
run_docker() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    docker "$@"
  elif command -v sudo >/dev/null 2>&1; then
    if has_tty; then
      sudo -t docker "$@"
    else
      sudo docker "$@"
    fi
  else
    docker "$@"
  fi
}

run_docker_stdin() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    docker "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo docker "$@"
  else
    docker "$@"
  fi
}

get_bootstrap_password() {
  local password_line
  password_line="$(
    run_docker logs "${CONTAINER_NAME}" 2>&1 \
      | sed -n 's/.*Bootstrap Password:[[:space:]]*//p' \
      | tail -n 1
  )"

  if [[ -n "${password_line}" ]]; then
    echo "初始密码（Bootstrap Password）：${password_line}"
    return 0
  fi

  echo "未在日志中找到 Bootstrap Password。"
  echo "可尝试："
  echo "  1) docker logs ${CONTAINER_NAME} | tail -n 100"
  echo "  2) brew k8s password --reset"
  echo "  3) brew k8s password --set '你的密码' -y"
  return 2
}

confirm_set_password() {
  if [[ "$PASSWORD_ASSUME_YES" == true ]]; then
    return 0
  fi
  if ! has_tty; then
    echo "当前无交互终端，请使用 -y 跳过确认: brew k8s password --set '密码' -y" >&2
    exit 1
  fi
  echo ""
  echo "将把 Rancher 管理员密码设置为指定值（容器: ${CONTAINER_NAME}）。"
  read -r -p "确认继续? [y/N]: " confirm
  [[ "$confirm" =~ ^[yY]$ ]]
}

set_admin_password() {
  local pass="$1"
  if [[ -z "$pass" ]]; then
    echo "请提供密码: brew k8s password --set 'YourPassword'" >&2
    exit 1
  fi
  if ((${#pass} < 8)); then
    echo "密码至少 8 位（Rancher 要求）。" >&2
    exit 1
  fi
  confirm_set_password || { echo "已取消"; exit 0; }

  echo "正在设置 Rancher 管理员密码..."
  # reset-password 从 stdin 读取新密码；勿用 sudo -t，避免与管道 stdin 冲突
  if printf '%s\n' "$pass" | run_docker_stdin exec -i "${CONTAINER_NAME}" reset-password 2>&1; then
    echo ""
    echo "管理员密码已更新。"
    echo "请使用 Rancher UI 登录（用户名一般为 admin 或 reset-password 输出中的 user-xxxxx）。"
    return 0
  fi

  echo ""
  echo "非交互设置失败，请尝试交互重置:"
  echo "  brew k8s password --reset"
  echo "  或: docker exec -it ${CONTAINER_NAME} reset-password"
  return 1
}

reset_password_interactive() {
  if ! has_tty; then
    echo "当前环境无交互终端（TTY），reset-password 无法等待你输入密码。" >&2
    echo "请在本机 SSH/终端中执行，或使用:" >&2
    echo "  brew k8s password --set '你的密码' -y" >&2
    echo "  docker exec -it ${CONTAINER_NAME} reset-password" >&2
    exit 1
  fi
  echo "进入容器交互 reset-password（按提示输入新密码）..."
  run_docker exec -it "${CONTAINER_NAME}" reset-password
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --set)
        PASSWORD_ACTION="set"
        PASSWORD_VALUE="${2:-}"
        [[ -n "$PASSWORD_VALUE" ]] || { echo "缺少 --set 参数" >&2; exit 1; }
        shift 2
        ;;
      --reset) PASSWORD_ACTION="reset"; shift ;;
      -y|--yes) PASSWORD_ASSUME_YES=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *)
        echo "未知参数: $1" >&2
        usage
        exit 1
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  require_docker_container

  case "$PASSWORD_ACTION" in
    get) get_bootstrap_password ;;
    set) set_admin_password "$PASSWORD_VALUE" ;;
    reset) reset_password_interactive ;;
    *)
      echo "未知操作: ${PASSWORD_ACTION}" >&2
      exit 1
      ;;
  esac
}

main "$@"
