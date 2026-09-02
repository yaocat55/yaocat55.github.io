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
description: "K8s 网络为什么这么难懂？因为它是多层网络叠在一起（物理机网段/节点网段/Pod 网段/Service 网段，kind 里节点网段是容器 IP 而非物理机 IP），且不同组件在不同协议层发力（CNI 在 L3、kube-proxy 在 L4、Ingress 在 L7）。本文用 OSI 七层/TCP-IP 四层做坐标系，逐层说明 K8s 通用组件职责，辨析四个 IP 等易混概念。"
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

因为 K8s 的"网络"根本不是一张网，而是**多张网叠在一起**，而且不同组件在**不同的协议层**各干各的。以本文的 kind 集群为例，从外到内是**四层**：

| 层 | 网段（本文 kind 集群实测） | 谁的"地盘" |
|------|------|------|
| 物理机/宿主机 | ` 192.168.8.26 ` （debian 宿主机） | **真实网卡**（kind 之外的真实世界） |
| 节点容器（kind 特有） | ` 172.18.0.0/16 ` （节点 IP：172.18.0.2/3/4） | **kind 节点 = Docker 容器**，这是 Docker 网络分给节点容器的 IP，不是物理机 IP |
| Pod 网段 | ` 10.244.0.0/16 ` （Pod IP：10.244.1.x、10.244.2.x） | 集群内每个 Pod 一个 IP（CNI 的虚拟网） |
| Service 网段 | ` 10.96.0.0/16 ` （ClusterIP：10.96.x.x） | 虚拟的"服务名"入口 |

> ⚠️ 新手提示：**kind 里看到的 172.18.0.x 是"节点容器"的 IP，不是物理机 IP**——kind 的"容器即节点"让节点本身就是 Docker 容器（网络栈因此多一层）。kubeadm/生产集群没有这一层：节点就是物理机/虚拟机，**节点 IP = 物理机 IP**（如 192.168.8.26）。看下面的图就清楚了。

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
%% OSI 七层 与 TCP/IP 四层 的对应关系 (style 强制深底白字)
flowchart LR
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

    style A7 fill:#0f172a,stroke:#3b82f6,stroke-width:2.5px,color:#ffffff,font-weight:bold
    style A4 fill:#0f172a,stroke:#3b82f6,stroke-width:2.5px,color:#ffffff,font-weight:bold
    style A3 fill:#0f172a,stroke:#3b82f6,stroke-width:2.5px,color:#ffffff,font-weight:bold
    style A2 fill:#0f172a,stroke:#3b82f6,stroke-width:2.5px,color:#ffffff,font-weight:bold
    style B4 fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#ffffff,font-weight:bold
    style B3 fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#ffffff,font-weight:bold
    style B2 fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#ffffff,font-weight:bold
    style B1 fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#ffffff,font-weight:bold
    style OSI fill:#0f172a,stroke:#3b82f6,color:#ffffff,font-weight:bold
    style TCPIP fill:#0f172a,stroke:#6b7280,color:#ffffff,font-weight:bold
