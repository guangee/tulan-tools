#!/usr/bin/env bash
# Python pip / npm / Go 国内镜像配置

set -euo pipefail

TULAN_PIP_TEMPLATE="${TULAN_PIP_TEMPLATE:-$(tulan_get_home)/config/pip.aliyun.conf}"
TULAN_NPM_TEMPLATE="${TULAN_NPM_TEMPLATE:-$(tulan_get_home)/config/npm.npmmirror.conf}"
TULAN_GO_TEMPLATE="${TULAN_GO_TEMPLATE:-$(tulan_get_home)/config/go.env.cn}"
TULAN_MIRRORS_ENV="${TULAN_MIRRORS_ENV:-$(tulan_get_home)/state/mirrors.env}"

TULAN_PIP_INDEX_URL="${TULAN_PIP_INDEX_URL:-https://mirrors.aliyun.com/pypi/simple/}"
TULAN_NPM_REGISTRY="${TULAN_NPM_REGISTRY:-https://registry.npmmirror.com}"
TULAN_GOPROXY="${TULAN_GOPROXY:-https://goproxy.cn,direct}"
TULAN_GOSUMDB="${TULAN_GOSUMDB:-sum.golang.google.cn}"

tulan_mirrors_configure_pip() {
  local pip_dir="${HOME}/.pip"

  if [[ -f "$TULAN_PIP_TEMPLATE" ]]; then
    mkdir -p "$pip_dir"
    cp "$TULAN_PIP_TEMPLATE" "${pip_dir}/pip.conf"
    tulan_log "已配置 pip: ${pip_dir}/pip.conf（阿里云 PyPI）"
  else
    mkdir -p "$pip_dir"
    cat > "${pip_dir}/pip.conf" <<EOF
[global]
index-url = ${TULAN_PIP_INDEX_URL}
trusted-host = mirrors.aliyun.com

[install]
trusted-host = mirrors.aliyun.com
EOF
    tulan_log "已配置 pip: ${pip_dir}/pip.conf"
  fi

  if command -v pip3 &>/dev/null; then
    pip3 config set global.index-url "$TULAN_PIP_INDEX_URL" 2>/dev/null || true
    pip3 config set install.trusted-host mirrors.aliyun.com 2>/dev/null || true
  fi
  if command -v pip &>/dev/null; then
    pip config set global.index-url "$TULAN_PIP_INDEX_URL" 2>/dev/null || true
    pip config set install.trusted-host mirrors.aliyun.com 2>/dev/null || true
  fi
}

tulan_mirrors_configure_npm() {
  local npmrc="${HOME}/.npmrc"

  if [[ -f "$TULAN_NPM_TEMPLATE" ]]; then
    cp "$TULAN_NPM_TEMPLATE" "$npmrc"
    tulan_log "已配置 npm: ${npmrc}（npmmirror）"
  else
    cat > "$npmrc" <<EOF
registry=${TULAN_NPM_REGISTRY}
disturl=https://npmmirror.com/dist
EOF
    tulan_log "已配置 npm: ${npmrc}"
  fi

  if command -v npm &>/dev/null; then
    npm config set registry "$TULAN_NPM_REGISTRY" 2>/dev/null || true
  fi
}

tulan_mirrors_configure_go() {
  local env_file="$TULAN_MIRRORS_ENV"
  local goproxy gosumdb

  mkdir -p "$(dirname "$env_file")"

  if [[ -f "$TULAN_GO_TEMPLATE" ]]; then
    {
      echo "# tulan-tools 国内 Go 代理（brew mirrors 自动生成）"
      grep -v '^[[:space:]]*#' "$TULAN_GO_TEMPLATE" | grep -v '^[[:space:]]*$' | while IFS= read -r line; do
        echo "export ${line}"
      done
    } > "$env_file"
  else
    cat > "$env_file" <<EOF
# tulan-tools 国内 Go 代理（brew mirrors 自动生成）
export GOPROXY=${TULAN_GOPROXY}
export GOSUMDB=${TULAN_GOSUMDB}
EOF
  fi

  # shellcheck source=/dev/null
  source "$env_file"
  tulan_log "已配置 Go: ${env_file}（GOPROXY=${GOPROXY}）"

  if command -v go &>/dev/null; then
    go env -w GOPROXY="$GOPROXY" 2>/dev/null || true
    go env -w GOSUMDB="$GOSUMDB" 2>/dev/null || true
  fi
}

