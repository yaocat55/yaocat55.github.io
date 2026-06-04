---
title: "SpringBoot Kafka 全操作指南"
date: 2022-11-14T08:00:00+00:00
tags: ["消息队列"]
categories: ["消息队列中间件"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "从原生 Kafka Client 迁移到 Spring Kafka：KafkaTemplate 同步/异步/回调发送、@KafkaListener 批量消费、JSON 序列化配置、Producer/Consumer 参数调优、完整 Controller 示例——读完直接上项目。"
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

# SpringBoot Kafka 全操作指南

> 📖 <strong>前置阅读</strong>：本文假设读者已理解 Kafka 的核心概念（Broker、Topic、Partition、ConsumerGroup、Offset）。如果还不熟悉，建议先阅读 [<strong>Kafka 核心架构与日志存储模型</strong>]({{< relref "KafkaFundamentals.md" >}})。

## 🎯 第一步：目标说明

上一篇用原版 Kafka Java Client 写了 `KafkaProducer` + `KafkaConsumer`。和 RabbitMQ、RocketMQ 一样——真实的 SpringBoot 项目里不需要那些样板代码。`spring-kafka` 帮我们处理了连接管理、Producer 生命周期、Consumer 线程池、Offset 提交。

读完这篇会掌握：

- <strong>KafkaTemplate</strong> 三种发送方式（同步/异步/回调）
- <strong>@KafkaListener</strong> 注解消费——单条和批量
- <strong>JSON 序列化</strong>全链路配置——Producer 端 `JsonSerializer` + Consumer 端 `JsonDeserializer`
- <strong>Producer 配置</strong>：`acks`、`retries`、`batch.size`、`linger.ms`、`compression.type`
- <strong>Consumer 配置</strong>：`group.id`、`auto.offset.reset`、`enable.auto.commit`、`max.poll.records`

## 📋 第二步：前置条件

| 前置项 | 具体要求 | 验证命令 |
|--------|----------|----------|
| JDK | 17+（8+ 也兼容） | `java -version` |
| SpringBoot | 3.x（文中用 3.2） | `mvn dependency:tree \| grep spring-boot` |
| Kafka | 3.7.0 KRaft 模式（单节点即可） | `docker ps \| grep kafka` |
| 前置知识 | Broker/Topic/Partition/ConsumerGroup/Offset 概念 | — |

确认 Kafka 在跑：

```bash
# 确认 Kafka Broker
docker logs kafka | tail -10
# 预期：[KafkaRaftServer] Kafka Server started
```

## 🔧 第三步：环境搭建

### 3.1 依赖

```xml
<dependency>
    <groupId>org.springframework.kafka</groupId>
    <artifactId>spring-kafka</artifactId>
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-web</artifactId>
</dependency>
<dependency>
    <groupId>com.fasterxml.jackson.core</groupId>
    <artifactId>jackson-databind</artifactId>
</dependency>
<dependency>
    <groupId>org.projectlombok</groupId>
    <artifactId>lombok</artifactId>
    <optional>true</optional>
</dependency>
```

`spring-kafka` 内置了 `kafka-clients`——不需要单独引入 `org.apache.kafka:kafka-clients`。SpringBoot 通过 `KafkaAutoConfiguration` 自动创建 `KafkaTemplate`、`ConsumerFactory` 等 Bean。

### 3.2 配置文件

```yaml
spring:
  kafka:
    bootstrap-servers: localhost:9092
    # ===== Producer 配置 =====
    producer:
      # Key 和 Value 的序列化器——Spring 自动注入
      key-serializer: org.apache.kafka.common.serialization.StringSerializer
      value-serializer: org.springframework.kafka.support.serializer.JsonSerializer
      # ACK 级别：all = 所有 ISR 副本确认（最可靠）
      acks: all
      # 发送重试次数
      retries: 3
      # 批量发送大小（字节）——凑满 16KB 才发送
      batch-size: 16384
      # 批量等待时间（ms）——即使没凑满，等 10ms 也发
      linger-ms: 10
      # 压缩算法——none / gzip / snappy / lz4 / zstd
      compression-type: snappy
    # ===== Consumer 配置 =====
    consumer:
      # Key 和 Value 的反序列化器
      key-deserializer: org.apache.kafka.common.serialization.StringDeserializer
      value-deserializer: org.springframework.kafka.support.serializer.JsonDeserializer
      # ConsumerGroup——同一组内 Partition 只会分配给一个实例
      group-id: order-consumer-group
      # 第一次连 Kafka 时从哪里开始消费
      auto-offset-reset: earliest
      # 是否自动提交 offset（false = 手动提交）
      enable-auto-commit: false
      # 每次 poll 最多拉取多少条
      max-poll-records: 50
    # ===== Listener 配置 =====
    listener:
      # 手动提交 offset
      ack-mode: manual
```

<strong>配置项逐个解释</strong>：

| 配置 | 含义 | 默认值 |
|------|------|:---:|
| `acks: all` | Producer 等待所有 ISR 副本确认后才认为发送成功 | `1`（Leader 确认即可） |
| `retries: 3` | 发送失败后重试 3 次 | `Integer.MAX_VALUE` |
| `batch-size: 16384` | 多条消息打包成一个请求发送——减少网络开销 | 16384 |
| `linger-ms: 10` | 即使没凑满 batch-size，等 10ms 也发出去——平衡吞吐量和延迟 | 0（立即发） |
| `compression-type: snappy` | 压缩消息体（snappy 平衡速度和压缩比） | `none` |
| `auto-offset-reset: earliest` | 第一次消费时从最早的消息开始读 | `latest` |
| `enable-auto-commit: false` | 关闭自动提交——手动控制 offset 提交时机 | `true` |
| `max-poll-records: 50` | 每次 `poll` 最多拉 50 条 | 500 |

> ⚠️ 新手提示：Kafka 的 Producer 默认会把消息攒在内存里、等 `batch.size` 满了或 `linger.ms` 到了才发送。同步发送时会阻塞当前线程等 Broker 确认——这个等待时间受 `request.timeout.ms`（默认 30s）限制。如果网络不稳定，同步发送可能卡住业务线程，此时应该用异步发送。

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
    private String action;    // created / paid / cancelled / shipped
    private LocalDateTime createTime;
}
```

### 4.2 KafkaTemplate —— 一行发消息

`KafkaTemplate` 是 Spring 对 `KafkaProducer` 的封装。注入后直接使用：

```java
@Service
public class OrderMessageService {

