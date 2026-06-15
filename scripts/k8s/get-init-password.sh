#!/usr/bin/env bash
# Rancher 管理员密码（bash 薄入口 → lib/tulan_tools/rancher/password.py）
#
# 用法:
#   brew k8s password
#   brew k8s password --set 'YourPassword'
#   brew k8s password --reset
set -euo pipefail

_SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../../lib/common.sh
source "${_SCRIPT_ROOT}/lib/common.sh"

export CONTAINER_NAME="${CONTAINER_NAME:-rancher}"
export RANCHER_KUBECONFIG="${RANCHER_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

exec tulan_python rancher password "$@"
