# tulan-tools

仓库地址：[github.com/guangee/tulan-tools](https://github.com/guangee/tulan-tools)

个人开发工具集，类似 oh-my-zsh。安装后自动配置 shell 环境，支持从 Git 仓库同步更新，并统一管理常用命令行工具和私有软件包。

适用于 Debian、Ubuntu、CentOS 等 Linux 系统。

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
# 国内推荐（GitHub 代理加速）
curl -fsSL https://gh.coding-space.cn/https://raw.githubusercontent.com/guangee/tulan-tools/master/install.sh | bash

# 直连 GitHub
curl -fsSL https://raw.githubusercontent.com/guangee/tulan-tools/master/install.sh | bash
```

项目始终安装在 `~/.tulan-tools`，并自动写入 `~/.bashrc` 和 `~/.zshrc`。

## 日常使用

所有功能通过统一命令 `tulan` 加子命令使用：

| 命令 | 作用 |
|------|------|
| `tulan` / `tulan help` / `help` | 查看帮助 |
| `tulan update` | 拉取仓库最新代码 |
| `tulan download` | 下载 kubectl、docker-compose、mc |
| `tulan list` | 查看二进制工具和私有软件包 |
| `tulan list --binaries` | 仅查看 kubectl、docker-compose、mc |
| `tulan install <包名>` | 安装软件包 |
| `tulan uninstall <包名>` | 卸载软件包 |
| `tulan docker` | 安装 Docker（阿里云源 + registry 镜像加速） |
| `tulan conda` | 安装 Miniconda（阿里云 conda/pip 源） |
| `tulan vim` | 安装 vimrc，配置 vim 为默认编辑器 |

打开新终端时会自动检查更新（每天最多一次），也可随时手动执行 `tulan update`。

## 下载常用工具

安装完成后，执行：

```bash
tulan download
tulan list --binaries    # 确认安装状态
```

工具会安装到 `~/.tulan-tools/bin`，可直接使用 `kubectl`、`docker-compose`、`mc`。

二进制**索引**在 `bin` 分支（`binaries.manifest.json`），使用时自动缓存到 `~/.tulan-tools/state/`。刷新索引默认经 [gh.coding-space.cn](https://gh.coding-space.cn/) 代理，失败时回退直连：
- `tulan update` 后自动刷新索引
- 超过 24 小时未刷新时，调用下载/列表命令会自动更新
- 可手动强制刷新：`tulan download --refresh-manifest`
- 排查下载问题：`tulan download --debug`（显示 manifest / 二进制直连与代理 URL）

默认通过 [gh.coding-space.cn](https://gh.coding-space.cn/) 代理加速，失败时自动回退直连：

```bash
tulan download --no-proxy          # 禁用代理
tulan download --source upstream   # 跳过索引，从官方源下载
```

## 安装 Docker

使用官方 `get.docker.com` 脚本，缓存到 `~/.tulan-tools/state/docker/`，默认通过**阿里云**安装 Docker CE，并配置 `https://hub.coding-space.cn` 为 registry 镜像加速：

```bash
tulan docker                        # 安装并配置
tulan docker configure              # 仅更新 registry 镜像配置
tulan docker fetch                  # 仅下载官方脚本
tulan docker --refresh-script       # 重新下载脚本后安装
```

## 安装 Miniconda

从**阿里云**下载 Miniconda 安装包（缓存到 `~/.tulan-tools/state/miniconda/`），安装到 `~/miniconda3`，并自动配置：

- `~/.condarc` — conda 阿里云源
- `~/.pip/pip.conf` — pip 阿里云源
- `~/.bashrc`、`~/.zshrc` — `conda init` 环境

```bash
tulan conda                         # 安装并配置
tulan conda configure               # 仅更新源与 shell 配置
tulan conda fetch                   # 仅下载安装包
tulan conda --prefix ~/miniconda3   # 自定义安装路径
```

安装后执行 `source ~/.bashrc` 或 `source ~/.zshrc` 生效。

## 安装 vimrc

自动检测并安装 vim，克隆 vimrc 到 `~/.vim_runtime`，执行官方安装脚本，并将 vim 设为默认编辑器（含 git merge）：

```bash
tulan vim                         # 完整安装
tulan vim configure               # 仅配置 EDITOR / git core.editor
tulan vim fetch                   # 仅克隆/更新 vimrc 仓库
tulan vim --refresh               # 强制重新克隆
```

配置项：
- `~/.bashrc`、`~/.zshrc` — `EDITOR=vim`、`VISUAL=vim`
- `git config --global core.editor vim` — 合并冲突等场景使用 vim
- Linux `update-alternatives` — 系统默认 `editor` 指向 vim

## 管理私有软件包

**新增一个包：**

```bash
cp -r packages/_template packages/my-tool
# 编辑 packages/my-tool/manifest.json
# 将可执行文件放到 packages/my-tool/bin/
```

**安装与卸载：**

```bash
tulan install my-tool
tulan uninstall my-tool
```

**查看状态：**

```bash
tulan list              # 全部可用包
tulan list --installed  # 已安装的包
```

## 自定义别名

编辑 `~/.tulan-tools/lib/aliases.sh`，保存后重新打开终端即可生效。

## 卸载

```bash
cd ~/.tulan-tools
./uninstall.sh              # 移除 shell 配置
./uninstall.sh --remove-dir # 同时删除安装目录
```

## 仓库维护者

推送代码到 `master` 后，CI 会自动运行 **Sync Binaries**，同步 kubectl、docker-compose、mc 到 `bin` 分支并更新 manifest。也可在 Actions 中手动触发。

发布版本：

```bash
git tag v1.0.0
git push origin v1.0.0
```

## 许可证

私有项目，仅供个人/团队内部使用。
