#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# 状态查看
tulan_k8s_show_status() {
  tulan_k8s_require_linux || return 1
  tulan_k8s_require_docker || return 1

  echo "Rancher / K8s 状态"
  echo "────────────────────────────────────"
  echo "  脚本目录: $(tulan_k8s_dir)"
  echo "  证书目录: ${TULAN_K8S_CERT_OUT}"
  tulan_k8s_load_rancher_config
  if [[ -f "$(tulan_k8s_rancher_env_path)" ]]; then
    echo "  部署证书: ${K8S_SITE_DOMAIN}"
    [[ -n "${K8S_SITE_IP:-}" ]] && echo "  证书 IP:   ${K8S_SITE_IP}"
    [[ -n "${RANCHER_IMAGE:-}" ]] && echo "  已装镜像: ${RANCHER_IMAGE}"
    [[ -n "${HTTP_PORT_MAP:-}" ]] && echo "  HTTP 端口:  ${HTTP_PORT_MAP}"
    [[ -n "${HTTPS_PORT_MAP:-}" ]] && echo "  HTTPS 端口: ${HTTPS_PORT_MAP}"
    if lan_ip="$(tulan_k8s_resolve_lan_ip 2>/dev/null)"; then
      echo "  内网注册:   $(tulan_k8s_build_rancher_url "$lan_ip" "$(tulan_k8s_host_port_from_map "${HTTPS_PORT_MAP:-}")")"
    fi
    [[ -n "${INSTALLED_AT:-}" ]] && echo "  安装时间: ${INSTALLED_AT}"
  else
    tulan_k8s_load_site_config
    if [[ -f "$(tulan_k8s_site_env_path)" ]]; then
      echo "  最近证书: ${K8S_SITE_DOMAIN}（未 install，见 site.env）"
      [[ -n "${K8S_SITE_IP:-}" ]] && echo "  证书 IP:   ${K8S_SITE_IP}"
    else
      echo "  部署证书: (未安装，请先 brew k8s ca && brew k8s install)"
    fi
  fi
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
