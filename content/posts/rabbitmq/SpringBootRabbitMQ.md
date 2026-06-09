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
description: "一篇掌握 SpringBoot RabbitMQ 全部常用操作：RabbitTemplate 发送、@RabbitListener 消费、Jackson2Json 消息转换、声明式拓扑配置、手动 ACK，以及真实电商项目的常量管理、MqHelper 双 Broker 抽象、四条业务线 MQ 模式与 RabbitMQ vs RocketMQ 分工。"
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

---

# Part 1：概念与前置

## 1.1 本文目标

前两篇用 RabbitMQ 原生 Java Client 写了所有代码——`channel.basicPublish`、`channel.basicConsume`、手动 `basicAck`。理解底层是正确的，但真正进项目时，Spring AMQP 帮我们做了 90% 的重复工作。

读完这篇会掌握：

- 用 <strong>RabbitTemplate</strong> 一行代码发消息（替代 `channel.basicPublish` 那一大堆）
- 用 <strong>@RabbitListener</strong> 注解收消息（替代手动 `basicConsume` + `DeliverCallback`）
- 用 <strong>Jackson2JsonMessageConverter</strong> 自动序列化/反序列化 Java 对象
- 用 <strong>@Bean + 声明式配置</strong> 管理 Exchange/Queue/Binding（替代每次启动时 `channel.exchangeDeclare`）
- 三种交换机在 Spring 中的完整示例代码（Direct / Fanout / Topic）
- <strong>手动 ACK</strong> 的配置和坑

## 1.2 前置条件

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

---

# Part 2：教程版实现

> ⚠️ <strong>阅读提示</strong>：Part 2 是纯教程代码，目的是让你跑通 Spring AMQP 的核心 API。每一段代码都可以直接复制到 SpringBoot 项目里运行。<strong>真实生产代码在 Part 3</strong>，两者分开是为了避免读者在学基础 API 时被生产复杂度干扰。

## 2.1 依赖

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

## 2.2 配置文件

```yaml
spring:
  rabbitmq:
    host: localhost
    port: 5672
    username: admin
    password: admin123
    virtual-host: /
    connection-timeout: 3s
    listener:
      simple:
        acknowledge-mode: manual
        prefetch: 1
        concurrency: 2
        max-concurrency: 10
        retry:
          enabled: true
          initial-interval: 5000ms
          max-attempts: 3
          multiplier: 2
```

## 2.3 配置类：声明 Exchange、Queue、Binding

前两篇中，每次都要在代码里手动 `channel.exchangeDeclare` 和 `channel.queueDeclare`。在 SpringBoot 中，这些操作变成 `@Bean` 声明——应用启动时自动创建。

```java
@Configuration
public class RabbitMQConfig {

    // ========== Direct Exchange ==========
    @Bean
    public DirectExchange orderDirectExchange() {
        return new DirectExchange("order.direct");
    }

    @Bean
    public Queue orderCreateQueue() {
        return QueueBuilder.durable("queue.order.create").build();
    }

    @Bean
    public Binding orderCreateBinding() {
        return BindingBuilder.bind(orderCreateQueue())
            .to(orderDirectExchange())
            .with("order.created");
    }

    // ========== Fanout Exchange（广播） ==========
    @Bean
    public FanoutExchange orderFanoutExchange() {
        return new FanoutExchange("order.fanout");
    }

    @Bean
    public Queue smsQueue() {
        return QueueBuilder.durable("queue.sms").build();
    }

    @Bean
    public Queue emailQueue() {
        return QueueBuilder.durable("queue.email").build();
    }

    @Bean
    public Binding smsBinding() {
        return BindingBuilder.bind(smsQueue()).to(orderFanoutExchange());
    }

    @Bean
    public Binding emailBinding() {
        return BindingBuilder.bind(emailQueue()).to(orderFanoutExchange());
    }

    // ========== Topic Exchange ==========
    @Bean
    public TopicExchange eventTopicExchange() {
        return new TopicExchange("event.topic");
    }

    @Bean
    public Queue orderAllQueue() {
        return QueueBuilder.durable("queue.order.all").build();
    }

    @Bean
    public Binding orderAllBinding() {
        return BindingBuilder.bind(orderAllQueue())
            .to(eventTopicExchange())
            .with("order.#");
    }
}
```

## 2.4 JSON 消息转换器

Spring AMQP 默认用 `SimpleMessageConverter`——它只能处理 `String`、`byte[]`、`Serializable`。发一个 Java 对象时，它会走 JDK 序列化，消息体变成二进制乱码。

换成 Jackson JSON 转换器：

