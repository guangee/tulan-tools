#!/usr/bin/env bash
# GitHub Actions 用：下载 linux amd64/arm64 二进制到 STAGING 目录

set -euo pipefail

STAGING="${1:-${RUNNER_TEMP}/binaries}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

log() { echo "[ci-download] $*"; }
err() { echo "[ci-download] 错误: $*" >&2; }

curl_download() {
  local url="$1" dest="$2"
  local attempt=1 max_attempts=5

  mkdir -p "$(dirname "$dest")"
  log "下载: $url"

  while (( attempt <= max_attempts )); do
    if curl -fsSL \
      --connect-timeout 30 \
      --max-time 600 \
      --retry 3 \
      --retry-delay 5 \
      --retry-all-errors \
      -o "${dest}.part" \
      "$url"; then
      mv -f "${dest}.part" "$dest"
      if [[ -s "$dest" ]]; then
        log "完成: $dest ($(wc -c < "$dest") bytes)"
        return 0
      fi
      err "空文件: $dest"
    else
      err "第 ${attempt}/${max_attempts} 次失败: $url"
    fi
    rm -f "${dest}.part"
    attempt=$((attempt + 1))
    sleep 5
  done

  err "下载失败: $url"
  return 1
}

github_latest_tag() {
  local repo="$1"
  local auth_args=()
  if [[ -n "$GITHUB_TOKEN" ]]; then
    auth_args=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi

  curl -fsSL \
    --connect-timeout 30 \
    --max-time 120 \
    "${auth_args[@]}" \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: tulan-tools-ci" \
    "https://api.github.com/repos/${repo}/releases/latest" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])"
}

main() {
  mkdir -p "${STAGING}/linux-amd64" "${STAGING}/linux-arm64}"
  log "暂存目录: ${STAGING}"
  df -h "${STAGING}" || true

  local kube_ver compose_ver mc_ver base

  kube_ver="$(curl -fsSL --connect-timeout 30 --max-time 60 https://dl.k8s.io/release/stable.txt)"
  [[ -n "$kube_ver" ]] || { err "无法获取 kubectl 版本"; exit 1; }
  log "kubectl ${kube_ver}"

  for arch in amd64 arm64; do
    base="https://dl.k8s.io/release/${kube_ver}/bin/linux/${arch}"
    curl_download "${base}/kubectl" "${STAGING}/linux-${arch}/kubectl"
    curl -fsSL "${base}/kubectl.sha256" | awk '{print $1}' > "${STAGING}/linux-${arch}/kubectl.sha256"
    chmod +x "${STAGING}/linux-${arch}/kubectl"
  done

  compose_ver="$(github_latest_tag "docker/compose")"
  [[ -n "$compose_ver" ]] || { err "无法获取 docker-compose 版本"; exit 1; }
  log "docker-compose ${compose_ver}"

  curl_download \
    "https://github.com/docker/compose/releases/download/${compose_ver}/docker-compose-linux-x86_64" \
    "${STAGING}/linux-amd64/docker-compose"
  curl_download \
    "https://github.com/docker/compose/releases/download/${compose_ver}/docker-compose-linux-aarch64" \
    "${STAGING}/linux-arm64/docker-compose"
  chmod +x "${STAGING}/linux-amd64/docker-compose" "${STAGING}/linux-arm64/docker-compose"

  mc_ver="$(github_latest_tag "minio/mc")"
  [[ -n "$mc_ver" ]] || { err "无法获取 mc 版本"; exit 1; }
  log "mc ${mc_ver}"

  curl_download \
    "https://github.com/minio/mc/releases/download/${mc_ver}/mc.linux-amd64.${mc_ver}" \
    "${STAGING}/linux-amd64/mc"
  curl_download \
    "https://github.com/minio/mc/releases/download/${mc_ver}/mc.linux-arm64.${mc_ver}" \
    "${STAGING}/linux-arm64/mc"
  chmod +x "${STAGING}/linux-amd64/mc" "${STAGING}/linux-arm64/mc"

  printf '{"kubectl":"%s","docker-compose":"%s","mc":"%s"}' \
    "$kube_ver" "$compose_ver" "$mc_ver" > "${STAGING}/versions.json"

  if [[ -n "${GITHUB_ENV:-}" ]]; then
    {
      echo "STAGING=${STAGING}"
      echo "KUBE_VER=${kube_ver}"
      echo "COMPOSE_VER=${compose_ver}"
      echo "MC_VER=${mc_ver}"
    } >> "$GITHUB_ENV"
  fi

  log "全部下载完成"
  ls -lh "${STAGING}/linux-amd64" "${STAGING}/linux-arm64"
}

main "$@"
