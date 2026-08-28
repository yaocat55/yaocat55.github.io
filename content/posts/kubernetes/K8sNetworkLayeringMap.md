---
title: "K8s 网络分层全景：OSI 七层视角下看清 Pod IP、Service、Ingress 与组件分工"
date: 2024-05-22T11:30:03+00:00
tags: ["容器技术", "原理解析", "Kubernetes"]
categories: ["技术类"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "K8s 网络为什么这么难懂？因为它是三张网叠在一起（节点网段/Pod 网段/Service 网段），且不同组件在不同协议层发力（CNI 在 L3、kube-proxy 在 L4、Ingress 在 L7）。本文用 OSI 七层/TCP-IP 四层做坐标系，逐层说明 K8s 通用组件职责，辨析 Pod IP 与物理机 IP 等易混概念。"
disableShare: true
hideSummary: false
searchHidden: false
ShowReadingTime: true
ShowBreadCrumbs: true
ShowPostNavLinks: true
ShowWordCount: true
ShowRssButtonInSectionTermList: true
UseHugoToc: true
cover:
    image: ""
    caption: ""
    relative: true
    hidden: false
---

# 为什么 K8s 网络这么难懂

因为 K8s 的"网络"根本不是一张网，而是**三张网叠在一起**，而且不同组件在**不同的协议层**各干各的：

| 网 | 网段（本文 kind 集群实测） | 谁的"地盘" |
|------|------|------|
| 节点网段 | ` 172.18.0.0/16 ` （节点 IP：172.18.0.2/3/4） | 物理机/虚拟机网卡 |
| Pod 网段 | ` 10.244.0.0/16 ` （Pod IP：10.244.1.x、10.244.2.x） | 集群内每个 Pod 一个 IP |
| Service 网段 | ` 10.96.0.0/16 ` （ClusterIP：10.96.x.x） | 虚拟的"服务名"入口 |

再加上：CoreDNS 在 **L7** 解析服务名、kube-proxy 在 **L4** 做转发、kindnet/CNI 在 **L3** 管 Pod IP 和路由、Ingress 在 **L7** 做域名路由——初学者拿着传统网络的知识套进来，发现"Pod 的 IP 不是 DNS 服务器的 IP"、"Service 的 IP 没有网卡"，自然就绕晕了。

这篇先用 OSI/TCP-IP 建立坐标系，再把 K8s 的每个通用组件**放进对应的层**，最后辨析那些最容易混的概念。

## 1. OSI 七层与 TCP/IP 四层回顾（坐标系）

### 1.1 OSI 七层（通俗版）

| 层 | 名字 | 一句话职责 | 传统世界的样子 |
|------|------|------|------|
| L7 | 应用层 | 应用程序的"语言"：HTTP、DNS、FTP | 你写的接口、浏览器请求 |
| L6 | 表示层 | 数据格式、加密、压缩 | 编码转换（现在大多并入应用层） |
| L5 | 会话层 | 建立/维持/断开会话 | 登录状态、连接保持（现在大多并入应用层） |
| L4 | 传输层 | 端到端传输：**端口** + 可靠性（TCP/UDP） | "发给哪台机器的哪个服务"——端口号在这层 |
| L3 | 网络层 | **IP 地址** + 路由：跨网络寻址 | 路由器的活：数据包怎么跳到目标网段 |
| L2 | 数据链路层 | MAC 地址 + 帧：同网段内交付 | 交换机：把帧交给同网段的下一跳 |
| L1 | 物理层 | 比特流：网线、信号 | 网卡、网线、无线信号 |

**记忆口诀**：从下往上——"物理传比特、链路找 MAC、网络定 IP、传输分端口、应用懂语义"。

**封装与解封装**（理解分层的关键）：数据从应用层出发，每往下一层就包一层"信封"（L4 加端口信息、L3 加 IP 地址、L2 加 MAC 地址），接收方每往上一层就拆一层信封。就像寄快递：你写地址（应用层），快递公司贴面单（网络层），货车按路段交接（链路层），每个环节只关心自己那一层的信息。

### 1.2 TCP/IP 四层与 OSI 的映射

```mermaid
%% OSI 七层 与 TCP/IP 四层 的对应关系
flowchart LR
    classDef root fill:#0f172a,stroke:#3b82f6,stroke-width:2.5px,color:#bfdbfe,font-weight:bold;
    classDef process fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#e5e7eb;

    subgraph OSI["OSI 七层"]
        A7["L7 应用层<br/>L6 表示层<br/>L5 会话层"]
        A4["L4 传输层"]
        A3["L3 网络层"]
        A2["L2 链路层<br/>L1 物理层"]
    end
    subgraph TCPIP["TCP/IP 四层"]
        B4["应用层<br/>(HTTP/DNS)"]
        B3["传输层<br/>(TCP/UDP)"]
        B2["网际层<br/>(IP)"]
        B1["网络接口层<br/>(以太网)"]
    end

    A7 -.-> B4
    A4 -.-> B3
    A3 -.-> B2
    A2 -.-> B1

    class OSI process;
    class TCPIP root;
```

**关键认知**：TCP/IP 把 OSI 的 L5-L7 合并成"应用层"，L1-L2 合并成"网络接口层"，中间 L3/L4 一一对应。**我们讨论 K8s 网络时，主要用到的是 L2/L3/L4/L7**（L1 网线、L5/L6 已并入应用层，基本不参与讨论）。

## 2. K8s 的三张网（全景框架）

```mermaid
%% K8s 三网段: 节点网段 / Pod 网段 / Service 网段 各司其职
flowchart TD
    classDef root fill:#0f172a,stroke:#3b82f6,stroke-width:2.5px,color:#bfdbfe,font-weight:bold;
    classDef process fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#e5e7eb;
    classDef data fill:#052e16,stroke:#16a34a,stroke-width:2px,color:#bbf7d0,font-weight:bold;

    N["节点网段 172.18.0.0/16<br/>节点 IP: 172.18.0.2/3/4<br/>L3 物理网卡"]
    P["Pod 网段 10.244.0.0/16<br/>每节点一个子网: 10.244.1.x / 10.244.2.x<br/>L3 由 CNI(kindnet) 分配与路由"]
    S["Service 网段 10.96.0.0/16<br/>ClusterIP: 10.96.x.x(虚拟,无网卡)<br/>L4 由 kube-proxy 实现"]

    N --> P
    P --> S

    class N,P,S root;
```

**三张网的定位**：

| 网 | 谁在用 | 谁维护 | 本质 |
|------|------|------|------|
| 节点网段 | 节点的操作系统、物理/虚拟机网卡 | 你的基础设施（Docker/虚拟机） | 真实存在的网卡 IP |
| Pod 网段 | 每个 Pod（虚拟网卡） | **CNI 插件**（kind 里是 kindnet，生产是 Calico/Terway/Flannel） | 集群内部的"虚拟网"，Pod 们在这个网段里互访 |
| Service 网段 | Service 的 ClusterIP | **kube-proxy**（iptables/ipvs 规则） | **纯虚拟的**——没有任何网卡有这个 IP，它只存在于转发规则里 |

> ⚠️ 新手提示： ` 10.96.0.1 ` 是集群 API Server 的 Service、 ` 10.96.0.10 ` 是 CoreDNS 的 Service——它们也在 Service 网段里，说明"集群的 DNS 本身也是一个 Service"。这就是"Pod 的 IP 不是 DNS 服务器的 IP"的来源：**Pod IP 是 10.244.x.x，DNS 的 IP 是 10.96.0.10，它们本来就在不同的网**。

## 3. K8s 通用组件逐层对应（职责地图）

不管 kind 还是 kubeadm，下面这些组件都有（名字可能略有差异），按协议层放：

| OSI 层 | K8s 组件 | 在这一层干什么 | 传统世界的对应物 |
|------|------|------|------|
| **L1/L2**（物理/链路） | 节点网卡、Docker bridge、CNI 的 veth 对 | 把比特和帧在节点/容器间搬动；veth 对 = 一根"虚拟网线" | 网线、交换机 |
| **L3**（网络） | **CNI（kindnet/Calico/Terway）** | 给 Pod 分配 IP（IPAM）、维护路由规则，让跨节点 Pod 能互通 | 路由器 + DHCP |
| **L4**（传输） | **kube-proxy + Service** | 把"ClusterIP:端口" DNAT 到后端 Pod（iptables/ipvs 规则）；Endpoints 提供后端列表 | 负载均衡器（四层） |
| **L7**（应用） | **CoreDNS** | 解析服务名 → ClusterIP（ ` nginx-svc ` → ` 10.96.x.x ` ） | DNS 服务器 |
| **L7**（应用） | **Ingress / Gateway API** | 按域名 + 路径路由到 Service；终止 TLS | 反向代理 / Nginx |

**一句话总览**：CNI 管"Pod 之间怎么走"（L3），kube-proxy 管"流量怎么到 Service 后端"（L4），DNS 管"名字怎么变成 IP"（L7），Ingress 管"域名怎么找到 Service"（L7）——**各管一层，互不越界**。

## 4. 最容易混的概念辨析

### 4.1 三个 IP，三种身份

| IP | 网段（实测） | 是谁 | 存在形式 | 别人怎么用它 |
|------|------|------|------|------|
| 节点 IP | 172.18.0.2/3/4 | 节点操作系统网卡 | 真实网卡 | SSH、NodePort 访问（`节点IP:端口`） |
| Pod IP | 10.244.1.x / 10.244.2.x | 每个 Pod 的虚拟网卡 | veth 虚拟网卡 | 集群内互访，但**会变**（Pod 重建就换） |
| ClusterIP | 10.96.x.x | Service 的"虚拟 IP" | **只存在于转发规则**，无网卡 | 集群内访问 `服务名` 时 DNS 解析到它 |

**三个 IP 不能互相替代**： ` curl http://10.244.1.63 ` （Pod IP）在集群内能通，但 Pod 一重建就失效； ` curl http://10.96.x.x ` （ClusterIP）稳定，但只在集群内通；节点 IP 可以 SSH 但一般不打业务流量。

### 4.2 三个端口，三种语义

| 端口 | 在哪 | 作用 |
|------|------|------|
| 容器端口（containerPort） | Pod 内部 | 应用监听的端口（如 nginx 的 80） |
| 服务端口（port / targetPort） | Service 定义 | port = 对外暴露的端口；targetPort = 转发到容器的哪个端口 |
| 节点端口（nodePort） | 每个节点上 | NodePort 类型的 Service 在节点上开的端口（30000-32767），外部走 `节点IP:nodePort` |

### 4.3 三个"路由/转发"动作，别混

| 动作 | 在哪层 | 谁做 | 例子 |
|------|------|------|------|
| **路由** | L3 | CNI（kindnet） | Pod 10.244.1.x 要访问 10.244.2.x，按路由表跳到对应节点 |
| **DNAT 转发** | L4 | kube-proxy（iptables/ipvs） | ClusterIP:80 → PodIP:80 的地址转换 |
| **反向代理** | L7 | Ingress / Gateway | 域名 `nginx.local` + 路径 → 转发到某个 Service |

**最经典的混**：把 kube-proxy 的 iptables 当成"防火墙规则"或"七层代理"——它既不是防火墙也不是代理，是**四层的地址转换**（DNAT），工作在传输层，不管 HTTP 内容和域名。

### 4.4 "DNS 解析" vs "路由转发"，是两件事

- **DNS（CoreDNS，L7）**：把名字变 IP—— ` nginx-svc ` → ` 10.96.x.x ` 。它**不转发流量**，只回答"这个服务名是哪个 IP"。
- **kube-proxy（L4）**：把流量送到——拿着 ClusterIP 去查转发规则，DNAT 到后端 Pod。它**不做名字解析**。

两者串联才是完整链路：**问 DNS 拿 IP（L7）→ 交给网络栈按 IP 转发（L4/L3）**。

## 5. 一条请求的完整旅程（串层看）

### 5.1 集群内：Pod A 调用 Pod B（微服务互调）

```mermaid
%% 集群内服务调用: 每一跳标注 OSI 层与组件
flowchart LR
    classDef root fill:#0f172a,stroke:#3b82f6,stroke-width:2.5px,color:#bfdbfe,font-weight:bold;
    classDef process fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#e5e7eb;
    classDef data fill:#052e16,stroke:#16a34a,stroke-width:2px,color:#bbf7d0,font-weight:bold;

    A["Pod A<br/>请求 http://nginx-svc"]
    D["CoreDNS (L7)<br/>nginx-svc → 10.96.x.x"]
    K["kube-proxy (L4)<br/>DNAT → 10.244.x.x:80"]
    R["CNI 路由 (L3)<br/>跨节点跳转"]
    B["Pod B (nginx)"]

    A -->|"1 查 DNS"| D
    D -->|"2 返回 ClusterIP"| A
    A -->|"3 按 ClusterIP 发包"| K
    K -->|"4 改写目标地址"| R
    R -->|"5 到达 Pod 网段"| B

    class A,B,D root;
    class K,R process;
```

**每一跳的层**：① DNS 解析（L7，CoreDNS）→ ③ 发往 ClusterIP（L3/L4）→ ④ 地址转换（L4，kube-proxy）→ ⑤ 路由送达（L3，CNI）。**一次调用，跨了应用层、传输层、网络层三个层，每个层都有对应的 K8s 组件**。

### 5.2 集群外：浏览器访问

```mermaid
%% 集群外访问: 域名 → Ingress(L7) → Service(L4) → Pod
flowchart LR
    classDef root fill:#0f172a,stroke:#3b82f6,stroke-width:2.5px,color:#bfdbfe,font-weight:bold;
    classDef process fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#e5e7eb;
    classDef data fill:#052e16,stroke:#16a34a,stroke-width:2px,color:#bbf7d0,font-weight:bold;

    U["浏览器<br/>nginx.local"]
    I["Ingress (L7)<br/>按域名/路径路由"]
    S["Service (L4)<br/>ClusterIP 负载均衡"]
    P["Pod"]

    U -->|"DNS → 入口IP"| I
    I -->|"按 Host 找到 Service"| S
    S -->|"kube-proxy DNAT"| P

    class U,I root;
    class S process;
    class P data;
```

**多了一层 L7**：浏览器 → Ingress（L7 按域名路由）→ Service（L4 负载均衡）→ Pod。这就是"从内到外全打通"的完整网络视图。

## 6. 总表：一层、一组件、一职责

| 层 | 组件 | 一句话职责 | 常见误解 |
|------|------|------|------|
| L1/L2 | 网卡/veth/Docker bridge | 比特与帧的搬运 | — |
| L3 | CNI（kindnet/Calico/Terway） | 分配 Pod IP + 跨节点路由 | 以为 Pod IP 是节点 IP |
| L4 | kube-proxy + Service | ClusterIP 的 DNAT 转发 + 负载均衡 | 以为是防火墙或七层代理 |
| L7 | CoreDNS | 服务名 → ClusterIP | 以为 DNS 管转发 |
| L7 | Ingress / Gateway API | 域名/路径 → Service | 以为它做四层转发 |

**三个记忆锚点**：

1. **三张网**：节点网（真实网卡）→ Pod 网（CNI 的虚拟网）→ Service 网（纯虚拟，只存在于规则里）；
2. **组件分层不越界**：CNI 管 L3、kube-proxy 管 L4、DNS/Ingress 管 L7——谁出问题就找对应层的组件；
3. **传统知识完全适用**：K8s 没有发明新协议，它只是把"路由、NAT、DNS、反向代理"这些传统网络组件**搬进了集群内部，并换成了 K8s 的名字**——用 OSI 当坐标系，每个组件立刻找到自己的位置。
