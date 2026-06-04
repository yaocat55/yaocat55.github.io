---
title: "所有中间件指标接入 Prometheus——统一仪表盘实战"
date: 2022-12-18T08:00:00+00:00
tags: ["运维与可观测"]
categories: ["日志分析工具"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "将 Spring Cloud Gateway、Sentinel、Nacos、Dubbo、OpenFeign、gRPC 六种中间件的指标全部接入 Prometheus——每个中间件的指标暴露配置、关键指标解读——以及在一张 Grafana 仪表盘上构建'微服务全景图'：QPS/RT/错误率/中间件健康状态一目了然，附带分级告警规则。"
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

# 所有中间件指标接入 Prometheus——统一仪表盘实战

> 📖 <strong>前置阅读</strong>：本文假设读者已掌握 Prometheus + Grafana 的基础搭建和 PromQL 语法。如果还不熟悉，建议先阅读 [<strong>Prometheus + Grafana 环境搭建与指标采集</strong>]({{< relref "PrometheusGrafanaFundamentals.md" >}})。

## 一、⚡ 你有 6 种中间件——但你知道一个请求穿过它们时发生了什么吗？

一个请求穿过整个微服务体系要走多少中间件？

```
浏览器请求 GET /api/orders/100：
  ① Gateway 收到请求——鉴权、路由匹配
  ② Gateway 转发到 order-service（OpenFeign 或 Dubbo）
  ③ order-service 调 user-service（OpenFeign）
  ④ order-service 调 product-service（Dubbo）
  ⑤ 所有服务都在 Nacos 中发现对方
  ⑥ Sentinel 在整个过程中限流/熔断

这 6 步中——任何一步慢了——整个请求就慢了
没有统一监控时——你不知道是 Gateway 慢了、OpenFeign 慢了、还是 Dubbo 慢了
```

<strong>这篇的目标——把每种中间件的指标接入 Prometheus，在一张 Grafana 仪表盘上看到全貌。</strong>

## 二、🏗️ 搭建教程——完整的 Docker Compose + Prometheus 配置

上一篇讲了 Prometheus + Grafana 的基础搭建——但那只是两个容器。这篇要接入 6 种中间件——需要一个完整的 Docker Compose 把 Prometheus、Grafana 和所有微服务编排在一起。

### 2.1 完整的 Docker Compose——Prometheus + Grafana + 微服务

```yaml
version: '3.8'
services:

  # ===== 监控基础设施 =====
  prometheus:
    image: prom/prometheus:v2.48.0
    container_name: prometheus
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus-data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=15d'
      - '--web.enable-lifecycle'

  grafana:
    image: grafana/grafana:10.2.0
    container_name: grafana
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin123
    volumes:
      - grafana-data:/var/lib/grafana
    depends_on:
      - prometheus

  # ===== 注册中心 & 配置中心 =====
  nacos:
    image: nacos/nacos-server:v2.2.3
    container_name: nacos
    environment:
      - MODE=standalone
      - PREFER_HOST_MODE=hostname
    ports:
      - "8848:8848"
      - "9848:9848"

  # ===== API 网关 =====
  gateway:
    build: ./gateway
    container_name: gateway
    ports:
      - "8080:8080"
    environment:
      - SPRING_CLOUD_NACOS_DISCOVERY_SERVER-ADDR=nacos:8848
      - MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE=health,prometheus
    depends_on:
      - nacos

  # ===== 微服务 =====
  order-service:
    build: ./order-service
    container_name: order-service
    ports:
      - "8081:8081"
    environment:
      - SPRING_CLOUD_NACOS_DISCOVERY_SERVER-ADDR=nacos:8848
      - MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE=health,prometheus
    depends_on:
      - nacos

  user-service:
    build: ./user-service
    container_name: user-service
    ports:
      - "8082:8082"
    environment:
      - SPRING_CLOUD_NACOS_DISCOVERY_SERVER-ADDR=nacos:8848
      - MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE=health,prometheus
    depends_on:
      - nacos

  product-service:
    build: ./product-service
    container_name: product-service
    ports:
      - "8083:8083"
    environment:
      - SPRING_CLOUD_NACOS_DISCOVERY_SERVER-ADDR=nacos:8848
      - MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE=health,prometheus
    depends_on:
      - nacos

  # ===== 可选——如果用了 Dubbo/gRPC =====
  # account-service (Dubbo):
  #   build: ./account-service
  #   ports:
  #     - "20880:20880"

  # ===== 可选——Sentinel Dashboard =====
  sentinel-dashboard:
    image: bladex/sentinel-dashboard:1.8.6
    container_name: sentinel-dashboard
    ports:
      - "8858:8858"

volumes:
  prometheus-data:
  grafana-data:
```

```bash
# 启动所有服务
docker-compose up -d

# 验证所有服务都在 Nacos 中注册了
curl http://localhost:8848/nacos/v1/ns/service/list

# 验证每个服务的 Prometheus 端点
curl http://localhost:8081/actuator/prometheus   # order-service
curl http://localhost:8082/actuator/prometheus   # user-service
curl http://localhost:8083/actuator/prometheus   # product-service
```

### 2.2 完整的 prometheus.yml——所有中间件的抓取配置

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:

  # ===== ① Prometheus 自身 =====
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  # ===== ② Spring Boot 微服务——核心 =====
  - job_name: 'spring-boot-services'
    metrics_path: '/actuator/prometheus'
    static_configs:
      - targets:
          - 'gateway:8080'
          - 'order-service:8081'
          - 'user-service:8082'
          - 'product-service:8083'
        labels:
          env: 'production'

  # ===== ③ Nacos Server 自身指标 =====
  - job_name: 'nacos-server'
    metrics_path: '/nacos/actuator/prometheus'
    static_configs:
      - targets:
          - 'nacos:8848'
        labels:
          component: 'nacos'

  # ===== ④ Sentinel Dashboard 自身指标 =====
  - job_name: 'sentinel-dashboard'
    metrics_path: '/actuator/prometheus'
    static_configs:
      - targets:
          - 'sentinel-dashboard:8858'
        labels:
          component: 'sentinel'

  # ===== ⑤ Dubbo 服务（如果用了 Dubbo——走 QOS 端口暴露 metrics）=====
  # Dubbo 3.x 的指标可以通过 Spring Boot Actuator 暴露——和 job ② 合并
  # Dubbo 2.7 需要单独的 QOS 端口：
  # - job_name: 'dubbo-services'
  #   metrics_path: '/metrics'
  #   static_configs:
  #     - targets:
  #         - 'account-service:22222'  # dubbo.metrics.protocol=prometheus 指定的端口
```

```bash
# 修改配置后热加载 Prometheus——不需要重启
curl -X POST http://localhost:9090/-/reload

# 在 Prometheus UI 中验证所有 target 都是 UP
# http://localhost:9090/targets
```

### 2.3 逐步验证——确保每种中间件的指标都暴露了

```bash
# ===== 验证 1：Spring Boot Actuator 端点 =====
# 每个微服务都应该返回 Prometheus 格式的指标
curl http://localhost:8081/actuator/prometheus | head -20
# 预期输出：看到 jvm_memory_used_bytes, http_server_requests_seconds 等

# ===== 验证 2：Gateway 指标 =====
curl http://localhost:8080/actuator/prometheus | grep gateway
# 预期输出：gateway_requests_seconds_count, gateway_requests_seconds_sum 等

# ===== 验证 3：Sentinel 指标 =====
# 先确认微服务已连接到 Sentinel Dashboard
curl http://localhost:8858
# 然后在微服务中访问一次 Sentinel 保护的接口
curl http://localhost:8081/api/orders
# 再查指标——应该出现 sentinel_blocked_total, sentinel_passed_total 等
curl http://localhost:8081/actuator/prometheus | grep sentinel

# ===== 验证 4：Nacos 指标 =====
curl http://localhost:8848/nacos/actuator/prometheus | grep nacos
# 预期输出：nacos_monitor_healthCheck, nacos_monitor_serviceCount 等

# ===== 验证 5：Dubbo 指标（如果用了 Dubbo） =====
curl http://localhost:8081/actuator/prometheus | grep dubbo
# 预期输出：dubbo_provider_requests_total, dubbo_consumer_requests_total 等

# ===== 验证 6：Feign 指标 =====
curl http://localhost:8081/actuator/prometheus | grep http_client
# 预期输出：http_client_requests_seconds_count 等（带 clientName=xxx 标签）

# ===== 验证 7：在 Prometheus 中查询 =====
# http://localhost:9090
# 输入查询：up → 应该看到所有 target
# 输入查询：up{job="spring-boot-services"} → 应该看到 4 个 service
```

### 2.4 Grafana 接入——创建统一 Data Source

```
步骤：
  ① 浏览器打开 http://localhost:3000
  ② 登录：admin / admin123
  ③ 左侧菜单 → Connections → Data Sources → Add data source
  ④ 选择 Prometheus → URL: http://prometheus:9090 → Save & test
  ⑤ 如果显示 "Data source is working" → 接入成功

导入预置仪表盘：
  ① 左侧菜单 → Dashboards → New → Import
  ② 输入 Dashboard ID:
     - 12900 → Spring Boot 2.7 Statistics（JVM + HTTP 全自动）
     - 4701  → JVM Micrometer（更详细的 JVM）
     - 11378 → HikariCP 连接池
     - 763   → Redis Dashboard
  ③ 选择刚创建的 Prometheus Data Source → Import
  ④ 现在每个仪表盘都是真实数据——不是示例数据
```

> ⚠️ 新手提示：Docker Compose 中服务之间的网络是互通的——Prometheus 通过 `order-service:8081` 访问 Actuator 端点。如果你在本地 IDE 中运行微服务（不在 Docker 中）——Prometheus 需要访问 `host.docker.internal:8081`（Windows/Mac）或 `172.17.0.1:8081`（Linux）。

## 三、🔌 统一接入——所有服务先暴露 Actuator

每个中间件都有自己暴露指标的方式——但接入 Prometheus 的模式都一样：

```xml
<!-- 每个微服务都引入这三个——无一例外 -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>
<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-registry-prometheus</artifactId>
</dependency>
<!-- 如果有 JPA -->
<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-core</artifactId>
</dependency>
```

```yaml
# 每个微服务的 application.yml 都有这段
management:
  endpoints:
    web:
      exposure:
        include: health,prometheus,metrics
  metrics:
    tags:
      application: ${spring.application.name}
    export:
      prometheus:
        enabled: true
```

<strong>这三步是统一的基础</strong>——后面每个中间件的特殊配置都是在这之上"加上"的。

## 四、🚪 Spring Cloud Gateway 指标

### 3.1 自动暴露的 Gateway 指标

Gateway 引入 Actuator 后——自动暴露这些指标：

| 指标 | 含义 | Tag |
|------|------|------|
| `gateway_requests_seconds_count` | 路由请求总数 | `routeId`（路由 ID）、`routeUri`（目标 URI） |
| `gateway_requests_seconds_sum` | 路由请求总耗时 | 同上 |
| `gateway_requests_seconds_max` | 路由请求最大耗时 | 同上 |

```promql
# 每个路由的 QPS
sum(rate(gateway_requests_seconds_count[1m])) by (routeId)

# 每个路由的平均 RT
sum(rate(gateway_requests_seconds_sum[1m])) by (routeId)
  /
sum(rate(gateway_requests_seconds_count[1m])) by (routeId)

# Gateway 的总 QPS——所有路由加起来
sum(rate(gateway_requests_seconds_count[1m]))
```

### 3.2 Gateway 本身的 JVM 指标

Gateway 也是 Spring Boot 应用——JVM 指标同样暴露。Gateway 的内存和 GC 指标尤其重要——因为它是所有流量的入口：

```promql
# Gateway 的堆内存使用率——太高会导致频繁 GC 影响转发性能
jvm_memory_used_bytes{application="api-gateway", area="heap"}
  /
jvm_memory_max_bytes{application="api-gateway", area="heap"}
  * 100

# Gateway 的 GC 频率——如果频繁 GC——堆小了或对象创建太多
rate(jvm_gc_pause_seconds_count{application="api-gateway"}[1m])
```

### 3.3 开启更详细的 Gateway 指标

```yaml
spring:
  cloud:
    gateway:
      metrics:
        enabled: true            # 开启 Gateway 特制指标
        tags:
          path:
            enabled: true        # 给指标加上 path Tag——看每个路径的指标
```

## 五、🛡️ Sentinel 指标

### 4.1 Sentinel 暴露 Prometheus 指标

```xml
<dependency>
    <groupId>com.alibaba.csp</groupId>
    <artifactId>sentinel-prometheus-metric-exporter</artifactId>
    <version>1.8.7</version>
</dependency>
```

```java
@Configuration
public class SentinelPrometheusConfig {

    @PostConstruct
    public void init() {
        PrometheusMetricExporter exporter = new PrometheusMetricExporter();
        MetricTimerListener.register(exporter);
        // 指标暴露在 Actuator 的 /actuator/prometheus 中——自动合并
    }
}
```

### 4.2 Sentinel 核心指标及 PromQL

| Sentinel 指标 | 含义 | PromQL 查询 |
|------|------|------|
| `sentinel_blocked_qps{resource="getUser"}` | 当前被 Sentinel 拦截的 QPS | 直接查看——这是实时值 |
| `sentinel_passed_qps{resource="getUser"}` | 当前通过的 QPS | 直接查看 |
| `sentinel_blocked_total{resource="getUser"}` | 累计被拦截总数 | `rate(sentinel_blocked_total[1m])` |
| `sentinel_passed_total{resource="getUser"}` | 累计通过总数 | `rate(sentinel_passed_total[1m])` |

```promql
# 关键：被 Sentinel 限流/降级的比率
# 如果这个值突然升高——说明限流或熔断在大量生效——要排查
sum(rate(sentinel_blocked_total[1m])) by (resource)
  /
(sum(rate(sentinel_passed_total[1m])) by (resource) + sum(rate(sentinel_blocked_total[1m])) by (resource))
  * 100
```

```promql
# Sentinel 的实时 QPS——当前通过 + 当前拒绝
sentinel_passed_qps + on(resource) sentinel_blocked_qps
```

## 六、🧭 Nacos 指标

### 5.1 Nacos Server 自身指标

Nacos 内置了 Prometheus 端点——不需要额外配置：

```yaml
# Prometheus 配置——抓 Nacos Server
scrape_configs:
  - job_name: 'nacos-server'
    metrics_path: '/nacos/actuator/prometheus'
    static_configs:
      - targets:
          - 'nacos1:8848'
          - 'nacos2:8848'
          - 'nacos3:8848'
```

| Nacos 指标 | 含义 | 告警阈值 |
|------|------|:---:|
| `nacos_monitor_healthCheck` | 健康检查耗时 | > 1000ms |
| `nacos_monitor_serviceCount` | 注册的服务总数 | 骤降——有服务批量下线 |
| `nacos_monitor_instanceCount` | 注册的实例总数 | 骤降——实例批量失联 |
| `nacos_monitor_cpu` | Nacos 进程 CPU | > 80% |
| `nacos_monitor_avgPushCost` | 平均推送耗时 | > 500ms——Nacos 变慢了 |

```promql
# Nacos 中每个服务的实例数——看是否有服务实例大量下线
nacos_monitor_instanceCount

# Nacos CPU 使用率——Nacos 本身也需要监控
nacos_monitor_cpu
```

### 5.2 Nacos Client 端指标

每个连接到 Nacos 的微服务也会暴露 Nacos Client 指标——在 Actuator 中可以看到，只是没有独立的 Prometheus exporter（主要是看 Nacos Server 端指标就够）。

## 七、🔄 Dubbo 指标

### 6.1 开启 Dubbo 的 Prometheus 指标

Dubbo 3.x 内置了 Micrometer 指标暴露——只需要加依赖：

```xml
<dependency>
    <groupId>org.apache.dubbo</groupId>
    <artifactId>dubbo-metrics-prometheus</artifactId>
</dependency>
<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-registry-prometheus</artifactId>
</dependency>
```

```yaml
dubbo:
  metrics:
    enable: true
    protocol: prometheus    # 用 Prometheus 格式暴露
  monitor:
    enable: true
```

### 6.2 Dubbo Provider 端指标

| 指标 | 含义 | PromQL |
|------|------|------|
| `dubbo_provider_requests_total` | Provider 收到的请求总数 | `rate(dubbo_provider_requests_total[1m])` |
| `dubbo_provider_requests_succeed_total` | 成功请求数 | `rate(dubbo_provider_requests_succeed_total[1m])` |
| `dubbo_provider_requests_failed_total` | 失败请求数 | `rate(dubbo_provider_requests_failed_total[1m])` |
| `dubbo_provider_rt_milliseconds` | Provider 处理耗时 | `histogram_quantile(0.99, rate(dubbo_provider_rt_milliseconds_bucket[1m]))` |
| `dubbo_provider_thread_pool_active` | 活跃线程数 | 超过 max 就排队了 |
| `dubbo_provider_thread_pool_max` | 最大线程数 | — |

```promql
# Dubbo Provider QPS——按服务和方法
sum(rate(dubbo_provider_requests_total[1m])) by (service, method)

# Dubbo Provider P99 延迟
histogram_quantile(0.99,
  sum(rate(dubbo_provider_rt_milliseconds_bucket[1m])) by (le, service, method))

# Dubbo Provider 线程池使用率——超过 80% 要扩容
dubbo_provider_thread_pool_active{service="com.example.UserService"}
  /
dubbo_provider_thread_pool_max{service="com.example.UserService"}
  * 100
```

### 6.3 Dubbo Consumer 端指标

| 指标 | 含义 |
|------|------|
| `dubbo_consumer_requests_total` | Consumer 发起的请求总数 |
| `dubbo_consumer_requests_succeed_total` | 成功数 |
| `dubbo_consumer_rt_milliseconds` | Consumer 感知的耗时（含网络） |

```promql
# Dubbo Consumer QPS——看哪个服务的调用量最大
sum(rate(dubbo_consumer_requests_total[1m])) by (service)

# Consumer 端感知的延迟——比 Provider 多一次网络往返
histogram_quantile(0.99,
  sum(rate(dubbo_consumer_rt_milliseconds_bucket[1m])) by (le, service))
```

## 八、📡 OpenFeign 指标

### 7.1 自动暴露——Feign 底层是 HTTP Client

因为 OpenFeign 本质上发 HTTP 请求——它自动被 Micrometer 的 HTTP Client 指标覆盖：

```yaml
# OpenFeign 指标不需要额外配置——HTTP Client 的指标自动暴露
# 在 /actuator/prometheus 中能看到：
http_client_requests_seconds_count{clientName="user-service", method="GET", uri="/api/users/{id}"}
```

| 指标 | Tag | 含义 |
|------|------|------|
| `http_client_requests_seconds_count` | `clientName`（Feign Client 名）、`uri`、`method` | Feign 请求总数 |
| `http_client_requests_seconds_sum` | 同上 | Feign 请求总耗时 |

```promql
# Feign 调用 QPS——按被调服务
sum(rate(http_client_requests_seconds_count[1m])) by (clientName)

# Feign 调用 P99 延迟——看哪个 Feign 调用最慢
histogram_quantile(0.99,
  sum(rate(http_client_requests_seconds_bucket[1m])) by (le, clientName, uri))
```

### 7.2 开启更详细的 Feign 指标

```yaml
spring:
  cloud:
    openfeign:
      metrics:
        enabled: true     # Feign 2.4+ 支持——没这行也有基础指标
      client:
        config:
          default:
            logger-level: HEADERS
```

## 九、🔌 gRPC 指标

gRPC 本身不直接暴露 Prometheus 指标——需要额外库或者手动采样：

```java
// 方式：在 gRPC 拦截器中手动打点到 Micrometer
@GrpcGlobalInterceptor
public class GrpcMetricsInterceptor implements ServerInterceptor {

    private final MeterRegistry registry;

    public GrpcMetricsInterceptor(MeterRegistry registry) {
        this.registry = registry;
    }

    @Override
    public <ReqT, RespT> ServerCall.Listener<ReqT> interceptCall(
            ServerCall<ReqT, RespT> call,
            Metadata headers,
            ServerCallHandler<ReqT, RespT> next) {

        long start = System.nanoTime();
        String method = call.getMethodDescriptor().getFullMethodName();

        // 请求计数
        Counter.builder("grpc.server.requests.total")
                .tag("method", method)
                .tag("service", "order-service")
                .register(registry)
                .increment();

        // 耗时采样
        ServerCall.Listener<ReqT> listener = next.startCall(call, headers);

        return new ForwardingServerCallListener.SimpleForwardingServerCallListener<>(listener) {
            @Override
            public void onComplete() {
                super.onComplete();
                long duration = System.nanoTime() - start;
                Timer.builder("grpc.server.duration")
                        .tag("method", method)
                        .register(registry)
                        .record(duration, TimeUnit.NANOSECONDS);
            }
        };
    }
}
```

## 十、📊 统一 Grafana 仪表盘——微服务全景图

### 9.1 仪表盘布局设计

```
┌─────────────────────────────────────────────────────┐
│  第一行：全局概览                                     │
│  [GateWay 总 QPS] [全服务总 QPS] [全局错误率%] [P99 延迟]│
├─────────────────────────────────────────────────────┤
│  第二行：Gateway 层                                  │
│  [各路由 QPS 折线]         [路由 RT 热力图]            │
├─────────────────────────────────────────────────────┤
│  第三行：RPC 调用层                                   │
│  [Dubbo Provider QPS]     [Dubbo P99]               │
│  [Feign Client QPS]       [Feign P99]               │
├─────────────────────────────────────────────────────┤
│  第四行：限流熔断                                     │
│  [Sentinel 拦截率]         [Sentinel 通过/拒绝 QPS]    │
├─────────────────────────────────────────────────────┤
│  第五行：注册中心                                     │
│  [Nacos 服务数]            [Nacos 实例数]              │
├─────────────────────────────────────────────────────┤
│  第六行：JVM 健康（每个服务一行）                        │
│  [堆内存%] [GC 频率] [线程数] [CPU%]                   │
└─────────────────────────────────────────────────────┘
```

### 9.2 核心 Panel 的 PromQL——直接复制

<strong>第一行：全局概览</strong>

```promql
# ① 全服务总 QPS（一个数字）
sum(rate(http_server_requests_seconds_count[1m]))

# ② 全局 P99 延迟（一个数字）——单位秒
histogram_quantile(0.99,
  sum(rate(http_server_requests_seconds_bucket[1m])) by (le))

# ③ 全局错误率（一个数字）——百分比
sum(rate(http_server_requests_seconds_count{status=~"5.."}[1m]))
  /
sum(rate(http_server_requests_seconds_count[1m]))
  * 100
```

<strong>第二行：Gateway 路由详情</strong>

```promql
# ④ Gateway 各路由 QPS（折线图）
sum(rate(gateway_requests_seconds_count[1m])) by (routeId)

# ⑤ Gateway 路由平均 RT（折线图）
sum(rate(gateway_requests_seconds_sum[1m])) by (routeId)
  /
sum(rate(gateway_requests_seconds_count[1m])) by (routeId)
```

<strong>第三行：RPC 调用</strong>

```promql
# ⑥ Dubbo Provider QPS——按服务（折线图）
sum(rate(dubbo_provider_requests_total[1m])) by (service)

# ⑦ Dubbo Provider P99（折线图）
histogram_quantile(0.99,
  sum(rate(dubbo_provider_rt_milliseconds_bucket[1m])) by (le, service))

# ⑧ Feign 调用 QPS——按被调服务（折线图）
sum(rate(http_client_requests_seconds_count[1m])) by (clientName)

# ⑨ Feign 调用 P99（折线图）
histogram_quantile(0.99,
  sum(rate(http_client_requests_seconds_bucket[1m])) by (le, clientName))
```

<strong>第四行：Sentinel 限流熔断</strong>

```promql
# ⑩ Sentinel 拦截率（折线图）——看限流/熔断是否异常
sum(rate(sentinel_blocked_total[1m])) by (resource)
  /
(sum(rate(sentinel_passed_total[1m])) by (resource)
   + sum(rate(sentinel_blocked_total[1m])) by (resource))
  * 100
```

<strong>第五行：Nacos 注册中心</strong>

```promql
# ⑪ Nacos 中注册的服务总数（数字）
nacos_monitor_serviceCount

# ⑫ Nacos 中注册的实例总数（数字）
nacos_monitor_instanceCount
```

<strong>第六行：JVM 健康</strong>

```promql
# ⑬ 每个服务的堆内存使用率（条形图）
jvm_memory_used_bytes{area="heap"}
  /
jvm_memory_max_bytes{area="heap"}
  * 100

# ⑭ 每个服务的 GC 频率（折线图）
rate(jvm_gc_pause_seconds_count[1m])
```

### 9.3 导入这个仪表盘 JSON（骨架）

```json
{
  "title": "微服务全景监控",
  "panels": [
    {
      "title": "全局 QPS",
      "targets": [
        { "expr": "sum(rate(http_server_requests_seconds_count[1m]))" }
      ]
    },
    {
      "title": "Gateway 路由 QPS",
      "targets": [
        { "expr": "sum(rate(gateway_requests_seconds_count[1m])) by (routeId)" }
      ]
    },
    {
      "title": "Dubbo Provider QPS",
      "targets": [
        { "expr": "sum(rate(dubbo_provider_requests_total[1m])) by (service)" }
      ]
    },
    {
      "title": "Sentinel 拦截率",
      "targets": [
        { "expr": "sum(rate(sentinel_blocked_total[1m])) by (resource) / (sum(rate(sentinel_passed_total[1m])) by (resource) + sum(rate(sentinel_blocked_total[1m])) by (resource)) * 100" }
      ]
    }
  ]
}
```

## 十一、🚨 分级告警规则

```yaml
# prometheus/alert_rules.yml
groups:
  # ===== P0 告警——立刻处理 =====
  - name: p0-critical
    rules:
      - alert: ServiceDown
        expr: up == 0
        for: 1m
        labels: { severity: critical }
        annotations:
          summary: "{{ $labels.instance }} 服务挂了"

      - alert: ErrorRateHigh
        expr: |
          sum(rate(http_server_requests_seconds_count{status=~"5.."}[5m])) by (application)
            /
          sum(rate(http_server_requests_seconds_count[5m])) by (application)
          * 100 > 10
        for: 3m
        labels: { severity: critical }
        annotations:
          summary: "{{ $labels.application }} 错误率超过 10%"

  # ===== P1 告警——需要关注 =====
  - name: p1-warning
    rules:
      - alert: HeapMemoryHigh
        expr: |
          jvm_memory_used_bytes{area="heap"}
            /
          jvm_memory_max_bytes{area="heap"}
          * 100 > 85
        for: 5m
        labels: { severity: warning }
        annotations:
          summary: "{{ $labels.application }} 堆内存使用率超过 85%"

      - alert: SentineBlockRateHigh
        expr: |
          sum(rate(sentinel_blocked_total[5m])) by (resource)
            /
          (sum(rate(sentinel_passed_total[5m])) by (resource)
             + sum(rate(sentinel_blocked_total[5m])) by (resource))
          * 100 > 20
        for: 3m
        labels: { severity: warning }
        annotations:
          summary: "{{ $labels.resource }} Sentinel 拦截率超过 20%"

      - alert: GcFrequencyHigh
        expr: rate(jvm_gc_pause_seconds_count[5m]) * 60 > 10
        for: 5m
        labels: { severity: warning }
        annotations:
          summary: "{{ $labels.application }} GC 频率 > 10次/min"

  # ===== P2 告警——信息通知 =====
  - name: p2-info
    rules:
      - alert: NacosInstanceDrop
        expr: |
          (nacos_monitor_instanceCount - nacos_monitor_instanceCount offset 10m)
            / nacos_monitor_instanceCount offset 10m < -0.3
        for: 5m
        labels: { severity: info }
        annotations:
          summary: "Nacos 实例数 10 分钟内下降超过 30%"
```

## 🎯 总结

1. <strong>每种中间件接入 Prometheus 的模式都一样——Actuator + Micrometer</strong>：Gateway/Dubbo 自动暴露，Sentinel 加 adaptor，Nacos 加 metrics_path，gRPC 在拦截器中手动打点。核心都是把指标暴露在 HTTP 端点上——Prometheus 来拉。

2. <strong>六种中间件的关键指标只需记这 6 句 PromQL</strong>：Gateway 看 `gateway_requests_seconds`、Dubbo 看 `dubbo_provider_*`、Sentinel 看 `sentinel_blocked_*/passed_*`、Nacos 看 `nacos_monitor_*`、Feign 看 `http_client_requests_*`、JVM 看 `jvm_memory_*` 和 `jvm_gc_*`。

3. <strong>一张 Grafana 仪表盘看全貌——六行布局</strong>：第一行全局概览、第二行 Gateway、第三行 RPC（Dubbo+Feign）、第四行 Sentinel、第五行 Nacos、第六行 JVM。排错时从第一行往下看——哪行异常定位到哪层。

4. <strong>告警分三级——别让告警疲劳</strong>：P0 立刻处理（服务挂了、错误率 > 10%），P1 需要关注（堆内存 > 85%、Sentinel 拦截异常），P2 信息通知（实例数异常下降）。

---

> 📖 <strong>系列回顾</strong>：Prometheus + Grafana 系列——
> 1. [<strong>环境搭建与指标采集</strong>]({{< relref "PrometheusGrafanaFundamentals.md" >}}) —— pull model、四种指标类型、PromQL、Grafana 搭建
> 2. <strong>所有中间件指标接入——统一仪表盘</strong>（本文） —— 六种中间件接入 Prometheus、统一仪表盘 PromQL、分级告警
>
> 📖 <strong>下一步阅读</strong>：Prometheus 的指标告诉你"出问题了"——但要想知道"为什么出问题"——需要分布式链路追踪来定位是调用链中哪个服务的哪个操作慢了。继续阅读 [<strong>SkyWalking 分布式链路追踪——从零搭建 APM 平台</strong>]({{< relref "SkyWalkingFundamentals.md" >}})。