    @Autowired
    private KafkaTemplate<String, Object> kafkaTemplate;

    // ===== 1. 发送——默认异步，不管结果 =====
    public void send(OrderMessage msg) {
        // send 是异步的——返回 ListenableFuture，不调 .get() 就不阻塞
        kafkaTemplate.send("order-topic", String.valueOf(msg.getOrderId()), msg);
    }

    // ===== 2. 同步发送——等待 Broker 确认 =====
    public void sendSync(OrderMessage msg) throws Exception {
        SendResult<String, Object> result =
                kafkaTemplate.send("order-topic",
                        String.valueOf(msg.getOrderId()), msg)
                        .get(5, TimeUnit.SECONDS);  // 阻塞最多 5 秒

        RecordMetadata meta = result.getRecordMetadata();
        System.out.printf("发送成功: topic=%s, partition=%d, offset=%d%n",
                meta.topic(), meta.partition(), meta.offset());
    }

    // ===== 3. 异步发送 + 回调 =====
    public void sendWithCallback(OrderMessage msg) {
        ListenableFuture<SendResult<String, Object>> future =
                kafkaTemplate.send("order-topic",
                        String.valueOf(msg.getOrderId()), msg);

        future.addCallback(
            // 成功回调
            result -> {
                RecordMetadata meta = result.getRecordMetadata();
                System.out.printf("异步发送成功: offset=%d, partition=%d%n",
                        meta.offset(), meta.partition());
            },
            // 失败回调
            ex -> {
                System.err.println("异步发送失败: " + ex.getMessage());
                // 补偿逻辑：写 DB 重试表、发告警...
            }
        );
    }

    // ===== 4. 指定 Partition =====
    public void sendToPartition(OrderMessage msg, int partition) {
        kafkaTemplate.send("order-topic", partition,
                String.valueOf(msg.getOrderId()), msg);
    }

    // ===== 5. 指定 Topic + Key（同一个 Key 的消息进入同一个 Partition） =====
    public void sendWithKey(OrderMessage msg) {
        // Kafka 对 Key 取哈希 % Partition 数
        // 同一个 orderId → 同一个哈希 → 同一个 Partition → 有序！
        kafkaTemplate.send("order-topic",
                String.valueOf(msg.getOrderId()), msg);
    }
}
```

<strong>KafkaTemplate 的 send 方法签名</strong>：

```java
// 最简形式：只指定 Topic
send(topic, data)

