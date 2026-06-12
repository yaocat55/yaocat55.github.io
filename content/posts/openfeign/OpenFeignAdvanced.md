---
title: "OpenFeign 进阶——配置、拦截器与容错"
date: 2022-12-11T08:00:00+00:00
tags: ["RPC框架", "实践教程", "SpringCloud"]
categories: ["RPC框架"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "OpenFeign 进阶全操作：超时/重试/连接池配置、RequestInterceptor 自动传递鉴权 Header 和 TraceId、日志级别、自定义 ErrorDecoder、FallbackFactory 降级——从能调到调得稳、调得快、调得安心。"
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

# 进阶指南：配置、拦截器与容错

> 📖 <strong>前置阅读</strong>：本文假设读者已掌握 OpenFeign 的基本用法——@FeignClient、注解映射。如果还不熟悉，建议先阅读 [<strong>OpenFeign 核心概念与快速上手</strong>]({{< relref "OpenFeignFundamentals.md" >}})。

## 一、⚡ 调通了——但第二天线上就出问题

Feign 的基本调用 5 分钟搞定。但一上生产——问题一个接一个：

```
问题 ①：用户服务偶尔慢 2 秒——订单服务的 Feign 一直等——线程全卡死
  → 需要超时配置

问题 ②：网络抖动——请求偶尔失败——直接抛异常给用户
  → 需要重试机制

问题 ③：用户服务需要 Token 鉴权——每次调 Feign 都要手动传 Header
  → 需要拦截器自动注入

问题 ④：用户服务挂了——Feign 调不通——订单服务的线程池被占满
  → 需要 Fallback 降级

问题 ⑤：排查问题——Feign 到底发了什么请求？返回了什么？
  → 需要日志
```

这一篇把以上每个问题都给出具体配置和代码。

## 二、⏱️ 超时与重试——Feign 最容易被忽略的配置

### 2.1 默认的超时太长了

Feign 底层用 Ribbon（老版本）或 LoadBalancer（新版本）做负载均衡。默认超时：

| 参数 | 默认值 | 说明 |
|------|:---:|------|
| `connect-timeout` | 1s | 建立 TCP 连接的超时——默认还好 |
| `read-timeout` | <strong>60s</strong> | 等响应的超时——太长了！一个慢请求能卡 60 秒 |

```yaml
# application.yml——Feign 超时配置
spring:
  cloud:
    openfeign:
      client:
        config:
          # ① 全局配置——对所有 FeignClient 生效
          default:
            connect-timeout: 3000     # 建连接最多等 3s
            read-timeout: 5000        # 等响应最多等 5s
            logger-level: BASIC

          # ② 按服务配置——针对特定服务
          user-service:               # 这个名字和 @FeignClient(name="user-service") 对应
            connect-timeout: 2000
            read-timeout: 3000        # 用户服务是核心——超时设短点

          product-service:
            connect-timeout: 5000
            read-timeout: 10000       # 商品服务偶尔慢——多给点时间
```

### 2.2 重试——哪些请求能重试，哪些不能

```yaml
spring:
  cloud:
    openfeign:
      client:
        config:
          default:
            retryer: com.example.feign.DefaultRetryer  # 自定义重试器
```

```java
// 自定义重试策略
@Configuration
public class FeignRetryConfig {

    @Bean
    public Retryer feignRetryer() {
        // 参数：period(初始间隔), maxPeriod(最大间隔), maxAttempts(最多尝试次数)
        // 下面 = 初始等 100ms → 每次乘 1.5 → 最多重试 3 次（总共 4 次）
        return new Retryer.Default(100, 1500, 3);
    }
}
```

```
重试的时间线：
  第 1 次请求 → 失败 → 等 100ms
  第 2 次请求 → 失败 → 等 250ms
  第 3 次请求 → 失败 → 等 625ms
  第 4 次请求 → 成功 → 返回
  如果第 4 次也失败 → 抛异常
```

> ⚠️ 新手提示：POST 请求不要重试！如果创建订单的 POST 请求超时——Feign 自动重试——用户被扣了两次钱。<strong>GET 可以重试（幂等），POST/PUT/DELETE 绝不重试。</strong>要控制这个——用 `@FeignClient` 的 `configuration` 属性对不同接口用不同的重试策略。

### 2.3 连接池——默认的 HttpURLConnection 太弱了

Feign 默认用 JDK 的 `HttpURLConnection`——它<strong>没有连接池</strong>，每个请求建立新的 TCP 连接。生产环境必须换成 Apache HttpClient 或 OkHttp：

```xml
<!-- 方式一：Apache HttpClient 5（推荐——和 RestTemplate 一致） -->
<dependency>
    <groupId>io.github.openfeign</groupId>
    <artifactId>feign-hc5</artifactId>
</dependency>
```

```yaml
spring:
  cloud:
    openfeign:
      httpclient:
        hc5:
          enabled: true              # 开启 HttpClient 5
      client:
        config:
          default:
            connect-timeout: 3000
            read-timeout: 5000
```

换成 HttpClient 后——连接池自动生效（默认最大 200 个连接、每个路由最大 50 个）。

## 三、🔐 RequestInterceptor——自动传递 Header

### 3.1 问题：每个 Feign 方法都要手动传 Token

```java
// ❌ 反模式——每个方法都加 @RequestHeader
@FeignClient(name = "user-service")
public interface UserClient {

    @GetMapping("/api/users/{userId}")
    User getUser(@PathVariable("userId") Long userId,
                 @RequestHeader("Authorization") String token,  // ← 又多一个参数
                 @RequestHeader("X-Trace-Id") String traceId);  // ← 又多一个参数
}

// Service 中调用时——每次都要传
User user = userClient.getUser(userId, getToken(), MDC.get("traceId"));
// 烦死了——明明这些 Header 每个 Feign 请求都应该带
```

### 3.2 解决方案：RequestInterceptor 自动注入

```java
// ② Feign 请求拦截器——每个发出的 Feign 请求都自动经过这个拦截器
@Component
public class FeignRequestInterceptor implements RequestInterceptor {

    @Override
    public void apply(RequestTemplate template) {
        // 自动带上认证 Token
        String token = getCurrentToken();
        if (token != null) {
            template.header("Authorization", "Bearer " + token);
        }

        // 自动带上 TraceId——全链路追踪
        String traceId = MDC.get("traceId");
        if (traceId != null) {
            template.header("X-Trace-Id", traceId);
        }

        // 自动带上调用方标识
        template.header("X-Caller-Service", "order-service");

        // 每个请求都带一个唯一 RequestId——排查问题用
        template.header("X-Request-Id", UUID.randomUUID().toString()
                .replace("-", "").substring(0, 12));
    }

    private String getCurrentToken() {
        // 从 RequestContextHolder 中拿到当前 HTTP 请求中的 Token
        // 这样——网关传给订单服务的 Token——订单服务再传给用户服务——全链路透传
        ServletRequestAttributes attributes =
                (ServletRequestAttributes) RequestContextHolder.getRequestAttributes();
        if (attributes != null) {
            String authHeader = attributes.getRequest().getHeader("Authorization");
            if (authHeader != null && authHeader.startsWith("Bearer ")) {
                return authHeader.substring(7);
            }
        }
        return null;
    }
}
```

```java
// ① 需要先配一个 RequestContextListener——让 RequestContextHolder 生效
// 在 SpringBoot 启动类或配置类中
@Bean
public RequestContextListener requestContextListener() {
    return new RequestContextListener();
}
```

现在 Feign 接口清爽了——不需要多余的参数：

```java
// ✅ RequestInterceptor 自动搞定——接口干净了
@FeignClient(name = "user-service")
public interface UserClient {
    @GetMapping("/api/users/{userId}")
    User getUser(@PathVariable("userId") Long userId);  // 只管业务参数
}
```

<strong>Token 透传链</strong>：

```
前端请求 → Gateway（解析 JWT）
  → 转发给 OrderService——Header Authorization 透传
  → OrderService 调 Feign → RequestInterceptor 自动取 Header 中的 Token 传给 UserService
  → UserService 调 Feign → 继续给 ProductService
```

## 四、📝 日志——Feign 到底发了什么请求？

### 4.1 配置日志级别

```yaml
logging:
  level:
    com.example.feign.UserClient: DEBUG   # 把这个 FeignClient 的日志打到 DEBUG
```

```java
@Configuration
public class FeignLogConfig {

    @Bean
    public Logger.Level feignLoggerLevel() {
        return Logger.Level.FULL;  // 生产用 BASIC 或 HEADERS
    }
}
```

| 日志级别 | 输出内容 | 适用环境 |
|------|------|------|
| `NONE` | 不输出——默认 | — |
| `BASIC` | 请求方法 + URL + 响应状态码 + 耗时 | <strong>生产推荐</strong> |
| `HEADERS` | BASIC + 请求头 + 响应头 | 调试时 |
| `FULL` | HEADERS + 请求体 + 响应体 | <strong>开发环境</strong>——生产别用（Body 可能包含敏感信息） |

### 4.2 日志输出示例

```
# FULL 级别日志
[UserClient#getUser] ---> GET http://user-service/api/users/123 HTTP/1.1
[UserClient#getUser] Authorization: Bearer eyJhbGc...
[UserClient#getUser] X-Trace-Id: a1b2c3d4e5f6
[UserClient#getUser] ---> END HTTP (0-byte body)

[UserClient#getUser] <--- HTTP/1.1 200 OK (127ms)
[UserClient#getUser] Content-Type: application/json
[UserClient#getUser] {"userId":123,"userName":"张三","email":"zhangsan@example.com"}
[UserClient#getUser] <--- END HTTP (64-byte body)
```

## 五、⚠️ ErrorDecoder——把 HTTP 错误码转成业务异常

默认情况下——Feign 收到 404 会抛 `FeignException.NotFound`，收到 500 会抛 `FeignException.InternalServerError`。但你更希望拿到业务异常：

```java
// 自定义 ErrorDecoder——把 HTTP 错误转成 Java 异常
@Component
public class FeignErrorDecoder implements ErrorDecoder {

    @Override
    public Exception decode(String methodKey, Response response) {
        // 尝试从响应体中解析错误信息
        try {
            String body = response.body() != null
                    ? new String(response.body().asInputStream().readAllBytes())
                    : "";

            switch (response.status()) {
                case 400:
                    return new BusinessException("请求参数错误: " + body);
                case 404:
                    return new ResourceNotFoundException("资源不存在: " + methodKey);
                case 429:
                    return new RateLimitException("请求被限流");
                case 503:
                    return new ServiceUnavailableException("服务不可用: " + body);
                default:
                    return new FeignException.FeignServerException(
                            response.status(), "服务内部错误", response.request(), null, null);
            }
        } catch (IOException e) {
            return new FeignException.FeignServerException(
                    response.status(), "无法解析响应", response.request(), null, null);
        }
    }
}
```

```java
// Service 中捕获业务异常而不是 FeignException
@Service
public class OrderService {

    @Autowired
    private UserClient userClient;

    public Order createOrder(CreateOrderRequest request) {
        try {
            User user = userClient.getUser(request.getUserId());
            // ... 创建订单
        } catch (ResourceNotFoundException e) {
            // 用户不存在——返回友好提示
            throw new BusinessException("用户不存在——userId:" + request.getUserId());
        } catch (ServiceUnavailableException e) {
            // 用户服务挂了——走降级
            return createOrderWithFallback(request);
        }
    }
}
```

## 六、🛡️ Fallback——被调服务挂了怎么办

### 6.1 Fallback——返回默认值

```java
// ① 定义 Fallback 类——实现 Feign 接口
@Component
public class UserClientFallback implements UserClient {

    @Override
    public User getUser(Long userId) {
        // 用户服务挂了——返回默认用户
        User fallbackUser = new User();
        fallbackUser.setUserId(userId);
        fallbackUser.setUserName("未知用户");
        fallbackUser.setEmail("");
        return fallbackUser;
    }

    @Override
    public User createUser(User user) {
        throw new BusinessException("用户服务不可用——暂时无法创建用户");
    }

    @Override
    public List<User> listUsers(String keyword, int page, int size) {
        return Collections.emptyList();
    }
}

// ② @FeignClient 中声明 Fallback
@FeignClient(name = "user-service", fallback = UserClientFallback.class)
public interface UserClient {
    @GetMapping("/api/users/{userId}")
    User getUser(@PathVariable("userId") Long userId);
    // ...
}
```

### 6.2 FallbackFactory——拿到异常信息

Fallback 的局限——你不知道<strong>为什么</strong>降级了（是超时？还是服务挂了？还是返回了 500？）。用 `FallbackFactory` 能拿到异常：

```java
@Component
public class UserClientFallbackFactory implements FallbackFactory<UserClient> {

    @Override
    public UserClient create(Throwable cause) {
        // 记录降级原因——方便排查
        System.err.println("UserClient 降级——原因: " + cause.getMessage());

        return new UserClient() {
            @Override
            public User getUser(Long userId) {
                User user = new User();
                user.setUserId(userId);

                // 根据异常类型返回不同的默认值
                if (cause instanceof RetryableException) {
                    user.setUserName("用户服务超时——请稍后重试");
                } else if (cause instanceof FeignException.NotFound) {
                    user.setUserName("用户不存在");
                } else {
                    user.setUserName("用户服务暂时不可用");
                }
                return user;
            }

            @Override
            public List<User> listUsers(String keyword, int page, int size) {
                return Collections.emptyList();
            }
        };
    }
}

// 使用 FallbackFactory 替代 Fallback
@FeignClient(name = "user-service",
             fallbackFactory = UserClientFallbackFactory.class)
public interface UserClient { ... }
```

<strong>Fallback vs FallbackFactory</strong>：

| 特性 | Fallback | FallbackFactory |
|------|:---:|:---:|
| 能否拿到异常原因 | ❌ 不能 | ✅ `Throwable cause` 包含了具体原因 |
| 实现复杂度 | 低——实现接口就行 | 中——多一层 Factory |
| 推荐场景 | 简单降级——不需要区分原因 | <strong>生产推荐</strong>——需要知道为什么降级 |

## 七、🚀 Feign 的异步调用

Feign 默认是同步的——调 `getUser()` 时会阻塞等响应。如果你需要并发调多个服务：

```java
@Service
public class OrderService {

    @Autowired
    private AsyncUserClient asyncUserClient;

    // 并发调用户服务和商品服务——不阻塞
    public Order createOrderAsync(CreateOrderRequest request) {

        CompletableFuture<User> userFuture =
                asyncUserClient.getUser(request.getUserId());

        CompletableFuture<Product> productFuture =
                asyncProductClient.getProduct(request.getProductId());

        // 两个都等——但它们是并发执行的——各不阻塞
        User user = userFuture.join();
        Product product = productFuture.join();

        return buildOrder(user, product);
    }
}

// 异步 Feign 接口——返回 CompletableFuture
@FeignClient(name = "user-service")
public interface AsyncUserClient {

    @GetMapping("/api/users/{userId}")
    CompletableFuture<User> getUser(@PathVariable("userId") Long userId);
}
```

## 八、📋 Feign 进阶 Checklist

| # | 配置项 | 推荐值 | 说明 |
|:--:|------|------|------|
| 1 | `connect-timeout` | 2000~5000 ms | 根据网络情况设——不要太长 |
| 2 | `read-timeout` | 3000~10000 ms | 根据接口正常 RT × 3 |
| 3 | 连接池 | <strong>Apache HttpClient 5</strong> | 替换默认——每个请求省一次 TCP 握手 |
| 4 | 重试 | GET 3 次 | POST/PUT/DELETE <strong>不重试</strong> |
| 5 | RequestInterceptor | 自动传 Token + TraceId | 不用每个方法手动加 Header |
| 6 | 日志 | 生产 `BASIC`、开发 `FULL` | 排查问题全靠 Feign 日志 |
| 7 | ErrorDecoder | 转成业务异常 | 不要让 FeignException 泄漏到业务代码 |
| 8 | FallbackFactory | <strong>必须配</strong> | 被调服务挂了——你至少要知道为什么 |

## 🎯 总结

1. <strong>超时和连接池是 Feign 上线前必须改的</strong>：默认 60s 超时太长——一个慢请求能拖死调用方。默认 `HttpURLConnection` 没连接池——换成 HttpClient 5。

2. <strong>RequestInterceptor 是 Feign 的"隐形管家"</strong>：Token、TraceId、RequestId 自动注入——Feign 接口只管业务参数。配合 `RequestContextHolder` 实现全链路 Token 透传。

3. <strong>FallbackFactory > Fallback</strong>：生产环境用 FallbackFactory——至少知道降级是因为超时、404 还是 500。简单降级用 Fallback——只返回默认值。

4. <strong>ErrorDecoder 把 FeignException 转成业务异常</strong>：不让底层的 HTTP 错误码污染业务代码——404 → ResourceNotFoundException，503 → ServiceUnavailableException。

> 📖 <strong>下一步阅读</strong>：Feign 和 Nacos 配合做服务发现——和 Sentinel 配合做熔断降级——和 Contract 配合做接口优先设计——继续阅读 [<strong>OpenFeign 生产实战——Nacos + Sentinel + 性能调优</strong>]({{< relref "OpenFeignProduction.md" >}})。
