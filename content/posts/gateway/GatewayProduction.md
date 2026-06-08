---
title: "Gateway 生产实战——鉴权、限流、熔断与部署"
date: 2022-12-05T08:00:00+00:00
tags: ["微服务中间件"]
categories: ["微服务网关"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "Spring Cloud Gateway 生产环境全方案：JWT 鉴权 GlobalFilter、Redis 令牌桶限流、Resilience4j 熔断降级、CORS 跨域配置、Prometheus + Grafana 监控、traceId 全链路追踪、Docker Compose 部署——附带 12 项生产上线 Checklist。"
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

# Gateway 生产实战——鉴权、限流、熔断与部署

> 📖 <strong>前置阅读</strong>：本文假设读者已掌握 Gateway 的 Route/Predicate/Filter 全操作。如果还不熟悉，建议先阅读前三篇：[<strong>核心概念</strong>]({{< relref "GatewayFundamentals.md" >}})、[<strong>Predicate 全解</strong>]({{< relref "GatewayPredicate.md" >}})、[<strong>Filter 全操作</strong>]({{< relref "GatewayFilterGuide.md" >}})。

## 一、⚡ 路由和 Filter 都调通了——但你能上线吗？

开发环境一切正常——`localhost` 上 Gateway 跑得稳稳的。但上线之前你至少还要解决：

```
① 认证——用户登录后的 JWT Token 在网关统一校验
② 限流——防止恶意刷接口——一个 IP 一秒最多 10 次
③ 熔断——后端挂了——网关直接降级返回而不是把 500 抛给前端
④ 跨域——前端从不同域名调网关——浏览器会拦截
⑤ 监控——请求量、错误率、延迟——全部看不到就是盲飞
⑥ TraceId——一个请求穿过网关到后端多个服务——怎么串联日志？
```

这一篇把以上每个问题都给出<strong>可直接使用的配置和代码</strong>。

## 二、🔐 JWT 鉴权——全局统一校验

### 2.1 为什么在网关做鉴权？

每个后端服务都自己解析 JWT——重复代码、分散维护、容易漏掉。在网关统一做——<strong>后端只信任网关传过来的 Header 就行了</strong>：

```
浏览器带 JWT → 网关解析 → Header 中放 userId + role → 后端直接用
```

### 2.2 完整的 JWT 鉴权 GlobalFilter

```java
@Component
@Order(-100)
public class JwtAuthGlobalFilter implements GlobalFilter {

    // 白名单——不需要 Token 的接口
    private static final List<String> WHITE_LIST = List.of(
            "/api/public/login",
            "/api/public/register",
            "/api/public/health"
    );

    // 从配置中心拿——这里简化为常量
    private static final String SECRET_KEY = "your-256-bit-secret-key";

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {

        String path = exchange.getRequest().getURI().getPath();

        // ① 白名单放行
        if (isWhiteListed(path)) {
            return chain.filter(exchange);
        }

        // ② 提取 Token
        String authHeader = exchange.getRequest()
                .getHeaders().getFirst(HttpHeaders.AUTHORIZATION);

        if (authHeader == null || !authHeader.startsWith("Bearer ")) {
            return unauthorized(exchange, "缺少认证 Token");
        }

        String token = authHeader.substring(7);

        // ③ 解析 JWT
        try {
            Claims claims = Jwts.parser()
                    .setSigningKey(SECRET_KEY)
                    .parseClaimsJws(token)
                    .getBody();

            // 检查是否过期
            if (claims.getExpiration().before(new Date())) {
                return unauthorized(exchange, "Token 已过期");
            }

            // ④ 把用户信息写入请求头——后端直接用
            ServerHttpRequest mutatedRequest = exchange.getRequest().mutate()
                    .header("X-User-Id", String.valueOf(claims.get("userId")))
                    .header("X-User-Name", claims.get("userName", String.class))
                    .header("X-User-Role", claims.get("role", String.class))
                    .build();

            // ⑤ 用修改后的 Request 继续
            return chain.filter(exchange.mutate().request(mutatedRequest).build());

        } catch (JwtException e) {
            return unauthorized(exchange, "Token 无效: " + e.getMessage());
        }
    }

    private boolean isWhiteListed(String path) {
        return WHITE_LIST.stream().anyMatch(path::startsWith);
    }

    private Mono<Void> unauthorized(ServerWebExchange exchange, String message) {
        exchange.getResponse().setStatusCode(HttpStatus.UNAUTHORIZED);
        exchange.getResponse().getHeaders()
                .setContentType(MediaType.APPLICATION_JSON);
        // 返回 JSON 错误信息
        byte[] body = ("{\"code\":401,\"message\":\"" + message + "\"}").getBytes();
        DataBuffer buffer = exchange.getResponse()
                .bufferFactory().wrap(body);
        return exchange.getResponse().writeWith(Mono.just(buffer));
    }
}
```

### 2.3 后端如何信任网关

后端服务应该<strong>只信任从网关来的请求</strong>——加一个内部 Token 做服务间认证：

```java
// Gateway 发请求时自动加上内部 Token
@Component
public class InternalTokenFilter implements GlobalFilter, Ordered {

    private static final String INTERNAL_TOKEN = "internal-secret-token";

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        ServerHttpRequest request = exchange.getRequest().mutate()
                .header("X-Internal-Token", INTERNAL_TOKEN)
                .build();
        return chain.filter(exchange.mutate().request(request).build());
    }

    @Override
    public int getOrder() { return -50; }  // 在鉴权之后——转发之前
}
```

```java
// 后端服务用拦截器验证内部 Token——确保请求是从网关来的
// 如果直接调后端绕过网关——请求被拒绝
@RestControllerAdvice
public class InternalTokenInterceptor {

    // 在每个后端服务中验证 X-Internal-Token——不是网关来的请求直接拒绝
}
```

## 三、🚦 Redis 限流——令牌桶算法

### 3.1 为什么要限流？

没有限流的网关 = 没有闸门的水库。一个恶意脚本每秒发 1000 次登录请求——用户服务直接打挂。

### 3.2 配置

```xml
<!-- 需要 spring-boot-starter-data-redis-reactive——Gateway 基于 WebFlux -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-redis-reactive</artifactId>
</dependency>
```

```yaml
spring:
  redis:
    host: localhost
    port: 6379
  cloud:
    gateway:
      routes:
        - id: user-service
          uri: lb://user-service
          predicates:
            - Path=/api/users/**
          filters:
            - StripPrefix=1
            - name: RequestRateLimiter
              args:
                # 每秒补充 10 个令牌（允许 10 QPS 持续）
                redis-rate-limiter.replenishRate: 10
                # 桶容量 20——允许瞬时突发 20 个请求
                redis-rate-limiter.burstCapacity: 20
                # 请求消耗的令牌数——可以配 > 1（如每次 2 令牌 = 4 QPS）
                redis-rate-limiter.requestedTokens: 1
                # Key Resolver——按什么维度限流
                key-resolver: "#{@ipKeyResolver}"
```

### 3.3 三种 Key Resolver——按 IP / 按用户 / 按接口

```java
@Configuration
public class RateLimiterConfig {

    // ① 按 IP 限流——最常用
    @Bean
    @Primary
    public KeyResolver ipKeyResolver() {
        return exchange -> Mono.just(
                exchange.getRequest().getRemoteAddress()
                        .getAddress().getHostAddress());
    }

    // ② 按用户限流——针对已登录用户
    @Bean
    public KeyResolver userKeyResolver() {
        return exchange -> {
            String userId = exchange.getRequest()
                    .getHeaders().getFirst("X-User-Id");
            return Mono.justOrEmpty(userId)
                    .switchIfEmpty(Mono.just("anonymous"));
        };
    }

    // ③ 按接口限流——针对单个 API
    @Bean
    public KeyResolver apiKeyResolver() {
        return exchange -> Mono.just(
                exchange.getRequest().getURI().getPath());
    }
}
```

### 3.4 自定义限流响应——不要给用户看 429 空页面

```java
@Configuration
public class GatewayConfig {

    @Bean
    public WebExceptionHandler rateLimitExceptionHandler() {
        return (exchange, ex) -> {
            if (ex instanceof ResponseStatusException rse
                    && rse.getStatusCode() == HttpStatus.TOO_MANY_REQUESTS) {
                exchange.getResponse().setStatusCode(HttpStatus.TOO_MANY_REQUESTS);
                exchange.getResponse().getHeaders()
                        .setContentType(MediaType.APPLICATION_JSON);
                String body = "{\"code\":429,\"message\":\"请求过于频繁，请稍后重试\",\"retryAfter\":3}";
                DataBuffer buffer = exchange.getResponse()
                        .bufferFactory().wrap(body.getBytes(StandardCharsets.UTF_8));
                return exchange.getResponse().writeWith(Mono.just(buffer));
            }
            return Mono.error(ex);
        };
    }
}
```

## 四、🔧 Resilience4j 熔断——后端挂了也能优雅降级

### 4.1 熔断器工作原理

```
熔断器有三种状态：
  CLOSED（关闭）    → 正常状态——请求正常转发
  OPEN（打开）      → 后端连续失败 > 阈值——请求不再转发，直接降级
  HALF_OPEN（半开） → 过了一段时间——放一个请求试试，成功 → CLOSED，失败 → OPEN
```

### 4.2 依赖与配置

```xml
<dependency>
    <groupId>org.springframework.cloud</groupId>
    <artifactId>spring-cloud-starter-circuitbreaker-reactor-resilience4j</artifactId>
</dependency>
```

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
            - name: CircuitBreaker
              args:
                name: userServiceCB
                fallbackUri: forward:/fallback/user-service  # 降级地址

# Resilience4j 熔断器参数
resilience4j:
  circuitbreaker:
    configs:
      default:
        sliding-window-size: 10           # 滑动窗口大小——最近 10 个请求
        minimum-number-of-calls: 5        # 最少 5 个请求才开始统计
        failure-rate-threshold: 50        # 失败率 50% 时熔断
        wait-duration-in-open-state: 10s  # 熔断后 10 秒进入半开
        automatic-transition-from-open-to-half-open-enabled: true
    instances:
      userServiceCB:
        base-config: default
  timelimiter:
    configs:
      default:
        timeout-duration: 3s             # 单个请求超时时间——3 秒没响应算失败
```

### 4.3 降级 Controller

```java
@RestController
@RequestMapping("/fallback")
public class FallbackController {

    @RequestMapping("/user-service")
    public Mono<Map<String, Object>> userServiceFallback(ServerWebExchange exchange) {
        return Mono.just(Map.of(
                "code", 503,
                "message", "用户服务暂时不可用",
                "service", "user-service",
                "timestamp", System.currentTimeMillis()
        ));
    }

    @RequestMapping("/order-service")
    public Mono<Map<String, Object>> orderServiceFallback() {
        return Mono.just(Map.of(
                "code", 503,
                "message", "订单服务暂时不可用，请稍后重试",
                "service", "order-service"
        ));
    }
}
```

> ⚠️ 新手提示：`fallbackUri` 只能用 `forward:/`（内部转发）——不能用 `redirect:/`（会发 302 给客户端再跳转）。降级是网关自己的事——客户端不应该感知。

## 五、🌐 CORS 跨域配置

前端从 `http://localhost:3000` 调网关 `http://gateway:8080`——浏览器会发 OPTIONS 预检请求。必须在网关统一配 CORS：

```yaml
spring:
  cloud:
    gateway:
      globalcors:
        cors-configurations:
          '[/**]':
            allowed-origins:
              - "http://localhost:3000"
              - "https://your-frontend.com"
            allowed-methods:
              - GET
              - POST
              - PUT
              - DELETE
              - OPTIONS
            allowed-headers:
              - "*"
            allow-credentials: true       # 允许带 Cookie
            max-age: 3600                 # 预检请求缓存 1 小时
```

```java
// 或者用 Java 配置——更灵活
@Configuration
public class CorsConfig implements WebFilter {

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, WebFilterChain chain) {
        ServerHttpRequest request = exchange.getRequest();

        // 如果是 OPTIONS 预检请求——直接返回
        if (request.getMethod() == HttpMethod.OPTIONS) {
            ServerHttpResponse response = exchange.getResponse();
            response.getHeaders().add("Access-Control-Allow-Origin", "*");
            response.getHeaders().add("Access-Control-Allow-Methods",
                    "GET, POST, PUT, DELETE, OPTIONS");
            response.getHeaders().add("Access-Control-Allow-Headers", "*");
            response.getHeaders().add("Access-Control-Max-Age", "3600");
            response.setStatusCode(HttpStatus.OK);
            return response.setComplete();
        }

        return chain.filter(exchange);
    }
}
```

## 六、📊 监控——Prometheus + Actuator

### 6.1 暴露指标

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
management:
  endpoints:
    web:
      exposure:
        include: health,info,metrics,prometheus,gateway
  metrics:
    tags:
      application: ${spring.application.name}
```

```bash
# 访问 http://gateway:8080/actuator/prometheus——看到 Prometheus 格式的指标
# gateway_requests_seconds_count{route="user-service",...}
# gateway_requests_seconds_sum{route="user-service",...}
```

### 6.2 Gateway 内置指标

Spring Cloud Gateway 自动暴露以下指标：

| 指标 | 含义 |
|------|------|
| `gateway_requests_seconds_count` | 总请求数 |
| `gateway_requests_seconds_sum` | 总耗时 |
| `gateway_requests_seconds_max` | 最大耗时 |
| `gateway_routes_count` | 路由数量 |
| `gateway_state` | 路由状态 |

### 6.3 Prometheus + Grafana 快速配置

```yaml
# prometheus.yml——Prometheus 抓取 Gateway 指标
scrape_configs:
  - job_name: 'gateway'
    metrics_path: '/actuator/prometheus'
    static_configs:
      - targets: ['gateway:8080']
```

Grafana 中导入 Spring Boot 仪表盘（ID: 12900）——直接看到 QPS、延迟分布、错误率。

## 七、🆔 TraceId 全链路追踪

一个请求穿过 Gateway → OrderService → UserService → ProductService。某个请求出错了——你需要一个 <strong>TraceId</strong> 把这条链路上的所有日志串起来。

### 7.1 Gateway 生成并传递 TraceId

```java
@Component
@Order(10)
public class TraceIdFilter implements GlobalFilter {

    private static final String TRACE_ID_HEADER = "X-Trace-Id";

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        // 如果上游已经传了 TraceId——沿用
        String traceId = exchange.getRequest()
                .getHeaders().getFirst(TRACE_ID_HEADER);

        if (traceId == null) {
            // 生成新的 TraceId——UUID 截短版
            traceId = UUID.randomUUID().toString()
                    .replace("-", "").substring(0, 16);
        }

        // 放入 MDC——Gateway 自己的日志也能打印
        MDC.put("traceId", traceId);

        // 写入请求头——往后端传递
        String finalTraceId = traceId;
        ServerHttpRequest request = exchange.getRequest().mutate()
                .header(TRACE_ID_HEADER, finalTraceId)
                .build();

        return chain.filter(exchange.mutate().request(request).build())
                .doFinally(s -> MDC.clear());  // 请求结束后清理 MDC
    }
}
```

### 7.2 后端服务接收并继续传递

```java
// 后端服务的 Filter / Interceptor——取 TraceId 放入 MDC
// 如果后端用 Dubbo → Dubbo Filter 中传递
// 如果后端用 Feign → Feign RequestInterceptor 中传递
// 如果后端用 gRPC → gRPC ClientInterceptor 中传递

