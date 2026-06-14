# tulan-tools

仓库地址：[github.com/guangee/tulan-tools](https://github.com/guangee/tulan-tools)

个人开发工具集，命令行入口为 **`brew`**（用法与 Homebrew 类似）。安装后自动配置 shell 环境，支持从 Git 仓库同步更新，并统一管理常用命令行工具和私有软件包。

适用于 Debian、Ubuntu、CentOS 及 macOS。

> **macOS 注意**：若已安装 [Homebrew](https://brew.sh)，系统自带 `/opt/homebrew/bin/brew`，与本工具集命令同名。Linux 服务器可正常使用；Mac 上建议主要在 Linux 环境使用，或调整 PATH 顺序避免冲突。

## 安装

**手动克隆安装（项目固定在 `~/.tulan-tools`）：**

```bash
git clone git@github.com:guangee/tulan-tools.git ~/.tulan-tools
cd ~/.tulan-tools
./install.sh --local
source ~/.bashrc   # 或 source ~/.zshrc
```

**远程一键安装：**

```bash
curl -fsSL https://gh.coding-space.cn/https://raw.githubusercontent.com/guangee/tulan-tools/master/install.sh | bash
```

## 日常使用

| 命令 | 作用 |
|------|------|
| `brew list` | 查看可安装的工具与软件包 |
| `brew versions <名称>` | 查看版本（索引/上游/已装） |
| `brew install <名称>` | 安装指定项（默认最新版） |
| `brew use <工具> <版本>` | 切换二进制激活版本 |
| `brew remove <名称>` | 移除已安装项 |
| `brew update` | 更新 tulan-tools |

**不会默认安装全部软件**。请先 `brew list`，再按需 `brew install`。

```bash
brew list
brew versions kubectl
brew install kubectl          # 安装 bin 索引最新版
brew install kubectl mc       # 安装多个
brew install my-tool          # 安装私有包
```

## 二进制工具（Cellar 多版本）

```bash
brew install kubectl --version v1.32.0 --source upstream
brew use kubectl v1.32.0
brew list --installed
```

- 实体：`~/.tulan-tools/cellar/<工具>/<版本>/`
- 命令：`~/.tulan-tools/bin/`（符号链接）
- 索引刷新：`brew install --refresh-manifest`（安装二进制时）

## OpenJDK 与 Maven

Linux 默认从 **bin 分支** 安装归档（CI 定期同步）；macOS 或无 bin 归档时自动回退上游。支持多版本并存并一键切换 `JAVA_HOME`：

```bash
brew install openjdk-8 openjdk-11 openjdk-17
brew install maven
brew versions java              # 查看各版本与当前 JAVA_HOME
brew use java 11                # 切换到 Java 11
brew use java 17                # 切换到 Java 17
source ~/.bashrc                # 或 source ~/.zshrc
java -version
mvn -version
```

- bin 归档：`bin` 分支 `linux-*/archives/openjdk-*.tar.gz`、`apache-maven-bin.tar.gz`
- JDK 目录：`~/.tulan-tools/cellar/openjdk-<8|11|17>/<版本>/`
- Maven：`~/.tulan-tools/cellar/maven/<版本>/`，命令链接 `~/.tulan-tools/bin/mvn`
- `JAVA_HOME` 写入 `~/.tulan-tools/state/env.sh`，`java` 链接到 `~/.tulan-tools/bin/`
- 强制上游：`brew install openjdk-11 --source upstream`

## Node.js

Linux 默认从 **bin 分支** 安装归档；其他平台回退 [nodejs.org](https://nodejs.org/) 上游。支持 16 / 18 / 20 / 22 / 24 多版本并存并一键切换：

```bash
brew install node-16 node-18 node-20 node-22 node-24
brew versions node              # 查看各版本与当前 NODE_HOME
brew use node 20                # 切换到 Node 20
brew use node 22                # 切换到 Node 22
source ~/.bashrc                # 或 source ~/.zshrc
node -v && npm -v
```

- bin 归档：`bin` 分支 `linux-*/archives/node-*.tar.gz`
- 目录：`~/.tulan-tools/cellar/node-<16|18|20|22|24>/<版本>/`
- `NODE_HOME` 写入 `~/.tulan-tools/state/env.sh`，`node`/`npm` 链接到 `~/.tulan-tools/bin/`
- 强制上游：`brew install node-20 --source upstream`

## Docker Engine

Linux 默认从 **bin 分支** 安装官方静态包（含 `docker`、`dockerd`、`containerd` 等）；无 bin 归档时回退上游：

```bash
brew install docker
brew versions docker
brew use docker 29.5.3
sudo dockerd                    # 启动守护进程
docker version
```

- bin 归档：`bin` 分支 `linux-*/archives/docker.tar.gz`
- 目录：`~/.tulan-tools/cellar/docker/<版本>/docker/`
- 命令链接：`~/.tulan-tools/bin/docker`、`dockerd`、`containerd`、`runc` 等
- 安装后尝试写入 `/etc/docker/daemon.json`（registry 镜像，需 sudo）
- 强制上游：`brew install docker --source upstream`

## 环境安装

```bash
brew conda     # Miniconda + 阿里云源
brew vim       # vimrc + 默认编辑器
brew time      # 东八区时区 + 国内 NTP 测速同步（需 sudo）
brew fonts     # 中文字体 + fontconfig + zh_CN locale（需 sudo）
brew mirrors   # pip / npm / Go 国内镜像；--repo 切换系统软件源
```

`brew time` 会探测 `config/ntp.servers.cn` 中的国内 NTP 源，自动选用延迟最低的服务器，并将系统时区设为 `Asia/Shanghai`（东八区）。可用 `brew time probe` 仅查看测速结果。

`brew fonts` 会安装 Noto CJK 与文泉驿字体，写入 `config/fonts.cn.conf` 到 fontconfig，并生成 `zh_CN.UTF-8` locale，确保终端与 GUI 常见汉字可正常显示。

`brew mirrors` 配置 pip（阿里云 PyPI）、npm（npmmirror）、Go（goproxy.cn）国内镜像。使用 `brew mirrors --repo` 可将 Debian / Ubuntu / CentOS 系统软件源切换为阿里云镜像，并在 `state/repo-backup/` 保留备份；`brew mirrors restore --repo` 可还原为原版源。

## K8s / Rancher 单机安装

基于 `scripts/k8s` 脚本，通过 Docker 部署 Rancher（内置 k3s）：

```bash
brew k8s ca          # 生成自签证书（/etc/certs）
brew k8s install     # 安装 Rancher（需 Docker + sudo）
brew k8s password    # 获取初始 Bootstrap 密码
brew k8s status
brew help k8s
```

脚本目录：`~/.tulan-tools/scripts/k8s/`，详细说明见该目录下 `README.md`。

## Docker 测试镜像

`docker/` 目录提供 Ubuntu 22.04/24.04/26.04、Debian 12、CentOS 7.8/7.9 的 Dockerfile，用于验证安装与 `brew time` / `brew mirrors`：

```bash
./docker/test.sh              # 构建并测试全部镜像
./docker/test.sh ubuntu-22.04 # 仅测试指定镜像
```

## 管理私有软件包

```bash
cp -r packages/_template packages/my-tool
brew list --pkgs
brew versions my-tool
brew install my-tool
brew remove my-tool
```

## 自定义别名

编辑 `~/.tulan-tools/lib/aliases.sh`。

## 卸载 tulan-tools

```bash
cd ~/.tulan-tools
./uninstall.sh --remove-dir
```
