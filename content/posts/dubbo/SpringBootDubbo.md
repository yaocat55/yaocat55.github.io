---
title: "SpringBoot Dubbo 全操作指南"
date: 2022-11-20T08:00:00+00:00
tags: ["RPC框架", "实践教程", "SpringBoot"]
categories: ["RPC框架"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "从原生 Dubbo Spring XML 迁移到 SpringBoot Starter：@DubboService 和 @DubboReference 两个注解替代全部 XML、dubbo/triple 协议切换、Hessian2/Fastjson2 序列化配置、Nacos 注册中心集成——附带完整的 Provider + Consumer 双向调用代码。"
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

# SpringBoot Dubbo

> 📖 <strong>前置阅读</strong>：本文假设读者已理解 Dubbo 的核心概念（Registry、Provider、Consumer、RPC 调用链路）。如果还不熟悉，建议先阅读 [<strong>Dubbo 核心架构与 RPC 模型</strong>]({{< relref "DubboFundamentals.md" >}})。

## 🎯 第一步：目标说明

上一篇用原生 Dubbo + Spring XML 写了 `<dubbo:service>`、`<dubbo:reference>`、`<dubbo:registry>`。SpringBoot 时代不需要那些 XML——`dubbo-spring-boot-starter` 用<strong>两个注解 + 一套 yml 配置</strong>替代全部 XML。

读完这篇会掌握：

- `dubbo-spring-boot-starter` 环境搭建——依赖 + yml 配置
- <strong>@DubboService</strong>——暴露服务，替代 `<dubbo:service>`
- <strong>@DubboReference</strong>——引用远程服务，替代 `<dubbo:reference>`
- dubbo 协议 vs triple 协议——什么时候用哪个
- Hessian2 / Fastjson2 序列化配置
- Nacos 注册中心的 SpringBoot 集成

## 📋 第二步：前置条件

| 前置项 | 具体要求 | 验证命令 |
|--------|----------|----------|
| JDK | 17+（8+ 也兼容） | `java -version` |
| SpringBoot | 3.x（文中用 3.2） | `mvn dependency:tree \| grep spring-boot` |
| Nacos | 2.3.0（单机即可） | `docker ps \| grep nacos` |
| 前置知识 | Registry/Provider/Consumer 概念 | — |

确认 Nacos 在跑：

```bash
docker ps | grep nacos
# 如果没跑起来：
docker run -d --name nacos -e MODE=standalone -p 8848:8848 -p 9848:9848 nacos/nacos-server:v2.3.0
```

## 🔧 第三步：环境搭建

### 3.1 项目结构

```
dubbo-demo
├── pom.xml                        # 父 POM
├── dubbo-api/                     # 公共接口模块——Provider 和 Consumer 共享
│   ├── pom.xml
│   └── src/main/java/org/example/api/
│       ├── Order.java             # 数据传输对象
│       └── OrderService.java      # 服务接口（契约）
├── dubbo-provider/                # 服务提供者
│   ├── pom.xml
│   └── src/main/java/org/example/provider/
│       └── OrderServiceImpl.java  # 接口实现
└── dubbo-consumer/                # 服务消费者
    ├── pom.xml
    └── src/main/java/org/example/consumer/
        └── OrderController.java   # 通过 Dubbo 调用远程服务
```

<strong>公共 API 模块是必需的</strong>——Dubbo 的契约就是 Java Interface。Provider 实现它，Consumer 通过它调用。两边引用同一个 API JAR。

### 3.2 依赖

父 POM：

```xml
<dependencyManagement>
    <dependencies>
        <dependency>
            <groupId>org.apache.dubbo</groupId>
            <artifactId>dubbo-bom</artifactId>
            <version>3.3.0</version>
            <type>pom</type>
            <scope>import</scope>
        </dependency>
    </dependencies>
</dependencyManagement>
```

`dubbo-api` 模块——只有数据类和接口，不需要 Dubbo 依赖：

```xml
<dependency>
    <groupId>org.projectlombok</groupId>
    <artifactId>lombok</artifactId>
    <optional>true</optional>
</dependency>
```

`dubbo-provider` 模块：

```xml
<dependencies>
    <!-- Dubbo SpringBoot Starter——一站式依赖 -->
    <dependency>
        <groupId>org.apache.dubbo</groupId>
        <artifactId>dubbo-spring-boot-starter</artifactId>
        <version>3.3.0</version>
    </dependency>
    <!-- Nacos 注册中心适配 -->
    <dependency>
        <groupId>org.apache.dubbo</groupId>
        <artifactId>dubbo-registry-nacos</artifactId>
    </dependency>
    <!-- Nacos 客户端 -->
    <dependency>
        <groupId>com.alibaba.nacos</groupId>
        <artifactId>nacos-client</artifactId>
        <version>2.3.0</version>
    </dependency>
    <!-- 引用公共 API 模块 -->
    <dependency>
        <groupId>org.example</groupId>
        <artifactId>dubbo-api</artifactId>
        <version>${project.version}</version>
    </dependency>
</dependencies>
```

`dubbo-consumer` 模块——依赖和 Provider 一样（它也需要 Dubbo Starter + Nacos）。

> ⚠️ 新手提示：`dubbo-spring-boot-starter` 版本和 Dubbo 版本用同一个号（3.3.0）。它内部包含了 `dubbo` 核心库、Spring 整合、Netty 通信。不需要额外引入 `dubbo`。

### 3.3 配置文件

Provider 的 `application.yml`：

```yaml
dubbo:
  application:
    name: order-provider              # 服务名称——全局唯一
  registry:
    address: nacos://localhost:8848   # 注册中心地址
  protocol:
    name: dubbo                       # 协议：dubbo / triple / rest
    port: 20880                       # 监听端口
  scan:
    base-packages: org.example.provider  # 扫描 @DubboService 的包路径
```

Consumer 的 `application.yml`：

```yaml
dubbo:
  application:
    name: order-consumer
  registry:
    address: nacos://localhost:8848
  # Consumer 不需要 protocol——它不暴露端口
```

<strong>配置项解释</strong>：

| 配置 | 含义 | 必须配？ |
|------|------|:---:|
| `dubbo.application.name` | 应用名称——在注册中心中作为服务的标识 | 是 |
| `dubbo.registry.address` | 注册中心地址——`nacos://host:port` 或 `zookeeper://host:port` | 是 |
| `dubbo.protocol.name` | 服务暴露的协议——`dubbo`（TCP长连接） 或 `triple`（HTTP/2） | Provider 才需要 |
| `dubbo.protocol.port` | 监听端口——每个 Provider 用一个独立端口 | Provider 才需要 |
| `dubbo.scan.base-packages` | 扫描 `@DubboService` 注解的包路径 | Provider 才需要 |

## 🏗️ 第四步：分步实践

### 4.1 公共接口（API 模块）

```java
// dubbo-api/src/main/java/org/example/api/Order.java
@Data
@NoArgsConstructor
@AllArgsConstructor
public class Order implements Serializable {
    private Long orderId;
    private Long userId;
    private String productName;
    private BigDecimal amount;
    private String action;
    private LocalDateTime createTime;
}

// dubbo-api/src/main/java/org/example/api/OrderService.java
public interface OrderService {

    /** 根据 ID 查询订单 */
    Order getOrderById(Long orderId);

    /** 创建订单 */
    Order createOrder(Long userId, String productName, BigDecimal amount);

    /** 取消订单 */
    boolean cancelOrder(Long orderId);
}
```

### 4.2 Provider —— 一个注解暴露服务

```java
// dubbo-provider/src/main/java/org/example/provider/OrderServiceImpl.java
@Service                                    // Spring 的 @Service——加入 Spring 容器
@DubboService                               // Dubbo 的 @DubboService——暴露为 RPC 服务
public class OrderServiceImpl implements OrderService {

    // 模拟数据库
    private final ConcurrentHashMap<Long, Order> orderDB = new ConcurrentHashMap<>();

    @Override
    public Order getOrderById(Long orderId) {
        System.out.printf("[Provider] 查询订单: orderId=%d%n", orderId);
        Order order = orderDB.get(orderId);
        if (order == null) {
            throw new RuntimeException("订单不存在: " + orderId);
        }
        return order;
    }

    @Override
    public Order createOrder(Long userId, String productName, BigDecimal amount) {
        Long orderId = System.currentTimeMillis();
        Order order = new Order(orderId, userId, productName, amount,
                "created", LocalDateTime.now());
        orderDB.put(orderId, order);
        System.out.printf("[Provider] 创建订单: orderId=%d, product=%s, amount=%s%n",
                orderId, productName, amount);
        return order;
    }

    @Override
    public boolean cancelOrder(Long orderId) {
        System.out.printf("[Provider] 取消订单: orderId=%d%n", orderId);
        Order order = orderDB.get(orderId);
        if (order != null) {
            orderDB.remove(orderId);
            return true;
        }
        return false;
    }
}
```

`@DubboService` 注解参数：

| 参数 | 含义 | 默认值 |
|------|------|:---:|
| `interfaceClass` | 暴露的接口类型 | 实现类的第一个接口 |
| `version` | 服务版本号——同一个接口的不同实现 | `""` |
| `group` | 服务分组——不同业务场景分组 | `""` |
| `timeout` | 调用超时（毫秒） | 默认 1000ms |
| `retries` | 重试次数 | 2（不含第一次调用） |
| `loadbalance` | 负载均衡策略 | `random` |
| `actives` | 最大并发调用数 | 0（不限制） |

```java
// 示例：暴露带版本号、超时和并发限制的服务
@DubboService(
    version = "1.0.0",
    timeout = 3000,
    retries = 1,
    loadbalance = "roundrobin",
    actives = 100
)
public class OrderServiceImpl implements OrderService { ... }
```

### 4.3 Consumer —— 一个注解引用远程服务

```java
// dubbo-consumer/src/main/java/org/example/consumer/OrderController.java
@RestController
@RequestMapping("/api/order")
public class OrderController {

    // @DubboReference 替代 <dubbo:reference>——
    // Dubbo 自动生成代理对象，注入到 Spring 容器中
    @DubboReference
    private OrderService orderService;  // 这个 Bean 是 Dubbo 的代理对象

    @GetMapping("/{orderId}")
    public Order getOrder(@PathVariable Long orderId) {
        // 调用 orderService 的方法 → RPC 调用 → Provider 执行 → 返回结果
        return orderService.getOrderById(orderId);
    }

    @PostMapping("/create")
    public Order createOrder(@RequestBody CreateOrderRequest request) {
        return orderService.createOrder(
                request.getUserId(),
                request.getProductName(),
                request.getAmount());
    }

    @PostMapping("/cancel/{orderId}")
    public String cancelOrder(@PathVariable Long orderId) {
        boolean result = orderService.cancelOrder(orderId);
        return result ? "订单已取消" : "取消失败";
    }
}
```

`@DubboReference` 注解参数：

| 参数 | 含义 | 默认值 |
|------|------|:---:|
| `interfaceClass` | 引用的接口类型 | 字段的类型 |
| `version` | 服务版本号——和 Provider 的 version 匹配 | `""` |
| `group` | 服务分组——和 Provider 的 group 匹配 | `""` |
| `timeout` | 调用超时（毫秒）——Consumer 端覆盖 Provider 端的配置 | 默认 1000ms |
| `retries` | 重试次数——Consumer 端覆盖 | 默认 2 |
| `check` | 启动时检查 Provider 是否可用——`false` 允许 Provider 后启动 | `true` |
| `loadbalance` | 负载均衡策略 | `random` |
| `injvm` | 是否优先调用本地（同一个 JVM 内）的服务实现 | `true` |

```java
// 示例：引用带版本号的服务，设超时和重试
@DubboReference(
    version = "1.0.0",
    timeout = 5000,
    retries = 0,    // 不重试——幂等场景关掉重试
    check = false   // Provider 没启动也不报错
)
private OrderService orderService;
```

> ⚠️ 新手提示：`check=false` 在开发环境很实用——不用等 Provider 启动好才能启动 Consumer。但在生产环境建议设为 `true`（默认）——Consumer 启动时发现 Provider 不可用，立刻报错而不是等到第一次调用才暴露问题。

### 4.4 Provider 和 Consumer 的启动类

```java
// Provider 启动类
@SpringBootApplication
@EnableDubbo         // ← 启用 Dubbo 自动配置
public class ProviderApp {
    public static void main(String[] args) {
        SpringApplication.run(ProviderApp.class, args);
        System.out.println("Provider 已启动，监听 dubbo://localhost:20880");
    }
}

// Consumer 启动类
@SpringBootApplication
@EnableDubbo
public class ConsumerApp {
    public static void main(String[] args) {
        SpringApplication.run(ConsumerApp.class, args);
        System.out.println("Consumer 已启动");
    }
}
```

`@EnableDubbo` 做了三件事：
1. 扫描 `@DubboService` → 暴露为 RPC 服务
2. 扫描 `@DubboReference` → 注入远程代理对象
3. 连接注册中心 → 服务注册/订阅

### 4.5 测试流程

```bash
# 1. 确认 Nacos 在跑
curl http://localhost:8848/nacos/v1/console/health/liveness

# 2. 启动 Provider
mvn -pl dubbo-provider spring-boot:run
# 输出：Provider 已启动，监听 dubbo://localhost:20880

# 3. 检查 Nacos——确认服务已注册
# http://localhost:8848/nacos → 服务列表 → order-provider

# 4. 启动 Consumer
mvn -pl dubbo-consumer spring-boot:run

# 5. 调用 API
# 创建订单
curl -X POST http://localhost:8080/api/order/create \
  -H "Content-Type: application/json" \
  -d '{"userId": 2001, "productName": "iPhone 15", "amount": 6999.00}'

# 查询订单（用返回的 orderId）
curl http://localhost:8080/api/order/1700000000001

# 取消订单
curl -X POST http://localhost:8080/api/order/cancel/1700000000001
```

## 第五步：协议选择与序列化配置

### 5.1 dubbo 协议 vs triple 协议

Dubbo 3.x 支持两种主要协议：

| 维度 | dubbo 协议 | triple 协议 |
|------|------|------|
| <strong>传输层</strong> | TCP 长连接（Netty） | HTTP/2（Netty） |
| <strong>序列化</strong> | Hessian2（默认） | Protobuf（默认），兼容 Hessian2 |
| <strong>连接模型</strong> | 单连接——Provider-Consumer 之间一个 TCP 连接复用 | 多路复用——HTTP/2 Stream |
| <strong>浏览器访问</strong> | 不支持 | 支持（HTTP/2 兼容 HTTP/1.1） |
| <strong>跨语言</strong> | 需要 dubbo-go/dubbo-js 等 | 原生支持（基于 HTTP/2 + Protobuf） |
| <strong>穿透网关</strong> | 难——非 HTTP 协议，需要特殊处理 | 易——HTTP/2，Nginx/Envoy 原生支持 |
| <strong>适用场景</strong> | Java 微服务内部高吞吐通信 | 跨语言、需要穿透网关、对外暴露 |

```yaml
# 使用 triple 协议
dubbo:
  protocol:
    name: triple
    port: 30880
```

```java
// 或者同时暴露两种协议——老服务用 dubbo，新服务用 triple
dubbo:
  protocols:
    dubbo-protocol:
      id: dubbo
      name: dubbo
      port: 20880
    triple-protocol:
      id: triple
      name: triple
      port: 30880
```

> ⚠️ 新手提示：`dubbo` 协议仍然是 Java 微服务内部通信的最高性能选择——TCP 长连接 + Hessian2 序列化，没有 HTTP/2 的帧头和头部压缩开销。`triple` 协议的优势在于<strong>跨语言和云原生兼容性</strong>——如果服务需要被 Go/Node.js 调用，或需要穿透 Istio/Envoy 服务网格，选 triple。

### 5.2 序列化配置

Dubbo 默认用 Hessian2 做序列化。3.x 支持多种替换方案：

| 序列化器 | 配置值 | 特点 |
|------|------|------|
| Hessian2 | `hessian2` | 默认——二进制、跨语言、稳定 |
| Fastjson2 | `fastjson2` | JSON——可读性好、Java 生态好、比 Hessian2 慢 |
| Protobuf | `protobuf` | 最小体量、最快速度——需要定义 .proto 文件 |
| Kryo | `kryo` | 二进制——Hessian2 的替代，更快但跨语言弱 |
| JDK | `java` | JDK 原生序列化——不推荐（慢 + 安全性差） |

```yaml
# 全局序列化配置
dubbo:
  provider:
    serialization: hessian2     # 默认
    
# 或者针对特定服务配置
@DubboService(serialization = "fastjson2")
public class OrderServiceImpl implements OrderService { ... }

@DubboReference(serialization = "fastjson2")
private OrderService orderService;
```

## 第六步：FAQ

| 问题 | 原因 | 解决 |
|------|------|------|
| `No provider available for the service` | Provider 没启动，或注册中心地址配错，或 Consumer 的 `check=true` 但 Provider 未注册 | ① 确认 Provider 在 Nacos 服务列表中可见 ② 设 `@DubboReference(check=false)` ③ 确认注册中心地址一致 |
| `Not found exported service` | `@DubboService` 注解的类<strong>没实现任何接口</strong>——Dubbo 找不到暴露的类型 | `@DubboService` 必须标注在实现了接口的类上——且接口在 API 模块中定义 |
| `java.lang.IllegalStateException: Duplicate application config` | 同一个 JVM 内启动了多个 Dubbo 应用实例——application name 冲突 | 确认只有一个 `dubbo.application.name` 配置 |
| 调用超时但 Provider 日志显示正常处理完了 | Consumer 的 `timeout` 设太短——Provider 处理完时 Consumer 已断开 | 调大 `@DubboReference(timeout=5000)` 或降低 Provider 处理时间 |
| Nacos 页面上 Consumer 也显示为 Provider | Consumer 的 `dubbo.scan.base-packages` 扫到了不该扫的包——把 Spring 的 `@Service` 当成了 Dubbo 服务 | 确认 `dubbo.scan.base-packages` 路径精确指向 Provider 包 |
| Provider 运行但 `@DubboReference` 注入的字段为 null | `@EnableDubbo` 没加——Spring 不知道要启用 Dubbo | 启动类上加上 `@EnableDubbo` |

## 🎯 总结

1. <strong>两个注解替代全部 XML</strong>：`@DubboService`（暴露服务，替代 `<dubbo:service>`）+ `@DubboReference`（引用服务，替代 `<dubbo:reference>`）。加上 `@EnableDubbo` 启动自动配置——三行注解搞定。

2. <strong>公共 API 模块是 Dubbo 的契约层</strong>：接口定义在独立的 Maven 模块中，Provider 和 Consumer 共享。Dubbo 不传实现类——传的是接口定义 + 参数。

3. <strong>dubbo 协议 vs triple 协议</strong>：`dubbo` 是 TCP 长连接 + Hessian2——Java 内部最高性能；`triple` 是 HTTP/2 + Protobuf——跨语言和云原生友好。不是二选一——可以同时暴露两种协议。

4. <strong>Nacos 是推荐的注册中心</strong>：`dubbo.registry.address: nacos://localhost:8848` 一行配完。Nacos 同时做注册中心和配置中心——下一篇展开配置管理。

5. <strong>序列化默认够用</strong>：Hessian2 是默认选择——二进制、跨语言、性能好。没有特殊需求不要换——Fastjson2 可读性好但慢，Protobuf 需要 .proto 文件增加维护成本。

> 📖 <strong>下一步阅读</strong>：RPC 调用基本走通了。但调用失败了怎么办？多个 Provider 怎么分配流量？能不能异步调用？继续阅读 [<strong>集群容错与负载均衡</strong>]({{< relref "DubboAdvanced.md" >}})，拆解 Dubbo 的全部服务治理能力。
