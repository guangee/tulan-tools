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

用法: brew help [主题]

命令:
  brew list                    查看可安装的工具与软件包
  brew versions <名称>         查看版本信息
  brew install <名称>...       安装（默认最新版，需指定名称）
  brew use <工具> <版本>       切换二进制 / Java / Node 版本
  brew uninstall <名称>        卸载
  brew update                  更新 tulan-tools
  brew docker / conda / vim    环境安装

自定义配置:
  编辑 ${TULAN_HOME}/lib/aliases.sh

查看子命令详细帮助:
  brew help install
  brew help list
  brew help docker
  brew help conda
  brew help vim
EOF
}

help_update() {
  cat <<EOF
brew update — 更新 tulan-tools

  brew update           从 Git 拉取最新代码
  brew update --force   立即更新，不等待每日限制
EOF
}

help_install() {
  cat <<EOF
brew install — 安装工具或软件包（类似 brew install）

  brew list                         先查看可安装项
  brew versions kubectl             查看版本
  brew install kubectl              安装最新版（bin 索引）
  brew install kubectl mc           安装多个
  brew install my-tool              安装私有包
  brew install kubectl --version v1.32.0 --source upstream
  brew use kubectl v1.32.0          切换激活版本
  brew install openjdk-8 openjdk-11 openjdk-17   # Linux 默认 bin 归档
  brew install maven
  brew use java 11                  切换 JAVA_HOME
  brew install node-16 node-18 node-20 node-22 node-24
  brew use node 20                  切换 NODE_HOME
  brew install node-20 --source upstream       # 强制上游

多版本: ${TULAN_HOME}/cellar/<工具>/<版本>/
链接:   ${TULAN_HOME}/bin/
Java:   ~/.bashrc / ~/.zshrc 中的 # >>> tulan-java >>> 块
Node:   ~/.bashrc / ~/.zshrc 中的 # >>> tulan-node >>> 块
EOF
}

help_list() {
  cat <<EOF
brew list — 查看可安装项

  brew list                 全部（二进制 + 私有包）
  brew list --binaries      仅二进制工具
  brew list --pkgs          仅私有软件包
  brew list --installed     仅已安装项

安装前请先 list，再 brew install <名称>
EOF
}

help_docker() {
  cat <<EOF
brew docker — 安装 Docker

  brew docker                      安装 Docker（默认阿里云 CE 源）
  brew docker fetch                下载官方脚本到本地缓存
  brew docker configure            仅配置 registry 镜像加速
EOF
}

help_conda() {
  cat <<EOF
brew conda — 安装 Miniconda

  brew conda                         安装并配置（默认 ~/miniconda3）
  brew conda configure               仅配置阿里云源与 shell
EOF
}

help_vim() {
  cat <<EOF
brew vim — 安装 vimrc 与默认编辑器

  brew vim                           完整安装
  brew vim configure                 仅配置编辑器
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
