---
title: "Sentinel 核心概念与快速上手"
date: 2022-12-06T08:00:00+00:00
tags: ["服务治理", "入门指南", "SpringCloud"]
categories: ["限流熔断中间件"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "从零理解 Sentinel：为什么 Hystrix 停更后 Sentinel 成了 Java 微服务限流熔断的事实标准？资源/规则/流量 grade 核心概念、@SentinelResource 注解、blockHandler 与 fallback 的区别、Dashboard 控制台部署——读完能跑起来第一个带限流的接口。"
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

# Sentinel 核心概念与快速上手

## 一、⚡ 流量控制——三个让你睡不着的问题

你写了三个微服务——用户服务、订单服务、商品服务。跑得挺稳——直到：

```
问题 ①：大促的流量是平时的 10 倍——订单服务扛不住了
  → 一个服务挂了 → 调用它的服务跟着挂 → 整个系统雪崩
  → 你想给订单接口限流——每秒最多处理 1000 个请求——多的直接拒绝

问题 ②：商品服务的"查价格"接口突然变慢了——耗时从 50ms 涨到 5s
  → 调它的线程全在等响应——线程池满了
  → 你想检测到 RT 异常时——先熔断掉这个接口——让它别拖死整个系统

问题 ③：不同的调用方重要程度不一样
  → 订单支付的接口 > 浏览订单的接口
  → 你想在流量高峰时——优先保证支付接口不被限流
```

这三个问题对应了 Sentinel 的三个核心能力：<strong>限流（Flow Control）、熔断降级（Circuit Breaking）、系统自适应保护（System Protection）</strong>。

## 二、🤔 Sentinel 是什么——以及为什么不是 Hystrix

Sentinel 是阿里巴巴开源的<strong>"流量防卫兵"</strong>——它以流量为切入点，从流量控制、熔断降级、系统负载保护三个维度保护服务的稳定性。

<strong>Hystrix 和 Sentinel 对比</strong>：

| 维度 | Hystrix | Sentinel |
|------|------|------|
| <strong>维护状态</strong> | 停止维护——只修 Bug 不加新功能 | ✅ 活跃维护——阿里巴巴 + 社区 |
| <strong>隔离策略</strong> | 信号量 + 线程池——二选一 | 信号量（默认）——更轻量 |
| <strong>限流粒度</strong> | 接口级别——比较粗糙 | ✅ 可按 QPS/线程/调用方/链路——精细化 |
| <strong>熔断策略</strong> | 按异常比例 | ✅ 按慢调用比例 + 异常比例 + 异常数 |
| <strong>规则动态修改</strong> | 需要改代码——不够灵活 | ✅ Dashboard 实时改——不需要重启 |
| <strong>系统自适应</strong> | 不支持 | ✅ 根据 Load/CPU/RT 自动限流 |
| <strong>规则持久化</strong> | Archaius（不推荐） | ✅ 推/拉模式——Nacos/Apollo/ZK 等 |

Hystrix 停更后——Sentinel 和 Resilience4j 是两大替代。Resilience4j 更"云原生"（轻量、函数式），Sentinel 更"企业级"（Dashboard 控制台、丰富的规则面板）。<strong>如果你的团队用了 Spring Cloud Alibaba——Sentinel 是默认选择。</strong>

## 三、🧩 Sentinel 的核心概念

### 3.1 资源（Resource）——你要保护什么？

<strong>资源是 Sentinel 中的核心概念</strong>——它可以是 Java 方法、一段代码、一个接口。只要你想限流或熔断它——它就是"资源"：

```java
// 方式一：@SentinelResource 注解——最简洁
@SentinelResource(value = "getUser")
public User getUser(Long userId) {
    return userRepository.findById(userId);
}

// 方式二：SphU API——在代码中埋点
try (Entry entry = SphU.entry("getUser")) {
    // 被保护的资源——执行你的业务逻辑
    return userRepository.findById(userId);
} catch (BlockException e) {
    // 被限流/降级了——走降级逻辑
    return getDefaultUser();
}

// 方式三：SphO API——只返回 true/false
if (SphO.entry("getUser")) {
    try {
        return userRepository.findById(userId);
    } finally {
        SphO.exit();
    }
} else {
    return getDefaultUser();
}
```

<strong>推荐用 `@SentinelResource` 注解</strong>——代码最干净。

### 3.2 规则（Rule）——你怎么保护它？

定义了资源后——你需要给它制定<strong>规则</strong>。Sentinel 有五类规则：

| 规则类型 | 作用 | 一句话 |
|------|------|------|
| <strong>流量控制（Flow）</strong> | 限制 QPS 或并发线程数 | "每秒最多 100 个请求——多了就拒绝" |
| <strong>熔断降级（Degrade）</strong> | 慢调用/异常比例达到阈值——打开熔断器 | "这个接口 50% 都超时了——先别调了" |
| <strong>系统保护（System）</strong> | 系统全局——Load/CPU/RT 阈值 | "整个机器 CPU 过 80% 了——所有接口都限流" |
| <strong>热点参数（ParamFlow）</strong> | 对某个参数值单独限流——如商品 ID | "热点商品 ID=10001 每秒最多 5000——其他 ID 不限" |
| <strong>授权控制（Authority）</strong> | 黑白名单 | "只有订单服务可以调支付接口" |

### 3.3 Entry 类型——流量是怎么定义的？

Sentinel 统计流量时区分三种 Entry 类型：

```java
// ① IN——进入资源——调方发起请求（默认就是 IN）
SphU.entry("getUser", EntryType.IN);

// ② OUT——离开资源——被调方处理请求
// 通常不需要自己加——Sentinel 会自动为每个入口创建 IN 和 OUT

// ③ 链路入口——和 @SentinelResource 的 entryType 对应
```

<strong>理解这个对"关联限流"很重要</strong>——见下一篇流控规则详解。

### 3.4 流量 grade——QPS 还是线程数？

```java
// Sentinel 中对资源做流量统计有两种方式：
// QPS 模式——统计每秒的请求次数
// 线程数模式——统计当前正在处理该资源的线程数
```

| 模式 | 统计维度 | 适用场景 | 示例 |
|------|------|------|------|
| `FLOW_GRADE_QPS` | 每秒请求量 | Web 接口——大多数场景 | "GET /api/users 每秒最多 1000 个请求" |
| `FLOW_GRADE_THREAD` | 并发线程数 | 耗时不稳定——防止慢请求占满线程池 | "getUser 方法同时最多 10 个线程在执行——第 11 个直接拒绝" |

## 四、🔧 第一个 Sentinel 项目

### 4.1 依赖

```xml
<dependencies>
    <!-- Sentinel 核心（sentinel-core）——负责限流/熔断逻辑 -->
    <dependency>
        <groupId>com.alibaba.cloud</groupId>
        <artifactId>spring-cloud-starter-alibaba-sentinel</artifactId>
    </dependency>

    <!-- Sentinel Dashboard 通信——用于从控制台推送/拉取规则 -->
    <dependency>
        <groupId>com.alibaba.csp</groupId>
        <artifactId>sentinel-transport-simple-http</artifactId>
    </dependency>
</dependencies>
```

### 4.2 配置

```yaml
spring:
  application:
    name: user-service
  cloud:
    sentinel:
      transport:
        dashboard: localhost:8080      # Sentinel Dashboard 地址
        port: 8719                     # 本服务与 Dashboard 通信的端口——每个服务不一样
      eager: true                      # 启动时立刻注册到 Dashboard——不等第一个请求
```

### 4.3 第一个被保护的接口

```java
@RestController
@RequestMapping("/api/users")
public class UserController {

    // @SentinelResource 把接口声明为 Sentinel 资源
    // value 就是这个资源的名字——在 Dashboard 中看到的也是这个
    @GetMapping("/{userId}")
    @SentinelResource(value = "getUser",
                      blockHandler = "getUserBlockHandler")  // 被限流时调这个方法
    public User getUser(@PathVariable Long userId) {
        return userService.getUser(userId);
    }

    // ===== blockHandler——限流/降级时走这里 =====
    // 方法签名必须和原方法一致 + 多一个 BlockException 参数
    public User getUserBlockHandler(Long userId, BlockException e) {
        System.out.println("getUser 被限流了——userId: " + userId);
        // 返回降级结果
        User fallback = new User();
        fallback.setUserId(userId);
        fallback.setUserName("系统繁忙，请稍后重试");
        return fallback;
    }

    // ===== fallback——业务异常时走这里（和 limit 无关）=====
    @GetMapping("/{userId}/orders")
    @SentinelResource(value = "getUserOrders",
                      blockHandler = "blockHandler",    // 限流降级时
                      fallback = "fallbackHandler")     // 业务抛异常时
    public List<Order> getUserOrders(@PathVariable Long userId) {
        // 这个接口可能抛异常——比如数据库连不上
        return orderService.getOrdersByUserId(userId);
    }

    // 限流/熔断触发时——调 blockHandler
    public List<Order> blockHandler(Long userId, BlockException e) {
        System.out.println("被 Sentinel 限流/熔断了");
        return Collections.emptyList();
    }

    // 业务异常触发时——调 fallback（不需要 BlockException 参数）
    public List<Order> fallbackHandler(Long userId, Throwable t) {
        System.out.println("业务方法出错——" + t.getMessage());
        return Collections.emptyList();
    }
}
```

<strong>blockHandler 和 fallback 的区别——非常重要</strong>：

| 回调 | 触发条件 | 参数签名 | 用途 |
|------|------|------|------|
| <strong>blockHandler</strong> | Sentinel 限流/降级——（BlockException） | 原参数 + `BlockException` | 流量控制——"当前请求太多，请稍后重试" |
| <strong>fallback</strong> | 业务方法抛异常——（Throwable） | 原参数 + `Throwable`（可选） | 业务容错——"数据库连不上，返回默认数据" |

### 4.4 用代码定义限流规则

```java
// 在应用启动时——用代码定义规则（不依赖 Dashboard）
@Component
public class SentinelRuleInitializer implements ApplicationRunner {

    @Override
    public void run(ApplicationArguments args) {
        initFlowRules();
    }

    private void initFlowRules() {
        List<FlowRule> rules = new ArrayList<>();

        // 规则 1：getUser 接口——QPS 限制为每秒 10 个
        FlowRule userRule = new FlowRule();
        userRule.setResource("getUser");           // 资源名——和 @SentinelResource 的 value 一致
        userRule.setGrade(RuleConstant.FLOW_GRADE_QPS);  // QPS 模式
        userRule.setCount(10);                     // 阈值：每秒 10 个
        userRule.setLimitApp("default");           // 对哪个调用方生效——default = 对所有调用方
        rules.add(userRule);

        // 规则 2：getUserOrders 接口——并发线程数限制为 5
        FlowRule orderRule = new FlowRule();
        orderRule.setResource("getUserOrders");
        orderRule.setGrade(RuleConstant.FLOW_GRADE_THREAD);  // 线程数模式
        orderRule.setCount(5);                      // 阈值：同时最多 5 个线程
        rules.add(orderRule);

        FlowRuleManager.loadRules(rules);
    }
}
```

### 4.5 启动 Dashboard——可视化控制台

```bash
# 下载 Sentinel Dashboard JAR
wget https://github.com/alibaba/Sentinel/releases/download/1.8.7/sentinel-dashboard-1.8.7.jar

# 启动——默认端口 8080
java -Dserver.port=8080 \
     -Dcsp.sentinel.dashboard.server=localhost:8080 \
     -Dproject.name=sentinel-dashboard \
     -jar sentinel-dashboard-1.8.7.jar

# 访问 http://localhost:8080
# 用户名/密码：sentinel/sentinel
```

启动 Dashboard 后——启动你的 Spring Boot 应用——再请求一次 `GET /api/users/1`。打开 Dashboard 的 `http://localhost:8080`——你会看到 `user-service` 出现在服务列表中。点进去——能看到每个接口的 QPS、通过数、拒绝数——以及<strong>实时添加/修改限流规则</strong>。

## 五、📊 Sentinel 统计数据结构——理解它才知道规则怎么配

Sentinel 对每个资源维护一个<strong>滑动时间窗口</strong>：

```
Sentinel 统计数据结构：
  ① 每个资源维护两个滑动窗口——一个 1s 一个 1min
  ② 滑动窗口包含 N 个桶——默认 2 个（采样窗格）
  ③ 每个桶记录：通过数、阻塞数、异常数、RT、当前线程数
  ④ 根据桶中数据——和规则的阈值对比——决定是否限流/熔断
```

```java
// 这段代码揭示了 Sentinel 统计的"底层原理"——不用在生产写
// 只是为了理解规则是怎么生效的
ClusterNode node = ClusterBuilderSlot.getClusterNode("getUser");
System.out.println("QPS: " + node.passQps());         // 每秒通过的请求
System.out.println("BlockQPS: " + node.blockQps());    // 每秒被拒绝的请求
System.out.println("AvgRT: " + node.avgRt());          // 平均响应时间
System.out.println("CurrentThread: " + node.curThreadNum()); // 当前线程数
```

这就是 Dashboard 中"实时监控"页面的数据来源。

## 六、🔗 Sentinel 与 Spring Cloud Gateway 的关系

在上一篇 Gateway 系列中——Gateway 有内置的 `RequestRateLimiter` 和 `CircuitBreaker` Filter。它们和 Sentinel 的关系：

| 场景 | 用什么 | 说明 |
|------|------|------|
| <strong>网关层统一限流</strong> | Gateway `RequestRateLimiter` | 在请求进入后端之前——网关层拦截 |
| <strong>单个接口精细限流</strong> | Sentinel `@SentinelResource` | 对方法级别做精细控制 |
| <strong>全局限流 + 后端正交</strong> | Gateway + Sentinel 都配 | 双保险——网关拦一级，后端拦一级 |

两者<strong>不是替代关系</strong>——是配合关系。网关做粗粒度限流——"所有 /api/users/** 每秒 1000 个"；Sentinel 做细粒度限流——"这个支付接口每秒 200 个"。

## 🎯 总结

1. <strong>Sentinel = 限流 + 熔断 + 系统保护</strong>：以"资源"为核心——任何你想保护的代码都可以用 `@SentinelResource` 注解声明。规则（Flow/Degrade/System/ParamFlow/Authority）决定怎么保护它。

2. <strong>blockHandler 和 fallback 不一样</strong>：BlockHandler 是限流/降级时触发（BlockException）；Fallback 是业务方法抛异常时触发（Throwable）。前者管"流量太大"，后者管"代码崩了"。

3. <strong>Dashboard 让规则管理可视化</strong>：不用重启——实时改规则、实时看效果。开发环境连本地 Dashboard，生产环境建集群。

4. <strong>Sentinel 和 Gateway 是配合不是替代</strong>：网关做粗粒度限流（按路径/IP），Sentinel 做细粒度限流（按方法/资源/调用方）。

> 📖 <strong>下一步阅读</strong>："每秒 100 个 QPS"只是流控的冰山一角——WarmUp 预热、排队等待、关联限流、链路限流——继续阅读 [<strong>Sentinel 流控规则全解</strong>]({{< relref "SentinelFlowControl.md" >}})。
