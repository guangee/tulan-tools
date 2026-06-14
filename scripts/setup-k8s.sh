#!/usr/bin/env bash
# Rancher 单机 K8s 快捷安装（scripts/k8s）

set -euo pipefail

_SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${_SCRIPT_ROOT}/lib/common.sh"
# shellcheck source=../lib/k8s.sh
source "${_SCRIPT_ROOT}/lib/k8s.sh"

TULAN_HOME="$(tulan_get_home)"
ACTION="install"
EXTRA_ARGS=()
CA_ASSUME_YES=false

usage() {
  cat <<EOF
用法: brew k8s [子命令] [选项/参数]

子命令:
  install           安装并启动 Rancher（Docker，默认）
  ca                生成自签 CA 与站点证书（交互式输入域名，自动检测局域网 IP）
  ca-clean          清理自签 CA 与站点证书（不清理 Rancher 容器）
  password          从容器日志获取 Bootstrap 初始密码
  upgrade           升级 Rancher 镜像版本
  clean             清理 Rancher/K3s/RKE2 组件与数据（危险）
  sync-registries   同步 registries.yaml 到节点清单（见 scripts/k8s/sync-registries.sh -h）
  shell-init        配置 crictl/kubectl 别名（写入 ~/.zshrc）
  status            查看 Rancher 容器与配置
  legacy-run        旧版 run-k8s.sh（Rancher v2.5.17，容器名 k8s）

ca 选项:
  -d, --domain <name>   指定证书域名（跳过交互）
  --ip <addr>           指定 SAN IP（默认自动检测局域网 IP）

ca-clean 选项:
  -y, --yes             跳过确认

环境变量:
  TULAN_K8S_CERT_OUT          证书目录，默认 /etc/certs
  TULAN_K8S_SITE_DOMAIN       默认证书域名（交互时的默认值）
  TULAN_K8S_RANCHER_DATA      数据目录，默认 /opt/rancher-data
  TULAN_K8S_RANCHER_IMAGE     Rancher 镜像，默认 rancher/rancher:v2.8.5
  TULAN_K8S_REGISTRY_MIRROR   镜像加速，默认 TULAN_DOCKER_REGISTRY_MIRROR
  TULAN_K8S_HTTP_PORT         默认 8080:80
  TULAN_K8S_HTTPS_PORT        默认 8443:443

说明:
  脚本目录: ${TULAN_HOME}/scripts/k8s/
  详细文档: ${TULAN_HOME}/scripts/k8s/README.md
  install/ca/ca-clean/clean/upgrade 需要 root 或 sudo

示例:
  brew k8s ca
  brew k8s ca -d rancher.local.example.com
  brew k8s ca-clean
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
    ca-clean|clean-ca|cert-clean) ACTION="ca-clean"; shift ;;
    password|pwd) ACTION="password"; shift ;;
    upgrade|up) ACTION="upgrade"; shift ;;
    clean|reset) ACTION="clean"; shift ;;
    sync-registries|sync) ACTION="sync-registries"; shift ;;
    shell-init|k3s-init|init-shell) ACTION="shell-init"; shift ;;
    status) ACTION="status"; shift ;;
    legacy-run|run) ACTION="legacy-run"; shift ;;
    -h|--help|help) usage; exit 0 ;;
    -d|--domain)
      [[ $# -ge 2 ]] || { tulan_error "缺少 --domain 参数"; exit 1; }
      export K8S_SITE_DOMAIN="$2"
      shift 2
      ;;
    --ip)
      [[ $# -ge 2 ]] || { tulan_error "缺少 --ip 参数"; exit 1; }
      export K8S_SITE_IP="$2"
      shift 2
      ;;
    -y|--yes) CA_ASSUME_YES=true; shift ;;
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
      tulan_k8s_require_linux || exit 1
      tulan_k8s_prompt_ca_params || exit 1
      tulan_require_privilege || exit 1
      tulan_k8s_run ca.sh
      ;;
    ca-clean)
      tulan_k8s_require_linux || exit 1
      if [[ "$CA_ASSUME_YES" != true ]]; then
        echo ""
        echo "将清理 ${TULAN_K8S_CERT_OUT} 下的 CA 与站点证书，并从系统信任链移除 tulan CA。"
        echo "（不会删除 Rancher 容器与数据，如需完整清理请用 brew k8s clean）"
        echo ""
        read -r -p "确认清理证书? [y/N]: " confirm
        [[ "$confirm" =~ ^[yY]$ ]] || { tulan_log "已取消"; exit 0; }
      fi
      tulan_require_privilege || exit 1
      tulan_k8s_run ca-clean.sh
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
