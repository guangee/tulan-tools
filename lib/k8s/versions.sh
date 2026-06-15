#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail

# Rancher 版本与升级
tulan_k8s_versions_cache_path() {
  echo "$(tulan_get_home)/state/k8s.rancher.versions.json"
}

tulan_k8s_versions_file() {
  local cache fallback
  cache="$(tulan_k8s_versions_cache_path)"
  if [[ -f "$cache" ]]; then
    echo "$cache"
    return 0
  fi
  fallback="${TULAN_K8S_VERSIONS_FILE:-$(tulan_get_home)/config/k8s.rancher.versions}"
  if [[ -f "$fallback" ]]; then
    echo "$fallback"
    return 0
  fi
  json_fallback="$(tulan_get_home)/config/k8s.rancher.versions.json"
  if [[ -f "$json_fallback" ]]; then
    echo "$json_fallback"
    return 0
  fi
  echo "$cache"
}

tulan_k8s_read_versions_from_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    return 1
  fi
  if [[ "$f" == *.json ]]; then
    tulan_python k8s read-versions "$f"
    return 0
  fi
  local line tag
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line// /}"
    [[ -n "$line" ]] || continue
    tag="$(tulan_k8s_normalize_version_tag "$line")"
    echo "$tag"
  done < "$f"
}

tulan_k8s_normalize_version_tag() {
  local tag="$1"
  tag="${tag#rancher/rancher:}"
  tag="${tag#rancher/rancher/}"
  [[ "$tag" == v* ]] || tag="v${tag}"
  echo "$tag"
}

tulan_k8s_image_from_tag() {
  local tag
  tag="$(tulan_k8s_normalize_version_tag "$1")"
  echo "rancher/rancher:${tag}"
}

tulan_k8s_tag_from_image() {
  local image="${1:-}"
  image="${image##*:}"
  tulan_k8s_normalize_version_tag "${image:-unknown}"
}

tulan_k8s_list_upgrade_versions() {
  local f
  f="$(tulan_k8s_versions_file)"
  if [[ -f "$f" ]]; then
    tulan_k8s_read_versions_from_file "$f"
    return 0
  fi
  tulan_k8s_tag_from_image "${TULAN_K8S_UPGRADE_DEFAULT}"
}

# 仅保留 >= 当前版本的 tag（用于 upgrade 交互列表）
tulan_k8s_filter_upgrade_versions_ge() {
  local current_tag="$1"
  tulan_python k8s filter-ge --current "$current_tag"
}

tulan_k8s_resolve_current_image() {
  local image=""
  tulan_k8s_load_rancher_config
  image="${RANCHER_IMAGE:-}"
  if [[ -z "$image" ]] && command -v docker &>/dev/null; then
    image="$(docker inspect -f '{{.Config.Image}}' "${CONTAINER_NAME:-${TULAN_K8S_CONTAINER}}" 2>/dev/null || true)"
  fi
  echo "${image:-unknown}"
}

tulan_k8s_prompt_upgrade_image() {
  local -a versions=()
  local current_image current_tag choice i target_image target_tag default_idx=1

  if [[ -n "${RANCHER_UPGRADE_IMAGE:-}" ]]; then
    return 0
  fi

  current_image="$(tulan_k8s_resolve_current_image)"
  current_tag="$(tulan_k8s_tag_from_image "$current_image")"

  mapfile -t versions < <(tulan_k8s_list_upgrade_versions | tulan_k8s_filter_upgrade_versions_ge "$current_tag")
  if [[ ${#versions[@]} -eq 0 ]]; then
    tulan_error "没有不低于当前版本 (${current_tag}) 的可选升级版本"
    tulan_log "版本列表: $(tulan_k8s_versions_file)"
    tulan_log "可指定更高版本: brew k8s upgrade -V vX.Y.Z"
    return 1
  fi

  echo ""
  echo "Rancher 升级"
  echo "────────────────────────────────────"
  echo "  当前版本: ${current_image}"
  echo ""
  echo "  可选升级版本（不含低于当前的旧版本）:"
  for i in "${!versions[@]}"; do
    if [[ "${versions[$i]}" == "$current_tag" ]]; then
      echo "  [$((i + 1))] ${versions[$i]}  ← 当前"
    elif [[ "$i" -eq 0 ]]; then
      echo "  [$((i + 1))] ${versions[$i]}  (推荐)"
    else
      echo "  [$((i + 1))] ${versions[$i]}"
    fi
  done
  echo "  也可直接输入版本号（如 v2.10.0 或 rancher/rancher:v2.10.0）"
  echo ""
  echo "  版本列表: $(tulan_k8s_versions_file)"
  echo "  更新列表: brew update（随 bin 索引同步）"
  echo ""
  read -r -p "请选择升级目标 [1-${#versions[@]}] (默认 ${default_idx}): " choice
  choice="${choice:-$default_idx}"

  if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#versions[@]} )); then
    target_tag="${versions[$((choice - 1))]}"
    target_image="$(tulan_k8s_image_from_tag "$target_tag")"
  elif [[ "$choice" == rancher/rancher:* ]]; then
    target_image="$choice"
    target_tag="$(tulan_k8s_tag_from_image "$target_image")"
  elif [[ -n "$choice" ]]; then
    target_tag="$(tulan_k8s_normalize_version_tag "$choice")"
    target_image="$(tulan_k8s_image_from_tag "$target_tag")"
  else
    tulan_error "无效选择: ${choice}"
    return 1
  fi

  if [[ "$target_tag" == "$current_tag" ]]; then
    tulan_log "目标版本与当前相同，将重新部署该版本"
  fi

  export RANCHER_UPGRADE_IMAGE="$target_image"
  echo ""
  echo "  升级目标: ${RANCHER_UPGRADE_IMAGE}"
  echo ""
}
