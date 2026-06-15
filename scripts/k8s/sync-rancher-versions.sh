#!/usr/bin/env bash
# 从 Docker Hub 同步 rancher/rancher 可升级版本到 config/k8s.rancher.versions

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SCRIPT_ROOT="$(cd "${_SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=../../lib/common.sh
source "${_SCRIPT_ROOT}/lib/common.sh"

OUTPUT="${TULAN_K8S_VERSIONS_FILE:-$(tulan_get_home)/config/k8s.rancher.versions}"
PY="${_SCRIPT_DIR}/sync-rancher-versions.py"

if [[ ! -f "$PY" ]]; then
  echo "缺少脚本: ${PY}" >&2
  exit 1
fi

exec python3 "$PY" --output "$OUTPUT" "$@"
