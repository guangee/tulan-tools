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

| 命令 | 作用 |
|------|------|
| `tulan-update` | 拉取仓库最新代码 |
| `tulan-download-binaries` | 下载 kubectl、docker-compose、mc |
| `tulan-list-pkgs` | 查看可安装的软件包 |
| `tulan-install-pkg <包名>` | 安装软件包 |
| `tulan-uninstall-pkg <包名>` | 卸载软件包 |

打开新终端时会自动检查更新（每天最多一次），也可随时手动执行 `tulan-update`。

## 下载常用工具

安装完成后，执行：

```bash
tulan-download-binaries
```

工具会安装到 `~/.tulan-tools/bin`，可直接使用 `kubectl`、`docker-compose`、`mc`。

默认通过 [gh.coding-space.cn](https://gh.coding-space.cn/) 代理加速 GitHub 下载，代理失败时自动回退直连。如需禁用代理：

```bash
tulan-download-binaries --no-proxy
```

若在其他机器上仅通过安装脚本部署、没有完整仓库，可指定 manifest 地址（同样走代理加速）：

```bash
TULAN_MANIFEST_URL=https://raw.githubusercontent.com/guangee/tulan-tools/master/config/binaries.manifest.json \
  tulan-download-binaries
```

## 管理私有软件包

**新增一个包：**

```bash
cp -r packages/_template packages/my-tool
# 编辑 packages/my-tool/manifest.json
# 将可执行文件放到 packages/my-tool/bin/
```

**安装与卸载：**

```bash
tulan-install-pkg my-tool
tulan-uninstall-pkg my-tool
```

**查看状态：**

```bash
tulan-list-pkgs              # 全部可用包
tulan-list-pkgs --installed  # 已安装的包
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

推送代码到 GitHub 后，建议在 Actions 中手动运行一次 **Sync Binaries**，同步 kubectl、docker-compose、mc 到 `bin` 分支，供用户下载。

发布版本：

```bash
git tag v1.0.0
git push origin v1.0.0
```

## 许可证

私有项目，仅供个人/团队内部使用。
