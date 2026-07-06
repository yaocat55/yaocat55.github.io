---
title: "合并与修复：mall-common重构、Nacos恢复、中间件排查"
date: 2023-06-23T11:30:03+00:00
tags: ["工程实践", "SpringCloud", "每日日报"]
categories: ["技术类"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "将外部独立维护的五个基础设施Starter合并回主仓库mall-common，同时恢复被误删的Nacos配置，排查ES/MongoDB/Redis连接问题，修复MyBatis ID生成拦截器兜底逻辑"
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
## 今日工作

### 1. 外部 Starter 合并回 mall-common

之前将 `mall-common` 的基础设施拆分到了独立仓库 `mall-spring-boot-starters` （含 `common-core` 、 `redis-starter` 、 `workid-starter` 、 `web-starter` 、 `sensitive-starter` ），但独立维护成本高、构建链长、改个工具类要跨仓库发版。今日全部合并回主项目。

**具体操作：**
- 5 个 external starter 模块搬入主项目，改用主项目 parent POM
- `mall-common-core` 与 `mall-common` 去重（删除 14 个重复工具类，由 common-core 提供）
- Redisson 依赖彻底移除（零处使用，纯历史包袱）
- JJWT 统一为 0.12.6 拆分 artifacts，替代旧版合并 JAR
- 各服务 POM 去掉外部 starter 引用，改为本地模块依赖

### 2. Application 启动类命名统一

去除 `Api` 后缀，统一为 `{模块名}Application` （如 `BasicApiApplication` → `BasicApplication` ）；BFF 层加 `Bff` 后缀（ `AdminApiApplication` → `AdminBffApplication` ）。

**影响范围：** 8 个文件改名 + 对应 `SpringApplication.run()` 引用修复。

### 3. mall-customer DTO 包修复

`mall-customer-client` 的 DTO 文件还在旧路径 `member/client/dto/`，包名也多了多余的 `.client` 层级。修复后统一为 `customer/dto/`，跟 basic-client、product-client 保持一致。

### 4. Nacos 配置恢复（踩坑）

此前在重构中误删了远程 Nacos 上所有配置，这回重建了全部 10 个服务的配置文件和 `common.yaml` 。同时确认了各服务的完整中间件清单：

| 服务 | 使用的中件间 |
|------|------------|
| basic | MySQL, Redis, MongoDB, MinIO, 阿里云SMS, RocketMQ, Ollama |
| admin | MySQL, Redis |
| customer | MySQL, Redis |
| product | MySQL, Redis, MongoDB, Elasticsearch, RocketMQ |
| order | ShardingSphere(8库), Redis, Elasticsearch, RocketMQ |
| pay | 支付宝SDK（无数据库） |
| marketing | MySQL, Redis, Elasticsearch |
| recommend | ShardingSphere(8库), Redis, RocketMQ, Mahout |
| message | ShardingSphere(8库), Redis, WebSocket |

### 5. ES、MongoDB 连接排查

- `EsConfig` 与 Spring Boot 自动配置的 ES 健康检查冲突（两套连接），需排除自动配置
- `RestHighLevelClient` 的 `host` 与 `uris` 属性名不一致导致 `UnknownHostException`
- MongoDB 健康检查超时，确认 product 的 MongoDB 是商品详情数据存储

### 6. UserInterceptor 修复

发现一个埋藏已久的 MyBatis 拦截器 `UserInterceptor` ，通过 JDK 动态代理在 insert 时注入雪花 ID 和用户审计字段（ `GENERATE_ID` 、 `CURRENT_USER_ID` 、 `CURRENT_USER_NAME` ）。此前 `IdGenerateHelper` Bean 未就绪时拦截器静默吞异常，导致 mapper XML 中 `#{GENERATE_ID}` 找不到值而 SQL 报错。

**修复：** catch 块增加 Hutool `IdUtil.getSnowflakeNextId()` 兜底，Redis 不可用时自动切换。

### 7. 其他

- SkyWalking logback 依赖改为非 optional（修复日志初始化报错）
- favicon.ico 占位文件（消除浏览器 404 ERROR日志）
- README.md 全面更新（模块数、项目结构、启动顺序含类名）
- Application 类名与模块名对齐

## 提交

```
<待commit>
```
