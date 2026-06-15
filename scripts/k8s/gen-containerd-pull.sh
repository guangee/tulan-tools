#!/usr/bin/env bash
# 根据本机 containerd 已拉取镜像，生成可在另一台机器手工执行的 pull 命令
#
# 用法:
#   brew k8s gen-pull
#   brew k8s gen-pull --socket /run/rancher/rke2/agent/containerd/containerd.sock
#   brew k8s gen-pull --tool crictl

set -euo pipefail

GEN_PULL_SOCKET="${GEN_PULL_SOCKET:-}"
GEN_PULL_TOOL="${GEN_PULL_TOOL:-ctr}"
GEN_PULL_NAMESPACE="${GEN_PULL_NAMESPACE:-k8s.io}"

usage() {
  cat <<'EOF'
用法: brew k8s gen-pull [选项]

读取本机 containerd（k3s / RKE2 / 系统）已拉取镜像，输出可在另一台机器执行的 pull 命令。
仅处理 containerd 镜像，不含 Docker。

选项:
  --socket <path>   指定 containerd socket（默认自动探测，优先 RKE2/k3s）
  --tool ctr|crictl 拉取工具（默认 ctr）
  -n, --namespace   ctr 命名空间（默认 k8s.io）
  -h, --help        显示帮助

示例:
  brew k8s gen-pull | tee pull-images.sh
  # 在目标机器:
  sudo bash pull-images.sh
EOF
}

have_cmd() {
  command -v "$1" &>/dev/null
}

