#!/usr/bin/env bash
# tulan-tools 自动更新脚本

set -euo pipefail

_SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${_SCRIPT_ROOT}/lib/common.sh"
# shellcheck source=../lib/binaries.sh
source "${_SCRIPT_ROOT}/lib/binaries.sh"

TULAN_HOME="$(tulan_get_home)"

CHECK_ON_START=false
FORCE=false
LAST_CHECK_FILE="${TULAN_HOME}/state/last-update-check"

usage() {
  cat <<EOF
tulan-tools 更新脚本

用法:
  brew update [选项]
  ./scripts/update.sh [选项]

选项:
  --check-on-start  静默检查（shell 启动时调用，每天最多一次）
  --force           强制更新，忽略时间限制
  -h, --help        显示帮助
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-on-start) CHECK_ON_START=true; shift ;;
    --force) FORCE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) shift ;;
  esac
done

should_check() {
  if [[ "$FORCE" == true ]]; then
    return 0
  fi

  if [[ ! -f "$LAST_CHECK_FILE" ]]; then
    return 0
  fi

  local last_check now
  last_check="$(cat "$LAST_CHECK_FILE")"
  now="$(date +%s)"
  # 24 小时内不重复检查
  if (( now - last_check < 86400 )); then
    return 1
  fi
  return 0
}

refresh_bin_index() {
  local force="${1:-true}"

  tulan_log "刷新 bin 分支二进制索引..."
  if tulan_manifest_refresh "$force" 2>/dev/null; then
    tulan_log "bin 索引已更新: $(tulan_manifest_cache_path)"
  else
    tulan_log "bin 索引刷新失败，将使用本地缓存"
  fi
}

do_update() {
  local git_updated=false

  if [[ ! -d "${TULAN_HOME}/.git" ]]; then
    [[ "$CHECK_ON_START" == false ]] && tulan_log "非 git 安装，跳过更新"
    return 0
  fi

  mkdir -p "${TULAN_HOME}/state"
  date +%s > "$LAST_CHECK_FILE"

  local remote_hash local_hash
  git -C "${TULAN_HOME}" fetch origin --quiet 2>/dev/null || return 0

  local branch
  branch="$(git -C "${TULAN_HOME}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "master")"

  remote_hash="$(git -C "${TULAN_HOME}" rev-parse "origin/${branch}" 2>/dev/null || echo "")"
  local_hash="$(git -C "${TULAN_HOME}" rev-parse HEAD 2>/dev/null || echo "")"

  if [[ -z "$remote_hash" ]] || [[ "$remote_hash" == "$local_hash" ]]; then
    [[ "$CHECK_ON_START" == false ]] && tulan_log "已是最新版本"
  else
    tulan_log "发现新版本，正在更新..."
    if ! git -C "${TULAN_HOME}" pull --ff-only origin "${branch}" 2>/dev/null; then
      if git -C "${TULAN_HOME}" diff --quiet 2>/dev/null && \
         git -C "${TULAN_HOME}" diff --cached --quiet 2>/dev/null; then
        tulan_error "更新失败，请检查网络或仓库状态"
        return 1
      fi
      tulan_log "检测到本地修改，自动 stash 后重试..."
      git -C "${TULAN_HOME}" stash push -m "tulan-tools auto-stash before update" >/dev/null 2>&1 || true
      git -C "${TULAN_HOME}" pull --ff-only origin "${branch}" || {
        tulan_error "更新失败。可手动: cd ${TULAN_HOME} && git stash && git pull"
        return 1
      }
      git -C "${TULAN_HOME}" stash pop >/dev/null 2>&1 || \
        tulan_log "提示: 本地修改在 stash 中，请执行: cd ${TULAN_HOME} && git stash pop"
    fi
    git_updated=true
    chmod +x "${TULAN_HOME}/bin/"* 2>/dev/null || true
    chmod +x "${TULAN_HOME}/scripts/"* 2>/dev/null || true
    tulan_log "更新完成: ${local_hash:0:7} -> ${remote_hash:0:7}"
  fi

  # 显式 brew update：始终强制刷新 bin 索引；shell 静默检查仍遵守 TTL
  if [[ "$CHECK_ON_START" == false ]]; then
    refresh_bin_index true
  elif [[ "$git_updated" == true ]]; then
    refresh_bin_index true
  else
    refresh_bin_index false
  fi
}

main() {
  tulan_cleanup_legacy_files

  if [[ "$CHECK_ON_START" == true ]]; then
    should_check || exit 0
    do_update
  else
    do_update
  fi
}

main "$@"
