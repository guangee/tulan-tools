#!/usr/bin/env bash
# zsh / Oh My Zsh 插件配置

set -euo pipefail

TULAN_ZSH_AUTOSUGGESTIONS_REPO="${TULAN_ZSH_AUTOSUGGESTIONS_REPO:-https://git.tulan.wang/github/zsh-autosuggestions.git}"
TULAN_ZSH_AUTOSUGGESTIONS_PLUGIN="${TULAN_ZSH_AUTOSUGGESTIONS_PLUGIN:-zsh-autosuggestions}"

tulan_zsh_rc_path() {
  echo "${ZDOTDIR:-${HOME}}/.zshrc"
}

tulan_zsh_read_rc_var() {
  local name="$1" default="${2:-}" rc line value
  rc="$(tulan_zsh_rc_path)"
  if [[ -f "$rc" ]]; then
    line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${name}=" "$rc" 2>/dev/null | head -1 || true)"
    if [[ -n "$line" ]]; then
      value="$(sed -E "s/^[[:space:]]*(export[[:space:]]+)?${name}=//" <<< "$line" | tr -d "\"'" | sed "s#^\$HOME#${HOME}#")"
      echo "$value"
      return 0
    fi
  fi
  echo "$default"
}

tulan_zsh_omz_dir() {
  local zsh_dir
  zsh_dir="$(tulan_zsh_read_rc_var ZSH "")"
  if [[ -z "$zsh_dir" ]]; then
    zsh_dir="${ZSH:-${HOME}/.oh-my-zsh}"
  fi
  echo "$zsh_dir"
}

tulan_zsh_custom_dir() {
  local custom
  custom="$(tulan_zsh_read_rc_var ZSH_CUSTOM "")"
  if [[ -z "$custom" ]]; then
    custom="${ZSH_CUSTOM:-$(tulan_zsh_omz_dir)/custom}"
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
  grep -qE '(oh-my-zsh|oh-my-zsh\.sh)' "$(tulan_zsh_rc_path)" 2>/dev/null \
    || [[ -f "$(tulan_zsh_omz_dir)/oh-my-zsh.sh" ]]
}

tulan_zsh_python_plugins() {
  python3 - "$@" <<'PY'
import re
import sys
from pathlib import Path

cmd = sys.argv[1]
rc_path = Path(sys.argv[2])
plugin = sys.argv[3] if len(sys.argv) > 3 else "zsh-autosuggestions"
text = rc_path.read_text() if rc_path.exists() else ""


def split_plugins(inner: str) -> list[str]:
    items = []
    for line in inner.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        code = stripped.split("#", 1)[0].strip()
        if not code:
            continue
        items.extend(re.split(r"\s+", code))
    if not items and inner.strip() and not inner.strip().startswith("#"):
        items = [x for x in re.split(r"\s+", inner.strip()) if x and not x.startswith("#")]
    return items


def find_plugins_block(content: str):
    for match in re.finditer(r"(?m)^(?P<prefix>[ \t]*(?:export[ \t]+)?)plugins=\(", content):
        start = match.end() - 1
        depth = 0
        i = start
        while i < len(content):
            ch = content[i]
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    inner = content[start + 1 : i]
                    prefix = match.group("prefix")
                    return match.start(), i + 1, inner, prefix
            i += 1
    return None


def list_plugins(content: str) -> list[str]:
    block = find_plugins_block(content)
    if not block:
        return []
    return split_plugins(block[2])


def render_plugins(prefix: str, inner: str, items: list[str]) -> str:
    export_kw = "export " if "export" in prefix else ""
    if "\n" in inner or re.search(r"(?m)^\s*\S", inner):
        body = "\n".join(f"  {x}" for x in items) + "\n"
        return f"{export_kw}plugins=(\n{body})"
    return f"{export_kw}plugins=({' '.join(items)})"


def dedupe(items: list[str]) -> list[str]:
    seen = set()
    out = []
    for item in items:
        if item in seen:
            continue
        seen.add(item)
        out.append(item)
    return out


if cmd == "enabled":
    sys.exit(0 if plugin in list_plugins(text) else 1)

if cmd == "add":
    block = find_plugins_block(text)
    if block:
        start, end, inner, prefix = block
        items = split_plugins(inner)
        if plugin in items:
            print("skip")
            sys.exit(0)
        items.append(plugin)
        new_block = render_plugins(prefix, inner, items)
        text = text[:start] + new_block + text[end:]
        rc_path.write_text(text)
        print("added")
        sys.exit(0)

    anchor = re.search(r"(?m)^[ \t]*source[ \t]+\$ZSH/oh-my-zsh\.sh", text)
    block_text = f"plugins=({plugin})\n\n"
    if anchor:
        text = text[: anchor.start()] + block_text + text[anchor.start() :]
    else:
        marker = f"# tulan-tools: {plugin}"
        if marker in text:
            print("skip")
            sys.exit(0)
        text = text.rstrip() + f"\n\n{marker}\nplugins=({plugin})\n"
    rc_path.write_text(text)
    print("added")
    sys.exit(0)

if cmd == "dedupe":
    block = find_plugins_block(text)
    if not block:
        sys.exit(1)
    start, end, inner, prefix = block
    items = split_plugins(inner)
    new_items = dedupe(items)
    if new_items == items:
        sys.exit(1)
    new_block = render_plugins(prefix, inner, new_items)
    text = text[:start] + new_block + text[end:]
    rc_path.write_text(text)
    sys.exit(0)

sys.exit(2)
PY
}