```

**关键认知**：TCP/IP 把 OSI 的 L5-L7 合并成"应用层"，L1-L2 合并成"网络接口层"，中间 L3/L4 一一对应。**我们讨论 K8s 网络时，主要用到的是 L2/L3/L4/L7**（L1 网线、L5/L6 已并入应用层，基本不参与讨论）。

## 2. K8s 的多层网络（全景框架）

```mermaid
%% K8s 四层网络栈: 每层一个容器, 内含该层的真实 IP 实例; 数据包自上而下穿透
flowchart TD

    subgraph L1["① 物理机层 · 真实网卡 (L3)"]
        M["debian 宿主机<br/>192.168.8.26<br/>真实 IP · SSH 入口"]
    end

    subgraph L2["② 节点容器层 · kind 特有 (L3 容器网卡)"]
        N1["learn-control-plane<br/>172.18.0.2"]
        N2["learn-worker<br/>172.18.0.3"]
        N3["learn-worker2<br/>172.18.0.4"]
    end

    subgraph L3["③ Pod 网络层 · CNI 虚拟网 (L3)"]
        P1n["nginx-demo pod<br/>10.244.1.63<br/>(worker2 子网)"]
        P2n["nginx-demo pod<br/>10.244.2.69<br/>(worker 子网)"]
        P3n["其他 Pod<br/>10.244.x.x"]
    end

    subgraph L4["④ Service 网络层 · 纯虚拟 (L4)"]
        S1["nginx-svc<br/>10.96.192.178"]
        S2["demo-app-svc<br/>10.96.231.108"]
        S3["CoreDNS<br/>10.96.0.10"]
    end

    M ==> N1 & N2 & N3
    N1 & N2 & N3 ==> P1n & P2n & P3n
    P1n & P2n & P3n ==> S1 & S2 & S3

    style L1 fill:#0f172a,stroke:#3b82f6,stroke-width:2px,color:#ffffff,font-weight:bold
    style L2 fill:#0f172a,stroke:#8b5cf6,stroke-width:2px,color:#ffffff,font-weight:bold
    style L3 fill:#0f172a,stroke:#10b981,stroke-width:2px,color:#ffffff,font-weight:bold
    style L4 fill:#0f172a,stroke:#ef4444,stroke-width:2px,color:#ffffff,font-weight:bold

```

**读图方法**：四层容器（①②③④），每层装着自己的 **IP 实例**——物理机层只有 192.168.8.26，节点层是 3 个容器 IP，Pod 层是真实的 10.244.x.x，Service 层是虚拟的 10.96.x.x（CoreDNS 10.96.0.10 也在其中）。**"哪个 IP 属于哪层"从图上一眼可见**；粗箭头是数据包穿透路径。颜色从蓝（真实）渐变到红（纯虚拟），文字为高对比浅色。

**各层网络的定位**：

| 层 | 谁在用 | 谁维护 | 本质 |
|------|------|------|------|
| 物理机网段 | 宿主机操作系统 | 你的基础设施（物理机/虚拟机） | **真实存在的网卡 IP**（如 debian 的 192.168.8.26） |
| 节点容器网段（kind 特有） | kind 节点容器 | Docker 网络（kind 网络） | 容器网卡 IP；**kubeadm/生产集群没有这层**，节点 IP 就是物理机 IP |
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

### 3.5 组件在集群里的位置地图（实测）

上面讲了"每个组件干什么"，这一节回答"每个组件在哪"——使用者脑袋里必须有的那张图。**本文 kind 集群实测分布**：

```mermaid
%% 组件位置地图: 三个节点上各跑着什么 (style 强制深底白字)
flowchart TD
    classDef cp fill:#1e3a8a,stroke:#60a5fa,stroke-width:2px,color:#ffffff,font-weight:bold;
    classDef wk fill:#312e81,stroke:#a78bfa,stroke-width:2px,color:#ffffff,font-weight:bold;

    CP["learn-control-plane (172.18.0.2)<br/>控制面静态 Pod: kube-apiserver / etcd<br/>kube-controller-manager / kube-scheduler<br/>+ coredns ×2 + kindnet + kube-proxy"]
    W1["learn-worker (172.18.0.3)<br/>kindnet + kube-proxy (每节点标配)<br/>业务: nginx-demo×3 demo-app×2<br/>prometheus + grafana<br/>入口: ingress-nginx 控制器 + metallb"]
    W2["learn-worker2 (172.18.0.4)<br/>kindnet + kube-proxy<br/>业务: nginx-demo×3 demo-app×1<br/>网关: Envoy/NGF 控制器 + 数据面"]

    CP --- W1
    CP --- W2

    style CP fill:#0f172a,stroke:#3b82f6,stroke-width:2px,color:#ffffff,font-weight:bold
    style W1 fill:#0f172a,stroke:#8b5cf6,stroke-width:2px,color:#ffffff,font-weight:bold
    style W2 fill:#0f172a,stroke:#8b5cf6,stroke-width:2px,color:#ffffff,font-weight:bold