// 指定 Key——同一个 Key 的消息哈希到同一个 Partition（保证顺序）
send(topic, key, data)

// 指定 Partition——绕过哈希，强制发到某个 Partition
send(topic, partition, key, data)

// 指定时间戳——用于按时间查询
send(topic, partition, timestamp, key, data)
```

<strong>三种发送方式对比</strong>：

| 方式 | 方法 | 返回 | 可靠性 | 吞吐量 | 适用场景 |
|------|------|------|:---:|:---:|------|
| <strong>同步发送</strong> | `send(...).get(timeout)` | `SendResult` | 高 | 中 | 订单、支付——必须确认写入 |
| <strong>异步回调</strong> | `send(...)` + `addCallback` | 回调通知 | 中 | 高 | 通知、邮件——需要知道结果但不阻塞 |
| <strong>纯异步</strong> | `send(...)` 不调 `get` | 无 | 低 | 最高 | 日志、埋点——丢了也无所谓 |

> ⚠️ 新手提示：Kafka 的 `send` 默认是异步的——调用后立即返回，消息还在内存 buffer 里，不一定已经发到 Broker。如果 main 线程直接结束，buffer 里的消息就丢了。同步发送必须调 `.get()` 阻塞等待，异步发送必须用 `addCallback` 处理失败情况。

### 4.3 消费者 —— @KafkaListener

一个注解替代上一篇的 `KafkaConsumer` + `while(true) poll` 全套样板代码：

```java
@Component
public class OrderMessageListener {

    private static final Logger log = LoggerFactory.getLogger(OrderMessageListener.class);

    // ===== 基本用法：单条消费 =====
    @KafkaListener(
        topics = "order-topic",
        groupId = "order-consumer-group"
    )
    public void onMessage(OrderMessage msg) {
        log.info("收到订单消息: orderId={}, action={}, amount={}",
                msg.getOrderId(), msg.getAction(), msg.getAmount());
        // 处理业务...
    }

    // ===== 拿到完整 ConsumerRecord =====
    @KafkaListener(topics = "order-topic", groupId = "order-consumer-group")
    public void onRecord(ConsumerRecord<String, OrderMessage> record) {
        log.info("收到: topic={}, partition={}, offset={}, key={}, value={}",
                record.topic(), record.partition(), record.offset(),
                record.key(), record.value());
    }

    // ===== 批量消费——一次 poll 拿到一批消息 =====
    @KafkaListener(
        topics = "order-topic",
        groupId = "order-batch-consumer-group"
    )
    public void onBatch(List<OrderMessage> messages) {
        log.info("批量收到 {} 条消息", messages.size());
        for (OrderMessage msg : messages) {
            processOrder(msg);
        }
    }

    // ===== 拿到完整的 ConsumerRecord 列表 =====
    @KafkaListener(topics = "order-topic", groupId = "order-batch-consumer-group")
    public void onBatchRecords(List<ConsumerRecord<String, OrderMessage>> records) {
        log.info("批量收到 {} 条消息", records.size());
        for (ConsumerRecord<String, OrderMessage> record : records) {
            log.info("  partition={}, offset={}, key={}",
                    record.partition(), record.offset(), record.key());
            processOrder(record.value());
        }
    }

    private void processOrder(OrderMessage msg) {
        // 实际业务逻辑
    }
}
```

<strong>@KafkaListener 的完整参数</strong>：

| 参数 | 含义 | 默认值 |
|------|------|:---:|
| `topics` | 订阅的 Topic 列表 | 必填（或 `topicPattern` 二选一） |
| `topicPattern` | 用正则匹配 Topic 名 | — |
| `groupId` | ConsumerGroup 名称 | 配置文件中的 `spring.kafka.consumer.group-id` |
| `concurrency` | 并发消费者数（每个线程一个 KafkaConsumer） | `1` |
| `autoStartup` | 应用启动时是否自动开始消费 | `true` |
| `properties` | 覆盖配置文件中的 Consumer 参数 | — |

<strong>方法参数类型自动识别</strong>：

```java
// Spring Kafka 根据方法参数类型自动注入：

// 1. 只有消息体
@KafkaListener(topics = "order-topic")
public void handle(OrderMessage msg)

// 2. 消息体 + Acknowledgment（手动提交 offset）
@KafkaListener(topics = "order-topic")
public void handle(OrderMessage msg, Acknowledgment ack)

// 3. ConsumerRecord（包含 topic/partition/offset/headers 全部信息）
@KafkaListener(topics = "order-topic")
public void handle(ConsumerRecord<String, OrderMessage> record)

