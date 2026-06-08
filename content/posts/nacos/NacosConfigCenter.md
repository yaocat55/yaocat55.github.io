---
title: "Nacos 配置中心全操作"
date: 2022-12-15T08:00:00+00:00
tags: ["微服务中间件"]
categories: ["注册中心"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "Nacos 配置中心完整操作指南：配置优先级（shared-configs > extension-configs > 本地）、多服务共享配置抽取公共配置、@RefreshScope 动态刷新原理与陷阱、灰度发布配置（标签路由）、Gateway 路由规则放 Nacos 动态生效、Sentinel 规则持久化到 Nacos——附带多服务配置组织最佳实践。"
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

# Nacos 配置中心全操作

> 📖 <strong>前置阅读</strong>：本文假设读者已掌握 Nacos 的基本概念和 `@RefreshScope`。如果还不熟悉，建议先阅读 [<strong>Nacos 核心概念与快速上手</strong>]({{< relref "NacosFundamentals.md" >}})。

## 一、⚡ 数据库密码改了——5 个服务 15 个实例要一个个改？

先来看看没有配置中心时的情况：

```
场景：MySQL 主库切换——数据库地址从 mysql-master-1 变成 mysql-master-2

没有配置中心：
  ① 改 5 个服务的 application.yml——每个服务改一次
  ② 重新打包/重启 15 个实例——顺序不能错（先启 DB 相关的）
  ③ 改到一半发现有个服务漏了——生产故障
  耗时：30 分钟 + 心跳加速

有了 Nacos 配置中心：
  ① 在 Nacos Dashboard 改一个配置——mysql.host
  ② 点发布——15 个实例自动收到推送
  ③ @RefreshScope 的 Bean 自动重建——新配置生效
  耗时：1 分钟 + 淡定
```

配置中心的价值就是一句话：<strong>改一次——推所有——不用重启</strong>。

## 二、🧩 配置的三级组织——shared-configs / extension-configs / 本地

Nacos 配置有三层——从最共享到最专属：

```
shared-configs（共享配置）          ← 所有服务通用的配置
  ↓ 可以被覆盖
extension-configs（扩展配置）       ← 一组服务共享的配置
  ↓ 可以被覆盖
${spring.application.name}-${profile}.${ext}（服务专属配置） ← 每个服务自己的配置
  ↓ 兜底
application.yml（本地配置）        ← 开发环境兜底——生产通常不放关键配置
```

### 2.1 三层配置在 yml 中怎么配

```yaml
# bootstrap.yml（早于 application.yml 加载——连 Nacos 必须放这里）
spring:
  application:
    name: order-service
  profiles:
    active: dev
  cloud:
    nacos:
      config:
        server-addr: localhost:8848
        namespace: dev
        group: DEFAULT_GROUP
        file-extension: yaml

        # ① shared-configs——所有服务共享的公共配置
        shared-configs:
          - data-id: common-mysql.yaml      # 数据库公共配置——所有服务共用一个 DB 集群
            group: DEFAULT_GROUP
            refresh: true                   # 允许动态刷新
          - data-id: common-redis.yaml      # Redis 公共配置
            group: DEFAULT_GROUP
            refresh: true
          - data-id: common-log.yaml        # 日志公共配置
            group: DEFAULT_GROUP
            refresh: false                  # 日志配置不动态刷新——改日志级别才需要

        # ② extension-configs——当前服务专属——比 shared 优先级高
        extension-configs:
          - data-id: order-service-custom.yaml
            group: DEFAULT_GROUP
            refresh: true
```

### 2.2 Nacos Dashboard 中创建公共配置

```
Nacos Dashboard → 配置管理 → 配置列表 → 新建配置

① common-mysql.yaml (DEFAULT_GROUP):
spring:
  datasource:
    url: jdbc:mysql://mysql-master:3306/
    username: app_user
    password: ${MYSQL_PASSWORD}    # ← 密码用环境变量——不写在配置中心
    hikari:
      maximum-pool-size: 20
      minimum-idle: 5
      connection-timeout: 3000

② common-redis.yaml (DEFAULT_GROUP):
spring:
  redis:
    host: redis-cluster.internal
    port: 6379
    lettuce:
      pool:
        max-active: 20
        max-idle: 10

③ order-service-dev.yaml (DEFAULT_GROUP):
# 订单服务专属配置——覆盖或扩展公共配置
spring:
  datasource:
    url: jdbc:mysql://mysql-master:3306/order_db?useSSL=false  # 覆盖——订单库
    hikari:
      maximum-pool-size: 50   # 覆盖公共配置——订单服务连接池要大一些

app:
  order:
    max-items-per-order: 50
    payment-timeout-seconds: 1800
```

### 2.3 配置加载的优先级——哪个生效？

当同一个配置在多个地方出现时——<strong>后加载的覆盖先加载的</strong>：

```
加载顺序（越晚越优先——后面的覆盖前面的）：
  ① shared-configs[0] → common-mysql.yaml
  ② shared-configs[1] → common-redis.yaml
  ③ shared-configs[2] → common-log.yaml
  ④ extension-configs  → order-service-custom.yaml
  ⑤ 服务专属配置        → order-service-dev.yaml
  ⑥ application.yml     → 本地（Nacos 连不上时的兜底）

结果：
  spring.datasource.url = order-service-dev.yaml 中的值（优先级最高）
  spring.datasource.hikari.maximum-pool-size = order-service-dev.yaml 中的 50
  spring.redis.host = common-redis.yaml 中的值（订单服务没覆盖——用公共的）
```

> ⚠️ 新手提示：公共配置中的值会被服务专属配置<strong>完全覆盖</strong>——不是合并。如果 `common-mysql.yaml` 中有 5 个 Hikari 配置——`order-service-dev.yaml` 只覆盖了 1 个——其他 4 个还是公共配置的值。

## 三、🔄 @RefreshScope 的原理与陷阱

### 3.1 为什么加了 @RefreshScope 就能动态刷新？

```java
// 普通 Bean——每个属性值启动时注入一次——以后不变
@Component
public class NormalBean {
    @Value("${app.timeout}")
    private int timeout;  // 启动时 = 30——永远是 30——直到重启
}

// @RefreshScope Bean——Nacos 配置变了 → Spring 容器销毁这个 Bean → 重新创建
@Configuration
@RefreshScope
public class RefreshableBean {
    @Value("${app.timeout}")
    private int timeout;  // 启动时 = 30 → Nacos 改成 60 → Bean 重建 → timeout = 60
}
```

<strong>@RefreshScope 做的事</strong>：当监听到 Nacos 配置变更——它<strong>销毁</strong>被标注的 Bean，让下次使用时<strong>重新创建</strong>。不是"修改内存里的值"——是"废弃旧的、创建新的"。

### 3.2 陷阱——三层刷新误区

| 陷阱 | 表现 | 正确做法 |
|------|------|------|
| <strong>@Value 拿不到新值</strong> | Bean 没加 `@RefreshScope`——值没变 | 把读取配置的 Bean 加上 `@RefreshScope` |
| <strong>修改 shared-configs 没生效</strong> | `shared-configs` 中 `refresh: false` | 把 `refresh: true` |
| <strong>数据库连接池变了但没刷新</strong> | `@RefreshScope` 不管 DataSource | HikariPool 不支持热更新连接池大小——需要重启 |
| <strong>修改 Nacos 配置后服务没反应</strong> | `spring.cloud.nacos.config.enabled: false` | 去掉这行——或者确认 Nacos Config 已引入 |

### 3.3 什么配置该刷新——什么不该

```yaml
# ✅ 适合动态刷新的配置
app:
  feature-flags:
    enable-new-recommend: true       # 功能开关——随时切换
  rate-limit:
    qps: 100                         # 限流阈值——动态调整
  external-api:
    timeout: 5000                    # 超时时间——根据外部服务响应调整

# ❌ 不适合动态刷新的配置（改了也不生效——需要重启）
spring:
  datasource:
    hikari:
      maximum-pool-size: 20          # 连接池大小——Hikari 不支持热更新
  server:
    port: 8080                       # 端口——启动后改不了
  cloud:
    nacos:
      discovery:
        server-addr: localhost:8848  # Nacos 地址——改了谁来推送？
```

## 四、🌿 配置灰度发布——先让一个小范围的服务验证

Nacos 支持<strong>标签路由</strong>——让配置先在特定标签的实例上生效：

```yaml
# 灰度实例——带标签
spring:
  cloud:
    nacos:
      discovery:
        metadata:
          env: gray           # ← 打标签——这是灰度实例
          version: beta

# 正式实例——不带标签
spring:
  cloud:
    nacos:
      discovery:
        metadata:
          env: stable
```

在 Nacos Dashboard 中发布配置时——选择"灰度发布"——指定 `env=gray` 的实例先收到配置。验证没问题后再全量发布。

```
灰度发布流程：
  ① 在 Nacos 新建灰度配置——指定标签 env=gray
  ② 灰度实例（打标 env=gray）收到新配置——正式实例不变
  ③ 观察灰度实例指标——确认正常
  ④ 全量发布——所有实例收到新配置
  ⑤ 灰度实例恢复正常——不再特殊
```

```yaml
# 灰度实例的完整配置
spring:
  cloud:
    nacos:
      discovery:
        metadata:
          env: gray
          version: beta-1.2.3
      config:
        # 灰度实例可以从特殊的 namespace 拿配置
        namespace: gray-test
```

## 五、🔗 串联：Gateway 路由规则存 Nacos——动态生效

Gateway 的路由默认写在 `application.yml` 里——改动需要重启。把路由配置存 Nacos——改完实时生效：

```yaml
# Gateway 的 bootstrap.yml
spring:
  cloud:
    nacos:
      config:
        server-addr: localhost:8848
        namespace: production
        group: GATEWAY_GROUP
        file-extension: yaml
        # 加载 Gateway 专用的路由配置
        extension-configs:
          - data-id: gateway-routes.yaml
            group: GATEWAY_GROUP
            refresh: true
```

在 Nacos 中新建 `gateway-routes.yaml` —— 内容就是 Gateway 的 routes 部分：

```yaml
# Nacos: gateway-routes.yaml (GATEWAY_GROUP)
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
            - name: RequestRateLimiter
              args:
                redis-rate-limiter.replenishRate: 50
                redis-rate-limiter.burstCapacity: 100
                key-resolver: "#{@ipKeyResolver}"

        - id: order-service
          uri: lb://order-service
          predicates:
            - Path=/api/orders/**
          filters:
            - StripPrefix=1
```

```java
// Gateway 监听 Nacos 配置变更——动态重建路由
@Component
public class GatewayRoutesRefresher implements ApplicationListener<RefreshRoutesEvent> {

    @Autowired
    private RouteDefinitionWriter routeDefinitionWriter;

    // 当 Nacos 中 gateway-routes.yaml 变更——Spring Cloud 发 RefreshRoutesEvent
    // Gateway 自动感知——不需要自己写代码

    // 如果要用 Nacos Config Listener 手动刷新——可以这样：
    @NacosConfigListener(dataId = "gateway-routes.yaml", groupId = "GATEWAY_GROUP")
    public void onRouteChange(String config) {
        // Nacos 配置变更 → 解析 JSON → 更新 RouteDefinition
        // 但通常不需要手动写——Gateway + Nacos 自动处理
    }
}
```

<strong>效果</strong>：在 Nacos Dashboard 中改 gateway-routes.yaml → 点发布 → Gateway 自动感知变更 → 路由规则实时生效——不需要重启 Gateway。

## 六、🔗 串联：Sentinel 规则持久化到 Nacos

Sentinel 规则默认存在内存——重启后全丢。把规则存 Nacos——永久保存 + 实时推送：

```yaml
# Sentinel 结合 Nacos 数据源
spring:
  cloud:
    sentinel:
      transport:
        dashboard: localhost:8080
        port: 8719
      datasource:
        # 流控规则
        flow-rules:
          nacos:
            server-addr: localhost:8848
            namespace: production
            data-id: ${spring.application.name}-flow-rules
            group-id: SENTINEL_GROUP
            data-type: json
            rule-type: flow
        # 熔断规则
        degrade-rules:
          nacos:
            server-addr: localhost:8848
            namespace: production
            data-id: ${spring.application.name}-degrade-rules
            group-id: SENTINEL_GROUP
            data-type: json
            rule-type: degrade
        # 系统规则
        system-rules:
          nacos:
            server-addr: localhost:8848
            namespace: production
            data-id: ${spring.application.name}-system-rules
            group-id: SENTINEL_GROUP
            data-type: json
            rule-type: system
```

在 Nacos 中创建 `user-service-flow-rules.json`（SENTINEL_GROUP）：

```json
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

<strong>现在 Sentinel 规则的生效路径</strong>：

```
Dashboard 修改规则 → Nacos 更新配置 → Sentinel 监听到 Nacos 变更 → 立即应用规则
服务重启 → 从 Nacos 加载规则 → 和重启前一样——不会丢
```

## 七、📦 配置中心的最佳组织实践

### 7.1 多服务项目的 Nacos 配置结构

```
Nacos Namespace: production

  Group: COMMON_GROUP
    common-mysql.yaml          ← 所有服务共用的 MySQL 连接
    common-redis.yaml          ← 所有服务共用的 Redis 连接
    common-mq.yaml             ← 所有服务共用的 RocketMQ Topic
    common-monitor.yaml        ← 所有服务共用的监控配置

  Group: SENTINEL_GROUP
    user-service-flow-rules.json
    user-service-degrade-rules.json
    order-service-flow-rules.json
    order-service-degrade-rules.json

  Group: GATEWAY_GROUP
    gateway-routes.yaml        ← Gateway 路由规则
    gateway-cors.yaml          ← Gateway CORS 配置

  Group: DEFAULT_GROUP
    user-service-prod.yaml     ← 用户服务专属配置
    order-service-prod.yaml    ← 订单服务专属配置
    product-service-prod.yaml  ← 商品服务专属配置
```

### 7.2 所有服务的 bootstrap.yml 模板

```yaml
spring:
  application:
    name: user-service
  profiles:
    active: prod
  cloud:
    nacos:
      config:
        server-addr: nacos-cluster.internal:8848
        namespace: production
        file-extension: yaml
        # 加载顺序——公共在前——专属在后
        shared-configs:
          - data-id: common-mysql.yaml
            group: COMMON_GROUP
            refresh: true
          - data-id: common-redis.yaml
            group: COMMON_GROUP
            refresh: true
          - data-id: common-mq.yaml
            group: COMMON_GROUP
            refresh: false
          - data-id: common-monitor.yaml
            group: COMMON_GROUP
            refresh: true
        extension-configs:
          - data-id: user-service-custom.yaml      # 本服务扩展配置
            group: DEFAULT_GROUP
            refresh: true
      # 服务发现也在同一个 Namespace
      discovery:
        server-addr: nacos-cluster.internal:8848
        namespace: production
```

## 🎯 总结

1. <strong>三层配置隔离（shared → extension → 专属）</strong>：公共配置放 `shared-configs`（MySQL/Redis/MQ 所有服务共享），业务配置放 `extension-configs`，服务特有配置用专属 dataId。改公共配置——所有服务同时生效。

2. <strong>@RefreshScope 的原理是销毁重建</strong>：不是修改内存中的值——是废弃旧 Bean 创建新 Bean。适合开关类、阈值类配置——不适合连接池大小、端口等启动参数。

3. <strong>Gateway 路由 + Sentinel 规则都可以存 Nacos</strong>：改路由不用重启 Gateway——改限流阈值不用重启各服务。配置中心是所有中间件的统一管理后台。

4. <strong>配置灰度——先验证后全量</strong>：用 Nacos 标签路由让灰度实例先收到新配置——观察正常后全量发布。生产改配置的必由之路。

> 📖 <strong>下一步阅读</strong>：所有中间件都通过 Nacos 串联起来了——但 Nacos 本身怎么部署？挂了怎么办？集群怎么搭？继续阅读 [<strong>Nacos 集群与生产部署——中间件整合总览</strong>]({{< relref "NacosProduction.md" >}})。
