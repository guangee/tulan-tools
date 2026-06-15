#!/usr/bin/env bash
# tulan-tools Python 调用入口（bash 侧薄封装）

set -euo pipefail

# lib/ 目录（含 tulan_tools 包）
_tulan_python_lib() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  echo "$here"
}

# 调用 python3 -m tulan_tools <子命令> [参数...]
tulan_python() {
  PYTHONPATH="$(_tulan_python_lib)${PYTHONPATH:+:${PYTHONPATH}}" \
    python3 -m tulan_tools "$@"
}

# 从 JSON 文件读取点分路径字段（如 tools.kubectl.version）
tulan_json_get() {
  local file="$1" path="$2" default="${3:-}"
  if [[ -n "$default" ]]; then
    tulan_python json get "$file" "$path" --default "$default"
  else
    tulan_python json get "$file" "$path"
  fi
}