tulan_zsh_plugin_enabled() {
  tulan_zsh_python_plugins enabled "$(tulan_zsh_rc_path)" "${TULAN_ZSH_AUTOSUGGESTIONS_PLUGIN}"
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

  result="$(tulan_zsh_python_plugins add "$rc" "$plugin")"

  case "$result" in
    skip)
      tulan_log "plugins 已包含 ${plugin}，跳过 ~/.zshrc 修改"
      ;;
    added)
      tulan_log "已在 ~/.zshrc 的 plugins 中加入 ${plugin}"
      ;;
    *)
      tulan_error "未能写入 ~/.zshrc plugins"
      return 1
      ;;
  esac

  if ! tulan_zsh_plugin_enabled; then
    tulan_error "写入后仍未在 plugins 中检测到 ${plugin}，请检查 ~/.zshrc 格式"
    return 1
  fi
}

tulan_zsh_dedupe_plugins() {
  tulan_zsh_python_plugins dedupe "$(tulan_zsh_rc_path)" "${TULAN_ZSH_AUTOSUGGESTIONS_PLUGIN}"
}

tulan_zsh_configure_autosuggestions() {
  if ! tulan_zsh_is_configured; then
    tulan_log "未检测到 Oh My Zsh / zsh 配置，跳过 zsh-autosuggestions 安装"
    tulan_log "  需要: zsh、~/.zshrc、~/.oh-my-zsh（或 ZSH 指向的目录）"
    return 0
  fi

  if tulan_zsh_plugin_enabled && tulan_zsh_autosuggestions_installed \
    && [[ "${TULAN_ZSH_REFRESH:-false}" != true ]]; then
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
  local rc omz custom plugin_dir plugins_list

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
  if tulan_zsh_plugin_enabled; then
    plugins_list="$(python3 - "$rc" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
for m in re.finditer(r"(?m)^[ \t]*(?:export[ \t]+)?plugins=\(", text):
    start = m.end()-1
    depth = 0
    for i in range(start, len(text)):
        if text[i] == '(': depth += 1
        elif text[i] == ')':
            depth -= 1
            if depth == 0:
                inner = text[start+1:i]
                items = []
                for line in inner.splitlines():
                    s = line.strip()
                    if not s or s.startswith('#'): continue
                    items.extend(s.split('#',1)[0].split())
                print(', '.join(items))
                break
    break
PY
)"
    echo "    plugins:  已启用 (${plugins_list})"
  else
    echo "    plugins:  未启用"
  fi
  echo "    仓库:     ${TULAN_ZSH_AUTOSUGGESTIONS_REPO}"
}
