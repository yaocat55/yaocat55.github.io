---
title: "序列化本质与 Jackson 全操作指南"
date: 2022-11-25T08:00:00+00:00
tags: ["基础技术"]
categories: ["序列化"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "从序列化的本质出发，拆解 Jackson 作为 SpringBoot 默认序列化器的全部核心操作：@JsonProperty/@JsonIgnore/@JsonFormat/@JsonInclude 等常用注解、ObjectMapper 定制配置、泛型反序列化、多态处理——附带完整代码示例。"
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

# 序列化本质与 Jackson 全操作指南

## 一、⚡ 序列化是什么：Java 对象和 JSON 之间的翻译官

日常写的代码里全是 Java 对象——`Order`、`User`、`Product`。但网络传输只能传二进制/文本，数据库只能存文本，前端浏览器只认得 JSON。怎么把 Java 对象变成 JSON、再把 JSON 变回 Java 对象？这就是<strong>序列化和反序列化</strong>：

```
序列化（Serialization）：    Java 对象  →  JSON / XML / 二进制
反序列化（Deserialization）： JSON / XML / 二进制  →  Java 对象
```

如果不做序列化，你就得手动拼 JSON：

```java
// 没有序列化工具——手动拼 JSON（又臭又长）
public String orderToJson(Order order) {
    return "{"
        + "\"orderId\":" + order.getOrderId() + ","
        + "\"userId\":" + order.getUserId() + ","
        + "\"productName\":\"" + escape(order.getProductName()) + "\","
        + "\"amount\":" + order.getAmount()
        + "}";
}
// 手写这段代码的时候，你就知道自己需要一个序列化工具了
```

序列化框架做的事就是<strong>自动</strong>完成这个转换——你要做的只是加几个注解、调一行方法。

### 1.1 序列化的两个方向

```java
// 你写的是左边，JSON 是右边
// 序列化：左边 → 右边（ObjectMapper.writeValueAsString）
// 反序列化：右边 → 左边（ObjectMapper.readValue）

Order order = new Order(10001L, 2001L, "iPhone 15", new BigDecimal("6999.00"), "created", LocalDateTime.now());

// 序列化后（JSON）：
{
  "orderId": 10001,
  "userId": 2001,
  "productName": "iPhone 15",
  "amount": 6999.00,
  "action": "created",
  "createTime": "2024-01-15T10:30:00"
}
```

### 1.2 JSON、XML、二进制——三种序列化格式

| 格式 | 可读性 | 体积 | 解析速度 | 适用场景 |
|------|:---:|:---:|:---:|------|
| <strong>JSON</strong> | 高（人眼可读） | 中 | 中 | HTTP API、配置文件、前端通信 |
| <strong>XML</strong> | 高 | 大 | 慢 | 旧系统、SOAP 协议 |
| <strong>二进制</strong>（Protobuf / Hessian2） | 低（不可读） | 最小 | 最快 | RPC 微服务内部通信 |

Jackson、Fastjson、Gson 都是<strong>JSON 序列化</strong>工具——只处理 JSON。Protobuf、Hessian2 是二进制序列化。

## 二、🧬 Jackson 是什么：SpringBoot 的"隐形"默认序列化器

如果你用过 SpringBoot，<strong>你已经在用 Jackson 了</strong>——只是你不知道：

```java
@RestController
public class OrderController {

    @GetMapping("/api/order/{id}")
    public Order getOrder(@PathVariable Long id) {
        Order order = orderService.getOrderById(id);
        return order;  // ← 这里！SpringBoot 自动调用 Jackson 把 Order 对象序列化为 JSON
    }
}

// curl http://localhost:8080/api/order/10001
// 返回：{"orderId":10001,"userId":2001,"productName":"iPhone 15","amount":6999.00}
//       ↑ 这就是 Jackson 干的活
```

<strong>SpringBoot 的 `spring-boot-starter-web` 默认依赖了 `jackson-databind`</strong>。当你写 `return order` 时，Spring 的 `MappingJackson2HttpMessageConverter` 拦截返回值，调 `ObjectMapper.writeValueAsString(order)` 转成 JSON，再写到 HTTP Response Body。整个过程对开发者透明——你只看到 return 了一个对象，浏览器收到了 JSON。

```mermaid
flowchart LR
    classDef startEnd fill:#F48FB1,stroke:#C2185B,stroke-width:2px,color:#212121,font-weight:bold;
    classDef process fill:#F5F5F5,stroke:#9E9E9E,stroke-width:1.5px,color:#212121;
    classDef data fill:#C8E6C9,stroke:#388E3C,stroke-width:1.5px,color:#1B5E20,font-weight:bold;
    classDef highlight fill:#FFCCBC,stroke:#E64A19,stroke-width:1.5px,color:#D84315,font-weight:bold;

    CTRL([Controller<br/>return order]) -->|"返回 Java 对象"| MC["MappingJackson2HttpMessageConverter<br/>Spring 的 HTTP 消息转换器"]
    MC -->|"调用"| MAPPER["ObjectMapper<br/>Jackson 的核心类"]
    MAPPER -->|"writeValueAsString"| JSON["{<br/>  \"orderId\": 10001,<br/>  \"productName\": \"iPhone 15\"<br/>}"]
    JSON -->|"写入 HTTP Response Body"| BROWSER([浏览器收到 JSON])

    class CTRL,BROWSER startEnd;
    class MC highlight;
    class MAPPER process;
    class JSON data;
```

## 三、🔧 ObjectMapper —— Jackson 的万能工具箱

### 3.1 基本用法

```java
// ObjectMapper 是 Jackson 最核心的类——一切转换都通过它
ObjectMapper mapper = new ObjectMapper();

// ===== 序列化：Java 对象 → JSON 字符串 =====
Order order = new Order(10001L, 2001L, "iPhone 15",
        new BigDecimal("6999.00"), "created", LocalDateTime.now());
String json = mapper.writeValueAsString(order);
System.out.println(json);
// 输出：{"orderId":10001,"userId":2001,"productName":"iPhone 15","amount":6999.00,"action":"created","createTime":"2024-01-15T10:30:00"}

// ===== 反序列化：JSON 字符串 → Java 对象 =====
String jsonStr = "{\"orderId\":10001,\"userId\":2001,\"productName\":\"iPhone 15\",\"amount\":6999.00}";
Order parsedOrder = mapper.readValue(jsonStr, Order.class);
System.out.println(parsedOrder.getProductName()); // 输出：iPhone 15

// ===== 反序列化：JSON 字节数组 → Java 对象 =====
byte[] jsonBytes = jsonStr.getBytes(StandardCharsets.UTF_8);
Order fromBytes = mapper.readValue(jsonBytes, Order.class);
```

### 3.2 用 Java 8 的 Optional 优雅拿值

```java
// Jackson 的 JsonNode（Tree Model）——不想定义 Java 类时用
String response = "{\"code\":200,\"message\":\"success\",\"data\":{\"orderId\":10001,\"amount\":6999.00}}";

JsonNode root = mapper.readTree(response);

// 链式取值——干净利落
int code = root.get("code").asInt();
String message = root.get("message").asText();
BigDecimal amount = new BigDecimal(root.get("data").get("amount").asText());

// 安全取值
Optional.ofNullable(root.get("data"))
        .map(data -> data.get("amount"))
        .map(JsonNode::asText)
        .map(BigDecimal::new)
        .ifPresent(amt -> System.out.println("金额: " + amt));
```

### 3.3 格式化输出（调试专用）

```java
// 紧凑模式——网络传输
String compact = mapper.writeValueAsString(order);
// {"orderId":10001,"userId":2001,"productName":"iPhone 15","amount":6999.00}

// 美化模式——日志/调试
String pretty = mapper.writerWithDefaultPrettyPrinter().writeValueAsString(order);
/*
{
  "orderId" : 10001,
  "userId" : 2001,
  "productName" : "iPhone 15",
  "amount" : 6999.00
}
*/
```

## 四、🏷️ Jackson 注解大全 —— 控制序列化的一切

### 4.1 @JsonProperty —— 改字段名、控制顺序

```java
public class Order {

    @JsonProperty("order_id")      // JSON 中的字段名变成 order_id
    private Long orderId;

    @JsonProperty(value = "user_id", index = 1)  // index 控制 JSON 输出顺序（越小越前）
    private Long userId;

    @JsonProperty(value = "product_name", index = 2)
    private String productName;

    // JSON 输出：
    // {
    //   "user_id": 2001,       ← index=1，排第一
    //   "product_name": "iPhone 15", ← index=2，排第二
    //   "order_id": 10001       ← 没指定 index，按声明顺序
    // }
}
```

### 4.2 @JsonIgnore / @JsonIgnoreProperties —— 隐藏字段

```java
// 方式一：标注在单个字段上
public class User {
    private Long userId;
    private String username;

    @JsonIgnore  // 序列化时完全忽略这个字段——不会出现在 JSON 中
    private String password;

    // 输出：{"userId": 2001, "username": "yaomingye"}
    // password 字段不存在——前端永远收不到密码
}

// 方式二：标注在类上——忽略多个字段
@JsonIgnoreProperties({"password", "salt", "internalId"})
public class User {
    private Long userId;
    private String username;
    private String password;
    private String salt;
    private Long internalId;
    // 序列化输出只包含 userId 和 username
}

// 方式三：忽略未知字段——防止反序列化时炸
@JsonIgnoreProperties(ignoreUnknown = true)
public class Order {
    // 已有的字段...
    // 如果前端多传了一个 "note" 字段，反序列化时不会报错——直接忽略
}
```

### 4.3 @JsonFormat —— 控制日期/数字格式

```java
public class Order {

    // 日期格式化
    @JsonFormat(pattern = "yyyy-MM-dd HH:mm:ss")
    private LocalDateTime createTime;
    // 输出："createTime": "2024-01-15 10:30:00"

    // 时区控制
    @JsonFormat(pattern = "yyyy-MM-dd HH:mm:ss", timezone = "GMT+8")
    private LocalDateTime updateTime;

    // 数字格式化
    @JsonFormat(shape = JsonFormat.Shape.STRING)
    private BigDecimal amount;
    // 输出："amount": "6999.00"
    // 不加这个注解 → 输出："amount": 6999.00 —— JS 可能精度丢失
}
```

> ⚠️ 新手提示：`BigDecimal` 一定要加 `@JsonFormat(shape = JsonFormat.Shape.STRING)`。JavaScript 的 Number 类型最大安全整数是 2^53-1（约 9007199254740991），超过这个值精度就丢了。`BigDecimal` 做金额计算精度极高——但 JSON 传输时 JavaScript 会把它当成 Number 处理，容易丢精度。<strong>金额字段必须用字符串传</strong>。

### 4.4 @JsonInclude —— 过滤 null 值和空值

```java
// 标注在类上——控制序列化时哪些字段被包含
@JsonInclude(JsonInclude.Include.NON_NULL)  // null 字段不输出
public class Order {
    private Long orderId;
    private String productName;      // 如果是 null → 不出现在 JSON 中
    private BigDecimal amount;
    private String remark;           // 如果是 null → 不出现在 JSON 中
}

// Order 对象：orderId=10001, productName=null, amount=6999.00, remark=null
// 序列化输出：{"orderId": 10001, "amount": 6999.00}
// 而不是：     {"orderId": 10001, "productName": null, "amount": 6999.00, "remark": null}
```

| Include 策略 | 行为 |
|------|------|
| `NON_NULL` | null 字段不输出 |
| `NON_EMPTY` | null + 空字符串 + 空集合 + 空数组不输出 |
| `NON_DEFAULT` | 等于默认值的字段不输出（int=0, boolean=false, String=null 等） |
| `ALWAYS`（默认） | 全部输出——包括 null |

### 4.5 @JsonPropertyOrder —— 按指定顺序输出

```java
@JsonPropertyOrder({"userId", "orderId", "amount", "productName"})
public class Order {
    private Long orderId;
    private Long userId;
    private String productName;
    private BigDecimal amount;
    // JSON 输出严格按照注解中的顺序——不管字段声明顺序
}
```

### 4.6 @JsonAlias —— 别名（兼容多个字段名）

```java
public class Order {

    @JsonAlias({"order_id", "orderId", "id"})
    private Long orderId;
    // 反序列化时：order_id / orderId / id 三个名字都能映射到 orderId 字段
    // 序列化时：输出用 @JsonProperty 的名，没有 @JsonProperty 就用字段名
}
```

### 4.7 @JsonSerialize / @JsonDeserialize —— 自定义序列化器

```java
// 场景：敏感信息脱敏——手机号中间四位变 ****
public class PhoneDesensitizeSerializer extends JsonSerializer<String> {
    @Override
    public void serialize(String value, JsonGenerator gen,
                          SerializerProvider serializers) throws IOException {
        if (value != null && value.length() == 11) {
            gen.writeString(value.substring(0, 3) + "****" + value.substring(7));
        } else {
            gen.writeString(value);
        }
    }
}

public class User {
    @JsonSerialize(using = PhoneDesensitizeSerializer.class)
    private String phone;
    // 序列化："phone": "138****5678"
}
```

## 五、ObjectMapper 全局配置

### 5.1 SpringBoot 中定制 ObjectMapper

```java
@Configuration
public class JacksonConfig {

    @Bean
    public Jackson2ObjectMapperBuilderCustomizer jacksonCustomizer() {
        return builder -> {
            // 日期格式
            builder.simpleDateFormat("yyyy-MM-dd HH:mm:ss");
            // 时区
            builder.timeZone("GMT+8");
            // null 字段不输出
            builder.serializationInclusion(JsonInclude.Include.NON_NULL);
            // 空 Bean 不报错（默认 true——空 Bean 序列化抛异常）
            builder.failOnEmptyBeans(false);
            // 未知字段不报错
            builder.failOnUnknownProperties(false);
            // 缩进输出（调试用——生产关闭）
            builder.indentOutput(false);
            // BigDecimal 用字符串输出——防止 JS 精度丢失
            builder.featuresToEnable(JsonGenerator.Feature.WRITE_BIGDECIMAL_AS_PLAIN);
        };
    }
}
```

```yaml
# 或者直接 yml——更简洁
spring:
  jackson:
    date-format: yyyy-MM-dd HH:mm:ss
    time-zone: GMT+8
    default-property-inclusion: non_null
    serialization:
      write-dates-as-timestamps: false  # 日期不转时间戳
    deserialization:
      fail-on-unknown-properties: false  # 未知字段不报错
    generator:
      write-bigdecimal-as-plain: true   # BigDecimal 不用科学计数法
```

### 5.2 关键配置项速查

| 配置 | yml 路径 | 默认值 | 建议 |
|------|------|:---:|------|
| 日期格式 | `spring.jackson.date-format` | — | `yyyy-MM-dd HH:mm:ss` |
| 时区 | `spring.jackson.time-zone` | UTC | `GMT+8` |
| null 不输出 | `spring.jackson.default-property-inclusion: non_null` | `always` | `non_null` |
| 未知字段报错 | `spring.jackson.deserialization.fail-on-unknown-properties` | `true` | <strong>`false`</strong>——生产必关 |
| BigDecimal 科学计数法 | `spring.jackson.generator.write-bigdecimal-as-plain` | `false` | <strong>`true`</strong>——必须开 |
| 日期转时间戳 | `spring.jackson.serialization.write-dates-as-timestamps` | `true` | `false`——人更愿意看字符串 |

## 六、泛型反序列化 —— TypeReference 解决擦除

```java
ObjectMapper mapper = new ObjectMapper();

// 场景：反序列化包含泛型的 API 响应
String response = """
    {
      "code": 200,
      "data": [
        {"orderId": 10001, "amount": 6999.00},
        {"orderId": 10002, "amount": 1999.00}
      ]
    }
    """;

// ❌ 错误写法——泛型擦除导致 ClassCastException
List<Order> orders = mapper.readValue(
    mapper.readTree(response).get("data").toString(),
    List.class  // 这里拿到的实际是 List<LinkedHashMap>，不是 List<Order>！
);

// ✅ 正确写法——用 TypeReference 保留泛型信息
List<Order> orders = mapper.readValue(
    mapper.readTree(response).get("data").toString(),
    new TypeReference<List<Order>>() {}  // ← 匿名子类保留泛型
);

for (Order o : orders) {
    System.out.println(o.getAmount());  // 6999.00, 1999.00
}
```

<strong>TypeReference 的原理</strong>：Java 泛型在编译后会被擦除——`List<Order>.class` 不存在，只有 `List.class`。`TypeReference` 通过创建匿名子类——子类的字节码中保留了父类的泛型参数信息——Jackson 通过反射读取这个信息来实现正确反序列化。

## 七、多态反序列化 —— @JsonTypeInfo

场景：一个字段的声明类型是父类/接口，但 JSON 中可能传任意子类：

```java
// 动物——可能是猫也可能是狗
@JsonTypeInfo(
    use = JsonTypeInfo.Id.NAME,       // 通过类型名称区分
    property = "type"                  // JSON 中的 type 字段标识具体类型
)
@JsonSubTypes({
    @JsonSubTypes.Type(value = Cat.class, name = "cat"),
    @JsonSubTypes.Type(value = Dog.class, name = "dog")
})
public abstract class Animal {
    private String name;
}

public class Cat extends Animal {
    private boolean indoor;
}

public class Dog extends Animal {
    private String breed;
}

// JSON：
// {"type": "cat", "name": "小白", "indoor": true}
//   → 反序列化为 Cat 对象

// {"type": "dog", "name": "大黄", "breed": "金毛"}
//   → 反序列化为 Dog 对象

// 使用——Animal 类型的字段可以接收任意子类
public class PetOwner {
    private Animal pet;  // 这里只写 Animal——Jackson 根据 type 字段自动选择子类
}
```

## 八、Jackson 的注册模块 —— 处理 JDK 8+ 特殊类型

```xml
<!-- Jackson 本身不理解 Java 8 的 LocalDateTime、Optional 等类型——需要额外模块 -->
<dependency>
    <groupId>com.fasterxml.jackson.datatype</groupId>
    <artifactId>jackson-datatype-jsr310</artifactId>
</dependency>
<dependency>
    <groupId>com.fasterxml.jackson.datatype</groupId>
    <artifactId>jackson-datatype-jdk8</artifactId>
</dependency>
```

```java
// 注册模块
ObjectMapper mapper = new ObjectMapper();
mapper.registerModule(new JavaTimeModule());  // 支持 LocalDateTime、LocalDate
mapper.registerModule(new Jdk8Module());      // 支持 Optional、Stream
mapper.disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS); // 日期不转时间戳

// SpringBoot 自动引入了 jackson-datatype-jsr310——不用手动注册
```

## 九、常见坑与 FAQ

| 问题 | 原因 | 解决 |
|------|------|------|
| `InvalidDefinitionException: No serializer found for class` | 类中没有 getter 方法——Jackson 默认通过 getter 方法获取字段值 | 给类加 `public` getter，或配 `mapper.setVisibility(PropertyAccessor.FIELD, Visibility.ANY)` |
| `UnrecognizedPropertyException: Unrecognized field "xxx"` | JSON 中有字段但 Java 类没有——Jackson 默认报错 | `@JsonIgnoreProperties(ignoreUnknown = true)` 或 yml 配 `fail-on-unknown-properties: false` |
| 前端收到的时间是一串数字（`1705284000000`） | Jackson 默认把日期序列化为时间戳 | `spring.jackson.serialization.write-dates-as-timestamps: false` |
| BigDecimal 变成 `6.999E+3` | Jackson 默认用科学计数法写 BigDecimal | `spring.jackson.generator.write-bigdecimal-as-plain: true` |
| `order_id` 字段映射不到 `orderId` | Jackson 默认按驼峰匹配——字段名 `order_id` → 对应的 Java 属性是 `setOrder_id()` | 加 `@JsonProperty("order_id")` |
| `List<Order>` 反序列化后变成 `List<LinkedHashMap>` | 泛型擦除 | 用 `new TypeReference<List<Order>>() {}` |

## 🎯 总结

1. <strong>序列化是 Java 对象和 JSON 之间的翻译官</strong>：序列化 = Java 对象 → JSON（输出），反序列化 = JSON → Java 对象（输入）。SpringBoot 默认用 Jackson 做这个翻译——`return order` 那一行背后就是 ObjectMapper。

2. <strong>Jackson 的注解就是控制开关</strong>：`@JsonProperty`（改字段名）、`@JsonIgnore`（隐藏字段）、`@JsonFormat`（格式化日期/数字）、`@JsonInclude`（过滤 null/空值）、`@JsonAlias`（兼容多个别名）。不需要改业务代码——加注解就行。

3. <strong>BigDecimal 必须用字符串传</strong>：`@JsonFormat(shape = JsonFormat.Shape.STRING)` 或全局配 `write-bigdecimal-as-plain: true`。这不是可选项——JavaScript 的 Number 精度不够。

4. <strong>泛型反序列化必须用 TypeReference</strong>：`new TypeReference<List<Order>>() {}`——泛型擦除后 Jackson 无法知道 List 里装什么类型。

5. <strong>SpringBoot yml 配置优先于代码 Bean</strong>：绝大多数 Jackson 全局设置都可以用 yml 一行搞定——不需要写 `@Bean Jackson2ObjectMapperBuilderCustomizer`。

> 📖 <strong>下一步阅读</strong>：Jackson 掌握了。但国内很多老项目用的是 Fastjson——它曾经是最快的 JSON 库，也爆出过一串高危漏洞。Fastjson 2 号称 "API 不变但安全了"。继续阅读 [<strong>Fastjson 进化史：从 1.x 漏洞到 Fastjson2</strong>]({{< relref "Fastjson2Guide.md" >}})。