```java
@Configuration
public class RabbitMQConfig {

    @Bean
    public Jackson2JsonMessageConverter messageConverter() {
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

## 2.5 消息对象定义

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

## 2.6 RabbitTemplate —— 发送消息

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
        String routingKey = "order." + msg.getAction();
        rabbitTemplate.convertAndSend("event.topic", routingKey, msg);
    }
}
```

## 2.7 @RabbitListener —— 接收消息

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
    }

    // ===== Fanout 队列：短信消费者 =====
    @RabbitListener(queues = "queue.sms")
    public void handleSms(OrderMessage msg) {
        log.info("发送下单短信: userId={}, orderId={}", msg.getUserId(), msg.getOrderId());
    }

    // ===== Fanout 队列：邮件消费者 =====
    @RabbitListener(queues = "queue.email")
    public void handleEmail(OrderMessage msg) {
        log.info("发送下单邮件: userId={}, orderId={}", msg.getUserId(), msg.getOrderId());
    }

    // ===== Topic 队列：收所有 order.# 事件 =====
    @RabbitListener(queues = "queue.order.all")
    public void handleAllOrderEvents(OrderMessage msg) {
        log.info("订单事件: action={}, orderId={}", msg.getAction(), msg.getOrderId());
    }
}
```

## 2.8 @RabbitListener 支持的参数类型

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
        channel.basicAck(tag, false);
    } catch (Exception e) {
        channel.basicNack(tag, false, true);
    }
}
```

## 2.9 手动 ACK 的正确姿势

`application.yml` 设了 `acknowledge-mode: manual` 后，<strong>消费者必须手动调用 ACK 或 NACK</strong>。如果不调，消息一直处于 Unacked 状态——消费者断开后会被重新分发。

```java
@RabbitListener(queues = "queue.order.create")
public void handleWithManualAck(
        OrderMessage msg,
        Channel channel,
        @Header(AmqpHeaders.DELIVERY_TAG) long deliveryTag) throws IOException {

    try {
        processOrder(msg);
        // 成功 → 确认，消息从队列中删除
        channel.basicAck(deliveryTag, false);
    } catch (Exception e) {
        log.error("处理消息失败: orderId={}", msg.getOrderId(), e);
        // 失败 → 重新入队（重试）
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

> ⚠️ 新手提示：`basicNack(tag, false, true)` 会让消息<strong>立刻回到队头重新投递</strong>。如果代码逻辑没变（比如空指针异常），重试一万次也是失败，就形成了死循环。生产环境请配合<strong>死信队列</strong>——重试 N 次失败后自动转入死信队列。

## 2.10 完整 Controller：发消息 + 验证

```java
@RestController
@RequestMapping("/api/order")
public class OrderController {

    @Autowired
    private OrderMessageSender sender;

    @Autowired
    private RabbitTemplate rabbitTemplate;

    @PostMapping("/create")
    public String createOrder(@RequestBody OrderMessage msg) {
        msg.setAction("created");
        msg.setCreateTime(LocalDateTime.now());
        sender.sendOrderCreated(msg);
        return "订单创建消息已发送: " + msg.getOrderId();
    }

    @PostMapping("/broadcast")
    public String broadcast(@RequestBody OrderMessage msg) {
        sender.broadcastOrderCreated(msg);
        return "广播消息已发送";
    }

    @PostMapping("/event")
    public String event(@RequestBody OrderMessage msg) {
        sender.sendEvent(msg);
        return "事件已发送: order." + msg.getAction();
    }

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

# 4. 查看队列积压
curl http://localhost:8080/api/order/queue/status
```

---

# Part 3：生产版升级

> 📌 <strong>以下代码全部来自 mall 电商项目真实源码</strong>（`mall-service` + `mall-job` 模块），与 Part 2 的教程版形成对照。每个升级点都会解释<strong>为什么</strong>生产环境要这样做。

## 3.1 配置管理：dev 直连 vs prod 环境变量

`application-dev.yml`：

```yaml
spring:
  rabbitmq:
    host: 117.72.88.11
    port: 5672
    username: admin
    password: susan123
```

`application-prod.yml`：

```yaml
spring:
  rabbitmq:
    host: ${RABBITMQ_HOST}
    port: ${RABBITMQ_PORT:5672}
    username: ${RABBITMQ_USER}
    password: ${RABBITMQ_PASSWORD}
```

<strong>两个设计决策</strong>：

<strong>① 为什么生产配置里只有 host/port/username/password 四行？</strong>

mall 项目的 RabbitMQ 用的全是 Spring Boot 的默认值——`virtual-host: /`（默认）、`acknowledge-mode: auto`（默认）、`prefetch: 250`（默认）。只配了连接必须的四项，其他全用默认。好处是：<strong>不出事的默认值就是对的默认值</strong>。只有当业务确实需要手动 ACK 或调整 prefetch 时，才加配置。

<strong>② 为什么 dev 写死 IP 和密码？</strong>

mall 项目的 `application-dev.yml` 直接写死了开发服务器的地址——不暴露到公网，只有内网能访问。但 `application-prod.yml` 全走环境变量——生产密码绝对不能出现在 Git 仓库里。

另外 mall-job 模块的 `application.yml` 还有一个特殊配置：

```yaml
spring:
  amqp:
    deserialization:
      trust:
        all: true    # 信任所有类型的消息反序列化
```

这个配置让消费者可以反序列化<strong>任意 Java 类型</strong>的消息。安全上不建议在生产环境开——正确做法是用 `trusted-packages` 白名单指定允许的包路径。

## 3.2 RabbitConfig：四条业务线拓扑声明

下面是 mall 电商项目真实的 `RabbitConfig`——<strong>四条业务线、四套 Exchange/Queue/Binding、一套常量命名规范</strong>：

```java
@Slf4j
@Configuration
public class RabbitConfig {

