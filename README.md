# tulan-tools

仓库地址：[github.com/guangee/tulan-tools](https://github.com/guangee/tulan-tools)

个人开发工具集，类似 oh-my-zsh + Homebrew。安装后自动配置 shell 环境，支持从 Git 仓库同步更新，并统一管理常用命令行工具和私有软件包。

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
curl -fsSL https://gh.coding-space.cn/https://raw.githubusercontent.com/guangee/tulan-tools/master/install.sh | bash
```

## 日常使用

| 命令 | 作用 |
|------|------|
| `tulan list` | 查看可安装的工具与软件包 |
| `tulan versions <名称>` | 查看版本（索引/上游/已装） |
| `tulan install <名称>` | 安装指定项（默认最新版） |
| `tulan use <工具> <版本>` | 切换二进制激活版本 |
| `tulan uninstall <名称>` | 卸载 |
| `tulan update` | 更新 tulan-tools |

**不会默认安装全部软件**。请先 `tulan list`，再按需 `tulan install`。

```bash
tulan list
tulan versions kubectl
tulan install kubectl          # 安装 bin 索引最新版
tulan install kubectl mc       # 安装多个
tulan install my-tool          # 安装私有包
```

## 二进制工具（Cellar 多版本）

```bash
tulan install kubectl --version v1.32.0 --source upstream
tulan use kubectl v1.32.0
tulan list --installed
```

- 实体：`~/.tulan-tools/cellar/<工具>/<版本>/`
- 命令：`~/.tulan-tools/bin/`（符号链接）
- 索引刷新：`tulan install --refresh-manifest`（安装二进制时）

## 环境安装

```bash
tulan docker    # Docker + 镜像加速
tulan conda     # Miniconda + 阿里云源
tulan vim       # vimrc + 默认编辑器
```

## 管理私有软件包

```bash
cp -r packages/_template packages/my-tool
tulan list --pkgs
tulan versions my-tool
tulan install my-tool
tulan uninstall my-tool
```

## 自定义别名

编辑 `~/.tulan-tools/lib/aliases.sh`。

## 卸载 tulan-tools

```bash
cd ~/.tulan-tools
./uninstall.sh --remove-dir
```
