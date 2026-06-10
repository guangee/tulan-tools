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
  tulan list                    查看可安装的工具与软件包
  tulan versions <名称>         查看版本信息
  tulan install <名称>...       安装（默认最新版，需指定名称）
  tulan use <工具> <版本>       切换二进制版本
  tulan uninstall <名称>        卸载
  tulan update                  更新 tulan-tools
  tulan docker / conda / vim    环境安装

自定义配置:
  编辑 ${TULAN_HOME}/lib/aliases.sh

查看子命令详细帮助:
  tulan help install
  tulan help list
  tulan help docker
  tulan help conda
  tulan help vim
EOF
}

help_update() {
  cat <<EOF
tulan update — 更新 tulan-tools

  tulan update           从 Git 拉取最新代码
  tulan update --force   立即更新，不等待每日限制
EOF
}

help_install() {
  cat <<EOF
tulan install — 安装工具或软件包（类似 brew install）

  tulan list                         先查看可安装项
  tulan versions kubectl             查看版本
  tulan install kubectl              安装最新版（bin 索引）
  tulan install kubectl mc           安装多个
  tulan install my-tool              安装私有包
  tulan install kubectl --version v1.32.0 --source upstream
  tulan use kubectl v1.32.0          切换激活版本

多版本: ${TULAN_HOME}/cellar/<工具>/<版本>/
链接:   ${TULAN_HOME}/bin/
EOF
}

help_list() {
  cat <<EOF
tulan list — 查看可安装项

  tulan list                 全部（二进制 + 私有包）
  tulan list --binaries      仅二进制工具
  tulan list --pkgs          仅私有软件包
  tulan list --installed     仅已安装项

安装前请先 list，再 tulan install <名称>
EOF
}

help_docker() {
  cat <<EOF
tulan docker — 安装 Docker

  tulan docker                      安装 Docker（默认阿里云 CE 源）
  tulan docker fetch                下载官方脚本到本地缓存
  tulan docker configure            仅配置 registry 镜像加速
EOF
}

help_conda() {
  cat <<EOF
tulan conda — 安装 Miniconda

  tulan conda                         安装并配置（默认 ~/miniconda3）
  tulan conda configure               仅配置阿里云源与 shell
EOF
}

help_vim() {
  cat <<EOF
tulan vim — 安装 vimrc 与默认编辑器

  tulan vim                           完整安装
  tulan vim configure                 仅配置编辑器
EOF
}

main() {
  case "${1:-}" in
    ""|-h|--help) usage ;;
    update) help_update ;;
    install|download|binaries) help_install ;;
    list|versions|pkg|package) help_list ;;
    docker) help_docker ;;
    conda|miniconda) help_conda ;;
    vim|vimrc) help_vim ;;
    *)
      echo "未知主题: $1"
      echo "可用主题: install, list, update, docker, conda, vim"
      exit 1
      ;;
  esac
}

main "$@"
