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
  python3 - "$(tulan_zsh_rc_path)" "${TULAN_ZSH_AUTOSUGGESTIONS_PLUGIN}" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
plugin = sys.argv[2]
for match in re.finditer(r'plugins=\(\s*(.*?)\s*\)', text, re.S):
    items = re.split(r'\s+', match.group(1).strip())
    items = [x for x in items if x and not x.startswith('#')]
    if plugin in items:
        sys.exit(0)
sys.exit(1)
PY
}

tulan_zsh_autosuggestions_installed() {
  local dest
  dest="$(tulan_zsh_autosuggestions_dir)"
  [[ -d "${dest}/.git" || -f "${dest}/zsh-autosuggestions.zsh" ]]
}

tulan_zsh_autosuggestions_ready() {
  tulan_zsh_autosuggestions_installed && tulan_zsh_plugin_enabled
}

tulan_zsh_clone_autosuggestions() {
  local dest repo
  dest="$(tulan_zsh_autosuggestions_dir)"
  repo="${TULAN_ZSH_AUTOSUGGESTIONS_REPO}"
  mkdir -p "$(dirname "$dest")"

  if [[ -d "${dest}/.git" ]]; then
    if [[ "${TULAN_ZSH_REFRESH:-false}" == true ]]; then
      tulan_log "更新插件: ${dest}"
      git -C "$dest" pull --ff-only 2>/dev/null || git -C "$dest" fetch --all --prune
    else
      tulan_log "插件已存在: ${dest}（跳过克隆/更新，可用 --refresh 强制更新）"
    fi
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
  local rc plugin result
  rc="$(tulan_zsh_rc_path)"
  plugin="${TULAN_ZSH_AUTOSUGGESTIONS_PLUGIN}"

  if tulan_zsh_plugin_enabled; then
    tulan_log "plugins 已包含 ${plugin}，跳过 ~/.zshrc 修改"
    if tulan_zsh_dedupe_plugins; then
      tulan_log "已去除 ~/.zshrc plugins 中的重复项"
    fi
    return 0
  fi

  result="$(python3 - "$rc" "$plugin" <<'PY'
import re
import sys
from pathlib import Path

rc_path = Path(sys.argv[1])
plugin = sys.argv[2]
text = rc_path.read_text()

def plugins_blocks(content):
    return list(re.finditer(r'plugins=\(\s*(.*?)\s*\)', content, re.S))

def split_plugins(inner):
    items = []
    for line in inner.splitlines():
        line = line.split('#', 1)[0].strip()
        if not line:
            continue
        items.extend(re.split(r'\s+', line))
    return [x for x in items if x]

blocks = plugins_blocks(text)
for block in blocks:
    if plugin in split_plugins(block.group(1)):
        print("skip")
        sys.exit(0)

match = blocks[0] if blocks else None
if match:
    items = split_plugins(match.group(1))
    items.append(plugin)
    new_inner = ' '.join(items)
    if '\n' in match.group(1):
        new_inner = match.group(1).rstrip() + f"\n  {plugin}\n"
    new_block = f"plugins=({new_inner})"
    text = text[: match.start()] + new_block + text[match.end() :]
    rc_path.write_text(text)
    print("added")
    sys.exit(0)

anchor = re.search(r'^\s*source\s+\$ZSH/oh-my-zsh\.sh', text, re.M)
block = f"plugins=({plugin})\n\n"
if anchor:
    text = text[: anchor.start()] + block + text[anchor.start() :]
else:
    if re.search(rf'#\s*tulan-tools:\s*{re.escape(plugin)}', text):
        print("skip")
        sys.exit(0)
    text = text.rstrip() + f"\n\n# tulan-tools: {plugin}\nplugins=({plugin})\n"
rc_path.write_text(text)
print("added")
PY
)"

  case "$result" in
    skip)
      tulan_log "plugins 已包含 ${plugin}，跳过 ~/.zshrc 修改"
      ;;
    added)
      tulan_log "已在 ~/.zshrc 的 plugins 中加入 ${plugin}"
      ;;
  esac
}

tulan_zsh_dedupe_plugins() {
  python3 - "$(tulan_zsh_rc_path)" <<'PY'
import re
import sys
from pathlib import Path

rc_path = Path(sys.argv[1])
text = rc_path.read_text()
changed = False

def split_plugins(inner):
    items = []
    for line in inner.splitlines():
        line = line.split('#', 1)[0].strip()
        if not line:
            continue
        items.extend(re.split(r'\s+', line))
    return [x for x in items if x]

def dedupe(items):
    seen = set()
    out = []
    for item in items:
        if item in seen:
            continue
        seen.add(item)
        out.append(item)
    return out

def repl(match):
    global changed
    inner = match.group(1)
    items = split_plugins(inner)
    new_items = dedupe(items)
    if new_items == items:
        return match.group(0)
    changed = True
    if '\n' in inner:
        body = '\n'.join(f"  {x}" for x in new_items) + '\n'
        return f"plugins=({body})"
    return f"plugins=({' '.join(new_items)})"

text, n = re.subn(r'plugins=\(\s*(.*?)\s*\)', repl, text, count=0, flags=re.S)
if changed:
    rc_path.write_text(text)
    sys.exit(0)
sys.exit(1)
PY
}

tulan_zsh_configure_autosuggestions() {
  if ! tulan_zsh_is_configured; then
    tulan_log "未检测到 Oh My Zsh / zsh 配置，跳过 zsh-autosuggestions 安装"
    tulan_log "  需要: zsh、~/.zshrc、~/.oh-my-zsh（或 ZSH 指向的目录）"
    return 0
  fi

  if tulan_zsh_autosuggestions_ready && [[ "${TULAN_ZSH_REFRESH:-false}" != true ]]; then
    tulan_log "zsh-autosuggestions 已配置（插件目录 + ~/.zshrc plugins），跳过"
    tulan_zsh_dedupe_plugins >/dev/null 2>&1 || true
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
