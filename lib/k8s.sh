#!/usr/bin/env bash
# Rancher / K8s 单机部署 — 模块入口（实现见 lib/k8s/）

set -euo pipefail

_K8S_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/k8s" && pwd)"

for _k8s_mod in vars common certs ports versions deploy register status; do
  # shellcheck source=k8s/vars.sh
  source "${_K8S_LIB}/${_k8s_mod}.sh"
done

unset _K8S_LIB _k8s_mod