tulan_mirrors_restore_pip() {
  rm -f "${HOME}/.pip/pip.conf"
  if command -v pip3 &>/dev/null; then
    pip3 config unset global.index-url 2>/dev/null || true
    pip3 config unset install.trusted-host 2>/dev/null || true
  fi
  if command -v pip &>/dev/null; then
    pip config unset global.index-url 2>/dev/null || true
    pip config unset install.trusted-host 2>/dev/null || true
  fi
  tulan_log "已还原 pip 为默认配置"
}

tulan_mirrors_restore_npm() {
  if [[ -f "${HOME}/.npmrc" ]]; then
    grep -v 'npmmirror.com' "${HOME}/.npmrc" > "${HOME}/.npmrc.tmp" 2>/dev/null || true
    if [[ -s "${HOME}/.npmrc.tmp" ]]; then
      mv "${HOME}/.npmrc.tmp" "${HOME}/.npmrc"
    else
      rm -f "${HOME}/.npmrc" "${HOME}/.npmrc.tmp"
    fi
  fi
  if command -v npm &>/dev/null; then
    npm config delete registry 2>/dev/null || true
  fi
  tulan_log "已还原 npm 为默认 registry"
}

tulan_mirrors_restore_go() {
  rm -f "$TULAN_MIRRORS_ENV"
  if command -v go &>/dev/null; then
    go env -u GOPROXY 2>/dev/null || true
    go env -u GOSUMDB 2>/dev/null || true
  fi
  tulan_log "已还原 Go 代理为默认"
}

tulan_mirrors_show_status() {
  echo "国内镜像配置状态"
  echo "────────────────────────────────────"

  if declare -F tulan_repo_mirror_show_status &>/dev/null; then
    tulan_repo_mirror_show_status
    echo ""
  fi

  echo "pip (~/.pip/pip.conf):"
  if [[ -f "${HOME}/.pip/pip.conf" ]]; then
    sed 's/^/  /' "${HOME}/.pip/pip.conf"
  else
    echo "  (未配置，运行 brew mirrors 配置)"
  fi

  echo ""
  echo "npm (~/.npmrc):"
  if [[ -f "${HOME}/.npmrc" ]]; then
    sed 's/^/  /' "${HOME}/.npmrc"
  else
    echo "  (未配置)"
  fi

  echo ""
  echo "Go (~/.tulan-tools/state/mirrors.env):"
  if [[ -f "$TULAN_MIRRORS_ENV" ]]; then
    sed 's/^/  /' "$TULAN_MIRRORS_ENV"
  else
    echo "  (未配置)"
  fi

  echo ""
  echo "运行时验证:"
  if command -v pip3 &>/dev/null; then
    echo "  pip3 index-url: $(pip3 config get global.index-url 2>/dev/null || echo N/A)"
  fi
  if command -v npm &>/dev/null; then
    echo "  npm registry: $(npm config get registry 2>/dev/null || echo N/A)"
  fi
  if command -v go &>/dev/null; then
    echo "  go GOPROXY: $(go env GOPROXY 2>/dev/null || echo N/A)"
  elif [[ -f "$TULAN_MIRRORS_ENV" ]]; then
    # shellcheck source=/dev/null
    source "$TULAN_MIRRORS_ENV"
    echo "  go GOPROXY (env): ${GOPROXY:-N/A}"
  fi
}

tulan_mirrors_restore() {
  local do_pip="${1:-false}"
  local do_npm="${2:-false}"
  local do_go="${3:-false}"
  local do_repo="${4:-false}"

  [[ "$do_pip" == true ]] && tulan_mirrors_restore_pip
  [[ "$do_npm" == true ]] && tulan_mirrors_restore_npm
  [[ "$do_go" == true ]] && tulan_mirrors_restore_go
  if [[ "$do_repo" == true ]]; then
    tulan_repo_mirror_restore
  fi

  tulan_refresh_shell_config 2>/dev/null || true
  echo ""
  tulan_mirrors_show_status
}

tulan_mirrors_setup() {
  local do_pip="${1:-true}"
  local do_npm="${2:-true}"
  local do_go="${3:-true}"
  local do_repo="${4:-false}"

  [[ "$do_pip" == true ]] && tulan_mirrors_configure_pip
  [[ "$do_npm" == true ]] && tulan_mirrors_configure_npm
  [[ "$do_go" == true ]] && tulan_mirrors_configure_go
  if [[ "$do_repo" == true ]]; then
    tulan_repo_mirror_configure_cn
  fi

  tulan_refresh_shell_config 2>/dev/null || true
  echo ""
  tulan_mirrors_show_status
}
