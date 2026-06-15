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
  brew conda / vim / time / fonts / mirrors / docker / zsh / firewall / k8s  环境安装

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
  brew help docker
  brew help zsh
  brew help firewall
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

help_docker() {
  cat <<EOF
brew docker — Docker 守护进程配置（daemon.json）

  brew docker configure              交互配置镜像加速与日志轮转
  brew docker status                 查看 daemon.json 与配置记录
  brew docker restore                从备份还原 daemon.json

  brew docker --mirror <url>         指定镜像加速
  brew docker --log-driver json-file 日志驱动（json-file / local）
  brew docker --log-max-size 10m     单日志文件大小
  brew docker --log-max-file 3       日志保留份数
  brew docker --log-compress         压缩 json-file 轮转日志
  brew docker -y                     跳过交互

默认模板: ${TULAN_HOME}/config/docker.daemon.defaults.json
配置备份: ${TULAN_HOME}/state/docker-backup/
状态记录: ${TULAN_HOME}/state/docker-config.json

安装 Docker 二进制: brew install docker
EOF
}

help_zsh() {
  cat <<EOF
brew zsh — zsh 历史指令提示（Oh My Zsh + zsh-autosuggestions）

  brew zsh                         安装插件并加入 ~/.zshrc plugins（已配置则跳过）
  brew zsh --refresh               强制更新已安装的插件仓库
  brew zsh status                  查看 zsh / Oh My Zsh 状态

  未检测到 Oh My Zsh 时自动跳过，不修改配置
  插件路径: \${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
  仓库: https://git.tulan.wang/github/zsh-autosuggestions.git
EOF
}

help_firewall() {
  cat <<EOF
brew firewall — 防火墙端口开放/关闭（多后端兼容）

  brew firewall status                   查看各防火墙组件状态
  brew firewall open <port>              开放端口（自动选择后端）
  brew firewall open 8443/tcp
  brew firewall close <port>             关闭端口
  brew firewall disable                  关闭全部防火墙
  brew firewall disable --restart-docker -y   关防火墙并重启 Docker
  brew firewall enable                   启用 ufw 或 firewalld

  兼容: firewalld、ufw、iptables、nftables
  Debian/Ubuntu 常用 ufw 或 iptables；CentOS/RHEL 常用 firewalld 或 iptables
  需要 sudo
EOF
}

help_dns() {
  cat <<EOF
brew dns — 自动测速并修复系统 DNS

  brew dns fix                         测速 + 修复（默认，需 sudo）
  brew dns fix -y                      跳过确认
  brew dns status                      查看当前 DNS / 诊断
  brew dns probe                       仅测速公共 DNS
  brew dns fix --no-probe --servers 223.5.5.5 223.6.6.6 -y

  自动识别 systemd-resolved / NetworkManager / netplan
  可修复 [::1]:53、127.0.0.53 等无效 DNS 导致的镜像拉取失败
  K8s 节点可用: brew k8s fix-dns（同 fix）
  需要 sudo
EOF
}

help_k8s() {
  cat <<EOF
brew k8s — Rancher 单机 K8s 快捷安装（scripts/k8s）

  brew k8s ca                        生成自签证书（交互输入域名，自动检测局域网 IP）
  brew k8s ca -d <domain>            指定域名生成证书
  brew k8s ca-clean                  交互选择要清理的域名证书
  brew k8s ca-clean -d <domain>      清理指定域名证书
  brew k8s ca-clean -a               清理全部域名证书及 CA
  brew k8s install                   安装 Rancher（交互选择证书与端口）
  brew k8s install -d <domain>       指定证书安装
  brew k8s install --https-port 9443 指定 HTTPS 端口（默认 8443）
  brew k8s ports                     修改已部署实例的 HTTP/HTTPS 端口
  brew k8s ports --https-port 9443 -y  非交互修改 HTTPS 端口
  brew k8s sync-versions             开发用：手动同步版本到本地 state
  brew k8s upgrade                   交互选择升级目标版本（列表来自 brew update）
  brew k8s upgrade -V v2.13.3        指定版本升级
  brew k8s upgrade --image rancher/rancher:v2.13.3
  brew k8s password                  获取 Bootstrap 初始密码
  brew k8s clean                     清理 K8s/Rancher（危险）
  brew k8s sync-registries -f nodes.txt   同步镜像源到节点
  brew k8s shell-init                配置 kubectl/crictl 别名
  brew k8s status                    查看状态
  brew k8s register-url              查看内网节点注册地址（推荐局域网节点使用）
  brew k8s register-url --format url 仅输出内网 URL（便于脚本）
  brew k8s register-url --public     查看域名/外网地址
  brew k8s register-url --set -y     将 Rancher server-url 改为内网地址
  brew k8s register-command          内网版节点注册命令（UI 仍显示外网时用此命令）
  brew k8s register-command -c <名>  指定集群
  brew k8s register-command --format command  仅输出一行可执行命令
  brew k8s register-command --from-url https://nginx.example.com  额外替换 nginx 入口
  brew k8s node-status                 在节点上查看注册/Agent 状态
  brew k8s node-status -v              附带 journal 日志
  brew k8s node-pull                   查看镜像拉取进度与 registry 网络
  brew k8s node-pull -f                持续跟踪 agent 拉取日志
  brew k8s node-restart master -y      重启 master（rke2-server）
  brew k8s node-restart worker -y      重启 worker（rke2-agent）
  brew k8s node-watch                  持续监控节点状态/镜像
  brew k8s node-watch -i 3             每 3 秒刷新
  brew k8s node-restart master -y      重启 master（rke2-server）
  brew k8s node-restart worker -y      重启 worker（rke2-agent）
  brew k8s node-watch                  持续监控节点状态/镜像
  brew k8s node-watch -i 3             每 3 秒刷新
  brew k8s fix-dns                     修复节点 DNS（测速 + 自动配置）
  brew k8s fix-dns -y
  brew k8s node-clean                  清理节点注册数据（便于重新注册）
  brew k8s node-clean -y               跳过确认
  brew k8s images                      查看 Docker + containerd 已拉取镜像

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
    docker|dockerd|docker-config) help_docker ;;
    zsh|oh-my-zsh|autosuggestions) help_zsh ;;
    firewall|fw|ufw) help_firewall ;;
    dns|resolv|nameserver) help_dns ;;
    k8s|k8s-init|rancher) help_k8s ;;
    *)
      echo "未知主题: $1"
      echo "可用主题: install, list, update, conda, vim, time, fonts, mirrors, docker, zsh, firewall, k8s"
      exit 1
      ;;
  esac
}

main "$@"
