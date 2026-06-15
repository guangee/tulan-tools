#!/usr/bin/env bash
# 1. 立即修复主机名解析 (解决 sudo 报无法解析 host 的烦人信息)
set -euo pipefail

CURRENT_HOSTNAME=$(hostname)
if ! grep -q "$CURRENT_HOSTNAME" /etc/hosts; then
  echo "127.0.0.1 $CURRENT_HOSTNAME" | sudo tee -a /etc/hosts
fi

# 2. 建立 crictl 配置文件 (让 crictl 知道去哪里找容器)
cat <<EOF | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///run/k3s/containerd/containerd.sock
image-endpoint: unix:///run/k3s/containerd/containerd.sock
timeout: 10
debug: false
EOF

# 3. 写入别名到 .zshrc (针对 Oh My Zsh 环境)
# 使用 sed 确保不会重复添加
sed -i '/RKE2 \/ Containerd/,$d' ~/.zshrc # 先清理旧的错误配置块（如果有）

cat <<'EOF' >> ~/.zshrc

# --- RKE2 / Containerd 快捷配置 ---
export PATH=$PATH:/var/lib/rancher/rke2/bin
alias di='sudo /var/lib/rancher/rke2/bin/crictl images'
alias dps='sudo /var/lib/rancher/rke2/bin/crictl ps'
alias dlogs='sudo /var/lib/rancher/rke2/bin/crictl logs'
alias dexec='sudo /var/lib/rancher/rke2/bin/crictl exec -it'
alias dinspect='sudo /var/lib/rancher/rke2/bin/crictl inspect'
alias k='sudo /var/lib/rancher/rke2/bin/kubectl'
alias kgp='sudo /var/lib/rancher/rke2/bin/kubectl get pods'
alias sudo='sudo -E'
EOF

# 4. 重点：手动让当前会话生效 (不调用 Oh My Zsh 整体，只加载 PATH 和别名)
export PATH=$PATH:/var/lib/rancher/rke2/bin
alias di='sudo /var/lib/rancher/rke2/bin/crictl images'
alias dps='sudo /var/lib/rancher/rke2/bin/crictl ps'
