# tulan-tools

类似 [oh-my-zsh](https://ohmyz.sh/) 的个人开发工具集，通过 Git 仓库自动同步更新，安装时自动配置 shell 环境，并支持发布私有软件包到 Debian/Ubuntu/CentOS 系统。

## 特性

- **Git 自动更新** — 每次打开终端时静默检查更新（每天最多一次），也可手动 `tulan-update`
- **Shell 自动配置** — 安装时自动向 `~/.bashrc` 和 `~/.zshrc` 注入 PATH 和别名
- **私有软件包** — 在 `packages/` 目录管理自己的工具，一键安装/卸载
- **多发行版支持** — 兼容 Debian、Ubuntu、CentOS/RHEL（apt/yum/dnf）
- **系统包构建** — 可打包为 `.deb` / `.rpm` 用于批量部署
- **二进制分发** — 主仓库记录路径，客户端通过 GitHub 公开链接下载（无需 git-lfs）

## 目录结构

```
tulan-tools/
├── install.sh              # 安装入口
├── uninstall.sh            # 卸载脚本
├── config/
│   └── binaries.manifest.json  # 二进制路径清单
├── bin/                    # 用户命令（自动加入 PATH）
│   ├── tulan-update
│   ├── tulan-install-pkg
│   ├── tulan-list-pkgs
│   ├── tulan-uninstall-pkg
│   └── tulan-download-binaries
├── lib/
│   ├── common.sh           # 公共函数（OS 检测、shell 配置、git 同步）
│   ├── binaries.sh         # 从 GitHub 公开链接下载二进制
│   ├── package.sh          # 软件包管理
│   └── aliases.sh          # 自定义别名（可编辑）
├── packages/               # 私有软件包
│   ├── _template/          # 新包模板
│   └── example-tool/       # 示例包
└── scripts/
    ├── update.sh           # 自动更新逻辑
    ├── download-binaries.sh
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

## 常用命令

| 命令 | 说明 |
|------|------|
| `tulan-update` | 手动从 Git 拉取最新代码 |
| `tulan-update --force` | 强制更新（忽略 24h 限制） |
| `tulan-list-pkgs` | 列出可用软件包 |
| `tulan-list-pkgs --installed` | 列出已安装软件包 |
| `tulan-install-pkg <名>` | 安装私有软件包 |
| `tulan-uninstall-pkg <名>` | 卸载私有软件包 |
| `tulan-download-binaries` | 下载 kubectl、docker-compose、mc |

## 二进制分发（无需客户端 git-lfs）

主仓库 `main` 分支**只记录文件路径**，实际二进制存在 `bin` 分支（GitHub LFS，仅 CI 使用）。

客户端通过公开 HTTP 链接直接下载，**不需要安装 git-lfs**：

```
main 分支                          bin 分支（LFS，仅 CI 维护）
config/binaries.manifest.json  →   linux-amd64/kubectl
  ├─ 文件路径                       linux-amd64/docker-compose
  ├─ 版本号                         linux-amd64/mc
  └─ SHA256                         linux-arm64/...
         │
         ▼
curl https://media.githubusercontent.com/media/{owner}/{repo}/bin/linux-amd64/kubectl
```

### 客户端下载

```bash
# 默认从 GitHub bin 分支下载（读取本地 manifest）
tulan-download-binaries

# 指定仓库（manifest 中 repository 为空时）
TULAN_GITHUB_REPO=yourname/tulan-tools tulan-download-binaries

# 远程安装场景：直接指定 manifest 地址
TULAN_MANIFEST_URL=https://raw.githubusercontent.com/yourname/tulan-tools/main/config/binaries.manifest.json \
  tulan-download-binaries

# 回退到上游官方源
tulan-download-binaries --source upstream
```

### CI 自动同步

`Sync Binaries` 工作流（每周一自动 / 可手动触发）：
1. 从上游下载最新 kubectl、docker-compose、mc（linux amd64/arm64）
2. 推送到 `bin` 分支（LFS 存储）
3. 更新 `main` 分支的 `config/binaries.manifest.json`（路径 + 版本 + SHA256）

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
| `TULAN_GITHUB_REPO` | 二进制仓库，如 `yourname/tulan-tools` | manifest 中配置 |
| `TULAN_MANIFEST_URL` | 远程 manifest 地址 | 本地 manifest 文件 |

## GitHub Actions

推送到 GitHub 后，仓库内置三个自动化工作流：

| 工作流 | 文件 | 触发条件 | 作用 |
|--------|------|----------|------|
| CI | `.github/workflows/ci.yml` | PR / push 到 main | Shellcheck、语法检查 |
| Sync Binaries | `.github/workflows/sync-binaries.yml` | 每周一 / 手动触发 | 同步二进制到 `bin` 分支，更新 manifest |
| Release | `.github/workflows/release.yml` | 推送 `v*` tag | 自动创建 GitHub Release |

推送 tag 发布版本：

```bash
git tag v1.0.0
git push origin v1.0.0
```

## 许可证

私有项目，仅供个人/团队内部使用。
