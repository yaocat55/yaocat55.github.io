---
title: "RocketMQ 消费者模式与过滤器"
date: 2022-11-11T08:00:00+00:00
tags: ["RocketMQ", "实践教程", "消息队列"]
categories: ["消息队列中间件"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "深入 RocketMQ 的集群消费与广播消费、Push 与 Pull 两种拉取模式、Tag 与 SQL92 消息过滤、Rebalance 队列分配机制——消费端的全部控制力。"
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

# RocketMQ 消费者模式

> 📖 <strong>前置阅读</strong>：本文假设读者已掌握 SpringBoot RocketMQ 的基本消费操作。如果还不熟悉，建议先阅读 [<strong>SpringBoot RocketMQ 全操作指南</strong>]({{< relref "SpringBootRocketMQ.md" >}})。

## 一、⚡ 问题切入：一条消息，谁来消费？

前面五篇的消费者代码都默认了一件事——一条消息只被一个消费者实例处理。但实际业务中：

- <strong>订单消息</strong>——只能被一个实例消费（一个订单不能被两个服务处理两次）
- <strong>配置刷新消息</strong>——所有实例都要收到（所有缓存节点刷新缓存）
- <strong>部分 Tag 的消息</strong>——只关心"订单创建"，对"订单支付"不感兴趣
- <strong>消费不过来</strong>——10 个 Queue，2 个实例，怎么分？

这四大问题的答案都在这一篇里。

## 二、集群消费 vs 广播消费

### 2.1 集群消费（CLUSTERING）——默认模式

<strong>同一个 ConsumerGroup 内的所有实例共享消费一个 Topic 的消息——每条消息只被组内一个实例消费</strong>。

```java
@Component
@RocketMQMessageListener(
    topic = "order-topic",
    consumerGroup = "order-consumer-group",
    messageModel = MessageModel.CLUSTERING   // 集群模式（默认值，可以不写）
)
public class OrderClusteringListener
        implements RocketMQListener<OrderMessage> {

    @Override
    public void onMessage(OrderMessage msg) {
        System.out.printf("[实例A] 处理订单: orderId=%d%n", msg.getOrderId());
    }
}
```

部署 3 个实例，Topic 有 8 个 Queue：

```
OrderConsumerGroup (3 个实例，8 个 Queue)

实例A → Queue-0, Queue-1, Queue-2    ← 分到 3 个 Queue
实例B → Queue-3, Queue-4, Queue-5    ← 分到 3 个 Queue
实例C → Queue-6, Queue-7             ← 分到 2 个 Queue

Queue-0 内的消息 [msg1, msg2, msg3]
    → 全部由实例A消费（不会被实例B或C消费）
```

### 2.2 广播消费（BROADCASTING）

<strong>同一个 ConsumerGroup 内的所有实例都收到 Topic 的全部消息</strong>。

```java
@Component
@RocketMQMessageListener(
    topic = "config-refresh-topic",
    consumerGroup = "config-broadcast-group",
    messageModel = MessageModel.BROADCASTING  // 广播模式
)
public class ConfigRefreshListener
        implements RocketMQListener<String> {

    @Override
    public void onMessage(String configKey) {
        System.out.printf("[实例%s] 收到配置刷新通知: %s%n",
                instanceId(), configKey);
        // 每个实例独立刷新自己的本地缓存
        cacheManager.refresh(configKey);
    }
}
```

| 维度 | CLUSTERING | BROADCASTING |
|------|:---:|:---:|
| 每条消息被消费次数 | 组内只有 1 次 | 组内每个实例 1 次 |
| 消费进度 (offset) 存储 | Broker 统一管理 | 每个实例本地存储 |
| Rebalance | 支持（实例增减时 Queue 重新分配） | 不支持 |
| 适用场景 | 订单处理、库存扣减 | 配置刷新、缓存清除、系统通知 |

> ⚠️ 新手提示：广播模式下<strong>消息不会重试</strong>——因为消费进度存在本地，Broker 不知道你的消费状态。广播消费失败后 RocketMQ 不会将消息转入 `%RETRY%` Topic，需要在本地自己做容错。

## 三、Push 模式 vs Pull 模式

### 3.1 默认是 Push——但本质是"长轮询 Pull"

RocketMQ 的 Push 模式并不是 Broker 主动往 Consumer 推消息——它实际上是<strong>长轮询 Pull</strong>：

```
Consumer → "有消息吗？" → Broker → "有" / "没有，等着(hold 15s)"

长轮询的工作流程：
    1. Consumer 向 Broker 发拉取请求
    2. 如果队列有消息 → Broker 立即返回
    3. 如果队列没消息 → Broker hold 住请求 15 秒
    4. 15 秒内有新消息到达 → 立即返回
    5. 15 秒到了还没消息 → 返回空，Consumer 立即发下一个拉取请求
```

<strong>为什么不用真正的 Push？</strong> 真正的 Push 是 Broker 往 Consumer 推——Broker 需要维护每个 Consumer 的 TCP 连接状态，影响横向扩展。Pull 模式下 Consumer 掌控消费节奏——快了多拉、慢了少拉，Broker 只管响应拉取请求。

### 3.2 什么时候用 Pull

SpringBoot Starter 默认使用 Push（`DefaultMQPushConsumer`）。如果需要更精细的控制（如流量控制、批量消费），可以用 Pull：

```java
@Service
public class PullConsumerService {

    @Autowired
    private RocketMQTemplate rocketMQTemplate;

    public List<OrderMessage> pullMessages() {
        // 手动拉取：从 order-topic 的 Queue-0 拉取最多 32 条，offset 从 0 开始
        List<OrderMessage> messages = rocketMQTemplate.receive(
                "order-topic:created",  // Topic:Tag
                OrderMessage.class
        );

        // Pull 模式下自己决定什么时候 ACK
        return messages;
    }
}
```

| 维度 | Push（长轮询 Pull） | 真正 Pull |
|------|:---:|:---:|
| 使用 | `@RocketMQMessageListener` | `rocketMQTemplate.receive` |
| 消费进度管理 | 自动（Broker 维护 offset） | 手动管理 offset |
| 流量控制 | 较粗糙（线程数 + prefetch） | 精细（自己决定拉取速率） |
| 适用场景 | 99% 的业务场景 | 需精细控制消费速率的场景 |

## 四、消息过滤

### 4.1 Tag 过滤 —— 最简单高效

Tag 过滤在<strong>Broker 端通过 ConsumeQueue 的 hash 字段</strong>执行——没匹配的消息根本不传输到 Consumer。

```java
// 只收 Tag=paid
@RocketMQMessageListener(
    topic = "order-topic",
    consumerGroup = "order-paid-group",
    selectorExpression = "paid",
    selectorType = SelectorType.TAG
)

// 收 paid 或 cancelled
selectorExpression = "paid || cancelled"
```

### 4.2 SQL92 过滤 —— 按消息属性过滤

SQL92 过滤基于消息的<strong>用户属性</strong>（User Properties），需要 Broker 开启 `enablePropertyFilter=true`：

```java
// 发送端——设置消息属性
public void sendWithProperties(OrderMessage msg) {
    Message<String> message = MessageBuilder
            .withPayload(JSON.toJSONString(msg))
            .setHeader("region", "cn-north")    // ← 自定义属性
            .setHeader("amount", msg.getAmount().toString())
            .setHeader("vip", msg.isVip() ? "true" : "false")
            .build();
    rocketMQTemplate.syncSend("order-topic:created", message);
}

// 消费端——SQL92 过滤
@Component
@RocketMQMessageListener(
    topic = "order-topic",
    consumerGroup = "vip-north-order-group",
    selectorExpression = "region = 'cn-north' AND vip = 'true' AND amount > 1000",
    selectorType = SelectorType.SQL92
)
public class VipNorthOrderListener
        implements RocketMQListener<OrderMessage> {
    @Override
    public void onMessage(OrderMessage msg) {
        // 只收到华北区域的 VIP 用户且金额 > 1000 的订单
    }
}
```

### 4.3 Broker 端过滤 vs Consumer 端过滤

| | Broker 端过滤（Tag / SQL92） | Consumer 端过滤（收到后判断） |
|------|:---:|:---:|
| <strong>网络传输</strong> | 不匹配的不传输 | 全拉过来再判断 |
| <strong>Consumer 压力</strong> | 只处理匹配的消息 | 不匹配的也要接收+丢弃 |
| <strong>过滤能力</strong> | Tag（简单）SQL92（丰富） | 任意逻辑（Java 代码） |
| <strong>推荐</strong> | ✅ 优先使用 | 只在 Tag 和 SQL92 都覆盖不了时才用 |

## 五、Rebalance —— Queue 怎么分配到消费者实例

### 5.1 Rebalance 的触发时机

| 时机 | 发生了什么 |
|------|------|
| <strong>消费者实例增加</strong> | 新实例加入 ConsumerGroup → Queue 重新分配 |
| <strong>消费者实例减少（宕机/下线）</strong> | 老实例离开 → 它的 Queue 分给其他实例 |
| <strong>Topic 的 Queue 数变化</strong> | Queue 增加 → 重新分配（但 Queue 减少不触发 Rebalance） |

### 5.2 分配策略

RocketMQ 默认使用<strong>平均分配策略</strong>（`AllocateMessageQueueAveragely`）：

```
Topic: order (8 个 Queue)
ConsumerGroup: order-group (3 个实例)

AllocateMessageQueueAveragely：
    实例 1 → [0, 1, 2]
    实例 2 → [3, 4, 5]
    实例 3 → [6, 7]

AllocateMessageQueueByMachineRoom（按机房分配）：
    实例 1 (机房A) → [0, 2, 4, 6]   ← 分机房A的 Queue
    实例 2 (机房A) → [1, 3, 5, 7]
    实例 3 (机房B) → []               ← 机房B没Queue，闲着
```

```java
// 自定义分配策略——不常用，但可以
@RocketMQMessageListener(
    topic = "order-topic",
    consumerGroup = "order-group",
    allocateMessageQueueStrategy = AllocateMessageQueueAveragely.class
)
```

### 5.3 Rebalance 的代价：消息可能重复

Rebalance 发生时，<strong>正在被处理的 offset 可能回退</strong>——导致消息被重复消费：

```
实例 A 正在处理 Queue-0 的 offset=100
↓ Rebalance 发生（实例 C 上线）
Queue-0 被分配给实例 C
实例 A 停止消费 Queue-0
实例 C 从上次提交的 offset=95 开始消费
→ offset 95~100 的消息被重复消费
```

这就是<strong>幂等</strong>必须做的原因——Rebalance 是正常操作（扩缩容时自动触发），无法避免。

## 六、消费进度（Offset）管理

集群消费模式下，消费进度存在<strong>Broker 上</strong>。每次 `CONSUME_SUCCESS` 之后，Consumer 定期提交 offset 到 Broker。

```java
// 手动查看消费进度
docker exec rocketmq-broker sh mqadmin consumerProgress \
    -g order-consumer-group

// 手动重置消费进度——从头消费
docker exec rocketmq-broker sh mqadmin resetOffsetByTimestamp \
    -g order-consumer-group -t order-topic -s 0
```

| 进度存储 | 集群消费 | 广播消费 |
|----------|:---:|:---:|
| 存储位置 | Broker | 本地文件 |
| 重启不影响 | 是（Broker 维护） | 否（本地文件在容器重启后丢失） |
| Rebalance 后 | 自动从 Broker 读取 | 不适用 |

## 🎯 总结

1. <strong>集群消费 vs 广播消费</strong>：集群消费（默认）每条消息在组内只消费一次，offset 存在 Broker；广播消费每条消息组内所有实例都收到，offset 存本地，不支持重试。

2. <strong>Push 本质是长轮询 Pull</strong>：Consumer 主动拉取，Broker hold 住请求等消息。真正的 Push 在 RocketMQ 中不存在——这保证了 Broker 的横向扩展能力。

3. <strong>过滤发生在 Broker 端</strong>：Tag 过滤基于 ConsumeQueue 的 hash 字段匹配，SQL92 过滤基于消息属性匹配——不匹配的消息根本不传输到 Consumer。过滤优先级：Tag > SQL92 > Consumer 端过滤。

4. <strong>Rebalance 自动触发，带来重复消费风险</strong>：实例增减或 Queue 数变化时发生。必须做幂等——因为正在处理的消息可能被新实例重新拉取。

> 📖 <strong>下一步阅读</strong>：消费端的最后一层也讲完了。所有功能原理都了解了，接下来是部署上线——集群搭建、Dashboard 监控、JVM 调优、常见故障处理。继续阅读 [<strong>生产环境部署与调优</strong>]({{< relref "ProductionDeployment.md" >}})。
