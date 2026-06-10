#!/usr/bin/env bash
# 运行时环境：统一写入 ~/.tulan-tools/state/env.sh，由主 shell 配置块加载

set -euo pipefail

TULAN_LEGACY_JAVA_MARKER="# >>> tulan-java >>>"
TULAN_LEGACY_JAVA_MARKER_END="# <<< tulan-java <<<"
TULAN_LEGACY_NODE_MARKER="# >>> tulan-node >>>"
TULAN_LEGACY_NODE_MARKER_END="# <<< tulan-node <<<"

tulan_env_file_path() {
  echo "$(tulan_get_home)/state/env.sh"
}

tulan_remove_rc_marker_block() {
  local rc_file="$1" marker="$2" marker_end="$3"
  [[ -f "$rc_file" ]] || return 0
  grep -qF "$marker" "$rc_file" 2>/dev/null || return 0
  local tmp
  tmp="$(mktemp)"
  awk -v marker="$marker" -v end="$marker_end" '
    $0 ~ marker { skip=1; next }
    $0 ~ end { skip=0; next }
    !skip { print }
  ' "$rc_file" > "$tmp"
  mv "$tmp" "$rc_file"
}

tulan_remove_legacy_env_markers() {
  local rc
  for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
    tulan_remove_rc_marker_block "$rc" "$TULAN_LEGACY_JAVA_MARKER" "$TULAN_LEGACY_JAVA_MARKER_END"
    tulan_remove_rc_marker_block "$rc" "$TULAN_LEGACY_NODE_MARKER" "$TULAN_LEGACY_NODE_MARKER_END"
  done
}

tulan_refresh_shell_config() {
  local home rc
  home="$(tulan_get_home)"
  for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
    if [[ -f "$rc" ]] && grep -qF "${TULAN_TOOLS_MARKER}" "$rc" 2>/dev/null; then
      tulan_inject_shell_config "$rc" "$home" >/dev/null
    fi
  done
}

tulan_env_render() {
  local env_file java_home node_home java_major node_major
  env_file="$(tulan_env_file_path)"
  mkdir -p "$(dirname "$env_file")"

  java_home=""
  node_home=""
  local java_state node_state
  java_state="$(tulan_get_home)/state/java.json"
  node_state="$(tulan_get_home)/state/node.json"

  if [[ -f "$java_state" ]]; then
    java_home="$(python3 - "$java_state" <<'PY' 2>/dev/null || true
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
if p.exists():
    print(json.loads(p.read_text()).get("java_home", ""))
PY
)"
  fi
  if [[ -f "$node_state" ]]; then
    node_home="$(python3 - "$node_state" <<'PY' 2>/dev/null || true
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
if p.exists():
    print(json.loads(p.read_text()).get("node_home", ""))
PY
)"
  fi

  {
    echo "# tulan-tools 运行时环境（brew use java/node 自动更新，请勿手改）"
    if [[ -n "$java_home" ]] && [[ -d "$java_home" ]]; then
      echo "export JAVA_HOME=\"${java_home}\""
    fi
    if [[ -n "$node_home" ]] && [[ -d "$node_home" ]]; then
      echo "export NODE_HOME=\"${node_home}\""
    fi
    echo -n 'export PATH="'
    [[ -n "$java_home" ]] && [[ -d "$java_home" ]] && echo -n '${JAVA_HOME}/bin:'
    [[ -n "$node_home" ]] && [[ -d "$node_home" ]] && echo -n '${NODE_HOME}/bin:'
    echo '${PATH}"'
  } > "$env_file"
}

tulan_link_tool_bin() {
  local tool_home="$1"
  shift
  local home bin_dir cmd target rel
  home="$(tulan_get_home)"
  bin_dir="${home}/bin"
  mkdir -p "$bin_dir"

  for cmd in "$@"; do
    target="${tool_home}/bin/${cmd}"
    [[ -x "$target" ]] || continue
    rel="$(python3 - "$target" "$bin_dir" <<'PY'
import os, sys
print(os.path.relpath(sys.argv[1], sys.argv[2]))
PY
)"
    ln -sf "$rel" "${bin_dir}/${cmd}"
  done
}

tulan_java_link_bin() {
  local java_home="$1"
  tulan_link_tool_bin "$java_home" java javac jar jshell javadoc javap keytool
}

tulan_java_unlink_bin() {
  local cmd
  for cmd in java javac jar jshell javadoc javap keytool; do
    rm -f "$(tulan_get_home)/bin/${cmd}"
  done
}

tulan_node_link_bin() {
  local node_home="$1"
  tulan_link_tool_bin "$node_home" node npm npx
}

tulan_node_unlink_bin() {
  local cmd
  for cmd in node npm npx; do
    rm -f "$(tulan_get_home)/bin/${cmd}"
  done
}

tulan_runtime_configure() {
  tulan_env_render
  tulan_remove_legacy_env_markers
  tulan_refresh_shell_config
}

tulan_runtime_hint() {
  echo ""
  echo "  环境文件: $(tulan_env_file_path)"
  echo "  命令目录: $(tulan_get_home)/bin"
  echo "  当前终端: hash -r 2>/dev/null; rehash 2>/dev/null; 或 source $(tulan_env_file_path)"
}
