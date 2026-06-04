---
title: "SpringBoot RabbitMQ 全操作指南"
date: 2022-11-03T08:00:00+00:00
tags: ["消息队列"]
categories: ["消息队列中间件"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "一篇掌握 SpringBoot RabbitMQ 全部常用操作：RabbitTemplate 发送、@RabbitListener 消费、Jackson2Json 消息转换、Direct/Fanout/Topic 三种交换机的 Spring 化声明、手动 ACK 配置与 FAQ 排错。"
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

# SpringBoot RabbitMQ 全操作指南

> 📖 <strong>前置阅读</strong>：本文假设读者已理解 RabbitMQ 的核心概念（Exchange、Queue、Binding、RoutingKey）和四种交换机类型。如果还不熟悉，建议先阅读前两篇：
> - [<strong>RabbitMQ 核心概念与 AMQP 协议</strong>]({{< relref "RabbitMQFundamentals.md" >}})
> - [<strong>交换机类型完全指南</strong>]({{< relref "ExchangeTypesGuide.md" >}})

## 🎯 第一步：目标说明

前两篇用 RabbitMQ 原生 Java Client 写了所有代码——`channel.basicPublish`、`channel.basicConsume`、手动 `basicAck`。理解底层是正确的，但真正进项目时，Spring AMQP 帮我们做了 90% 的重复工作。

读完这篇会掌握：

- 用 <strong>RabbitTemplate</strong> 一行代码发消息（替代 `channel.basicPublish` 那一大堆）
- 用 <strong>@RabbitListener</strong> 注解收消息（替代手动 `basicConsume` + `DeliverCallback`）
- 用 <strong>Jackson2JsonMessageConverter</strong> 自动序列化/反序列化 Java 对象
- 用 <strong>@Bean + 声明式配置</strong> 管理 Exchange/Queue/Binding（替代每次启动时 `channel.exchangeDeclare`）
- 三种交换机在 Spring 中的完整示例代码（Direct / Fanout / Topic）
- <strong>手动 ACK</strong> 的配置和坑

文中的所有代码可以直接复制到 SpringBoot 项目里运行。

## 📋 第二步：前置条件

| 前置项 | 具体要求 | 验证命令 |
|--------|----------|----------|
| JDK | 17+（8+ 也兼容） | `java -version` |
| Maven | 3.6+ | `mvn -v` |
| SpringBoot | 3.x（文中用 3.2） | `mvn dependency:tree \| grep spring-boot` |
| RabbitMQ | 3.12+（management 版） | `docker ps \| grep rabbitmq` |
| 前置知识 | 前两篇的 Exchange/Queue/Binding/RoutingKey 概念 | — |

确认 RabbitMQ 在跑：

```bash
docker ps | grep rabbitmq
# 如果没跑起来，执行：
docker run -d --name rabbitmq -p 5672:5672 -p 15672:15672 \
  -e RABBITMQ_DEFAULT_USER=admin -e RABBITMQ_DEFAULT_PASS=admin123 \
  rabbitmq:3.12-management-alpine
```

## 🔧 第三步：环境搭建

### 3.1 依赖

```xml
<!-- Spring AMQP（RabbitMQ 的 Spring 封装） -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-amqp</artifactId>
</dependency>

<!-- Jackson JSON（消息序列化用） -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-json</artifactId>
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

<strong>一个 `spring-boot-starter-amqp` 就够了</strong>——它内置了 RabbitMQ 客户端、Spring AMQP 核心、连接工厂自动配置。不需要额外引入 `com.rabbitmq:amqp-client`。

### 3.2 配置文件

```yaml
spring:
  rabbitmq:
    host: localhost
    port: 5672
    username: admin
    password: admin123
    virtual-host: /
    # 连接超时
    connection-timeout: 3s
    # 消费者配置
    listener:
      simple:
        # 手动确认——生产环境标配
        acknowledge-mode: manual
        # 每次抓取 1 条消息（公平分发）
        prefetch: 1
        # 消费者数量
        concurrency: 2
        max-concurrency: 10
        # 重试（失败后重试 3 次，间隔 5s）
        retry:
          enabled: true
          initial-interval: 5000ms
          max-attempts: 3
          multiplier: 2
```

| 配置项 | 含义 | 默认值 |
|--------|------|:---:|
| `acknowledge-mode: manual` | 手动确认——消费者处理完显式 ACK | `auto`（不推荐） |
| `prefetch: 1` | 每次只分发 1 条消息给消费者——处理完 ACK 后才分下一条 | `250` |
| `concurrency` | 初始消费者线程数 | `1` |
| `max-concurrency` | 最大消费者线程数 | 无上限 |
| `retry.initial-interval` | 消息处理失败后的重试间隔 | `1000ms` |

> ⚠️ 新手提示：`prefetch: 1` 至关重要。RabbitMQ 默认把消息<strong>轮询分发</strong>给所有消费者——不管他们处理快慢。如果两个消费者处理速度差 10 倍，默认行为是各分一半消息，快的消费者闲着，慢的消费者堆积。`prefetch: 1` 开启<strong>公平分发</strong>：处理完一条才给下一条。

## 🏗️ 第四步：公共基础设施

### 4.1 配置类：声明 Exchange、Queue、Binding

前两篇中，每次都要在代码里手动 `channel.exchangeDeclare` 和 `channel.queueDeclare`。在 SpringBoot 中，这些操作变成 `@Bean` 声明——应用启动时自动创建。

下面搭一个<strong>电商订单消息</strong>的完整配置，同时覆盖 Direct、Fanout、Topic 三种 Exchange：

```java
@Configuration
public class RabbitMQConfig {

    // ========== Direct Exchange ==========
    @Bean
    public DirectExchange orderDirectExchange() {
        return new DirectExchange("order.direct", true, false);
    }

    @Bean
    public Queue orderCreateQueue() {
        return QueueBuilder.durable("queue.order.create").build();
    }

    @Bean
    public Binding orderCreateBinding() {
        return BindingBuilder
                .bind(orderCreateQueue())
                .to(orderDirectExchange())
                .with("order.created");
    }

    // ========== Fanout Exchange ==========
    @Bean
    public FanoutExchange orderFanoutExchange() {
        return new FanoutExchange("order.fanout", true, false);
    }

    @Bean
    public Queue orderSmsQueue() {
        return new Queue("queue.sms", true);
    }

    @Bean
    public Queue orderEmailQueue() {
        return new Queue("queue.email", true);
    }

    @Bean
    public Queue orderRiskQueue() {
        return new Queue("queue.risk", true);
    }

    @Bean
    public Binding smsBinding() {
        // Fanout 下 RoutingKey 被忽略
        return BindingBuilder.bind(orderSmsQueue()).to(orderFanoutExchange());
    }

    @Bean
    public Binding emailBinding() {
        return BindingBuilder.bind(orderEmailQueue()).to(orderFanoutExchange());
    }

    @Bean
    public Binding riskBinding() {
        return BindingBuilder.bind(orderRiskQueue()).to(orderFanoutExchange());
    }

    // ========== Topic Exchange ==========
    @Bean
    public TopicExchange eventTopicExchange() {
        return new TopicExchange("event.topic", true, false);
    }

    @Bean
    public Queue orderAllQueue() {
        return QueueBuilder.durable("queue.order.all").build();
    }

    @Bean
    public Binding orderAllBinding() {
        return BindingBuilder
                .bind(orderAllQueue())
                .to(eventTopicExchange())
                .with("order.#");
    }
}
```

`BindingBuilder` 链式调用的三个方法对应 AMQP 的 Binding 三要素：

```java
BindingBuilder
    .bind(队列)           // Queue
    .to(交换机)            // Exchange
    .with("order.#");     // BindingKey / RoutingKey
```

### 4.2 JSON 消息转换器

Spring AMQP 默认用 `SimpleMessageConverter`——它只能处理 `String`、`byte[]`、`Serializable`。发一个 Java 对象时，它会走 JDK 序列化，消息体变成二进制乱码。

换成 Jackson JSON 转换器：

```java
@Configuration
public class RabbitMQConfig {

    @Bean
    public Jackson2JsonMessageConverter messageConverter() {
        // 用 Jackson 将 Java 对象 ↔ JSON 互转
        return new Jackson2JsonMessageConverter();
    }

    @Bean
    public RabbitTemplate rabbitTemplate(
            ConnectionFactory factory,
            Jackson2JsonMessageConverter converter) {

        RabbitTemplate template = new RabbitTemplate(factory);
        template.setMessageConverter(converter);
        return template;
    }
}
```

配置后，发送一个 `OrderMessage` 对象时，RabbitTemplate 自动序列化为 JSON 字符串发给 RabbitMQ；消费者收到时，自动反序列化回 `OrderMessage` 对象。

## 第五步：分步实践

### 5.1 消息对象定义

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

### 5.2 RabbitTemplate —— 发送消息

`RabbitTemplate` 是 Spring 对 `channel.basicPublish` 的封装。一切发送操作都通过它：

```java
@Service
public class OrderMessageSender {

    @Autowired
    private RabbitTemplate rabbitTemplate;

    // ===== 发送到 Direct Exchange =====
    public void sendOrderCreated(OrderMessage msg) {
        rabbitTemplate.convertAndSend(
            "order.direct",       // exchange
            "order.created",      // routingKey
            msg                   // 消息对象——自动 JSON 序列化
        );
    }

    // ===== 发送到 Fanout Exchange（广播，RoutingKey 随意） =====
    public void broadcastOrderCreated(OrderMessage msg) {
        rabbitTemplate.convertAndSend("order.fanout", "", msg);
    }

    // ===== 发送到 Topic Exchange =====
    public void sendEvent(OrderMessage msg) {
        // RoutingKey 动态拼接：order.{action}
        String routingKey = "order." + msg.getAction();
        rabbitTemplate.convertAndSend("event.topic", routingKey, msg);
    }

    // ===== 发送带自定义 Headers 的消息 =====
    public void sendWithHeaders(OrderMessage msg) {
        rabbitTemplate.convertAndSend("order.direct", "order.created", msg,
            message -> {
                // 设置消息属性
                message.getMessageProperties().setHeader("source", "web");
                message.getMessageProperties().setHeader("version", "v2");
                message.getMessageProperties().setExpiration("10000"); // 10s TTL
                return message;
            });
    }

    // ===== 发送并等待确认（可靠性场景） =====
    public void sendWithConfirm(OrderMessage msg) {
        rabbitTemplate.setConfirmCallback((correlationData, ack, cause) -> {
            if (ack) {
                log.info("消息已到达 Broker: {}", correlationData.getId());
            } else {
                log.error("消息发送失败: {}", cause);
            }
        });
        rabbitTemplate.convertAndSend("order.direct", "order.created", msg);
    }
}
```

`convertAndSend` 的三个重载：

| 方法 | 参数 | 用途 |
|------|------|------|
| `convertAndSend(routingKey, msg)` | routingKey + 消息 | 发到默认 Exchange |
| `convertAndSend(exchange, routingKey, msg)` | exchange + routingKey + 消息 | 标准用法 |
| `convertAndSend(exchange, routingKey, msg, postProcessor)` | 同上 + 后处理 | 设置消息 Header、TTL 等属性 |

> ⚠️ 新手提示：`convertAndSend` 中的 "convert" 指的是<strong>自动调用 MessageConverter 把 Java 对象转成消息体</strong>。如果用 `send` 方法，需要自己构建 `org.springframework.amqp.core.Message` 对象，不推荐。

### 5.3 @RabbitListener —— 接收消息

`@RabbitListener` 注解标在方法上，Spring 自动创建消费者监听队列。替代了手动 `channel.basicConsume` + `DeliverCallback`。

```java
@Component
public class OrderMessageListener {

    private static final Logger log = LoggerFactory.getLogger(OrderMessageListener.class);

    // ===== Direct 队列：只收 order.created =====
    @RabbitListener(queues = "queue.order.create")
    public void handleOrderCreated(OrderMessage msg) {
        log.info("收到订单创建消息: orderId={}, product={}, amount={}",
                msg.getOrderId(), msg.getProductName(), msg.getAmount());
        // 实际业务：扣减库存、生成物流单、记录审计日志...
    }

    // ===== Fanout 队列：短信消费者 =====
    @RabbitListener(queues = "queue.sms")
    public void handleSms(OrderMessage msg) {
        log.info("发送下单短信: userId={}, orderId={}", msg.getUserId(), msg.getOrderId());
        // 调用短信 API
    }

    // ===== Fanout 队列：邮件消费者 =====
    @RabbitListener(queues = "queue.email")
    public void handleEmail(OrderMessage msg) {
        log.info("发送下单邮件: userId={}, orderId={}", msg.getUserId(), msg.getOrderId());
        // 调用邮件 API
    }

    // ===== Topic 队列：收所有 order.# 事件 =====
    @RabbitListener(queues = "queue.order.all")
    public void handleAllOrderEvents(OrderMessage msg) {
        log.info("订单事件: action={}, orderId={}", msg.getAction(), msg.getOrderId());
    }
}
```

### 5.4 @RabbitListener 支持的参数类型

Spring AMQP 可以自动将消息的不同部分注入方法参数：

```java
@RabbitListener(queues = "queue.order.create")
public void handle(
        // 1. 消息体——自动 JSON 反序列化
        OrderMessage msg,

        // 2. Channel——需要手动 ACK 时需要
        Channel channel,

        // 3. Message——原始 Spring AMQP 消息对象（含 Headers）
        Message message,

        // 4. deliveryTag——ACK 时用
        @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag
) {
    // ...
}
```

常用组合：

```java
// 只关心消息体——最常见的写法
@RabbitListener(queues = "queue.sms")
public void handle(OrderMessage msg) { ... }

// 需要手动 ACK——拿到 Channel + deliveryTag
@RabbitListener(queues = "queue.order.create")
public void handle(OrderMessage msg, Channel channel,
                   @Header(AmqpHeaders.DELIVERY_TAG) long tag) throws IOException {
    try {
        // 处理业务...
        channel.basicAck(tag, false);   // 手动确认
    } catch (Exception e) {
        channel.basicNack(tag, false, true);  // 重新入队
    }
}
```

### 5.5 手动 ACK 的正确姿势

`application.yml` 设了 `acknowledge-mode: manual` 后，<strong>消费者必须手动调用 ACK 或 NACK</strong>。如果不调，消息一直处于 Unacked 状态——消费者断开后会被重新分发。

```java
@RabbitListener(queues = "queue.order.create")
public void handleWithManualAck(
        OrderMessage msg,
        Channel channel,
        @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag) throws IOException {

    try {
        // 执行业务逻辑...
        processOrder(msg);

        // 成功 → 确认，消息从队列中删除
        // multiple=false: 只确认这一条（不是批量确认）
        channel.basicAck(deliveryTag, false);

    } catch (Exception e) {
        log.error("处理消息失败: orderId={}", msg.getOrderId(), e);

        // 失败 → 两种选择：
        // 1. basicNack(deliveryTag, false, true) → 重新入队（重试）
        // 2. basicNack(deliveryTag, false, false) → 不重新入队（丢弃或进死信）
        channel.basicNack(deliveryTag, false, true);
    }
}
```

| 方法 | 效果 | 场景 |
|------|------|------|
| `basicAck(tag, false)` | 确认成功，消息从队列删除 | 正常处理完 |
| `basicNack(tag, false, true)` | 拒绝，消息重新入队 | 临时错误，期望重试 |
| `basicNack(tag, false, false)` | 拒绝，不重新入队 | 无法处理的坏消息（配合死信队列） |
| `basicReject(tag, true)` | 同上，但只能拒绝单条 | 较少用 |

> ⚠️ 新手提示：`basicNack(tag, false, true)` 会让消息<strong>立刻回到队头重新投递</strong>。如果代码逻辑没变（比如空指针异常），重试一万次也是失败，就形成了死循环。生产环境请配合<strong>死信队列</strong>——重试 N 次失败后自动转入死信队列，下一篇展开。

### 5.6 完整 Controller：发消息 + 验证

```java
@RestController
@RequestMapping("/api/order")
public class OrderController {

    @Autowired
    private OrderMessageSender sender;

    @Autowired
    private RabbitTemplate rabbitTemplate;

    // 创建订单 → 发 Direct 消息
    @PostMapping("/create")
    public String createOrder(@RequestBody OrderMessage msg) {
        msg.setAction("created");
        msg.setCreateTime(LocalDateTime.now());
        sender.sendOrderCreated(msg);
        return "订单创建消息已发送: " + msg.getOrderId();
    }

    // 广播通知（Fanout）
    @PostMapping("/broadcast")
    public String broadcast(@RequestBody OrderMessage msg) {
        sender.broadcastOrderCreated(msg);
        return "广播消息已发送";
    }

    // 按 action 动态路由（Topic）
    @PostMapping("/event")
    public String event(@RequestBody OrderMessage msg) {
        sender.sendEvent(msg);
        return "事件已发送: order." + msg.getAction();
    }

    // 查看队列状态
    @GetMapping("/queue/status")
    public Map<String, Integer> queueStatus() {
        Map<String, Integer> result = new HashMap<>();
        String[] queues = {"queue.order.create", "queue.sms",
                "queue.email", "queue.risk", "queue.order.all"};
        for (String q : queues) {
            Integer count = (Integer) rabbitTemplate.execute(channel ->
                    channel.queueDeclarePassive(q).getMessageCount());
            result.put(q, count);
        }
        return result;
    }
}
```

测试流程：

```bash
# 1. 启动应用
mvn spring-boot:run

# 2. 发一个订单创建请求
curl -X POST http://localhost:8080/api/order/create \
  -H "Content-Type: application/json" \
  -d '{
    "orderId": 10001,
    "userId": 2001,
    "productName": "iPhone 15",
    "amount": 6999.00,
    "action": "created"
  }'

