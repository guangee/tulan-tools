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
  brew remove <名称>           移除已安装项
  brew update                  更新 tulan-tools
  brew conda / vim / time / fonts / mirrors / k8s  环境安装

自定义配置:
  编辑 ${TULAN_HOME}/lib/aliases.sh

查看子命令详细帮助:
  brew help install
  brew help list
  brew help conda
  brew help vim
  brew help time
  brew help fonts
  brew help mirrors
  brew help k8s
EOF
}

help_update() {
  cat <<EOF
brew update — 更新 tulan-tools

  brew update           从 Git 拉取最新代码，并刷新 bin 分支索引
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
  brew install docker                          # Linux 静态包（bin 索引）
  brew install openjdk-8 openjdk-11 openjdk-17   # Linux 默认 bin 归档
  brew install maven
  brew use java 11                  切换 JAVA_HOME
  brew install node-16 node-18 node-20 node-22 node-24
  brew use node 20                  切换 NODE_HOME
  brew install node-20 --source upstream       # 强制上游
  brew install openjdk-17 --verbose            # 详细下载日志

多版本: ${TULAN_HOME}/cellar/<工具>/<版本>/
链接:   ${TULAN_HOME}/bin/
Java/Node: ~/.tulan-tools/state/env.sh（主配置块自动加载）
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

help_time() {
  cat <<EOF
brew time — 配置东八区时区与国内 NTP 同步

  brew time                          测速选最快 NTP + 东八区 + 同步
  brew time now                      显示东八区当前时间（+0800）
  brew time shell                    让 date 自动显示上海时区格式（无需 sudo）
  brew time probe                    仅探测各 NTP 延迟
  brew time status                   查看时区与 NTP 状态
  brew time --servers ntp.aliyun.com cn.ntp.org.cn

默认 NTP 列表: ${TULAN_HOME}/config/ntp.servers.cn
需要 sudo（Linux）
EOF
}

help_fonts() {
  cat <<EOF
brew fonts — 安装中文字体并配置 fontconfig

  brew fonts                         安装 Noto CJK + 文泉驿 + locale
  brew fonts status                  查看中文字体与 locale 状态
  brew fonts test                    测试中文渲染匹配
  brew fonts configure --user        仅用户级 fontconfig

fontconfig 模板: ${TULAN_HOME}/config/fonts.cn.conf
install 需要 sudo（Linux）
EOF
}

help_mirrors() {
  cat <<EOF
brew mirrors — 国内镜像配置（系统源 + pip / npm / Go）

  brew mirrors                       配置 pip + npm + Go 国内镜像
  brew mirrors --repo                Debian/Ubuntu/CentOS 切换国内软件源
  brew mirrors --all                 系统源 + pip + npm + Go
  brew mirrors restore --repo        还原系统软件源（优先从备份恢复）
  brew mirrors restore --all         还原全部镜像配置
  brew mirrors status                查看当前配置

系统源备份: ${TULAN_HOME}/state/repo-backup/
配置系统源需要 sudo（Linux）
EOF
}

help_k8s() {
  cat <<EOF
brew k8s — Rancher 单机 K8s 快捷安装（scripts/k8s）

  brew k8s ca                        生成自签证书（交互输入域名，自动检测局域网 IP）
  brew k8s ca -d <domain>            指定域名生成证书
  brew k8s ca-clean                  清理自签证书
  brew k8s install                   安装 Rancher（Docker）
  brew k8s password                  获取 Bootstrap 初始密码
  brew k8s upgrade                   升级 Rancher 版本
  brew k8s clean                     清理 K8s/Rancher（危险）
  brew k8s sync-registries -f nodes.txt   同步镜像源到节点
  brew k8s shell-init                配置 kubectl/crictl 别名
  brew k8s status                    查看状态

脚本目录: ${TULAN_HOME}/scripts/k8s/
详细说明: ${TULAN_HOME}/scripts/k8s/README.md
EOF
}

main() {
  case "${1:-}" in
    ""|-h|--help) usage ;;
    update) help_update ;;
    install|download|binaries) help_install ;;
    list|versions|pkg|package) help_list ;;
    conda|miniconda) help_conda ;;
    vim|vimrc) help_vim ;;
    time|timezone|ntp) help_time ;;
    fonts|font|cjk) help_fonts ;;
    mirrors|mirror) help_mirrors ;;
    k8s|k8s-init|rancher) help_k8s ;;
    *)
      echo "未知主题: $1"
      echo "可用主题: install, list, update, conda, vim, time, fonts, mirrors, k8s"
      exit 1
      ;;
  esac
}

main "$@"
