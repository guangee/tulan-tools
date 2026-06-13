#!/usr/bin/env bash
# 系统中文字体安装与 fontconfig 配置

set -euo pipefail

TULAN_FONTS_TEMPLATE="${TULAN_FONTS_TEMPLATE:-$(tulan_get_home)/config/fonts.cn.conf}"
TULAN_FONTS_CONF_NAME="99-tulan-tools-cjk.conf"
TULAN_FONTS_TEST_CHARS="${TULAN_FONTS_TEST_CHARS:-中文测试：简体繁體常用汉字显示}"

tulan_fonts_require_linux() {
  if [[ "$(uname -s | tr '[:upper:]' '[:lower:]')" != "linux" ]]; then
    tulan_error "中文字体配置目前仅支持 Linux"
    return 1
  fi
}

# 输出当前平台应安装的字形包（空格分隔）
tulan_fonts_pkg_list() {
  local minimal="${1:-false}"
  local pkg_manager
  pkg_manager="$(tulan_detect_pkg_manager)"

  case "$pkg_manager" in
    apt)
      if [[ "$minimal" == true ]]; then
        echo "fonts-noto-cjk fontconfig"
      else
        echo "fonts-noto-cjk fonts-noto-cjk-extra fonts-wqy-zenhei fonts-wqy-microhei fontconfig locales"
      fi
      ;;
    dnf)
      if [[ "$minimal" == true ]]; then
        echo "google-noto-sans-cjk-sc-fonts fontconfig glibc-langpack-zh"
      else
        echo "google-noto-sans-cjk-sc-fonts google-noto-serif-cjk-sc-fonts google-noto-sans-mono-cjk-sc-fonts wqy-zenhei-fonts wqy-microhei-fonts fontconfig glibc-langpack-zh"
      fi
      ;;
    yum)
      if [[ "$minimal" == true ]]; then
        echo "google-noto-sans-cjk-sc-fonts fontconfig glibc-langpack-zh"
      else
        echo "google-noto-sans-cjk-sc-fonts google-noto-serif-cjk-sc-fonts google-noto-sans-mono-cjk-sc-fonts wqy-zenhei-fonts wqy-microhei-fonts fontconfig glibc-langpack-zh"
      fi
      ;;
    *)
      tulan_error "无法识别包管理器，请手动安装 Noto CJK 与文泉驿字体"
      return 1
      ;;
  esac
}

tulan_fonts_install_packages() {
  local minimal="${1:-false}"
  local pkg_manager pkgs=()
  local pkg

  tulan_require_privilege || return 1
  read -r -a pkgs <<< "$(tulan_fonts_pkg_list "$minimal")"
  pkg_manager="$(tulan_detect_pkg_manager)"

  tulan_log "安装中文字体包（${#pkgs[@]} 个）..."
  case "$pkg_manager" in
    apt)
      tulan_as_root apt-get update -qq
      tulan_as_root apt-get install -y "${pkgs[@]}"
      ;;
    dnf)
      tulan_as_root dnf install -y "${pkgs[@]}"
      ;;
    yum)
      tulan_as_root yum install -y "${pkgs[@]}"
      ;;
    *)
      return 1
      ;;
  esac
}

tulan_fonts_configure_locale() {
  local pkg_manager
  pkg_manager="$(tulan_detect_pkg_manager)"

  tulan_log "配置中文 locale（zh_CN.UTF-8）..."
  case "$pkg_manager" in
    apt)
      if ! locale -a 2>/dev/null | grep -qi 'zh_CN\.utf-8'; then
        if grep -q '^#.*zh_CN.UTF-8' /etc/locale.gen 2>/dev/null; then
          tulan_as_root sed -i 's/^# \(zh_CN.UTF-8 UTF-8\)/\1/' /etc/locale.gen
        elif ! grep -q '^zh_CN.UTF-8 UTF-8' /etc/locale.gen 2>/dev/null; then
          echo "zh_CN.UTF-8 UTF-8" | tulan_as_root tee -a /etc/locale.gen >/dev/null
        fi
        tulan_as_root locale-gen zh_CN.UTF-8 2>/dev/null || tulan_as_root locale-gen
      fi
      ;;
    dnf|yum)
      tulan_as_root dnf install -y glibc-langpack-zh 2>/dev/null || tulan_as_root yum install -y glibc-langpack-zh 2>/dev/null || true
      ;;
  esac
}

tulan_fonts_conf_target() {
  local user_mode="${1:-false}"
  if [[ "$user_mode" == true ]]; then
    echo "${HOME}/.config/fontconfig/conf.d/${TULAN_FONTS_CONF_NAME}"
  else
    echo "/etc/fonts/conf.d/${TULAN_FONTS_CONF_NAME}"
  fi
}

