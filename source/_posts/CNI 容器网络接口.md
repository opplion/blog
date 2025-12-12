---
title: CNI 容器网络接口
date: 2025-12-11 17:13:09
tags: Kubernetes
categories: 容器与虚拟化
cover: http://sona-nyl.oss-cn-hangzhou.aliyuncs.com/img/8.webp
---

## 什么是 CNI？

在 Kubernetes 中，核心组件（如 kubelet、调度器等）专注于 Pod 的调度与生命周期管理，而**容器网络的实现被抽象为一个标准化接口**——即 **CNI（Container Network Interface，容器网络接口）**。

通过这一设计，Kubernetes 将网络功能解耦，交由专门的 CNI 插件负责 Pod 的 IP 分配、虚拟网卡创建、路由配置、网络策略实施等任务，从而实现灵活、可插拔且与底层基础设施无关的网络架构。

---

## Pod 网络的起点：网络命名空间

在 CNI 插件介入之前，Pod 的网络基础已经由 Linux 内核准备好：

当 kubelet 准备创建一个 Pod 时，容器运行时会首先为该 Pod **创建一个独立的网络命名空间（Network Namespace）**。这是 Linux 的一项核心隔离机制，使得每个 Pod 拥有：

- 独立的网络协议栈（包括 loopback 接口）；
- 与主机及其他 Pod 网络完全隔离的初始状态。

> 📌 此时，该网络命名空间**尚未连接到任何网络设备**（如 veth 对、网桥或物理网卡），因此 Pod 虽有“网络”，但无法通信。

CNI 插件的作用，正是在这一“空白”网络命名空间中注入网络能力——创建虚拟网卡、分配 IP、配置路由，并将其连接到主机或集群网络，最终使 Pod 具备完整的网络连通性。

---

## CNI 是如何工作的？

CNI 并不是一个常驻的守护进程，而是一组可执行的二进制文件。当 Pod 被创建时，Kubernetes 调用这些插件来完成复杂的网络配置。其核心工作流程可以概括为以下两步：

### 1. 建立联通：打通宿主机与 Pod 的隧道

CNI 的首要任务是打破“网络命名空间”的隔离，让 Pod 能与外界通信。

大多数 CNI 插件（如 Flannel, Calico）使用 **Veth Pair（虚拟以太网对）** 技术来实现这一点。你可以把 Veth Pair 想象成一根**虚拟网线**：
*   **一端（eth0）**：被“插”在 Pod 的网络命名空间内，作为 Pod 的网卡。
*   **另一端（vethxxx）**：被留在宿主机（Host）上，通常连接到一个网桥（如 `cni0`）或直接通过路由规则转发流量。

通过这根“虚拟网线”，数据包就能从 Pod 内部流出，到达宿主机的网络协议栈，进而被转发到其他节点。

### 2. 身份标识：IP 地址管理 (IPAM)

打通物理连接后，Pod 还需要一个合法的“身份证”——即 **集群内唯一的 IP 地址**。

CNI 插件通常包含或调用一个专门的 **IPAM（IP Address Management）插件**（如 `host-local` 或 `calico-ipam`）来完成此任务：
*   **分配 IP**：IPAM 插件从预定义的子网段（CIDR）中申请一个未使用的 IP，并将其分配给 Pod 内部的 `eth0` 网卡。
*   **保证唯一性**：确保该 IP 在整个 Kubernetes 集群中不与其他 Pod 冲突。
*   **路由广播**：一旦 IP 分配完成，CNI 插件会在宿主机上配置路由表（或通过 BGP 广播），告诉网络：“去往这个 Pod IP 的数据包，请发送到这台宿主机的这个 veth 接口。”

## 总结：一个 Pod 网络的生命周期

当 Kubelet 决定启动一个 Pod 时，幕后发生的一系列动作如下：

```bash
step
    Kubelet->>Runtime: 1. 请求创建 Pod
    Runtime->>NetNS: 2. 创建网络命名空间 (仅有 loopback)
    Runtime->>CNI: 3. 调用 CNI ADD 指令 (传入 NetNS 路径)
    CNI->>NetNS: 4. 创建 Veth Pair (连接主机与Pod)
    CNI->>IPAM: 5. 请求分配 IP 地址
    CNI->>NetNS: 6. 将 IP 绑定到 Pod 的 eth0
    CNI->>Runtime: 7. 配置完成，返回结果
    Runtime-->>Kubelet: Pod 启动成功，网络就绪
```