    // ==========================================
    // ① 常量：所有 Exchange / Queue / RoutingKey 名称集中管理
    // ==========================================
    public static final String EXCEL_EXPORT_EXCHANGE = "excel_export_exchange";
    public static final String EXCEL_EXPORT_QUEUE = "excel_export_queue";
    public static final String EXCEL_EXPORT_QUEUE_ROUTING_KEY_PREFIX = "excel_export.";
    public static final String EXCEL_EXPORT_QUEUE_ROUTING_KEY =
        EXCEL_EXPORT_QUEUE_ROUTING_KEY_PREFIX + "#";

    public static final String OVER_TIME_CANCEL_TRADE_EXCHANGE = "over_time_cancel_trade_exchange";
    public static final String OVER_TIME_CANCEL_TRADE_QUEUE = "over_time_cancel_trade_queue";
    public static final String OVER_TIME_CANCEL_QUEUE_ROUTING_KEY_PREFIX = "over_time_cancel_trade.";
    public static final String OVER_TIME_CANCEL_QUEUE_ROUTING_KEY =
        OVER_TIME_CANCEL_QUEUE_ROUTING_KEY_PREFIX + "#";

    public static final String TRADE_STATUS_CHANGE_EXCHANGE = "trade_status_change_exchange";
    public static final String TRADE_STATUS_CHANGE_QUEUE = "trade_status_change_queue";
    public static final String TRADE_STATUS_CHANGE_ROUTING_KEY_PREFIX = "trade_status_change.";
    public static final String TRADE_STATUS_CHANGE_ROUTING_KEY =
        TRADE_STATUS_CHANGE_ROUTING_KEY_PREFIX + "#";

    public static final String DYNAMIC_JOB_EXCHANGE = "dynamic_job_exchange";
    public static final String DYNAMIC_JOB_QUEUE = "dynamic_job_queue";
    public static final String DYNAMIC_JOB_ROUTING_KEY_PREFIX = "dynamic_job.";
    public static final String DYNAMIC_JOB_ROUTING_KEY =
        DYNAMIC_JOB_ROUTING_KEY_PREFIX + "#";

    public static final Integer DELAY_TIME = 10000;

    // ==========================================
    // ② RabbitTemplate：配置 JSON 序列化 + 连接工厂
    // ==========================================
    @Autowired
    private CachingConnectionFactory cachingConnectionFactory;

    @Bean
    public RabbitTemplate rabbitTemplate() {
        RabbitTemplate rabbitTemplate = new RabbitTemplate(cachingConnectionFactory);
        rabbitTemplate.setMessageConverter(new Jackson2JsonMessageConverter());
        return rabbitTemplate;
    }

    @Bean
    public MessageConverter jsonToMapMessageConverter() {
        return new Jackson2JsonMessageConverter();
    }

    // ==========================================
    // ③ 四条业务线的拓扑声明
    // ==========================================

    // --- 业务 1：Excel 导出通知 ---
    @Bean("excelExportExchange")
    public Exchange excelExportExchange() {
        return new TopicExchange(EXCEL_EXPORT_EXCHANGE, true, false);
    }

    @Bean("excelExportQueue")
    public Queue excelExportQueue() {
        Map<String, Object> args = new HashMap<>(1);
        args.put("x-message-ttl", DELAY_TIME);
        return QueueBuilder.durable(EXCEL_EXPORT_QUEUE).withArguments(args).build();
    }

