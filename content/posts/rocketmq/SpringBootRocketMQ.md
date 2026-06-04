---
title: "SpringBoot RocketMQ 全操作指南"
date: 2022-11-08T08:00:00+00:00
tags: ["消息队列"]
categories: ["消息队列中间件"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "一篇掌握 SpringBoot RocketMQ 全部常用操作：同步/异步/单向发送、顺序消费、消息过滤、rocketmq-spring-boot-starter 全配置，读完直接上项目。"
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
    hidden: false
---

# SpringBoot RocketMQ 全操作指南

> 📖 <strong>前置阅读</strong>：本文假设读者已理解 RocketMQ 的核心概念（NameServer、Broker、Topic、Queue、ConsumerGroup）。如果还不熟悉，建议先阅读 [<strong>RocketMQ 核心架构与消息模型</strong>]({{< relref "RocketMQFundamentals.md" >}})。

## 🎯 第一步：目标说明

上一篇用原版 RocketMQ Java Client 写了 `DefaultMQProducer` + `DefaultMQPushConsumer`。真实的 SpringBoot 项目里不需要那么多样板代码——`rocketmq-spring-boot-starter` 帮你处理了 NameServer 连接、Producer 启动、Consumer 注册。

读完这篇会掌握：

- <strong>RocketMQTemplate</strong> 三种发送模式（同步/异步/单向）
- <strong>顺序消息</strong>的发送和消费——RocketMQ 原生能力
- <strong>@RocketMQMessageListener</strong> 注解消费——并发和顺序模式
- <strong>Tag 过滤 + SQL 过滤</strong>——比 RabbitMQ 的 RoutingKey 更灵活
- 消息对象自动 JSON 序列化/反序列化

## 📋 第二步：前置条件

| 前置项 | 具体要求 | 验证命令 |
|--------|----------|----------|
| JDK | 17+（8+ 也兼容） | `java -version` |
| SpringBoot | 3.x（文中用 3.2） | `mvn dependency:tree \| grep spring-boot` |
| RocketMQ | 5.1.4（NameServer + Broker 都在运行） | `docker ps \| grep rocketmq` |
| 前置知识 | NameServer/Broker/Topic/Queue 概念 | — |

确认 RocketMQ 在跑：

```bash
# 确认 NameServer
docker logs rocketmq-namesrv | tail -5
# 预期：The Name Server boot success

# 确认 Broker
docker logs rocketmq-broker | grep "boot success"
# 预期：The broker[broker-a, ...] boot success
```

## 🔧 第三步：环境搭建

### 3.1 依赖

```xml
<dependency>
    <groupId>org.apache.rocketmq</groupId>
    <artifactId>rocketmq-spring-boot-starter</artifactId>
    <version>2.3.0</version>
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-web</artifactId>
</dependency>
<dependency>
    <groupId>org.projectlombok</groupId>
    <artifactId>lombok</artifactId>
    <optional>true</optional>
</dependency>
```

> ⚠️ 新手提示：`rocketmq-spring-boot-starter` 版本和 RocketMQ Server 版本不要求完全一致——2.3.0 的 starter 连接 5.x 的 Broker 完全没问题。但 Client 协议需要兼容——5.x 的 starter 不能用 `rocketmq-client` 4.x。

### 3.2 配置文件

```yaml
rocketmq:
  # NameServer 地址——多个用分号或逗号分隔
  name-server: 192.168.1.100:9876
  # 生产者默认组名
  producer:
    group: springboot-producer-group
    # 发送超时（毫秒）
    send-message-timeout: 3000
    # 重试次数（同步模式）
    retry-times-when-send-failed: 2
    # 异步发送失败重试次数
    retry-times-when-send-async-failed: 2
    # 消息最大大小（字节）
    max-message-size: 4194304
```

## 🏗️ 第四步：分步实践

### 4.1 消息对象

```java
@Data
@NoArgsConstructor
@AllArgsConstructor
public class OrderMessage implements Serializable {
    private Long orderId;
    private Long userId;
    private String productName;
    private BigDecimal amount;
    private String action;    // created / paid / cancelled
    private LocalDateTime createTime;
}
```

### 4.2 RocketMQTemplate —— 一行发消息

`RocketMQTemplate` 是 Spring 对 `DefaultMQProducer` 的封装。注入后直接使用：

```java
@Service
public class OrderMessageService {

    @Autowired
    private RocketMQTemplate rocketMQTemplate;

    // ===== 1. 同步发送 —— 最常用 =====
    public void sendSync(OrderMessage msg) {
        // convertAndSend：自动将 Java 对象序列化为 JSON 字符串
        SendResult result = rocketMQTemplate.syncSend(
            "order-topic:created",   // Topic:Tag 格式
            msg
        );
        System.out.printf("同步发送成功: msgId=%s, queueId=%d%n",
                result.getMsgId(), result.getMessageQueue().getQueueId());
    }

    // ===== 2. 异步发送 —— 不阻塞当前线程 =====
    public void sendAsync(OrderMessage msg) {
        rocketMQTemplate.asyncSend("order-topic:paid", msg,
            new SendCallback() {
                @Override
                public void onSuccess(SendResult result) {
                    System.out.println("异步发送成功: " + result.getMsgId());
                }

                @Override
                public void onException(Throwable e) {
                    System.err.println("异步发送失败: " + e.getMessage());
                    // 补偿逻辑：写 DB 重试表、发告警...
                }
            }
        );
    }

    // ===== 3. 单向发送 —— 不关心结果，最高吞吐 =====
    public void sendOneWay(OrderMessage msg) {
        // 不等待 Broker 确认——适合日志、埋点等可丢失场景
        rocketMQTemplate.sendOneWay("order-topic:log", msg);
    }

    // ===== 4. 指定 Topic + Tag 分别传参 =====
    public void sendWithTag(OrderMessage msg, String tag) {
        rocketMQTemplate.syncSend("order-topic:" + tag, msg);
    }

    // ===== 5. 发送 Key —— 用于定位消息 =====
    public void sendWithKey(OrderMessage msg) {
        Message<String> message = MessageBuilder
                .withPayload(JSON.toJSONString(msg))
                .setHeader(MessageConst.PROPERTY_KEYS,
                        "order:" + msg.getOrderId())
                .build();
        rocketMQTemplate.syncSend("order-topic:created", message);
    }
}
```

<strong>三种发送模式对比</strong>：

| 模式 | 方法 | 返回 | 吞吐量 | 可靠性 | 适用场景 |
|------|------|------|:---:|:---:|------|
| <strong>同步发送</strong> | `syncSend` | `SendResult` | 中 | 高 | 订单、支付 |
| <strong>异步发送</strong> | `asyncSend` | 回调通知 | 高 | 中 | 通知、邮件 |
| <strong>单向发送</strong> | `sendOneWay` | 无 | 最高 | 最低 | 日志、埋点 |

### 4.3 消费者 —— @RocketMQMessageListener

一个注解替代上一篇的 `DefaultMQPushConsumer` + `registerMessageListener` 全部样板代码：

```java
@Component
@RocketMQMessageListener(
    topic = "order-topic",               // 订阅的 Topic
    consumerGroup = "order-consumer-group", // ConsumerGroup
    selectorExpression = "created || paid", // Tag 过滤——只收 Tag=created 或 paid
    consumeMode = ConsumeMode.CONCURRENTLY,  // 并发消费（默认）
    consumeThreadNumber = 20                 // 消费线程数
)
public class OrderCreatedListener
        implements RocketMQListener<OrderMessage> {

    @Override
    public void onMessage(OrderMessage msg) {
        System.out.printf("收到订单消息: orderId=%d, action=%s, amount=%s%n",
                msg.getOrderId(), msg.getAction(), msg.getAmount());
        // 处理业务...
    }
}
```

<strong>注解参数详解</strong>：

| 参数 | 含义 | 默认值 |
|------|------|:---:|
| `topic` | 订阅的 Topic | 必填 |
| `consumerGroup` | ConsumerGroup 名称 | 必填 |
| `selectorExpression` | 过滤表达式——Tag 过滤 或 SQL92 过滤 | `*`（全部） |
| `selectorType` | 过滤类型——`TAG` 或 `SQL92` | `TAG` |
| `consumeMode` | `CONCURRENTLY`（并发）或 `ORDERLY`（顺序） | `CONCURRENTLY` |
| `consumeThreadNumber` | 消费线程数 | 20 |

<strong>消息类型自动转换</strong>：`RocketMQMessageListener<OrderMessage>` 中的泛型告诉 Spring——消息体是 JSON 时自动反序列化为 `OrderMessage` 对象，不需要手动解析。

### 4.4 顺序消息 —— RocketMQ 的原生杀手锏

<strong>需求</strong>：订单创建 → 支付 → 发货 三条消息必须按顺序消费。如果发货消息在支付消息之前被处理，业务就乱了。

RabbitMQ 要保证顺序很麻烦——需要关掉所有并发、限制一个消费者。RocketMQ 原生支持：<strong>同一个 Queue 内的消息严格有序</strong>。

<strong>发送端</strong>——用 `syncSendOrderly`，指定选择 Queue 的 key：

```java
// 同一个 orderId 的消息进同一个 Queue → 这个 Queue 内消息天然有序
public void sendOrderly(OrderMessage msg) {
    rocketMQTemplate.syncSendOrderly(
        "order-topic",       // Topic（不含 Tag）
        msg,
        msg.getOrderId().toString()   // 根据 orderId 哈希 → 选 Queue
        //  同一个 orderId → 同一个哈希 → 同一个 Queue → 消息有序！
    );
}
```

<strong>消费端</strong>——消费模式设为 `CONSUME.ORDERLY`：

```java
@Component
@RocketMQMessageListener(
    topic = "order-topic",
    consumerGroup = "order-orderly-consumer",
    consumeMode = ConsumeMode.ORDERLY   // ← 顺序消费模式
)
public class OrderOrderlyListener
        implements RocketMQListener<OrderMessage> {

    @Override
    public void onMessage(OrderMessage msg) {
        System.out.printf("顺序消费: orderId=%d, action=%s, queueId=%d%n",
                msg.getOrderId(), msg.getAction(),
                // 同一订单的三条消息在同一个 Queue
                msg.getQueueId());
        // 处理业务...
        // 注意：顺序模式下，前一条消息返回 CONSUME_SUCCESS 后，
        //       消费者才会拉取下一条——不能在这里开异步线程
    }
}
```

<strong>`syncSendOrderly` 的哈希原理</strong>：

```
hash = messageQueueSelector.select(messageQueueList, message, hashKey)
// hashKey = orderId.toString()

假设 8 个 Queue：
    "10001" → hash("10001") % 8 = 3 → Queue-3
    "10002" → hash("10002") % 8 = 5 → Queue-5
    "10001" 的另一条消息 → hash("10001") % 8 = 3 → Queue-3  ✅ 和之前的订单在同一个 Queue
```

> ⚠️ 新手提示：顺序消息是 RocketMQ 的强项，但<strong>不能滥用</strong>。顺序消费的吞吐量远低于并发消费——因为同一个 Queue 只能被一个线程消费，且前一条 ACK 后才能拉下一条。只对确实需要顺序的业务（如订单状态流转）使用顺序消息。普通的通知、日志不需要。

### 4.5 Tag 过滤与 SQL 过滤

<strong>Tag 过滤</strong>（`selectorType = TAG`，默认）：

```java
@Component
@RocketMQMessageListener(
    topic = "order-topic",
    consumerGroup = "order-payment-consumer",
    selectorExpression = "paid",  // 只收 Tag=paid 的消息
    selectorType = SelectorType.TAG
)
public class OrderPaymentListener
        implements RocketMQListener<OrderMessage> {
    // ...
}
```

Tag 表达式支持 `||`：

```java
selectorExpression = "created || paid"           // 收 created 或 paid
selectorExpression = "*"                          // 收所有 Tag
selectorExpression = "paid || cancelled || refund" // 收三个 Tag
```

<strong>SQL92 过滤</strong>（`selectorType = SQL92`）——更强大的过滤：

```java
@Component
@RocketMQMessageListener(
    topic = "order-topic",
    consumerGroup = "order-important-consumer",
    // SQL92 表达式——只收金额 > 1000 的高价值订单
    selectorExpression = "amount > 1000",
    selectorType = SelectorType.SQL92
)
public class ImportantOrderListener
        implements RocketMQListener<OrderMessage> {
    // ...
}
```

SQL92 过滤支持：

```sql
-- 比较
amount > 1000 AND action = 'created'

-- IS NULL / IS NOT NULL
productName IS NOT NULL

-- IN
action IN ('created', 'paid')

-- 范围
(amount >= 500 AND amount <= 5000)
```

启用 SQL92 过滤需要在 Broker 配置中加上：

```properties
# broker.conf
enablePropertyFilter = true
```

> ⚠️ 新手提示：SQL92 过滤是在 Broker 端执行的——不符合条件的消息<strong>根本不会被传输到消费者</strong>，节省了网络带宽。但启动时需要在 Broker 配置 `enablePropertyFilter=true`，否则消费者会报错连不上。

### 4.6 完整的 Controller 示例

```java
@RestController
@RequestMapping("/api/order")
public class OrderController {

    @Autowired
    private OrderMessageService orderMessageService;

    // 创建订单 → 同步发送
    @PostMapping("/create")
    public String createOrder(@RequestBody OrderMessage msg) {
        msg.setAction("created");
        msg.setCreateTime(LocalDateTime.now());
        orderMessageService.sendSync(msg);
        return "订单创建消息已发送: " + msg.getOrderId();
    }

    // 付款通知 → 异步发送
    @PostMapping("/pay")
    public String payOrder(@RequestBody OrderMessage msg) {
        msg.setAction("paid");
        orderMessageService.sendAsync(msg);
        return "支付消息已异步发送";
    }

    // 日志 → 单向发送
    @PostMapping("/log")
    public String log(@RequestBody OrderMessage msg) {
        msg.setAction("log");
        orderMessageService.sendOneWay(msg);
        return "日志已发送（单向模式）";
    }

    // 顺序消息 → 同一订单的发货通知
    @PostMapping("/ship/{orderId}")
    public String shipOrder(@PathVariable Long orderId) {
        OrderMessage msg = new OrderMessage();
        msg.setOrderId(orderId);
        msg.setAction("shipped");
        orderMessageService.sendOrderly(msg);  // 用 syncSendOrderly
        return "发货消息已顺序发送: " + orderId;
    }
}
```

## 第五步：FAQ

| 问题 | 原因 | 解决 |
|------|------|------|
| `MQClientException: No route info of this topic` | Topic 不存在——Broker 没有该 Topic 的路由信息 | 生产者首次发送时 Broker 自动创建（需要 `autoCreateTopicEnable=true`），或手动创建 `mqadmin updateTopic` |
| `MQClientException: CODE: 1, DESC: null` | NameServer 地址配错或连不上 | `telnet 192.168.1.100 9876` 测试连通性 |
| 消费者收不到消息但 `syncSend` 返回 SEND_OK | ConsumerGroup 的消费进度 (offset) 已超过新消息的 offset | 新 ConsumerGroup 设 `consumeFromWhere=CONSUME_FROM_FIRST_OFFSET` |
| `ConsumeConcurrentlyException` | 消费者泛型类型与消息体不匹配 | 确认 JSON 序列化的字段名和 Java 类的字段名一致——RocketMQ 默认用 FastJSON |
| 顺序消息消费"卡住" | 前一条消息没返回 SUCCESS | 顺序模式下，同一个 Queue 的消息必须<strong>逐条确认</strong>——前一条不返回 SUCCESS，下一条永远不拉取 |

## 🎯 总结

本文把上一篇中的原生 RocketMQ Client 全部替换为 SpringBoot Starter：

1. <strong>三种发送模式</strong>：`syncSend`（可靠，有返回值）、`asyncSend`（高性能，回调通知）、`sendOneWay`（最高吞吐，不关心结果）。发送目标用 `"Topic:Tag"` 格式一个字符串搞定。

2. <strong>一个消费注解</strong>：`@RocketMQMessageListener(topic, consumerGroup, selectorExpression, consumeMode)` 替代所有样板代码。泛型 `RocketMQListener<T>` 自动 JSON 反序列化。

3. <strong>顺序消息</strong>：`syncSendOrderly` + `ConsumeMode.ORDERLY`——同一 orderId 哈希到同一个 Queue，该 Queue 内严格 FIFO。RocketMQ 的原生杀手锏。

4. <strong>消息过滤</strong>：Tag 过滤（简单，Broker 端执行）和 SQL92 过滤（灵活，支持比较/范围/IN）。过滤在 Broker 端发生，节省网络传输。

5. <strong>消费确认</strong>：返回 `CONSUME_SUCCESS` 即确认——比 RabbitMQ 的 `channel.basicAck` 更简洁。返回 `RECONSUME_LATER` 进入重试。

> 📖 <strong>下一步阅读</strong>：发送和消费的基本操作都会了。但"下单后 30 分钟自动取消"怎么做？"下单+扣库存+发消息"这三件事怎么原子执行？继续阅读 [<strong>顺序消息、延迟消息与事务消息</strong>]({{< relref "AdvancedMessages.md" >}})，一篇掌握 RocketMQ 最独特的三大高级特性。
