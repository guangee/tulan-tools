# Rancher 单机部署材料说明

本目录用于在单机环境通过 Docker 部署 Rancher（内置 k3s），并使用自签证书访问管理端。

## 通过 tulan-tools 使用（推荐）

```bash
brew k8s ca          # 生成证书
brew k8s install     # 安装 Rancher
brew k8s password    # 获取初始密码
brew k8s status
brew help k8s        # 完整子命令列表
```

也可直接执行本目录脚本（需 root）：`sudo bash k8s-init/install.sh`

## 目录文件说明

- `ca.sh`：生成 CA 与站点证书（`k8s.local.tulan.wang`），并将 CA 安装到系统信任链。
- `install.sh`：启动 Rancher 容器（默认 `rancher/rancher:v2.8.5`），挂载证书与镜像源配置。
- `get-init-password.sh`：从 Rancher 容器日志提取首次登录密码（Bootstrap Password）。
- `clean.sh`：清理 Rancher/k3s/rke2 相关进程、容器、网络与数据目录（高风险操作）。
- `registries.yaml`：k3s 容器运行时镜像仓库配置（会被 `install.sh` 覆盖）。
- `ca.crt` / `ca.key`：自签 CA 证书与私钥。
- `k8s.local.tulan.wang.crt` / `.key`：Rancher HTTPS 站点证书与私钥。

## 前置条件

- Linux 主机，已安装 Docker 与 systemd。
- 具备 root 权限（或可使用 `sudo`）。
- 本机可访问 Rancher 镜像与后续业务集群所需镜像仓库。
- DNS 或 hosts 已将 `k8s.local.tulan.wang` 指向服务器地址（证书中默认为 `192.168.20.250`）。

## 快速开始

1. 生成证书（首次部署）：

```bash
sudo bash /etc/certs/ca.sh
```

2. 安装并启动 Rancher：

```bash
sudo bash /etc/certs/install.sh
```

3. 获取初始密码：

```bash
sudo bash /etc/certs/get-init-password.sh
```

4. 浏览器访问：

- `https://k8s.local.tulan.wang:8443`（默认端口映射）
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

## 清理与重装

执行以下命令会清理 Rancher/K8s 相关组件与数据，请谨慎：

```bash
sudo bash /etc/certs/clean.sh
```

建议清理后重启系统，再重新执行 `ca.sh` + `install.sh`。

## 常见问题

- 证书域名不匹配：确保访问地址与证书 CN/SAN 一致（默认 `k8s.local.tulan.wang`）。
- 镜像拉取失败：检查 `registries.yaml` 与网络连通性，必要时切回官方仓库。
- 无法获取初始密码：可执行 `docker exec -it rancher reset-password` 重置管理员密码。

## 安全建议

- `ca.key` 与站点私钥应妥善保管，不要上传到公共仓库。
- 生产环境建议使用受信任 CA 证书与独立高可用 Kubernetes 集群。
