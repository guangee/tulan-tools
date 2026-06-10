#!/usr/bin/env bash
# tulan-tools 帮助信息

set -euo pipefail

_SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "${_SCRIPT_ROOT}/lib/common.sh"

TULAN_HOME="$(tulan_get_home)"

usage() {
  cat <<EOF
tulan-tools — 个人开发工具集
仓库: https://github.com/guangee/tulan-tools
安装目录: ${TULAN_HOME}

用法: tulan help [主题]

命令:
  tulan                         显示本帮助
  tulan update                  拉取仓库最新代码
  tulan update --force          强制更新（忽略 24 小时限制）
  tulan download                下载 kubectl、docker-compose、mc
  tulan list                    查看二进制工具和私有软件包
  tulan list --installed        查看已安装项
  tulan list --binaries         仅查看 kubectl、docker-compose、mc
  tulan install <包名>          安装软件包
  tulan uninstall <包名>        卸载软件包

下载选项:
  tulan download --tool kubectl           仅下载 kubectl
  tulan download --refresh-manifest       强制刷新 bin 分支索引缓存
  tulan download --debug                  显示实际下载 URL
  tulan download --no-proxy             禁用 GitHub 代理
  tulan download --source upstream        从官方源下载

自定义配置:
  编辑 ${TULAN_HOME}/lib/aliases.sh

卸载:
  ${TULAN_HOME}/uninstall.sh
  ${TULAN_HOME}/uninstall.sh --remove-dir

查看子命令详细帮助:
  tulan help update
  tulan help download
  tulan help pkg
EOF
}

help_update() {
  cat <<EOF
tulan update — 更新 tulan-tools

  tulan update           从 Git 拉取最新代码
  tulan update --force   立即更新，不等待每日限制

打开终端时会自动静默检查更新（每天最多一次）。
EOF
}

help_download() {
  cat <<EOF
tulan download — 下载常用二进制工具

  tulan download                      下载全部（kubectl、docker-compose、mc）
  tulan download --tool kubectl       仅下载指定工具
  tulan download --refresh-manifest   从 bin 分支刷新索引缓存
  tulan download --debug              显示实际下载 URL
  tulan download --no-proxy           直连 GitHub
  tulan download --source upstream      从官方源下载

索引缓存: ${TULAN_HOME}/state/binaries.manifest.json（默认 24h 有效）
工具安装: ${TULAN_HOME}/bin
EOF
}

help_pkg() {
  cat <<EOF
tulan list / install / uninstall — 管理工具与软件包

  tulan list                 列出二进制工具 + 私有包
  tulan list --binaries      仅列出 kubectl、docker-compose、mc
  tulan list --pkgs          仅列出私有软件包
  tulan list --installed     列出已安装项
  tulan install <包名>       安装包
  tulan install <包名> --force  强制重装
  tulan uninstall <包名>     卸载包

软件包目录: ${TULAN_HOME}/packages/
新增包模板: ${TULAN_HOME}/packages/_template/
EOF
}

main() {
  case "${1:-}" in
    ""|-h|--help) usage ;;
    update)       help_update ;;
    download|binaries) help_download ;;
    pkg|package|packages|list) help_pkg ;;
    *)
      echo "未知主题: $1"
      echo "可用主题: update, download, pkg"
      exit 1
      ;;
  esac
}

main "$@"