    @Bean("excelExportBinding")
    public Binding excelExportBinding(
            @Qualifier("excelExportQueue") Queue queue,
            @Qualifier("excelExportExchange") Exchange exchange) {
        return BindingBuilder.bind(queue).to(exchange)
            .with(EXCEL_EXPORT_QUEUE_ROUTING_KEY).noargs();
    }

    // --- 业务 2：超时订单取消 ---
    @Bean("overtimeCancelTradeExchange")
    public Exchange overtimeCancelTradeExchange() {
        return new TopicExchange(OVER_TIME_CANCEL_TRADE_EXCHANGE, true, false);
    }

    @Bean("overtimeCancelTradeQueue")
    public Queue overtimeCancelTradeQueue() {
        Map<String, Object> args = new HashMap<>(1);
        args.put("x-message-ttl", DELAY_TIME);
        return QueueBuilder.durable(OVER_TIME_CANCEL_TRADE_QUEUE).withArguments(args).build();
    }

    @Bean("overtimeCancelTradeBinding")
    public Binding overtimeCancelTradeBinding(
            @Qualifier("overtimeCancelTradeQueue") Queue queue,
            @Qualifier("overtimeCancelTradeExchange") Exchange exchange) {
        return BindingBuilder.bind(queue).to(exchange)
            .with(OVER_TIME_CANCEL_QUEUE_ROUTING_KEY).noargs();
    }

    // --- 业务 3：订单状态变更 ---
    @Bean("tradeStatusChangeExchange")
    public Exchange tradeStatusChangeExchange() {
        return new TopicExchange(TRADE_STATUS_CHANGE_EXCHANGE, true, false);
    }

    @Bean("tradeStatusChangeQueue")
    public Queue tradeStatusChangeQueue() {
        Map<String, Object> args = new HashMap<>(1);
        args.put("x-message-ttl", DELAY_TIME);
        return QueueBuilder.durable(TRADE_STATUS_CHANGE_QUEUE).withArguments(args).build();
    }

    @Bean("tradeStatusChangeBinding")
    public Binding tradeStatusChangeBinding(
            @Qualifier("tradeStatusChangeQueue") Queue queue,
            @Qualifier("tradeStatusChangeExchange") Exchange exchange) {
        return BindingBuilder.bind(queue).to(exchange)
            .with(TRADE_STATUS_CHANGE_ROUTING_KEY).noargs();
    }

    // --- 业务 4：动态定时任务同步 ---
    @Bean("dynamicJobExchange")
    public Exchange dynamicJobExchange() {
        return new TopicExchange(DYNAMIC_JOB_EXCHANGE, true, false);
    }

    @Bean("dynamicJobQueue")
    public Queue dynamicJobQueue() {
        Map<String, Object> args = new HashMap<>(1);
        args.put("x-message-ttl", DELAY_TIME);
        return QueueBuilder.durable(DYNAMIC_JOB_QUEUE).withArguments(args).build();
    }

