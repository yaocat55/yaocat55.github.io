---
title: "SpringBoot RocketMQ 全操作指南"
date: 2022-11-08T08:00:00+00:00
tags: ["RocketMQ", "实践教程", "SpringBoot"]
categories: ["消息队列中间件"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "真实商城项目 RocketMQ 实战：MqHelper 封装、延迟消息自动取消订单、WebSocket 通知推送、多节点任务同步、RabbitMQ 双 MQ 基础设施先行策略。"
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

# SpringBoot 集成 RocketMQ：从发送到消费

> 📖 <strong>前置阅读</strong>：本文假设读者已理解 RocketMQ 的核心概念（NameServer、Broker、Topic、Queue、ConsumerGroup）。如果还不熟悉，建议先阅读 [<strong>RocketMQ 核心架构与消息模型</strong>]({{< relref "RocketMQFundamentals.md" >}})。

---

# Part 1：概念与前置

## 1.1 本文目标

上一篇用原版 RocketMQ Java Client 写了 `DefaultMQProducer` + `DefaultMQPushConsumer`。真实的 SpringBoot 项目里不需要那么多样板代码——`rocketmq-spring-boot-starter` 帮你处理了 NameServer 连接、Producer 启动、Consumer 注册。

读完这篇会掌握：

- <strong>MqHelper 封装</strong>——为什么要在 `RocketMQTemplate` 上再包一层，asyncSend + SendCallback 的真实用法
- <strong>30 分钟延迟取消订单</strong>——RocketMQ 内置 delayLevel 的完整实战流程，和 RabbitMQ 方案的对比
- <strong>@RocketMQMessageListener 消费者</strong>——MessageExt 手动反序列化 vs 泛型自动解析，以及三个真实业务消费者
- <strong>Domain Entity 直传</strong>——为什么不做 DTO 转换，以及什么情况下不能这样做
- <strong>双 MQ 基础设施先行</strong>——RabbitMQ 拓扑已就绪但全用 RocketMQ 的设计决策

## 1.2 前置条件

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

---

# Part 2：教程版实现

> ⚠️ <strong>阅读提示</strong>：Part 2 是纯教程代码，覆盖 RocketMQ 在 SpringBoot 中的核心 API。每一段代码都可以直接复制运行。<strong>真实生产代码在 Part 3</strong>，两者分开是为了避免读者在学基础 API 时被生产复杂度干扰。

## 2.1 依赖

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

## 2.2 配置文件

```yaml
rocketmq:
  name-server: 127.0.0.1:9876
  producer:
    group: tutorial-producer-group
    send-message-timeout: 3000
```

## 2.3 RocketMQTemplate —— 发送消息

教程里通常直接注入 `RocketMQTemplate`，一行代码搞定：

```java
@Service
public class MessageSender {

    @Autowired
    private RocketMQTemplate rocketMQTemplate;

    // ===== 同步发送 =====
    public void sendSync(String topic, Object msg) {
        SendResult result = rocketMQTemplate.syncSend(topic, msg);
        System.out.printf("发送结果: %s%n", result.getSendStatus());
    }

    // ===== 异步发送 =====
    public void sendAsync(String topic, Object msg) {
        rocketMQTemplate.asyncSend(topic, msg, new SendCallback() {
            @Override
            public void onSuccess(SendResult sendResult) {
                System.out.println("发送成功: " + sendResult.getMsgId());
            }
            @Override
            public void onException(Throwable throwable) {
                System.err.println("发送失败: " + throwable.getMessage());
            }
        });
    }

    // ===== 单向发送（不关心结果） =====
    public void sendOneWay(String topic, Object msg) {
        rocketMQTemplate.sendOneWay(topic, msg);
    }
}
```

| 模式 | 方法 | 特点 |
|------|------|------|
| <strong>同步发送</strong> | `syncSend` | 等 Broker 确认，有返回值 |
| <strong>异步发送</strong> | `asyncSend` + `SendCallback` | 不阻塞，回调通知结果 |
| <strong>单向发送</strong> | `sendOneWay` | 不等待确认，最高吞吐 |

## 2.4 @RocketMQMessageListener —— 接收消息

```java
@Component
@RocketMQMessageListener(
    topic = "order-topic",
    consumerGroup = "order-consumer-group")
public class OrderConsumer implements RocketMQListener<OrderMessage> {

    @Override
    public void onMessage(OrderMessage msg) {
        System.out.printf("收到订单消息: orderId=%d, action=%s%n",
                msg.getOrderId(), msg.getAction());
    }
}
```

泛型 `<OrderMessage>` 自动反序列化 JSON 为 Java 对象。开发阶段很方便——不需要手动解析字节数组。

## 2.5 顺序消息 —— RocketMQ 的原生杀手锏

<strong>需求</strong>：订单创建 → 支付 → 发货 三条消息必须按顺序消费。如果发货消息在支付消息之前被处理，业务就乱了。

RabbitMQ 要保证顺序很麻烦——需要关掉所有并发、限制一个消费者。RocketMQ 原生支持：<strong>同一个 Queue 内的消息严格有序</strong>。

<strong>发送端</strong>——用 `syncSendOrderly`，指定选择 Queue 的 key：

```java
// 同一个 orderId 的消息进同一个 Queue → 这个 Queue 内消息天然有序
public void sendOrderly(OrderMessage msg) {
    rocketMQTemplate.syncSendOrderly(
        "order-topic",
        msg,
        msg.getOrderId().toString()   // 根据 orderId 哈希 → 选 Queue
        // 同一个 orderId → 同一个哈希 → 同一个 Queue → 消息有序！
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
                msg.getOrderId(), msg.getAction(), msg.getQueueId());
        // 注意：顺序模式下，前一条消息返回 CONSUME_SUCCESS 后，
        // 消费者才会拉取下一条——不能在这里开异步线程
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

> ⚠️ 新手提示：顺序消息是 RocketMQ 的强项，但<strong>不能滥用</strong>。顺序消费的吞吐量远低于并发消费——因为同一个 Queue 只能被一个线程消费，且前一条 ACK 后才能拉下一条。只对确实需要顺序的业务（如订单状态流转）使用顺序消息。

## 2.6 Tag 过滤与 SQL 过滤

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

---

# Part 3：生产版升级

> 📌 <strong>以下代码全部来自 mall 电商项目真实源码</strong>（`mall-service` + `mall-job` 模块），与 Part 2 的教程版形成对照。每个升级点都会解释<strong>为什么</strong>生产环境要这样做。

## 3.1 配置管理

<strong>真实项目 dev 环境</strong>（mall-api）：

```yaml
rocketmq:
  name-server: 117.72.88.11:9876
  producer:
    group: susan-mall-mgt-group
    send-message-timeout: 3000
```

<strong>真实项目 prod 环境</strong>——敏感信息全部走环境变量注入：

```yaml
rocketmq:
  name-server: ${ROCKETMQ_NAME_SERVER}
  producer:
    group: ${ROCKETMQ_PRODUCER_GROUP:susan-mall-mgt-group}
    send-message-timeout: 3000
```

<strong>三个设计决策</strong>：

1. <strong>配置极简</strong>——只配了 `name-server`、`group`、`send-message-timeout` 三项。其余参数如 `retry-times-when-send-failed`、`max-message-size` 等全部用 Starter 默认值。真实项目中，默认值在大多数场景下够用。

2. <strong>dev 直连 vs prod 环境变量</strong>——dev 写死内网 IP 方便本地联调；prod 用 `${}` 占位，部署时通过 K8s ConfigMap 或启动参数注入。`susan-mall-mgt-group` 作为 `group` 的默认值兜底，保证即使运维忘记配环境变量也不会启动失败。

3. <strong>依赖版本</strong>：`rocketmq-spring-boot-starter 2.1.1`，不是最新的 2.3.0——stabilization 优先，`2.1.1` 已经在生产环境跑通，没必要追新。

## 3.2 消息体：直接用 Domain Entity，不做 DTO 转换

教程中通常会定义一个 `XxxMessage` 作为消息载体，但真实项目中往往<strong>直接把 Domain Entity 扔进消息队列</strong>：

```java
// 超时取消订单消息 —— 直接发 TradeEntity
// TradeSaveService.java:80
mqHelper.send(overTimeCancelTradeTopic, tradeEntity, OVER_TIME_CANCEL_TRADE_DELAY_LEVEL);

// Excel导出通知消息 —— 直接发 CommonNotifyEntity
// ExcelExportTask.java:106
mqHelper.send(excelExportTopic, commonNotifyEntity);

// 动态定时任务消息 —— 直接发 CommonJobEntity
// CommonJobService.java:141
mqHelper.send(commonJobTopic, commonJobEntity);
```

三个真实消息载体：

```java
// 1. 订单实体 (TradeEntity) —— 包含订单全部字段
@Data
public class TradeEntity implements Serializable {
    private Long id;
    private String code;          // 订单编号
    private Long userId;
    private Integer orderStatus;  // OrderStatusEnum: CREATE/PAY/CANCEL...
    private Integer payStatus;    // PayStatusEnum: WAIT_PAY/PAID...
    private BigDecimal tradeAmount;
    private String orderType;     // NORMAL / SECKILL_PRODUCT
    // ... 省略收货地址、商品明细等字段
}

// 2. 通知实体 (CommonNotifyEntity) —— 站内通知
@Data
public class CommonNotifyEntity implements Serializable {
    private String title;
    private String content;       // HTML 格式的通知内容
    private Long toUserId;        // 接收通知的用户 ID
    private Integer isPush;       // 0=未推送 1=已推送
    private Integer readStatus;   // 0=未读 1=已读
}

// 3. 动态任务实体 (CommonJobEntity) —— Quartz 任务描述
@Data
public class CommonJobEntity implements Serializable {
    private String beanName;      // Spring Bean 名称
    private String cronExpression;
    private CommonJobOperateTypeEnum operateTypeEnum; // NEW/UPDATE/DELETE/RUN_NOW/PAUSE/RESUME
    private Boolean pauseStatus;
}
```

<strong>为什么不做 DTO 转换？</strong>

| 做法 | 优点 | 缺点 |
|------|------|------|
| 定义 XxxMessage DTO | 接口解耦，消息格式独立于 DB 表变更 | 多一层转换，字段变更时两端都要改 |
| <strong>直接发 Domain Entity</strong> | 零转换成本，消费者拿到的对象和 DB 一致 | 消息大小随表字段膨胀，改表可能影响消息兼容性 |

该项目的做法有一个看不见的约束支撑：<strong>同一业务模块的发送端和消费端在同一个项目内，共享同一套 Domain 类</strong>。所以不存在"消息格式与消费者不兼容"的问题。

> ⚠️ 新手提示：如果消息的发送方和消费方<strong>分属不同的微服务</strong>，就不要这样干了——应该定义独立的 DTO 类，保证消息契约的独立性。

## 3.3 MqHelper 封装：为什么在 RocketMQTemplate 上再加一层

教程里直接注入 `RocketMQTemplate`。真实项目里多了一层抽象——`MqHelper` 统一包装了 RabbitMQ 和 RocketMQ 的发送逻辑。

<strong>为什么需要 MqHelper？</strong> 这个项目里 RabbitMQ 和 RocketMQ 是同时使用的（RabbitMQ 有完整的基础设施配置，只是当前全部业务跑在 RocketMQ 上）。如果每个业务 Service 都同时注入 `RabbitTemplate` 和 `RocketMQTemplate`，切换成本很高。`MqHelper` 把两种 MQ 的发送逻辑收拢到一起，哪天需要从 RocketMQ 迁到 RabbitMQ，只需改 `MqHelper` 内部实现，业务代码不受影响。

<strong>MqHelper 中 RocketMQ 相关的两个核心方法</strong>：

```java
@Slf4j
@Component
public class MqHelper {

    @Autowired
    private RocketMQTemplate rocketMQTemplate;
    @Autowired
    private RabbitTemplate rabbitTemplate;

    /**
     * 发送 RocketMQ 延迟消息
     * @param topic       Topic 名称
     * @param data        消息体（直接传 Domain Entity）
     * @param delayLevel  RocketMQ 延迟级别（1~18）
     */
    public void send(String topic, Object data, int delayLevel) {
        try {
            MessageHeaders headers = new MessageHeaders(
                    Collections.singletonMap(
                            MessageConst.PROPERTY_DELAY_TIME_LEVEL,
                            String.valueOf(delayLevel)
                    )
            );
            org.springframework.messaging.Message<Object> message =
                    MessageBuilder.createMessage(data, headers);
            rocketMQTemplate.asyncSend(topic, message,
                new SendCallback() {
                    @Override
                    public void onSuccess(SendResult sendResult) {
                        log.info("延迟消息发送成功, topic:{},message:{}",
                                topic, data);
                    }
                    @Override
                    public void onException(Throwable throwable) {
                        log.error("延迟消息发送失败, topic:{}", topic, throwable);
                    }
                }, 3000, delayLevel);
        } catch (Exception e) {
            log.error("延迟消息发送失败, topic={}", topic, e);
            throw new BusinessException("消息发送失败，请重试");
        }
    }

    /**
     * 发送 RocketMQ 普通消息（异步）
     * @param topic   Topic 名称
     * @param message 消息体
     */
    public void send(String topic, Object message) {
        try {
            rocketMQTemplate.asyncSend(topic, message,
                new SendCallback() {
                    @Override
                    public void onSuccess(SendResult sendResult) {
                        log.info("消息发送成功, topic:{},message:{}",
                                topic, message);
                    }
                    @Override
                    public void onException(Throwable throwable) {
                        log.error("消息发送失败, topic:{}", topic, throwable);
                    }
                });
        } catch (Exception e) {
            log.error("消息发送失败, topic={}", topic, e);
            throw new BusinessException("消息发送失败，请重试");
        }
    }
}
```

<strong>五个设计决策</strong>：

1. <strong>全部用 asyncSend，不用 syncSend</strong>——syncSend 要等 Broker 返回 `SendResult`，阻塞业务线程。asyncSend 通过 `SendCallback` 回调通知结果，主业务路径不被 MQ 拖累。失败时写日志就够了——三个业务场景（超时取消、通知、定时任务同步）都不需要同步确认。

2. <strong>延迟消息不走 RocketMQ 的 `syncSendDelay`</strong>（那是同步阻塞的），而是通过 `MessageHeaders` 注入 `PROPERTY_DELAY_TIME_LEVEL` 再用 asyncSend——异步 + 延迟的组合做法。

3. <strong>统一 try-catch 兜底</strong>——不管是什么原因（NameServer 连不上、Topic 不存在、消息体序列化失败），全部 catch 并抛 `BusinessException("消息发送失败，请重试")`，让上层 ControllerAdvice 统一处理。

4. <strong>Topic 名称从 `@Value` 注入</strong>——`@Value("${mall.mgt.excelExportTopic:EXCEL_EXPORT_TOPIC}")`，而不是代码里写死字符串。好处是改 Topic 名只需要改配置，甚至可以通过环境变量覆盖。

5. <strong>不用 `Topic:Tag` 拼接格式</strong>——`rocketMQTemplate.asyncSend(topic, message)` 而不是 `asyncSend("topic:tag", message)`。这个项目的消息过滤需求简单，不需要 Tag 细分。

| 模式 | MqHelper 对应 | 底层方法 | 项目是否使用 |
|------|:---:|------|:---:|
| <strong>同步发送</strong> | — | `syncSend` | ❌ 不使用 |
| <strong>异步发送</strong> | `send(topic, data)` | `asyncSend` + `SendCallback` | ✅ Excel导出通知、动态任务同步 |
| <strong>异步延迟</strong> | `send(topic, data, delayLevel)` | `asyncSend` + header | ✅ 超时取消订单 |
| <strong>单向发送</strong> | — | `sendOneWay` | ❌ 不使用 |

## 3.4 核心链路：下单 → 延迟消息 → 30 分钟后自动取消

这是 RocketMQ 在该项目里<strong>最关键的使命</strong>——"下单 30 分钟未支付自动取消"。

```mermaid
sequenceDiagram
    participant U as 用户
    participant API as mall-api(TradeSaveService)
    participant MQ as RocketMQ Broker
    participant JOB as mall-job(Consumer)
    participant DB as MySQL(ShardingSphere)

    U->>API: 提交订单
    API->>DB: TransactionTemplate\ntradeMapper.insert +\ntradeItemMapper.batchInsert
    API->>MQ: asyncSend(topic, tradeEntity, delayLevel=16)
    Note right of API: 消息在 Broker 侧\n等 30 分钟后才投递
    Note over MQ: delayLevel 16 = 30min\nRocketMQ 18 个预设级别
    MQ-->>API: SendCallback.onSuccess(记日志)
    API-->>U: 下单成功

    Note over MQ: === 30 分钟后 ===

    MQ->>JOB: 投递 OverTimeCancelTradeConsumer
    JOB->>DB: tradeService.findById
    DB-->>JOB: TradeEntity(orderStatus=CREATE)
    opt 订单仍未支付
        JOB->>DB: update orderStatus=CANCEL
        opt 秒杀订单
            JOB->>MQ: send(overTimeCancelTradeTopic, trade)\n通知库存恢复
        end
    end
```

### 3.4.1 TradeSaveService.createTrade：发送端完整代码

```java
@Service
public class TradeSaveService {

    // 订单超时取消延迟：30分钟
    private static final int OVER_TIME_CANCEL_TRADE_DELAY_TIME = 30 * 60 * 1000;
    // RocketMQ 延迟级别 16 = 30分钟
    // 18个级别：1s/5s/10s/30s/1m/2m/3m/4m/5m/6m/7m/8m/9m/10m/20m/30m/1h/2h
    private static final int OVER_TIME_CANCEL_TRADE_DELAY_LEVEL = 16;

    @Autowired
    private TradeMapper tradeMapper;
    @Autowired
    private TradeItemMapper tradeItemMapper;
    @Autowired
    private TransactionTemplate transactionTemplate;
    @Autowired
    private IdGenerateHelper idGenerateHelper;
    @Autowired
    private MqHelper mqHelper;
    @Value("${mall.job.overTimeCancelTradeTopic:OVER_TIME_CANCEL_TRADE_TOPIC}")
    private String overTimeCancelTradeTopic;

    @DS("sharding")
    public void createTrade(JwtUserEntity currentUserInfo, TradeEntity tradeEntity) {
        tradeEntity.setId(idGenerateHelper.nextId());
        tradeEntity.setUserId(currentUserInfo.getId());
        tradeEntity.setUserName(currentUserInfo.getUsername());
        tradeEntity.setOrderStatus(OrderStatusEnum.CREATE.getValue());
        tradeEntity.setPayStatus(PayStatusEnum.WAIT_PAY.getValue());
        tradeEntity.setOrderTime(new Date());

        // TransactionTemplate 而非 @Transactional——
        // ShardingSphere 分库分表下声明式事务不生效
        transactionTemplate.execute((status) -> {
                    tradeMapper.insert(tradeEntity);
                    tradeEntity.getTradeItemEntityList().forEach(x -> {
                        x.setTradeId(tradeEntity.getId());
                        x.setCode(tradeEntity.getCode());
                    });
                    tradeItemMapper.batchInsert(tradeEntity.getTradeItemEntityList());
                    return Boolean.TRUE;
                }
        );

        // 发送 RocketMQ 延迟消息（30分钟后），由消费者检查订单是否已支付，未支付则自动取消
        sendOvertimeCancelTradeMessage(tradeEntity);
    }

    private void sendOvertimeCancelTradeMessage(TradeEntity tradeEntity) {
        mqHelper.send(overTimeCancelTradeTopic,
                tradeEntity,
                OVER_TIME_CANCEL_TRADE_DELAY_LEVEL
        );
    }
}
```

### 3.4.2 OverTimeCancelTradeConsumer：消费端

```java
@RocketMQMessageListener(
    topic = "${mall.job.overTimeCancelTradeTopic:OVER_TIME_CANCEL_TRADE_TOPIC}",
    consumerGroup = "${mall.job.overTimeCancelTradeGroup:OVER_TIME_CANCEL_TRADE_GROUP}")
@Slf4j
@Component
public class OverTimeCancelTradeConsumer
        implements RocketMQListener<MessageExt> {

    @Autowired
    private TradeService tradeService;

    @Override
    public void onMessage(MessageExt message) {
        byte[] body = message.getBody();
        String content = new String(body);
        log.info("OverTimeCancelTradeConsumer接收到消息：{}", content);
        TradeEntity tradeEntity = JSONUtil.toBean(content, TradeEntity.class);
        tradeService.handleOverTimeCancelTrade(tradeEntity);
    }
}
```

### 3.4.3 TradeSubmitService.handleOverTimeCancelTrade：实际取消逻辑

```java
@Service
public class TradeSubmitService {

    @Autowired
    private TradeService tradeService;
    @Autowired
    private MqHelper mqHelper;
    @Value("${mall.job.overTimeCancelTradeTopic:OVER_TIME_CANCEL_TRADE_TOPIC}")
    private String overTimeCancelTradeTopic;

    public void handleOverTimeCancelTrade(TradeEntity tradeEntity) {
        // 从 DB 重新查询，确保拿到最新状态
        TradeEntity tradeEntityFromDB = tradeService.findById(tradeEntity.getId());
        AssertUtil.notNull(tradeEntityFromDB, "订单不存在");

        // 只有订单状态仍为 CREATE（未支付）时才取消
        if (OrderStatusEnum.CREATE.getValue().equals(tradeEntityFromDB.getOrderStatus())) {
            TradeEntity updateEntity = new TradeEntity();
            updateEntity.setOrderStatus(OrderStatusEnum.CANCEL.getValue());
            updateEntity.setUpdateTime(new Date());
            updateEntity.setId(tradeEntityFromDB.getId());
            tradeService.update(updateEntity);

            // 如果是秒杀订单，再发一条消息通知库存恢复
            if (OrderTypeEnum.SECKILL_PRODUCT.getValue().equals(tradeEntityFromDB.getOrderType())) {
                mqHelper.send(overTimeCancelTradeTopic, tradeEntity);
            }
        }
    }
}
```

<strong>为什么用 RocketMQ 做延迟取消而不是 RabbitMQ？</strong>

| 方案 | 延迟实现 | 精度 | 可靠性 |
|------|----------|:---:|:---:|
| <strong>RocketMQ delayLevel</strong> | Broker 内置 18 个延迟级别，原生支持 | 分钟级（预设级别） | 高——Broker 端消息持久化 |
| RabbitMQ x-message-ttl + DLX | 队列 TTL 过期 → 死信队列 | 毫秒级 | 中——消息在 TTL 期间无法被其他消费者看到 |
| RabbitMQ delayed-message-exchange | 插件实现（非官方） | 毫秒级 | 低——插件可能不兼容新版 Broker |
| Redis 过期回调 + 定时扫表 | keyspace notification + 定时任务 | 秒级 | 低——过期回调不可靠，可能丢 |

项目选了 RocketMQ 延迟消息做超时取消，看中的就是<strong>Broker 原生支持、不需要额外插件、消息持久化可靠</strong>。30 分钟正好是 delayLevel=16（预设的 18 个级别之一），不需要精确到秒。

## 3.5 通知链路：Excel 导出 → MQ → WebSocket 推送

后台管理导出 Excel → 生成文件 → 写通知记录 → 发 RocketMQ → 消费者通过 WebSocket 推到用户浏览器。

### 3.5.1 ExcelExportTask.doExportExcel：发送端完整代码

```java
@AsyncTask(TaskTypeEnum.EXPORT_EXCEL)
@Slf4j
@Service
public class ExcelExportTask implements IAsyncTask {

    @Autowired
    private CommonTaskMapper commonTaskMapper;
    @Autowired
    private CommonNotifyMapper commonNotifyMapper;
    @Autowired
    private TransactionTemplate transactionTemplate;
    @Autowired
    private MqHelper mqHelper;
    @Value("${mall.job.excelExportTopic:EXCEL_EXPORT_TOPIC}")
    private String excelExportTopic;

    @Override
    public void doTask(CommonTaskEntity commonTaskEntity) {
        doExportExcel(commonTaskEntity);
    }

    private void doExportExcel(CommonTaskEntity commonTaskEntity) {
        ExcelBizTypeEnum excelBizTypeEnum = getExcelBizTypeEnum(commonTaskEntity.getBizType());
        // 任务开始执行时，状态改成执行中
        commonTaskEntity.setStatus(TaskStatusEnum.RUNNING.getValue());
        FillUserUtil.fillUpdateUserInfoFromCreate(commonTaskEntity);
        commonTaskMapper.update(commonTaskEntity);

        try {
            // 通过反射调用对应的 Service 执行导出
            String requestEntity = excelBizTypeEnum.getRequestEntity();
            Class<?> aClass = Class.forName(requestEntity);
            String requestParam = commonTaskEntity.getRequestParam();
            Object toBean = JSONUtil.toBean(requestParam, aClass);
            String serviceName = getServiceName(requestEntity);
            BaseService baseService = (BaseService) SpringBeanUtil.getBean(serviceName);
            String fileName = getFileName(excelBizTypeEnum.getDesc());
            String fileUrl = baseService.export(toBean, fileName, getEntityName(requestEntity));
            // 执行成功
            commonTaskEntity.setFileUrl(fileUrl);
            commonTaskEntity.setStatus(TaskStatusEnum.SUCCESS.getValue());
        } catch (Exception e) {
            log.error("数据导出异常，原因：", e);
            commonTaskEntity.setFailureCount(commonTaskEntity.getFailureCount() + 1);
            // 失败次数超过3次 → 标记失败，不再重试
            if (commonTaskEntity.getFailureCount() >= 3) {
                commonTaskEntity.setStatus(TaskStatusEnum.FAIL.getValue());
            }
        }

        commonTaskEntity.setUpdateTime(new Date());

        // TransactionTemplate：任务状态更新 + 通知消息写入 在同一事务中
        CommonNotifyEntity commonNotifyEntity = transactionTemplate.execute((status) -> {
            commonTaskMapper.update(commonTaskEntity);
            return saveNotifyMessage(commonTaskEntity);
        });

        // 通过 RocketMQ 异步通知，不阻塞导出线程
        mqHelper.send(excelExportTopic, commonNotifyEntity);
    }

    private CommonNotifyEntity saveNotifyMessage(CommonTaskEntity commonTaskEntity) {
        CommonNotifyEntity commonNotifyEntity = new CommonNotifyEntity();
        commonNotifyEntity.setTitle("excel导出通知");
        commonNotifyEntity.setContent(getContent(commonTaskEntity));
        commonNotifyEntity.setToUserId(commonTaskEntity.getCreateUserId());
        commonNotifyEntity.setIsPush(0);
        commonNotifyEntity.setType(1);
        commonNotifyEntity.setReadStatus(0);
        commonNotifyEntity.setCreateUserId(commonTaskEntity.getCreateUserId());
        commonNotifyEntity.setCreateUserName(commonTaskEntity.getCreateUserName());
        commonNotifyEntity.setCreateTime(new Date());
        commonNotifyEntity.setIsDel(0);
        commonNotifyMapper.insert(commonNotifyEntity);
        return commonNotifyEntity;
    }
}
```

### 3.5.2 ExcelExportConsumer：消费端

```java
@RocketMQMessageListener(
    topic = "${mall.job.excelExportTopic:EXCEL_EXPORT_TOPIC}",
    consumerGroup = "${mall.job.excelExportGroup:EXCEL_EXPORT_GROUP}")
@Slf4j
@Component
public class ExcelExportConsumer implements RocketMQListener<MessageExt> {

    @Autowired
    private CommonNotifyMapper commonNotifyMapper;

    @Override
    public void onMessage(MessageExt message) {
        byte[] body = message.getBody();
        String content = new String(body);
        log.info("ExcelExportConsumer接收到消息：{}", content);
        CommonNotifyEntity commonTaskEntity =
                JSONUtil.toBean(content, CommonNotifyEntity.class);
        pushNotify(commonTaskEntity);
    }

    private void pushNotify(CommonNotifyEntity commonNotifyEntity) {
        try {
            // WebSocket 推送到目标用户浏览器
            WebSocketServer.sendMessage(commonNotifyEntity);
            // 标记已推送
            commonNotifyEntity.setIsPush(1);
            FillUserUtil.mockCurrentUser();
            commonNotifyMapper.update(commonNotifyEntity);
        } catch (IOException e) {
            log.error("WebSocket通知推送失败，原因：", e);
        } finally {
            FillUserUtil.clearCurrentUser();
        }
    }
}
```

这个消费者的特别之处：<strong>消息消费 + WebSocket 推送 + DB 状态回写</strong>三步在同一个方法中完成。但注意 <strong>它不是事务性的</strong>——WebSocket 推送失败后 DB 更新不会回滚，只记日志。这是有意为之：Excel 导出通知允许偶尔推送失败（用户刷新页面也能看到），但 push 失败的记录不会标记为"已推送"，下次可重试。

## 3.6 一致性链路：多节点 Quartz 动态任务同步

当管理员在后台新增/修改/删除/暂停/恢复一个定时任务时，<strong>所有 mall-job 节点都需要感知到这个变化</strong>——RocketMQ 在这里的角色是"分布式事件总线"。

### 3.6.1 CommonJobService：发送端完整代码

```java
@Slf4j
@Service
public class CommonJobService extends BaseService<CommonJobEntity, CommonJobQuery> {

    @Autowired
    private CommonJobMapper commonJobMapper;
    @Autowired
    private MqHelper mqHelper;
    @Value("${mall.job.commonJobTopic:COMMON_JOB_TOPIC}")
    private String commonJobTopic;

    /** 新增定时任务 */
    public int insert(CommonJobEntity commonJobEntity) {
        checkParam(commonJobEntity);
        commonJobEntity.setPauseStatus(false);
        int insert = commonJobMapper.insert(commonJobEntity);  // 先落库
        commonJobEntity.setOperateTypeEnum(CommonJobOperateTypeEnum.NEW);
        sendDynamicJobMessage(commonJobEntity);  // 再广播
        return insert;
    }

    /** 修改定时任务 */
    public int update(CommonJobEntity commonJobEntity) {
        AssertUtil.notNull(commonJobEntity.getId(), "id不能为空");
        checkParam(commonJobEntity);
        int update = commonJobMapper.update(commonJobEntity);
        commonJobEntity.setOperateTypeEnum(CommonJobOperateTypeEnum.UPDATE);
        sendDynamicJobMessage(commonJobEntity);
        return update;
    }

    /** 批量删除 */
    public int deleteByIds(List<Long> ids) {
        List<CommonJobEntity> entities = commonJobMapper.findByIds(ids);
        AssertUtil.notEmpty(entities, "定时任务已被删除");

        CommonJobEntity entity = new CommonJobEntity();
        FillUserUtil.fillUpdateUserInfo(entity);
        int delete = commonJobMapper.deleteByIds(ids, entity);

        for (CommonJobEntity commonJobEntity : entities) {
            commonJobEntity.setOperateTypeEnum(CommonJobOperateTypeEnum.DELETE);
            sendDynamicJobMessage(commonJobEntity);
        }
        return delete;
    }

    /** 恢复任务 */
    public void resume(CommonJobEntity commonJobEntity) {
        CommonJobEntity jobEntity = checkChangeJobParam(commonJobEntity);
        jobEntity.setPauseStatus(false);
        FillUserUtil.fillUpdateUserInfo(jobEntity);
        commonJobMapper.update(jobEntity);

        jobEntity.setOperateTypeEnum(CommonJobOperateTypeEnum.RESUME);
        sendDynamicJobMessage(jobEntity);
    }

    /** 暂停任务 */
    public void pause(CommonJobEntity commonJobEntity) {
        CommonJobEntity jobEntity = checkChangeJobParam(commonJobEntity);
        jobEntity.setPauseStatus(true);
        FillUserUtil.fillUpdateUserInfo(jobEntity);
        commonJobMapper.update(jobEntity);

        jobEntity.setOperateTypeEnum(CommonJobOperateTypeEnum.PAUSE);
        sendDynamicJobMessage(jobEntity);
    }

    /** 立即执行 */
    public void runNow(CommonJobEntity commonJobEntity) {
        changeJob(commonJobEntity, CommonJobOperateTypeEnum.RUN_NOW);
    }

    private void sendDynamicJobMessage(CommonJobEntity commonJobEntity) {
        mqHelper.send(commonJobTopic, commonJobEntity);
    }

    // ... checkParam, checkChangeJobParam, changeJob 等辅助方法省略
}
```

关键设计：<strong>先落库、再发消息</strong>——Consumer 收到消息后从内存里的 `QuartzManage` 直接操作，但 DB 记录已经在发送端写好了。如果消息丢失（asyncSend 的场景），至少 DB 是准的，后续可以通过定时全量同步来修复。

### 3.6.2 DynamicJobConsumer：消费端

```java
@RocketMQMessageListener(
    topic = "${mall.job.commonJobTopic:COMMON_JOB_TOPIC}",
    consumerGroup = "${mall.job.commonJobGroup:COMMON_JOB_GROUP}")
@Slf4j
@Component
public class DynamicJobConsumer implements RocketMQListener<MessageExt> {

    @Autowired
    private QuartzManage quartzManage;

    @Override
    public void onMessage(MessageExt message) {
        byte[] body = message.getBody();
        String content = new String(body);
        log.info("DynamicJobConsumer接收到消息：{}", content);
        CommonJobEntity commonJobEntity =
                JSONUtil.toBean(content, CommonJobEntity.class);
        handleDynamicJobMessage(commonJobEntity);
    }

    private void handleDynamicJobMessage(CommonJobEntity commonJobEntity) {
        CommonJobOperateTypeEnum operateTypeEnum =
                commonJobEntity.getOperateTypeEnum();
        switch (operateTypeEnum) {
            case NEW:     quartzManage.addJob(commonJobEntity);      break;
            case UPDATE:  quartzManage.updateJobCron(commonJobEntity); break;
            case DELETE:  quartzManage.deleteJob(commonJobEntity);   break;
            case RUN_NOW: quartzManage.runJobNow(commonJobEntity);   break;
            case PAUSE:   quartzManage.pauseJob(commonJobEntity);    break;
            case RESUME:  quartzManage.resumeJob(commonJobEntity);   break;
            default:
                throw new BusinessException("动态定时任务操作类型错误");
        }
    }
}
```

这是典型的<strong>"命令消息"模式</strong>——消息体里有 `operateTypeEnum` 枚举字段，消费者根据枚举值 dispatch 到不同的 Quartz 操作。<strong>为什么不拆成 6 个 Consumer？</strong>因为操作类型是消息的一部分，拆 Consumer 要 6 个类、6 个注解、6 个 ConsumerGroup，维护成本和 Topic 数量都翻倍。一个 Consumer 一个 switch 足够清晰。

### 3.6.3 三个消费者的共同模式

三个消费者有一个共同模式——<strong>接收 `MessageExt` 并用 Hutool JSONUtil 手动解析</strong>，不用泛型自动反序列化。

为什么不用 `RocketMQListener<TradeEntity>` 泛型自动解析？两个原因：

1. <strong>消息体不是纯 JSON</strong>——`RocketMQTemplate.asyncSend` 发送 Java 对象时，底层用的是 RocketMQ 的 `MessagePayloadConverter`，序列化格式依赖 Starter 版本。直接收 `MessageExt` 然后 `new String(body)` + `JSONUtil.toBean` 更可控。
2. <strong>泛型解析失败时异常信息很差</strong>——"类型转换异常: can not cast ..." 不如手动解析写清楚日志 "接收到消息：{content}" 再反序列化，排查快得多。

## 3.7 基础设施：WebSocketServer + QuartzManage

前面 3 条业务线的消费者依赖两个底层组件——`WebSocketServer` 做消息推送，`QuartzManage` 做动态任务管理。下面是它们的完整源码。

### 3.7.1 WebSocketServer：消息推送基础设施

```java
@ServerEndpoint("/websocket/{userId}")
@Component
@Slf4j
public class WebSocketServer {

    private static int onlineCount = 0;
    private static ConcurrentHashMap<Long, WebSocketServer> webSocketMap = new ConcurrentHashMap<>();
    private Session session;
    private Long userId;

    @OnOpen
    public void onOpen(Session session, @PathParam("userId") Long userId) {
        this.session = session;
        this.userId = userId;
        if (webSocketMap.containsKey(userId)) {
            webSocketMap.remove(userId);
        } else {
            webSocketMap.put(userId, this);
            addOnlineCount();
        }
        log.info("用户连接:{}, 当前在线人数为:{}", userId, getOnlineCount());
    }

    @OnClose
    public void onClose() {
        if (webSocketMap.containsKey(userId)) {
            webSocketMap.remove(userId);
            subOnlineCount();
        }
        log.info("用户退出userId:{}, 当前在线人数为:{}", userId, getOnlineCount());
    }

    @OnMessage
    public void onMessage(String message, Session session) {
        log.info("用户消息:{}, 报文:{}", userId, message);
        if (StringUtils.isNotBlank(message)) {
            try {
                if (Objects.nonNull(userId) && webSocketMap.containsKey(userId)) {
                    webSocketMap.get(userId).sendMessage(message);
                } else {
                    log.error("请求的userId:{} 不在该服务器上", userId);
                }
            } catch (Exception e) {
                log.error("服务器处理通知失败", e);
            }
        }
    }

    @OnError
    public void onError(Session session, Throwable error) {
        log.error("用户错误:{}, 原因:{}", this.userId, error.getMessage(), error);
    }

    public void sendMessage(String message) throws IOException {
        synchronized (session) {
            try {
                RemoteEndpoint.Basic basicRemote = this.session.getBasicRemote();
                basicRemote.sendText(message);
                log.info("通知：{}推送成功", message);
            } catch (IOException e) {
                log.error("服务器推送失败", e);
                throw e;
            }
        }
    }

    /**
     * 静态推送方法：toUserId 为空时广播所有人，否则定向推送
     */
    public static void sendMessage(CommonNotifyEntity commonNotifyEntity) throws IOException {
        if (Objects.isNull(commonNotifyEntity.getToUserId())) {
            Iterator<Long> iterator = webSocketMap.keySet().iterator();
            while (iterator.hasNext()) {
                Long userId = iterator.next();
                WebSocketServer item = webSocketMap.get(userId);
                item.sendMessage(commonNotifyEntity.getContent());
            }
        } else if (webSocketMap.containsKey(commonNotifyEntity.getToUserId())) {
            WebSocketServer item = webSocketMap.get(commonNotifyEntity.getToUserId());
            item.sendMessage(commonNotifyEntity.getContent());
        } else {
            log.error("请求的userId:{} 不在该服务器上", commonNotifyEntity.getToUserId());
        }
    }

    public static synchronized int getOnlineCount() { return onlineCount; }
    public static synchronized void addOnlineCount() { WebSocketServer.onlineCount++; }
    public static synchronized void subOnlineCount() { WebSocketServer.onlineCount--; }
}
```

<strong>关键设计</strong>：`sendMessage(CommonNotifyEntity)` 是静态方法——消费者在任意位置都可以直接调用 `WebSocketServer.sendMessage(entity)` 推送消息，不需要注入 Bean。`ConcurrentHashMap<Long, WebSocketServer>` 维护了 userId → WebSocket 连接的映射。`toUserId` 为空时广播所有在线用户，否则定向推送给指定用户。

### 3.7.2 QuartzManage：动态定时任务管理器

```java
@Slf4j
@Component
public class QuartzManage {

    public static final String JOB_KEY = "JOB_KEY";
    private static final String JOB_NAME = "TASK_";

    @Autowired
    private Scheduler scheduler;

    /** 新增任务 */
    public void addJob(CommonJobEntity jobEntity) {
        try {
            TriggerKey triggerKey = TriggerKey.triggerKey(JOB_NAME + jobEntity.getId());
            CronTrigger trigger = (CronTrigger) scheduler.getTrigger(triggerKey);
            if (Objects.nonNull(trigger)) {
                return;  // 已存在，跳过
            }

            JobDetail jobDetail = JobBuilder.newJob(QuartzExecutionJob.class)
                    .withIdentity(JOB_NAME + jobEntity.getId()).build();

            Trigger cronTrigger = newTrigger()
                    .withIdentity(JOB_NAME + jobEntity.getId())
                    .startNow()
                    .withSchedule(CronScheduleBuilder.cronSchedule(jobEntity.getCronExpression()))
                    .build();

            cronTrigger.getJobDataMap().put(JOB_KEY, jobEntity);
            ((CronTriggerImpl) cronTrigger).setStartTime(new Date());
            scheduler.scheduleJob(jobDetail, cronTrigger);

            if (jobEntity.getPauseStatus()) {
                pauseJob(jobEntity);
            }
        } catch (Exception e) {
            log.error("创建定时任务失败", e);
            throw new BusinessException("创建定时任务失败");
        }
    }

    /** 更新 cron 表达式 */
    public void updateJobCron(CommonJobEntity jobEntity) {
        try {
            TriggerKey triggerKey = TriggerKey.triggerKey(JOB_NAME + jobEntity.getId());
            CronTrigger trigger = (CronTrigger) scheduler.getTrigger(triggerKey);
            if (trigger == null) {
                addJob(jobEntity);
                trigger = (CronTrigger) scheduler.getTrigger(triggerKey);
            }
            CronScheduleBuilder scheduleBuilder = CronScheduleBuilder.cronSchedule(jobEntity.getCronExpression());
            trigger = trigger.getTriggerBuilder().withIdentity(triggerKey).withSchedule(scheduleBuilder).build();
            ((CronTriggerImpl) trigger).setStartTime(new Date());
            trigger.getJobDataMap().put(JOB_KEY, jobEntity);
            scheduler.rescheduleJob(triggerKey, trigger);
            if (jobEntity.getPauseStatus()) {
                pauseJob(jobEntity);
            }
        } catch (Exception e) {
            log.error("更新定时任务失败", e);
            throw new BusinessException("更新定时任务失败");
        }
    }

    /** 删除任务 */
    public void deleteJob(CommonJobEntity jobEntity) {
        try {
            JobKey jobKey = JobKey.jobKey(JOB_NAME + jobEntity.getId());
            scheduler.pauseJob(jobKey);
            scheduler.deleteJob(jobKey);
        } catch (Exception e) {
            log.error("删除定时任务失败", e);
            throw new BusinessException("删除定时任务失败");
        }
    }

    /** 恢复任务 */
    public void resumeJob(CommonJobEntity jobEntity) {
        try {
            TriggerKey triggerKey = TriggerKey.triggerKey(JOB_NAME + jobEntity.getId());
            CronTrigger trigger = (CronTrigger) scheduler.getTrigger(triggerKey);
            if (trigger == null) {
                addJob(jobEntity);
            }
            JobKey jobKey = JobKey.jobKey(JOB_NAME + jobEntity.getId());
            scheduler.resumeJob(jobKey);
        } catch (Exception e) {
            log.error("恢复定时任务失败", e);
            throw new BusinessException("恢复定时任务失败");
        }
    }

    /** 立即执行 */
    public void runJobNow(CommonJobEntity jobEntity) {
        try {
            TriggerKey triggerKey = TriggerKey.triggerKey(JOB_NAME + jobEntity.getId());
            CronTrigger trigger = (CronTrigger) scheduler.getTrigger(triggerKey);
            if (trigger == null) {
                addJob(jobEntity);
            }
            JobDataMap dataMap = new JobDataMap();
            dataMap.put(JOB_KEY, jobEntity);
            JobKey jobKey = JobKey.jobKey(JOB_NAME + jobEntity.getId());
            scheduler.triggerJob(jobKey, dataMap);
        } catch (Exception e) {
            log.error("定时任务执行失败", e);
            throw new BusinessException("定时任务执行失败");
        }
    }

    /** 暂停任务 */
    public void pauseJob(CommonJobEntity jobEntity) {
        try {
            JobKey jobKey = JobKey.jobKey(JOB_NAME + jobEntity.getId());
            scheduler.pauseJob(jobKey);
        } catch (Exception e) {
            log.error("定时任务暂停失败", e);
            throw new BusinessException("定时任务暂停失败");
        }
    }
}
```

<strong>关键设计</strong>：所有任务以 `TASK_` + `jobEntity.getId()` 作为 JobKey/TriggerKey 命名规则——保证全局唯一。每个方法都是幂等的（如 `addJob` 先检查是否存在、`updateJobCron` 不存在则创建）——因为消息可能重复投递。`QuartzExecutionJob` 是实际执行的 Job 实现类，通过 `JobDataMap` 传递 `CommonJobEntity` 参数。

## 3.8 生产消费全链路数据流总结

三条业务线在 RocketMQ 上的完整数据流：

```
┌──────────────────────────────────────────────────────────────────┐
│  mall-api (生产者)                                                │
│                                                                   │
│  TradeSaveService.createTrade()                                   │
│    ├─ TransactionTemplate: insert trade + batchInsert items       │
│    └─ mqHelper.send(topic, tradeEntity, delayLevel=16)  ──────┐  │
│                                                                 │  │
│  ExcelExportTask.doExportExcel()                                │  │
│    ├─ baseService.export() → 生成 Excel 文件                     │  │
│    ├─ TransactionTemplate: update task + insert notify          │  │
│    └─ mqHelper.send(topic, commonNotifyEntity)  ────────────┐  │  │
│                                                               │  │  │
│  CommonJobService.insert/update/delete/pause/resume/runNow()  │  │  │
│    ├─ DB 操作先落库                                             │  │  │
│    └─ mqHelper.send(topic, commonJobEntity)  ──────────────┐ │  │  │
│                                                             │ │  │  │
├─────────────────────────────────────────────────────────────┼─┼──┼──┤
│                        RocketMQ Broker                       │ │  │  │
│  ① OVER_TIME_CANCEL_TRADE_TOPIC (delayLevel=16, 30min)      │←┘  │  │
│  ② EXCEL_EXPORT_TOPIC                                        │←───┘  │
│  ③ COMMON_JOB_TOPIC                                          │←──────┘
├─────────────────────────────────────────────────────────────┼─┼──┼──┤
│  mall-job (消费者)                                            │ │  │  │
│                                                               │ │  │  │
│  OverTimeCancelTradeConsumer.onMessage(MessageExt)  ←────────┘ │  │
│    └─ tradeService.handleOverTimeCancelTrade()                  │  │
│         └─ TradeSubmitService: 检查状态 → 取消 → 秒杀则再发消息  │  │
│                                                               │  │
│  ExcelExportConsumer.onMessage(MessageExt)  ←─────────────────┘  │
│    ├─ WebSocketServer.sendMessage(notifyEntity)  → 用户浏览器     │
│    └─ commonNotifyMapper.update(isPush=1)                         │
│                                                               │  │
│  DynamicJobConsumer.onMessage(MessageExt)  ←──────────────────┘
│    └─ quartzManage.addJob/updateJobCron/deleteJob/...
│         └─ scheduler.scheduleJob/rescheduleJob/deleteJob...
```

## 3.9 为什么 RabbitMQ 基础设施也配好了却没用？

在 `RabbitConfig` 里可以看到 4 组 Exchange/Queue/Binding 全配好了——`excel_export_exchange`、`over_time_cancel_trade_exchange`、`trade_status_change_exchange`、`dynamic_job_exchange`，对应 RocketMQ 的三个业务场景。但 `MqHelper` 里所有业务代码调用的都是 `send(String topic, ...)` → RocketMQ。

这是典型的<strong>"基础设施先行"策略</strong>：RabbitMQ 的拓扑结构已经声明，MqHelper 的 RabbitMQ 相关方法（`send(exchange, routingKey, data)`、`sendDelayMessage(...)`）也已经就绪。哪天需要从 RocketMQ 切到 RabbitMQ，操作步骤非常明确：

1. `application.yml` 添加 `spring.rabbitmq` 配置
2. 把 `mqHelper.send(topic, data)` 改成 `mqHelper.send(exchange, routingKey, data)`（用对应的 RabbitConfig 常量）
3. 消费者端把 `@RocketMQMessageListener` 改成 `@RabbitListener`

不需要重新设计拓扑，不需要重新定义消息格式，<strong>切换成本被 MqHelper 层控制在 3 步以内</strong>。

---

# Part 4：验证与排错

## 4.1 FAQ

| 问题 | 原因 | 解决 |
|------|------|------|
| `MQClientException: No route info of this topic` | Topic 不存在——Broker 自动创建关闭或生产者没权限 | 首次发送前手动创建 Topic：`mqadmin updateTopic -n namesrv:9876 -t OVER_TIME_CANCEL_TRADE_TOPIC`。生产环境关闭 `autoCreateTopicEnable` 是安全要求 |
| 延迟消息没按预期 30 分钟后投递 | RocketMQ 的 delayLevel 和实际时间的映射记错了 | RocketMQ 不支持自定义延迟时间！只有 18 个预设级别：`1=1s, 2=5s, 3=10s, 4=30s, 5=1m, 6=2m, 7=3m, 8=4m, 9=5m, 10=6m, 11=7m, 12=8m, 13=9m, 14=10m, 15=20m, 16=30m, 17=1h, 18=2h` |
| `asyncSend` 回调里抛异常，调用方感知不到 | asyncSend 的 `SendCallback.onException` 只记日志 | 项目里 MqHelper 的 `SendCallback.onException` 只打 `log.error`。对于关键业务，建议额外加监控——比如 `onException` 里写一个 Redis key 或发告警 Webhook |
| 消费者收到消息但反序列化报错 | 发送端和消费端用了不同的 JSON 库或实体类版本不一致 | 项目用 `MessageExt.getBody()` + Hutool `JSONUtil.toBean` 手动反序列化，比泛型自动反序列化更可控 |
| Topic 名称的 SpEL 表达式没解析，直接当字符串用了 | 忘记在 `@Value` 里配对应的配置 key | `@RocketMQMessageListener(topic = "${mall.job.excelExportTopic:EXCEL_EXPORT_TOPIC}")` 要求 `application.yml` 中有对应配置。如果没配，走默认值 |
| 消费者重复消费同一条消息 | RocketMQ 消费超时后 Broker 重新投递 | 消费者方法里尽量做幂等：超时取消消费者先查订单状态（已取消就不重复操作），Excel 通知消费者用 `isPush=1` 做去重标记 |
| RabbitMQ 的 `RabbitConfig` 里配了 4 组 Exchange/Queue，但消费者全是 RocketMQ 的 | 项目做了双 MQ 基础设施准备，RabbitMQ 拓扑已声明但未启用 | 不是 bug——这是"基础设施先行"策略。想切到 RabbitMQ 时参考 3.9 的切换步骤 |
| `@RocketMQMessageListener` 注解参数速查 | — | `topic`: SpEL 可读配置；`consumerGroup`: 消费者组；`selectorExpression`: Tag/SQL92 过滤表达式（默认 `*`）；`consumeMode`: 并发/顺序（默认并发）；`consumeThreadNumber`: 消费线程数（默认 20） |

## 4.2 总结

本文从教程到生产，把 RocketMQ 在 SpringBoot 项目中的真实用法讲了一遍：

1. <strong>Part 2 教程版</strong>：`RocketMQTemplate` 三种发送模式、`@RocketMQMessageListener` 泛型自动解析、顺序消息（`syncSendOrderly` + `ConsumeMode.ORDERLY`）、Tag/SQL92 过滤。

2. <strong>MqHelper 统一封装</strong>：不直接注入 `RocketMQTemplate`，而是通过 `MqHelper` 收拢发送逻辑。asyncSend + SendCallback 日志记录、统一 try-catch 兜底转 BusinessException、Topic 名从配置注入。同时预留 RabbitMQ 发送方法，为双 MQ 切换做准备。

3. <strong>延迟消息——RocketMQ 的核心价值</strong>：利用内置 18 个 delayLevel 实现"下单 30 分钟未支付自动取消"。完整链路：`TradeSaveService.createTrade`（TransactionTemplate + MQ）→ `OverTimeCancelTradeConsumer` → `TradeSubmitService.handleOverTimeCancelTrade`（状态检查 + 幂等取消 + 秒杀库存恢复）。

4. <strong>三个真实消费者的完整实现</strong>：超时取消（延迟消息 + 业务补偿）、Excel 通知（MQ → WebSocket → DB 状态回写）、动态任务同步（枚举驱动六路操作分发）。全部接收 `MessageExt` 手动反序列化。

5. <strong>基础设施完整代码</strong>：`WebSocketServer`（JSR 356, `ConcurrentHashMap<Long, WebSocketServer>` 连接管理, 静态推送方法）、`QuartzManage`（6 种操作全部幂等, `TASK_` 命名规则, `QuartzExecutionJob` 动态执行）、`CommonJobService`（完整 CRUD + 先落库再发消息）。

6. <strong>Domain Entity 直传 + RabbitMQ 基础设施先行</strong>：`TradeEntity`、`CommonNotifyEntity`、`CommonJobEntity` 直接扔进消息队列。虽然当前全部业务跑在 RocketMQ 上，但 RabbitMQ 的 4 组 Exchange/Queue/Binding 已经在 `RabbitConfig` 中就绪。`MqHelper` 的抽象层让将来切换只需改 3 步。

> 📖 <strong>下一步阅读</strong>：延迟消息搞定了"30 分钟自动取消"，但怎么保证"下单 + 扣库存 + 发消息"这三个操作的原子性？继续阅读 [<strong>顺序消息、延迟消息与事务消息</strong>]({{< relref "AdvancedMessages.md" >}})，一篇掌握 RocketMQ 最独特的三大高级特性。