// 4. ConsumerRecord + Acknowledgment
@KafkaListener(topics = "order-topic")
public void handle(ConsumerRecord<String, OrderMessage> record, Acknowledgment ack)

// 5. 批量：List<消息体>
@KafkaListener(topics = "order-topic")
public void handle(List<OrderMessage> messages, Acknowledgment ack)

// 6. 批量：List<ConsumerRecord>
@KafkaListener(topics = "order-topic")
public void handle(List<ConsumerRecord<String, OrderMessage>> records)
```

### 4.4 手动提交 Offset

Kafka 和 RabbitMQ/RocketMQ 有一个关键区别——<strong>Offset 是消费者自己提交的</strong>，不是 Broker 推给你然后 Broker 记录。上一篇讲了 Offset 存在 Kafka 的内部 Topic `__consumer_offsets` 中。

在 Spring Kafka 中，`ack-mode: manual` 后可以手动控制提交时机：

```java
@Component
public class ManualCommitListener {

    private static final Logger log = LoggerFactory.getLogger(ManualCommitListener.class);

    // 单条消费 + 手动提交
    @KafkaListener(topics = "order-topic", groupId = "order-manual-commit")
    public void handle(OrderMessage msg, Acknowledgment ack) {
        try {
            processOrder(msg);
            // 处理成功 → 提交 offset
            ack.acknowledge();
        } catch (Exception e) {
            log.error("处理失败: orderId={}", msg.getOrderId(), e);
            // 不调用 acknowledge() → 下次 poll 时重新拉取这条消息
            // 注意：不是"立即"重新消费，而是下次 poll 时
        }
    }

    // 批量消费 + 手动提交
    @KafkaListener(topics = "order-topic", groupId = "order-batch-manual")
    public void handleBatch(List<OrderMessage> messages, Acknowledgment ack) {
        for (OrderMessage msg : messages) {
            processOrder(msg);
        }
        // 整批处理完后提交
        ack.acknowledge();
    }

    private void processOrder(OrderMessage msg) { /* ... */ }
}
```

<strong>Acknowledgment 的几种模式</strong>（配置 `spring.kafka.listener.ack-mode`）：

| ack-mode | 提交时机 | 可靠性 |
|------|------|:---:|
| `record` | 每条消息处理后自动提交 | 中（可能丢失未提交的消息） |
| `batch` | 每批 poll 完成后自动提交 | 中 |
| `time` | 定时提交（配合 `ack-time`） | 中 |
| `count` | 消费 N 条后提交（配合 `ack-count`） | 中 |
| `count_time` | 数量或时间任一条件满足就提交 | 中 |
| <strong>`manual`</strong> | 手动调用 `ack.acknowledge()` | 最高——完全控制提交时机 |
| <strong>`manual_immediate`</strong> | 手动调用后立即提交（不等待下一轮 poll） | 最高 |

> ⚠️ 新手提示：Kafka 的 Offset 提交和 RabbitMQ 的 ACK 不是一回事。RabbitMQ 的 ACK 告诉 Broker"消息已处理，可以删了"。Kafka 的 Offset 提交是告诉 Broker"这个 ConsumerGroup 在这个 Partition 上的消费进度到了 X"——<strong>消息本身不删</strong>，只是消费位置往前移了。

### 4.5 JSON 反序列化 —— 关键的包路径配置

Kafka 的 `JsonDeserializer` 需要知道消息体反序列化成什么类——这个信息通过 Consumer 配置中的 `spring.json.value.default.type` 或消息 Header 中的 `__TypeId__` 传递。

<strong>方式一：全局指定默认类型（简单，推荐入门用）</strong>：

```yaml
spring:
  kafka:
    consumer:
      value-deserializer: org.springframework.kafka.support.serializer.JsonDeserializer
      properties:
        # 告诉 Deserializer 反序列化成哪个类
        spring.json.value.default.type: com.example.demo.OrderMessage
        # 信任的包——只有这些包下的类才允许反序列化（安全机制）
        spring.json.trusted.packages: com.example.demo
```

<strong>方式二：发送时在 Header 中携带类型信息（灵活，推荐多 Topic 场景）</strong>：

```java
// Provider 发送时，JsonSerializer 自动在消息 Header 中写入 __TypeId__
// 不需要任何额外配置——JsonSerializer 默认就写 Header
kafkaTemplate.send("order-topic", String.valueOf(msg.getOrderId()), msg);
// Header 中自动包含: __TypeId__ = com.example.demo.OrderMessage

