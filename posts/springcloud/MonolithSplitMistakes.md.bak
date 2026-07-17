---
title: "单体拆分微服务：9 个服务踩出来的 7 个典型错误"
date: 2023-03-06T11:30:03+00:00
tags: ["SpringCloud", "工程实践", "原理解析"]
categories: ["技术类"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "接手一套从单体拆分的 Spring Cloud Alibaba 项目，本以为只是熟悉业务，结果发现 9 个服务里藏了 7 个典型拆分错误——从全量包扫描到依赖管理混乱，逐一拆解并给出改进方案。"
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
    relative: true
    hidden: false
---
# 单体拆微服务，这 7 个坑你踩过几个？

接手了一套从单体架构拆分为微服务的 Spring Cloud Alibaba 项目。9 个服务，Spring Boot 3.3.5，集齐了 Nacos、Gateway、Sentinel、RocketMQ、ShardingSphere、Elasticsearch 全家桶——看 POM 文件像一份微服务教科书。

实际跑起来就发现问题了：**项目虽然拆成了 9 个模块，但在架构思维上仍然是个单体。** 用了微服务的壳，没改掉单体时代的坏习惯。一顿排查下来，发现了 7 个典型错误。

## 错误一：全量包扫描——每个服务都在扫整个宇宙

第一个映入眼帘的就是各个 Application 类上的注解：

`` `java
@ComponentScan(basePackages = "cn.net.mall")
```

9 个服务里有好几个直接扫整个项目包树。这意味着什么？ `mall-pay` 启动的时候，Spring 会去扫描 `mall-common` 下的所有类，包括 `cn.net.mall.util.RedisUtil `。而 `RedisUtil` 又依赖 `StringRedisTemplate `，这个类来自 `spring-boot-starter-data-redis `，偏偏 `mall-pay` 的 POM 里没加这个依赖。

```
mall-pay 启动 → 扫描 cn.net.mall → 发现 RedisUtil → 尝试创建 → StringRedisTemplate 不在 classpath → ClassNotFoundException → 启动失败
```

`` `mermaid
flowchart LR
    subgraph SCAN["全量扫描 `cn.net.mall `"]
        PAY["mall-pay\n@ComponentScan"]
        COMMON["mall-common\nRedisUtil ← 依赖 → StringRedisTemplate"]
    end

    subgraph CLASSPATH["pay 的 classpath"]
        DEPS["mall-common.jar\n（但有 optional=true）"]
        MISSING["❌ StringRedisTemplate 不在"]
    end

    PAY -->|"扫描到"| COMMON
    COMMON -.->|"尝试创建 bean"| MISSING
    MISSING -->|"ClassNotFoundException"| CRASH["启动崩溃"]

    classDef process fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#e5e7eb;
    classDef reject fill:#450a0a,stroke:#dc2626,stroke-width:2px,color:#fecaca;
    classDef highlight fill:#431407,stroke:#ea580c,stroke-width:2px,color:#fed7aa;
    class PAY,COMMON process;
    class MISSING,CRASH reject;
    class DEPS highlight;
```

更隐蔽的问题是：**全量扫描让分仓库成为泡影。** 微服务的核心理念之一就是独立开发、独立部署。如果每个服务都假设"所有模块在同一个 classpath 上"，那一旦把服务拆到独立 Git 仓库，全量扫描就会漏掉其他服务的类——因为它根本不在 classpath 上。

**改进方案：** 每个服务的 `@SpringBootApplication` 只扫自身包路径，Feign 客户端精确声明到具体 client 包：

`` `java
// ❌ 错误写法：扫全量
@ComponentScan(basePackages = "cn.net.mall")

// ✅ 正确写法：限缩到自身
@SpringBootApplication(scanBasePackages = {"cn.net.mall.pay"})
@EnableFeignClients(basePackages = {"cn.net.mall.pay", "cn.net.mall.order.client"})
```

## 错误二：公共模块无差别加载——没有条件注解，只有统统加载

`mall-common` 里放了一个 `MallCommonAutoConfiguration `，通过 `AutoConfiguration.imports` 全局注册，然后用 `@ComponentScan` 统一扫描几个公共包：

`` `java
@AutoConfiguration
@ComponentScan(basePackages = {
    "cn.net.mall.config",
    "cn.net.mall.helper",
    "cn.net.mall.util",
    // ...
})
public class MallCommonAutoConfiguration {}
```

这相当于给所有依赖 `mall-common` 的服务强行注入了一整套 bean——不管服务用不用 Redis、用不用 Token 校验、用不用敏感词过滤。一旦某个服务的 classpath 缺了某个依赖，整个启动就崩了。

`` `mermaid
flowchart TD
    subgraph COMMON_MODULE["mall-common（AutoConfiguration.imports）"]
        MCA["MallCommonAutoConfiguration\n无条件 @ComponentScan"]
        REDIS["RedisUtil"]
        TOKEN["TokenHelper"]
        SENSITIVE["SensitiveService"]
        WORKID["WorkIdAllocator"]
    end

    subgraph SERVICES["各微服务"]
        AUTH["mall-auth ✅\n有 redisson 依赖"]
        PAY["mall-pay ❌\n无 redisson 依赖"]
    end

    MCA -->|"全部加载"| REDIS & TOKEN & SENSITIVE & WORKID
    REDIS -->|"StringRedisTemplate 可用"| AUTH
    REDIS -->|"StringRedisTemplate 不存在"| PAY
    PAY --> CRASH(["ClassNotFoundException\n启动失败"])

    classDef process fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#e5e7eb;
    classDef reject fill:#450a0a,stroke:#dc2626,stroke-width:2px,color:#fecaca;
    classDef data fill:#052e16,stroke:#16a34a,stroke-width:2px,color:#bbf7d0;
    class MCA,REDIS,TOKEN,SENSITIVE,WORKID process;
    class PAY,CRASH reject;
    class AUTH data;
```

**改进方案：** 每个公共组件应该用 `@ConditionalOnClass` 按条件加载：

`` `java
@AutoConfiguration
@ConditionalOnClass(StringRedisTemplate.class)  // ← 没有 redis 就不激活
public class RedisAutoConfiguration {
    @Bean
    public RedisUtil redisUtil(StringRedisTemplate template) {
        return new RedisUtil(template);
    }
}
```

## 错误三：Starter 机制缺失——公共组件没有独立封装

`mall-common` 承担了过多的职责：

| 功能 | 当前归属 | 应该归属 |
|------|----------|----------|
| Redis 工具类 + Token 校验 | mall-common | mall-redis-spring-boot-starter |
| 雪花算法 ID 生成 | mall-common | mall-workid-spring-boot-starter |
| 敏感词过滤 | mall-common | mall-sensitive-spring-boot-starter |
| 全局异常处理 | mall-common | mall-web-spring-boot-starter |
| 通用拦截器 | mall-common | mall-web-spring-boot-starter |

把所有东西塞进一个 common 模块，然后靠 `@ComponentScan` 一次性扫描，这本质上是**单体的"工具包"思维**——"把所有工具放一个包里，谁要用谁拿"。微服务下的正确做法是拆成独立的 starter，每个 starter 有自己的版本号、条件注解、按需加载。

`` `mermaid
flowchart LR
    subgraph BEFORE["当前：common 大杂烩"]
        C["mall-common\nRedisUtil\nTokenHelper\nWorkIdAllocator\n敏感词\n全局异常"]
        S1["mall-auth"] -->|"依赖"| C
        S2["mall-pay"] -->|"依赖"| C
        S3["mall-product"] -->|"依赖"| C
    end

    subgraph AFTER["改进：独立 starter"]
        R["mall-redis-starter\n@ConditionalOnClass"]
        W["mall-workid-starter\n@ConditionalOnClass"]
        SEN["mall-sensitive-starter\n@ConditionalOnClass"]
        S1_AFTER["mall-auth"] -->|"按需引入"| R & W
        S2_AFTER["mall-pay"] -->|"按需引入"| W
        S3_AFTER["mall-product"] -->|"按需引入"| R & W & SEN
    end

    BEFORE -->|"重构方向"| AFTER

    classDef reject fill:#450a0a,stroke:#dc2626,stroke-width:2px,color:#fecaca;
    classDef data fill:#052e16,stroke:#16a34a,stroke-width:2px,color:#bbf7d0;
    classDef process fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#e5e7eb;
    class C,S1,S2,S3 reject;
    class R,W,SEN,S1_AFTER,S2_AFTER,S3_AFTER data;
    class BEFORE,AFTER process;
```

## 错误四：依赖管理混乱——optional 遍地，死依赖成堆

检查各服务的 POM 时发现了一个规律： `mall-common` 里几乎所有中间件依赖都打了 `<optional>true</optional>`：

`` `xml
<!-- mall-common/pom.xml -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-redis</artifactId>
    <optional>true</optional>
</dependency>
<dependency>
    <groupId>org.redisson</groupId>
    <artifactId>redisson-spring-boot-starter</artifactId>
    <optional>true</optional>
</dependency>
```

这意味着依赖不会传递。每个具体服务必须自己在 POM 里再声明一次。但 9 个服务里只有 7 个加了 redis 依赖， `mall-pay` 和 `mall-gateway` 漏掉了，导致运行时 classpath 上缺少 `StringRedisTemplate `。

更搞笑的是，全项目没有一个服务用到 RabbitMQ，但有 4 个服务的 POM 里赫然写着：

`` `xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-amqp</artifactId>
</dependency>
```

不用的依赖写在 POM 里，唯一的贡献就是让启动日志多一行 `Rabbit health check failed `。

**改进方案：** 定期清理 POM 中的死依赖，用 `mvn dependency:analyze` 可以检测未使用的依赖。

## 错误五：配置迁移不完整——从本地搬到 Nacos，搬了一半

项目原来的配置分布在各服务的本地 `application.yml` 中，重构时决定统一迁到 Nacos 配置中心。思路是对的，但执行是灾难性的——每迁移一个服务就漏几个配置项。

典型的表现是：**A 服务启动正常，B 服务启动报错，查了半天发现 B 的 Nacos 配置里少了两个字段。** 因为每个服务的配置结构都不一样——有人把 ES 配在 `spring.elasticsearch.host `，有人用 `spring.data.elasticsearch.uris `，搬的时候只搬了看得见的，漏了藏在代码 `@Value` 注解里的。

`` `mermaid
flowchart LR
    subgraph LOCAL["迁移前：分散在本地"]
        L1["mall-product\napplication.yml\n（含 ES、RocketMQ）"]
        L2["mall-order\napplication.yml\n（含 Redis、分库分表）"]
    end

    subgraph NACOS["迁移后：统一配置中心"]
        N1["mall-product-api-dev.yaml\n❌ 漏了 ES 配置"]
        N2["mall-order-api-dev.yaml\n❌ 漏了 RocketMQ"]
    end

    L1 -->|"手工搬运"| N1
    L2 -->|"手工搬运"| N2
    N1 -->|"启动崩溃"| CRASH1["EsConfig\nHost name may not be empty"]
    N2 -->|"启动崩溃"| CRASH2["RocketMQ\nconnect to [] failed"]

    classDef reject fill:#450a0a,stroke:#dc2626,stroke-width:2px,color:#fecaca;
    classDef process fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#e5e7eb;
    class N1,N2,CRASH1,CRASH2 reject;
    class L1,L2 process;
```

**改进方案：** 配置迁移前先枚举所有 `@Value` 注解、所有 `spring.*` 配置项，和老配置逐条比对。或者直接用脚本从远程 Nacos 拉取配置做 diff。

## 错误六：BOM 版本覆盖——依赖冲突静默发生

根 POM 中通过 `dependencyManagement` 导入了 `spring-cloud-alibaba-dependencies:2023.0.1.0 `：

`` `xml
<dependencyManagement>
    <dependencies>
        <dependency>
            <groupId>com.alibaba.cloud</groupId>
            <artifactId>spring-cloud-alibaba-dependencies</artifactId>
            <version>2023.0.1.0</version>
            <type>pom</type>
            <scope>import</scope>
        </dependency>
    </dependencies>
</dependencyManagement>
```

这个 BOM 里有一条不起眼的配置：

`` `xml
<rocketmq.version>5.1.4</rocketmq.version>
```

而项目用的 `rocketmq-spring-boot-starter:2.1.1 `（2020 年发布）的代码里引用了 `org.apache.rocketmq.common.protocol.heartbeat.MessageModel` 这个类——**它在 RocketMQ 5.x 中被移除了**。

```
Alibaba BOM → rocketmq-client:5.1.4 → ❌ MessageModel 不存在
starter 父 POM → rocketmq-client:4.7.1 → ✅ 有 MessageModel
```

正常启动时如果只是发消息不会触发这个类加载，但一旦有 `@RocketMQMessageListener` 注解，消息监听容器初始化时就会加载 `MessageModel `，然后直接 ClassNotFoundException。

**改进方案：** 根 POM 中统一锁定 RocketMQ 版本，覆盖 BOM 带来的错误版本：

`` `xml
<dependency>
    <groupId>org.apache.rocketmq</groupId>
    <artifactId>rocketmq-client</artifactId>
    <version>4.9.4</version>
</dependency>
```

## 错误七：Bean 注入方式不统一——有的降级，有的硬刚

同一个 `RocketMQTemplate `，三个服务三种写法：

| 服务 | 注入方式 | 没 RocketMQ 时的表现 |
|------|----------|-------------------|
| mall-order | 自定义 `@Bean` 创建 | 始终能用 |
| mall-product | `ObjectProvider<RocketMQTemplate>` | 优雅跳过，不报错 |
| mall-basic | 直接 `@Autowired RocketMQTemplate` | **启动崩溃** |

`` `java
// mall-basic（❌ 直接注入——没有就崩）
public MqHelper(RocketMQTemplate rocketMQTemplate) {
    this.rocketMQTemplate = rocketMQTemplate;
}

// mall-product（✅ ObjectProvider——没有就跳过）
public MqHelper(ObjectProvider<RocketMQTemplate> provider) {
    this.rocketMQTemplateProvider = provider;
}
public void send(String topic, Object data) {
    RocketMQTemplate template = rocketMQTemplateProvider.getIfAvailable();
    if (template == null) {
        log.warn("RocketMQTemplate不存在，跳过发送");
        return;
    }
    // ...
}
```

对于可选组件（RocketMQ、Redis 等本地开发不一定要启动的服务），用 `ObjectProvider` 是更健壮的做法——不想配就不配，发了消息也只是打个日志。

## 这些错误的共同根源

回头看这 7 个错误，发现它们都指向同一个问题：**拆分架构了，但没拆分思维。**

- 全量扫描 → 还是单体时代"一个项目一个包"的习惯
- 公共模块无差别加载 → 还是"所有工具放一个包"的 utils 思维
- 没有 starter → 不知道或者懒得拆，common 一把梭
- 依赖随意 → POM 复制粘贴，没人清理
- 配置搬家漏一半 → 没有系统化的迁移方案
- BOM 版本冲突 → 升级只改了版本号，没验证兼容性
- 注入方式不统一 → 没有团队的代码规范

微服务拆分不只是在 POM 文件里加几个模块，也不只是在 Nacos 上建几个 dataId。**真正的拆分是把"一个什么都能干的大项目"变成"一群各司其职的小项目"——每个小项目有自己独立的边界、独立的依赖、独立的生命周期。** 这是个好目标，但不是拆完就自动实现的。

## 从这 7 个错误中学到的拆分原则

### 原则一：按需引入，而非全量继承

根 POM 的 `dependencyManagement` 和 `mall-common` 是两种完全不同的角色，混在一起用是最大的问题。

`` `mermaid
flowchart TD
    subgraph WRONG["目前的做法"]
        ROOT["根 POM
dependencyManagement
管理版本 + 声明依赖"]
        COMMON["mall-common
管理公共代码 + 中间件依赖"]
        S1["mall-auth"] -->|"继承一切"| ROOT
        S1 -->|"继承一切"| COMMON
        S2["mall-pay"] -->|"继承一切"| ROOT
        S2 -->|"继承一切"| COMMON
    end

    subgraph RIGHT["正确的做法"]
        BOM["根 POM（BOM）
只管理版本，不声明依赖"]
        LIB1["mall-redis-starter
独立封装"]
        LIB2["mall-workid-starter
独立封装"]
        LIB3["mall-sensitive-starter
独立封装"]
        S1_OK["mall-auth"] -->|"按需引入"| LIB1 & LIB2
        S2_OK["mall-pay"] -->|"按需引入"| LIB2
    end

    WRONG -->|"重构方向"| RIGHT

    classDef reject fill:#450a0a,stroke:#dc2626,stroke-width:2px,color:#fecaca;
    classDef data fill:#052e16,stroke:#16a34a,stroke-width:2px,color:#bbf7d0;
    classDef process fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#e5e7eb;
    class WRONG,ROOT,COMMON,S1,S2 reject;
    class RIGHT,BOM,LIB1,LIB2,LIB3,S1_OK,S2_OK data;
```

**根 POM** 应该只做一件事：统一管理依赖版本（Bill of Materials，BOM）。它声明版本号，但不声明具体依赖。各服务在需要时才在自 POM 中声明依赖，版本从根 POM 继承。

** `mall-common `** 的角色应该是"被拆散"的——它的每一个功能模块都应该是一个独立的 starter。服务按需引入，不用的就不加到 classpath 上。

> 一个服务该引入什么依赖，取决于它干了什么，不取决于它和谁在同一个仓库里。如果"因为其他服务都用 redis 所以我也得带上"——这就是单体思维。

### 原则二：依赖可见性原则——依赖是契约，不是赠品

每个 POM 里的 `<dependency>` 都是一个显式声明。如果 A 服务用到了 Redis，它就应该自己在 POM 里写 `<dependency>` 声明 `spring-boot-starter-data-redis `，而不是指望 `mall-common` 通过 `<optional>true</optional>` 传递过来。

这条原则落地很简单：**不允许通过传递依赖获取运行时需要的 jar**。所有运行时必须的依赖，必须在当前模块的 POM 中显式声明。 `mvn dependency:analyze` 可以用来检测哪些传递依赖被隐式使用了，然后显式加上。

### 原则三：接口稳定性原则——拆分从 API 开始，不是从实现开始

很多团队拆微服务的顺序是反的：先拆模块、建目录、搬代码，然后发现依赖一团糟。正确顺序应该是：

   第一步：定义 API 契约（Feign 接口 + DTO）
   第二步：验证契约的完整性（API 提供方能满足所有消费方的需求吗？）
   第三步：实现拆分（把 API 和实现放到不同模块）
   第四步：独立构建验证（不依赖其他模块的实现也能编译通过吗？）

这个项目里普遍存在的"全量扫描 Feign 客户端"就是因为跳过了一二步——API 边界都没理清楚，直接进入第三步了。

### 原则四：最小依赖原则——一个服务启动所需的依赖应当尽可能少

一个典型的微服务应该只需要：

   Web 容器 + 服务发现 + 配置中心 + 自身业务依赖

而不是：

   Web 容器 + 服务发现 + 配置中心 + Redis + RocketMQ + ES + MongoDB + RabbitMQ + ShardingSphere + 所有 common 代码

每多一个依赖，启动时就多一个潜在的失败点。检查清单里应该有一条："这个服务真的需要这个中间件吗？"

## 如果你是负责拆分的人，首先应该做什么？

接手这类项目，最容易犯的错误就是**上来就改代码**。正确的第一步不是动 POM，而是做三件事：

### 1. 画依赖图

搞清楚当前的服务依赖关系。用 `mvn dependency:tree` 生成每个服务的依赖树，找出：

- 哪些依赖是真正用到的（在 `import` 语句中出现过）
- 哪些依赖是传递进来的（服务自己甚至不知道它的存在）
- 哪些服务之间存在编译期依赖（A 服务需要 B 服务的类才能编译）

`` `bash
# 找出每个服务实际的编译依赖
mvn dependency:tree -pl mall-pay -Dincludes=cn.net.mall
# 找出未使用的声明依赖
mvn dependency:analyze -pl mall-pay
```

### 2. 识别共享边界

把所有公共代码（common 模块）按功能分类，画一张类似这样的表：

| 功能 | 被哪些服务使用 | 是否可选 | 建议 |
|------|--------------|---------|------|
| `RedisUtil` | 6 个服务 | 是 | 拆成独立 starter，`@ConditionalOnClass` |
| `TokenHelper` | 3 个服务 | 是 | 随 Redis starter 一起 |
| `WorkIdAllocator` | 使用 Feign 的服务 | 是 | 拆成独立 starter |
| `SensitiveService` | 1 个服务 | 是 | 拆成独立 starter |
| 全局异常处理 | 所有 Web 服务 | 否 | 可以保留在 common 或拆成 web-starter |
| 通用拦截器 | 所有 Web 服务 | 否 | 随全局异常一起 |

可选的组件必须先拆，因为它们才是导致"缺依赖就崩"的根源。

### 3. 确定拆分优先级

不是所有错误都要同时修的。按影响范围排优先级：

**P0 — 不改就跑不起来**
- 包扫描限缩（修复 ClassNotFoundException）
- 依赖补齐（修复 classpath 缺失）
- BOM 版本锁定（修复 RocketMQ 等版本冲突）

**P1 — 能跑但不规范**
- 公共组件 Starter 化
- 消除 `MallCommonAutoConfiguration` 的全局扫描
- 统一 Bean 注入方式

**P2 — 长期治理**
- 配置迁移自动化
- 独立仓库拆分
- ArchUnit 架构约束

这三步做完，才应该开始改第一行代码。**拆分的核心不是拆分本身，而是理解边界。边界理清楚了，拆分是自然而然的结果。**

## 后续改进建议

基于这 7 个错误，这里有一条可执行的改进路线：

### 短期（1-2 周）

- **统一包扫描范围** — 检查所有服务的 `@SpringBootApplication `、`@ComponentScan `、`@EnableFeignClients `，确保都限缩到具体包路径，没有扫全量的
- **清理死依赖** — 对每个服务跑 `mvn dependency:analyze `，删除未使用的依赖声明。重点关注全项目无代码引用但 POM 里写着的 `spring-boot-starter-amqp`
- **统一 RocketMQ 版本** — 在根 POM 的 `dependencyManagement` 中锁定 `rocketmq-client `、 `rocketmq-common` 等版本为 4.9.4，防止 Alibaba BOM 覆盖
- **补齐缺失依赖** — 对比 `mall-auth `（能正常运行的基准服务）和 `mall-pay `、 `mall-gateway` 的 POM，将漏掉的 redis 依赖补齐

### 中期（1-2 个月）

- **公共组件 Starter 化** — 将 `RedisUtil `、 `TokenHelper `、雪花算法 `WorkIdAllocator` 等从 `mall-common` 中逐个拆出，封装为独立的 Spring Boot Starter，每个 starter 用 `@ConditionalOnClass` 按需加载。推荐拆分顺序：

  ```
  mall-common
    -> mall-redis-spring-boot-starter    （RedisUtil、TokenHelper）
    -> mall-workid-spring-boot-starter   （雪花算法）
    -> mall-sensitive-spring-boot-starter（敏感词过滤）
    -> mall-web-spring-boot-starter      （全局异常、拦截器）
  ```

- **消除 MallCommonAutoConfiguration** — 待所有组件拆成独立 starter 后， `MallCommonAutoConfiguration` 的 `@ComponentScan` 就不再需要了，可以删除

- **统一 Bean 注入规范** — 团队约定：对于可选中间件（RocketMQ、Redis 等），统一使用 `ObjectProvider` 而非直接 `@Autowired `，确保缺依赖时优雅降级而不是启动崩溃

### 长期（3-6 个月）

- **配置迁移自动化** — 生成每个服务的配置清单（枚举所有 `@Value `、`@ConfigurationProperties `），与 Nacos 上的 dataId 做 Diff，迁移不再靠手工

- **独立仓库拆分** — 在上述重构完成后，将每个服务拆到独立 Git 仓库，利用独立 CI/CD 流水线验证每个服务的独立构建和部署能力

- **引入 ArchUnit 等架构约束工具** — 用单元测试来强制执行架构规范，例如：

  `` `java
  // 禁止全量包扫描
  classes().that().areAnnotatedWith(SpringBootApplication.class)
      .should().haveField("scanBasePackages")
      .and().haveField("scanBasePackages").not().contain("cn.net.mall");
  // 禁止 Optional 依赖的误用
  classes().that().resideInAPackage("..common..")
      .should().onlyDependOnClassesThat().resideInAnyPackage("..springframework..", "..lombok..");
  ```

### 检查清单：新服务上线前

| 检查项 | 方法 |
|--------|------|
| 包扫描是否限缩 | 查看 `@SpringBootApplication(scanBasePackages)` |
| Feign 扫描是否精确 | 查看 `@EnableFeignClients(basePackages)` |
| 是否有未使用的依赖 | `mvn dependency:analyze` |
| RocketMQ 版本是否一致 | 查看 `mvn dependency:tree -Dincludes=org.apache.rocketmq` |
| 配置是否全部迁到 Nacos | 对比本地 yml 和 Nacos dataId 的内容 |
| Bean 注入方式是否统一 | 搜索 `@Autowired.*RocketMQTemplate` 或 `RedisUtil` 等关键类 |

## 分仓库后的 POM 和 Client 管理方案

前面的改进建议中提到了"独立仓库拆分"是长期目标，但拆分后最大的挑战是：**各仓库如何统一版本？Client 模块怎么管理？**

### 方案：BOM + 独立 Client + Starter 化

不要试图保留一个"超级根 POM"来管理所有仓库的版本，也不要让每个仓库自己声明全套版本。正确做法是抽一个 **BOM 模块**：

`` `mermaid
flowchart LR
    subgraph BOM["仓库1: mall-cloud-bom"]
        B["发布到 Nexus\n各服务仓库通过\nimport 引用此 BOM"]
    end

    subgraph CLIENTS["独立发布到 Nexus"]
        OC["mall-order-client:1.2.0"]
        PC["mall-pay-client:1.0.0"]
        RC["mall-redis-starter:1.0.0"]
    end

    subgraph SERVICES["各服务独立仓库"]
        ORDER["mall-order\n引用 BOM + order-client"]
        PAY["mall-pay\n引用 BOM + order-client 1.2.0\n + redis-starter"]
    end

    B -->|"统一版本"| ORDER & PAY
    OC -->|"发布"| ORDER & PAY
    PC -->|"发布"| PAY
    RC -->|"发布"| ORDER & PAY

    classDef process fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#e5e7eb;
    classDef data fill:#052e16,stroke:#16a34a,stroke-width:2px,color:#bbf7d0;
    class B,OC,PC,RC data;
    class ORDER,PAY process;
```

### BOM 模块（mall-cloud-bom）

这是一个独立的 Maven 模块，**只包含 `<dependencyManagement>`，没有任何业务代码**，独立发布到私有 Maven 仓库（Nexus / Artifactory）：

`` `xml
<!-- mall-cloud-bom/pom.xml -->
<artifactId>mall-cloud-bom</artifactId>
<packaging>pom</packaging>

<dependencyManagement>
    <dependencies>
        <!-- 第三方 BOM 导入 -->
        <dependency>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-dependencies</artifactId>
            <version>3.3.5</version>
            <type>pom</type>
            <scope>import</scope>
        </dependency>
        <dependency>
            <groupId>com.alibaba.cloud</groupId>
            <artifactId>spring-cloud-alibaba-dependencies</artifactId>
            <version>2023.0.1.0</version>
            <type>pom</type>
            <scope>import</scope>
        </dependency>

        <!-- 统一锁定被 BOM 覆盖的版本 -->
        <dependency>
            <groupId>org.apache.rocketmq</groupId>
            <artifactId>rocketmq-client</artifactId>
            <version>4.9.4</version>
        </dependency>

        <!-- 各 Client 和 Starter 的版本 -->
        <dependency>
            <groupId>cn.net.mall</groupId>
            <artifactId>mall-order-client</artifactId>
            <version>${mall-order-client.version}</version>
        </dependency>
        <dependency>
            <groupId>cn.net.mall</groupId>
            <artifactId>mall-pay-client</artifactId>
            <version>${mall-pay-client.version}</version>
        </dependency>
        <dependency>
            <groupId>cn.net.mall</groupId>
            <artifactId>mall-redis-spring-boot-starter</artifactId>
            <version>${mall-redis-starter.version}</version>
        </dependency>
    </dependencies>
</dependencyManagement>
```

各服务仓库的根 POM 只需要 import 这个 BOM，不再自己管版本：

`` `xml
<!-- mall-order 独立仓库的根 POM -->
<dependencyManagement>
    <dependencies>
        <dependency>
            <groupId>cn.net.mall</groupId>
            <artifactId>mall-cloud-bom</artifactId>
            <version>1.0.0</version>
            <type>pom</type>
            <scope>import</scope>
        </dependency>
    </dependencies>
</dependencyManagement>
```

这样所有服务的版本来源是唯一的，BOM 升级一个版本号，所有服务同步。

### Client 模块独立发布

每个 client 模块独立打包、独立版本号、发布到私有仓库：

| Client | 坐标 | 频率 |
|--------|------|------|
| mall-order-client | `cn.net.mall:mall-order-client:1.2.0` | 接口变更时 |
| mall-pay-client | `cn.net.mall:mall-pay-client:1.0.0` | 接口变更时 |

**Client 的 POM 必须最轻量**，不能依赖服务实现模块：

`` `xml
<!-- mall-order-client/pom.xml — 正确 -->
<dependencies>
    <dependency>
        <groupId>org.springframework.cloud</groupId>
        <artifactId>spring-cloud-starter-openfeign</artifactId>
    </dependency>
    <!-- 只有 DTO 需要的 Jackson 注解 -->
    <dependency>
        <groupId>com.fasterxml.jackson.core</groupId>
        <artifactId>jackson-annotations</artifactId>
    </dependency>
</dependencies>
```

`` `xml
<!-- mall-order-client/pom.xml — 错误 -->
<dependencies>
    <!-- 这会让 client 的消费者被迫引入整个业务实现 -->
    <dependency>
        <groupId>cn.net.mall</groupId>
        <artifactId>mall-order-api</artifactId>  <!-- ← 不要这么做！ -->
    </dependency>
</dependencies>
```

Consumer 服务在 POM 里按需引入所需的 client：

`` `xml
<!-- mall-pay/pom.xml -->
<dependencies>
    <!-- 要调 order 接口 -->
    <dependency>
        <groupId>cn.net.mall</groupId>
        <artifactId>mall-order-client</artifactId>
    </dependency>
    <!-- 要用 Redis -->
    <dependency>
        <groupId>cn.net.mall</groupId>
        <artifactId>mall-redis-spring-boot-starter</artifactId>
    </dependency>
</dependencies>
```

### Starter 模块独立管理

`mall-common` 拆散的每个 starter 也是独立仓库、独立版本号。它们的消费者只看自己需要哪些 starter，不再被迫继承整个 common。

`` `xml
<!-- mall-redis-spring-boot-starter/pom.xml -->
<dependencies>
    <!-- 显式声明自己依赖什么，不靠传递 -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-data-redis</artifactId>
    </dependency>
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-autoconfigure</artifactId>
    </dependency>
</dependencies>
```

`` `java
// 自动配置类带条件，没有 redis 依赖就不激活
@AutoConfiguration
@ConditionalOnClass(StringRedisTemplate.class)
public class RedisAutoConfiguration {
    @Bean
    @ConditionalOnMissingBean
    public RedisUtil redisUtil(StringRedisTemplate template) {
        return new RedisUtil(template);
    }
}
```

### 最终仓库结构

```
independent-repo/
├── mall-cloud-bom/                          # 版本管控中心
│   └── pom.xml（只有 dependencyManagement）
│
├── mall-redis-spring-boot-starter/          # 独立 starter
├── mall-workid-spring-boot-starter/
├── mall-sensitive-spring-boot-starter/
│
├── mall-order/                              # 独立服务
│   ├── mall-order-client/pom.xml            # Feign 接口
│   ├── mall-order-api/pom.xml               # 业务实现
│   └── pom.xml（import mall-cloud-bom）
│
├── mall-pay/
│   ├── mall-pay-client/pom.xml
│   ├── mall-pay-api/pom.xml
│   └── pom.xml（import mall-cloud-bom）
│
├── mall-product/
│   ├── mall-product-client/pom.xml
│   └── ...
│
└── ……
```

### 必须遵守的规则

| 规则 | 违反后的后果 |
|------|------------|
| **Client 不依赖任何实现模块** | 调 order client 时被迫引入整个 order 的依赖树 |
| **Client 只有接口 + DTO** | 不同版本的 client 行为不一致，排查困难 |
| **BOM 中只声明 `dependencyManagement `** | 各服务被动引入不需要的依赖，回到老路 |
| **BOM 版本一经发布不可修改** | 使用方不确定自己该用哪个版本 |
| **每个 starter 和 client 独立版本号** | consumer 无法选择只升级某个组件 |
| **Common 模块彻底拆分后才分仓库** | 否则分仓库后 common 改个东西要通知所有仓库同步 |

