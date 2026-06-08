---
title: "gRPC Gateway 与生产环境部署"
date: 2022-12-01T08:00:00+00:00
tags: ["微服务中间件"]
categories: ["RPC框架"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "gRPC 调通了——前端怎么调？gRPC-Gateway 把 gRPC 转成 HTTP JSON、Envoy 负载均衡、gRPC 健康检查协议、TLS/mTLS 加密、JWT 认证——附带完整的生产环境 Docker Compose 部署方案。"
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

# gRPC Gateway 与生产环境部署

> 📖 <strong>前置阅读</strong>：本文假设读者已完成 gRPC 服务的开发和微服务拆分。如果还不熟悉，建议先阅读 [<strong>SpringBoot gRPC 全操作指南</strong>]({{< relref "SpringBootGrpc.md" >}}) 和 [<strong>微服务拆分实战：以 proto 为契约</strong>]({{< relref "GrpcMicroservice.md" >}})。

## 一、⚡ gRPC 最大的问题：浏览器不支持

你花了两周把微服务之间的通信全换成了 gRPC——性能翻了 3 倍，Protobuf 二进制传输省了 60% 带宽。看起来很完美。

然后前端同事找来了：<strong>"你的接口怎么调？Postman 发 HTTP 请求连不上。"</strong>

这就是 gRPC 最大的现实问题——<strong>gRPC 基于 HTTP/2，浏览器不直接支持 gRPC 协议</strong>。你在浏览器里 `fetch('http://localhost:9090/...')` 是调不通的——浏览器不会说 gRPC。

解决方案是<strong>gRPC-Gateway</strong>——在 gRPC 服务前面放一个网关，对外提供标准的 HTTP RESTful JSON 接口，对内转成 gRPC 调用：

```
浏览器/移动端/curl（HTTP/1.1 JSON）
     ↓
[gRPC-Gateway / Envoy / grpc-web]  ← 协议转换层
     ↓ gRPC（HTTP/2 Protobuf）
[gRPC Server]
```

## 二、🔌 方案选择：三种网关方案

| 方案 | 原理 | 适用场景 | 复杂度 |
|------|------|------|:---:|
| <strong>gRPC-Gateway</strong> | 从 proto 自动生成反向代理代码——HTTP JSON ↔ gRPC 转换 | gRPC 服务需要同时支持 HTTP JSON 和 gRPC 调用方 | 中 |
| <strong>Envoy gRPC-JSON Transcoder</strong> | Envoy 代理层做协议转换——不需要修改代码 | 有服务网格——统一的入口网关 | 中 |
| <strong>grpc-web + Envoy</strong> | 浏览器用 grpc-web 协议（HTTP/1.1），Envoy 转成 gRPC | 前端直接在浏览器中调 gRPC（不需要 REST 包装） | 高 |

本文重点讲<strong>方案一 gRPC-Gateway</strong>——它最直接、不需要额外的代理基础设施、和 SpringBoot 整合最简单。

## 三、🏗️ gRPC-Gateway 实战——用 proto 自动生成 HTTP 网关

### 3.1 原理

```
.proto 文件中加 HTTP 路由注解
     ↓
protoc-gen-grpc-gateway 插件自动生成网关代码
     ↓
网关代码就是一个 SpringBoot 服务——对外暴 HTTP/JSON，对内调 gRPC
     ↓
前端调 http://localhost:8080/api/users/1 → 网关调 gRPC localhost:9090 → 返回 JSON
```

### 3.2 proto 文件中定义 HTTP 路由

```protobuf
// proto-user/src/main/proto/user_service.proto
// 在原有 proto 基础上加上 HTTP 路由注解
syntax = "proto3";
package user;

option java_multiple_files = true;
option java_package = "com.example.user";

import "google/api/annotations.proto";  // ← gRPC-Gateway 的 HTTP 注解
import "common/common.proto";

message User {
  int64 user_id = 1;
  string user_name = 2;
  string email = 3;
  string phone = 4;
  int32 status = 5;
  int64 created_at = 6;
}

message GetUserRequest {
  int64 user_id = 1;
}

message BatchGetUserRequest {
  repeated int64 user_ids = 1;
}

message BatchGetUserResponse {
  repeated User users = 1;
}

message ListUsersRequest {
  string keyword = 1;
  common.PageRequest page = 2;
}

message ListUsersResponse {
  repeated User users = 1;
  common.PageResponse page_info = 2;
}

service UserService {
  // 每个 RPC 方法上加 HTTP 路由注解——定义它对外暴露的 REST 路径
  rpc GetUser(GetUserRequest) returns (User) {
    option (google.api.http) = {
      get: "/api/users/{user_id}"     // ← HTTP GET /api/users/1 → gRPC GetUser
    };
  }

  rpc BatchGetUsers(BatchGetUserRequest) returns (BatchGetUserResponse) {
    option (google.api.http) = {
      post: "/api/users/batch"        // ← HTTP POST /api/users/batch → gRPC BatchGetUsers
      body: "*"                       // ← 整个请求体作为 gRPC 请求
    };
  }

  rpc ListUsers(ListUsersRequest) returns (ListUsersResponse) {
    option (google.api.http) = {
      get: "/api/users"              // ← HTTP GET /api/users?keyword=xxx&page=1&page_size=20
    };
  }
}
```

<strong>HTTP 注解语法规则</strong>：

| 注解写法 | HTTP 映射 | 示例 |
|------|------|------|
| `get: "/api/users/{user_id}"` | GET 请求——`{user_id}` 对应 proto 中的字段 | `GET /api/users/1` |
| `post: "/api/users" body: "*"` | POST 请求——请求体映射到整个 gRPC 请求 | `POST /api/users {"userName":"张三"}` |
| `post: "/api/users" body: "name"` | POST 请求——只映射指定字段 | `POST /api/users {"name":"张三"}` → gRPC 的 name 字段 |
| `delete: "/api/users/{user_id}"` | DELETE 请求 | `DELETE /api/users/1` |

> ⚠️ 新手提示：`google/api/annotations.proto` 不是 Protobuf 自带的——需要单独引入 `googleapis` 依赖。它在 [googleapis/googleapis](https://github.com/googleapis/googleapis) 仓库中——Maven 插件需要配置 proto 源路径。

### 3.3 Maven 插件配置——生成网关代码

```xml
<!-- proto-user/pom.xml——增加 gRPC-Gateway 的代码生成 -->
<build>
    <plugins>
        <plugin>
            <groupId>org.xolstice.maven.plugins</groupId>
            <artifactId>protobuf-maven-plugin</artifactId>
            <version>0.6.1</version>
            <configuration>
                <!-- protoc 编译器 -->
                <protocArtifact>com.google.protobuf:protoc:3.25.0:exe:${os.detected.classifier}</protocArtifact>
                <!-- 额外的 proto 导入路径——google/api/annotations.proto 所在目录 -->
                <protoSourceRoot>${project.basedir}/src/main/proto</protoSourceRoot>
                <additionalProtoPathElements>
                    <additionalProtoPathElement>${project.basedir}/../googleapis</additionalProtoPathElement>
                </additionalProtoPathElements>
                <!-- gRPC-Java 插件——生成 gRPC Stub -->
                <pluginId>grpc-java</pluginId>
                <pluginArtifact>io.grpc:protoc-gen-grpc-java:1.60.0:exe:${os.detected.classifier}</pluginArtifact>
            </configuration>
        </plugin>
    </plugins>
</build>
```

实际上，在纯 Java 生态中——很多团队选择<strong>手写网关 Controller</strong>而不是用代码生成。因为 gRPC-Gateway 的 proto 注解插件链在 Java 中不如 Go 生态成熟。下面是两种方案的对比：

| 方案 | 优点 | 缺点 |
|------|------|------|
| <strong>protoc-gen-grpc-gateway 自动生成</strong> | proto 即文档——改 proto 自动更新网关 | 插件链复杂——Java 生态支持不如 Go |
| <strong>手写 SpringBoot REST Controller</strong> | 简单直接——所有 Java 开发者都会 | proto 和 Controller 可能不同步 |

<strong>对于 Java 项目——推荐手写 Controller</strong>。proto 文件已经定义了服务契约——手写 Controller 保证网关和契约一致。接下来用这个方案。

### 3.4 手写 gRPC 网关 Controller

```java
// gateway/src/main/java/.../controller/UserGatewayController.java
@RestController
@RequestMapping("/api/users")
public class UserGatewayController {

    // 网关本身也是一个 gRPC 客户端——调后端的 gRPC 服务
    @GrpcClient("user-service")
    private UserServiceGrpc.UserServiceBlockingStub userStub;

    // GET /api/users/1 → gRPC GetUser
    @GetMapping("/{userId}")
    public ResponseEntity<Map<String, Object>> getUser(@PathVariable Long userId) {
        try {
            User user = userStub
                    .withDeadlineAfter(3, TimeUnit.SECONDS)
                    .getUser(GetUserRequest.newBuilder()
                            .setUserId(userId)
                            .build());

            return ResponseEntity.ok(Map.of(
                    "userId", user.getUserId(),
                    "userName", user.getUserName(),
                    "email", user.getEmail(),
                    "phone", user.getPhone(),
                    "status", user.getStatus(),
                    "createdAt", user.getCreatedAt()
            ));

        } catch (StatusRuntimeException e) {
            return switch (e.getStatus().getCode()) {
                case NOT_FOUND ->
                    ResponseEntity.status(404).body(Map.of("error", "用户不存在"));
                case INVALID_ARGUMENT ->
                    ResponseEntity.status(400).body(Map.of("error", "参数错误"));
                case DEADLINE_EXCEEDED ->
                    ResponseEntity.status(504).body(Map.of("error", "请求超时"));
                default ->
                    ResponseEntity.status(500).body(Map.of("error", "服务内部错误"));
            };
        }
    }

    // GET /api/users?keyword=xxx&page=1&pageSize=20 → gRPC ListUsers
    @GetMapping
    public ResponseEntity<Map<String, Object>> listUsers(
            @RequestParam(defaultValue = "") String keyword,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int pageSize) {

        ListUsersResponse response = userStub
                .withDeadlineAfter(5, TimeUnit.SECONDS)
                .listUsers(ListUsersRequest.newBuilder()
                        .setKeyword(keyword)
                        .setPage(com.example.common.PageRequest.newBuilder()
                                .setPage(page)
                                .setPageSize(pageSize)
                                .build())
                        .build());

        List<Map<String, Object>> users = response.getUsersList().stream()
                .map(u -> Map.<String, Object>of(
                        "userId", u.getUserId(),
                        "userName", u.getUserName(),
                        "email", u.getEmail()))
                .toList();

        return ResponseEntity.ok(Map.of(
                "users", users,
                "total", response.getPageInfo().getTotal(),
                "page", response.getPageInfo().getPage(),
                "pageSize", response.getPageInfo().getPageSize()
        ));
    }

    // POST /api/users/batch → gRPC BatchGetUsers
    @PostMapping("/batch")
    public ResponseEntity<List<Map<String, Object>>> batchGetUsers(
            @RequestBody List<Long> userIds) {

        BatchGetUserResponse response = userStub
                .batchGetUsers(BatchGetUserRequest.newBuilder()
                        .addAllUserIds(userIds)
                        .build());

        List<Map<String, Object>> users = response.getUsersList().stream()
                .map(u -> Map.<String, Object>of(
                        "userId", u.getUserId(),
                        "userName", u.getUserName()))
                .toList();

        return ResponseEntity.ok(users);
    }
}
```

<strong>gRPC Status → HTTP 状态码的映射规则</strong>：

```java
// 你可以抽一个工具方法——统一转换
public class GrpcStatusConverter {

    public static ResponseEntity<Map<String, Object>> toResponse(
            StatusRuntimeException e) {
        HttpStatus httpStatus = switch (e.getStatus().getCode()) {
            case OK -> HttpStatus.OK;
            case NOT_FOUND -> HttpStatus.NOT_FOUND;
            case INVALID_ARGUMENT -> HttpStatus.BAD_REQUEST;
            case UNAUTHENTICATED -> HttpStatus.UNAUTHORIZED;
            case PERMISSION_DENIED -> HttpStatus.FORBIDDEN;
            case DEADLINE_EXCEEDED -> HttpStatus.GATEWAY_TIMEOUT;
            case RESOURCE_EXHAUSTED -> HttpStatus.TOO_MANY_REQUESTS;
            case UNAVAILABLE -> HttpStatus.SERVICE_UNAVAILABLE;
            case UNIMPLEMENTED -> HttpStatus.NOT_IMPLEMENTED;
            default -> HttpStatus.INTERNAL_SERVER_ERROR;
        };

        return ResponseEntity.status(httpStatus)
                .body(Map.of(
                        "code", e.getStatus().getCode().name(),
                        "message", e.getStatus().getDescription()
                ));
    }
}
```

## 四、⚖️ 负载均衡

### 4.1 问题：UserService 部署了 3 个实例——请求发给谁？

gRPC 基于 HTTP/2 长连接——客户端和服务端建立连接后维持复用。这和 REST 的短连接不同——传统的 Nginx `upstream` 轮询对 gRPC 不太合适：

```
REST（短连接）：
  Client → 每请求建立 TCP → Nginx → 轮询到某个实例 → 断开
  Nginx 天然能做到每个请求分到不同实例

gRPC（长连接）：
  Client → 一次 TCP 握手 → 一直复用这个连接
  如果不强制重连——所有请求一直打到同一个实例
```

### 4.2 客户端负载均衡——gRPC 原生支持

<strong>gRPC 推荐客户端侧负载均衡</strong>——客户端自己知道后端有哪些实例，自己决定发给谁：

```yaml
# gRPC Client 配置——不用 static://，用服务发现
grpc:
  client:
    user-service:
      # 方式一：DNS 解析——给多个 A 记录
      address: dns:///user-service.internal:9090
      # 方式二：static 多地址——客户端侧轮询
      address: static://10.0.1.1:9090,10.0.1.2:9090,10.0.1.3:9090
      negotiation-type: plaintext
      # 负载均衡策略
      default-load-balancing-policy: round_robin
```

<strong>gRPC 支持的负载均衡策略</strong>：

| 策略 | 行为 | 适用场景 |
|------|------|------|
| `round_robin` | 轮流发给每个可用实例 | 默认选择——简单有效 |
| `pick_first` | 选第一个可用实例——一直用它直到它挂了 | 单实例开发环境 |
| `weighted_round_robin` | 按权重轮询——权重由服务端报告 | 实例配置不均——如 4C8G 和 8C16G 混合部署 |

### 4.3 服务端负载均衡——Envoy / Nginx 代理

如果要用中间代理（因为公司要求统一网关或需要 TLS 终结）——Nginx 1.13.10+ 支持 gRPC：

```nginx
# nginx.conf——gRPC 反向代理
server {
    listen 443 http2;  # ← gRPC 必须 HTTP/2——listen 后面加 http2

    server_name api.example.com;

    # TLS 证书—Nginx 做 TLS 终结
    ssl_certificate     /etc/nginx/certs/server.crt;
    ssl_certificate_key /etc/nginx/certs/server.key;

    location /com.example.user.UserService/ {
        # grpc_pass 是 gRPC 专用的代理指令
        grpc_pass grpc://user-service-backend:9090;
        grpc_set_header Host $host;
    }
}

upstream user-service-backend {
    server 10.0.1.1:9090;
    server 10.0.1.2:9090;
    server 10.0.1.3:9090;
}
```

对于更复杂的场景——Envoy 是 gRPC 社区推荐的代理：

```yaml
# envoy.yaml——Envoy 作为 gRPC 代理
static_resources:
  listeners:
  - name: grpc_listener
    address:
      socket_address: { address: 0.0.0.0, port_value: 443 }
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: grpc_ingress
          codec_type: AUTO
          route_config:
            name: local_route
            virtual_hosts:
            - name: backend
              domains: ["*"]
              routes:
              - match: { prefix: "/" }
                route:
                  cluster: user_service
                  max_grpc_timeout: 5s
          http_filters:
          - name: envoy.filters.http.router
  clusters:
  - name: user_service
    type: STRICT_DNS
    lb_policy: ROUND_ROBIN
    http2_protocol_options: {}  # ← gRPC 需要 HTTP/2
    load_assignment:
      cluster_name: user_service
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: { address: user-service-1, port_value: 9090 }
        - endpoint:
            address:
              socket_address: { address: user-service-2, port_value: 9090 }
```

## 五、🏥 健康检查

### 5.1 gRPC 健康检查协议

gRPC 有一套标准的健康检查协议——定义在 `grpc.health.v1.Health` 中：

```protobuf
// grpc/health/v1/health.proto——gRPC 官方提供的健康检查协议
// 不需要自己写——gRPC 库自带
// proto 内容大致如下：
syntax = "proto3";
package grpc.health.v1;

service Health {
  rpc Check(HealthCheckRequest) returns (HealthCheckResponse);
  rpc Watch(HealthCheckRequest) returns (stream HealthCheckResponse); // 服务端流——持续推送状态
}

message HealthCheckRequest {
  string service = 1;  // 空字符串代表检查整个服务——不是特定 RPC 方法
}

message HealthCheckResponse {
  enum ServingStatus {
    UNKNOWN = 0;
    SERVING = 1;
    NOT_SERVING = 2;
  }
  ServingStatus status = 1;
}
```

### 5.2 SpringBoot gRPC 中启用健康检查

```xml
<!-- 增加 grpc-services 依赖——包含健康检查的实现 -->
<dependency>
    <groupId>io.grpc</groupId>
    <artifactId>grpc-services</artifactId>
</dependency>
```

```java
// 只需要加一个 Bean——grpc-spring-boot-starter 自动把它暴露为 gRPC 服务
@Configuration
public class HealthCheckConfig {

    @Bean
    public HealthStatusService healthStatusService() {
        // 返回 SERVING 状态
        HealthStatusService service = new HealthStatusService();
        service.setStatus("", HealthCheckResponse.ServingStatus.SERVING);
        return service;
    }
}
```

```bash
# 用 grpc_health_probe 检查——Kubernetes 中用这个做 liveness probe
grpc_health_probe -addr=localhost:9090
# 输出：status: SERVING
```

```yaml
# Kubernetes Deployment 中使用 gRPC 健康检查
apiVersion: apps/v1
kind: Deployment
metadata:
  name: user-service
spec:
  template:
    spec:
      containers:
      - name: user-service
        image: user-service:1.0.0
        ports:
        - containerPort: 9090
        livenessProbe:
          exec:
            command:
            - "/bin/grpc_health_probe"
            - "-addr=:9090"
          initialDelaySeconds: 10
          periodSeconds: 10
        readinessProbe:
          exec:
            command:
            - "/bin/grpc_health_probe"
            - "-addr=:9090"
          initialDelaySeconds: 5
          periodSeconds: 5
```

## 六、🔒 TLS 与认证

### 6.1 TLS——加密传输

gRPC 生产环境必须开 TLS——否则所有数据明文传输。

```yaml
# Server 端——启用 TLS
grpc:
  server:
    port: 9090
    security:
      enabled: true
      certificate-chain: /etc/grpc/certs/server.crt   # 服务端证书
      private-key: /etc/grpc/certs/server.key          # 服务端私钥
```

```yaml
# Client 端——信任服务端证书
grpc:
  client:
    user-service:
      address: static://user-service:9090
      security:
        enabled: true
        certificate-chain: /etc/grpc/certs/ca.crt      # CA 根证书——验证服务端
```

### 6.2 mTLS——双向认证

服务端也要验证客户端身份——适合严格的服务间通信：

```yaml
# Server 端——要求客户端提供证书
grpc:
  server:
    security:
      enabled: true
      certificate-chain: /etc/grpc/certs/server.crt
      private-key: /etc/grpc/certs/server.key
      trust-cert-collection: /etc/grpc/certs/ca.crt   # 验证客户端证书的 CA
      client-auth: REQUIRE                             # 要求客户端提供证书
```

```yaml
# Client 端——提供自己的证书
grpc:
  client:
    user-service:
      security:
        enabled: true
        certificate-chain: /etc/grpc/certs/client.crt   # 客户端自己的证书
        private-key: /etc/grpc/certs/client.key          # 客户端私钥
        trust-cert-collection: /etc/grpc/certs/ca.crt    # 验证服务端证书的 CA
```

### 6.3 JWT Token 认证

mTLS 保证了服务间通信的安全——但<strong>谁在调这个服务？</strong> 对于用户请求——需要 JWT Token 传递用户身份：

```java
// Server 端——从 Metadata 中提取并验证 JWT
@GrpcGlobalInterceptor
@Order(1)  // 最先执行——认证在鉴权之前
public class JwtAuthInterceptor implements ServerInterceptor {

    @Override
    public <ReqT, RespT> ServerCall.Listener<ReqT> interceptCall(
            ServerCall<ReqT, RespT> call,
            Metadata headers,
            ServerCallHandler<ReqT, RespT> next) {

        // ① 提取 Token
        String token = headers.get(
                Metadata.Key.of("Authorization", Metadata.ASCII_STRING_MARSHALLER));

        if (token == null || !token.startsWith("Bearer ")) {
            call.close(Status.UNAUTHENTICATED
                    .withDescription("缺少 Authorization Token"), new Metadata());
            return new ServerCall.Listener<>() {};
        }

        String jwt = token.substring(7);  // 去除 "Bearer " 前缀

        // ② 验证 JWT——提取其中的用户信息
        try {
            Claims claims = Jwts.parser()
                    .setSigningKey(SECRET_KEY)
                    .parseClaimsJws(jwt)
                    .getBody();

            // ③ 把用户信息放到 gRPC Context 中——后续的拦截器和服务实现可以拿到
            Context ctx = Context.current()
                    .withValue(USER_ID_KEY, claims.get("userId", Long.class))
                    .withValue(USER_ROLE_KEY, claims.get("role", String.class));

            return Contexts.interceptCall(ctx, call, headers, next);

        } catch (JwtException e) {
            call.close(Status.UNAUTHENTICATED
                    .withDescription("Token 无效或已过期"), new Metadata());
            return new ServerCall.Listener<>() {};
        }
    }

    // gRPC Context 的 Key——和 ThreadLocal 类似，但在异步调用链中传递
    public static final Context.Key<Long> USER_ID_KEY =
            Context.key("userId");
    public static final Context.Key<String> USER_ROLE_KEY =
            Context.key("userRole");
}
```

```java
// 在 gRPC 服务实现中获取当前用户信息
@Override
public void getOrder(GetOrderRequest request,
                     StreamObserver<Order> responseObserver) {

    // 从 gRPC Context 中拿当前用户——不过通过参数传
    Long currentUserId = JwtAuthInterceptor.USER_ID_KEY.get();

    // 用户只能查自己的订单
    if (!currentUserId.equals(request.getUserId())) {
        responseObserver.onError(
            Status.PERMISSION_DENIED
                .withDescription("只能查看自己的订单")
                .asRuntimeException());
        return;
    }
    // ... 正常业务逻辑
}
```

```java
// Client 端——发请求时自动带上 Token
@GrpcGlobalClientInterceptor
public class JwtClientInterceptor implements ClientInterceptor {

    @Override
    public <ReqT, RespT> ClientCall<ReqT, RespT> interceptCall(
            MethodDescriptor<ReqT, RespT> method,
            CallOptions callOptions,
            Channel next) {

        return new ForwardingClientCall.SimpleForwardingClientCall<>(
                next.newCall(method, callOptions)) {

            @Override
            public void start(Listener<RespT> responseListener, Metadata headers) {
                headers.put(
                        Metadata.Key.of("Authorization", Metadata.ASCII_STRING_MARSHALLER),
                        "Bearer " + generateServiceToken());
                super.start(responseListener, headers);
            }
        };
    }

    private String generateServiceToken() {
        // 服务间调用——生成 Machine-to-Machine 的 JWT
        return Jwts.builder()
                .setSubject("order-service")
                .setIssuedAt(new Date())
                .setExpiration(new Date(System.currentTimeMillis() + 300_000)) // 5 分钟
                .signWith(SECRET_KEY)
                .compact();
    }
}
```

## 七、🚀 完整生产环境部署方案

### 7.1 Docker Compose —— 一键启动全部服务

```yaml
# docker-compose.yml——生产环境最小化部署
version: '3.8'
services:

  # ===== 基础服务 =====
  # 服务发现——或者用 K8s Service 替代
  consul:
    image: consul:1.15
    ports:
      - "8500:8500"

  # ===== gRPC 微服务 =====
  user-service:
    image: user-service:1.0.0
    ports:
      - "9090:9090"
    environment:
      - SPRING_PROFILES_ACTIVE=prod
      - GRPC_SERVER_PORT=9090
      - DB_URL=jdbc:mysql://mysql:3306/user_db
    depends_on:
      - mysql
      - consul

  product-service:
    image: product-service:1.0.0
    ports:
      - "9091:9091"
    environment:
      - SPRING_PROFILES_ACTIVE=prod
      - GRPC_SERVER_PORT=9091
      - DB_URL=jdbc:mysql://mysql:3306/product_db
    depends_on:
      - mysql
      - consul

  order-service:
    image: order-service:1.0.0
    ports:
      - "9092:9092"
    environment:
      - SPRING_PROFILES_ACTIVE=prod
      - GRPC_SERVER_PORT=9092
      - GRPC_CLIENT_USER-SERVICE_ADDRESS=static://user-service:9090
      - GRPC_CLIENT_PRODUCT-SERVICE_ADDRESS=static://product-service:9091
      - DB_URL=jdbc:mysql://mysql:3306/order_db
    depends_on:
      - mysql
      - user-service
      - product-service

  # ===== gRPC 网关 =====
  gateway:
    image: gateway:1.0.0
    ports:
      - "8080:8080"               # HTTP RESTful 接口——前端调这个
    environment:
      - GRPC_CLIENT_USER-SERVICE_ADDRESS=static://user-service:9090
      - GRPC_CLIENT_ORDER-SERVICE_ADDRESS=static://order-service:9092
      - GRPC_CLIENT_PRODUCT-SERVICE_ADDRESS=static://product-service:9091
    depends_on:
      - user-service
      - product-service
      - order-service

  # ===== 数据库 =====
  mysql:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: root123
    ports:
      - "3306:3306"
    volumes:
      - mysql-data:/var/lib/mysql
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql  # 初始化库和表

  # ===== Envoy 代理（TLS 终结 + 负载均衡）=====
  envoy:
    image: envoyproxy/envoy:v1.28
    ports:
      - "443:443"                 # HTTPS——对外暴露
    volumes:
      - ./envoy.yaml:/etc/envoy/envoy.yaml
      - ./certs:/etc/envoy/certs  # TLS 证书

volumes:
  mysql-data:
```

### 7.2 生产环境应用配置

```yaml
# application-prod.yml——生产环境配置（每个服务）
grpc:
  server:
    port: ${GRPC_SERVER_PORT:9090}
    security:
      enabled: true
      certificate-chain: /etc/grpc/certs/server.crt
      private-key: /etc/grpc/certs/server.key

spring:
  datasource:
    url: ${DB_URL}
    username: ${DB_USER:root}
    password: ${DB_PASSWORD}
    hikari:
      maximum-pool-size: 20
      minimum-idle: 5
      connection-timeout: 3000

# 监控端点——Prometheus 采集
management:
  endpoints:
    web:
      exposure:
        include: health,metrics,prometheus
  metrics:
    export:
      prometheus:
        enabled: true
```

### 7.3 部署架构总览

```
                           ┌─────────────────┐
                           │  浏览器 / 移动端  │
                           └────────┬────────┘
                                    │ HTTPS
                                    ▼
                           ┌─────────────────┐
                           │  Envoy :443     │ ← TLS 终结 + 负载均衡
                           └────────┬────────┘
                                    │
            ┌───────────────────────┼───────────────────────┐
            │ gRPC                  │                       │
            ▼                       ▼                       ▼
   ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐
   │  Gateway :8080  │   │  Gateway :8080  │   │  Gateway :8080  │
   │  (HTTP → gRPC)  │   │  (HTTP → gRPC)  │   │  (HTTP → gRPC)  │
   └────────┬────────┘   └────────┬────────┘   └────────┬────────┘
            │ gRPC                  │                       │
            ▼                       ▼                       ▼
   ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐
   │  UserService    │   │  ProductService │   │  OrderService   │
   │  :9090          │   │  :9091          │   │  :9092          │
   └────────┬────────┘   └────────┬────────┘   └────────┬────────┘
            │                       │                       │
            ▼                       ▼                       ▼
   ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐
   │   User DB       │   │   Product DB    │   │   Order DB      │
   └─────────────────┘   └─────────────────┘   └─────────────────┘
```

## 八、📋 生产环境上线 Checklist

| # | 检查项 | 为什么 | 怎么做 |
|:--:|------|------|------|
| 1 | <strong>TLS 开启</strong> | 公网必须加密——明文就是送给中间人 | Server 和 Client 都配 `certificate-chain` 和 `private-key` |
| 2 | <strong>健康检查</strong> | K8s 需要知道 Pod 是否活着 | 集成 gRPC Health Check——`grpc_health_probe` |
| 3 | <strong>Deadline 超时</strong> | 不设超时——一个慢请求永久占用连接 | 每个 RPC 调用都 `withDeadlineAfter()` |
| 4 | <strong>重试策略</strong> | 网络抖动导致瞬时失败——需要自动重试 | gRPC 内置 Retry Policy——在 `ManagedChannelBuilder` 上配 |
| 5 | <strong>连接池大小</strong> | gRPC 长连接——连接太多浪费资源 | 每个后端 2-4 个连接即可——HTTP/2 多路复用 |
| 6 | <strong>Keepalive 心跳</strong> | 长连接可能被防火墙/负载均衡器断开——需要心跳保活 | `keepAliveTime=30s, keepAliveTimeout=10s, keepAliveWithoutCalls=true` |
| 7 | <strong>监控指标</strong> | 没监控——服务挂了也不知道 | gRPC 内置 Metrics + Prometheus——请求量、延迟、错误率 |
| 8 | <strong>优雅关闭</strong> | K8s 滚动更新时——直接杀进程会丢请求 | `grpc.server.shutdown-timeout=30s` + SpringBoot `server.shutdown=graceful` |
| 9 | <strong>日志中带 TraceId</strong> | 跨服务排查问题——需要全链路追踪 | gRPC 拦截器中从 Metadata 提取 `traceId`——放入 MDC |
| 10 | <strong>限流</strong> | 没限流——一个恶意调用方打垮服务 | gRPC 服务端拦截器中实现令牌桶或信号量限流 |

## 九、⚠️ 常见生产问题

| 问题 | 现象 | 原因 | 解决 |
|------|------|------|------|
| `UNAVAILABLE: io exception` | 偶发——马上恢复 | 后端 Pod 滚动更新——连接被断开 | 启用重试策略——`retryPolicy` |
| 连接泄漏 | 一段时间后所有请求超时 | 客户端创建了 ManagedChannel 但没有复用 | `@GrpcClient` 注入 Stub 是线程安全的——全局复用 |
| 内存涨 | 老年代一直不回收 | gRPC 服务端的消息太大 + 频繁分配 byte[] | 设 `maxInboundMessageSize`——限制消息大小 |
| `RESOURCE_EXHAUSTED` | 大量并发请求被拒 | 服务端限流 `maxConcurrentCallsPerConnection` | 调大限制——或客户端加退避重试 |
| Deadline 不传播 | 上游超时了下游还在跑 | 中间服务没有传递 Context | 用 `Contexts.interceptCall`——确保 Context 传播 |

## 🎯 总结

1. <strong>浏览器不直接支持 gRPC——需要网关</strong>：gRPC-Gateway 手写 Controller 是最简单的方案——对外暴 HTTP JSON，对内转 gRPC 调用。proto 文件已定义了服务契约——手写时直接参照。

2. <strong>负载均衡选客户端侧</strong>：gRPC 基于 HTTP/2 长连接——传统的服务端代理轮询不合适。客户端内置 `round_robin` 策略——简单有效。

3. <strong>生产环境三件套——TLS + 认证 + 健康检查</strong>：TLS 加密传输、JWT/mTLS 认证调用方身份、gRPC Health Check 协议告知 K8s 服务状态。三者缺一不可。

4. <strong>Keepalive + Deadline + Retry 是 gRPC 生产三要素</strong>：Keepalive 保持连接存活、Deadline 防止请求无限等待、Retry 应对瞬时的网络抖动。配对了这三点——gRPC 生产环境才算及格。

---

> 📖 <strong>系列回顾</strong>：gRPC 系列到此结束——
> 1. [<strong>Protobuf 语法精讲与 gRPC 概念</strong>]({{< relref "ProtobufGuide.md" >}}) —— 每个语法元素都拆开讲
> 2. [<strong>SpringBoot gRPC 全操作指南</strong>]({{< relref "SpringBootGrpc.md" >}}) —— 四种 RPC 模式写一遍
> 3. [<strong>微服务拆分实战：以 proto 为契约</strong>]({{< relref "GrpcMicroservice.md" >}}) —— 多服务项目结构和 DTO 转换
> 4. [<strong>gRPC Gateway 与生产环境部署</strong>]({{< relref "GrpcGateway.md" >}}) —— 网关、TLS、认证、Docker Compose 全部上线
