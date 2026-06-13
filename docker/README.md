# Docker 测试镜像

用于在多种 Linux 发行版容器中验证 tulan-tools 安装，以及 `brew time`、`brew mirrors` 是否正常工作。

## 镜像列表

| 标签 | 基础镜像 |
|------|----------|
| ubuntu-22.04 | `ubuntu:22.04` |
| ubuntu-24.04 | `ubuntu:24.04` |
| ubuntu-26.04 | `ubuntu:26.04` |
| debian-12 | `debian:12` |
| centos-7.8 | `centos:7.8.2003` |
| centos-7.9 | `centos:7.9.2009` |

## 用法

```bash
# 测试全部镜像（需 Docker）
./docker/test.sh

# 仅测试单个镜像
./docker/test.sh ubuntu-22.04
./docker/test.sh debian-12
```

构建时会将当前仓库复制到容器内 `/src/tulan-tools`，执行 `docker/common/bootstrap.sh`：

1. 安装 git、python3、chrony、go、npm 等依赖
2. `./install.sh --local` 安装 tulan-tools
3. `brew mirrors` 配置 pip / npm / Go 国内镜像
4. `brew time probe` + `brew time` 配置东八区与 NTP

## 手动构建

```bash
docker build -f docker/ubuntu/22.04/Dockerfile -t tulan-tools:ubuntu-22.04 .
docker run --rm --cap-add SYS_TIME tulan-tools:ubuntu-22.04
```

`--cap-add SYS_TIME` 允许容器内调整系统时钟（NTP 同步测试需要）。
