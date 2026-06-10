---
title: "SkyWalking 中间件集成与链路分析实战"
date: 2022-12-20T08:00:00+00:00
tags: ["可观测性", "实践教程", "SpringCloud"]
categories: ["日志分析工具"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "SkyWalking 生产实战：Gateway/Dubbo/OpenFeign/gRPC/Sentinel 所有中间件的链路追踪配置、自定义业务 Span 和 @Trace 注解、异步任务和 MQ 追踪、日志通过 TraceId 关联——ELK + SkyWalking 联合排错、gRPC 手动埋点、性能剖析（慢端点识别 + 调用树分析）、性能开销实测、集群部署、生产检查清单。"
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
    relative: false
    hidden: true
---

# SkyWalking 中间件集成与链路分析实战

> 📖 <strong>前置阅读</strong>：本文假设读者已搭建 SkyWalking 并了解 Trace/Span/Segment 概念。如果还不熟悉，建议先阅读 [<strong>SkyWalking 分布式链路追踪——从零搭建 APM 平台</strong>]({{< relref "SkyWalkingFundamentals.md" >}})。

## 一、⚡ 全链路通了——但只有 HTTP 调用——Dubbo 和 gRPC 看不到

上一篇搭好了 SkyWalking——`/api/orders` 的调用链能看到了——HTTP → Feign → MySQL 都有。

但我们的系统不止 HTTP：

```
真实调用链路：
  Browser → Gateway → order-service
    ├─ Feign → user-service (HTTP)       ✅ SkyWalking 自动追踪
    ├─ Dubbo → account-service (RPC)     ❌ 看不到——Dubbo Span 没出来
    ├─ gRPC → inventory-service (RPC)    ❌ 看不到——gRPC Span 没出来
    ├─ Sentinel → 限流熔断               ❌ 看不到——被限流的请求没有标记
    ├─ RocketMQ → payment-service (异步)  ❌ 看不到——MQ 跨进程 Trace 断了
    └─ @Async → sendEmail (异步)          ❌ 看不到——异步线程 Trace 丢了
```

<strong>Agent 不是万能的——不同中间件需要不同配置——有些还需要手动埋点。</strong>

## 二、🏗️ 搭建教程——SkyWalking + 所有微服务一键部署

上一篇搭建了 OAP + UI + ES 三个容器——但那只是 SkyWalking 本身。这篇要把 SkyWalking 和所有微服务编排在一起——每个服务挂载 Agent——全链路追踪自动生效。

### 2.1 完整的 Docker Compose——SkyWalking + Nacos + 微服务

```yaml
version: '3.8'
services:

  # ===== SkyWalking 基础设施 =====
  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:7.17.9
    container_name: es
    environment:
      - discovery.type=single-node
      - "ES_JAVA_OPTS=-Xms512m -Xmx512m"
      - xpack.security.enabled=false
    ports:
      - "9200:9200"
    volumes:
      - es-data:/usr/share/elasticsearch/data

  oap:
    image: apache/skywalking-oap-server:9.5.0
    container_name: oap
    depends_on:
      - elasticsearch
    environment:
      SW_STORAGE: elasticsearch
      SW_STORAGE_ES_CLUSTER_NODES: elasticsearch:9200
      SW_TELEMETRY: prometheus
    ports:
      - "11800:11800"  # Agent gRPC 上报端口
      - "12800:12800"  # UI 查询端口
      - "1234:1234"    # OAP 自身 Prometheus 指标

  ui:
    image: apache/skywalking-ui:9.5.0
    container_name: skywalking-ui
    depends_on:
      - oap
    environment:
      SW_OAP_ADDRESS: http://oap:12800
    ports:
      - "8080:8080"

  # ===== 注册中心 =====
  nacos:
    image: nacos/nacos-server:v2.2.3
    container_name: nacos
    environment:
      - MODE=standalone
    ports:
      - "8848:8848"
      - "9848:9848"

  # ===== Gateway——挂载 Agent =====
  gateway:
    build: ./gateway
    container_name: gateway
    ports:
      - "8088:8088"
    environment:
      - SPRING_CLOUD_NACOS_DISCOVERY_SERVER-ADDR=nacos:8848
      - JAVA_TOOL_OPTIONS=-javaagent:/agent/skywalking-agent.jar
      - SW_AGENT_NAME=gateway-service
      - SW_AGENT_COLLECTOR_BACKEND_SERVICES=oap:11800
    volumes:
      - ./skywalking-agent:/agent:ro      # 挂载 Agent 目录——只读
    depends_on:
      - nacos
      - oap

  # ===== order-service（Feign + Dubbo 双协议）=====
  order-service:
    build: ./order-service
    container_name: order-service
    ports:
      - "8081:8081"
    environment:
      - SPRING_CLOUD_NACOS_DISCOVERY_SERVER-ADDR=nacos:8848
      - JAVA_TOOL_OPTIONS=-javaagent:/agent/skywalking-agent.jar
      - SW_AGENT_NAME=order-service
      - SW_AGENT_COLLECTOR_BACKEND_SERVICES=oap:11800
    volumes:
      - ./skywalking-agent:/agent:ro
    depends_on:
      - nacos
      - oap

  # ===== user-service（Feign）=====
  user-service:
    build: ./user-service
    container_name: user-service
    ports:
      - "8082:8082"
    environment:
      - SPRING_CLOUD_NACOS_DISCOVERY_SERVER-ADDR=nacos:8848
      - JAVA_TOOL_OPTIONS=-javaagent:/agent/skywalking-agent.jar
      - SW_AGENT_NAME=user-service
      - SW_AGENT_COLLECTOR_BACKEND_SERVICES=oap:11800
    volumes:
      - ./skywalking-agent:/agent:ro
    depends_on:
      - nacos
      - oap

  # ===== product-service（gRPC）=====
  product-service:
    build: ./product-service
    container_name: product-service
    ports:
      - "8083:8083"
      - "9090:9090"  # gRPC 端口
    environment:
      - SPRING_CLOUD_NACOS_DISCOVERY_SERVER-ADDR=nacos:8848
      - JAVA_TOOL_OPTIONS=-javaagent:/agent/skywalking-agent.jar
      - SW_AGENT_NAME=product-service
      - SW_AGENT_COLLECTOR_BACKEND_SERVICES=oap:11800
    volumes:
      - ./skywalking-agent:/agent:ro
    depends_on:
      - nacos
      - oap

  # ===== account-service（Dubbo）=====
  account-service:
    build: ./account-service
    container_name: account-service
    ports:
      - "20880:20880"
    environment:
      - DUBBO_REGISTRY_ADDRESS=nacos://nacos:8848
      - JAVA_TOOL_OPTIONS=-javaagent:/agent/skywalking-agent.jar
      - SW_AGENT_NAME=account-service
      - SW_AGENT_COLLECTOR_BACKEND_SERVICES=oap:11800
    volumes:
      - ./skywalking-agent:/agent:ro
    depends_on:
      - nacos
      - oap

volumes:
  es-data:
```

```bash
# ① 下载 Agent——放在项目目录下
wget https://dlcdn.apache.org/skywalking/java-agent/9.1.0/apache-skywalking-java-agent-9.1.0.tgz
tar -xzf apache-skywalking-java-agent-9.1.0.tgz
mv apache-skywalking-java-agent ./skywalking-agent

# ② 修改 Agent 默认配置——指定 OAP 地址
vim skywalking-agent/config/agent.config
# 只需改这两行——其余用 Docker 环境变量覆盖：
#   agent.service_name=${SW_AGENT_NAME:default-service}
#   collector.backend_service=${SW_AGENT_COLLECTOR_BACKEND_SERVICES:127.0.0.1:11800}

# ③ 启动所有服务
docker-compose up -d

# ④ 等待 30 秒——所有服务注册到 Nacos + 连接到 OAP
sleep 30
docker-compose ps
```

### 2.2 本地 IDE 开发——不用 Docker 时的 Agent 挂载

```bash
# 开发时服务跑在 IDE 中——SkyWalking 跑在 Docker 中
# Agent 需要知道 OAP 的地址——localhost:11800

# IDEA 中配置 VM Options（每个服务）：
# Run → Edit Configurations → VM options:
-javaagent:D:/tools/skywalking-agent/skywalking-agent.jar
-Dskywalking.agent.service_name=order-service
-Dskywalking.collector.backend_service=127.0.0.1:11800
```

```yaml
# Docker Compose 只启动 SkyWalking + Nacos——服务在 IDE 中启动
# docker-compose-infra.yml
version: '3.8'
services:
  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:7.17.9
    environment:
      - discovery.type=single-node
      - "ES_JAVA_OPTS=-Xms512m -Xmx512m"
      - xpack.security.enabled=false
    ports:
      - "9200:9200"

  oap:
    image: apache/skywalking-oap-server:9.5.0
    depends_on:
      - elasticsearch
    environment:
      SW_STORAGE: elasticsearch
      SW_STORAGE_ES_CLUSTER_NODES: elasticsearch:9200
    ports:
      - "11800:11800"
      - "12800:12800"

  ui:
    image: apache/skywalking-ui:9.5.0
    depends_on:
      - oap
    environment:
      SW_OAP_ADDRESS: http://oap:12800
    ports:
      - "8080:8080"

  nacos:
    image: nacos/nacos-server:v2.2.3
    environment:
      - MODE=standalone
    ports:
      - "8848:8848"

# 启动基础设施——服务在 IDE 中依次启动
# docker-compose -f docker-compose-infra.yml up -d
```

### 2.3 逐步验证——确保所有中间件的追踪都生效了

```bash
# ===== Step 1：检查所有服务都注册到 Nacos =====
curl http://localhost:8848/nacos/v1/ns/service/list
# 预期：看到 gateway-service, order-service, user-service, product-service, account-service

# ===== Step 2：检查所有服务都连接到 OAP =====
docker logs oap | grep "registered"
# 预期：看到 5 个服务名——每个服务启动时都会向 OAP 注册

# ===== Step 3：检查 Agent 日志——确认连接成功 =====
docker logs order-service | grep "SkyWalking"
# 预期：INFO - SkyWalking agent connected to collector successfully

# ===== Step 4：制造一些流量——调用接口 =====
# 通过 Gateway 发一个请求——触发完整调用链
curl http://localhost:8088/api/orders \
  -H "Content-Type: application/json" \
  -d '{"userId":1001,"items":[{"productId":2001,"quantity":2}]}'

# 再调用几次——有足够的 Trace 数据
for i in {1..5}; do
  curl -s http://localhost:8088/api/users/1001 > /dev/null
done

# ===== Step 5：打开 SkyWalking UI 验证 =====
# http://localhost:8080
```

```
打开 SkyWalking UI → 拓扑图：

  应该自动出现一张调用拓扑——所有服务之间的关系一目了然：
  ┌────────────────┐
  │ gateway-service│ ← 入口
  └───────┬────────┘
          │
  ┌───────▼────────┐
  │ order-service  │
  └──┬──────┬──────┘
     │      │
     ▼      ▼
  ┌────┐  ┌──────────┐
  │user│  │product-svc│
  │-svc│  │ (gRPC)   │
  └────┘  └──────────┘
              │
         ┌────▼────┐
         │account  │
         │-service │
         │(Dubbo)  │
         └─────────┘

如果拓扑图没有出现 → 说明 Agent 没连上 OAP → 检查 collector.backend_service 配置
如果某条连线缺失 → 说明该中间件的追踪没生效 → 按下面的章节逐个排查
```

```
打开 SkyWalking UI → 追踪 → 选择 order-service → 搜索：

  应该看到一条 Trace：
  ┌────────────────────────────────────────────────┐
  │ TraceId: t-xxx | 全局耗时: 320ms               │
  │                                                │
  │ gateway-service: GET /api/orders (325ms)       │
  │   ├─ order-service: POST /api/orders (320ms)   │
  │   │   ├─ Feign: user-service GET /api/users/1  │← Feign Span 自动出现
  │   │   │   └─ MySQL: SELECT * FROM users        │
  │   │   ├─ gRPC: product-service/getProduct      │← gRPC Span 出现（如果手动埋了）
  │   │   │   └─ MySQL: SELECT * FROM products     │
  │   │   └─ MySQL: INSERT INTO orders             │
  │   └─ [响应返回]                                │
  └────────────────────────────────────────────────┘

如果看不到 HTTP Span → Agent jar 没生效——检查 -javaagent 参数
如果看不到 MySQL Span → Agent 版本太旧——升级到 9.x
如果看不到 Dubbo Span → 检查 agent.config 中 plugin.dubbo.active=true
如果看不到 gRPC Span → 没配手动埋点——gRPC 需要按本文 gRPC 小节（3.4）配置拦截器
```

### 2.4 Agent 配置速查——关键参数一览

```bash
# skywalking-agent/config/agent.config——所有可配置项
# 完整列表：https://skywalking.apache.org/docs/skywalking-java/latest/en/setup/service-agent/java-agent/configurations/

agent.service_name=${SW_AGENT_NAME:your-app-name}      # 必配——服务名
collector.backend_service=${SW_AGENT_COLLECTOR_BACKEND_SERVICES:127.0.0.1:11800}  # 必配——OAP 地址

# 采样——以下二选一
agent.sample_n_per_3_secs=-1                             # 默认 -1 = 全量（推荐）
agent.sample_n_per_3_secs=1000                           # 每 3 秒最多 1000 条——QPS > 50,000 时用

# 插件开关——按需关闭不需要的（减少开销）
plugin.spring_mvc.active=true        # Spring MVC 自动追踪
plugin.feign.http9xx.active=true     # OpenFeign 自动追踪
plugin.dubbo.active=true             # Dubbo 自动追踪
plugin.jdbc.active=true              # JDBC（MySQL/PostgreSQL）自动追踪
plugin.jedis.active=true             # Jedis（Redis）自动追踪
plugin.lettuce.active=true           # Lettuce（Redis）自动追踪
plugin.kafka.active=true             # Kafka 自动追踪
plugin.rocketmq.active=true          # RocketMQ 自动追踪
plugin.sentinel.active=true          # Sentinel 自动追踪

# 忽略某些 URL——不追踪（健康检查、静态资源）
trace.ignore_path=/actuator/**,/health,/static/**        # 默认值

# 日志关联——自动注入 TraceId 到 MDC
plugin.toolkit.log.transmit_formatted=true                # 默认 true
```

> ⚠️ 新手提示：Agent 配置有两个来源——`agent.config` 文件（全局默认）+ 环境变量/系统属性（覆盖）。Docker Compose 中用 `SW_AGENT_NAME` 环境变量覆盖 `agent.service_name`——这是 SkyWalking 8.8+ 的特性——环境变量前缀 `SW_` 对应 agent.config 中的配置项。

## 三、🔗 六种中间件——SkyWalking 追踪逐个配置

### 2.1 Spring Cloud Gateway——自动追踪

Gateway 基于 WebFlux + Netty——SkyWalking Agent 8.7+ 支持自动追踪：

```yaml
# Gateway 的 application.yml——不需要加任何 SkyWalking 配置
spring:
  cloud:
    gateway:
      routes:
        - id: order-service
          uri: lb://order-service
          predicates:
            - Path=/api/orders/**
          filters:
            - StripPrefix=1
```

启动时挂载 Agent——Gateway 的 Span 自动产生：

```
浏览器 → Gateway → 转发到 order-service

SkyWalking 中看到的 Span 树：
  Gateway: GET /api/orders/1 (入口——根 Span)
    └─ order-service: POST /api/orders (HTTP Client Span)
         ├─ MySQL: SELECT ... (Database Span)
         └─ Feign: user-service GET /api/users/1 (HTTP Client Span)
```

```bash
# Gateway 启动——注意 service_name 加 gw- 前缀便于区分
java -javaagent:/opt/skywalking/agent/skywalking-agent.jar \
     -Dskywalking.agent.service_name=gateway-service \
     -Dskywalking.collector.backend_service=oap:11800 \
     -jar gateway.jar
```

<strong>Gateway 特有的 Span 信息</strong>：在 SkyWalking UI 中——Gateway 产生的 Span 可以看到：
- 原始请求路径：`/api/orders/1`
- 路由目标：`lb://order-service`
- 转发后路径：`/orders/1`（StripPrefix=1 之后）
- 过滤链执行耗时

### 2.2 OpenFeign——完全自动——零配置

Feign 基于 HTTP——Agent 自动拦截 `feign.Client#execute()`——不需要任何额外配置：

```java
// 不需要加任何 SkyWalking 注解或配置——Agent 自动处理
@FeignClient(name = "user-service")
public interface UserClient {
    @GetMapping("/api/users/{userId}")
    User getUser(@PathVariable("userId") Long userId);
}
```

SkyWalking 中看到的 Span：

```
order-service
  └─ Feign: user-service GET /api/users/1001 (52ms)  ← 自动产生的 HTTP Client Span
       ├─ HTTP 状态码: 200
       ├─ 请求 URL: http://10.0.1.2:8082/api/users/1001
       └─ 响应大小: 256 bytes

user-service
  └─ GET /api/users/{userId} (48ms)  ← 自动产生的 HTTP Server Span
       └─ MySQL: SELECT * FROM users WHERE id=? (8ms)
```

### 2.3 Dubbo——需要插件配置

Dubbo 2.7 / 3.x 都支持——但需要在 Agent 侧显式启用 Dubbo 插件：

```bash
# 默认 Dubbo 插件是启用的——如果没生效——检查 Agent 配置
# /opt/skywalking/agent/config/agent.config
# 确认这行没有被注释：
plugin.dubbo.active=true
```

```yaml
# Dubbo 服务——不需要改代码
dubbo:
  application:
    name: account-service
  registry:
    address: nacos://localhost:8848
  protocol:
    name: dubbo
    port: 20880
```

```java
@DubboService
public class AccountServiceImpl implements AccountService {
    @Override
    public Account getAccount(Long userId) {
        // Agent 自动创建 Dubbo Server Span——不需要手动埋点
        return accountMapper.selectByUserId(userId);
    }
}

// Consumer 侧——也是一样
@DubboReference
private AccountService accountService;  // 调用时自动产生 Dubbo Client Span
```

SkyWalking 中 Dubbo Span 的样子：

```
order-service
  └─ Dubbo: com.example.AccountService.getAccount() (38ms)
       ├─ RPC 协议: dubbo://
       ├─ 目标地址: 10.0.1.3:20880
       ├─ 参数: userId=1001
       └─ 返回值: Account{id=1, balance=500}
```

> ⚠️ 新手提示：Dubbo 和 Feign 同时用——在拓扑图中能看到两种不同协议的连线——Dubbo 和 HTTP 的颜色和粗细不同——可以直观对比两种 RPC 的调用量和延迟。

### 2.4 gRPC——需要手动埋点

gRPC 不像 Dubbo/Feign 那样自带完整的 Filter 机制——SkyWalking Agent 对 gRPC 的支持有限。需要手动埋点：

```xml
<!-- gRPC 服务需要额外依赖 -->
<dependency>
    <groupId>org.apache.skywalking</groupId>
    <artifactId>apm-toolkit-trace</artifactId>
    <version>9.1.0</version>
</dependency>
```

```java
// gRPC Server 拦截器——手动创建 Span
@Component
public class GrpcSkyWalkingInterceptor implements ServerInterceptor {

    @Override
    public <ReqT, RespT> ServerCall.Listener<ReqT> interceptCall(
            ServerCall<ReqT, RespT> call,
            Metadata headers,
            ServerCallHandler<ReqT, RespT> next) {

        // ① 从 gRPC Metadata 中提取 SkyWalking Trace 信息
        String traceHeader = headers.get(
                Metadata.Key.of("sw8", Metadata.ASCII_STRING_MARSHALLER));

        // ② 创建 gRPC Server Span
        Span span = TraceContext.createEntrySpan(
                "gRPC/" + call.getMethodDescriptor().getFullMethodName());

        try {
            // ③ 执行实际的 gRPC 调用
            ServerCall.Listener<ReqT> listener = next.startCall(call, headers);
            span.setTag("grpc.method", call.getMethodDescriptor().getFullMethodName());
            span.setTag("grpc.service", call.getMethodDescriptor().getServiceName());
            return new ForwardingServerCallListener.SimpleForwardingServerCallListener<ReqT>(listener) {
                @Override
                public void onComplete() {
                    span.asyncFinish();  // ④ Span 结束
                    super.onComplete();
                }
            };
        } catch (Exception e) {
            span.log(e);       // 记录异常
            span.errorOccurred();
            span.asyncFinish();
            throw e;
        }
    }
}

// gRPC Client 拦截器——传播 Trace + 创建 Client Span
@Component
public class GrpcClientSkyWalkingInterceptor implements ClientInterceptor {

    @Override
    public <ReqT, RespT> ClientCall<ReqT, RespT> interceptCall(
            MethodDescriptor<ReqT, RespT> method,
            CallOptions callOptions,
            Channel next) {

        // ① 创建 gRPC Client Span
        Span span = TraceContext.createExitSpan(
                "gRPC/" + method.getFullMethodName(),
                next.authority());

        return new ForwardingClientCall.SimpleForwardingClientCall<ReqT, RespT>(
                next.newCall(method, callOptions)) {

            @Override
            public void start(Listener<RespT> responseListener, Metadata headers) {
                // ② 注入 SkyWalking Trace 信息到 gRPC Metadata
                span.inject(headers, (h, key, value) ->
                        h.put(Metadata.Key.of(key, Metadata.ASCII_STRING_MARSHALLER), value));
                super.start(responseListener, headers);
            }

            @Override
            public void halfClose() {
                span.asyncFinish();
                super.halfClose();
            }
        };
    }
}
```

> 📖 <strong>前置知识</strong>：gRPC 的 `ClientInterceptor` 和 `ServerInterceptor` 是 gRPC Java 的拦截器接口——类似 Dubbo 的 Filter。如果你还不熟悉 gRPC 拦截器机制，建议回顾 [<strong>gRPC 拦截器与认证]({{< relref "GrpcGateway.md" >}})。</strong>

### 2.5 Sentinel——限流熔断在链路中的标记

Sentinel 的限流/熔断也出现在 SkyWalking 追踪中——但默认 Sentinel Span 过于底层——不直观。推荐使用 SkyWalking 的 Sentinel 插件：

```xml
<!-- Sentinel 结合 SkyWalking——通过 Sentinel 的 Slot 扩展 -->
<dependency>
    <groupId>org.apache.skywalking</groupId>
    <artifactId>apm-sentinel-1.x-plugin</artifactId>
    <version>9.1.0</version>
</dependency>
```

在 SkyWalking UI 中——被 Sentinel 保护的资源会有标记：

```
order-service
  └─ POST /api/orders (已被限流——返回 429)
       └─ Feign: user-service GET /api/users/1 (未执行——被限流了)
```

```java
// 更细粒度——自定义限流结果标记到 Span 上
@SentinelResource(
    value = "createOrder",
    blockHandler = "createOrderBlocked"
)
@Trace(operationName = "OrderService.createOrder")  // SkyWalking 自定义 Span 名
public Order createOrder(CreateOrderRequest request) {
    // 给当前 Span 打 Tag——标识经过了 Sentinel
    ActiveSpan.tag("sentinel.resource", "createOrder");
    ActiveSpan.tag("sentinel.status", "PASSED");

    return orderService.createOrder(request);
}

// 被限流时的处理
public Order createOrderBlocked(CreateOrderRequest request, BlockException ex) {
    ActiveSpan.tag("sentinel.status", "BLOCKED");
    ActiveSpan.tag("sentinel.block.reason", ex.getRule().getResource());
    ActiveSpan.error();  // 标记 Span 为错误
    throw new ServiceException("请求被限流");
}
```

### 2.6 Nacos——注册中心的调用不影响业务 Trace

Nacos 是注册中心/配置中心——它的调用（注册、发现、心跳、拉取配置）不会被当作业务 Trace 的一环——因为它们不是同一个请求链。但可以在 SkyWalking 中看到 Nacos Client 到 Nacos Server 的连接：

```
拓扑图中：
  Nacos Server 是独立节点——所有服务都有到它的连线——但线很细——因为是心跳/配置拉取——不是业务流量
```

如果想专门追踪 Nacos 的调用——需要在 Agent 配置中显式启用：

```bash
# agent/config/agent.config
plugin.nacos-client.active=true
```

## 四、📝 自定义 Span——给你的业务逻辑加上追踪

Agent 自动追踪了框架级的调用——但你的业务逻辑中的关键步骤——Agent 不知道。需要手动加 Span：

### 3.1 @Trace 注解——最简单的自定义 Span

```xml
<dependency>
    <groupId>org.apache.skywalking</groupId>
    <artifactId>apm-toolkit-trace</artifactId>
    <version>9.1.0</version>
</dependency>
```

```java
@Service
public class OrderService {

    @Trace(operationName = "OrderService.createOrder")
    public Order createOrder(CreateOrderRequest request) {
        // ① 参数校验——自定义子 Span
        validateOrderRequest(request);

        // ② 价格计算——自定义子 Span
        BigDecimal totalPrice = calculateTotalPrice(request.getItems());

        // ③ 扣减库存——自定义子 Span
        deductInventory(request.getItems());

        // ④ 创建订单——自定义子 Span
        Order order = saveOrder(request, totalPrice);

        return order;
    }

    // 方法上的 @Trace 创建子 Span——出现在父 Span 下面
    @Trace(operationName = "OrderService.validateOrderRequest")
    private void validateOrderRequest(CreateOrderRequest request) {
        // 加 Tag——在 SkyWalking 中能看到
        ActiveSpan.tag("order.items.count", String.valueOf(request.getItems().size()));
        ActiveSpan.tag("order.userId", String.valueOf(request.getUserId()));

        if (request.getItems().isEmpty()) {
            ActiveSpan.error();  // 标记 Span 为错误
            throw new IllegalArgumentException("订单项不能为空");
        }
    }

    @Trace(operationName = "OrderService.calculateTotalPrice")
    private BigDecimal calculateTotalPrice(List<OrderItem> items) {
        ActiveSpan.tag("order.items.count", String.valueOf(items.size()));

        BigDecimal total = BigDecimal.ZERO;
        for (OrderItem item : items) {
            // 每个商品的查询是一个子 Span
            BigDecimal price = getProductPrice(item.getProductId());
            total = total.add(price.multiply(BigDecimal.valueOf(item.getQuantity())));
        }

        ActiveSpan.tag("order.totalPrice", total.toString());
        return total;
    }
}
```

在 SkyWalking UI 中的效果：

```
POST /api/orders (320ms)
  ├─ OrderService.createOrder (315ms)
  │   ├─ OrderService.validateOrderRequest (5ms)
  │   │   └─ tags: order.items.count=3, order.userId=1001
  │   ├─ OrderService.calculateTotalPrice (280ms)
  │   │   ├─ MySQL: SELECT price FROM products WHERE id=? (85ms)
  │   │   ├─ MySQL: SELECT price FROM products WHERE id=? (92ms)
  │   │   ├─ MySQL: SELECT price FROM products WHERE id=? (78ms)
  │   │   └─ tags: order.totalPrice=299.97
  │   ├─ OrderService.deductInventory (18ms)
  │   └─ MySQL: INSERT INTO orders ... (12ms)
```

### 3.2 手动创建 Span——更细粒度控制

`@Trace` 注解只能标在方法上——有些场景需要更灵活的 Span 控制（比如在循环中创建子 Span）：

```java
@Trace(operationName = "OrderService.deductInventory")
private void deductInventory(List<OrderItem> items) {
    for (OrderItem item : items) {
        // 为每个商品扣库存创建独立的子 Span
        Span span = TraceContext.createLocalSpan(
                "deductInventory.product." + item.getProductId());

        try {
            span.setTag("productId", String.valueOf(item.getProductId()));
            span.setTag("quantity", String.valueOf(item.getQuantity()));

            boolean success = inventoryService.deduct(
                    item.getProductId(), item.getQuantity());

            if (!success) {
                span.log("库存不足");
                span.errorOccurred();
                throw new InsufficientInventoryException(
                        "商品 " + item.getProductId() + " 库存不足");
            }
        } catch (Exception e) {
            span.log(e);
            span.errorOccurred();
            throw e;
        } finally {
            span.asyncFinish();  // 必须手动结束 Span
        }
    }
}
```

### 3.3 给 Span 加日志——在追踪中看到关键信息

```java
// SkyWalking 中每个 Span 可以附带日志——但不是系统日志——而是业务关键信息
@Trace(operationName = "OrderService.createOrder")
public Order createOrder(CreateOrderRequest request) {
    // 记录关键信息——在 SkyWalking UI 的 Span 详情中能看到
    ActiveSpan.info("开始创建订单——用户: " + request.getUserId());

    Order order = doCreateOrder(request);

    ActiveSpan.info("订单创建成功——订单号: " + order.getOrderNo());
    ActiveSpan.tag("order.orderNo", order.getOrderNo());
    ActiveSpan.tag("order.amount", order.getTotalAmount().toString());

    return order;
}
```

## 五、🔄 异步和 MQ 场景——Trace 怎么不断？

### 4.1 @Async——跨线程追踪

Agent 自动处理 Spring `@Async`——不需要手动传播 TraceId：

```java
@Service
public class OrderService {

    @Async
    @Trace(operationName = "OrderService.sendOrderNotification")
    public CompletableFuture<Void> sendOrderNotification(Order order) {
        // Agent 自动把主线程的 Trace 信息带到这个异步线程中
        // SkyWalking 中——这个 Span 和主线程的 Span 在同一个 Trace 下
        emailService.sendOrderConfirmation(order);
        smsService.sendOrderSms(order);
        return CompletableFuture.completedFuture(null);
    }
}
```

<strong>条件</strong>：`@Async` 的线程池必须是 Spring 管理的——不能用 `new Thread()` 或自定义的非 Spring Bean 线程池。

### 4.2 CompletableFuture——串行和并行都会追踪

```java
@Trace(operationName = "OrderService.createOrderAsync")
public Order createOrderAsync(CreateOrderRequest request) {

    // 并行查询用户和商品——三个异步任务
    CompletableFuture<User> userFuture =
            CompletableFuture.supplyAsync(() -> userService.getUser(request.getUserId()));

    CompletableFuture<Product> productFuture =
            CompletableFuture.supplyAsync(() -> productService.getProduct(request.getProductId()));

    CompletableFuture<Account> accountFuture =
            CompletableFuture.supplyAsync(() -> accountService.getAccount(request.getUserId()));

    // 等待所有完成
    CompletableFuture.allOf(userFuture, productFuture, accountFuture).join();

    // 后面的逻辑在主线程——Trace 继续
    Order order = buildOrder(userFuture.join(), productFuture.join(), accountFuture.join());
    return orderRepository.save(order);
}
```

在 SkyWalking 中——三个异步 Span 在同一个 Trace 下——并行显示：

```
POST /api/orders (158ms)
  ├─ OrderService.createOrderAsync (150ms)
  │   ├─ [并行] Feign: user-service GET /api/users/1 (52ms)
  │   ├─ [并行] Feign: product-service GET /api/products/1 (48ms)
  │   ├─ [并行] Dubbo: AccountService.getAccount (38ms)
  │   └─ MySQL: INSERT INTO orders ... (12ms)
```

> ⚠️ 新手提示：自定义线程池（用 `new ThreadPoolExecutor()` 而不是 Spring 的 `ThreadPoolTaskExecutor`）——SkyWalking Agent 默认不会自动传播 Trace。解决方法——用 `@TraceCrossThread` 注解（SkyWalking 8.8+ 支持）——或者用 `TraceRunnable.wrap()` 手动包装。

### 4.3 MQ 消息——跨进程跨队列追踪（RocketMQ）

```
生产者 → MQ Broker → 消费者

MQ 调用是异步解耦的——Trace 如何跨 MQ 传播？
  ① 生产者发送消息时——SkyWalking Agent 自动把 Trace 信息放进消息 Header
  ② 消费者消费消息时——Agent 从 Header 中提取 Trace 信息——创建新的 Segment
  ③ 虽然中间隔了一个 Broker——SkyWalking UI 中能看到完整的调用链
```

```java
// RocketMQ 生产者——不需要手动处理——Agent 自动给消息加 Trace Header
@Service
public class OrderMessageProducer {

    @Autowired
    private RocketMQTemplate rocketMQTemplate;

    public void sendOrderCreatedEvent(Order order) {
        // Agent 自动在消息 Header 中加上 SkyWalking Trace 信息
        rocketMQTemplate.syncSend("order-created-topic", order);
        
        // 如果 TPS 极高——异步发送
        rocketMQTemplate.asyncSend("order-created-topic", order, new SendCallback() {
            @Override
            public void onSuccess(SendResult sendResult) {
                // Trace 传播到 MQ 发送成功
            }
            @Override
            public void onException(Throwable e) {
                // 发送失败——Span 标记为错误
            }
        });
    }
}

// 消费者——也不需要手动处理
@Component
@RocketMQMessageListener(
    topic = "order-created-topic",
    consumerGroup = "order-created-consumer"
)
public class OrderCreatedConsumer implements RocketMQListener<Order> {

    @Override
    public void onMessage(Order order) {
        // Agent 自动从消息 Header 中提取 Trace——创建新 Segment——关联到原始 Trace
        // 在 SkyWalking 中能看到完整的链路：
        //   order-service 发送 MQ → ... → payment-service 消费 MQ
    }
}
```

SkyWalking 中 MQ 链路的展示：

```
POST /api/orders (320ms)
  └─ order-service
       └─ RocketMQ: send order-created-topic (5ms)
            └─ RocketMQ Broker（虚拟节点）
                 └─ payment-service
                      └─ RocketMQ: consume order-created-topic (105ms)
                           └─ paymentService.processPayment (100ms)
                                └─ MySQL: UPDATE account SET balance=... (15ms)
```

> ⚠️ 新手提示：Kafka 同理——Producer 发送时 Agent 把 Trace 信息塞进 Kafka Header——Consumer 消费时自动提取。不需要改代码。

## 六、📋 日志关联——通过 TraceId 把日志和链路串起来

### 5.1 问题：日志分散在 5 个服务——怎么关联到同一次请求？

```
传统查日志——猜谜游戏：
  grep "userId=1001" order-service.log    → 找到 3 条日志
  grep "userId=1001" user-service.log     → 找到 2 条日志
  grep "userId=1001" inventory-service.log → 找到 1 条错误日志
  → 但不知道哪条日志对应到哪个请求——也不知道它们之间的时间关系

SkyWalking + TraceId 打印在日志中：
  在 SkyWalking 中找到慢请求 t-abc123
  去 ELK 中搜索 TraceId=t-abc123
  → 所有服务中属于这个请求的日志——全部出来——按时间排列
```

### 5.2 配置 logback——把 TraceId 打印到每行日志

```xml
<!-- logback-spring.xml -->
<configuration>
    <!-- 从 SkyWalking Agent 中获取 TraceId——放在 MDC 中 -->
    <appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
        <encoder>
            <!-- %tid 就是 SkyWalking 注入的 TraceId -->
            <pattern>
                %d{yyyy-MM-dd HH:mm:ss.SSS} [%thread] [%tid] %-5level %logger{36} - %msg%n
            </pattern>
        </encoder>
    </appender>

    <root level="INFO">
        <appender-ref ref="CONSOLE"/>
    </root>
</configuration>
```

```xml
<!-- pom.xml——需要 SkyWalking 的 logback 集成包 -->
<dependency>
    <groupId>org.apache.skywalking</groupId>
    <artifactId>apm-toolkit-logback-1.x</artifactId>
    <version>9.1.0</version>
</dependency>
```

<strong>效果——每行日志都带上 TraceId</strong>：

```
# order-service 日志
2022-12-20 03:15:22.331 [http-nio-8081] [t-abc123] INFO  OrderService - 开始创建订单——用户: 1001
2022-12-20 03:15:22.384 [http-nio-8081] [t-abc123] INFO  OrderService - 查询用户信息完成——耗时: 52ms
2022-12-20 03:15:25.365 [http-nio-8081] [t-abc123] INFO  OrderService - 订单创建成功——订单号: ORD-2022001

# user-service 日志
2022-12-20 03:15:22.335 [http-nio-8082] [t-abc123] INFO  UserService - 查询用户——id: 1001
2022-12-20 03:15:22.383 [http-nio-8082] [t-abc123] INFO  UserService - 命中缓存——user:1001

# inventory-service 日志（慢的那个）
2022-12-20 03:15:22.384 [http-nio-8083] [t-abc123] INFO  InventoryService - 检查库存——productId: 2001
2022-12-20 03:15:25.214 [http-nio-8083] [t-abc123] WARN  InventoryService - 库存查询耗时: 2830ms——SQL: SELECT * FROM inventory WHERE product_id = 2001
2022-12-20 03:15:25.215 [http-nio-8083] [t-abc123] ERROR InventoryService - 查询超时——建议检查索引
```

<strong>排查流程</strong>：

```
① SkyWalking UI → 追踪 → 按耗时排序 → 找到最慢的 TraceId: t-abc123
② ELK → 搜索: TraceId:t-abc123 → 所有服务的日志按时间排列
③ 日志 + Span 对比：
   - 哪步慢了 → Span 树中 inventory-service 的 MySQL Span 花了 2.8s
   - 当时的参数是什么 → Span tag: productId=2001
   - 日志中有什么线索 → WARN "库存查询耗时: 2830ms——SQL: SELECT * FROM inventory WHERE product_id = 2001"
④ 去查这条 SQL → EXPLAIN → 全表扫描 → 加索引
```

### 5.3 日志采集 + SkyWalking + ELK 的三方联动

```
┌─────────────┐     ┌───────────────┐     ┌─────────────┐
│ SkyWalking  │     │    ELK Stack  │     │  Prometheus │
│             │     │               │     │  + Grafana  │
│ Trace:      │     │ 日志查询：     │     │             │
│ t-abc123    │────→│ TraceId:      │     │ 指标监控：   │
│ 3s 慢请求   │     │ t-abc123      │     │ P99 延迟 3s │
│             │     │ 按时间排列     │     │ QPS 正常    │
│ 发现是哪条  │     │ 看到完整      │     │ 错误率 2%   │
│ SQL慢了     │     │ 日志上下文     │     │             │
└─────────────┘     └───────────────┘     └─────────────┘
       ↑                                        ↑
       │ 提供 TraceId                           │ 告警触发
       │                                        │
   ① Grafana 告警: "P99 延迟 > 2s"
   ② SkyWalking 找那条慢 Trace → TraceId: t-abc123 → 发现是 inventory-service MySQL Span 耗时 2.8s
   ③ ELK 搜 TraceId: t-abc123 → 看到完整日志上下文 → 确认是库存查询慢
   ④ 复盘: 加索引 → 验证 → P99 恢复正常
```

## 七、🔬 性能剖析——不只是追踪——看代码内部耗时

SkyWalking 9.2+ 支持性能剖析——在线程级别采样——看到方法内部的 CPU 耗时分布：

```
SkyWalking UI → 性能剖析 → 新建任务
  选择服务: order-service
  端点: POST:/api/orders
  采样时长: 10 分钟
  采样间隔: 10ms

结果——类似 Java Profiler 的火焰图：
  createOrder()                    100% (320ms)
    ├─ validateOrderRequest()       2%  (6ms)
    │   └─ items.isEmpty()          2%
    ├─ calculateTotalPrice()        85% (272ms)
    │   ├─ getProductPrice(item1)   28% (90ms)  ← 第一次查询——缓存未命中
    │   │   └─ productMapper.selectById()
    │   ├─ getProductPrice(item2)   29% (93ms)
    │   │   └─ productMapper.selectById()
    │   └─ getProductPrice(item3)   26% (83ms)
    │       └─ productMapper.selectById()
    ├─ deductInventory()            6% (19ms)
    └─ saveOrder()                  5% (16ms)

结论：
  ① 85% 的时间花在 calculateTotalPrice——因为循环中逐次查数据库（N+1 问题）
  ② 改成批量查询——一次 SELECT ... WHERE id IN (?,?,?) → 总时间降到 15ms
```

> ⚠️ 新手提示：性能剖析对 CPU 有轻微开销（3%-5%）——不要在生产环境长时间开启——只在需要排查问题时临时打开。

## 八、📦 集群部署——生产环境架构

```
                   ┌─────────────────────┐
                   │   Nginx (LB)        │
                   │   :80               │
                   └──────┬──────────────┘
                          │
              ┌───────────┼───────────┐
              ▼           ▼           ▼
        ┌─────────┐ ┌─────────┐ ┌─────────┐
        │ OAP-1   │ │ OAP-2   │ │ OAP-3   │  ← OAP 集群——3 节点
        │ :11800  │ │ :11800  │ │ :11800  │
        │ :12800  │ │ :12800  │ │ :12800  │
        └────┬────┘ └────┬────┘ └────┬────┘
             │           │           │
             └───────────┼───────────┘
                         ▼
              ┌─────────────────────┐
              │ Elasticsearch 集群  │  ← 存储——3 节点
              │ es-1 / es-2 / es-3  │
              └─────────────────────┘
```

```yaml
# docker-compose-cluster.yml
version: '3.8'
services:

  oap-1:
    image: apache/skywalking-oap-server:9.5.0
    environment:
      SW_CLUSTER: consul                    # 集群协调——Consul / Nacos / Zookeeper
      SW_CLUSTER_CONSUL_HOST: consul:8500
      SW_STORAGE: elasticsearch
      SW_STORAGE_ES_CLUSTER_NODES: es-1:9200,es-2:9200,es-3:9200
    ports:
      - "11801:11800"
    depends_on:
      - consul

  oap-2:
    image: apache/skywalking-oap-server:9.5.0
    environment:
      SW_CLUSTER: consul
      SW_CLUSTER_CONSUL_HOST: consul:8500
      SW_STORAGE: elasticsearch
      SW_STORAGE_ES_CLUSTER_NODES: es-1:9200,es-2:9200,es-3:9200
    ports:
      - "11802:11800"
    depends_on:
      - consul

  oap-3:
    image: apache/skywalking-oap-server:9.5.0
    environment:
      SW_CLUSTER: consul
      SW_CLUSTER_CONSUL_HOST: consul:8500
      SW_STORAGE: elasticsearch
      SW_STORAGE_ES_CLUSTER_NODES: es-1:9200,es-2:9200,es-3:9200
    ports:
      - "11803:11800"
    depends_on:
      - consul

  ui:
    image: apache/skywalking-ui:9.5.0
    environment:
      SW_OAP_ADDRESS: http://oap-1:12800,http://oap-2:12800,http://oap-3:12800
    ports:
      - "8080:8080"
```

```bash
# Agent 配置——连 OAP 集群
# agent/config/agent.config
collector.backend_service=oap-1:11800,oap-2:11800,oap-3:11800
```

### 性能预算——每 1000 QPS 需要的资源

| 组件 | CPU | 内存 | 磁盘（一天） | 备注 |
|------|:---:|:---:|:---:|------|
| <strong>Agent</strong> | < 1% | +64MB | 0 | 字节码增强——几乎无开销 |
| <strong>OAP × 3</strong> | 2 Core | 4GB | 0 | OAP 本身不存数据——只做分析 |
| <strong>ES × 3</strong> | 4 Core | 8GB | ~50GB | 1000 QPS 全量追踪——每天约 50GB 原始数据——ES 压缩后约 15GB |
| <strong>总计（1000 QPS）</strong> | 18 Core | 36GB | 15GB/天 | 相当于 3 台 8C16G 的机器 |

<strong>如果 QPS < 100——单机 OAP + ES 就够了——4C8G。</strong>

## 🎯 总结

1. <strong>SkyWalking Agent 自动追踪 HTTP/Dubbo/Feign/DB/Cache/MQ——gRPC 需要手动埋点</strong>：Gateway/Feign/Dubbo 一行配置都不用改——Agent 自动拦截。gRPC 需要在 ClientInterceptor 和 ServerInterceptor 中手动创建 Span 和传播 Trace 信息。

2. <strong>自定义 Span 用 @Trace 注解或手动创建 LocalSpan</strong>：框架级调用自动追踪——业务逻辑的关键步骤用 `@Trace` 注解标记——在循环中创建子 Span 用 `TraceContext.createLocalSpan()`。给 Span 加 Tag 和 Log——在 SkyWalking UI 中能看到业务上下文。

3. <strong>通过 TraceId 串联日志和链路——SkyWalking + ELK 联合排错</strong>：logback 中 `%tid` 打印 SkyWalking TraceId——在 SkyWalking 中找到慢请求的 TraceId → 去 ELK 搜索 → 看到所有相关服务的日志按时间排列。指标告诉你"出问题了"——链路告诉你"具体哪条请求"——日志告诉你"为什么"。

4. <strong>MQ 和 @Async 的 Trace 传播是自动的——不需要手动处理</strong>：Agent 自动在 MQ Header 中传播 Trace 信息——消费者自动提取。Spring @Async 自动传播——自定义线程池需要用 `@TraceCrossThread` 或 `TraceRunnable.wrap()`。

> 📖 <strong>系列回顾</strong>：可观测性三部曲至此完成——
> 1. [<strong>Prometheus + Grafana 环境搭建与指标采集</strong>]({{< relref "PrometheusGrafanaFundamentals.md" >}}) —— 指标监控
> 2. [<strong>所有中间件指标接入 Prometheus——统一仪表盘</strong>]({{< relref "PrometheusMiddleware.md" >}}) —— 六种中间件指标汇总
> 3. [<strong>SkyWalking 分布式链路追踪——从零搭建 APM 平台</strong>]({{< relref "SkyWalkingFundamentals.md" >}}) —— 链路追踪
> 4. <strong>SkyWalking 中间件集成与链路分析实战</strong>（本文） —— 中间件集成 + 日志关联 + 性能剖析