// 举例——Dubbo 传递 TraceId
@Activate(group = PROVIDER)
public class TraceIdDubboFilter implements Filter {

    @Override
    public Result invoke(Invoker<?> invoker, Invocation invocation) {
        String traceId = RpcContext.getContext()
                .getAttachment("X-Trace-Id");
        if (traceId != null) {
            MDC.put("traceId", traceId);
        }
        try {
            return invoker.invoke(invocation);
        } finally {
            MDC.clear();
        }
    }
}
```

### 7.3 日志配置——让 TraceId 出现在每条日志中

```xml
<!-- logback-spring.xml —— 日志格式中加上 traceId -->
<configuration>
    <appender name="CONSOLE" class="ch.qos.logback.core.ConsoleAppender">
        <encoder>
            <!-- %X{traceId} 从 MDC 中取 traceId -->
            <pattern>
                %d{yyyy-MM-dd HH:mm:ss.SSS} [%thread] [%X{traceId}] %-5level %logger{36} - %msg%n
            </pattern>
        </encoder>
    </appender>
    <root level="INFO">
        <appender-ref ref="CONSOLE"/>
    </root>
</configuration>
```

```bash
# 日志输出效果——同一个 traceId 贯穿网关到所有后端服务
# 2024-12-05 10:30:01.123 [reactor-http-1] [a1b2c3d4e5f6a7b8] INFO  Gateway - 收到请求 GET /api/users/1
# 2024-12-05 10:30:01.145 [reactor-http-1] [a1b2c3d4e5f6a7b8] INFO  Gateway - 转发到 user-service
# 2024-12-05 10:30:01.200 [http-nio-8081-1] [a1b2c3d4e5f6a7b8] INFO  UserSvc - 查询用户 ID=1
# 2024-12-05 10:30:01.250 [reactor-http-1] [a1b2c3d4e5f6a7b8] INFO  Gateway - 响应状态: 200, 耗时: 127ms
```

## 八、🐳 Docker Compose 部署

### 8.1 完整 docker-compose.yml

```yaml
version: '3.8'
services:

  # ===== Redis——限流依赖 =====
  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    command: redis-server --appendonly yes
    volumes:
      - redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 3

  # ===== Nacos——服务发现 =====
  nacos:
    image: nacos/nacos-server:v2.3.0
    environment:
      - MODE=standalone
      - PREFER_HOST_MODE=hostname
    ports:
      - "8848:8848"
      - "9848:9848"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8848/nacos/v1/console/health/readiness"]
      interval: 10s
      retries: 5

  # ===== Spring Cloud Gateway =====
  gateway:
    image: api-gateway:1.0.0
    ports:
      - "8080:8080"
    environment:
      - SPRING_PROFILES_ACTIVE=prod
      - SPRING_REDIS_HOST=redis
      - SPRING_CLOUD_NACOS_DISCOVERY_SERVER-ADDR=nacos:8848
    depends_on:
      redis:
        condition: service_healthy
      nacos:
        condition: service_healthy
    # JVM 参数——Gateway 主要是网络操作，堆不需要太大
    mem_limit: 512m
    mem_reservation: 256m

  # ===== Prometheus——指标采集 =====
  prometheus:
    image: prom/prometheus:v2.48.0
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'

  # ===== Grafana——指标可视化 =====
  grafana:
    image: grafana/grafana:10.2.0
    ports:
      - "3000:3000"
    depends_on:
      - prometheus