    @Bean("dynamicJobBinding")
    public Binding dynamicJobBinding(
            @Qualifier("dynamicJobQueue") Queue queue,
            @Qualifier("dynamicJobExchange") Exchange exchange) {
        return BindingBuilder.bind(queue).to(exchange)
            .with(DYNAMIC_JOB_ROUTING_KEY).noargs();
    }
}
```

<strong>五个与教学用配置不同的设计决策</strong>：

<strong>① 为什么所有交换机都是 `TopicExchange`，没有 Direct 和 Fanout？</strong>

`TopicExchange` 是 Direct 和 Fanout 的超集。用 `routing.key` 匹配就是 Direct 行为，用 `#` 匹配所有就是 Fanout 行为。mall 项目统一用 Topic——<strong>用一种交换机覆盖所有路由需求，减少认知负担</strong>。以后某条业务线需要从"只监听一个 key"升级到"监听多个 key"时，只需改 RoutingKey，不用重建交换机。

<strong>② 为什么 Exchange/Queue 名称用 `snake_case`？</strong>

RabbitMQ 内部用字符串匹配 RoutingKey——`excel_export.#`、`over_time_cancel_trade.#`。snake_case 在日志和管理界面中比 camelCase 更易读。而且 `QueueBuilder.durable()` 创建的队列名会直接出现在 RabbitMQ Management 界面——`excel_export_queue` 一眼就知道是"Excel 导出"的队列。

<strong>③ 为什么所有队列统一设 `x-message-ttl=10000`（10 秒）？</strong>

mall 项目的消息都是<strong>实时通知</strong>类（导出完成通知、订单取消提醒、任务状态变更）——消息的意义只在"当下"有效。如果消费者挂了 10 秒还没处理，这条消息对用户来说已经没用了（用户已经刷新页面或重新操作了）。10 秒 TTL 防止<strong>消费者离线期间队列无限堆积</strong>。

<strong>④ 为什么常量定义在 `RabbitConfig` 类里而不是单独的常量类？</strong>

这四条业务线的 Exchange/Queue/RoutingKey 是配置类的"内部实现细节"——只有 `RabbitConfig` 的 `@Bean` 方法和少数几个 Service 在用。放在同一个类里便于<strong>新加一条业务线时复制粘贴改名字</strong>——四个常量块结构完全一致，肉眼对比就能发现差异。

<strong>⑤ 为什么用 `@Qualifier` 按名字注入 Bean？</strong>

同一个类型有 4 个 Exchange Bean、4 个 Queue Bean——Spring 按类型注入时会找不到唯一的。`@Qualifier("excelExportExchange")` 精确指定要注入哪一个。

## 3.3 MqHelper：双 Broker 抽象层

Part 2 演示了直接注入 `RabbitTemplate` 发消息。mall 项目更进一步——封装了一个 `MqHelper`，<strong>同时管理 RabbitMQ 和 RocketMQ 两套消息队列</strong>，对外提供统一的 `send()` 接口：

```java
@Slf4j
@Component
public class MqHelper {

    @Autowired
    private RabbitTemplate rabbitTemplate;
    @Autowired
    private RocketMQTemplate rocketMQTemplate;

    // ===== RocketMQ：普通异步消息 =====
    public void send(String topic, Object message) {
        try {
            rocketMQTemplate.asyncSend(topic, message, new SendCallback() {
                @Override
                public void onSuccess(SendResult sendResult) {
                    log.info("消息发送成功, topic:{},message:{}", topic, message);
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

    // ===== RocketMQ：延迟消息（delayLevel 为延迟等级） =====
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
                        log.info("延迟消息发送成功, topic:{},message:{}", topic, data);
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

    // ===== RabbitMQ：原始 Message 发送 =====
    public void send(String routingKey, Message message) {
        try {
            rabbitTemplate.send(routingKey, message);
        } catch (Exception e) {
            log.error("发送MQ消息失败, routingKey={}", routingKey, e);
            throw new BusinessException("消息发送失败，请重试");
        }
    }

    // ===== RabbitMQ：标准路由消息（convertAndSend） =====
    public void send(String exchange, String routingKey, Object data) {
        try {
            rabbitTemplate.convertAndSend(exchange, routingKey, data);
            log.info("消息发送成功, exchange:{},routingKey:{},message:{}",
                exchange, routingKey, data);
        } catch (Exception e) {
            log.error("消息发送失败, exchange={}, routingKey={}", exchange, routingKey, e);
            throw new BusinessException("消息发送失败，请重试");
        }
    }

    // ===== RabbitMQ：延迟消息（毫秒级延迟） =====
    public void sendDelayMessage(String exchange, String routingKey,
                                  Object data, int delayTime) {
        try {
            rabbitTemplate.convertAndSend(exchange, routingKey, data, message -> {
                message.getMessageProperties().setDelay(delayTime);
                return message;
            });
            log.info("延迟消息发送成功, exchange:{},routingKey:{},delay:{}ms",
                exchange, routingKey, delayTime);
        } catch (Exception e) {
            log.error("延迟消息发送失败, exchange={}, routingKey={}", exchange, routingKey, e);
            throw new BusinessException("消息发送失败，请重试");
        }
    }
}
```

<strong>四个设计决策</strong>：

<strong>① 为什么封装 MqHelper 而不是直接注入 RabbitTemplate？</strong>

两个好处：一是<strong>统一异常处理</strong>——所有 `send()` 方法 catch 异常后抛 `BusinessException`，调用方不需要每个发送点都 try-catch。二是<strong>统一日志</strong>——每条消息的发送成功/失败都会打印 topic/exchange/routingKey/message，排查问题时日志链路完整。

<strong>② 为什么同时引入 RabbitMQ 和 RocketMQ？</strong>

mall 项目早期用的是 RabbitMQ，后来部分高并发场景（超时订单取消、动态任务同步）迁移到了 RocketMQ——因为 RocketMQ 的<strong>延迟消息等级</strong>（`delayLevel`）比 RabbitMQ 的延迟插件更稳定、堆积能力更强。`MqHelper` 屏蔽了这个差异——调用方只调 `mqHelper.send(...)`，不关心底下是 RabbitMQ 还是 RocketMQ。换 MQ 中间件时<strong>只改 MqHelper 内部，不改业务代码</strong>。

<strong>③ 为什么 RocketMQ 用 `asyncSend` + `SendCallback` 而不是同步 `syncSend`？</strong>

消息发送是<strong>非核心路径</strong>——订单创建成功是核心，发一条"可能需要取消订单"的延时消息是辅助。`asyncSend` 不阻塞主线程，失败了打日志即可，不影响订单创建的响应时间。

<strong>④ 为什么 RabbitMQ 的延迟消息走 `setDelay()` 而不是 `x-message-ttl`？</strong>

`setDelay()` 是 RabbitMQ 延迟消息插件（`rabbitmq-delayed-message-exchange`）的 API——消息到达交换机后<strong>先延迟再投递</strong>，队列里看不到这条消息。而 `x-message-ttl` 是队列级别的过期——消息先进队列，过期后变成死信再转发。<strong>延迟插件是"投递层面的延迟"，TTL 是"存储层面的过期"</strong>，前者更干净。

## 3.4 消息体：直接用领域实体，不做 DTO 转换

Part 2 定义了一个专用的 `OrderMessage` DTO。mall 项目里消息体<strong>直接用领域实体</strong>——不额外定义 Message 类，省去一层 Entity→Message 的转换：

| 领域实体 | 对应业务 | 包含字段 |
|------|------|------|
| `TradeEntity` | 超时订单取消 | `id`, `userId`, `totalPrice`, `status`, `createTime`, `payTime`... |
| `CommonNotifyEntity` | Excel 导出通知 | `userId`, `title`, `content`, `notifyType`, `isRead` |
| `CommonJobEntity` | 动态任务同步 | `jobId`, `jobName`, `cronExpression`, `beanName`, `operateType`, `params` |

<strong>为什么直接用领域实体而不是定义 Message DTO？</strong> 消费者收到消息后要执行业务操作——取消订单需要 `TradeEntity` 的所有字段、同步任务需要 `CommonJobEntity` 的所有字段。如果定义 `OrderCancelMessage` DTO，字段和 `TradeEntity` 几乎一模一样，纯粹是重复代码。mall 项目的做法是：<strong>发送端序列化领域实体 → 消息体是 JSON → 消费端反序列化回同一个领域实体</strong>。前提是发送端和消费端在同一个代码仓库（共享同一个 Entity 类）——微服务项目不要这么做。

## 3.5 四条业务线的生产者代码

4 条业务线在生产环境实际走的是 RocketMQ（RabbitMQ 基础设施已就绪，作为备选方案）：

```java
// === 业务 1：超时订单取消（延时消息，30 分钟后检查并取消未支付订单） ===
// TradeSaveService.sendOvertimeCancelTradeMessage()
mqHelper.send(overtimeCancelTradeTopic, tradeEntity, delayLevel);
// delayLevel=16 → RocketMQ 的 30 分钟延迟等级

// === 业务 2：Excel 导出完成通知（用户提交导出后，后台生成文件完成时推送） ===
// ExcelExportTask.doExportExcel()
mqHelper.send(excelExportTopic, commonNotifyEntity);

// === 业务 3：动态定时任务同步（多节点集群中同步 Quartz 任务状态） ===
// CommonJobService.sendDynamicJobMessage()
mqHelper.send(commonJobTopic, commonJobEntity);

// === 业务 4：订单创建后发送普通消息 ===
// TradeSubmitService.handleOverTimeCancelTrade()
mqHelper.send(topic, tradeEntity);
```

对应到 RabbitMQ，如果迁移过来，发送代码就是：

```java
// 超时订单取消 → RabbitMQ（用延迟插件替代 RocketMQ delayLevel）
mqHelper.sendDelayMessage(
    RabbitConfig.OVER_TIME_CANCEL_TRADE_EXCHANGE,
    "over_time_cancel_trade.create",
    tradeEntity,
    30 * 60 * 1000   // 30 分钟 = 1,800,000 ms
);

// Excel 导出通知 → RabbitMQ
mqHelper.send(
    RabbitConfig.EXCEL_EXPORT_EXCHANGE,
    "excel_export.done",
    commonNotifyEntity
);

// 订单状态变更 → RabbitMQ
mqHelper.send(
    RabbitConfig.TRADE_STATUS_CHANGE_EXCHANGE,
    "trade_status_change.paid",
    tradeEntity
);
```

注意这里引用常量 `RabbitConfig.OVER_TIME_CANCEL_TRADE_EXCHANGE`——不是写死字符串。3.2 节定义的 `public static final` 常量在这里体现价值：<strong>编译期就能发现拼写错误，IDE 重构时自动更新所有引用</strong>。

## 3.6 BusinessConsumers：三条业务线的 RabbitMQ 消费者

mall 项目当前 4 条业务线的消费者跑在 RocketMQ 上，但对应的 RabbitMQ 拓扑已在 3.2 声明好。迁移到 RabbitMQ 后，消费者长这样：

```java
@Component
public class BusinessConsumers {

    // === 超时订单取消 —— 从 over_time_cancel_trade_queue 消费 ===
    @RabbitListener(queues = RabbitConfig.OVER_TIME_CANCEL_TRADE_QUEUE)
    public void handleOvertimeCancelTrade(TradeEntity tradeEntity,
                                           Channel channel,
                                           @Header(AmqpHeaders.DELIVERY_TAG) long tag)
            throws IOException {
        try {
            tradeService.cancelOvertimeTrade(tradeEntity);
            channel.basicAck(tag, false);
        } catch (Exception e) {
            log.error("超时取消订单失败: tradeId={}", tradeEntity.getId(), e);
            channel.basicNack(tag, false, true);
        }
    }

    // === Excel 导出通知 —— 从 excel_export_queue 消费 ===
    @RabbitListener(queues = RabbitConfig.EXCEL_EXPORT_QUEUE)
    public void handleExcelExportNotify(CommonNotifyEntity notifyEntity,
                                         Channel channel,
                                         @Header(AmqpHeaders.DELIVERY_TAG) long tag)
            throws IOException {
        try {
            webSocketService.pushNotification(notifyEntity);
            channel.basicAck(tag, false);
        } catch (Exception e) {
            log.error("导出通知推送失败: userId={}", notifyEntity.getUserId(), e);
            // 通知失败不重试——用户刷新页面就能看到导出记录
            channel.basicNack(tag, false, false);
        }
    }

    // === 动态任务同步 —— 从 dynamic_job_queue 消费 ===
    @RabbitListener(queues = RabbitConfig.DYNAMIC_JOB_QUEUE)
    public void handleDynamicJobSync(CommonJobEntity jobEntity,
                                      Channel channel,
                                      @Header(AmqpHeaders.DELIVERY_TAG) long tag)
            throws IOException {
        try {
            switch (jobEntity.getOperateType()) {
                case NEW:    quartzManage.addJob(jobEntity);    break;
                case DELETE: quartzManage.removeJob(jobEntity); break;
                case PAUSE:  quartzManage.pauseJob(jobEntity);  break;
                case RESUME: quartzManage.resumeJob(jobEntity); break;
                case RUN_NOW: quartzManage.runNow(jobEntity);   break;
            }
            channel.basicAck(tag, false);
        } catch (Exception e) {
            log.error("动态任务同步失败: jobId={}", jobEntity.getJobId(), e);
            channel.basicNack(tag, false, true);
        }
    }
}
```

注意三个点：① `queues = RabbitConfig.xxx_QUEUE` 引用常量而不是写死字符串——队列改名只需改一处。② Excel 导出通知失败用 `basicNack(tag, false, false)`（不重试）——因为通知是 UX 体验，不是数据正确性问题。③ `switch (operateType)` 分发不同操作——一条队列承载 NEW/UPDATE/DELETE/PAUSE 等多种操作类型，靠消息体内的枚举字段区分。

## 3.7 WebSocketServer：消息推送基础设施

`BusinessConsumers` 中的 Excel 导出消费者需要把通知推送到用户浏览器。mall 项目使用 JSR 356 WebSocket 实现：

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
            // 广播：向所有在线用户推送
            Iterator<Long> iterator = webSocketMap.keySet().iterator();
            while (iterator.hasNext()) {
                Long userId = iterator.next();
                WebSocketServer item = webSocketMap.get(userId);
                item.sendMessage(commonNotifyEntity.getContent());
            }
        } else if (webSocketMap.containsKey(commonNotifyEntity.getToUserId())) {
            // 定向推送
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

<strong>关键设计</strong>：`sendMessage(CommonNotifyEntity)` 是静态方法——消费者在任意位置都可以直接调用 `WebSocketServer.sendMessage(entity)` 推送消息，不需要注入 Bean。`ConcurrentHashMap<Long, WebSocketServer>` 维护了 userId → WebSocket 连接的映射，支持定向推送和全量广播。

## 3.8 RabbitMQ vs RocketMQ 在项目中的分工

| 维度 | RabbitMQ | RocketMQ |
|------|------|------|
| 当前状态 | 拓扑声明就绪，生产者/消费者待迁移 | 4 条业务线全部跑在 RocketMQ 上 |
| 延迟消息 | 需要安装 `delayed-message-exchange` 插件 | 内置 18 个延迟等级，`delayLevel` 直接传 |
| 堆积能力 | 适合低吞吐（万级） | 适合高吞吐（十万级），写磁盘顺序 IO |
| Spring 集成 | `RabbitTemplate` + `@RabbitListener` | `RocketMQTemplate` + `@RocketMQMessageListener` |
| 项目中的角色 | 通用业务消息（通知、状态同步） | 高吞吐 + 延迟消息（订单超时取消） |

---

# Part 4：验证与排错

## 4.1 FAQ

| 问题 | 原因 | 解决 |
|------|------|------|
| 消息发出去但 `@RabbitListener` 没反应 | Exchange 和队列的 Binding 没配，或 RoutingKey 不匹配 | 检查管理界面 Exchange → Bindings，确认队列已绑定且 RoutingKey 正确 |
| `org.springframework.amqp.AmqpException: No method found for class` | MessageConverter 不认消息类型——Body 不是 JSON | 确认 `Jackson2JsonMessageConverter` 已配置；发送端和接收端使用相同的消息类 |
| 消费者拿到消息后 JSON 反序列化失败 | 发送端和接收端的类路径不一致 | 消息用 `_class_` Header 记录源类型——默认情况下两边包路径必须一致 |
| "Channel shutdown: channel error" | 可能多次声明相同名称的 Exchange/Queue 但参数不同 | 检查 `@Bean` 定义——同一个队列名只能有一种参数组合 |
| `acknowledge-mode: manual` 但没调 `basicAck`，消息一直 Unacked | 手动模式下必须显式确认 | 加上 `channel.basicAck` 调用 |
| `convertAndSend` 不抛异常但消息也没到队列 | 消息被路由但 RoutingKey 没匹配到任何 Binding | 发消息前确保 Binding 已经声明好 |
| `@RabbitListener` 收到消息但反序列化为 null | Jackson 不知道要反序列化成哪个 Java 类——`_class_` Header 缺失 | 确认发送端用了 `Jackson2JsonMessageConverter`，不要手动存 JSON 字符串再发 |
| 4 个 Exchange/Queue 声明了但消费者还没写 | MQ 拓扑先于消费者代码部署（infrastructure-first） | 正常——拓扑声明不依赖消费者存在，等消费者部署后消息自动开始投递 |
| 消息发出去 10 秒就没了还没消费 | 队列的 `x-message-ttl=10000` 到期自动删除 | 根据业务调整 TTL，或确保消费者在 TTL 窗口内处理完毕 |
| `spring.amqp.deserialization.trust.all: true` 有什么风险 | 攻击者可以在消息里嵌入恶意序列化 payload | 生产环境改用 `trusted-packages: com.mall.domain` 白名单指定允许的包 |

## 4.2 总结

本文把前两篇中纯 Java 客户端的手动操作全部迁移到了 Spring AMQP，并以 mall 电商项目的真实 MQ 架构贯穿全文：

1. <strong>Part 2 教程版</strong>：`@Bean` 声明拓扑、`RabbitTemplate.convertAndSend` 发消息、`@RabbitListener` 收消息、手动 ACK——零依赖、可直接运行。

2. <strong>Part 3 生产版</strong>：四条业务线的完整 `RabbitConfig`、`MqHelper` 双 Broker 抽象（RabbitMQ + RocketMQ 统一 `send()` 接口）、Domain Entity 直传（省去 DTO 转换）、`@Qualifier` 按名注入、`WebSocketServer` 推送基础设施。

3. <strong>四种真实业务 MQ 模式</strong>：延时消息（超时订单取消 30min）、通知推送（Excel 导出完成 → WebSocket）、集群同步（Quartz 任务多节点同步）、领域实体直传（TradeEntity/CommonJobEntity 直接发）。

4. <strong>手动 ACK 两个方法</strong>：`basicAck` 确认成功 + `basicNack` 拒绝。`basicNack(tag, false, false)` 用于"不重要"的通知，`basicNack(tag, false, true)` 用于"必须成功"的操作。

下一步要解决消息<strong>不丢、不重、不阻塞</strong>的问题——消息可靠性保障、死信队列、重试机制。

> 📖 <strong>下一步阅读</strong>：消息发出去了，怎么保证不丢？消费者挂了消息去哪了？继续阅读 [<strong>消息可靠性保障</strong>]({{< relref "MessageReliability.md" >}})，一篇讲透 ACK、持久化、Publisher Confirm、死信队列和重试机制。
