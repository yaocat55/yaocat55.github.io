---
title: "今日日报：Redis Lua 原子脚本与三段式库存模型——从商品表拆出独立库存微服务"
date: 2023-07-09T11:30:03+00:00
tags: ["工程实践", "SpringCloud", "Redis", "每日日报"]
categories: ["技术类"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "从商品表拆出独立库存微服务，Redis Lua 原子脚本解决冻结与扣减的一致性问题，以及 8 个 Feign 客户端模块的自动配置改造"
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

## 拆库存服务：库存不是商品的附属品

某天盯着商品表的字段列表，发现 `quantity`、`remain_quantity`、`sale_count` 这三个东西怎么看怎么和 `name`、`price`、`cover_url` 不是一家人。`name` 改了不频繁，库存每秒都在扣——高频写和低频读挤在同一行，互相锁着玩。

决定拆。新建了一个 `mall-inventory` 微服务，独立数据库 `cloud_mall_inventory`，三张表：`inventory`（主库存）、`inventory_batch`（批次追踪）、`inventory_log`（变动流水）。

## 最头疼的问题：扣库存的一致性

库存扣减最怕两个事：超卖和半截崩溃。

第一个做法是两条 Redis 命令：

```java
redisUtil.increment(key, -quantity);       // 扣 available
redisUtil.increment(frozenKey, quantity);   // 加 frozen
```

问题很明显——第一条执行完、第二条还没跑的时候，机器崩了怎么办？available 扣了但 frozen 没加，库存"凭空消失"了。

解法是 Lua 脚本，把两条操作打包发给 Redis：

```lua
local qty = -tonumber(ARGV[1])
local avail = redis.call('INCRBY', KEYS[1], qty)
if avail < 0 then
    redis.call('INCRBY', KEYS[1], -qty)
    return -1
end
redis.call('INCRBY', KEYS[2], -qty)
return avail - qty
```

Redis 内部保证整个脚本一次性原子执行，不存在中间状态。Spring Data Redis 的 `StringRedisTemplate.execute(script, keys, args)` 直接调用就行。

## 三段式库存模型

完整链路改成了"冻结 → 确定 → 释放"：

```
下单 → frozen +1, available -1（冻结）
  ├─ 支付成功 → frozen -1, sale_count +1（确认扣减）
  └─ 超时/取消 → frozen -1, available +1（释放）
```

之前是下单直接扣 `remain_quantity`，30 分钟后超时取消还要回滚。但回滚依赖 MQ 消息，MQ 挂了库存就永远不恢复了。新模型不存在这个问题——「可用库存」只负责「卖」，frozen 只负责「锁」，职责拆开，逻辑自洽。

> ⚠️ 新手提示：三段式不只适用于电商库存。优惠券余量、API 调用次数、活动名额——凡是"先锁定再确认"的场景，结构都是一样的。

## Redis 宕机怎么办：三层降级

`freeze()` 方法的完整链路：

```
Normal:  Lua 脚本（Redis 原子执行）
  │
  ↓ Redis 异常
Fallback: MySQL 条件扣减（不带版本号，用 available >= qty 做原子判断）
```

降级路径刻意去掉了版本号——因为降级时全量流量打到 MySQL，乐观锁的版本冲突会导致大量"误报库存不足"。

```sql
UPDATE inventory SET available = available - #{quantity}
WHERE product_id = ? AND available >= #{quantity}
```

MySQL 行锁排队执行，不会超卖，不会误报。

## Feign 客户端自动配置

另一个大改动是把 8 个 `*-client` 模块全部改成了通过 `AutoConfiguration.imports` 自注册。

以前每加一个 Feign 客户端，要在调用方的 `@EnableFeignClients(basePackages = {...})` 里手动列包。这次在每一个 `*-client` 模块中加了一个自动配置类：

```java
@AutoConfiguration
@EnableFeignClients(basePackages = "cn.net.mall.xxx.client")
public class XxxFeignAutoConfig {}
```

配合 `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports` 注册。调用方只要加依赖，Feign 客户端自动出现在 Spring 容器中，不需要碰任何 Application.java。

以后拆仓库时，每个 `-client` 模块独立发版，版本号由调用方自己决定，零配置耦合。

## 顺手做的杂活

- **商品服务 ES 更新**： `mall-product` 和 `mall-marketing` 的 `EsTemplate` 从 `RestHighLevelClient`（ES 7.17 已弃用）迁移到 `ElasticsearchOperations`（Spring Data ES 5.x）
- **商品 update 允许部分更新**：改掉了原来 `checkParams` 强制所有字段必传的问题，现在传 `{"id":1,"price":99.99}` 只改价格
- **批量 update null 安全修复**： `ProductService.update()` 的 `checkAttribute` 遇到了 `skuAttributeEntityList` 为 null 的 NPE，加空判断解决
- **库存 Lua 脚本加载**：通过 `DefaultRedisScript` + `ClassPathResource` 加载 `scripts/freeze.lua`
- **Nacos 配置**：补了 `mall-inventory-api-dev.yaml` 的 R4J 熔断配置
- **README 更新**：补充库存服务、Feign 自动配置说明、`已修复` 清单