volumes:
  redis-data:
```

### 8.2 Gateway 生产配置

```yaml
# application-prod.yml
server:
  port: 8080
  netty:                             # Gateway 底层是 Netty
    connection-timeout: 5000ms       # 连接超时

spring:
  application:
    name: api-gateway
  cloud:
    gateway:
      httpclient:
        connect-timeout: 2000        # 连接后端超时
        response-timeout: 10s        # 后端响应超时
        pool:
          max-idle-time: 30s         # 空闲连接存活时间
          max-connections: 500       # 最大连接数
          acquire-timeout: 5000      # 等连接超时
      metrics:
        enabled: true
      # 路由定义
      routes:
        - id: user-service
          uri: lb://user-service
          predicates:
            - Path=/api/users/**
          filters:
            - StripPrefix=1
            - name: CircuitBreaker
              args:
                name: userServiceCB
                fallbackUri: forward:/fallback/user-service
            - name: RequestRateLimiter
              args:
                redis-rate-limiter.replenishRate: 50
                redis-rate-limiter.burstCapacity: 100
                key-resolver: "#{@ipKeyResolver}"

  redis:
    host: ${SPRING_REDIS_HOST:localhost}
    port: 6379
    lettuce:
      pool:
        max-active: 20
        max-idle: 10
        min-idle: 5

# Netty 线程——Gateway 默认 = CPU 核心数，一般不改
# reactor:
#   netty:
#     ioWorkerCount: 4

# 日志
logging:
  level:
    org.springframework.cloud.gateway: INFO
    # 排查问题时临时开 TRACE——看每个 Predicate 的匹配过程
```

## 九、📋 生产上线 12 项 Checklist

| # | 检查项 | 配置位置 | 为什么 |
|:--:|------|------|------|
| 1 | <strong>不要引入 spring-boot-starter-web</strong> | pom.xml | WebFlux 和 MVC 不兼容——引入会导致启动失败 |
| 2 | <strong>JWT 鉴权放网关——不在后端</strong> | GlobalFilter | 统一入口——每个后端都自己解析是重复劳动 |
| 3 | <strong>限流必须配——以 IP 为 Key</strong> | RequestRateLimiter | 没有限流——恶意脚本轻易打垮后端 |
| 4 | <strong>熔断每个关键 Route 都配</strong> | CircuitBreaker | 后端挂了网关还能优雅降级——不影响其他 Route |
| 5 | <strong>CORS 在网关统一配——不在后端</strong> | globalcors | 跨域是网关的事——后端不该关心 |
| 6 | <strong>TraceId 在网关生成并传播</strong> | GlobalFilter | 一个请求串起所有服务的日志——排查利器 |
| 7 | <strong>内部 Token 隔离网关和后端</strong> | GlobalFilter | 防止绕过网关直接调后端 |
| 8 | <strong>健康检查端点暴露——不给外部</strong> | Actuator + Security | `/actuator/health` 给 K8s 用——`/actuator/gateway` 需要认证 |
| 9 | <strong>连接池限制</strong> | httpclient.pool | Gateway 转发的连接不是无限的——500 够用 |
| 10 | <strong>超时时间配好</strong> | httpclient.response-timeout | 不设超时——一个慢后端会拖死 Gateway |
| 11 | <strong>Prometheus 指标配好</strong> | actuator + micrometer | 没监控就是盲飞——QPS/延迟/错误率全看不到 |
| 12 | <strong>Graceful Shutdown 配好</strong> | server.shutdown=graceful | K8s 滚动更新——给正在处理的请求 30s 缓冲 |

## 🎯 总结

1. <strong>JWT 鉴权放在网关——后端只信任网关 Header</strong>：`X-User-Id`、`X-User-Role` 在网关解析 JWT 后写入。后端拿这些 Header 直接用——不需要再解析 Token。

2. <strong>限流和熔断是生产必备——不加就是裸奔</strong>：Redis 令牌桶按 IP 限流——每个 IP 每秒 N 次。Resilience4j 熔断后端失败率 > 50% 时自动降级——降级比直接 500 友好得多。

3. <strong>TraceId 在网关生成——贯穿全链路</strong>：网关加上 `X-Trace-Id` → 后端取出来放 MDC → 每条日志都带 TraceId。排查问题时 `grep traceId` 一条命令串起所有日志。

4. <strong>Gateway 部署注意 Netty 特性</strong>：堆不需要太大（256M~512M 够用）、连接池限制 500、超时配合理——网关只做转发，不做业务。

---

> 📖 <strong>系列回顾</strong>：Spring Cloud Gateway 系列到此结束——
> 1. [<strong>核心概念与快速上手</strong>]({{< relref "GatewayFundamentals.md" >}}) —— 为什么选 Gateway、Route/Predicate/Filter 三要素
> 2. [<strong>Predicate 与路由规则全解</strong>]({{< relref "GatewayPredicate.md" >}}) —— 12 种 Predicate、yml vs DSL、动态路由
> 3. [<strong>GatewayFilter 与 GlobalFilter 全操作</strong>]({{< relref "GatewayFilterGuide.md" >}}) —— 内置 Filter、自定义 Filter、执行链
> 4. [<strong>生产实战——鉴权、限流、熔断与部署</strong>]({{< relref "GatewayProduction.md" >}}) —— JWT、限流、熔断、CORS、监控、TraceId、Docker
