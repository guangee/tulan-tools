# Rancher 单机部署材料说明

本目录用于在单机环境通过 Docker 部署 Rancher（内置 k3s），并使用自签证书访问管理端。

## 通过 tulan-tools 使用（推荐）

```bash
brew k8s ca          # 交互生成证书（自动检测局域网 IP，询问域名）
brew k8s ca -d rancher.local.example.com   # 指定域名
brew k8s install     # 交互选择证书与端口并安装（写入 rancher.env）
brew k8s install -d rancher.local.example.com
brew k8s install --https-port 9443   # 指定 HTTPS 端口（默认 8443）
brew k8s upgrade     # 交互选择升级版本（版本列表随 brew update 同步）
brew k8s upgrade -V v2.13.3
brew k8s ports       # 修改已部署实例的端口（重建容器，数据不变）
brew k8s ports --https-port 9443 -y
brew k8s ca-clean    # 清理自签证书
brew k8s password    # 获取初始密码
brew k8s status
brew help k8s        # 完整子命令列表
```

也可直接执行本目录脚本（需 root）：`sudo bash scripts/k8s/install.sh`

## 目录文件说明

- `ca.sh`：生成 CA 与站点证书，自动写入 `site.env`（域名与 IP），并将 CA 安装到系统信任链。
- `ca-clean.sh`：清理自签 CA 与站点证书（不删除 Rancher 容器与数据）。
- `install.sh`：启动 Rancher 容器（默认 `rancher/rancher:v2.8.5`），挂载证书与镜像源配置。
- `ports.sh`：修改已部署 Rancher 的 HTTP/HTTPS 端口（重建容器，保留数据与证书）。
- `get-init-password.sh`：从 Rancher 容器日志提取首次登录密码（Bootstrap Password）。
- `clean.sh`：清理 Rancher/k3s/rke2 相关进程、容器、网络与数据目录（高风险操作）。
- `registries.yaml`：k3s 容器运行时镜像仓库配置（会被 `install.sh` 覆盖）。
- `site.env`：由 `ca.sh` 生成，记录最近一次生成的证书域名与 IP。
- `rancher.env`：由 `install.sh` 写入、`upgrade.sh` / `ports.sh` 更新，记录当前 Rancher 部署使用的证书、端口映射与镜像等信息。
- `config/k8s.rancher.versions.json`：bin 分支上的 Rancher 版本索引（CI 生成，`brew update` 拉取）。
- `sync-rancher-versions.py`：CI/开发用，从 Docker Hub 同步 `vX.Y.Z`（同一 vX.Y 最多 3 个 patch）。

## 前置条件

- Linux 主机，已安装 Docker 与 systemd。
- 具备 root 权限（或可使用 `sudo`）。
- 本机可访问 Rancher 镜像与后续业务集群所需镜像仓库。
- DNS 或 hosts 已将证书域名（`brew k8s ca` 时输入）指向服务器地址；证书 SAN 会自动包含检测到的局域网 IP。

## 快速开始

1. 生成证书（首次部署，会询问域名并自动检测局域网 IP）：

```bash
brew k8s ca
```

2. 安装并启动 Rancher（多套证书时会提示选择；安装前可配置 HTTP/HTTPS 端口，并写入 `rancher.env`）：

```bash
brew k8s install
# HTTPS 宿主机端口 [8443]: 9443
# HTTP 宿主机端口 [8080]:
```

非交互指定端口：

```bash
brew k8s install --https-port 9443
```

3. 获取初始密码：

```bash
brew k8s password
```

4. 浏览器访问：

- `https://<你的域名>:<HTTPS端口>`（默认 HTTPS 8443，实际端口见 `/etc/certs/rancher.env` 中的 `HTTPS_PORT_MAP`）
- 如使用了默认 hosts/DNS 且做了反向代理，也可按实际入口访问

## install.sh 可选参数

可通过环境变量覆盖默认行为，例如：

```bash
sudo CERT_OUT=/etc/certs \
  RANCHER_IMAGE=rancher/rancher:v2.8.5 \
  REGISTRY_MIRROR=https://hub.local.tulan.wang \
  RANCHER_DATA=/opt/rancher-data \
  HTTP_PORT_MAP=8080:80 \
  HTTPS_PORT_MAP=8443:443 \
  bash /etc/certs/install.sh
```

关键变量说明：

- `CERT_OUT`：证书目录，默认 `/etc/certs`。
- `RANCHER_IMAGE`：Rancher 镜像版本。
- `REGISTRY_MIRROR`：写入 `registries.yaml` 的 `docker.io` 镜像源。
- `RANCHER_DATA`：Rancher 持久化数据目录。
- `HTTP_PORT_MAP` / `HTTPS_PORT_MAP`：容器端口映射。

## 常用运维命令

查看容器状态：

```bash
docker ps --filter name=rancher
```

查看 Rancher 日志：

```bash
docker logs -f rancher
```

进入容器执行 kubectl：

```bash
docker exec -it rancher sh
kubectl get pods -A
```

重启 Rancher：

```bash
docker restart rancher
```

修改 HTTP/HTTPS 端口（保留数据与证书，会短暂中断）：

```bash
brew k8s ports
brew k8s ports --https-port 9443 -y
```

## 同步可升级版本

Rancher 可升级版本在 **CI 构建 bin 分支**时从 [Docker Hub](https://hub.docker.com/r/rancher/rancher/tags) 自动同步，写入 `k8s.rancher.versions.json`（仅 `vX.Y.Z`，同一 `vX.Y` 最多 3 个 patch）。

客户端执行 `brew update` 时会与二进制索引一并拉取到 `~/.tulan-tools/state/k8s.rancher.versions.json`，**无需手动 sync-versions**。

开发/CI 可手动运行：

```bash
python3 scripts/k8s/sync-rancher-versions.py --format json --max-per-minor 3 -o k8s.rancher.versions.json
brew k8s sync-versions   # 写入本地 state 缓存（开发调试用）
```

## 清理与重装

仅清理证书（保留 Rancher 容器与数据，会列出可清理的域名供选择）：

```bash
brew k8s ca-clean                              # 交互选择域名
brew k8s ca-clean -d rancher.local.example.com # 指定域名
brew k8s ca-clean -a                           # 清理全部
```

完整清理 Rancher/K8s 相关组件与数据（请谨慎）：

```bash
brew k8s clean
```

建议完整清理后重启系统，再重新执行 `brew k8s ca` + `brew k8s install`。

## 常见问题

- 证书域名不匹配：确保访问地址与 `site.env` 中的 `K8S_SITE_DOMAIN` 一致。
- 镜像拉取失败：检查 `registries.yaml` 与网络连通性，必要时切回官方仓库。
- 无法获取初始密码：可执行 `docker exec -it rancher reset-password` 重置管理员密码。

## 安全建议

- `ca.key` 与站点私钥应妥善保管，不要上传到公共仓库。
- 生产环境建议使用受信任 CA 证书与独立高可用 Kubernetes 集群。