run_privileged() {
  if "$@" 2>/dev/null; then
    return 0
  fi
  if [[ "${EUID:-$(id -u)}" -ne 0 ]] && have_cmd sudo; then
    sudo "$@"
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
    [[ -n "$p" ]] || continue
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
    /run/rancher/rke2/agent/containerd/containerd.sock \
    /run/rancher/rke2/containerd/containerd.sock \
    /run/k3s/containerd/containerd.sock \
    /run/k3s/agent/containerd/containerd.sock \
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

pick_default_socket() {
  local sock
  if [[ -n "$GEN_PULL_SOCKET" ]]; then
    echo "$GEN_PULL_SOCKET"
    return 0
  fi
  while read -r sock; do
    [[ -n "$sock" ]] || continue
    echo "$sock"
    return 0
  done < <(containerd_sockets)
  return 1
}

normalize_ref() {
  local ref="$1"
  ref="${ref#docker.io/}"
  [[ "$ref" == */* ]] || ref="library/${ref}"
  echo "docker.io/${ref}"
}

collect_refs_ctr() {
  local ctr="$1" sock="$2" ns="$3" line ref
  if ! run_privileged "$ctr" -a "$sock" -n "$ns" images ls 2>/dev/null | tail -n +2 | grep -q .; then
    run_privileged "$ctr" -a "$sock" images ls 2>/dev/null | tail -n +2 || true
    return 0
  fi
  run_privileged "$ctr" -a "$sock" -n "$ns" images ls 2>/dev/null | tail -n +2 || true
}

collect_refs_crictl() {
  local crictl="$1" sock="$2" line image tag
  run_privileged "$crictl" --runtime-endpoint "unix://${sock}" images 2>/dev/null \
    | tail -n +2 || true
}

refs_from_ctr_output() {
  local line ref
  while read -r line; do
    [[ -n "$line" ]] || continue
    ref="${line%% *}"
    [[ -n "$ref" && "$ref" != "REF" ]] || continue
    echo "$ref"
  done
}

refs_from_crictl_output() {
  local line image tag
  while read -r line; do
    [[ -n "$line" ]] || continue
    image="$(awk '{print $1}' <<<"$line")"
    tag="$(awk '{print $2}' <<<"$line")"
    [[ -n "$image" && "$image" != "IMAGE" ]] || continue
    if [[ "$tag" == "<none>" || -z "$tag" ]]; then
      echo "$image"
    else
      echo "${image}:${tag}"
    fi
  done
}

emit_header() {
  local sock="$1" label="$2" count="$3"
  cat <<EOF
#!/usr/bin/env bash
# containerd 手工拉取脚本 — 由 brew k8s gen-pull 生成
# 源主机: $(hostname 2>/dev/null || echo unknown)  时间: $(date -Iseconds 2>/dev/null || date)
# socket: ${sock} (${label})  镜像数: ${count}
# 在目标机器执行: sudo bash pull-images.sh
set -euo pipefail

CONTAINERD_SOCKET="${sock}"
CTR_NS="${GEN_PULL_NAMESPACE}"
EOF
}

emit_ctr_commands() {
  local ctr="$1" ref
  cat <<EOF

CTR="${ctr}"
if ! command -v "\${CTR}" &>/dev/null; then
  echo "未找到 ctr 命令" >&2
  exit 1
fi

pull_one() {
  local ref="\$1"
  echo "==> pull \${ref}"
  "\${CTR}" -a "\${CONTAINERD_SOCKET}" -n "\${CTR_NS}" images pull "\${ref}"
}

EOF
  for ref in "$@"; do
    printf 'pull_one %q\n' "$ref"
  done
}

emit_crictl_commands() {
  local crictl="$1" ref
  cat <<EOF

CRICTL="${crictl}"
if ! command -v "\${CRICTL}" &>/dev/null && [[ ! -x "\${CRICTL}" ]]; then
  echo "未找到 crictl 命令" >&2
  exit 1
fi

pull_one() {
  local ref="\$1"
  echo "==> pull \${ref}"
  "\${CRICTL}" --runtime-endpoint "unix://\${CONTAINERD_SOCKET}" pull "\${ref}"
}

EOF
  for ref in "$@"; do
    printf 'pull_one %q\n' "$ref"
  done
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --socket)
        GEN_PULL_SOCKET="${2:-}"
        shift 2
        ;;
      --tool)
        GEN_PULL_TOOL="${2:-ctr}"
        shift 2
        ;;
      -n|--namespace)
        GEN_PULL_NAMESPACE="${2:-k8s.io}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "未知参数: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

main() {
  if [[ "$(uname -s | tr '[:upper:]' '[:lower:]')" != "linux" ]]; then
    echo "此命令需在 Linux 上执行" >&2
    exit 1
  fi

  parse_args "$@"

  local sock label ctr crictl raw
  sock="$(pick_default_socket || true)"
  if [[ -z "$sock" ]]; then
    echo "未发现 containerd socket（k3s/RKE2 是否已安装？）" >&2
    exit 1
  fi
  if [[ -n "$GEN_PULL_SOCKET" && ! -S "$GEN_PULL_SOCKET" ]]; then
    echo "socket 不存在: ${GEN_PULL_SOCKET}" >&2
    exit 1
  fi

  label="$(socket_label "$sock")"
  declare -a refs=()
  declare -A seen=()

  case "$GEN_PULL_TOOL" in
    ctr)
      ctr="$(pick_ctr || true)"
      [[ -n "$ctr" ]] || { echo "未找到 ctr 命令" >&2; exit 1; }
      raw="$(collect_refs_ctr "$ctr" "$sock" "$GEN_PULL_NAMESPACE")"
      while IFS= read -r ref; do
        [[ -n "$ref" ]] || continue
        [[ -n "${seen[$ref]:-}" ]] && continue
        seen[$ref]=1
        refs+=("$ref")
      done < <(refs_from_ctr_output <<<"$raw")
      if ((${#refs[@]} == 0)); then
        echo "socket ${sock} 上未发现 containerd 镜像" >&2
        echo "提示: 在已成功拉取镜像的 Rancher 节点上执行本命令" >&2
        exit 1
      fi
      emit_header "$sock" "$label" "${#refs[@]}"
      emit_ctr_commands "$ctr" "${refs[@]}"
      ;;
    crictl)
      crictl="$(pick_crictl || true)"
      [[ -n "$crictl" ]] || { echo "未找到 crictl 命令" >&2; exit 1; }
      raw="$(collect_refs_crictl "$crictl" "$sock")"
      while IFS= read -r ref; do
        [[ -n "$ref" ]] || continue
        [[ -n "${seen[$ref]:-}" ]] && continue
        seen[$ref]=1
        refs+=("$ref")
      done < <(refs_from_crictl_output <<<"$raw")
      if ((${#refs[@]} == 0)); then
        echo "socket ${sock} 上未发现 containerd 镜像" >&2
        exit 1
      fi
      emit_header "$sock" "$label" "${#refs[@]}"
      emit_crictl_commands "$crictl" "${refs[@]}"
      ;;
    *)
      echo "不支持的 --tool: ${GEN_PULL_TOOL}（仅 ctr / crictl）" >&2
      exit 1
      ;;
  esac

  echo ""
  echo "echo \"完成，共 ${#refs[@]} 个镜像\""
}

main "$@"
