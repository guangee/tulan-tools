#!/usr/bin/env bash
# brew time 注入 shell 时使用：统一东八区显示，避免 PM/CST 歧义

# 清除可能冲突的 alias / 缓存，确保函数生效
unalias date 2>/dev/null || true
hash -r 2>/dev/null || true
rehash 2>/dev/null || true

# 无参数时默认 24 小时 +0800；有参数时仍走 Asia/Shanghai
# shellcheck disable=SC2329  # 故意覆盖 date 命令
date() {
  if [[ $# -eq 0 ]]; then
    command date "+%Y-%m-%d %H:%M:%S %z (Asia/Shanghai)"
  else
    command date "$@"
  fi
}

# 显式查看东八区时间（与 brew time now 一致）
cnnow() {
  command date "+%Y-%m-%d %H:%M:%S %z (Asia/Shanghai)"
}