```

**部署形态决定"它在哪"**：

| 组件 | 部署形态 | 位置（实测） | 数量 |
|------|------|------|:---:|
| kube-apiserver / etcd / controller-manager / scheduler | **静态 Pod**（绑定节点，kubeadm 方式） | 全部在 control-plane 节点 | 各 1 |
| kube-proxy | **DaemonSet**（每节点必有一个） | 3 个节点各 1 个 | 3 |
| kindnet（CNI） | **DaemonSet** | 3 个节点各 1 个 | 3 |
| coredns | Deployment | 都调度到了 control-plane（**它有控制面污点的容忍度**） | 2 |
| ingress-nginx 控制器 | Deployment | learn-worker | 1 |
| Envoy Gateway / NGF 控制器 | Deployment | learn-worker2 | 各 1 |
| 业务 Pod（nginx-demo 等） | Deployment | 分散在两个 worker | 按副本 |

**四个位置认知（记住这张图）**：

1. **控制面 4 件套永远在控制面节点**——kubeadm 方式下是静态 Pod（绑定节点、名字带节点名）；**上 ACK 托管版后这 4 个消失**（平台托管，你看不到也管不到）；
2. **DaemonSet = 每节点标配**：kube-proxy 和 CNI 是"每个节点必须有一个"，新节点加入自动补齐——排障时"某节点网络不通"先看这两样在不在；
3. **业务 Pod 永不上 control-plane**（污点 ` NoSchedule ` ，前面学过）；**coredns 是例外**——系统组件带容忍度，能上控制面（实测两个副本都在 control-plane）；
4. 上云后节点侧组件（kube-proxy/CNI/kubelet）**依然每节点存在**——它们就是"节点标配"，不管自建还是托管。

> ⚠️ **上面的实测布局是 kind 的"省资源版"，不是生产常态**——kind 为了在 7.6G 内存的机器上跑起来，把能挤的组件都挤在单控制面节点（coredns 甚至容忍污点挤上去）。**kubeadm 原生（生产常态）的教科书布局**如下：

```mermaid
%% kubeadm 生产布局: HA 三控制面 + worker 节点标配 (style 强制深底白字)
flowchart TD
    classDef cp fill:#1e3a8a,stroke:#60a5fa,stroke-width:2px,color:#ffffff,font-weight:bold;
    classDef wk fill:#312e81,stroke:#a78bfa,stroke-width:2px,color:#ffffff,font-weight:bold;

    CP1["控制面节点1<br/>静态Pod: kube-apiserver / etcd<br/>controller-manager / scheduler"]
    CP2["控制面节点2<br/>etcd / apiserver / 控制器"]
    CP3["控制面节点3<br/>etcd / apiserver / 控制器"]
    W1["worker 节点1<br/>DaemonSet: kube-proxy + CNI<br/>coredns 副本 + 业务 Pod"]
    W2["worker 节点2<br/>DaemonSet: kube-proxy + CNI<br/>coredns 副本 + 业务 Pod"]

    CP1 <--> CP2
    CP2 <--> CP3
    CP1 <--> W1
    CP1 <--> W2
    CP2 <--> W1
    CP2 <--> W2

    style CP1 fill:#0f172a,stroke:#3b82f6,stroke-width:2px,color:#ffffff,font-weight:bold
    style CP2 fill:#0f172a,stroke:#3b82f6,stroke-width:2px,color:#ffffff,font-weight:bold
    style CP3 fill:#0f172a,stroke:#3b82f6,stroke-width:2px,color:#ffffff,font-weight:bold
    style W1 fill:#0f172a,stroke:#8b5cf6,stroke-width:2px,color:#ffffff,font-weight:bold
    style W2 fill:#0f172a,stroke:#8b5cf6,stroke-width:2px,color:#ffffff,font-weight:bold