tulan_fonts_write_fontconfig() {
  local user_mode="${1:-false}"
  local target

  if [[ ! -f "$TULAN_FONTS_TEMPLATE" ]]; then
    tulan_error "缺少字体配置模板: ${TULAN_FONTS_TEMPLATE}"
    return 1
  fi

  target="$(tulan_fonts_conf_target "$user_mode")"
  if [[ "$user_mode" == true ]]; then
    mkdir -p "$(dirname "$target")"
    cp "$TULAN_FONTS_TEMPLATE" "$target"
    tulan_log "已写入用户 fontconfig: ${target}"
  else
    tulan_require_privilege || return 1
    tulan_as_root mkdir -p "$(dirname "$target")"
    tulan_as_root cp "$TULAN_FONTS_TEMPLATE" "$target"
    tulan_log "已写入系统 fontconfig: ${target}"
  fi
}

tulan_fonts_refresh_cache() {
  if ! command -v fc-cache &>/dev/null; then
    tulan_log "未找到 fc-cache，跳过字体缓存刷新"
    return 0
  fi

  tulan_log "刷新字体缓存..."
  fc-cache -f >/dev/null 2>&1 || true
  if tulan_can_privilege; then
    tulan_as_root fc-cache -f >/dev/null 2>&1 || true
  fi
}

tulan_fonts_list_zh() {
  if ! command -v fc-list &>/dev/null; then
    tulan_error "未安装 fontconfig（fc-list 不可用）"
    return 1
  fi

  fc-list :lang=zh family 2>/dev/null | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sort -u
}

tulan_fonts_show_status() {
  echo "中文字体状态"
  echo "────────────────────────────────────"

  echo "Locale:"
  if command -v locale &>/dev/null; then
    locale 2>/dev/null | sed 's/^/  /' || echo "  (不可用)"
  else
    echo "  (locale 命令不可用)"
  fi

  echo ""
  echo "中文 locale 是否可用:"
  if locale -a 2>/dev/null | grep -qi 'zh_CN\.utf-8'; then
    echo "  zh_CN.UTF-8: 是"
  else
    echo "  zh_CN.UTF-8: 否（运行 brew fonts 可生成）"
  fi

  echo ""
  echo "fontconfig 配置:"
  local conf
  for conf in "/etc/fonts/conf.d/${TULAN_FONTS_CONF_NAME}" "${HOME}/.config/fontconfig/conf.d/${TULAN_FONTS_CONF_NAME}"; do
    if [[ -f "$conf" ]]; then
      echo "  ${conf}"
    fi
  done

  echo ""
  echo "已安装的中文字体（:lang=zh）:"
  if command -v fc-list &>/dev/null; then
    local count=0 line
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      count=$((count + 1))
      echo "  - ${line}"
    done < <(tulan_fonts_list_zh 2>/dev/null || true)
    if [[ "$count" -eq 0 ]]; then
      echo "  (无，请运行 brew fonts 安装)"
    fi
  else
    echo "  (fc-list 不可用)"
  fi

  echo ""
  echo "字体匹配（:lang=zh）:"
  if command -v fc-match &>/dev/null; then
    echo "  sans-serif: $(fc-match 'sans-serif:lang=zh' 2>/dev/null || echo 不可用)"
    echo "  serif:      $(fc-match 'serif:lang=zh' 2>/dev/null || echo 不可用)"
    echo "  monospace:  $(fc-match 'monospace:lang=zh' 2>/dev/null || echo 不可用)"
  else
    echo "  (fc-match 不可用)"
  fi
}

tulan_fonts_test_render() {
  echo "字体渲染测试"
  echo "────────────────────────────────────"
  echo "  文本: ${TULAN_FONTS_TEST_CHARS}"
  echo ""

  if command -v fc-match &>/dev/null; then
    echo "  sans-serif -> $(fc-match 'sans-serif:lang=zh')"
    echo "  monospace  -> $(fc-match 'monospace:lang=zh')"
  fi

  if command -v python3 &>/dev/null; then
    python3 - "$TULAN_FONTS_TEST_CHARS" <<'PY'
import sys

text = sys.argv[1]
try:
    text.encode("utf-8")
    print(f"  UTF-8 编码: OK（{len(text)} 字符）")
except UnicodeEncodeError as exc:
    print(f"  UTF-8 编码: 失败 ({exc})")
PY
  fi
}

tulan_fonts_setup() {
  local install_pkgs="${1:-true}"
  local configure_locale="${2:-true}"
  local minimal="${3:-false}"
  local user_mode="${4:-false}"

  tulan_fonts_require_linux || return 1

  if [[ "$install_pkgs" == true ]]; then
    tulan_fonts_install_packages "$minimal"
  fi

  if [[ "$configure_locale" == true && "$user_mode" != true ]]; then
    tulan_fonts_configure_locale
  fi

  tulan_fonts_write_fontconfig "$user_mode"
  tulan_fonts_refresh_cache

  echo ""
  tulan_fonts_show_status
}
