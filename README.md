# tulan-tools

类似 [oh-my-zsh](https://ohmyz.sh/) 的个人开发工具集，通过 Git 仓库自动同步更新，安装时自动配置 shell 环境，并支持发布私有软件包到 Debian/Ubuntu/CentOS 系统。

## 特性

- **Git 自动更新** — 每次打开终端时静默检查更新（每天最多一次），也可手动 `tulan-update`
- **Shell 自动配置** — 安装时自动向 `~/.bashrc` 和 `~/.zshrc` 注入 PATH 和别名
- **私有软件包** — 在 `packages/` 目录管理自己的工具，一键安装/卸载
- **多发行版支持** — 兼容 Debian、Ubuntu、CentOS/RHEL（apt/yum/dnf）
- **系统包构建** — 可打包为 `.deb` / `.rpm` 用于批量部署
- **Docker 工具镜像** — 基于 Apache2 的镜像预装 kubectl、docker-compose、mc，推送到 Docker Hub 后本地直接引用

## 目录结构

```
tulan-tools/
├── install.sh              # 安装入口
├── uninstall.sh            # 卸载脚本
├── bin/                    # 用户命令（自动加入 PATH）
│   ├── tulan-update
│   ├── tulan-install-pkg
│   ├── tulan-list-pkgs
│   ├── tulan-uninstall-pkg
│   ├── tulan-docker-start / tulan-docker-stop
│   ├── tulan-exec / tulan-kubectl / tulan-mc / tulan-compose
│   └── tulan-download-binaries
├── docker/                 # 工具镜像 Dockerfile
│   ├── Dockerfile
│   ├── build.sh
│   └── install-tools.sh
├── docker-compose.yml      # 引用 Docker Hub 镜像
├── .env.example            # 镜像地址配置
├── lib/
│   ├── common.sh           # 公共函数（OS 检测、shell 配置、git 同步）
│   ├── package.sh          # 软件包管理
│   └── aliases.sh          # 自定义别名（可编辑）
├── packages/               # 私有软件包
│   ├── _template/          # 新包模板
│   └── example-tool/       # 示例包
└── scripts/
    ├── update.sh           # 自动更新逻辑
    ├── build-package.sh    # 构建 tulan-tools 本体 deb/rpm
    └── build-pkg.sh        # 构建单个私有包 deb/rpm
```

## 快速开始

### 方式一：从 Git 仓库安装（推荐）

```bash
# 克隆并安装
git clone git@github.com:you/tulan-tools.git
cd tulan-tools
./install.sh --local

# 或远程一键安装
curl -fsSL https://your-server/raw/main/install.sh | bash -s -- \
  --repo git@github.com:you/tulan-tools.git
```

### 方式二：安装系统包（批量部署）

```bash
# 构建 deb 包
./scripts/build-package.sh --version 1.0.0 --format deb

# 在目标机器安装
sudo dpkg -i dist/tulan-tools_1.0.0_deb.deb

# CentOS/RHEL
sudo rpm -i dist/tulan-tools_1.0.0_rpm.rpm
```

安装后执行 `source ~/.bashrc` 或重新打开终端。

## Docker 工具镜像

将常用二进制维护在基于 **Debian + Apache2** 的 Docker 镜像中，构建后推送到 Docker Hub，本地项目只需指向该镜像即可。

### 架构

```
docker/Dockerfile  →  构建镜像  →  Docker Hub
                                        ↓
docker-compose.yml  ←  引用镜像地址（.env 配置）
        ↓
tulan-docker-start  →  启动容器
tulan-kubectl/mc/compose  →  通过容器执行命令
```

### 1. 构建并推送镜像

```bash
# 本地测试构建
./docker/build.sh --load --image yourname/tulan-binaries

# 登录 Docker Hub 并推送（支持 amd64 + arm64）
docker login
./docker/build.sh --push --image yourname/tulan-binaries --tag latest
```

镜像内预装工具（构建时自动拉取最新版）：
- `kubectl`
- `docker-compose`
- `mc` (MinIO Client)
- Apache2（端口 80，可用于健康检查）

### 2. 配置本地项目

```bash
cp .env.example .env
# 编辑 .env，填写你的 Docker Hub 镜像地址
# TULAN_DOCKER_IMAGE=yourname/tulan-binaries
```

### 3. 启动并使用

```bash
# 启动容器（后台运行，Apache 映射到 18080）
tulan-docker-start

# 通过容器执行命令
tulan-kubectl get nodes
tulan-mc ls myminio
tulan-compose -f app/docker-compose.yml up -d

# 通用入口
tulan-exec kubectl version --client

# 停止容器
tulan-docker-stop
```

安装 tulan-tools 后，`kubectl`、`mc`、`docker-compose` 会自动别名到容器版本（见 `lib/aliases.sh`）。

### 挂载说明

`docker-compose.yml` 默认挂载：
- `~/.kube` — kubectl 配置（只读）
- `~/.mc` — MinIO Client 配置
- 当前项目目录 → `/workspace` — docker-compose 工作目录

## 常用命令

| 命令 | 说明 |
|------|------|
| `tulan-update` | 手动从 Git 拉取最新代码 |
| `tulan-update --force` | 强制更新（忽略 24h 限制） |
| `tulan-list-pkgs` | 列出可用软件包 |
| `tulan-list-pkgs --installed` | 列出已安装软件包 |
| `tulan-install-pkg <名>` | 安装私有软件包 |
| `tulan-uninstall-pkg <名>` | 卸载私有软件包 |
| `tulan-docker-start` | 启动工具容器 |
| `tulan-docker-stop` | 停止工具容器 |
| `tulan-exec <命令>` | 在容器内执行任意命令 |
| `tulan-kubectl` / `tulan-mc` / `tulan-compose` | 容器内工具快捷入口 |

## 发布私有软件包

### 1. 创建新包

```bash
cp -r packages/_template packages/my-tool
```

编辑 `packages/my-tool/manifest.json`：

```json
{
  "name": "my-tool",
  "version": "1.0.0",
  "description": "我的私有工具",
  "dependencies": ["curl", "jq"],
  "platforms": ["debian", "ubuntu", "centos"],
  "bin": ["my-tool"]
}
```

### 2. 添加可执行文件

```
packages/my-tool/
├── manifest.json
├── install.sh       # 安装逻辑（可选）
├── uninstall.sh     # 卸载逻辑（可选）
└── bin/
    └── my-tool      # 命令入口
```

`install.sh` 中可使用环境变量：

- `TULAN_PKG_NAME` — 包名
- `TULAN_PKG_VERSION` — 版本
- `TULAN_PKG_DIR` — 包目录路径

### 3. 安装与分发

```bash
# 本地安装（从 git 仓库）
tulan-install-pkg my-tool

# 构建独立 deb/rpm 包分发
./scripts/build-pkg.sh my-tool --format all
# 输出: dist/packages/my-tool_1.0.0.deb
```

## Shell 配置说明

安装时会在 `~/.bashrc` 和 `~/.zshrc` 中注入标记区块：

```bash
# >>> tulan-tools >>>
export TULAN_TOOLS_HOME="$HOME/.tulan-tools"
export PATH="${TULAN_TOOLS_HOME}/bin:${PATH}"
# ...
# <<< tulan-tools <<<
```

卸载时运行 `./uninstall.sh` 会自动清除该区块。

## 构建依赖

构建 deb/rpm 包需要 [fpm](https://github.com/jordansissel/fpm)：

```bash
# Debian/Ubuntu
sudo apt-get install -y ruby ruby-dev build-essential
sudo gem install fpm

# CentOS/RHEL
sudo yum install -y ruby ruby-devel gcc make
sudo gem install fpm
```

## 卸载

```bash
./uninstall.sh              # 仅移除 shell 配置
./uninstall.sh --remove-dir # 同时删除 ~/.tulan-tools
```

## 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `TULAN_TOOLS_HOME` | 安装目录 | `~/.tulan-tools` |
| `TULAN_TOOLS_DEFAULT_REPO` | 默认 Git 仓库地址 | — |

## GitHub Actions

推送到 GitHub 后，仓库内置三个自动化工作流：

| 工作流 | 文件 | 触发条件 | 作用 |
|--------|------|----------|------|
| CI | `.github/workflows/ci.yml` | PR / push 到 main | Shellcheck、语法检查、Docker 构建测试 |
| Docker Publish | `.github/workflows/docker-publish.yml` | push main（docker 目录变更）、打 tag、手动触发 | 多平台构建并推送 Docker Hub |
| Release | `.github/workflows/release.yml` | 推送 `v*` tag | 自动创建 GitHub Release |

### 配置 Docker Hub Secrets

在 GitHub 仓库 **Settings → Secrets and variables → Actions** 中添加：

| Secret | 说明 |
|--------|------|
| `DOCKERHUB_USERNAME` | Docker Hub 用户名 |
| `DOCKERHUB_TOKEN` | Docker Hub Access Token（非登录密码） |

Token 创建：Docker Hub → Account Settings → Security → New Access Token

### 镜像标签规则

- 推送到 `main` 分支 → `yourname/tulan-binaries:latest`
- 推送 tag `v1.2.3` → `yourname/tulan-binaries:1.2.3` 和 `:1.2`
- 每次构建同时打上 commit SHA 短标签

推送 tag 发布版本：

```bash
git tag v1.0.0
git push origin v1.0.0
```

本地 `.env` 中配置对应镜像：

```
TULAN_DOCKER_IMAGE=yourname/tulan-binaries
TULAN_DOCKER_TAG=latest
```

## 许可证

私有项目，仅供个人/团队内部使用。