```

**为什么这么设计（动机）**——布局不是随意的，是三个原则的落地：

| 设计 | 传统痛点 | 原则回应 |
|------|------|------|
| **控制面 3 节点（HA）** | 控制面是集群大脑，挂了整个集群瘫；etcd 是唯一真相，必须高可用 | etcd 用 **Raft 选举，必须奇数节点（2N+1）**：3 节点容忍挂 1 台（多数派 2/3 仍在）；2 台会脑裂（各说各话），1 台没有高可用 |
| **控制面与 worker 分离** | 业务 Pod 吃光 CPU/内存，控制面组件饿死 → 调度瘫痪、状态失稳 | **污点 `NoSchedule` 隔离**：业务 Pod 默认上不了控制面节点（前面学过） |
| **etcd 独享存储（生产细节）** | 每次资源变更都写 etcd（高频小写），慢盘/IO 争抢拖垮整个集群 | 生产里 etcd 配 **SSD + 独立磁盘**，不和业务抢 IO |
| **kube-proxy/CNI 每节点（DaemonSet）** | 任何节点都可能被调度到业务 Pod，网络能力不能缺 | **DaemonSet：新节点加入自动补齐**，不用人肉装 |
| **coredns 分散在 worker** | DNS 是集群内所有解析的全局依赖，单点 = 全集群解析失败 | **Deployment 多副本分散**；容忍度只是"允许"上控制面，不代表推荐（kind 挤上去纯属省资源） |

**一句话**：布局 = **高可用（奇数 etcd）+ 隔离（控制面/worker 分离）+ 冗余（每节点标配）** 三个原则的落地——每个位置都是回应一个"挂了会怎样"的痛点。

**与 kind 的对照**：

| 组件 | kubeadm 生产布局 | kind（本文实测） | 差异原因 |
|------|------|------|------|
| apiserver / etcd / controller-manager / scheduler | 控制面节点静态 Pod；**HA 时 3 个控制面节点，etcd 每节点一个** | 1 个控制面节点（无 HA） | kind 单机无 HA |
| coredns | Deployment 副本**分散在 worker**（容忍度只是"允许"上控制面，生产调度器不这么放） | 2 副本都挤在 control-plane | **kind 省资源** |
| kube-proxy / CNI | **DaemonSet 每节点** | 每节点（一致） | 形态规则不变 |
| 业务 Pod | worker 节点 | worker 节点（一致） | 规则不变 |
| ingress-nginx / 网关控制器 | Deployment 在 worker | worker（一致） | 规则不变 |

**结论**：**形态规则不变，变的只是资源宽松度**——控制面 4 件套永远在控制面节点、DaemonSet 永远每节点一个、业务永远在 worker，这是 kubeadm 和 kind 共通的"位置宪法"。生产里组件该分散就分散，kind 里能挤就挤。**排障时按形态找组件，别按"它上次在哪个节点"找**（coredns 在 CP 只是 kind 的资源决策，不是它的固定位置）。

### 3.6 Spring Cloud 开发者视角：这些概念你早就见过

如果你是 Spring Cloud 开发者，上面每个组件都能找到"老熟人"——而且对比之后会发现一个贯穿全文的洞察：

| K8s 概念（这篇学的） | Spring Cloud 里的对应 | 核心区别 |
|------|------|------|
| **Service（ClusterIP）+ Endpoints** | Nacos 注册中心 / 服务发现 | Nacos 要代码集成（ ` @EnableDiscoveryClient ` + 心跳续约）；Service 是平台声明（ ` selector ` 自动匹配 Pod、Endpoints 自动维护）——**服务发现从应用代码下沉到平台层** |
| **CoreDNS 服务名解析** | Eureka/Nacos 地址簿 + Feign/Ribbon 拿实例 | 都是"名字 → 地址"，但 DNS 不用引依赖、不用写 ` @FeignClient ` ——服务名直接当 URL 用 |
| **kube-proxy 负载均衡** | Ribbon / Spring Cloud LoadBalancer | Ribbon 是**客户端负载均衡**（写在调用方代码里）；kube-proxy 是**平台透明负载均衡**（iptables DNAT，调用方无感知）——**负载均衡也从代码下沉到平台** |
| **Ingress / Gateway API** | Spring Cloud Gateway | 同是 L7 网关（域名/路径路由），但 Spring Cloud Gateway 是**要自己部署维护的应用**；Ingress 是**声明式资源**（控制器实现，平台管） |
| **Pod IP 会变** | 服务实例 IP 会变（重启换 IP） | 传统微服务靠 Nacos 心跳续约兜住；K8s 由 Service 的 Endpoints 自动兜住——调用方始终无感 |

**一句话主线**：*Spring Cloud 用代码解决的问题（注册、发现、负载均衡），K8s 全部下沉到平台层*——代码里不再需要 Nacos 客户端、不需要 Ribbon 依赖，剩下的只是"声明一个 Service，平台帮你搞定服务发现和负载均衡"。这就是"云原生"对微服务架构最直接的含义。

> 📌 对 Spring Cloud 开发者：回到第 2 节的三层网络——传统微服务的"内网"就是同一个网段直连；K8s 把"内网"拆成了 **Pod 网（实例 IP）+ Service 虚拟网（服务名入口）** 两层，你的服务间调用从"走 Nacos 拿实例 IP"变成"走 DNS 拿 Service 名"——**概念一样，位置从应用层搬到了平台层**。

## 4. 最容易混的概念辨析

### 4.1 四个 IP，四种身份

| IP | 网段（实测） | 是谁 | 存在形式 | 别人怎么用它 |
|------|------|------|------|------|
| **物理机 IP** | 192.168.8.26（debian 宿主机） | 真实世界的服务器 | **真实网卡** | SSH 进服务器；kind 之外的一切访问 |
| 节点 IP | 172.18.0.2/3/4（kind 里是**容器** IP） | kind 节点 = Docker 容器 | 容器网卡（kubeadm 里=物理机 IP） | NodePort 访问（`节点IP:端口`） |
| Pod IP | 10.244.1.x / 10.244.2.x | 每个 Pod 的虚拟网卡 | veth 虚拟网卡 | 集群内互访，但**会变**（Pod 重建就换） |
| ClusterIP | 10.96.x.x | Service 的"虚拟 IP" | **只存在于转发规则**，无网卡 | 集群内访问 `服务名` 时 DNS 解析到它 |

**四个 IP 不能互相替代**： ` curl http://192.168.8.26 ` （物理机）能 SSH 但跟集群无关； ` curl http://172.18.0.3 ` （节点容器）走 Docker 网络； ` curl http://10.244.1.63 ` （Pod IP）在集群内能通，但 Pod 一重建就失效； ` curl http://10.96.x.x ` （ClusterIP）稳定，但只在集群内通。**每一层 IP 只在它自己那层网络里有效**——这就是多层网络容易绕晕的根源。

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

