#!/usr/bin/env bash
# tulan-tools 自定义别名和函数
# 在此文件中添加你的个人配置

alias help='brew help'

# 东八区 date 显示（brew time 写入 time.env 后生效）
if [[ -n "${TULAN_TOOLS_HOME:-}" && -f "${TULAN_TOOLS_HOME}/state/time.env" ]]; then
  # shellcheck source=/dev/null
  source "${TULAN_TOOLS_HOME}/state/time.env"
fi

# 示例别名
# alias ll='ls -alh'
# alias gs='git status'
