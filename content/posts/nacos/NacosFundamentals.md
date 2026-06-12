---
title: "Nacos 核心概念与快速上手"
date: 2022-12-13T08:00:00+00:00
tags: ["服务治理", "入门指南", "SpringCloud"]
categories: ["注册中心"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "从零理解 Nacos：为什么它一个组件能替代 Eureka + Config + Bus？服务发现和配置中心的核心概念、AP/CP 模式切换（何时选 AP 何时选 CP）、namespace/group/dataId 三级隔离体系——读完部署第一个 Nacos 并跑通服务注册和动态配置刷新。"
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

# 核心概念与快速上手

## 一、⚡ 服务多了——两个最头疼的问题

微服务写到第 6 个的时候——你会发现两个问题越来越痛：

```
问题 ①：服务之间怎么找到对方？
  OrderService 调 UserService——以前一个 IP:Port 写死就行了
  现在 UserService 有 3 个实例——10.0.1.1:8081、10.0.1.2:8081、10.0.1.3:8081
  明天扩容到 5 个——OrderService 难道重新改配置上线？
  → 需要"服务发现"——调用方不关心实例在哪——找注册中心问

问题 ②：改了配置怎么让所有服务生效？
  数据库连接池从 20 改到 50——5 个服务 × 3 个实例 = 15 个 yml 文件要改
  改完还得一个个重启——重启顺序还不能乱
  → 需要"配置中心"——一处修改——所有实例自动感知
```

这两个问题的答案就是 <strong>Nacos</strong>——一个组件同时搞定<strong>服务发现</strong>和<strong>配置中心</strong>。

## 二、🧩 Nacos 是什么——一句话

Nacos（NAming and COnfiguration Service）= <strong>服务发现 + 配置中心</strong>。它是阿里开源的微服务基础设施——Spring Cloud Alibaba 的核心组件。

在 Nacos 之前——Spring Cloud 微服务需要两个组件：

```
没有 Nacos 的时代：
  Eureka（服务注册/发现） + Spring Cloud Config（配置中心） + Spring Cloud Bus（配置刷新）
  三个组件——三套配置——三种部署方式

有了 Nacos：
  Nacos 一个组件 = Eureka + Config + Bus
  一套配置——一种部署方式——学习成本砍一半
```

## 三、🏗️ 部署 Nacos Server——3 分钟跑起来

```bash
# 方式一：Docker——最快
docker run -d \
  --name nacos \
  -p 8848:8848 \
  -p 9848:9848 \
  -e MODE=standalone \
  nacos/nacos-server:v2.3.0

# 方式二：直接运行——下载后解压
# https://github.com/alibaba/nacos/releases
# 解压后
cd nacos/bin
# Windows:
startup.cmd -m standalone
# Linux/Mac:
sh startup.sh -m standalone

# 访问 http://localhost:8848/nacos
# 用户名/密码：nacos/nacos
```

<strong>两个端口的作用</strong>：

| 端口 | 用途 | 协议 |
|:---|------|------|
| <strong>8848</strong> | HTTP 端口——Dashboard + OpenAPI | HTTP |
| <strong>9848</strong> | gRPC 端口——Client 和 Server 之间的通信（Nacos 2.x 新增） | gRPC |

Nacos 2.x 把客户端和服务端的通信从 HTTP 改成了 gRPC——长连接、性能更好、支持服务端推送。

## 四、🔗 第一个服务——注册到 Nacos

### 4.1 依赖

```xml
<dependency>
    <groupId>com.alibaba.cloud</groupId>
    <artifactId>spring-cloud-starter-alibaba-nacos-discovery</artifactId>
</dependency>
```

### 4.2 配置

```yaml
spring:
  application:
    name: user-service          # ← 这个就是注册到 Nacos 的服务名
  cloud:
    nacos:
      discovery:
        server-addr: localhost:8848
        namespace: dev           # 命名空间——隔离环境
        group: DEFAULT_GROUP     # 分组——默认即可
```

### 4.3 启动

```java
@SpringBootApplication
@EnableDiscoveryClient  // ← 开启服务注册/发现——Spring Cloud 标准注解
public class UserServiceApplication {
    public static void main(String[] args) {
        SpringApplication.run(UserServiceApplication.class, args);
    }
}
```

启动后打开 Nacos Dashboard → 服务管理 → 服务列表——看到 `user-service` 已经注册上去了。

## 五、🧭 Nacos 的核心概念——名字空间、分组、服务

Nacos 用<strong>三级隔离体系</strong>来组织服务：

```
Namespace（命名空间）
  └── Group（分组）
        └── Service（服务）
              └── Instance（实例——IP:Port）
```

| 层级 | 概念 | 作用 | 典型用法 |
|------|------|------|------|
| <strong>Namespace</strong> | 命名空间——环境隔离 | 不同命名空间中的服务完全不互通 | <strong>dev / test / prod</strong>——生产服务绝不可能调到开发实例 |
| <strong>Group</strong> | 分组——更细的隔离 | 同一环境内——按业务或区域分组 | DEFAULT_GROUP / SHANGHAI_GROUP / BEIJING_GROUP |
| <strong>Service</strong> | 服务 | 一个微服务 | user-service / order-service |
| <strong>Instance</strong> | 实例 | 一个服务的一个副本 | 10.0.1.1:8081 / 10.0.1.2:8081 |

```yaml
# 开发环境
spring.cloud.nacos.discovery.namespace: dev
spring.cloud.nacos.discovery.group: DEFAULT_GROUP

# 生产环境
spring.cloud.nacos.discovery.namespace: prod
spring.cloud.nacos.discovery.group: DEFAULT_GROUP
```

<strong>Namespace 是最重要的隔离手段</strong>——生产环境绝对不能和开发环境共享同一个 Namespace。否则——开发的同学不小心把测试数据调到了生产服务——事故就是这样来的。

## 六、🔄 AP vs CP——Nacos 最独特的能力

CAP 定理说：一致性（Consistency）、可用性（Availability）、分区容错性（Partition Tolerance）——三者最多同时满足两个。

<strong>Nacos 的特殊之处——AP 和 CP 可以切换</strong>：

| 模式 | 保证 | 牺牲 | 适用场景 | 同类产品 |
|------|------|------|------|------|
| <strong>AP</strong> | 可用性——服务列表永远可查 | 强一致性——可能拿到旧数据（几秒） | <strong>服务发现</strong>（默认） | Eureka |
| <strong>CP</strong> | 一致性——数据绝对正确 | 可用性——网络分区时少数节点不可用 | <strong>配置中心</strong>——配置绝不能错 | Zookeeper、Consul |

```yaml
# 在 Nacos 中切换 AP/CP——通过 API
# 大部分场景不需要改——Nacos 默认同时支持 AP 和 CP
# 服务发现走 AP，配置中心走 CP——各取所需

# 服务注册时选择临时实例（AP）还是持久实例（CP）
spring:
  cloud:
    nacos:
      discovery:
        ephemeral: true   # true = 临时实例（AP——默认）
                          # false = 持久实例（CP——服务不下线就一直在）
```

<strong>默认行为和最佳实践</strong>：Spring Cloud 的服务注册为临时实例（AP）——服务下线后自动剔除。如果想用持久实例（CP）——服务下线后仍保留在服务列表中——适合需要人工确认后才能下线的关键服务。

## 七、⚙️ 配置中心——第一个动态刷新的配置

### 7.1 依赖

```xml
<dependency>
    <groupId>com.alibaba.cloud</groupId>
    <artifactId>spring-cloud-starter-alibaba-nacos-config</artifactId>
</dependency>
```

### 7.2 配置文件的优先级

Spring Boot 引入 Nacos Config 后——配置文件优先级（数字越小越优先）：

```
① Nacos 当前环境配置 dataId: user-service-dev.yaml
② Nacos 默认配置     dataId: user-service.yaml
③ application.yml    本地配置
④ bootstrap.yml      引导配置（如果需要连 Nacos 才能启动）
```

### 7.3 Nacos 中的配置 DataId 规则

```
dataId = ${prefix}-${spring.profiles.active}.${file-extension}

示例：
  spring.application.name = user-service
  spring.profiles.active = dev
  file-extension = yaml
  → dataId = user-service-dev.yaml
```

### 7.4 在 Nacos Dashboard 中添加配置

```
Nacos Dashboard → 配置管理 → 配置列表 → 新建配置

Data ID:   user-service-dev.yaml
Group:     DEFAULT_GROUP
配置格式:  YAML

配置内容：
spring:
  datasource:
    url: jdbc:mysql://localhost:3306/user_db?useSSL=false
    username: root
    password: root123
    hikari:
      maximum-pool-size: 20
      minimum-idle: 5
  redis:
    host: localhost
    port: 6379

# 业务配置——放在顶层
app:
  user:
    max-login-attempts: 5
    session-timeout-minutes: 30
```

### 7.5 代码中读取并动态刷新

```java
@RestController
@RequestMapping("/api/config")
// @RefreshScope——Nacos 配置变了——这个 Bean 自动重新创建——拿到新值
@RefreshScope
public class ConfigController {

    // 读取 Nacos 中的配置——和读取本地 yml 一模一样
    @Value("${app.user.max-login-attempts}")
    private int maxLoginAttempts;

    @Value("${app.user.session-timeout-minutes}")
    private int sessionTimeout;

    @GetMapping("/login-config")
    public Map<String, Object> getLoginConfig() {
        return Map.of(
                "maxLoginAttempts", maxLoginAttempts,
                "sessionTimeout", sessionTimeout
        );
    }
}
```

<strong>动态刷新的效果</strong>：在 Nacos Dashboard 中把 `max-login-attempts` 从 5 改成 3 → 点发布 → 不需要重启应用——调 `/api/config/login-config` 返回的就是 3。

### 7.6 `@RefreshScope` 的推荐用法

| 适用 | 不适用 |
|------|------|
| 开关类配置——功能开关、调试级别 | 框架底层配置——数据库连接池、RPC 线程数 |
| 业务参数——超时时间、阈值 | 启动参数——端口、服务名 |
| 外部服务地址——第三方 API URL | 安全配置——密码改了重启动更可靠 |

```java
// ✅ @RefreshScope 用在 Controller 或专门的 @ConfigurationProperties Bean
@Configuration
@ConfigurationProperties(prefix = "app.user")
@RefreshScope
public class UserConfigProperties {
    private int maxLoginAttempts;
    private int sessionTimeoutMinutes;
    // getter / setter
}

// ❌ 不要用在 @Service / @Repository 上——业务 Bean 重创建开销大
```

## 八、🖥️ Nacos Dashboard 快速导航

```
Nacos Dashboard (http://localhost:8848/nacos) 的核心菜单：

① 服务管理 → 服务列表
   看所有已注册的服务——每个服务有几个实例——健康状态如何

② 服务管理 → 订阅者列表
   谁在调用这个服务——调用方列表

③ 配置管理 → 配置列表
   所有配置项——增删改查——发布——历史版本回滚

④ 配置管理 → 监听查询
   当配置变了——哪些服务会收到推送

⑤ 命名空间
   创建 dev/test/prod 命名空间——生成独立的 namespace-id
```

## 🎯 总结

1. <strong>Nacos = 服务发现 + 配置中心</strong>：一个组件替代 Eureka + Config + Bus。Nacos 2.x 客户端通信用 gRPC 长连接——比 HTTP 轮询效率高。

2. <strong>Namespace 是环境隔离的核心</strong>：生产服务绝不能和开发服务在同一个 Namespace。Group 是二级隔离——按业务或区域分组。

3. <strong>AP 和 CP 各取所需</strong>：服务发现走 AP（临时实例——下线自动剔除），配置中心走 CP（配置绝不能出错）。Nacos 是唯一同时支持两种模式的注册中心。

4. <strong>`@RefreshScope` 让配置修改不重启</strong>：功能开关、业务参数、阈值——在 Nacos Dashboard 中改了立刻生效。生产改配置不再需要重启服务。

> 📖 <strong>下一步阅读</strong>：服务注册上去了——但 Nacos 怎么判断一个服务是不是健康的？心跳机制是什么？临时实例和持久实例有什么区别？Dubbo/OpenFeign/gRPC 怎么通过 Nacos 发现服务？继续阅读 [<strong>Nacos 服务发现深度解析</strong>]({{< relref "NacosServiceDiscovery.md" >}})。