## 5. 四类通信全链路（生产环境视角：从软件到硬件）

> ⚠️ 前面几节把组件和概念摆清楚了，这一节回答最实在的问题：**一个数据包从 Pod A 到 Pod B，到底经过了哪些软件组件、哪些网卡硬件**。注意：这里讲的是**生产环境**（kubeadm 物理机/虚拟机 + flannel/Calico CNI），不是 kind——kind 是容器套容器，验证不了真实物理链路（为什么，见 5.6）。

### 5.1 基础设施热身：四个"看不见的网件"

| 网件 | 生产环境长什么样 | 谁创建的 | 干什么 |
|------|------|------|------|
| **veth pair**（虚拟以太网对） | 一根"虚拟网线"，**一头在 Pod 里（叫 eth0），一头挂在节点上（叫 vethXXX）** | CNI 插件（创建 Pod 时） | 把 Pod 的网络命名空间"接"进节点的网络栈 |
| **网桥**（cni0 / flannel 用 cni0） | 节点内核里的**虚拟交换机** | CNI 插件 | 同节点 Pod 的二层互通（像交换机转发 MAC 帧） |
| **路由表**（ip route） | 节点上的"往哪走"决策表 | kubeadm/CNI 写入 | Pod 子网（10.244.x.0/24）→ 本地网桥 or 对端节点 |
| **iptables / ipvs** | kube-proxy 维护的 NAT 规则链 | kube-proxy | ClusterIP 的 DNAT 地址转换 + 负载均衡 |

