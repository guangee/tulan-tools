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
CA_CLEAN_ALL=false
PORTS_ASSUME_YES=false
K8S_PORTS_CLI_HTTP=false
K8S_PORTS_CLI_HTTPS=false
REGISTER_URL_MODE="lan"
REGISTER_URL_FORMAT="text"
REGISTER_URL_SET=false
REGISTER_CMD_CLUSTER=""
REGISTER_CMD_REFRESH=false
NODE_CLEAN_ASSUME_YES=false

usage() {
  cat <<EOF
用法: brew k8s [子命令] [选项/参数]

子命令:
  brew k8s install                   安装 Rancher（交互选择证书，写入 rancher.env）
  brew k8s install -d <domain>       指定证书安装
  brew k8s upgrade                   升级 Rancher（交互选择目标版本）
  brew k8s upgrade -V v2.13.3        指定版本升级
  ca                生成自签 CA 与站点证书（交互式输入域名，自动检测局域网 IP）
  ca-clean          清理自签 CA 与站点证书（不清理 Rancher 容器）
  password          从容器日志获取 Bootstrap 初始密码
  upgrade           升级 Rancher 镜像版本
  ports             修改已部署 Rancher 的 HTTP/HTTPS 端口
  clean             清理 Rancher/K3s/RKE2 组件与数据（危险，含 Server）
  sync-registries   同步 registries.yaml 到节点清单（见 scripts/k8s/sync-registries.sh -h）
  sync-versions     开发用：手动同步 Rancher 版本到本地 state
  shell-init        配置 crictl/kubectl 别名（写入 ~/.zshrc）
  status            查看 Rancher 容器与配置
  register-url      查看/设置节点注册用的内网 Rancher 地址
  register-command  输出内网版节点注册命令（替换 UI 中的外网域名）
  node-status       在节点上查看注册/Agent 状态（system-agent + rke2/k3s）
  node-pull         在节点上查看镜像拉取进度与 registry 网络连通性
  fix-dns           修复节点 DNS（同 brew dns fix）
  node-clean        清理节点注册数据，便于重新注册（不含 Rancher Server）
  images            查看本机 Docker + containerd 已拉取镜像
  legacy-run        旧版 run-k8s.sh（Rancher v2.5.17，容器名 k8s）

ca 选项:
  -d, --domain <name>   指定证书域名（跳过交互）
  --ip <addr>           指定 SAN IP（默认自动检测局域网 IP）

ca-clean 选项:
  -d, --domain <name>   指定要清理的域名证书
  -a, --all             清理全部域名证书及 CA
  -y, --yes             跳过确认

install / upgrade / ports 选项:
  -d, --domain <name>   install 时指定证书域名（跳过选择）
  --https-port <port>   指定 HTTPS 宿主机端口
  --http-port <port>    指定 HTTP 宿主机端口
  -V, --version <tag>    upgrade 时指定目标版本（如 v2.13.3）
  --image <name>        upgrade 时指定完整镜像
  -y, --yes             ports/register-url --set/node-clean 时跳过确认

register-url 选项:
  --lan                 输出内网地址（默认）
  --public              输出域名/外网地址（register-url）
  --format text|json|url  输出格式（url 仅一行，便于脚本）
  --set                 将 Rancher server-url 设为内网地址

register-command 选项:
  -c, --cluster <name>  指定集群名（默认列出全部）
  --from-url <url>      额外替换此外网 URL（如 nginx 入口与证书域名不同）
  --refresh             删除并重建 registration token 后再输出
  --format text|json|command  text=对比展示, command=仅一行命令

环境变量:
  TULAN_K8S_CERT_OUT          证书目录，默认 /etc/certs
  TULAN_K8S_SITE_DOMAIN       默认证书域名（交互时的默认值）
  TULAN_K8S_RANCHER_DATA      数据目录，默认 /opt/rancher-data
  TULAN_K8S_RANCHER_IMAGE     Rancher 镜像，默认 rancher/rancher:v2.8.5
  TULAN_K8S_REGISTRY_MIRROR   镜像加速，默认 TULAN_DOCKER_REGISTRY_MIRROR
  TULAN_K8S_HTTP_PORT         默认 8080:80
  TULAN_K8S_HTTPS_PORT        默认 8443:443
  TULAN_K8S_UPGRADE_DEFAULT     默认升级镜像，默认 rancher/rancher:v2.13.3
  TULAN_K8S_VERSIONS_FILE       本地 fallback，默认 config/k8s.rancher.versions
                                （正常由 brew update 缓存 state/k8s.rancher.versions.json）

说明:
  脚本目录: ${TULAN_HOME}/scripts/k8s/
  详细文档: ${TULAN_HOME}/scripts/k8s/README.md
  install/ca/ca-clean/clean/upgrade 需要 root 或 sudo

示例:
  brew k8s ca
  brew k8s ca -d rancher.local.example.com
  brew k8s ca-clean
  brew k8s ca-clean -d rancher.local.example.com
  brew k8s ca-clean -a
  brew k8s install
  brew k8s install --https-port 9443
  brew k8s ports
  brew k8s ports --https-port 9443 -y
  brew k8s sync-versions
  brew k8s upgrade
  brew k8s upgrade -V v2.13.3
  brew k8s password
  brew k8s register-url                查看内网节点注册地址
  brew k8s register-url --format url   仅输出内网 URL
  brew k8s register-url --set -y       将 Rancher server-url 改为内网
  brew k8s register-command            内网版节点注册命令（替换 UI 外网域名）
  brew k8s register-command --format command -c mycluster
  brew k8s node-status                 在节点上查看注册状态
  brew k8s node-pull                   查看镜像拉取与 registry 网络
  brew k8s fix-dns -y                  修复节点 DNS
  brew k8s node-pull -f                持续跟踪拉取日志
  brew k8s node-clean -y               清理节点注册数据后重新注册
  brew k8s images                      查看 Docker + containerd 镜像
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
    ports|port|set-ports) ACTION="ports"; shift ;;
    clean|reset) ACTION="clean"; shift ;;
    sync-registries|sync) ACTION="sync-registries"; shift ;;
    sync-versions|sync-rancher-versions|versions-sync) ACTION="sync-versions"; shift ;;
    shell-init|k3s-init|init-shell) ACTION="shell-init"; shift ;;
    status) ACTION="status"; shift ;;
    register-url|reg-url|server-url|node-url) ACTION="register-url"; shift ;;
    register-command|reg-cmd|register-cmd) ACTION="register-command"; shift ;;
    node-status|node|check-node) ACTION="node-status"; shift ;;
    node-pull|pull|pull-status|node-net) ACTION="node-pull"; shift ;;
    fix-dns|dns-fix) ACTION="fix-dns"; shift ;;
    node-clean|clean-node) ACTION="node-clean"; shift ;;
    images|list-images|imgs) ACTION="images"; shift ;;
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
    --https-port)
      [[ $# -ge 2 ]] || { tulan_error "缺少 --https-port 参数"; exit 1; }
      tulan_k8s_set_https_port "$2" || exit 1
      K8S_PORTS_CLI_HTTPS=true
      shift 2
      ;;
    --http-port)
      [[ $# -ge 2 ]] || { tulan_error "缺少 --http-port 参数"; exit 1; }
      tulan_k8s_set_http_port "$2" || exit 1
      K8S_PORTS_CLI_HTTP=true
      shift 2
      ;;
    -V|--version)
      [[ $# -ge 2 ]] || { tulan_error "缺少 --version 参数"; exit 1; }
      export RANCHER_UPGRADE_IMAGE
      RANCHER_UPGRADE_IMAGE="$(tulan_k8s_image_from_tag "$2")" || exit 1
      shift 2
      ;;
    --image)
      [[ $# -ge 2 ]] || { tulan_error "缺少 --image 参数"; exit 1; }
      export RANCHER_UPGRADE_IMAGE="$2"
      shift 2
      ;;
    -y|--yes)
      CA_ASSUME_YES=true
      PORTS_ASSUME_YES=true
      NODE_CLEAN_ASSUME_YES=true
      shift
      ;;
    --lan|--internal)
      REGISTER_URL_MODE="lan"
      shift
      ;;
    --public)
      REGISTER_URL_MODE="public"
      shift
      ;;
    --format)
      [[ $# -ge 2 ]] || { tulan_error "缺少 --format 参数"; exit 1; }
      REGISTER_URL_FORMAT="$2"
      shift 2
      ;;
    --set)
      REGISTER_URL_SET=true
      shift
      ;;
    -c|--cluster)
      [[ $# -ge 2 ]] || { tulan_error "缺少 --cluster 参数"; exit 1; }
      REGISTER_CMD_CLUSTER="$2"
      shift 2
      ;;
    --from-url)
      [[ $# -ge 2 ]] || { tulan_error "缺少 --from-url 参数"; exit 1; }
      K8S_REGISTER_EXTRA_FROM_URL="$2"
      shift 2
      ;;
    --refresh)
      REGISTER_CMD_REFRESH=true
      shift
      ;;
    -v|--verbose)
      export NODE_STATUS_VERBOSE=true
      shift
      ;;
    -*) EXTRA_ARGS+=("$1"); shift ;;
    *) EXTRA_ARGS+=("$1"); shift ;;
  esac
