#!/usr/bin/env bash
# example-tool 安装脚本
# 环境变量: TULAN_PKG_NAME, TULAN_PKG_VERSION, TULAN_PKG_DIR

set -euo pipefail

echo "[example-tool] 安装 v${TULAN_PKG_VERSION}..."

# 在此添加自定义安装逻辑，例如:
# - 下载二进制文件
# - 编译源码
# - 配置服务

echo "[example-tool] 安装完成"