// Consumer 接收时，JsonDeserializer 从 Header 中读取 __TypeId__ 确定目标类型
// 只需要配 spring.json.trusted.packages
```

```yaml
spring:
  kafka:
    consumer:
      value-deserializer: org.springframework.kafka.support.serializer.JsonDeserializer
      properties:
        # 信任 demo 包下的所有类
        spring.json.trusted.packages: com.example.demo
        # 如果 Header 中没有 __TypeId__，回退到这个默认类型
        spring.json.value.default.type: com.example.demo.OrderMessage
```

<strong>遇到这个错误就是包路径没配</strong>：

```
org.apache.kafka.common.errors.SerializationException:
  The class 'com.example.demo.OrderMessage' is not in the trusted packages
```

解决：在 `application.yml` 中加上：

```yaml
spring:
  kafka:
    consumer:
      properties:
        spring.json.trusted.packages: com.example.demo
```

### 4.6 完整 Controller 示例

```java
@RestController
@RequestMapping("/api/order")
public class OrderController {

    @Autowired
    private OrderMessageService orderMessageService;

    // 创建订单 → 同步发送（等 Broker 确认）
    @PostMapping("/create")
    public String createOrder(@RequestBody OrderMessage msg) {
        msg.setAction("created");
        msg.setCreateTime(LocalDateTime.now());
        try {
            orderMessageService.sendSync(msg);
            return "订单消息已发送（同步确认）: " + msg.getOrderId();
        } catch (Exception e) {
            return "发送失败: " + e.getMessage();
        }
    }

    // 付款通知 → 异步回调发送
    @PostMapping("/pay")
    public String payOrder(@RequestBody OrderMessage msg) {
        msg.setAction("paid");
        orderMessageService.sendWithCallback(msg);
        return "支付消息已异步发送: " + msg.getOrderId();
    }

    // 日志 → 纯异步发送（丢了无所谓）
    @PostMapping("/log")
    public String logOrder(@RequestBody OrderMessage msg) {
        msg.setAction("log");
        orderMessageService.send(msg);
        return "日志已异步发送（不管结果）: " + msg.getOrderId();
    }

    // 发货通知 → 指定 Partition 发送
    @PostMapping("/ship/{orderId}")
    public String shipOrder(@PathVariable Long orderId) {
        OrderMessage msg = new OrderMessage();
        msg.setOrderId(orderId);
        msg.setAction("shipped");
        msg.setCreateTime(LocalDateTime.now());
        // 根据 orderId 哈希决定 Partition，保证同一订单的消息有序
        orderMessageService.sendWithKey(msg);
        return "发货消息已发送: " + orderId;
    }
}
```

测试流程：

```bash
# 1. 先手动创建 Topic（生产环境 autoCreateTopicEnable=false）
docker exec -it kafka \
  /opt/kafka/bin/kafka-topics.sh --create \
  --topic order-topic \
  --bootstrap-server localhost:9092 \
  --partitions 3 \
  --replication-factor 1

# 2. 启动应用
mvn spring-boot:run

# 3. 发送创建订单请求
curl -X POST http://localhost:8080/api/order/create \
  -H "Content-Type: application/json" \
  -d '{
    "orderId": 10001,
    "userId": 2001,
    "productName": "iPhone 15",
    "amount": 6999.00
  }'

# 4. 观察控制台
# 生产者侧: 发送成功: topic=order-topic, partition=1, offset=0
# 消费者侧: 收到订单消息: orderId=10001, action=created, amount=6999.00

# 5. 测试批量消费
# 先发 10 条消息
for i in $(seq 1 10); do
  curl -X POST http://localhost:8080/api/order/log \
    -H "Content-Type: application/json" \
    -d "{\"orderId\": 1000$i, \"userId\": 2001, \"amount\": 99.00}"
