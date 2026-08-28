---
title: "Gateway API 实战：ingress-nginx 归档后的新标准（kind + Envoy Gateway 全打通）"
date: 2024-05-20T11:30:03+00:00
tags: ["容器技术", "实践教程", "Kubernetes"]
categories: ["教程"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "ingress-nginx 已于 2026 年 3 月归档停更，K8s 流量入口的新标准是 Gateway API。本文在 kind 上用 Envoy Gateway 完整打通 GatewayClass/Gateway/HTTPRoute 三级资源模型，含全部命令、真实踩坑（NGF 配置 bug、镜像预载、GatewayClass 缺失）与 Ingress 迁移对照。"
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

# Ingress 归档了，流量入口的新标准长什么样

先说一个 2026 年的重要事实（本文写作时实测验证）：**kubernetes/ingress-nginx 仓库已于 2026 年 3 月归档**——GitHub API 返回 ` archived: true ` ，最后 release 是 v1.15.1（2026-03-19）。标准 Ingress Controller 停止更新了，但存量集群里的 Ingress 资源不会消失（照常工作），只是**新项目的流量入口应该选新标准：Gateway API**（本文写作时最新 v1.6.1，2026-07 发布，活跃迭代中）。

系列前一篇《Service 与 Ingress 实战》学的 Ingress 并没有白学——Gateway API 的设计目标之一就是**吸收 Ingress 的经验、补上它的短板**，两者资源模型一一对应。这篇在 kind 上用 Envoy Gateway 把 Gateway API 全链路打通：原理（三级资源模型）→ 实践（全部命令）→ 真实踩坑 → 迁移对照。

## 1. 动机先行：为什么要有 Gateway API

| Ingress 的痛点 | Gateway API 的回应 |
|------|------|
| 一个 IngressClass / Ingress 资源，表达力有限（只能按域名+路径路由） | 拆分三级资源：**GatewayClass → Gateway → HTTPRoute**，每级各司其职、可独立复用 |
| 路由规则与暴露方式混在一个资源里 | 暴露（Gateway）与路由（HTTPRoute）**解耦**：同一个 Gateway 可以被多个 HTTPRoute 挂载 |
| 协议扩展靠注解（ ` nginx.ingress.kubernetes.io/xxx ` ），非标准 | 资源模型原生支持 HTTP/TLS/TCP/UDP，扩展用标准 CRD |
| 不同实现行为不一致（nginx/traefik/...） | 规范定义了资源的状态语义（Accepted/Programmed），实现行为更一致 |

**一句话**：Ingress 是"路由规则 + 入口绑在一起"的早期设计，Gateway API 把它拆成"谁提供服务（GatewayClass）→ 入口长什么样（Gateway）→ 流量怎么路由（HTTPRoute）"三层——分层带来复用和表达力。

## 2. 原理：三级资源模型

```mermaid
%% Gateway API 三级资源模型: 类 → 网关 → 路由 → 后端服务
flowchart TD
    classDef root fill:#0f172a,stroke:#3b82f6,stroke-width:2.5px,color:#bfdbfe,font-weight:bold;
    classDef process fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#e5e7eb;
    classDef data fill:#052e16,stroke:#16a34a,stroke-width:2px,color:#bbf7d0,font-weight:bold;

    GC["GatewayClass\n(类: 声明用哪个实现, 如 envoy-gateway)"]
    G["Gateway\n(入口: 监听端口/协议, 拿到 LB IP)"]
    R1["HTTPRoute\n(路由: 域名+路径 → 后端)"]
    R2["HTTPRoute\n(路由: 其他域名/路径)"]
    S1["后端 Service\n(nginx-svc)"]
    S2["后端 Service\n(其他服务)"]

    GC --> G
    G --> R1
    G --> R2
    R1 --> S1
    R2 --> S2

    class GC,G root;
    class R1,R2 process;
    class S1,S2 data;
```

| 资源 | 一句话职责 | 类比 Ingress 时代 |
|------|------|------|
| **GatewayClass** | 声明"用哪个实现"（envoy-gateway / nginx 等） | 类似 IngressClass，但表达力更强 |
| **Gateway** | 声明"入口长什么样"：监听端口、协议、拿到对外 IP | 类似 Ingress 里的暴露部分（独立出来了） |
| **HTTPRoute** | 声明"流量怎么路由"：域名 + 路径 → 后端 Service | 类似 Ingress 里的路由规则（独立出来了） |

**与 Ingress 的对应关系**（迁移时照着搬就行）：

| Ingress 时代 | Gateway API |
|------|------|
| `IngressClass` | `GatewayClass` |
| ` Ingress ` （暴露 + 路由合体） | ` Gateway ` （暴露）+ ` HTTPRoute ` （路由） |
| `spec.rules[].host` | `HTTPRoute.spec.hostnames` |
| `spec.rules[].http.paths[].path` | `HTTPRoute.spec.rules[].matches[].path` |
| `spec.rules[].http.paths[].backend.service` | `HTTPRoute.spec.rules[].backendRefs` |

## 3. 实践：kind + Envoy Gateway 全打通

环境：kind 一主二从集群（learn）+ metallb（IP 池 ` 172.18.255.1-250 ` ）+ 已有 Service ` nginx-svc ` （3 副本 nginx:1.25，selector ` app=nginx-demo ` ）。

### 3.1 安装 Gateway API CRD

```bash
curl -sL -o /tmp/gateway-crd.yaml \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/standard-install.yaml"
kubectl apply -f /tmp/gateway-crd.yaml

# 确认装上了(标准 CRD + 可能带实验性 CRD)
kubectl get crd | grep gateway.networking.k8s.io | wc -l
```

### 3.2 部署 Envoy Gateway（CNCF 实现，本文选用）

```bash
curl -sL -o /tmp/eg-install.yaml \
  "https://github.com/envoyproxy/gateway/releases/download/v1.9.0/install.yaml"
# 控制器镜像要预载进 kind 节点 —— 原因: kind 节点容器内的 containerd 直连公网 registry
# (ghcr.io/docker.io) 会超时, 必须"宿主机代理拉取 → kind load 搬运进每个节点"(全系列老规矩):
docker pull envoyproxy/gateway:v1.9.0
kind load docker-image envoyproxy/gateway:v1.9.0 --name learn
kubectl apply -f /tmp/eg-install.yaml        # 34 个资源: CRD + 控制器 + RBAC
kubectl get pods -n envoy-gateway-system     # envoy-gateway-xxx 1/1 Running
```

### 3.3 创建 GatewayClass（install.yaml 不创建，需手动）

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy-gateway
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
```

```bash
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: envoy-gateway
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
EOF
kubectl get gatewayclass envoy-gateway
# NAME            CONTROLLER                                      ACCEPTED
# envoy-gateway   gateway.envoyproxy.io/gatewayclass-controller   True
```

### 3.4 创建 Gateway（入口，metallb 分配 IP）

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: eg-gw
  namespace: default
spec:
  gatewayClassName: envoy-gateway
  listeners:
  - name: http
    port: 80
    protocol: HTTP
```

```bash
kubectl apply -f eg-gw.yaml
kubectl get gateway eg-gw
# NAME    CLASS           ADDRESS        PROGRAMMED
# eg-gw   envoy-gateway   172.18.255.4   True
```

**注意**：Gateway 的 ` PROGRAMMED=True ` 意味着控制器已经为它创建了数据面（envoy 代理 pod）。**数据面 pod 在 ` envoy-gateway-system ` 命名空间，不在 default——找 pod 别找错地方**。数据面镜像同样要预载，否则 pod 会卡在 ImagePullBackOff（kubelet 直连 docker.io 拉取超时，事件里能看到 ` dial tcp ... i/o timeout ` ）：

```bash
docker pull envoyproxy/envoy:distroless-v1.39.0
kind load docker-image envoyproxy/envoy:distroless-v1.39.0 --name learn
# 数据面 pod 自动恢复(镜像到位后 kubelet 重试成功)
kubectl get pods -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=eg-gw
# envoy-default-eg-gw-63522087-xxx   2/2 Running
```

### 3.5 创建 HTTPRoute（路由规则）并验证

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: nginx-demo-route
  namespace: default
spec:
  parentRefs:
  - name: eg-gw
  hostnames:
  - nginx.local
  rules:
  - backendRefs:
    - name: nginx-svc
      port: 80
```

```bash
kubectl apply -f route.yaml
curl -H "Host: nginx.local" http://172.18.255.4      # HTTP 200, Welcome to nginx!
curl http://172.18.255.4                              # 无匹配 Host → HTTP 404
```

**实测结果**： ` Host: nginx.local ` → **200**（ ` <title>Welcome to nginx!</title> ` ）；不带 Host → **404**——路由匹配精确生效，和 Ingress 的体验一致，但资源是拆开的、可复用的。

### 3.6 弯路全记录：NGF v2.6.7 完整尝试（为什么放弃）

先试的是 NGINX Gateway Fabric（ingress-nginx 归档后最自然的"继任者"），v2.6.7 是当时的 latest。**完整踩坑过程如下，每一步都是实测**。

**架构发现（v2 与 v1 不同）**：NGF v2 是**控制面/数据面分离**——主 Deployment（ ` nginx-gateway ` ）只是控制面（leader 选举 + 配置生成 + agent 通道），它自动 provision 一个**数据面 Deployment**（名字 = ` <Gateway 名>-nginx ` ，如 ` gw-nginx ` ），真正跑 nginx 的是数据面。而且**两个是不同镜像**：

```text
控制面: ghcr.io/nginx/nginx-gateway-fabric:2.6.7
数据面: ghcr.io/nginx/nginx-gateway-fabric/nginx:2.6.7   ← 别漏了 /nginx
```

**坑 A：数据面镜像漏 load**。只 load 了控制面镜像，数据面 pod 卡 Pulling（kubelet 直连 ghcr.io 超时）。排查： ` kubectl describe pod ` 看事件（ ` Pulling image ... i/o timeout ` ）→ 补 load 数据面镜像。

**坑 B：控制面 Service 的 targetPort 被弄乱**。给控制面 Service 加 HTTP 端口时误把 443 的 targetPort 从 8443 改成 80 → 数据面 nginx 连控制面 agent 通道（ ` 10.96.1.15:443 ` ）持续报 ` connection refused ` 。排查链路：数据面容器日志暴露连接目标 → 检查 Service/endpoints 发现 targetPort 错 → 修回 8443（数据面 pod 就绪）。

**坑 C（放弃原因）：server_tokens 配置解析失败**。镜像补齐、agent 通道修好后，数据面日志：

```text
Config apply failed, rollback successful
error="failed to parse config invalid number of arguments in
\"server_tokens\" directive in /etc/nginx/conf.d/http.conf:46"
```

NGF v2.6.7 生成的配置，它**自己配套的 nginx 1.31.3**（v2.6.7 release notes 明示 ` Update NGINX OSS to 1.31.3 ` ）解析不了 → 配置回滚 → nginx 没起来 → readiness 失败 → 流量不通。这是**发布级 bug**（官方配套版本自相矛盾），不是操作问题。GitHub issue 搜索无现成 workaround（搜到的都是 server_tokens 功能请求，不是这个解析 bug）。

**排查方法论**（这条弯路沉淀的可复用技能）：

| 步骤 | 命令/动作 | 得到什么 |
|------|------|------|
| 1 | `kubectl describe pod` | 事件：Pulling / ImagePullBackOff / 探针失败 |
| 2 | `kubectl logs` 数据面容器 | 根因：agent 连接错误 → 配置解析错误 |
| 3 | ` nginx -T ` （容器内） | 回滚后显示 ` syntax is ok ` ——证明坏配置没生效 |
| 4 | GitHub issue 搜索 | 确认是发布级 bug 而非已知可绕问题 |

**结论**：标准 API 之下实现可换——换 Envoy Gateway（本文主线），零配置改动。v2.6.7 的问题后续用降级 v2.5.1 验证为版本级 bug（见第 4 节续集）。

## 4. 真实踩坑记录（复现必看）

| # | 坑 | 症状 | 解法 |
|---|------|------|------|
| 1 | **ingress-nginx 已归档** | GitHub API ` archived: true ` （2026-03） | 新项目用 Gateway API；存量照常跑 |
| 2 | **NGF v2.6.7 配置生成 bug** | ` failed to parse config ... "server_tokens" directive ` ——官方配套 nginx 1.31.3 解析不了自己生成的配置（v2.6.7 release notes 明示配套 nginx 1.31.3） | 换 Envoy Gateway（或降级 NGF 旧版） |
| 3 | 控制器镜像节点内拉不动 | ` dial tcp ... i/o timeout ` / ImagePullBackOff | 宿主机 ` docker pull ` （走代理）+ ` kind load docker-image ` |
| 4 | **数据面是独立镜像**（NGF v2 和 Envoy 都是） | 主镜像 load 了，数据面 pod 还是 ImagePullBackOff | 看数据面 pod 事件里要什么镜像，单独 load（Envoy 数据面是 ` envoyproxy/envoy:distroless-v1.39.0 ` ） |
| 5 | Envoy install.yaml 不创建 GatewayClass | 控制器日志 ` failed to get GatewayClass "envoy-gateway" not found ` 、Gateway 卡 PROGRAMMED=False | 手动创建 GatewayClass |
| 6 | kind load 大镜像慢（低配机器） | 命令 300s 超时被 kill | 后台跑（ ` background=true ` ）；再 load 同镜像会提示 ` already present on all nodes ` |

**坑 2 的细节见 3.6 节**（NGF 架构发现、数据面镜像、targetPort、server_tokens 的完整排查链）。要点：v2.6.7 生成的 `server_tokens` 配置连它自己配套的 nginx 1.31.3 都解析失败（发布级 bug），遂换 Envoy Gateway——**"Gateway API 是标准，实现可换"正是它的设计价值**。

**坑 2 的续集：降级 v2.5.1 后 bug 消失（实测验证）**。写博客时有个怀疑：v2.6.7 是 2026-07 刚发布的新版本（两个月内连打 7 个补丁 v2.6.0→v2.6.7），bug 可能出在"太新"——于是实测降级到更成熟的 **v2.5.1**（2026-04-08 发布），验证"稳定版是否绕开"。

过程（全部实测）：

```bash
# 1. 清理 v2.6.7 残留
kubectl delete gatewayclass nginx
kubectl delete gateway gw -n default
kubectl delete deploy gw-nginx svc gw-nginx -n default 2>/dev/null
kubectl delete ns nginx-gateway

# 2. 拉 v2.5.1 双镜像并预载(控制面 + 数据面)
docker pull ghcr.io/nginx/nginx-gateway-fabric:2.5.1
docker pull ghcr.io/nginx/nginx-gateway-fabric/nginx:2.5.1
kind load docker-image ghcr.io/nginx/nginx-gateway-fabric:2.5.1 \
  ghcr.io/nginx/nginx-gateway-fabric/nginx:2.5.1 --name learn

# 3. 部署(清单从 v2.5.1 tag 下载, 含 GatewayClass nginx)
kubectl apply -f deploy.yaml

# 4. 创建 Gateway + HTTPRoute(域名 ngf.local)
kubectl apply -f ngf-gw.yaml
```

结果：

| 验证项 | 实测输出 |
|------|------|
| 控制器 | `nginx-gateway-69c9678649-kv7ms 1/1 Running` |
| GatewayClass | `nginx ... ACCEPTED=True` |
| Gateway | ` ngf-gw ... 172.18.255.2 PROGRAMMED=True ` （metallb 分配） |
| 数据面日志 | **Config apply successful**（v2.6.7 这里是 ` Config apply failed ` ）——**bug 消失** |
| 路由 | `curl -H "Host: ngf.local" http://172.18.255.2` → **HTTP 200**；无匹配 Host → **404** |

**意外收获——双实现共存**：Envoy Gateway 没有清理，两个实现同时在线：

```text
kubectl get gatewayclass
# envoy-gateway   gateway.envoyproxy.io/gatewayclass-controller   True
# nginx          gateway.nginx.org/nginx-gateway-controller      True

kubectl get gateway
# eg-gw    envoy-gateway   172.18.255.4   True
# ngf-gw   nginx           172.18.255.2   True
```

` eg-gw ` （Envoy）和 ` ngf-gw ` （NGF）并行工作互不影响——**"标准 API + 多实现共存"从概念变成了眼前的现实**。

**结论**：v2.6.7 的 server_tokens 是**版本级 bug**（官方配套版本自相矛盾），降级稳定版 v2.5.1 即绕开——"用稳定版"的直觉在这里是对的。这也给选型一个实用原则：**Gateway API 实现版本迭代快，踩到发布级 bug 时，优先试降级稳定版，而不是换实现**（换实现往往要重新过一遍镜像/清单的坑）。

## 5. Ingress → Gateway API 迁移思路

```mermaid
%% Ingress 到 Gateway API 的迁移映射
flowchart LR
    classDef root fill:#0f172a,stroke:#3b82f6,stroke-width:2.5px,color:#bfdbfe,font-weight:bold;
    classDef process fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#e5e7eb;

    subgraph OLD["Ingress 时代"]
        I1["IngressClass"]
        I2["Ingress(域名+路径+后端 合体)"]
    end
    subgraph NEW["Gateway API"]
        G1["GatewayClass"]
        G2["Gateway(暴露)"]
        G3["HTTPRoute(路由)"]
    end

    I1 --> G1
    I2 --> G2
    I2 --> G3

    class OLD process;
    class NEW root;
```

1. **存量不动**：正在跑的 Ingress 照常工作（控制器不更新但能跑）；
2. **新流量走新标准**：新域名/新服务用 Gateway API（Gateway + HTTPRoute）；
3. **逐条迁移**：按第 2 节的对应表把 Ingress 规则翻译成 HTTPRoute，验证后删 Ingress 资源；
4. **实现选择**：标准 API 之下实现可换——Envoy Gateway（CNCF，本文用）、NGINX Gateway Fabric（但注意 2.6.7 的配置 bug）、Traefik 等，都遵循同一套资源模型。

## 6. 总结

三个记忆点：

1. **Ingress 没有消失，但停止演进**——存量照跑，新项目选 Gateway API（2026 年的事实）；
2. **Gateway API 的核心是分层**：GatewayClass（用哪个实现）→ Gateway（入口长什么样）→ HTTPRoute（流量怎么路由），暴露与路由解耦是它相对 Ingress 的最大改进；
3. **标准 API + 可换实现**：这次实践里 NGF 出 bug 直接换 Envoy Gateway，资源模型一行不用改——这就是"标准"的价值。

（本篇无图片/视频占位。）
