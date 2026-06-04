---
title: "Prometheus + Grafana 环境搭建与指标采集"
date: 2022-12-17T08:00:00+00:00
tags: ["运维与可观测"]
categories: ["日志分析工具"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "从零搭建微服务监控体系：Prometheus pull 模型原理、四种指标类型（Counter/Gauge/Histogram/Summary）、Spring Boot Actuator + Micrometer 打点实战、JVM 指标解读、自定义业务指标、PromQL 查询语法——以及 Grafana 接入 Prometheus 构建第一个仪表盘。"
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

# Prometheus + Grafana 环境搭建与指标采集

## 一、⚡ 微服务上线了——但你知道它现在是死是活吗？

前面写了 6 种中间件、拆了 5 个微服务、配了限流熔断、布了集群——一切看起来很完美。

凌晨 3 点，电话响了：<strong>"用户说下单超时——你看一下"</strong>。你打开电脑——但你能看什么？

```
没有监控时：
  ① SSH 到服务器——tail -f 看日志——满屏 WARN——不知道哪个先出问题
  ② 查数据库——慢查询一大堆——不知道是不是今天的查询就变慢了
  ③ 调 JVM 看线程——200 个线程在 BLOCKED——不知道是哪个接口引起的
  → 30 分钟过去了——你在猜问题在哪

有了 Prometheus + Grafana：
  ① 打开 Grafana 看板——QPS 正常——但 RT 从 50ms 涨到 3s
  ② 看 JVM 仪表盘——线程数飚到 500——GC 频繁
  ③ 看中间件面板——Dubbo 线程池满了——Sentinel 开始熔断
  → 2 分钟定位——是商品服务的 Dubbo 线程池被打满了
```

<strong>监控不是运维的事——是每个后端开发必须掌握的技能。</strong>

## 二、🧩 Prometheus 是什么——拉模型 + 时序数据库 + PromQL

### 2.1 Prometheus 的 pull model——和传统监控的区别

大多数监控系统是<strong>push model</strong>——应用主动把指标推给监控 server。Prometheus 是<strong>pull model</strong>——它定期去应用那里"拉"指标：

```
Push Model（Zabbix / Graphite）：
  App → 定时推指标 → Monitoring Server
  问题：Server 挂了——指标丢了

Pull Model（Prometheus）：
  Prometheus → 定时 GET /actuator/prometheus → App
  优势：App 无状态——只管暴露 HTTP 端点——Prometheus 来拉
```

### 2.2 核心组件

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────┐
│   App 1     │     │    Prometheus    │     │   Grafana   │
│ :8081       │────→│    Server        │────→│   :3000     │
│ /actuator/  │     │  抓取 + 存储 + 告警│     │  可视化仪表盘│
│ prometheus  │     └──────────────────┘     └─────────────┘
└─────────────┘
       ↑
┌─────────────┐
│   App 2     │     Prometheus 每 15s 拉一次 /actuator/prometheus
│ :8082       │     App 只是被动暴露——不需要知道 Prometheus 在哪
└─────────────┘
```

| 组件 | 作用 | 一句话 |
|------|------|------|
| <strong>Prometheus Server</strong> | 定时抓取指标、存储到时序数据库、执行告警规则 | 核心——指标数据的采集和存储 |
| <strong>Exporters</strong> | 把不暴露 Prometheus 指标的系统转成 Prometheus 能拉的格式 | Node Exporter（机器指标）、Redis Exporter 等 |
| <strong>Alertmanager</strong> | 处理告警——去重、分组、路由（邮件/钉钉/Slack） | 告警管理——不是 Prometheus 自己发 |
| <strong>Grafana</strong> | 可视化——把 Prometheus 的数据画成图表 | 业界标准的仪表盘工具 |
| <strong>Micrometer</strong> | Java 指标门面——统一的 API 对接不同监控系统 | 你写一次 Micrometer——Prometheus/InfluxDB 都能用 |

## 三、📊 Prometheus 的四种指标类型——你只需要两个

Prometheus 定义了四种指标类型——实际上最常用的就两种：

### 3.1 Counter（计数器）——只增不减

```
适用：请求总数、错误总数、消息发送条数
性质：只能增——重启归零（这不重要——Prometheus 有 rate() 函数算增量）
```

```java
// Micrometer 中创建 Counter
@Component
public class OrderMetrics {

    private final Counter orderCreatedCounter;
    private final Counter orderFailedCounter;

    public OrderMetrics(MeterRegistry registry) {
        this.orderCreatedCounter = Counter.builder("orders.created.total")
                .description("订单创建总数")
                .tag("service", "order-service")
                .register(registry);

        this.orderFailedCounter = Counter.builder("orders.failed.total")
                .description("订单创建失败总数")
                .tag("service", "order-service")
                .register(registry);
    }

    public void incrementOrderCreated() {
        orderCreatedCounter.increment();  // +1
    }

    public void incrementOrderFailed(String reason) {
        orderFailedCounter.increment();   // +1——带 tag 区分原因
    }
}
```

```
# Counter 暴露出的 Prometheus 指标：
orders_created_total{service="order-service"} 1523

# PromQL 查询——计算每秒订单创建速率
rate(orders_created_total[1m])
```

### 3.2 Gauge（仪表盘）——可增可减

```
适用：当前线程数、队列长度、内存使用量、CPU 温度
性质：有上有下——可增可减
```

```java
@Component
public class OrderMetrics {

    private final AtomicInteger pendingOrders = new AtomicInteger(0);

    public OrderMetrics(MeterRegistry registry) {
        Gauge.builder("orders.pending", pendingOrders, AtomicInteger::get)
                .description("当前待处理的订单数")
                .tag("service", "order-service")
                .register(registry);
    }

    public void incrementPending() { pendingOrders.incrementAndGet(); }
    public void decrementPending() { pendingOrders.decrementAndGet(); }
}
```

### 3.3 Histogram（直方图）——分桶统计分布

```
适用：请求耗时分布、响应体大小分布
关键：预定义桶——桶分得好不好决定你能看到什么
```

```java
// 方式一：用 @Timed 注解——最简单
@RestController
@RequestMapping("/api/orders")
public class OrderController {

    @PostMapping
    @Timed(value = "orders.create.duration", description = "创建订单耗时")
    public Order createOrder(@RequestBody CreateOrderRequest request) {
        return orderService.createOrder(request);
    }
}

// 方式二：用 Timer——手动记录
@Component
public class OrderMetrics {

    private final Timer orderCreateTimer;

    public OrderMetrics(MeterRegistry registry) {
        this.orderCreateTimer = Timer.builder("orders.create.duration")
                .description("创建订单耗时")
                .publishPercentiles(0.5, 0.95, 0.99)  // 自动算 P50/P95/P99
                .sla(Duration.ofMillis(100), Duration.ofMillis(500))  // SLA 桶
                .register(registry);
    }

    public void recordOrderCreate(long durationMs) {
        orderCreateTimer.record(durationMs, TimeUnit.MILLISECONDS);
    }
}
```

```
# Histogram 暴露出的指标：
orders_create_duration_seconds_bucket{le="0.1"} 120    # <=100ms 的有 120 个
orders_create_duration_seconds_bucket{le="0.5"} 450    # <=500ms 的有 450 个
orders_create_duration_seconds_bucket{le="1.0"} 530    # <=1s 的有 530 个
orders_create_duration_seconds_bucket{le="+Inf"} 600   # 总共 600 个

# PromQL 查询——P99 延迟：
histogram_quantile(0.99, rate(orders_create_duration_seconds_bucket[1m]))
```

### 3.4 Summary（摘要）——客户端算分位数

和 Histogram 类似——但分位数在客户端算。Prometheus 社区<strong>推荐 Histogram</strong>——因为 Summary 的分位数不能聚合（多个实例的分位数无法求平均）。

### 3.5 什么时候用哪个——速查表

| 你想知道什么 | 指标类型 | 示例 |
|------|:---:|------|
| 一共发生了多少次 | <strong>Counter</strong> | 请求总数、错误数、消息数 |
| 当前是多少 | <strong>Gauge</strong> | 线程数、队列长度、内存 |
| 耗时分布——P50/P95/P99 | <strong>Histogram</strong> | 接口耗时、消息处理时长 |
| 不可聚合的分位数 | Summary | 一般不用——用 Histogram |

## 四、🔧 Prometheus + Grafana 搭建——Docker Compose

### 4.1 Docker Compose

```yaml
version: '3.8'
services:

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
      - '--storage.tsdb.retention.time=15d'    # 数据保留 15 天
      - '--web.enable-lifecycle'               # 允许热加载配置

  grafana:
    image: grafana/grafana:10.2.0
    container_name: grafana
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin123
      - GF_INSTALL_PLUGINS=grafana-clock-panel
    volumes:
      - grafana-data:/var/lib/grafana
    depends_on:
      - prometheus

volumes:
  prometheus-data:
  grafana-data:
```

### 4.2 Prometheus 配置

```yaml
# prometheus.yml
global:
  scrape_interval: 15s          # 每 15s 抓一次——生产默认
  evaluation_interval: 15s      # 每 15s 评估一次告警规则

# 抓取目标配置
scrape_configs:
  # Prometheus 自身的指标
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  # Spring Boot 微服务——通过 Actuator 暴露
  - job_name: 'spring-boot-apps'
    metrics_path: '/actuator/prometheus'
    static_configs:
      - targets:
          - 'user-service:8081'
          - 'order-service:8082'
          - 'product-service:8083'
        labels:
          env: 'production'
```

### 4.3 Spring Boot 暴露 Prometheus 指标

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-actuator</artifactId>
</dependency>
<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-registry-prometheus</artifactId>
</dependency>
```

```yaml
# application.yml
management:
  endpoints:
    web:
      exposure:
        include: health,info,metrics,prometheus  # ← 暴露 /actuator/prometheus
  metrics:
    tags:
      application: ${spring.application.name}     # 给所有指标打上应用 Tag
    export:
      prometheus:
        enabled: true
```

```bash
# 验证——访问这个 URL 看到 Prometheus 格式的指标
curl http://localhost:8081/actuator/prometheus

# 输出示例：
# HELP jvm_memory_used_bytes The amount of used memory
# TYPE jvm_memory_used_bytes gauge
# jvm_memory_used_bytes{area="heap",application="user-service"} 1.5E8
# HELP http_server_requests_seconds Histogram of HTTP request durations
# TYPE http_server_requests_seconds histogram
# http_server_requests_seconds_bucket{method="GET",outcome="SUCCESS",status="200",uri="/api/users/{id}",le="0.1",} 120.0
```

## 五、📊 Spring Boot 自动暴露的 JVM 指标——不用写一行代码

Micrometer 自动收集的指标已经非常丰富：

| 指标前缀 | 含义 | 关键项 |
|------|------|------|
| `jvm_memory_used_bytes` | JVM 内存使用 | heap / nonheap |
| `jvm_memory_max_bytes` | JVM 最大内存 | —Xmx 的值 |
| `jvm_gc_pause_seconds` | GC 暂停时间 | 暂停频率和持续——最长的一天 |
| `jvm_threads_live_threads` | 活线程数 | 飚到很高 = 有问题 |
| `jvm_threads_states_threads` | 按状态的线程数 | BLOCKED 线程数 > 0 = 死锁风险 |
| `jvm_classes_loaded_classes` | 已加载的类数 | 持续增长 = Metaspace 泄漏 |
| `process_cpu_usage` | 进程 CPU 使用率 | > 80% = CPU 瓶颈 |
| `http_server_requests_seconds` | HTTP 请求耗时 | 自动按 URI/方法/状态码分桶 |
| `spring_data_repository_invocations_seconds` | Spring Data 查询耗时 | 自动按 Repository 方法分 |
| `cache_gets_total` | 缓存命中/未命中 | Spring Cache 自动统计 |

<strong>这些指标已经覆盖了 80% 的排查场景——不用自己写一行打点代码。</strong>

## 六、🔍 PromQL——Prometheus 的查询语言

PromQL 是 Prometheus 的查询语言——Grafana 中的所有图表都靠它。只记最常用的 5 个：

### 6.1 基础查询

```promql
# ① 直接查值——加 {label="value"} 过滤
http_server_requests_seconds_count{application="user-service", uri="/api/users/{id}"}

# ② rate()——计算每秒增长速率（Counter 用）
# Counter 只增不减——rate 算增量除以时间——得到 QPS
rate(http_server_requests_seconds_count{application="user-service"}[1m])
# 意思是：近 1 分钟内——每秒的请求增长速率 = QPS

# ③ irate()——瞬时速率（比 rate 更灵敏——但曲线毛刺多）
irate(http_server_requests_seconds_count{application="user-service"}[1m])

# ④ histogram_quantile()——从 Histogram 算分位数
# P99 延迟——99% 的请求在多少时间内完成
histogram_quantile(0.99, rate(http_server_requests_seconds_bucket[1m]))

# ⑤ sum() by()——按维度聚合
# 按应用名汇总 QPS
sum(rate(http_server_requests_seconds_count[1m])) by (application)
```

### 6.2 最常用的 PromQL 模式

```promql
# QPS——每秒请求量
sum(rate(http_server_requests_seconds_count[1m])) by (application, uri)

# 错误率——5xx 错误占比
sum(rate(http_server_requests_seconds_count{status=~"5.."}[1m])) by (application)
  /
sum(rate(http_server_requests_seconds_count[1m])) by (application)
  * 100

# P99 延迟
histogram_quantile(0.99,
  sum(rate(http_server_requests_seconds_bucket[5m])) by (le, application))

# JVM 堆内存使用率
jvm_memory_used_bytes{area="heap"}
  /
jvm_memory_max_bytes{area="heap"}
  * 100

# GC 频率——每分钟 GC 次数
rate(jvm_gc_pause_seconds_count[1m])
```

## 七、📈 Grafana——从 Prometheus 数据到可视化仪表盘

### 7.1 启动 Grafana

```
访问 http://localhost:3000
默认用户名/密码：admin/admin123（上面 docker-compose 设的）

步骤：
  ① 添加 Data Source → Prometheus → URL: http://prometheus:9090 → Save & Test
  ② 导入官方仪表盘——Spring Boot 2.7 Statistics（ID: 12900）
  ③ 进入仪表盘——JVM/HTTP/QPS 全部自动展示
```

### 7.2 导入现成的仪表盘

Grafana 有官方的仪表盘市场——不需要从零画图：

| Grafana 仪表盘 ID | 用途 |
|:---|------|
| <strong>12900</strong> | Spring Boot 2.7 Statistics——JVM/HTTP 完整面板 |
| <strong>4701</strong> | JVM Micrometer——更详细的 JVM 指标 |
| <strong>11378</strong> | Spring Boot HikariCP——数据库连接池 |
| <strong>12639</strong> | Node Exporter——机器 CPU/内存/磁盘 |
| <strong>763</strong> | Redis Dashboard |
| <strong>7362</strong> | MySQL Overview |

### 7.3 自己创建 Panel——以 QPS 折线图为例

```
① 点 "+" → Create Dashboard → Add visualization
② Data source: Prometheus
③ Query:
   sum(rate(http_server_requests_seconds_count{application="order-service"}[1m])) by (uri)
④ Legend: {{uri}}
⑤ Panel title: 订单服务 QPS
⑥ 右上角 Apply
```

### 7.4 创建告警规则——Grafana 内置告警

```
① Alerting → Alert rules → New alert rule
② Select data source: Prometheus
③ Query:
   sum(rate(http_server_requests_seconds_count{status=~"5.."}[5m]))
     /
   sum(rate(http_server_requests_seconds_count[5m]))
   * 100
④ Condition: 错误率 > 5%（持续 5 分钟）
⑤ 通知渠道：钉钉 / Slack / Email
```

```yaml
# 或者在 Prometheus 中定义告警规则（推荐——和 Grafana 告警二选一）
# prometheus/alert_rules.yml
groups:
  - name: spring-boot
    rules:
      - alert: HighErrorRate
        expr: |
          sum(rate(http_server_requests_seconds_count{status=~"5.."}[5m])) by (application)
            /
          sum(rate(http_server_requests_seconds_count[5m])) by (application)
          * 100 > 5
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "{{ $labels.application }} 错误率超过 5%"
```

## 🎯 总结

1. <strong>Prometheus 用 pull model——应用只暴露端点，不关心谁在拉</strong>：Micrometer 是 Java 指标门面——你写一次 Counter/Gauge/Timer，Prometheus/InfluxDB 都能对接。Spring Boot Actuator 已经自动暴露了丰富的 JVM 和 HTTP 指标——零代码。

2. <strong>四种指标类型中——Counter 和 Histogram 最常用</strong>：Counter 统计"一共多少次"（QPS、错误数），Histogram 统计"耗时分布"（P95/P99），Gauge 统计"当前是多少"（线程数、队列长度）。

3. <strong>PromQL 的核心是 rate() + histogram_quantile()</strong>：`rate(counter[1m])` 求每秒速率，`histogram_quantile(0.99, rate(bucket[1m]))` 求 P99 延迟。

4. <strong>Grafana 不需要从零画图——导入官方仪表盘</strong>：Spring Boot 仪表盘 ID 12900，JVM 仪表盘 ID 4701——免费的专业级可视化。

> 📖 <strong>下一步阅读</strong>：JVM 指标看到了——但你在 Gateway 中能知道哪个路由最慢吗？Sentinel 拦截了多少请求？Dubbo 线程池满了吗？继续阅读 [<strong>所有中间件指标接入 Prometheus——统一仪表盘实战</strong>]({{< relref "PrometheusMiddleware.md" >}})。
