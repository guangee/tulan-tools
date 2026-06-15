#!/usr/bin/env bash
# 从 Docker Hub 同步 rancher/rancher 可升级版本（开发/CI 用）
# 客户端默认通过 brew update 从 bin 分支拉取 k8s.rancher.versions.json

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SCRIPT_ROOT="$(cd "${_SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=../../lib/common.sh
source "${_SCRIPT_ROOT}/lib/common.sh"

PY="${_SCRIPT_DIR}/sync-rancher-versions.py"

if [[ ! -f "$PY" ]]; then
  echo "缺少脚本: ${PY}" >&2
  exit 1
fi

if [[ $# -eq 0 ]]; then
  set -- --format json --min-version v2.8.5 --max-per-minor 3 \
    --output "$(tulan_get_home)/state/k8s.rancher.versions.json"
fi

exec python3 "$PY" "$@"