**记忆锚点**：veth 是"线"，网桥是"交换机"，路由表是"路口指示牌"，iptables 是"改地址的关卡"——四类通信的物理路径就是这几样东西的组合。

### 5.2 通信一：同 Pod 的 container ↔ container（最常被误解）

**Pod 内的所有容器共享一个网络命名空间**（由 pause 容器持有）——它们**没有各自的 veth，也没有网桥**，就像同一台机器上的两个进程：

```mermaid
%% 通信一: 同 Pod 容器互访 = 共享 netns, 走 lo 回环 (style 白字)
flowchart LR
    C1["容器1 (app)<br/>进程监听 :8080"]
    C2["容器2 (sidecar)<br/>进程访问 localhost:8080"]

    C2 -->|"localhost:8080<br/>走 lo 回环, 不碰网卡"| C1

    style C1 fill:#0f172a,stroke:#3b82f6,stroke-width:2.5px,color:#ffffff,font-weight:bold
    style C2 fill:#0f172a,stroke:#3b82f6,stroke-width:2.5px,color:#ffffff,font-weight:bold
```

**链路**：进程 → `localhost:8080` → **lo 回环接口**（内核直接回环，**不经过任何物理/虚拟网卡、不碰 veth、不碰 iptables**）→ 同 Pod 另一容器的进程。**这是四类通信里唯一不碰"网络硬件"的一类**——本质是"同 netns 的进程间通信"。

### 5.3 通信二：同节点 pod ↔ pod（不经 Service）

```mermaid
%% 通信二: 同节点 Pod 互访 = veth → 网桥二层直通, 不出节点 (style 白字)
flowchart LR
    subgraph PODA["Pod A (netns)"]
        EA["eth0 (veth 一头)<br/>10.244.2.44"]
    end
    subgraph PODB["Pod B (netns)"]
        EB["eth0 (veth 一头)<br/>10.244.2.60"]
    end
    BR["节点上的网桥 cni0<br/>(虚拟交换机, 查 MAC 转发表)"]
    VA["vethXXX (veth 另一头)"]
    VB["vethYYY (veth 另一头)"]

    EA --- VA
    VA --- BR
    BR --- VB
    VB --- EB

    style PODA fill:#0f172a,stroke:#3b82f6,stroke-width:2px,color:#ffffff,font-weight:bold
    style PODB fill:#0f172a,stroke:#3b82f6,stroke-width:2px,color:#ffffff,font-weight:bold
    style BR fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#ffffff,font-weight:bold
    style EA fill:#052e16,stroke:#16a34a,stroke-width:2px,color:#ffffff,font-weight:bold
    style EB fill:#052e16,stroke:#16a34a,stroke-width:2px,color:#ffffff,font-weight:bold
    style VA fill:#052e16,stroke:#16a34a,stroke-width:2px,color:#ffffff,font-weight:bold
    style VB fill:#052e16,stroke:#16a34a,stroke-width:2px,color:#ffffff,font-weight:bold
```

**链路（软件 → 硬件）**：Pod A 进程 → Pod A 的 eth0（veth 一头）→ **veth pair 这根虚拟网线**（数据包穿过 veth，出现在节点侧的 vethXXX）→ **网桥 cni0**（虚拟交换机，按 MAC 地址查转发表，把帧从对应端口转发出去）→ vethYYY → Pod B 的 eth0 → 进程。

**要点**：
- **全程二层**（同网段 10.244.x.0/24，靠 MAC 转发），**不出节点、不碰路由表、不碰 iptables**——所以不经 Service 的同节点互访是最短路径；
- 软件组件：只有 **CNI**（创建 veth pair 和网桥）；硬件路径：veth 虚拟网线 + 内核网桥（虚拟交换机）——**全在宿主机内核里完成**。

### 5.4 通信三：跨节点 pod ↔ pod（pod ↔ Service 一般发生在这里）

用户主场景：**Service1 的 Pod 访问 Service2 的 Pod**，两者一般在不同节点。逻辑链路（前面 5.2 的简版旅程）之外，这里给**硬件视图**：