# 3. 观察控制台输出——三个消费者各收到一条消息
# [SMS消费者] 发送下单短信...
# [邮件消费者] 发送下单邮件...
# [风控消费者] 收到订单创建消息...
# [全事件消费者] 订单事件: action=created, orderId=10001

# 4. 查看队列积压
curl http://localhost:8080/api/order/queue/status
# {"queue.order.create":0, "queue.sms":0, ...}
```

## 第六步：FAQ（写过的都懂）

| 问题 | 原因 | 解决 |
|------|------|------|
| 消息发出去但 `@RabbitListener` 没反应 | Exchange 和队列的 Binding 没配，或 RoutingKey 不匹配 | 检查管理界面 Exchange → Bindings，确认队列已绑定且 RoutingKey 正确 |
| `org.springframework.amqp.AmqpException: No method found for class` | MessageConverter 不认消息类型——Body 不是 JSON | 确认 `Jackson2JsonMessageConverter` 已配置；发送端和接收端使用相同的消息类 |
| 消费者拿到消息后 JSON 反序列化失败 | 发送端和接收端的类路径不一致 | 消息用 `_class_` Header 记录源类型——默认情况下两边包路径必须一致 |
| "Channel shutdown: channel error" | 可能多次声明相同名称的 Exchange/Queue 但参数不同 | 检查 `@Bean` 定义——同一个队列名只能有一种参数组合 |
| `acknowledge-mode: manual` 但没调 `basicAck`，消息一直 Unacked | 手动模式下必须显式确认 | 加上 `channel.basicAck` 调用 |
| `convertAndSend` 不抛异常但消息也没到队列 | 消息被路由但 RoutingKey 没匹配到任何 Binding（Topic/Direct） | 发消息前确保 Binding 已经声明好 |

## 🎯 总结

本文把前两篇中纯 Java 客户端的手动操作全部迁移到了 Spring AMQP：

1. <strong>配置声明化</strong>：Exchange/Queue/Binding 用 `@Bean` 声明，应用启动时自动创建。`BindingBuilder.bind(queue).to(exchange).with(routingKey)` 链式调用。

2. <strong>发送一行代码</strong>：`rabbitTemplate.convertAndSend(exchange, routingKey, msg)`，自动 JSON 序列化。发 Fanout 时 RoutingKey 填 `""`。

3. <strong>消费一个注解</strong>：`@RabbitListener(queues = "queue.name")` 标注方法，Spring 自动创建消费者。方法参数自动注入消息体、Channel、deliveryTag。

4. <strong>手动 ACK 两个方法</strong>：`basicAck` 确认成功 + `basicNack` 拒绝（可重新入队）。配合 `prefetch: 1` 实现公平分发。

5. <strong>Jackson2Json 自动转</strong>：配置一个 Bean，Java 对象 ↔ JSON 无需手动序列化。

下一步要解决消息<strong>不丢、不重、不阻塞</strong>的问题——消息可靠性保障、死信队列、重试机制。

> 📖 <strong>下一步阅读</strong>：消息发出去了，怎么保证不丢？消费者挂了消息去哪了？继续阅读 [<strong>消息可靠性保障</strong>]({{< relref "MessageReliability.md" >}})，一篇讲透 ACK、持久化、Publisher Confirm、死信队列和重试机制。
