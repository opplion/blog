---
title: 一文教你自建VPN
date: 2026-02-25 16:37:12
tags: 计算机网络
categories: 其他
cover: https://sona-nyl.oss-cn-hangzhou.aliyuncs.com/img/10.webp
---

## 前言

对于跑服务而言，云服务器虽然功能强大，但高昂的价格让人望而生畏。本文将提供一种更加经济的方案，让你在只有一个公网IP的情况下，将流量全部转发到本地机器上运行。

### 概念梳理

VPN（Virtual Private Network，虚拟专用网络）通过软件模拟在两个不同网段之间建立一条虚拟的"网线"，使它们的网络环境看起来仿佛处于同一个局域网中。WireGuard 是一种现代、高性能的 VPN 协议，相比传统的 OpenVPN 等方案，配置更简单，性能更好。

### 准备工作

至少需要两台机器：
- **服务端**：拥有公网IP的云服务器
- **客户端**：本地机器（需要将流量转发到的目标）

在每台机器上安装 WireGuard 组网工具，Linux 内核版本要求 >= 5.6（或使用 WireGuard 的内核模块兼容旧版本）。

**服务端额外准备**：
```bash
# 开启IP转发
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p

# 确保防火墙开放UDP端口（以50814为例）
# 如果使用ufw：
ufw allow 50814/udp
# 如果使用iptables：
iptables -A INPUT -p udp --dport 50814 -j ACCEPT
```

### 执行步骤

#### 1. 生成密钥对

服务端和客户端都需要生成各自的公私钥对（建议在各自机器上生成）：

```bash
# 服务端生成密钥
wg genkey | tee server_privatekey | wg pubkey > server_publickey

# 客户端生成密钥
wg genkey | tee client_privatekey | wg pubkey > client_publickey
```

#### 2. 编写配置文件

**服务端配置** (`/etc/wireguard/wg0.conf`)：

```ini
[Interface]
PrivateKey = 服务端私钥
Address = 10.0.8.1/24
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
ListenPort = 50814  # 注意该端口是UDP端口
MTU = 1420

[Peer]
PublicKey = 客户端公钥
AllowedIPs = 10.0.8.10/32  # 客户端的具体IP地址
```

**客户端配置** (`/etc/wireguard/client.conf`)：

```ini
[Interface]
PrivateKey = 客户端私钥
Address = 10.0.8.10/24
DNS = 8.8.8.8
MTU = 1420

[Peer]
PublicKey = 服务端公钥
Endpoint = 你的公网IP:50814
AllowedIPs = 0.0.0.0/0  # 转发所有流量到VPN，如只需VPN内网互通则用 10.0.8.0/24
PersistentKeepalive = 25
```

> **注意**：
> - `eth0` 需要替换为服务端实际的公网网卡名称（可用 `ip addr` 查看）
> - 服务端的 `AllowedIPs` 指定允许连接的客户端IP，`/32` 表示精确到单个IP
> - 客户端的 `AllowedIPs` 设为 `0.0.0.0/0` 会将所有流量通过VPN转发

#### 3. 启动 WireGuard

**服务端**：
```bash
# 启动WireGuard
wg-quick up wg0
# 停止WireGuard
wg-quick down wg0
# 开机自启
systemctl enable wg-quick@wg0
```

**客户端**：
```bash
# 启动WireGuard
wg-quick up client
# 停止WireGuard
wg-quick down client
# 开机自启
systemctl enable wg-quick@client
```

#### 4. 扩展
1. 在服务端配置文件中添加多个 `[Peer]` 段落，每个客户端配置独立的内网 IP 和公钥，就可以添加多个本地节点。
2. 如果你也和主包一样只需要把流量转发到本地，在服务器上可以通过如下命令开启linux内核的ip转发，不需要nignx。
```
sudo sysctl -w net.ipv4.ip_forward=1 （开启ip转发）
sudo iptables -t nat -A PREROUTING -p tcp --dport 服务器端口 -j DNAT --to-destination 客户端ip:端口
```
### 工作原理

#### NAT 穿透与连接建立

在没有 VPN 的情况下，本地机器通过路由器访问公网时，路由器会维护一张 NAT（网络地址转换）表，记录内部IP与端口号的映射关系。当外部服务器响应时，路由器根据 NAT 表将数据包转发给对应的内部机器。

但问题在于：路由器的 NAT 记录有时效性，如果长时间没有活动会被清理掉。而且，外网主动发起的连接无法穿透 NAT 到达内网。

WireGuard 通过以下方式解决这个问题：

1. **Keepalive 机制**：客户端设置 `PersistentKeepalive = 25`，每25秒主动向服务端发送一个 UDP 心跳包，确保 NAT 表项始终有效。

2. **UDP 打洞**：WireGuard 监听配置的 UDP 端口，将 VPN 流量封装在 UDP 数据包中传输。服务端收到后解封装并转发到目标网络。

#### 数据流转过程

1. **虚拟网卡创建**：WireGuard 启动时创建虚拟网卡（如 `wg0`），配置指定的内网 IP 地址。

2. **路由规则匹配**：根据 `AllowedIPs` 配置，系统将目标 IP 匹配的流量路由到虚拟网卡。

3. **加密与封装**：WireGuard 监听虚拟网卡，捕获流量后使用预共享的公钥加密，封装成 UDP 数据包。

4. **网络传输**：加密后的 UDP 数据包通过物理网卡发送到对端（服务端或客户端）。

5. **解密与转发**：对端 WireGuard 接收 UDP 包，解密后还原原始数据，通过虚拟网卡转发到本地网络。

```
客户端访问外网 ──> 路由到 wg0 虚拟网卡 ──> WireGuard 加密封装
                                            ↓
                                    通过公网 UDP 传输
                                            ↓
服务端接收 UDP 包 ──> WireGuard 解密 ──> 转发到本地网络
```

通过这种方式，本地的机器仿佛拥有了服务端的公网 IP，可以直接访问互联网，或者反向地将服务端的流量转发到本地处理。