```mermaid
%% 通信三: 跨节点 = veth → 网桥 → 路由 → VXLAN 封装 → 物理网卡 → 交换机 (style 白字)
flowchart LR
    subgraph N1["节点1 (物理机/VM)"]
        PA["Pod A<br/>eth0 10.244.2.44"]
        B1["网桥 cni0"]
        RT["路由表<br/>10.244.1.0/24 via 节点2"]
        FL["flannel.1<br/>VXLAN 隧道封装"]
        ETH1["eth0 物理网卡<br/>172.18.x.x"]
    end
    SW["物理交换机/路由器"]
    subgraph N2["节点2 (物理机/VM)"]
        ETH2["eth0 物理网卡"]
        FL2["flannel.1 解封装"]
        B2["网桥 cni0"]
        PB["Pod B<br/>eth0 10.244.1.60"]
    end

    PA --> B1 --> RT --> FL --> ETH1
    ETH1 --> SW
    SW --> ETH2 --> FL2 --> B2 --> PB

    style N1 fill:#0f172a,stroke:#3b82f6,stroke-width:2px,color:#ffffff,font-weight:bold
    style N2 fill:#0f172a,stroke:#8b5cf6,stroke-width:2px,color:#ffffff,font-weight:bold
    style SW fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#ffffff,font-weight:bold
    style PA fill:#052e16,stroke:#16a34a,stroke-width:2px,color:#ffffff,font-weight:bold
    style PB fill:#052e16,stroke:#16a34a,stroke-width:2px,color:#ffffff,font-weight:bold
    style B1 fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#ffffff,font-weight:bold
    style B2 fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#ffffff,font-weight:bold
    style RT fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#ffffff,font-weight:bold
    style FL fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#ffffff,font-weight:bold
    style FL2 fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#ffffff,font-weight:bold
    style ETH1 fill:#7f1d1d,stroke:#f87171,stroke-width:2px,color:#ffffff,font-weight:bold
    style ETH2 fill:#7f1d1d,stroke:#f87171,stroke-width:2px,color:#ffffff,font-weight:bold
```

**完整链路（经 Service，软件 + 硬件全标注）**：

| 步 | 谁 | 干什么 | 类型 |
|----|------|------|------|
| ① | **CoreDNS**（L7） | 解析 `service2` → ClusterIP 10.96.x.x | 软件（应用层） |
| ② | **kube-proxy**（iptables DNAT，L4） | 把 ClusterIP:80 改写为选中的后端 Pod IP:80 | 软件（内核 NAT 规则） |
| ③ | **Pod A eth0 → veth → cni0** | 出 Pod、进节点 | 虚拟网线 + 网桥 |
| ④ | **路由表**（L3） | 目标 10.244.1.0/24 → 下一跳节点 2 的 IP | 软件（内核路由） |
| ⑤ | **flannel.1**（VXLAN，L3 隧道） | 把原始包**封装**进 UDP（外层 IP = 节点1→节点2） | 软件（overlay） |
| ⑥ | **eth0 物理网卡** | 真实比特流出机器 | **硬件** |
| ⑦ | **交换机/路由器** | 按外层 IP 转发到节点 2 | **硬件** |
| ⑧ | 节点 2 逆序：eth0 → 解封装 → cni0 → veth → Pod B eth0 | 还原原始包送达 | 软硬件 |

**两种 CNI 的实现差异**：**flannel（VXLAN）** 走 ⑤⑥⑦ 的"封装过隧道"（overlay，对底层网络无要求）；**Calico（BGP）** 不封装——它把 Pod 网段通过 BGP 路由宣告给网络，数据包**直接以 Pod IP 路由**（像真实内网 IP 一样走），性能更好但对网络设备有要求。**这就是"CNI 是 L3 组件"的完整含义**：它决定 Pod IP 怎么路由、要不要封装。

### 5.5 通信四：互联网 ↔ 集群

