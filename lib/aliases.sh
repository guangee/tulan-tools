#!/usr/bin/env bash
# tulan-tools 自定义别名和函数

# Docker 工具容器快捷命令（镜像需已通过 docker-compose 启动）
if command -v tulan-exec &>/dev/null; then
  alias kubectl='tulan-kubectl'
  alias mc='tulan-mc'
  alias docker-compose='tulan-compose'
fi
