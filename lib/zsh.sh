#!/usr/bin/env bash
# zsh / Oh My Zsh 插件配置

set -euo pipefail

TULAN_ZSH_AUTOSUGGESTIONS_REPO="${TULAN_ZSH_AUTOSUGGESTIONS_REPO:-https://git.tulan.wang/github/zsh-autosuggestions.git}"
TULAN_ZSH_AUTOSUGGESTIONS_PLUGIN="${TULAN_ZSH_AUTOSUGGESTIONS_PLUGIN:-zsh-autosuggestions}"

tulan_zsh_rc_path() {
  echo "${ZDOTDIR:-${HOME}}/.zshrc"
}

tulan_zsh_omz_dir() {
  local zsh_dir="${ZSH:-}"
  if [[ -z "$zsh_dir" && -f "$(tulan_zsh_rc_path)" ]]; then
    zsh_dir="$(grep -E '^[[:space:]]*(export[[:space:]]+)?ZSH=' "$(tulan_zsh_rc_path)" 2>/dev/null | head -1 \
      | sed -E 's/^[[:space:]]*(export[[:space:]]+)?ZSH=//' \
      | tr -d "\"'" \
      | sed "s#^\$HOME#${HOME}#")"
  fi
  if [[ -z "$zsh_dir" ]]; then
    zsh_dir="${HOME}/.oh-my-zsh"
  fi
  echo "$zsh_dir"
}

tulan_zsh_custom_dir() {
  local custom="${ZSH_CUSTOM:-}"
  if [[ -z "$custom" && -f "$(tulan_zsh_rc_path)" ]]; then
    custom="$(grep -E '^[[:space:]]*(export[[:space:]]+)?ZSH_CUSTOM=' "$(tulan_zsh_rc_path)" 2>/dev/null | head -1 \
      | sed -E 's/^[[:space:]]*(export[[:space:]]+)?ZSH_CUSTOM=//' \
      | tr -d "\"'" \
      | sed "s#^\$HOME#${HOME}#")"
  fi
  if [[ -z "$custom" ]]; then
    custom="$(tulan_zsh_omz_dir)/custom"
  fi
  echo "$custom"
}

tulan_zsh_autosuggestions_dir() {
  echo "$(tulan_zsh_custom_dir)/plugins/${TULAN_ZSH_AUTOSUGGESTIONS_PLUGIN}"
}

tulan_zsh_is_configured() {
  command -v zsh &>/dev/null || return 1
  [[ -f "$(tulan_zsh_rc_path)" ]] || return 1
  [[ -d "$(tulan_zsh_omz_dir)" ]] || return 1
  grep -q 'oh-my-zsh' "$(tulan_zsh_rc_path)" 2>/dev/null \
    || [[ -f "$(tulan_zsh_omz_dir)/oh-my-zsh.sh" ]]
}

tulan_zsh_plugin_enabled() {
  grep -qE '(^|[[:space:]])'"${TULAN_ZSH_AUTOSUGGESTIONS_PLUGIN}"'([[:space:]]|$|\))' "$(tulan_zsh_rc_path)" 2>/dev/null
}

tulan_zsh_clone_autosuggestions() {
  local dest repo
  dest="$(tulan_zsh_autosuggestions_dir)"
  repo="${TULAN_ZSH_AUTOSUGGESTIONS_REPO}"
  mkdir -p "$(dirname "$dest")"

  if [[ -d "${dest}/.git" ]]; then
    tulan_log "更新插件: ${dest}"
    git -C "$dest" pull --ff-only 2>/dev/null || git -C "$dest" fetch --all --prune
    return 0
  fi

  if [[ -e "$dest" ]]; then
    tulan_error "目标路径已存在且非 git 仓库: ${dest}"
    return 1
  fi

  tulan_log "克隆 ${TULAN_ZSH_AUTOSUGGESTIONS_PLUGIN} -> ${dest}"
  git clone "$repo" "$dest"
}

tulan_zsh_enable_autosuggestions_plugin() {
  local rc plugin
  rc="$(tulan_zsh_rc_path)"
  plugin="${TULAN_ZSH_AUTOSUGGESTIONS_PLUGIN}"

  if tulan_zsh_plugin_enabled; then
    tulan_log "plugins 已包含 ${plugin}，跳过 ~/.zshrc 修改"
    return 0
  fi

  python3 - "$rc" "$plugin" <<'PY'
import re
import sys
from pathlib import Path

rc_path = Path(sys.argv[1])
plugin = sys.argv[2]
text = rc_path.read_text()
if re.search(rf'(^|\s){re.escape(plugin)}(\s|$|\))', text):
    sys.exit(0)

match = re.search(r'plugins=\(\s*(.*?)\s*\)', text, re.S)
if match:
    inner = match.group(1).strip()
    if inner:
        if inner.endswith('\n'):
            addition = f"  {plugin}\n"
            new_inner = inner + addition
        else:
            new_inner = inner + f" {plugin}"
    else:
        new_inner = plugin
    new_block = f"plugins=({new_inner})"
    text = text[: match.start()] + new_block + text[match.end() :]
else:
    anchor = re.search(r'^\s*source\s+\$ZSH/oh-my-zsh\.sh', text, re.M)
    block = f"plugins=({plugin})\n\n"
    if anchor:
        text = text[: anchor.start()] + block + text[anchor.start() :]
    else:
        text = text.rstrip() + f"\n\n# tulan-tools: {plugin}\nplugins=({plugin})\n"

rc_path.write_text(text)
print(f"已在 {rc_path} 的 plugins 中加入 {plugin}")
PY
  tulan_log "已更新 ${rc}"
}

tulan_zsh_configure_autosuggestions() {
  if ! tulan_zsh_is_configured; then
    tulan_log "未检测到 Oh My Zsh / zsh 配置，跳过 zsh-autosuggestions 安装"
    tulan_log "  需要: zsh、~/.zshrc、~/.oh-my-zsh（或 ZSH 指向的目录）"
    return 0
  fi

  command -v git &>/dev/null || {
    tulan_error "需要 git 才能克隆插件"
    return 1
  }

  tulan_zsh_clone_autosuggestions
  tulan_zsh_enable_autosuggestions_plugin
  tulan_log "完成。请执行: source ~/.zshrc  或重新打开终端"
}

tulan_zsh_show_status() {
  local rc omz custom plugin_dir

  rc="$(tulan_zsh_rc_path)"
  omz="$(tulan_zsh_omz_dir)"
  custom="$(tulan_zsh_custom_dir)"
  plugin_dir="$(tulan_zsh_autosuggestions_dir)"

  echo "zsh / Oh My Zsh 状态"
  echo "────────────────────────────────────"
  if command -v zsh &>/dev/null; then
    echo "  zsh:        $(command -v zsh) ($(zsh --version 2>/dev/null | head -1))"
  else
    echo "  zsh:        (未安装)"
  fi
  echo "  ~/.zshrc:   $([[ -f $rc ]] && echo "存在" || echo "不存在")"
  echo "  Oh My Zsh:  $([[ -d $omz ]] && echo "$omz" || echo "(未安装)")"
  echo "  ZSH_CUSTOM: ${custom}"
  echo ""
  echo "  zsh-autosuggestions:"
  echo "    插件目录: $([[ -d $plugin_dir ]] && echo "$plugin_dir" || echo "(未克隆)")"
  echo "    plugins:  $(tulan_zsh_plugin_enabled && echo "已启用" || echo "未启用")"
  echo "    仓库:     ${TULAN_ZSH_AUTOSUGGESTIONS_REPO}"
}