```mermaid
%% 通信四: 互联网入口 = LB/Ingress → NodePort → Service → Pod (style 白字)
flowchart LR
    U["互联网<br/>浏览器/外部系统"]
    LB["云 SLB (L4)<br/>或 Ingress 控制器 (L7)"]
    NP["节点 NodePort<br/>iptables 入口"]
    SV["Service ClusterIP<br/>kube-proxy DNAT"]
    P["Pod"]

    U -->|"域名 DNS → 公网 IP"| LB
    LB -->|"转发到节点端口"| NP
    NP -->|"DNAT 到 ClusterIP"| SV
    SV -->|"选中后端 Pod"| P

    style U fill:#0f172a,stroke:#3b82f6,stroke-width:2.5px,color:#ffffff,font-weight:bold
    style LB fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#ffffff,font-weight:bold
    style NP fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#ffffff,font-weight:bold
    style SV fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#ffffff,font-weight:bold
    style P fill:#052e16,stroke:#16a34a,stroke-width:2px,color:#ffffff,font-weight:bold
```

**链路**：互联网 → 域名 DNS（真实 DNS，解析到云 SLB 的公网 IP）→ **云 SLB**（四层负载均衡器，物理设备或云软件——流量先进这里）→ 节点 **NodePort**（iptables 入口规则）→ **Service ClusterIP** → kube-proxy DNAT → Pod。**Ingress 场景**：SLB → Ingress 控制器 Pod（L7 按域名路由，它自己也是 Pod）→ Service → Pod。

**与前三类的差别**：这是唯一**跨出集群**的通信——真实 DNS、公网 IP、负载均衡器、机房网络全参与；进集群后反而走最熟悉的链路（NodePort/Service/kube-proxy 都是前面学过的）。

### 5.6 为什么 kind 验证不了这些（诚实说明）

kind 是"容器套容器"：节点本身就是 Docker 容器，所以——

| 生产环境的真东西 | kind 里的样子 | 结论 |
|------|------|------|
| eth0 物理网卡 | eth0 是 veth 的一头（虚拟的） | 验证不了真实网卡路径 |
| 跨节点走物理交换机 + VXLAN/BGP | 节点容器在同一 Docker 二层，**kindnet 直接写路由，无 VXLAN 封装** | 验证不了 overlay 隧道 |
| cni0 网桥在宿主机内核 | 网桥在容器网络栈里 | 位置都不同 |
| 真实路由/交换设备 | 没有 | 验证不了 |

**kind 的价值是验证"组件存在和行为"**（veth/bridge/iptables 规则都有，kube-proxy 的 DNAT 真实生效）；**生产/云上才能验证"真实物理路径"**（网卡、隧道、交换机）。所以这篇的物理链路以生产为准——kind 里学的概念（veth、网桥、iptables）一个不浪费，只是"真实路径"要上生产/ACK 才能亲眼看到。

## 6. 总表：一层、一组件、一职责

| 层 | 组件 | 一句话职责 | 常见误解 |
|------|------|------|------|
| L1/L2 | 网卡/veth/Docker bridge | 比特与帧的搬运 | — |
| L3 | CNI（kindnet/Calico/Terway） | 分配 Pod IP + 跨节点路由 | 以为 Pod IP 是节点 IP |
| L4 | kube-proxy + Service | ClusterIP 的 DNAT 转发 + 负载均衡 | 以为是防火墙或七层代理 |
| L7 | CoreDNS | 服务名 → ClusterIP | 以为 DNS 管转发 |
| L7 | Ingress / Gateway API | 域名/路径 → Service | 以为它做四层转发 |

**三个记忆锚点**：

1. **多层网络**：物理机（真实网卡）→ 节点（kind 里是容器 IP，kubeadm 里=物理机 IP）→ Pod 网（CNI 的虚拟网）→ Service 网（纯虚拟，只存在于规则里）；
2. **组件分层不越界**：CNI 管 L3、kube-proxy 管 L4、DNS/Ingress 管 L7——谁出问题就找对应层的组件；
3. **传统知识完全适用**：K8s 没有发明新协议，它只是把"路由、NAT、DNS、反向代理"这些传统网络组件**搬进了集群内部，并换成了 K8s 的名字**——用 OSI 当坐标系，每个组件立刻找到自己的位置。
