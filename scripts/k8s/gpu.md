# Rancher 集群接入 GPU 操作指南

本文档用于指导你在 Rancher 管理的 Kubernetes 集群中接入 NVIDIA GPU，并验证可以部署使用 GPU 的容器。

## 1. 前置条件

- 节点已安装 NVIDIA 显卡驱动，且在宿主机执行 `nvidia-smi` 正常。
- 集群节点系统可联网拉取镜像（或已配置私有镜像加速/代理）。
- Rancher 可正常访问目标下游集群（Imported/Provisioned 均可）。
- 建议 GPU 节点使用 Linux，内核与驱动版本匹配。

## 2. 节点准备（建议）

在 GPU 节点打标签，便于后续调度控制：

```bash
kubectl label node <gpu-node-name> accelerator=nvidia --overwrite
```

查看标签：

```bash
kubectl get nodes --show-labels | rg accelerator
```

> 如果节点没有 `rg`，可用 `kubectl get nodes --show-labels` 手工查看。

## 3. 在 Rancher 中安装 NVIDIA GPU Operator

1. 打开 Rancher，进入目标集群。
2. 进入 **Apps -> Charts**（或 **Cluster Tools**，不同版本入口略有差异）。
3. 搜索并安装 **NVIDIA GPU Operator**。
4. 安装时建议确认以下配置：
   - 命名空间：`gpu-operator`
   - `driver.enabled`：如果节点已安装宿主机驱动，可设为 `false`；否则可由 Operator 管理驱动
   - Toolkit / Device Plugin / GFD 保持开启
   - 如需指定运行时，确保使用 `nvidia` runtime（RKE2/containerd 场景）
5. 点击安装并等待组件就绪。

## 4. 安装后检查

### 4.1 查看 Operator 组件状态

```bash
kubectl get pods -n gpu-operator
```

预期关键组件 `Running` 或 `Completed`，例如：

- `nvidia-device-plugin-daemonset-*`
- `nvidia-container-toolkit-daemonset-*`
- `gpu-feature-discovery-*`
- `nvidia-operator-validator-*`

### 4.2 查看 RuntimeClass

```bash
kubectl get runtimeclass
```

通常应看到 `nvidia`（以及可能的 `nvidia-cdi` 等）。

### 4.3 查看节点 GPU 资源是否上报

```bash
kubectl get node -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu
```

如果 GPU 列显示数字（如 `1`、`2`），说明设备插件已上报成功。

## 5. 验证可部署 GPU 容器

创建 `gpu-smoke.yaml`：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-smoke
spec:
  restartPolicy: Never
  runtimeClassName: nvidia
  containers:
    - name: gpu-smoke
      image: nvidia/cuda:12.3.1-base-ubuntu22.04
      command: ["bash", "-lc", "nvidia-smi"]
      resources:
        limits:
          nvidia.com/gpu: 1
```

执行验证：

```bash
kubectl apply -f gpu-smoke.yaml
kubectl logs -f pod/gpu-smoke
kubectl delete -f gpu-smoke.yaml
```

日志中如果成功输出 `NVIDIA-SMI` 信息（显卡型号、驱动、CUDA 版本），即表示 GPU 容器能力可用。

## 6. 业务工作负载接入要点

- 在 Pod/Deployment 中声明 GPU 限制：
  - `resources.limits.nvidia.com/gpu: 1`
- 建议同时设置 CPU/内存 `requests/limits`，避免资源争抢。
- 如仅让工作负载跑在 GPU 节点，可增加：
  - `nodeSelector: { accelerator: nvidia }`
  - 或 `nodeAffinity` 做更细粒度调度。

Deployment 示例片段：

```yaml
spec:
  template:
    spec:
      runtimeClassName: nvidia
      nodeSelector:
        accelerator: nvidia
      containers:
        - name: app
          image: <your-image>
          resources:
            limits:
              nvidia.com/gpu: 1
              cpu: "2"
              memory: 4Gi
            requests:
              cpu: "1"
              memory: 2Gi
```

## 7. 常见问题排查

### 7.1 Pod 一直 Pending

```bash
kubectl describe pod <pod-name>
```

重点看事件：

- `Insufficient nvidia.com/gpu`：GPU 不足或未上报
- `runtimeClass "nvidia" not found`：运行时未注册

### 7.2 组件异常

```bash
kubectl -n gpu-operator get pods
kubectl -n gpu-operator logs -l app=nvidia-device-plugin-daemonset --tail=200
```

### 7.3 节点上 `nvidia-smi` 失败

- 先修复宿主机驱动问题，再回到集群层面排查
- 检查内核升级后驱动是否失效

## 8. 验收标准（建议）

满足以下条件可视为“GPU 已加入 Rancher 并可生产使用”：

- `gpu-operator` 关键组件全部就绪
- `kubectl get runtimeclass` 存在 `nvidia`
- GPU 节点 `allocatable.nvidia.com/gpu` 为正数
- `gpu-smoke` 能输出 `nvidia-smi`
- 业务 Deployment 可稳定申请并使用 GPU
