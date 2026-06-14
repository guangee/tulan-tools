#!/usr/bin/env bash
# Rancher 单机 K8s 快捷安装（k8s-init）

set -euo pipefail

_SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${_SCRIPT_ROOT}/lib/common.sh"
# shellcheck source=../lib/k8s.sh
source "${_SCRIPT_ROOT}/lib/k8s.sh"

TULAN_HOME="$(tulan_get_home)"
ACTION="install"
EXTRA_ARGS=()

usage() {
  cat <<EOF
用法: brew k8s [子命令] [选项/参数]

子命令:
  install           安装并启动 Rancher（Docker，默认）
  ca                生成自签 CA 与站点证书
  password          从容器日志获取 Bootstrap 初始密码
  upgrade           升级 Rancher 镜像版本
  clean             清理 Rancher/K3s/RKE2 组件与数据（危险）
  sync-registries   同步 registries.yaml 到节点清单（见 k8s-init/sync-registries.sh -h）
  shell-init        配置 crictl/kubectl 别名（写入 ~/.zshrc）
  status            查看 Rancher 容器与配置
  legacy-run        旧版 run-k8s.sh（Rancher v2.5.17，容器名 k8s）

环境变量:
  TULAN_K8S_CERT_OUT          证书目录，默认 /etc/certs
  TULAN_K8S_RANCHER_DATA      数据目录，默认 /opt/rancher-data
  TULAN_K8S_RANCHER_IMAGE     Rancher 镜像，默认 rancher/rancher:v2.8.5
  TULAN_K8S_REGISTRY_MIRROR   镜像加速，默认 TULAN_DOCKER_REGISTRY_MIRROR
  TULAN_K8S_HTTP_PORT         默认 8080:80
  TULAN_K8S_HTTPS_PORT        默认 8443:443

说明:
  脚本目录: ${TULAN_HOME}/k8s-init/
  详细文档: ${TULAN_HOME}/k8s-init/README.md
  install/ca/clean/upgrade 需要 root 或 sudo

示例:
  brew k8s ca
  brew k8s install
  brew k8s password
  brew k8s sync-registries -f nodes.txt
  REGISTRY_MIRROR=https://hub.example.com brew k8s install
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    install) ACTION="install"; shift ;;
    ca|cert|certs) ACTION="ca"; shift ;;
    password|pwd) ACTION="password"; shift ;;
    upgrade|up) ACTION="upgrade"; shift ;;
    clean|reset) ACTION="clean"; shift ;;
    sync-registries|sync) ACTION="sync-registries"; shift ;;
    shell-init|k3s-init|init-shell) ACTION="shell-init"; shift ;;
    status) ACTION="status"; shift ;;
    legacy-run|run) ACTION="legacy-run"; shift ;;
    -h|--help|help) usage; exit 0 ;;
    -*) EXTRA_ARGS+=("$1"); shift ;;
    *) EXTRA_ARGS+=("$1"); shift ;;
  esac
done

main() {
  case "$ACTION" in
    install)
      tulan_require_privilege || exit 1
      tulan_k8s_run install.sh
      ;;
    ca)
      tulan_require_privilege || exit 1
      tulan_k8s_run ca.sh
      ;;
    password)
      tulan_k8s_run get-init-password.sh
      ;;
    upgrade)
      tulan_require_privilege || exit 1
      tulan_k8s_run upgrade.sh
      ;;
    clean)
      tulan_require_privilege || exit 1
      tulan_k8s_run clean.sh
      ;;
    sync-registries)
      tulan_k8s_run_user sync-registries.sh "${EXTRA_ARGS[@]}"
      ;;
    shell-init)
      tulan_k8s_run_user k3s-command-init.sh
      ;;
    status)
      tulan_k8s_show_status
      ;;
    legacy-run)
      tulan_require_privilege || exit 1
      tulan_k8s_run run-k8s.sh
      ;;
    *)
      tulan_error "未知子命令: ${ACTION}"
      usage
      exit 1
      ;;
  esac
}

main "$@"