done
# 批量消费者一次收到最多 50 条（max-poll-records 配置）
```

## 第五步：KafkaTemplate 和 RocketMQTemplate / RabbitTemplate 的关键差异

搞过 RabbitMQ 和 RocketMQ 后，Kafka 的 Template 有几点不同：

| 维度 | RabbitTemplate | RocketMQTemplate | KafkaTemplate |
|------|:---:|:---:|:---:|
| <strong>发送目标</strong> | `convertAndSend(exchange, routingKey, msg)` | `syncSend("Topic:Tag", msg)` | `send(topic, key, msg)` |
| <strong>同步发送</strong> | 本身就是同步——阻塞等待 | `syncSend` | `send(...).get(timeout)`——默认异步，必须 `.get` 才是同步 |
| <strong>异步回调</strong> | `RabbitTemplate.ConfirmCallback` | `asyncSend(msg, SendCallback)` | `send(...).addCallback(success, failure)` |
| <strong>消息路由方式</strong> | Exchange + RoutingKey → 绑定到 Queue | Topic + Tag → Queue 通过 Broker 路由 | Topic → Partition（Key 哈希或指定 Partition） |
| <strong>Template 泛型</strong> | 无泛型 | 无泛型 | `KafkaTemplate<K, V>`——Key 和 Value 类型 |
| <strong>消息转换</strong> | `Jackson2JsonMessageConverter` | 自动（FastJSON） | Producer 用 `JsonSerializer`，Consumer 用 `JsonDeserializer` |

KafkaTemplate 最特别的是<strong>默认异步</strong>——`send()` 返回 `ListenableFuture`，线程不阻塞。这和 RabbitMQ（默认同步）和 RocketMQ（`syncSend` 明确标记同步）都不一样。

## 第六步：FAQ

| 问题 | 原因 | 解决 |
|------|------|------|
| `send(...).get()` 一直阻塞不返回 | Broker 无法连接或 ACK 级别设了 `all` 但 ISR 副本不足 | 检查 `bootstrap-servers` 是否可连；单节点 Broker 设 `acks=1` |
| Producer 发送成功但消费者收不到消息 | ConsumerGroup 的 `auto.offset.reset` 是 `latest`，启动后新产生的消息才收得到 | 改 `auto-offset-reset: earliest`，或 ConsumerGroup 换一个名字 |
| `SerializationException: not in the trusted packages` | `JsonDeserializer` 的安全机制——不信任发来的类型 | 配置 `spring.json.trusted.packages` |
| 消费者重启后重复收到之前处理过的消息 | `enable-auto-commit: false` 且上次处理的 offset 没提交 | 处理完后调用 `ack.acknowledge()` 手动提交 |
| 同一个 `groupId` 的多个实例只有一个在消费 | Topic 只有一个 Partition——组内只有 1 个实例能分到 Partition | 增加 Topic 的 Partition 数量（`kafka-topics.sh --alter --partitions 6`） |
| 消费者时不时报 `CommitFailedException` | `max.poll.interval.ms`（默认 5 分钟）内没处理完就提交 offset | 缩短单条消息处理时间，或增大 `max.poll.interval.ms` |
| `@KafkaListener` 批量消费拿不到 `List<>` 参数 | 需要额外配置开启批量模式 | 配 `spring.kafka.listener.type: batch` 且方法参数用 `List` |

## 🎯 总结

本文把上一篇的原生 Kafka Client 全部替换为 Spring Kafka：

1. <strong>三种发送方式</strong>：默认异步 `send()`、同步 `send(...).get()`、异步回调 `send(...).addCallback()`。KafkaTemplate 最特别的是<strong>默认异步</strong>——不会阻塞调用线程。

2. <strong>一个消费注解</strong>：`@KafkaListener(topics, groupId)` 替代 `while(true) + poll` 全套样板。方法参数类型决定收到什么——`ConsumerRecord`（完整信息）、`消息体`（自动反序列化）、`List`（批量）。

3. <strong>JSON 序列化全链路</strong>：Producer 端 `JsonSerializer` 自动写 `__TypeId__` Header，Consumer 端 `JsonDeserializer` 读到 Header 反序列化——两边不需要手动写一行序列化代码。只需要配 `spring.json.trusted.packages`。

4. <strong>手动 Offset 提交</strong>：`ack-mode: manual` + `ack.acknowledge()`。和 RabbitMQ 的 ACK 不同——Offset 提交是记录消费位置，消息本身不删除。

5. <strong>Producer 参数四个关键值</strong>：`acks`（可靠性）、`batch.size + linger.ms`（吞吐量）、`compression.type`（网络带宽）。Consumer 参数三个关键值：`auto-offset-reset`（从哪里开始）、`max-poll-records`（每次拉多少）、`enable-auto-commit`（怎么提交）。

> 📖 <strong>下一步阅读</strong>：发送和消费的基本操作都会了。但消息到底发到哪个 Partition？`acks=all`、`enable.idempotence`、事务消息的底层原理是什么？继续阅读 [<strong>Producer 深入：分区、ACK 与幂等</strong>]({{< relref "ProducerInternals.md" >}})，拆解 Kafka Producer 的全部控制力。
