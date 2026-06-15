#!/usr/bin/env bash
# 查看本机已拉取的 Docker 与 containerd（k3s/RKE2）镜像
#
# 用法:
#   brew k8s images
#   sudo bash list-images.sh

set -euo pipefail

section() {
  echo ""
  echo "$1"
  echo "────────────────────────────────────"
}

note() {
  printf '  %s\n' "$*"
}

warn() {
  note "! $*"
}

have_cmd() {
  command -v "$1" &>/dev/null
}

run_privileged() {
  if "$@" 2>/dev/null; then
    return 0
  fi
  if [[ "${EUID:-$(id -u)}" -ne 0 ]] && have_cmd sudo; then
    sudo "$@" 2>/dev/null
    return $?
  fi
  return 1
}

pick_crictl() {
  local p
  for p in \
    /var/lib/rancher/rke2/bin/crictl \
    /var/lib/rancher/k3s/data/current/bin/crictl \
    crictl; do
    if [[ -x "$p" ]] || have_cmd "$p"; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

pick_ctr() {
  local p
  for p in \
    /var/lib/rancher/rke2/bin/ctr \
    /var/lib/rancher/k3s/data/current/bin/ctr \
    ctr; do
    [[ -n "$p" ]] || continue
    if [[ -x "$p" ]] || have_cmd "$p"; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

containerd_sockets() {
  local sock
  for sock in \
    /run/k3s/containerd/containerd.sock \
    /run/k3s/agent/containerd/containerd.sock \
    /run/rancher/rke2/containerd/containerd.sock \
    /run/rancher/rke2/agent/containerd/containerd.sock \
    /run/containerd/containerd.sock \
    /var/run/containerd/containerd.sock; do
    [[ -S "$sock" ]] && echo "$sock"
  done
}

socket_label() {
  local sock="$1"
  case "$sock" in
    */k3s/containerd/*) echo "k3s" ;;
    */k3s/agent/*) echo "k3s-agent" ;;
    */rke2/containerd/*) echo "rke2-server" ;;
    */rke2/agent/*) echo "rke2-agent" ;;
    *) echo "containerd" ;;
  esac
}

show_docker_images() {
  local count=0
  if ! have_cmd docker; then
    warn "未安装 docker 命令"
    return 1
  fi
  if ! run_privileged docker info &>/dev/null; then
    warn "docker 不可用（daemon 未运行或无权限）"
    return 1
  fi
  section "Docker 镜像"
  if run_privileged docker images; then
    count="$(run_privileged docker images -q 2>/dev/null | wc -l | tr -d ' ')"
    note "共 ${count} 个镜像（含重复 tag）"
    return 0
  fi
  warn "docker images 执行失败"
  return 1
}

show_crictl_images() {
  local crictl sock label shown=0 count total=0
  crictl="$(pick_crictl || true)"
  [[ -n "$crictl" ]] || return 1

  while read -r sock; do
    [[ -n "$sock" ]] || continue
    label="$(socket_label "$sock")"
    section "containerd 镜像 [${label}] (${sock})"
    if run_privileged "$crictl" --runtime-endpoint "unix://${sock}" images; then
      shown=1
      count="$(run_privileged "$crictl" --runtime-endpoint "unix://${sock}" images -q 2>/dev/null | wc -l | tr -d ' ')"
      note "共 ${count} 条记录"
      total=$((total + count))
    else
      warn "crictl images 失败"
    fi
  done < <(containerd_sockets)

  if (( shown > 0 )); then
    return 0
  fi
  return 1
}

show_ctr_images() {
  local ctr sock label shown=0
  ctr="$(pick_ctr || true)"
  [[ -n "$ctr" ]] || return 1

  while read -r sock; do
    [[ -n "$sock" ]] || continue
    label="$(socket_label "$sock")"
    section "containerd 镜像 [${label}] (ctr, ${sock})"
    if run_privileged "$ctr" --address "unix://${sock}" -n k8s.io images ls; then
      shown=1
    elif run_privileged "$ctr" --address "unix://${sock}" images ls; then
      shown=1
    else
      warn "ctr images 失败"
    fi
  done < <(containerd_sockets)

  (( shown > 0 )) && return 0
  return 1
}

main() {
  if [[ "$(uname -s | tr '[:upper:]' '[:lower:]')" != "linux" ]]; then
    echo "此命令需在 Linux 上执行"
    exit 1
  fi

  section "本机镜像列表 — $(hostname 2>/dev/null || echo unknown)"
  note "包含 Docker 与 containerd（k3s / RKE2 / 系统）"

  local docker_ok=0 cri_ok=0
  if show_docker_images; then
    docker_ok=1
  fi

  if show_crictl_images; then
    cri_ok=1
  elif show_ctr_images; then
    cri_ok=1
  else
    if [[ "$(containerd_sockets | wc -l | tr -d ' ')" -eq 0 ]]; then
      warn "未发现 containerd socket（可能无 k3s/RKE2 或未启动）"
    else
      warn "未找到 crictl/ctr，无法列出 containerd 镜像"
      note "可安装 crictl 或执行: brew k8s shell-init"
    fi
  fi

  section "摘要"
  note "Docker:      $([[ "$docker_ok" -eq 1 ]] && echo 已列出 || echo 跳过/不可用)"
  note "containerd:  $([[ "$cri_ok" -eq 1 ]] && echo 已列出 || echo 跳过/不可用)"

  if [[ "$docker_ok" -eq 0 && "$cri_ok" -eq 0 ]]; then
    exit 1
  fi
}

main "$@"
