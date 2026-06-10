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
| `brew uninstall <名称>` | 卸载 |
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

## 环境安装

```bash
brew docker    # Docker + 镜像加速
brew conda     # Miniconda + 阿里云源
brew vim       # vimrc + 默认编辑器
```

## 管理私有软件包

```bash
cp -r packages/_template packages/my-tool
brew list --pkgs
brew versions my-tool
brew install my-tool
brew uninstall my-tool
```

## 自定义别名

编辑 `~/.tulan-tools/lib/aliases.sh`。

## 卸载 tulan-tools

```bash
cd ~/.tulan-tools
./uninstall.sh --remove-dir
```