done

main() {
  case "$ACTION" in
    install)
      tulan_k8s_require_linux || exit 1
      tulan_k8s_prompt_install_cert || exit 1
      tulan_k8s_prompt_install_ports || exit 1
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
      if [[ "$CA_CLEAN_ALL" == true ]]; then
        export K8S_CLEAN_DOMAINS
        K8S_CLEAN_DOMAINS="$(tulan_k8s_list_cert_domains | tr '\n' ' ')"
        K8S_CLEAN_DOMAINS="${K8S_CLEAN_DOMAINS%% }"
        export K8S_CLEAN_INCLUDE_CA=true
        if [[ -z "$K8S_CLEAN_DOMAINS" ]] && ! tulan_k8s_has_ca_files; then
          tulan_error "未发现可清理的证书（${TULAN_K8S_CERT_OUT}）"
          exit 1
        fi
        [[ -n "$K8S_CLEAN_DOMAINS" ]] || export K8S_CLEAN_DOMAINS="__ca_only__"
      else
        tulan_k8s_prompt_ca_clean || exit 1
      fi
      export TULAN_K8S_CA_CLEAN_YES="$CA_ASSUME_YES"
      tulan_k8s_confirm_ca_clean || exit 0
      tulan_require_privilege || exit 1
      tulan_k8s_run ca-clean.sh
      ;;
    password)
      tulan_k8s_run get-init-password.sh
      ;;
    upgrade)
      tulan_k8s_require_linux || exit 1
      tulan_k8s_require_rancher_config || exit 1
      tulan_k8s_prompt_upgrade_image || exit 1
      tulan_log "升级: $(tulan_k8s_resolve_current_image) → ${RANCHER_UPGRADE_IMAGE}"
      tulan_log "沿用证书: ${K8S_SITE_DOMAIN}，端口: ${HTTP_PORT_MAP}, ${HTTPS_PORT_MAP}"
      tulan_require_privilege || exit 1
      tulan_k8s_run upgrade.sh
      ;;
    ports)
      tulan_k8s_require_linux || exit 1
      tulan_k8s_require_docker || exit 1
      cli_http="${HTTP_PORT_MAP:-}"
      cli_https="${HTTPS_PORT_MAP:-}"
      tulan_k8s_resolve_deploy_config || exit 1
      export K8S_OLD_HTTP_PORT_MAP="${HTTP_PORT_MAP}"
      export K8S_OLD_HTTPS_PORT_MAP="${HTTPS_PORT_MAP}"
      [[ -n "$cli_http" ]] && export HTTP_PORT_MAP="$cli_http"
      [[ -n "$cli_https" ]] && export HTTPS_PORT_MAP="$cli_https"
      export K8S_PORTS_CLI_HTTP K8S_PORTS_CLI_HTTPS
      tulan_k8s_prompt_ports change || exit 0
      export TULAN_K8S_PORTS_YES="$PORTS_ASSUME_YES"
      tulan_k8s_confirm_change_ports || exit 0
      tulan_require_privilege || exit 1
      tulan_k8s_run ports.sh
      ;;
    clean)
      tulan_require_privilege || exit 1
      tulan_k8s_run clean.sh
      ;;
    sync-registries)
      tulan_k8s_run_user sync-registries.sh "${EXTRA_ARGS[@]}"
      ;;
    sync-versions)
      tulan_k8s_require_linux || exit 1
      tulan_k8s_run_user sync-rancher-versions.sh "${EXTRA_ARGS[@]}"
      ;;
    shell-init)
      tulan_k8s_run_user k3s-command-init.sh
      ;;
    status)
      tulan_k8s_show_status
      ;;
    register-url)
      tulan_k8s_require_linux || exit 1
      if [[ "$REGISTER_URL_SET" == true ]]; then
        export TULAN_K8S_REGISTER_SET_YES="$PORTS_ASSUME_YES"
        tulan_require_privilege || exit 1
        tulan_k8s_set_register_url
      else
        tulan_k8s_print_register_url "$REGISTER_URL_MODE" "$REGISTER_URL_FORMAT"
      fi
      ;;
    register-command)
      tulan_k8s_require_linux || exit 1
      export TULAN_K8S_REGISTER_SET_YES="$PORTS_ASSUME_YES"
      export K8S_REGISTER_EXTRA_FROM_URL
      tulan_k8s_print_register_command "$REGISTER_CMD_CLUSTER" "$REGISTER_CMD_REFRESH" "$REGISTER_URL_FORMAT"
      ;;
    node-status)
      tulan_k8s_require_linux || exit 1
      tulan_k8s_run_user node-status.sh "${EXTRA_ARGS[@]}"
      ;;
    node-pull)
      tulan_k8s_require_linux || exit 1
      tulan_k8s_run_user node-pull.sh "${EXTRA_ARGS[@]}"
      ;;
    fix-dns)
      exec "${TULAN_HOME}/scripts/setup-dns.sh" fix "${EXTRA_ARGS[@]}"
      ;;
    node-clean)
      tulan_k8s_require_linux || exit 1
      export TULAN_K8S_NODE_CLEAN_YES="$NODE_CLEAN_ASSUME_YES"
      tulan_require_privilege || exit 1
      tulan_k8s_run node-clean.sh
      ;;
    images)
      tulan_k8s_require_linux || exit 1
      tulan_k8s_run_user list-images.sh "${EXTRA_ARGS[@]}"
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
