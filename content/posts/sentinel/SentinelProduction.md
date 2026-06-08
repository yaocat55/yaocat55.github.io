---
title: "Sentinel 系统规则与生产部署"
date: 2022-12-09T08:00:00+00:00
tags: ["微服务中间件"]
categories: ["限流熔断中间件"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "Sentinel 生产环境完整方案：系统自适应保护（Load/CPU/RT/QPS/线程数）、Gateway 集成 Sentinel 限流、热点参数限流、规则持久化到 Nacos（重启不丢失）、Dashboard 集群部署、Prometheus 指标对接——附带 10 项生产 Checklist。"
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

# Sentinel 系统规则与生产部署

> 📖 <strong>前置阅读</strong>：本文假设读者已掌握 Sentinel 流控和熔断规则。如果还不熟悉，建议先阅读前三篇：[<strong>核心概念</strong>]({{< relref "SentinelFundamentals.md" >}})、[<strong>流控规则</strong>]({{< relref "SentinelFlowControl.md" >}})、[<strong>熔断降级</strong>]({{< relref "SentinelDegrade.md" >}})。

## 一、⚡ 流控和熔断都配了——但整个机器的 CPU 飙到 95% 了

流控规则保护的是单个接口——"getUser 每秒最多 100 个"。"熔断规则保护的是接口自身故障——"getUser 50% 慢调用就熔断"。

但这些规则<strong>不保护整个机器</strong>——如果 20 个接口各自都没超过自己的 QPS 阈值，但加起来把机器的 CPU 打满了——所有接口不可用。

<strong>系统规则（System Rule）解决的就是这个问题——从整个应用的层面做自适应保护。</strong>

## 二、🧬 系统自适应保护——不配具体 QPS，配"健康指标"

### 2.1 五种系统规则

```java
// 系统规则——对整个服务生效——不是针对某个资源
SystemRule systemRule = new SystemRule();

// ① Load 保护——系统负载（仅 Linux）超过阈值时限流
systemRule.setHighestSystemLoad(4.0);      // CPU 核数——如 4 核 CPU
// 系统 Load > 4.0 时——所有入口 QPS 自动降到 (Load / 当前Load) * 当前QPS

// ② CPU 使用率保护
systemRule.setHighestCpuUsage(0.8);        // CPU 使用率 > 80% 时——拒绝新的入口请求

// ③ 平均 RT 保护
systemRule.setAvgRt(100);                  // 所有入口的平均 RT > 100ms 时——限流

// ④ 最大并发线程数
systemRule.setMaxThread(200);              // 并发线程数 > 200——拒绝新请求

// ⑤ 入口 QPS——这个最直接
systemRule.setQps(500);                    // 所有入口（不管是哪个资源）——总 QPS > 500
```

| 系统规则 | 指标 | 阈值建议 | 适用场景 |
|------|------|------|------|
| <strong>Load</strong> | 系统 Load | ≤ CPU 核数 | <strong>Linux 环境——最推荐</strong> |
| <strong>CPU 使用率</strong> | CPU usage | ≤ 80% | 跨平台——和 Load 二选一 |
| <strong>平均 RT</strong> | 所有入口平均 RT | ≤ 正常值 × 2 | 服务变慢时自动降 QPS |
| <strong>并发线程数</strong> | 并发线程数 | ≤ 线程池大小 | 防止线程池满 |
| <strong>入口 QPS</strong> | 总 QPS | ≤ 压测值 × 80% | 简单粗暴——兜底方案 |

### 2.2 系统规则的最佳组合

```java
@Component
public class SystemRuleInitializer implements ApplicationRunner {

    @Override
    public void run(ApplicationArguments args) {
        List<SystemRule> rules = new ArrayList<>();

        // 规则 1：Load 保护——系统负载过高时自动降 QPS
        SystemRule loadRule = new SystemRule();
        loadRule.setHighestSystemLoad(4.0);
        rules.add(loadRule);

        // 规则 2：平均 RT 保护——接口变慢时自动减速
        SystemRule rtRule = new SystemRule();
        rtRule.setAvgRt(200);
        rules.add(rtRule);

        // 规则 3：并发线程数保护——防止线程池满
        SystemRule threadRule = new SystemRule();
        threadRule.setMaxThread(300);
        rules.add(threadRule);

        SystemRuleManager.loadRules(rules);
    }
}
```

<strong>系统规则是整个 JVM 级别的——不需要指定资源名</strong>。它的作用范围是所有入口（所有经过 Sentinel 保护的入口流量的汇总）。

### 2.3 系统规则和流控规则的关系——谁先生效？

```
请求进来 →
  ① 先检查系统规则——整个机器 CPU 80% 了吗？
    → 如果 CPU 80%：直接拒绝（不管你这个接口自己的 QPS 多少）
    → 如果 CPU 正常：继续
  ② 再检查流控规则——这个接口的 QPS 过 100 了吗？
    → 如果超了：拒绝
    → 如果没超：通过
```

<strong>系统规则优先级最高</strong>——它是全局兜底。单个接口被限流了只是一个接口不可用——但机器打挂了是所有接口不可用。

## 三、🔥 热点参数限流——什么时候需要"按参数过滤"？

### 3.1 为什么需要参数级限流？

QPS 限流是"这个接口总共每秒最多 1000 个"。但当 1000 个请求中 900 个都在查同一个热点商品（ID=10001），这个商品所在的数据库分片可能被打爆。

<strong>热点参数限流让你对热门参数值单独设阈值</strong>：

```java
// 场景：GET /api/products/{productId} 接口
// productId=10001 是最火的商品——每秒 5000 个查询
// 其他 productId 加起来每秒 500 个
// 需求：productId=10001 单独限流——每秒最多 3000 个

@GetMapping("/{productId}")
@SentinelResource(value = "getProduct",
                  blockHandler = "getProductBlockHandler")
public Product getProduct(@PathVariable Long productId) {
    return productService.getProduct(productId);
}

public Product getProductBlockHandler(Long productId, BlockException e) {
    throw new RuntimeException("该商品太热门了——请稍后重试");
}
```

```java
// 初始化热点参数规则
ParamFlowRule rule = new ParamFlowRule();
rule.setResource("getProduct");                    // 资源名
rule.setGrade(RuleConstant.FLOW_GRADE_QPS);
rule.setCount(1000);                               // 默认阈值——每秒 1000
rule.setParamIdx(0);                               // 第几个参数——productId 是第 0 个（第一个参数）

// 为特定参数值设独立阈值
ParamFlowItem item = new ParamFlowItem();
item.setObject("10001");                           // productId=10001
item.setCount(3000);                               // 每秒 3000——比默认 1000 高（更宽松）
item.setClassType(long.class.getName());
rule.addParamFlowItem(item);

// 另一个热点——严格限制
ParamFlowItem item2 = new ParamFlowItem();
item2.setObject("10002");                          // productId=10002
item2.setCount(500);                               // 每秒 500——比默认 1000 低（更严格）
item2.setClassType(long.class.getName());
rule.addParamFlowItem(item2);

ParamFlowRuleManager.loadRules(Collections.singletonList(rule));
```

<strong>热点参数限流的效果</strong>：

| productId | 阈值 | 说明 |
|:---|:---|------|
| 默认（其他所有 productId） | 1000 QPS | 普通商品——每秒 1000 |
| <strong>10001</strong> | <strong>3000 QPS</strong> | 超热门商品——单独放宽到 3000 |
| <strong>10002</strong> | <strong>500 QPS</strong> | 问题商品——可能有爬虫在抓——严格限制 |

## 四、🚪 Gateway 集成 Sentinel——在网关层统一限流

### 4.1 Gateway 中的 Sentinel 不如 "Gateway RequestRateLimiter" 简单——但更强大

Spring Cloud Gateway 内置的 `RequestRateLimiter` 是简单的 Redis 令牌桶——够用但功能有限。换成 Sentinel——你拿到了流控、熔断、系统保护全部能力：

```xml
<dependency>
    <groupId>com.alibaba.cloud</groupId>
    <artifactId>spring-cloud-alibaba-sentinel-gateway</artifactId>
</dependency>
```

### 4.2 Gateway 路由配置

```yaml
spring:
  cloud:
    gateway:
      routes:
        - id: user-service
          uri: lb://user-service
          predicates:
            - Path=/api/users/**
          filters:
            - StripPrefix=1
    sentinel:
      transport:
        dashboard: localhost:8080
        port: 8720
      # Gateway 专属配置
      scg:
        fallback:
          mode: response                    # 限流/降级时返回什么
          response-status: 429             # HTTP 429 Too Many Requests
          response-body: '{"code":429,"message":"Too Many Requests"}'
          content-type: application/json
```

### 4.3 自定义 Gateway 限流分组——按路径或按 IP

```java
@Configuration
public class GatewaySentinelConfig {

    @PostConstruct
    public void initGatewayRules() {
        Set<GatewayFlowRule> rules = new HashSet<>();

        // 规则 1：按路由限流——user-service 路由整体 QPS 不超过 1000
        GatewayFlowRule userServiceRule = new GatewayFlowRule("user-service");
        userServiceRule.setCount(1000);
        userServiceRule.setIntervalSec(1);
        rules.add(userServiceRule);

        // 规则 2：按 API 分组——把多个路径映射到一个组统一限流
        ApiDefinition apiDef = new ApiDefinition("user-read-api")
                .setPredicateItems(new HashSet<>(Arrays.asList(
                        new ApiPathPredicateItem()
                                .setPattern("/api/users/**")
                                .setMatchStrategy(SentinelGatewayConstants.URL_MATCH_STRATEGY_PREFIX)
                )));
        GatewayApiDefinitionManager.loadApiDefinitions(Collections.singleton(apiDef));

        GatewayFlowRule apiRule = new GatewayFlowRule("user-read-api");
        apiRule.setCount(500);           // 这组 API 总共 500 QPS
        apiRule.setIntervalSec(1);
        apiRule.setBurst(2);             // 参数索引（burst 模式）
        rules.add(apiRule);

        // 规则 3：按 IP 限流——每个 IP 最多 10 QPS
        GatewayFlowRule ipRule = new GatewayFlowRule("user-service");
        ipRule.setCount(10);
        ipRule.setIntervalSec(1);
        ipRule.setParamItem(new GatewayParamFlowItem()
                .setParseStrategy(SentinelGatewayConstants.PARAM_PARSE_STRATEGY_CLIENT_IP));
        rules.add(ipRule);

        GatewayRuleManager.loadRules(rules);
    }
}
```

## 五、💾 规则持久化到 Nacos——重启不丢失

### 5.1 问题：Dashboard 配的规则——服务重启就没了

<strong>Sentinel 的规则默认存在内存中——重启后全部丢失。</strong>要实现持久化——有三种模式：

| 模式 | 原理 | 优缺点 |
|------|------|------|
| <strong>原始模式（默认）</strong> | 规则存在服务内存——Dashboard 推送给服务 | 重启丢失——只在内存中 |
| <strong>Pull 模式</strong> | 定期从 Nacos/文件拉取——类似定时轮询 | 简单但有时延——改完规则要等一会 |
| <strong>Push 模式（推荐）</strong> | Dashboard 改规则 → 写 Nacos → Nacos 推给所有服务实例 | <strong>实时生效+持久化</strong>——配置复杂一些 |

### 5.2 Push 模式——Nacos 做规则数据源

```xml
<!-- 引入 Sentinel 的 Nacos 数据源适配 -->
<dependency>
    <groupId>com.alibaba.csp</groupId>
    <artifactId>sentinel-datasource-nacos</artifactId>
</dependency>
```

```yaml
spring:
  cloud:
    sentinel:
      transport:
        dashboard: localhost:8080
      datasource:
        # 流控规则——从 Nacos 拉取
        flow-rules:
          nacos:
            server-addr: localhost:8848
            data-id: ${spring.application.name}-flow-rules
            group-id: SENTINEL_GROUP
            data-type: json
            rule-type: flow
        # 熔断规则——从 Nacos 拉取
        degrade-rules:
          nacos:
            server-addr: localhost:8848
            data-id: ${spring.application.name}-degrade-rules
            group-id: SENTINEL_GROUP
            data-type: json
            rule-type: degrade
        # 系统规则——从 Nacos 拉取
        system-rules:
          nacos:
            server-addr: localhost:8848
            data-id: ${spring.application.name}-system-rules
            group-id: SENTINEL_GROUP
            data-type: json
            rule-type: system
```

```json
// Nacos 中 user-service-flow-rules 的内容——JSON 格式
[
    {
        "resource": "getUser",
        "grade": 1,
        "count": 100,
        "strategy": 0,
        "controlBehavior": 0,
        "limitApp": "default"
    },
    {
        "resource": "createOrder",
        "grade": 1,
        "count": 50,
        "strategy": 0,
        "controlBehavior": 0,
        "limitApp": "default"
    }
]
```

配置后——规则按以下流程生效：

```
Dashboard 修改规则 → Nacos 更新配置 → Sentinel 监听到 Nacos 变更 → 实时应用规则
服务重启 → 从 Nacos 加载规则 → 和重启前一样
```

## 六、📊 监控——Prometheus + Grafana 接入

### 6.1 Sentinel 暴露 Prometheus 指标

```xml
<!-- Sentinel 的 Prometheus 适配——把内部指标转成 Prometheus 格式 -->
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
        // 开启 Prometheus Exporter——默认暴露在 http://localhost:8719/metrics
        PrometheusMetricExporter exporter = new PrometheusMetricExporter();
        MetricTimerListener.register(exporter);
    }
}
```

### 6.2 Prometheus 抓取配置

```yaml
# prometheus.yml——抓取每个服务暴露的 Sentinel 指标
scrape_configs:
  - job_name: 'sentinel-metrics'
    metrics_path: '/metrics'
    static_configs:
      - targets:
        - 'user-service:8719'
        - 'order-service:8720'
        - 'product-service:8721'
    # 如果需要鉴权
    # basic_auth:
    #   username: admin
    #   password: admin
```

### 6.3 关键指标

| Prometheus 指标 | 含义 |
|------|------|
| `sentinel_blocked_total{resource="getUser"}` | 被 Sentinel 拦截的请求总数 |
| `sentinel_passed_total{resource="getUser"}` | 通过的请求总数 |
| `sentinel_exception_total{resource="getUser"}` | 业务异常总数 |
| `sentinel_rt_total{resource="getUser"}` | 总响应时间 |
| `sentinel_current_thread{resource="getUser"}` | 当前并发线程数 |
| `sentinel_qps{resource="getUser"}` | 当前 QPS |

## 七、🐳 Dashboard 生产环境部署

### 7.1 Sentinel Dashboard 集群部署

```
生产环境 Dashboard 架构：

                 ┌──────────────┐
                 │   Nacos 集群  │  ← 规则持久化存储
                 └──────┬───────┘
                        │
        ┌───────────────┼───────────────┐
        │               │               │
   ┌────▼────┐    ┌────▼────┐    ┌────▼────┐
   │Dashboard│    │Dashboard│    │Dashboard│    ← Dashboard 多实例（无状态）
   │  实例 1  │    │  实例 2  │    │  实例 3  │
   └────┬────┘    └────┬────┘    └────┬────┘
        │               │               │
        └───────────────┼───────────────┘
                        │
        ┌───────────────┼───────────────┐
        │               │               │
   ┌────▼────┐    ┌────▼────┐    ┌────▼────┐
   │  User-  │    │ Order-  │    │Product- │    ← 微服务实例
   │ Service │    │ Service │    │ Service │
   └─────────┘    └─────────┘    └─────────┘
```

```yaml
# docker-compose.yml——Sentinel Dashboard
version: '3.8'
services:
  sentinel-dashboard:
    image: bladex/sentinel-dashboard:1.8.7
    ports:
      - "8080:8080"
    environment:
      - JAVA_OPTS=-Dserver.port=8080
        -Dcsp.sentinel.dashboard.server=localhost:8080
        -Dsentinel.dashboard.auth.username=admin
        -Dsentinel.dashboard.auth.password=your-secure-password
        -Dserver.servlet.session.timeout=7200
    volumes:
      - ./sentinel-logs:/root/logs
```

## 八、📋 生产上线 10 项 Checklist

| # | 检查项 | 配置位置 | 为什么 |
|:--:|------|------|------|
| 1 | <strong>系统规则配 Load/CPU 保护</strong> | SystemRule | 接口级别规则都配了——全局兜底只靠系统规则——忘了配整个机器就打挂了 |
| 2 | <strong>规则持久化到 Nacos</strong> | datasource.nacos | 默认存在内存——重启后全丢——Nacos 持久化保你不丢规则 |
| 3 | <strong>Dashboard 密码不要用默认</strong> | `sentinel.dashboard.auth.password` | 默认 sentinel/sentinel——谁都能进 Dashboard 改规则 |
| 4 | <strong>每个服务的 sentinel.transport.port 不能冲突</strong> | yml | 默认 8719——同一台机器多个服务启动——端口冲突——Dashboard 看不到 |
| 5 | <strong>blockHandler 和 fallback 都要配</strong> | @SentinelResource | 只配 blockHandler——业务异常拿不到降级——用户看到 500 |
| 6 | <strong>Gateway 层和微服务层的 Sentinel 都要配</strong> | Gateway + 微服务 | 网关做粗粒度（按路径）——微服务做细粒度（按资源按调用方） |
| 7 | <strong>熔断时长设合理——别太短别太长</strong> | DegradeRule.timeWindow | 太短——反复开合（振荡）；太长——接口一直不可用 |
| 8 | <strong>慢调用阈值 ≥ 正常 RT × 1.5</strong> | DegradeRule.count | 太接近正常值——网络抖动就误熔断；太大——真慢了还不熔断 |
| 9 | <strong>Prometheus 指标暴露——不暴露给外部</strong> | Actuator | Sentinel 指标暴露在 8719 端口——需要认证或只内网可达 |
| 10 | <strong>压测验证——不是配完就完</strong> | — | 用 JMeter/Wrk 压测——验证限流/熔断能按预期触发——上线前必须测 |

## 🎯 总结

1. <strong>系统规则是最后的防线</strong>：接口限流和熔断保护单个资源——系统规则保护整个 JVM。Load > CPU 核数或 CPU 使用率 > 80% 时——所有入口统一限流。系统规则优先级最高——全局兜底。

2. <strong>规则持久化是必须的——别用默认内存模式</strong>：Sentinel 默认规则存在内存——服务重启后丢光。用 Nacos Push 模式——Dashboard 改规则 → 写 Nacos → 推所有实例——重启也不丢。

3. <strong>Gateway 集成 Sentinel 做网关层限流</strong>：Gateway Filter 中内置了 Sentinel——按路由/API 分组/IP 三种维度限流。和微服务层的 Sentinel 不冲突——双保险。

4. <strong>热点参数限流是精细化工具</strong>：热门 productId 放更宽的阈值——爬虫盯上的 ID 放更严的阈值。别给所有参数值一视同仁。

---

> 📖 <strong>系列回顾</strong>：Sentinel 系列到此结束——
> 1. [<strong>核心概念与快速上手</strong>]({{< relref "SentinelFundamentals.md" >}}) —— 资源/规则/Dashboard/@SentinelResource
> 2. [<strong>流控规则全解</strong>]({{< relref "SentinelFlowControl.md" >}}) —— QPS/线程数、三种效果×三种策略、WarmUp/排队/关联/链路
> 3. [<strong>熔断降级规则</strong>]({{< relref "SentinelDegrade.md" >}}) —— 慢调用/异常比例/异常数、熔断器状态机
> 4. [<strong>系统规则与生产部署</strong>]({{< relref "SentinelProduction.md" >}}) —— Load/CPU 保护、热点参数、Gateway 集成、Nacos 持久化、Docker
