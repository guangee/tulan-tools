#!/usr/bin/env bash
# Docker 守护进程配置（daemon.json：镜像加速、日志轮转）

set -euo pipefail

_SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${_SCRIPT_ROOT}/lib/common.sh"
# shellcheck source=../lib/docker.sh
source "${_SCRIPT_ROOT}/lib/docker.sh"

TULAN_HOME="$(tulan_get_home)"
ACTION="configure"
CLI_SET=false

usage() {
  cat <<EOF
用法: brew docker [子命令] [选项]

子命令:
  configure         配置 daemon.json（默认，交互式）
  install           同 configure
  status            查看当前 daemon.json 与 tulan-tools 记录
  restore           从最近备份还原 daemon.json

选项:
  --mirror <url>        镜像加速地址
  --log-driver <name>   日志驱动，json-file 或 local（默认 json-file）
  --log-max-size <sz>   单日志文件大小，如 10m、100m
  --log-max-file <n>    日志保留份数（轮转文件数）
  --log-compress        压缩 json-file 轮转日志（默认开启）
  --no-log-compress     不压缩轮转日志
  -y, --yes             跳过交互确认

环境变量:
  TULAN_DOCKER_REGISTRY_MIRROR   默认镜像加速
  TULAN_DOCKER_LOG_DRIVER        默认 json-file
  TULAN_DOCKER_LOG_MAX_SIZE        默认 10m
  TULAN_DOCKER_LOG_MAX_FILE        默认 3
  TULAN_DOCKER_DAEMON_PATH         默认 /etc/docker/daemon.json

说明:
  默认模板: ${TULAN_HOME}/config/docker.daemon.defaults.json
  配置备份: ${TULAN_HOME}/state/docker-backup/
  状态记录: ${TULAN_HOME}/state/docker-config.json
  需要 root 或 sudo（Linux）

示例:
  brew docker configure
  brew docker --mirror https://hub.coding-space.cn --log-max-size 20m --log-max-file 5
  brew docker status
  brew docker restore
  brew help docker
EOF
}

load_defaults_if_needed() {
  if [[ -f "$TULAN_DOCKER_DEFAULTS_FILE" ]]; then
    eval "$(python3 - "$TULAN_DOCKER_DEFAULTS_FILE" <<'PY'
import json, sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
mirrors = data.get("registry-mirrors") or []
if mirrors:
    print(f"export TULAN_DOCKER_REGISTRY_MIRROR={mirrors[0]!r}")
print(f"export TULAN_DOCKER_LOG_DRIVER={data.get('log-driver', 'json-file')!r}")
opts = data.get("log-opts") or {}
print(f"export TULAN_DOCKER_LOG_MAX_SIZE={opts.get('max-size', '10m')!r}")
print(f"export TULAN_DOCKER_LOG_MAX_FILE={opts.get('max-file', '3')!r}")
print(f"export TULAN_DOCKER_LOG_COMPRESS={opts.get('compress', 'true')!r}")
PY
)"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    configure|install|setup) ACTION="configure"; shift ;;
    status) ACTION="status"; shift ;;
    restore|reset) ACTION="restore"; shift ;;
    -h|--help|help) usage; exit 0 ;;
    --mirror)
      [[ $# -ge 2 ]] || { tulan_error "缺少 --mirror 参数"; exit 1; }
      export DOCKER_REGISTRY_MIRROR="$2"
      export TULAN_DOCKER_REGISTRY_MIRROR="$2"
      CLI_SET=true
      shift 2
      ;;
    --log-driver)
      [[ $# -ge 2 ]] || { tulan_error "缺少 --log-driver 参数"; exit 1; }
      export DOCKER_LOG_DRIVER="$2"
      export TULAN_DOCKER_LOG_DRIVER="$2"
      CLI_SET=true
      shift 2
      ;;
    --log-max-size)
      [[ $# -ge 2 ]] || { tulan_error "缺少 --log-max-size 参数"; exit 1; }
      export DOCKER_LOG_MAX_SIZE="$2"
      export TULAN_DOCKER_LOG_MAX_SIZE="$2"
      CLI_SET=true
      shift 2
      ;;
    --log-max-file)
      [[ $# -ge 2 ]] || { tulan_error "缺少 --log-max-file 参数"; exit 1; }
      export DOCKER_LOG_MAX_FILE="$2"
      export TULAN_DOCKER_LOG_MAX_FILE="$2"
      CLI_SET=true
      shift 2
      ;;
    --log-compress) export TULAN_DOCKER_LOG_COMPRESS=true; CLI_SET=true; shift ;;
    --no-log-compress) export TULAN_DOCKER_LOG_COMPRESS=false; CLI_SET=true; shift ;;
    -y|--yes) export DOCKER_SKIP_PROMPT=true; shift ;;
    *)
      tulan_error "未知参数: $1"
      usage
      exit 1
      ;;
  esac
done

main() {
  load_defaults_if_needed

  case "$ACTION" in
    configure)
      tulan_docker_require_linux || exit 1
      if [[ "$CLI_SET" == true ]]; then
        export DOCKER_SKIP_PROMPT=true
      fi
      tulan_docker_prompt_config || exit 1
      tulan_docker_backup_daemon || exit 1
      tulan_docker_apply_daemon_config \
        "$TULAN_DOCKER_REGISTRY_MIRROR" \
        "$TULAN_DOCKER_LOG_DRIVER" \
        "$TULAN_DOCKER_LOG_MAX_SIZE" \
        "$TULAN_DOCKER_LOG_MAX_FILE" \
        "$TULAN_DOCKER_LOG_COMPRESS"
      ;;
    status)
      tulan_docker_require_linux || exit 1
      tulan_docker_show_config_status
      ;;
    restore)
      tulan_docker_require_linux || exit 1
      tulan_docker_restore_daemon
      ;;
    *)
      tulan_error "未知子命令: ${ACTION}"
      usage
      exit 1
      ;;
  esac
}

main "$@"
