#!/usr/bin/env bash
# Rancher 管理员密码：查看 Bootstrap / 重置随机密码 / 设置指定密码
#
# 用法:
#   brew k8s password
#   brew k8s password --set 'YourPassword'
#   brew k8s password --reset
#
# 可选变量:
#   CONTAINER_NAME=rancher
#   RANCHER_KUBECONFIG=/etc/rancher/k3s/k3s.yaml
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-rancher}"
RANCHER_KUBECONFIG="${RANCHER_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
PASSWORD_ACTION="${PASSWORD_ACTION:-get}"
PASSWORD_VALUE="${PASSWORD_VALUE:-}"
PASSWORD_ASSUME_YES="${PASSWORD_ASSUME_YES:-false}"

usage() {
  cat <<EOF
用法: brew k8s password [选项]

  无参数              从容器日志读取 Bootstrap 初始密码
  --set <密码>        将管理员密码设为指定值（kubectl 写入 bcrypt 哈希）
  --reset             生成新的随机管理员密码（Rancher reset-password）
  -y, --yes           --set 时跳过确认
  -h, --help          显示帮助

说明:
  Rancher 自带的 reset-password 只会生成随机密码，不能指定密码。
  --set 通过 kubectl patch User 资源写入 bcrypt 哈希。
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

run_docker_stdin() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    docker "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo docker "$@"
  else
    docker "$@"
  fi
}

rancher_kubectl() {
  run_docker_stdin exec -i "${CONTAINER_NAME}" kubectl --kubeconfig "$RANCHER_KUBECONFIG" "$@"
}

# Rancher User.password 为 bcrypt（cost=10）
bcrypt_hash_password() {
  local pass="$1"
  local hash=""

  hash="$(python3 - "$pass" <<'PY' 2>/dev/null || true
import sys
passw = sys.argv[1]
try:
    import bcrypt
except ImportError:
    sys.exit(2)
print(bcrypt.hashpw(passw.encode(), bcrypt.gensalt(rounds=10)).decode())
PY
)"
  if [[ -n "$hash" ]]; then
    echo "$hash"
    return 0
  fi

  if command -v htpasswd >/dev/null 2>&1; then
    hash="$(htpasswd -bnBC 10 '' "$pass" 2>/dev/null | tr -d '\n\r' | sed 's/^://')"
    if [[ -n "$hash" && "$hash" == \$2* ]]; then
      echo "$hash"
      return 0
    fi
  fi

  hash="$(
    printf '%s' "$pass" | run_docker_stdin exec -i "${CONTAINER_NAME}" sh -c \
      'read -r p; command -v htpasswd >/dev/null || exit 2; htpasswd -bnBC 10 "" "$p" | tr -d "\n\r" | sed "s/^://"' \
      2>/dev/null || true
  )"
  if [[ -n "$hash" && "$hash" == \$2* ]]; then
    echo "$hash"
    return 0
  fi

  echo "无法生成 bcrypt 哈希。请在 master 安装其一:" >&2
  echo "  apt install apache2-utils    # 提供 htpasswd" >&2
  echo "  pip3 install bcrypt" >&2
  return 1
}

find_bootstrap_admin_user() {
  local name=""
  name="$(rancher_kubectl get users.management.cattle.io \
    -l authz.management.cattle.io/bootstrapping=admin-user \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$name" ]]; then
    echo "$name"
    return 0
  fi
  name="$(rancher_kubectl get users.management.cattle.io \
    -o jsonpath='{range .items[?(@.username=="admin")]}{.metadata.name}{end}' 2>/dev/null || true)"
  [[ -n "$name" ]] && echo "$name"
}

build_password_patch_json() {
  local hash="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$hash" <<'PY'
import json, sys
print(json.dumps({"password": sys.argv[1], "mustChangePassword": False}))
PY
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg p "$hash" '{password: $p, mustChangePassword: false}'
    return 0
  fi
  echo "需要 python3 或 jq 构建 patch JSON。" >&2
  return 1
}

get_bootstrap_password() {
  local password_line
  password_line="$(
    run_docker_stdin logs "${CONTAINER_NAME}" 2>&1 \
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
  local hash admin_name username patch_json

  if [[ -z "$pass" ]]; then
    echo "请提供密码: brew k8s password --set 'YourPassword'" >&2
    exit 1
  fi
  if ((${#pass} < 8)); then
    echo "密码至少 8 位（Rancher 要求）。" >&2
    exit 1
  fi
  confirm_set_password || { echo "已取消"; exit 0; }

  admin_name="$(find_bootstrap_admin_user)"
  if [[ -z "$admin_name" ]]; then
    echo "未找到 bootstrap 管理员用户。" >&2
    echo "可尝试: docker exec -it ${CONTAINER_NAME} ensure-default-admin" >&2
    exit 1
  fi

  echo "正在设置 Rancher 管理员密码（用户: ${admin_name}）..."
  hash="$(bcrypt_hash_password "$pass")" || exit 1
  patch_json="$(build_password_patch_json "$hash")" || exit 1

  if ! rancher_kubectl patch "users.management.cattle.io/${admin_name}" \
    --type=merge -p "$patch_json" >/dev/null; then
    echo "kubectl patch 失败，请检查 Rancher 容器内 kubectl 与 kubeconfig。" >&2
    exit 1
  fi

  username="$(rancher_kubectl get "users.management.cattle.io/${admin_name}" \
    -o jsonpath='{.username}' 2>/dev/null || true)"

  echo ""
  echo "管理员密码已设置为指定值。"
  echo "登录用户名: ${username:-admin}"
}

reset_password_random() {
  local output new_pass admin_hint

  echo "Rancher reset-password 将生成随机密码（不支持自行指定）..."
  output="$(run_docker_stdin exec -i "${CONTAINER_NAME}" reset-password 2>&1)" || {
    echo "$output" >&2
    exit 1
  }
  echo "$output"

  admin_hint="$(printf '%s\n' "$output" | sed -n 's/^New password for default admin user (\(.*\)):$/\1/p' | tail -n 1)"
  new_pass="$(printf '%s\n' "$output" | awk 'NF && $0 !~ /^New password for default admin user/ && $0 !~ /^W[0-9]/ { last=$0 } END { print last }')"

  if [[ -n "$new_pass" ]]; then
    echo ""
    echo "新随机密码: ${new_pass}"
    if [[ -n "$admin_hint" ]]; then
      echo "用户 ID: ${admin_hint}（登录名见 Rancher UI 或 users 资源 .username 字段）"
    fi
    echo "请保存并用于 Rancher UI 登录。"
  fi
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
    reset) reset_password_random ;;
    *)
      echo "未知操作: ${PASSWORD_ACTION}" >&2
      exit 1
      ;;
  esac
}

main "$@"
