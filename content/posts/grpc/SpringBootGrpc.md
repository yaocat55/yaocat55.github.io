---
title: "SpringBoot gRPC 全操作指南"
date: 2022-11-29T08:00:00+00:00
tags: ["微服务中间件"]
categories: ["RPC框架"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "SpringBoot 集成 gRPC 的全部操作：grpc-spring-boot-starter 环境搭建、四种 RPC 模式完整代码（Unary/ServerStream/ClientStream/BiDi Stream）、拦截器、异常处理 Status、Deadline 超时传播——附带完整的 Maven 多模块项目与 curl/grpcurl 验证。"
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

# SpringBoot gRPC 全操作指南

> 📖 <strong>前置阅读</strong>：本文假设读者已掌握 Protobuf 语法和 gRPC 四种调用模式的概念。如果还不熟悉，建议先阅读 [<strong>Protobuf 语法精讲与 gRPC 概念</strong>]({{< relref "ProtobufGuide.md" >}})。

## 🎯 第一步：目标说明

上一篇用 `protoc` 写了 `.proto` 文件，手动编译生成了 Java 代码。接下来把这一切接入 SpringBoot——用 `@GrpcService` 暴露 gRPC 服务，用 `@GrpcClient` 注入远程代理，四种 RPC 模式全部用代码跑通。

## 📋 第二步：前置条件

| 前置项 | 具体要求 | 验证命令 |
|--------|----------|----------|
| JDK | 17+ | `java -version` |
| SpringBoot | 3.x | `mvn dependency:tree \| grep spring-boot` |
| protoc | 3.25+ (Maven 插件会自动下载) | — |
| 前置知识 | Protobuf 语法、gRPC 四种模式概念 | — |

## 🔧 第三步：项目结构与依赖

### 3.1 多模块 Maven 项目

```
grpc-demo
├── pom.xml                          # 父 POM
├── grpc-api/                        # proto 文件 + 生成的 Java 代码
│   ├── pom.xml                      # 有 protobuf-maven-plugin
│   └── src/main/proto/
│       └── order.proto
├── grpc-server/                     # gRPC 服务端——实现业务逻辑
│   ├── pom.xml                      # 依赖 grpc-api
│   └── src/main/java/...
└── grpc-client/                     # gRPC 客户端——调用远程服务
    ├── pom.xml                      # 依赖 grpc-api
    └── src/main/java/...
```

<strong>为什么要把 proto 放在独立模块？</strong> 服务端和客户端都依赖 proto 生成的 Java 代码——放独立模块中双方共享编译结果，而不是各自编译一份。

### 3.2 依赖

父 POM：

```xml
<dependencyManagement>
    <dependencies>
        <dependency>
            <groupId>io.grpc</groupId>
            <artifactId>grpc-bom</artifactId>
            <version>1.60.0</version>
            <type>pom</type>
            <scope>import</scope>
        </dependency>
    </dependencies>
</dependencyManagement>
```

`grpc-api` 模块：

```xml
<dependencies>
    <!-- gRPC 核心依赖——protobuf + gRPC 运行时 -->
    <dependency>
        <groupId>io.grpc</groupId>
        <artifactId>grpc-protobuf</artifactId>
    </dependency>
    <dependency>
        <groupId>io.grpc</groupId>
        <artifactId>grpc-stub</artifactId>
    </dependency>
    <!-- 如果 proto 中用了 google.protobuf.Timestamp 等内置类型 -->
    <dependency>
        <groupId>io.grpc</groupId>
        <artifactId>grpc-protobuf-lite</artifactId>
        <!-- 或者用 com.google.api.grpc:proto-google-common-protos -->
    </dependency>
    <!-- 如果要在 Client 端用注解 @GrpcClient -->
    <dependency>
        <groupId>net.devh</groupId>
        <artifactId>grpc-client-spring-boot-starter</artifactId>
        <version>3.0.0.RELEASE</version>
    </dependency>
</dependencies>
```

`grpc-server` 模块：

```xml
<dependencies>
    <dependency>
        <groupId>net.devh</groupId>
        <artifactId>grpc-server-spring-boot-starter</artifactId>
        <version>3.0.0.RELEASE</version>
    </dependency>
    <dependency>
        <groupId>org.example</groupId>
        <artifactId>grpc-api</artifactId>
        <version>${project.version}</version>
    </dependency>
</dependencies>
```

`grpc-client` 模块：

```xml
<dependencies>
    <dependency>
        <groupId>net.devh</groupId>
        <artifactId>grpc-client-spring-boot-starter</artifactId>
        <version>3.0.0.RELEASE</version>
    </dependency>
    <dependency>
        <groupId>org.example</groupId>
        <artifactId>grpc-api</artifactId>
        <version>${project.version}</version>
    </dependency>
</dependencies>
```

> ⚠️ 新手提示：`grpc-spring-boot-starter` 和 `grpc-server-spring-boot-starter` / `grpc-client-spring-boot-starter` 是同一个 library 的不同模块。Server 项目只用 server starter，Client 项目只用 client starter。不要一股脑全引——server starter 默认在 9090 端口起 gRPC 服务，client starter 不出端口。

### 3.3 proto 文件

```protobuf
// grpc-api/src/main/proto/order.proto
syntax = "proto3";
package com.example.grpc;
option java_multiple_files = true;

service OrderService {
  // ① Unary——一问一答
  rpc GetOrder(GetOrderRequest) returns (Order);

  // ② Server Streaming——一问多答
  rpc WatchOrders(WatchRequest) returns (stream Order);

  // ③ Client Streaming——多问一答
  rpc BatchCreateOrders(stream CreateOrderRequest) returns (BatchResult);

  // ④ Bidirectional Streaming——多问多答
  rpc ProcessOrders(stream OrderRequest) returns (stream OrderResponse);
}

message Order {
  int64 order_id = 1;
  string product_name = 2;
  double amount = 3;
  string status = 4;
}

message GetOrderRequest { int64 order_id = 1; }
message WatchRequest { int64 user_id = 1; }
message CreateOrderRequest {
  string product_name = 1;
  double amount = 2;
}
message BatchResult {
  int32 success_count = 1;
  int32 fail_count = 2;
}
message OrderRequest { int64 order_id = 1; }
message OrderResponse {
  int64 order_id = 1;
  string result = 2;
}
```

### 3.4 配置文件

Server 的 `application.yml`：

```yaml
grpc:
  server:
    port: 9090                    # gRPC 服务端口——默认 9090
spring:
  application:
    name: grpc-server
```

Client 的 `application.yml`：

```yaml
grpc:
  client:
    order-service:               # 给这个 gRPC 客户端起个名字——下面会用
      address: static://localhost:9090  # 直连模式——static://IP:Port
      negotiation-type: plaintext       # 明文——生产用 TLS
spring:
  application:
    name: grpc-client
server:
  port: 8080                     # REST Controller 的端口——和 gRPC 不冲突
```

## 🏗️ 第四步：四种 RPC 模式全部写一遍

### 4.1 Unary —— 一问一答

最常用的模式——客户端发一个请求，服务端返回一个响应。和 REST 的 GET / POST 一样简单。

Server 端实现：

```java
// grpc-server——@GrpcService 暴露 gRPC 服务
@GrpcService
public class OrderServiceImpl extends OrderServiceGrpc.OrderServiceImplBase {

    // 模拟数据库
    private final Map<Long, Order> orderDB = new ConcurrentHashMap<>();

    @Override
    public void getOrder(GetOrderRequest request,
                         StreamObserver<Order> responseObserver) {

        Order order = orderDB.get(request.getOrderId());

        if (order == null) {
            // gRPC 的错误处理——用 Status 抛异常
            responseObserver.onError(
                Status.NOT_FOUND
                    .withDescription("订单不存在: " + request.getOrderId())
                    .asRuntimeException()
            );
            return;
        }

        // 发送响应
        responseObserver.onNext(order);
        // 告诉客户端——"我说完了"
        responseObserver.onCompleted();
    }
}
```

<strong>StreamObserver 三个方法详解</strong>：

| 方法 | 何时调用 | 作用 |
|------|------|------|
| `onNext(response)` | 每产生一个响应时 | 发送一条消息给客户端——Unary 只调一次 |
| `onCompleted()` | 所有响应都发完了 | 关闭连接——告诉客户端"我讲完了" |
| `onError(throwable)` | 出现错误时 | 中断连接——告诉客户端"出问题了"并带上异常信息 |

Client 端调用：

```java
@RestController
@RequestMapping("/api/order")
public class OrderController {

    // @GrpcClient 注入 gRPC 客户端——和 Dubbo 的 @DubboReference 一个意思
    @GrpcClient("order-service")
    private OrderServiceGrpc.OrderServiceBlockingStub blockingStub;
    // BlockingStub = 同步调用——阻塞等待响应
    // OrderServiceStub = 异步调用——返回 StreamObserver

    @GetMapping("/{orderId}")
    public Map<String, Object> getOrder(@PathVariable Long orderId) {
        try {
            Order order = blockingStub
                    .withDeadlineAfter(3, TimeUnit.SECONDS)  // 3s 超时
                    .getOrder(GetOrderRequest.newBuilder()
                            .setOrderId(orderId)
                            .build());

            return Map.of("orderId", order.getOrderId(),
                    "productName", order.getProductName(),
                    "amount", order.getAmount());
        } catch (StatusRuntimeException e) {
            return Map.of("error", e.getStatus().getDescription());
        }
    }
}
```

<strong>三种 Stub（调用方式）</strong>：

| Stub 类型 | 调用方式 | 适用场景 |
|------|------|------|
| `BlockingStub` | 同步——等返回才往下走 | REST Controller 中——HTTP 请求本身就是同步的 |
| `Stub`（async） | 异步——返回 `StreamObserver` | 不阻塞当前线程——需要组合多个 gRPC 调用时 |
| `FutureStub` | 异步——返回 `ListenableFuture` | 和 Java 的 CompletableFuture 配合 |

### 4.2 Server Streaming —— 一问多答

需求：客户端发一个 `userId`，服务端把该用户的订单逐条推回来——像是服务器在"直播"数据库中的订单。

Server 端实现：

```java
@Override
public void watchOrders(WatchRequest request,
                        StreamObserver<Order> responseObserver) {

    // 从数据库查出该用户的订单——逐条返回
    List<Order> userOrders = orderDB.values().stream()
            .filter(o -> o.getUserId() == request.getUserId())
            .toList();

    for (Order order : userOrders) {
        // 每条订单调一次 onNext——客户端收到一条
        responseObserver.onNext(order);
        try {
            Thread.sleep(500); // 模拟间隔——实际场景可能是消息队列逐条推送
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    // 全部发完了——通知客户端
    responseObserver.onCompleted();
}
```

Client 端调用：

```java
@GetMapping("/watch/{userId}")
public List<Map<String, Object>> watchOrders(@PathVariable Long userId) {
    List<Map<String, Object>> results = new ArrayList<>();

    // 用 Iterator 消费服务端的流——BlockingStub 自动转成 Iterator
    Iterator<Order> iterator = blockingStub
            .withDeadlineAfter(10, TimeUnit.SECONDS)
            .watchOrders(WatchRequest.newBuilder()
                    .setUserId(userId)
                    .build());

    while (iterator.hasNext()) {
        Order order = iterator.next();
        results.add(Map.of(
                "orderId", order.getOrderId(),
                "productName", order.getProductName()
        ));
    }
    // iterator.hasNext() 会在服务端调 onCompleted() 时返回 false
    return results;
}
```

<strong>客户端看到的效果</strong>：服务端每 `onNext` 一次，客户端的 `iterator.hasNext()` 返回 `true`，`iterator.next()` 返回最新一条。服务端 `onCompleted()` 后——`iterator.hasNext()` 返回 `false`，循环结束。

### 4.3 Client Streaming —— 多问一答

需求：客户端发一组创建订单的请求——全部发完后服务端返回一个批量操作的结果。

Server 端实现：

```java
@Override
public StreamObserver<CreateOrderRequest> batchCreateOrders(
        StreamObserver<BatchResult> responseObserver) {

    // 返回一个 StreamObserver——客户端通过它发送消息
    return new StreamObserver<CreateOrderRequest>() {

        private int successCount = 0;
        private int failCount = 0;

        @Override
        public void onNext(CreateOrderRequest request) {
            // 客户端每发一条——服务端收到就处理
            try {
                createOrder(request);   // 实际业务逻辑
                successCount++;
            } catch (Exception e) {
                failCount++;
            }
        }

        @Override
        public void onError(Throwable t) {
            // 客户端发送过程中出了错
            System.err.println("客户端发送出错: " + t.getMessage());
        }

        @Override
        public void onCompleted() {
            // 客户端说"我发完了"——服务端此时返回汇总结果
            BatchResult result = BatchResult.newBuilder()
                    .setSuccessCount(successCount)
                    .setFailCount(failCount)
                    .build();
            responseObserver.onNext(result);
            responseObserver.onCompleted();
        }
    };
}
```

Client 端调用：

```java
@PostMapping("/batch-create")
public Map<String, Object> batchCreate(@RequestBody List<Map<String, Object>> orders) {
    // 创建 StreamObserver——服务端会返回一个来接收客户端的数据流
    StreamObserver<CreateOrderRequest> requestObserver =
            blockingStub.batchCreateOrders(
                new StreamObserver<BatchResult>() {
                    @Override
                    public void onNext(BatchResult result) {
                        // 服务端处理完后返回汇总结果
                        System.out.printf("批量创建完成: 成功%d, 失败%d%n",
                                result.getSuccessCount(), result.getFailCount());
                    }

                    @Override
                    public void onError(Throwable t) {
                        System.err.println("批量创建出错: " + t.getMessage());
                    }

                    @Override
                    public void onCompleted() {
                        System.out.println("批量创建流关闭");
                    }
                });

    // 逐条发送——每条都是一个 CreateOrderRequest
    for (Map<String, Object> order : orders) {
        requestObserver.onNext(CreateOrderRequest.newBuilder()
                .setProductName((String) order.get("productName"))
                .setAmount(((Number) order.get("amount")).doubleValue())
                .build());
    }

    // 全部发完——通知服务端
    requestObserver.onCompleted();

    return Map.of("status", "sent", "count", orders.size());
}
```

### 4.4 Bidirectional Streaming —— 多问多答

需求：客户端和服务端可以随时互相发消息——像一个聊天室。这里做一个订单处理流水线——客户端发订单号，服务端逐条处理逐条返回结果。

Server 端实现：

```java
@Override
public StreamObserver<OrderRequest> processOrders(
        StreamObserver<OrderResponse> responseObserver) {

    return new StreamObserver<OrderRequest>() {

        @Override
        public void onNext(OrderRequest request) {
            // 客户端发来一个订单请求——即时处理并回复
            OrderResponse response = processAndReply(request.getOrderId());
            responseObserver.onNext(response);  // 每条都立即回复
        }

        @Override
        public void onError(Throwable t) {
            responseObserver.onError(t);  // 把错误传回客户端
        }

        @Override
        public void onCompleted() {
            responseObserver.onCompleted();  // 双向关闭
        }
    };
}

private OrderResponse processAndReply(long orderId) {
    return OrderResponse.newBuilder()
            .setOrderId(orderId)
            .setResult(orderDB.containsKey(orderId) ? "processed" : "not_found")
            .build();
}
```

Client 端调用：

```java
@PostMapping("/process")
public void processOrders(@RequestBody List<Long> orderIds) {
    CountDownLatch latch = new CountDownLatch(orderIds.size());

    StreamObserver<OrderRequest> requestObserver =
            // 这里用 asyncStub——不用 BlockingStub，因为两边都发消息
            asyncStub.processOrders(new StreamObserver<OrderResponse>() {

                @Override
                public void onNext(OrderResponse response) {
                    System.out.printf("收到处理结果: orderId=%d, result=%s%n",
                            response.getOrderId(), response.getResult());
                    latch.countDown();  // 收到一条——计数器减一
                }

                @Override
                public void onError(Throwable t) {
                    System.err.println("处理出错: " + t.getMessage());
                    while (latch.getCount() > 0) latch.countDown();  // 释放锁
                }

                @Override
                public void onCompleted() {
                    System.out.println("全部处理完成");
                }
            });

    // 逐条发送请求——服务端逐条处理并回复
    for (Long orderId : orderIds) {
        requestObserver.onNext(OrderRequest.newBuilder()
                .setOrderId(orderId)
                .build());
    }

    requestObserver.onCompleted();

    try {
        latch.await(30, TimeUnit.SECONDS);  // 等所有响应返回——最多 30s
    } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
    }
}
```

## 第五步：拦截器与异常处理

### 5.1 Server 端拦截器——认证/日志/限流

```java
@GrpcGlobalInterceptor
public class AuthInterceptor implements ServerInterceptor {

    @Override
    public <ReqT, RespT> ServerCall.Listener<ReqT> interceptCall(
            ServerCall<ReqT, RespT> call,
            Metadata headers,
            ServerCallHandler<ReqT, RespT> next) {

        // 从 Metadata 中提取 Token
        String token = headers.get(
                Metadata.Key.of("Authorization", Metadata.ASCII_STRING_MARSHALLER));

        if (token == null || !token.startsWith("Bearer ")) {
            // 没 Token 或格式不对——直接拒绝
            call.close(Status.UNAUTHENTICATED
                    .withDescription("缺少 Authorization Token"), new Metadata());
            return new ServerCall.Listener<>() {};  // 空 Listener——不处理
        }

        System.out.println("收到 gRPC 请求: " + call.getMethodDescriptor().getFullMethodName());

        // 放行——调下一个拦截器或真正的服务实现
        return next.startCall(call, headers);
    }
}
```

### 5.2 Client 端拦截器——自动注入 Token

```java
@GrpcGlobalClientInterceptor
public class TokenClientInterceptor implements ClientInterceptor {

    @Override
    public <ReqT, RespT> ClientCall<ReqT, RespT> interceptCall(
            MethodDescriptor<ReqT, RespT> method,
            CallOptions callOptions,
            Channel next) {

        return new ForwardingClientCall.SimpleForwardingClientCall<>(
                next.newCall(method, callOptions)) {

            @Override
            public void start(Listener<RespT> responseListener, Metadata headers) {
                // 每个发出的 gRPC 请求——自动附上 Token
                headers.put(
                        Metadata.Key.of("Authorization", Metadata.ASCII_STRING_MARSHALLER),
                        "Bearer " + getServiceToken());
                super.start(responseListener, headers);
            }
        };
    }

    private String getServiceToken() {
        // 从配置或缓存中拿 Token——这里简化
        return "your-service-token";
    }
}
```

### 5.3 异常处理——gRPC Status 的完整错误码

```java
// gRPC 的标准状态码——不用自己定义错误码
// Server 端各种错误情况：

// ① 资源不存在——HTTP 404
responseObserver.onError(
    Status.NOT_FOUND.withDescription("订单不存在").asRuntimeException());

// ② 参数不合法——HTTP 400
responseObserver.onError(
    Status.INVALID_ARGUMENT.withDescription("orderId 不能为空").asRuntimeException());

// ③ 未授权——HTTP 401
responseObserver.onError(
    Status.UNAUTHENTICATED.withDescription("Token 已过期").asRuntimeException());

// ④ 权限不足——HTTP 403
responseObserver.onError(
    Status.PERMISSION_DENIED.withDescription("没有访问该订单的权限").asRuntimeException());

// ⑤ 服务端内部错——HTTP 500
responseObserver.onError(
    Status.INTERNAL.withDescription("数据库连接失败").asRuntimeException());

// ⑥ 服务端太忙——HTTP 429
responseObserver.onError(
    Status.RESOURCE_EXHAUSTED.withDescription("请求过多，请稍后重试").asRuntimeException());
```

| gRPC Status | HTTP 对应 | 使用场景 |
|------|:---:|------|
| `OK` | 200 | 正常——不抛异常 |
| `NOT_FOUND` | 404 | 查不到资源 |
| `INVALID_ARGUMENT` | 400 | 参数错误 |
| `UNAUTHENTICATED` | 401 | 未登录/Token 过期 |
| `PERMISSION_DENIED` | 403 | 没权限 |
| `INTERNAL` | 500 | 服务端崩了 |
| `UNAVAILABLE` | 503 | 服务不可用/熔断 |
| `DEADLINE_EXCEEDED` | 504 | 超时——Deadline 到了 |
| `RESOURCE_EXHAUSTED` | 429 | 被限流了 |

## 第六步：Deadline 超时传播

```java
// 场景：A 调 B，B 调 C——如果 B 超时了，C 也该停止执行
// gRPC Deadline 的传播机制：下游继承上游的 Deadline

// A 调用 B 时设 Deadline = 3s
blockingStub.withDeadlineAfter(3, TimeUnit.SECONDS)
        .getOrder(request);
    // B 收到请求——拿到 Deadline = 当前时间 + 3s
    // B 调用 C 时——必须用同一个 Deadline（已经过了 1s，剩余 2s）
    // C 收到请求——拿到 Deadline = 当前时间 + 2s
    // C 超过 2s 没返回——直接抛 DEADLINE_EXCEEDED

// B 的代码——正确传播 Deadline
@Override
public void getOrder(GetOrderRequest request,
                     StreamObserver<Order> responseObserver) {
    // 从当前 gRPC 上下文中获取 Deadline
    Deadline deadline = Context.current().getDeadline();

    // 调用下游时传递 Deadline
    Order result = downstreamStub
            .withDeadline(deadline)  // ← 传递上游的 Deadline
            .getOrder(request);

    responseObserver.onNext(result);
    responseObserver.onCompleted();
}
```

<strong>如果不传播 Deadline</strong>——上游 3 秒超时了，下游还在跑。大 BUG。

## 第七步：FAQ

| 问题 | 原因 | 解决 |
|------|------|------|
| `@GrpcClient` 注入的 Stub 为 null | `grpc.client.xxx.address` 没配——gRPC 找不到目标 | 检查 yml 中 `grpc.client.order-service.address` 是否正确 |
| `io.grpc.StatusRuntimeException: UNAVAILABLE` | 连不上 gRPC Server——端口没开或 Server 没启动 | `telnet localhost 9090`——确认端口可连通 |
| 客户端收到 `CANCELLED` 但服务端日志正常 | 客户端超时后取消请求——服务端还在处理导致的 | 设置合理的 `withDeadlineAfter()`——不要设太小 |
| `StreamObserver.onNext()` 在 `onCompleted()` 之后调 | Unary 模式下——onNext 必须在 onCompleted 之前 | 用 `responseObserver.onNext(resp); responseObserver.onCompleted();`——顺序不能反 |
| proto 编译后找不到生成的 Java 类 | Maven 插件没跑——target/generated-sources 不在 classpath | 确认 protobuf-maven-plugin 配置正确 + `mvn clean compile` |

## 🎯 总结

1. <strong>四个注解/类搞定 gRPC</strong>：`@GrpcService`（暴露服务，替代手动 `ServerBuilder`）、`@GrpcClient`（注入客户端 Stub，替代手动 `ManagedChannel`）、`StreamObserver`（处理流的回调——onNext/onCompleted/onError）、`Status`（错误码——替代 HTTP 状态码）。

2. <strong>四种模式三种 Stub</strong>：Unary（一问一答）用 `BlockingStub`，Server Streaming（一问多答）用 `BlockingStub` + Iterator，Client Streaming（多问一答）返回 `StreamObserver`，BiDi Streaming（多问多答）双向 `StreamObserver`。

3. <strong>拦截器有两个位置</strong>：`ServerInterceptor`（认证、日志、限流——在服务端拦截所有进入的请求）、`ClientInterceptor`（注入 Token、传播 Deadline——在客户端拦截所有发出的请求）。

4. <strong>Deadline 必须传播</strong>：A 调 B 调 C——如果 A 的超时是 3s，B 调用 C 时必须传递同一个 Deadline。否则 A 等超时了 C 还在跑——雪崩就是这样开始的。

> 📖 <strong>下一步阅读</strong>：SpringBoot 的操作搞定了。但在实际微服务项目中——proto 文件怎么组织？DTO 和 Domain 怎么转换？多个微服务之间的 proto 依赖怎么管理？继续阅读 [<strong>微服务拆分实战：以 proto 为契约</strong>]({{< relref "GrpcMicroservice.md" >}})。
