---
title: "Protobuf 语法精讲与 gRPC 概念"
date: 2022-11-28T08:00:00+00:00
tags: ["RPC框架", "实践教程", "序列化"]
categories: ["RPC框架"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "从零讲透 Protobuf 的每一个语法元素——message/oneof/map/enum/reserved/import/service、每行语法都有完整代码示例与编译验证、附带 HTTP/2 基础与 gRPC 四种调用模式概念——读完就能写出正确的 .proto 文件。"
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

# Protobuf 语法精讲与 gRPC 概念

## 一、⚡ Protobuf 是什么：为什么非要学一门"新语言"？

前面讲了 JSON 序列化——Jackson 和 Fastjson2 把 Java 对象和 JSON 之间互转。JSON 是人眼可读的文本——但<strong>文本格式有两个天然的劣势</strong>：

```
JSON 消息体（108 字节）：
{
  "orderId": 10001,
  "userId": 2001,
  "productName": "iPhone 15",
  "amount": 6999.00
}

同样的信息——Protobuf 二进制（约 35 字节）：
\x08\x91N\x12\x04...（肉眼不可读的二进制）
```

| JSON | Protobuf |
|------|------|
| 文本格式——每个字符占 1 字节 | 二进制格式——用最少的字节表达同样的数据 |
| 字段名重复传输（`"orderId"` 每次都要传） | 字段名不传——用数字编号代替（`orderId = 1`） |
| 解析慢——文本解析器 | 解析快——二进制解码器 |
| 人眼可读——curl 能调 | 人眼不可读——需要专用工具 |

<strong>Protobuf 省的不是几字节——是高并发场景下每一条消息都省 60%~80% 带宽</strong>。这就是为什么 gRPC 选择 Protobuf 作为默认序列化格式。

## 二、🧬 Protobuf 语法逐一拆解

Protobuf 的语法就是<strong>定义数据结构和服务接口的语言</strong>。文件后缀是 `.proto`。先看一个完整的例子，然后每个语法元素拆开讲：

```protobuf
// order.proto —— 订单服务的完整 proto 定义
syntax = "proto3";                      // ① 语法版本

package com.example.order;              // ② 包名

option java_multiple_files = true;      // ③ 编译选项
option java_package = "com.example.order.dto";

import "google/protobuf/timestamp.proto"; // ④ 导入其他 proto

// ⑤ 枚举定义
enum OrderStatus {
  ORDER_STATUS_UNSPECIFIED = 0;   // 枚举第一个值必须是 0
  ORDER_STATUS_CREATED = 1;
  ORDER_STATUS_PAID = 2;
  ORDER_STATUS_CANCELLED = 3;
}

// ⑥ 消息定义——Protobuf 的核心
message Order {
  int64 order_id = 1;                   // 字段编号 = 1
  string product_name = 2;              // 字段编号 = 2
  double amount = 3;                    // 字段编号 = 3
  OrderStatus status = 4;               // 使用上面定义的枚举
  google.protobuf.Timestamp created_at = 5; // 使用导入的时间戳类型
  repeated string tags = 6;             // repeated = 数组/列表
  map<string, string> metadata = 7;     // map 类型
}

// ⑦ 服务定义——gRPC 的方法声明
service OrderService {
  rpc GetOrder(GetOrderRequest) returns (Order);
  rpc ListOrders(ListOrdersRequest) returns (stream Order);    // 服务端流
  rpc CreateOrder(stream CreateOrderRequest) returns (stream Order); // 双向流
}

// 消息定义可以在 service 之后——顺序不要求
message GetOrderRequest {
  int64 order_id = 1;
}

message ListOrdersRequest {
  int64 user_id = 1;
  int32 page_size = 2;
}

message CreateOrderRequest {
  string product_name = 1;
  double amount = 2;
}
```

### 2.1  `syntax` —— 声明语法版本

```protobuf
syntax = "proto3";  // 必须在文件第一行（注释上面可以，语法上面不能有东西）
```

| 版本 | 特点 | 当前状态 |
|------|------|:---:|
| `proto2` | 老版本——有 `required`/`optional`/`default` 关键字 | gRPC 也支持，但不推荐新项目用 |
| <strong>`proto3`</strong> | 新版本——去掉了 `required` 和 `default`，所有字段默认可选 | <strong>当前主流——新项目统一用 proto3</strong> |

### 2.2 `package` —— 包名

```protobuf
package com.example.order;  // 防止命名冲突——和 Java 的 package 概念一样
// 生成 Java 代码时：类放在 com.example.order 包下
```

### 2.3 `option` —— 编译选项

```protobuf
// java_multiple_files: true → 每个 message 生成一个独立的 .java 文件
//                        false（默认） → 所有 message 生成到一个巨大的外部类中
option java_multiple_files = true;

// java_package: 指定生成的 Java 文件所在的包——如果不写，用 package 的值
option java_package = "com.example.order.dto";

// java_outer_classname: java_multiple_files = false 时——指定外部类的类名
option java_outer_classname = "OrderProto";

// optimize_for: 生成代码优化方向——SPEED / CODE_SIZE / LITE_RUNTIME
option optimize_for = SPEED;
```

| 选项 | 默认值 | 建议 |
|------|:---:|------|
| `java_multiple_files` | `false` | <strong>`true`</strong>——每个 message 一个文件，方便 IDE 导航 |
| `java_package` | `package` 的值（但它是默认的，不是必然） | 写成和 Java 项目一致的包名 |
| `optimize_for` | `SPEED` | 保持默认 |

### 2.4 `import` —— 导入其他 proto 文件

```protobuf
import "google/protobuf/timestamp.proto";   // 导入 Google 内置类型
import "common/common.proto";              // 导入自己项目的公共 proto
import public "common/new.proto";          // 公开导入——谁 import 你，谁也看得到 new.proto 的类型
```

<strong>常用内置类型</strong>（`google/protobuf/` 下的类型）：

| 类型 | proto 写法 | Java 生成 |
|------|------|------|
| Timestamp | `google.protobuf.Timestamp` | `java.time.Instant`（需要额外插件） |
| Duration | `google.protobuf.Duration` | `java.time.Duration` |
| Empty | `google.protobuf.Empty` | 空的请求/响应——无参方法用 |
| Any | `google.protobuf.Any` | 包任意类型——类似于 Object |
| Struct | `google.protobuf.Struct` | JSON Object——用于动态 JSON |
| Wrappers | `google.protobuf.Int64Value` 等 | 包装类型——区分 null 和 0 |

```protobuf
// 使用内置类型
import "google/protobuf/empty.proto";
import "google/protobuf/timestamp.proto";
import "google/protobuf/wrappers.proto";

service PingService {
  rpc Ping(google.protobuf.Empty) returns (google.protobuf.Empty);
}

message Product {
  string name = 1;
  google.protobuf.Timestamp created_at = 2;
  google.protobuf.Int64Value stock = 3; // Int64Value 可以区分"0"和"没传"——int64 做不到
}
```

### 2.5 核心语法：message

message 是 Protobuf 的核心——定义一个数据结构。每个字段有三个要素：

```protobuf
message Order {
  // 格式：类型 字段名 = 字段编号;
  int64 order_id = 1;        // 编号 = 1
  string product_name = 2;   // 编号 = 2
  double amount = 3;         // 编号 = 3
}
```

#### 字段类型对照表

| Protobuf 类型 | Java 类型 | 默认值 | 说明 |
|------|------|------|------|
| `int32` | `int` | 0 | 32 位整数——负数编码效率低 |
| <strong>`sint32`</strong> | `int` | 0 | 有符号 32 位——负数编码效率高 |
| `int64` | `long` | 0L | 64 位整数——负数编码效率低 |
| <strong>`sint64`</strong> | `long` | 0L | 有符号 64 位——负数编码效率高 |
| `uint32` | `int` | 0 | 无符号 32 位 |
| `float` | `float` | 0.0f | 单精度浮点——精度低，不推荐 |
| <strong>`double`</strong> | `double` | 0.0 | 双精度浮点——金额模拟永远不要用 |
| `bool` | `boolean` | false | 布尔 |
| <strong>`string`</strong> | `String` | "" | 字符串——UTF-8 编码 |
| <strong>`bytes`</strong> | `ByteString` | 空 | 二进制数据 |
| `fixed32` | `int` | 0 | 定长 32 位——处理大数值比 int32 快 |
| `fixed64` | `long` | 0L | 定长 64 位——同上 |

> ⚠️ 新手提示：`double` 对金额来说和 JSON 的 Number 一样有精度问题。<strong>金额用字符串传</strong>是最安全的——Protobuf 中没有 `BigDecimal` 类型，有三种解决方案：① 用 `string` 传——最可靠；② 用 `int64` 传分（6999.00 元 = 699900 分）；③ 定义 `Decimal` 类型（自定义 message，包含整数部份和小数部份）。

#### 字段编号 —— 最容易踩的坑

```protobuf
message Order {
  int64 order_id = 1;   // 1 是字段编号——不是默认值！
  string name = 2;
  // ...
}
```

<strong>字段编号是 Protobuf 序列化后二进制数据中的唯一标识</strong>——它不传字段名，只传编号 + 值。所以：

- <strong>编号 1~15</strong> 用一个字节存储——给最常用的字段
- <strong>编号 16~2047</strong> 用两个字节——给不常用的字段
- <strong>编号 19000~19999</strong> —— Protobuf 保留，不能用
- <strong>编号一旦使用</strong>——永远不要改，否则旧数据无法反序列化

```protobuf
// ❌ 反面教材——字段编号不能乱改
message Order {
  int64 order_id = 1;    // 第一次发布——order_id 对应编号 1
  // ... 三个月后
  string order_id = 1;   // ❌ 把类型从 int64 改成 string——旧数据是 int，奔溃！
  int64 user_id = 1;     // ❌ 把编号 1 分给 user_id——旧数据的 order_id 被读成 user_id！
}

// ✅ 正确做法——废弃字段，新建一个
message Order {
  reserved 1;              // 保留编号 1——谁也别用
  reserved "old_field";    // 保留字段名——谁也别用
  int64 user_id = 2;       // 新字段用新编号
}
```

### 2.6 `repeated` —— 数组 / 列表

```protobuf
message Order {
  repeated string tags = 1;              // 字符串列表 → Java: List<String>
  repeated OrderItem items = 2;          // 消息列表   → Java: List<OrderItem>
  repeated google.protobuf.Any details = 3; // 任意类型列表
}

message OrderItem {
  string product_name = 1;
  int32 quantity = 2;
}
```

```java
// Java 生成的代码——操作方式
Order order = Order.newBuilder()
    .addTags("urgent")
    .addTags("gift")
    .addItems(OrderItem.newBuilder()
        .setProductName("iPhone 15")
        .setQuantity(1)
        .build())
    .build();

// 拿到的是不可变 List
List<String> tags = order.getTagsList();       // ["urgent", "gift"]
int quantity = order.getItems(0).getQuantity(); // 1
```

### 2.7 `map` —— 键值对

```protobuf
message Order {
  map<string, string> metadata = 1;    // key=string, value=string
  map<int64, OrderItem> items = 2;     // key=long, value=OrderItem
  map<string, int32> scores = 3;       // key=string, value=int
}
// ❌ 限制：key 不能是 float/double/bytes/message/enum（只能是整数或字符串）
// ❌ 限制：value 不能是另一个 map
// ✅ 支持：map<string, MessageType>
// ✅ 支持：map<string, int32>
```

### 2.8 `enum` —— 枚举

```protobuf
enum OrderStatus {
  ORDER_STATUS_UNSPECIFIED = 0;  // 第一个值必须是 0——这是硬性规定
  ORDER_STATUS_CREATED = 1;
  ORDER_STATUS_PAID = 2;
  ORDER_STATUS_CANCELLED = 3;
  ORDER_STATUS_REFUNDED = 4;
}
// 命名规范：全大写 + 下划线——ORDER_STATUS_CREATED
//   - 前导 ORDER_STATUS_ 防止和其他枚举的值冲突（Protobuf 的枚举值是全局的！）
```

<strong>为什么第一个值必须是 0？</strong> proto3 中所有字段都有默认值——整数的默认值是 0，枚举的默认值就是第一个定义的值。如果不显式设置一个枚举字段，它会被赋值为 0——对应的枚举值必须有意义（如 `UNSPECIFIED`），否则反序列化后会看到"假数据"。

```protobuf
// ❌ 反模式
enum OrderStatus {
  ORDER_STATUS_CREATED = 1;     // ❌ 没有 0 值！proto3 不允许
}

// ✅ 正确
enum OrderStatus {
  ORDER_STATUS_UNSPECIFIED = 0; // ✅ 0 值表示"未知/未设置"
  ORDER_STATUS_CREATED = 1;
}
```

> ⚠️ 新手提示：Protobuf 枚举值的命名必须全大写 + 下划线，和其他语言的枚举规范完全不同。不遵守这个规范编译器会摇头。

### 2.9 `oneof` —— 多选一

```protobuf
message PaymentMethod {
  // 支付方式——只能选一种
  oneof method {
    string credit_card_number = 1;   // 信用卡号
    string alipay_account = 2;       // 支付宝账号
    string wechat_open_id = 3;       // 微信 OpenID
  }
}
// oneof 中的字段共享内存——只存一个值
// 设置 alipay_account 后，credit_card_number 自动清空
```

```java
// Java 代码——检查是哪种支付方式
PaymentMethod method = PaymentMethod.newBuilder()
    .setAlipayAccount("user@alipay.com")
    .build();

switch (method.getMethodCase()) {
    case CREDIT_CARD_NUMBER:
        System.out.println("信用卡支付");
        break;
    case ALIPAY_ACCOUNT:
        System.out.println("支付宝支付");
        break;
    case WECHAT_OPEN_ID:
        System.out.println("微信支付");
        break;
    case METHOD_NOT_SET:
        System.out.println("未设置支付方式");
        break;
}
```

### 2.10 `reserved` —— 永久删除字段

```protobuf
message Order {
  reserved 2, 15, 9 to 11;         // 保留编号 2、15、9~11——永远不能用
  reserved "old_field", "deprecated";  // 保留字段名——防止后人误用

  int64 order_id = 1;
  string product_name = 3;          // 用新编号
}
```

<strong>为什么要用 `reserved`？</strong> 删掉一个字段后——它的编号释放了。三个月后新同事不知道——用了编号 2 定义了一个新字段。结果——旧服务收到的数据中编号 2 被误读成新字段，产生难以调试的数据错乱。

### 2.11 `service` —— 定义 gRPC 方法

```protobuf
// Unary：一问一答——最常用的模式
service OrderService {
  // 格式：rpc 方法名(请求类型) returns (响应类型);
  rpc GetOrder(GetOrderRequest) returns (Order);
  rpc CreateOrder(CreateOrderRequest) returns (Order);
  rpc CancelOrder(CancelOrderRequest) returns (google.protobuf.Empty);
}

// 四种 gRPC 方法模式：
service StreamingDemo {
  // ① Unary：一问一答
  rpc GetOrder(GetOrderRequest) returns (Order);

  // ② Server Streaming：一问——N 答
  rpc ListOrders(ListOrdersRequest) returns (stream Order);
  //    客户端发一个请求 → 服务端逐条返回结果流（就像看视频——请求一次，画面连续返回）

  // ③ Client Streaming：N 问——一答
  rpc CreateOrders(stream CreateOrderRequest) returns (BatchResult);
  //    客户端发一组消息 → 服务端全部收完后返回一个结果（就像上传文件——分块上传，全部完成确认）

  // ④ Bidirectional Streaming：N 问——N 答
  rpc Chat(stream ChatMessage) returns (stream ChatMessage);
  //    客户端和服务端可以随时发送消息——顺序不受限制（就像打电话——两边都在说）
}
```

<strong>理解 `stream` 关键字</strong>：加在请求类型前 = 客户端流，加在响应类型前 = 服务端流，两边都加 = 双向流。

### 2.12 嵌套 message

```protobuf
message Order {
  int64 order_id = 1;

  // 嵌套定义——内部 message 只在 Order 中使用
  message OrderItem {
    string product_name = 1;
    int32 quantity = 2;
  }

  repeated OrderItem items = 2;
}
// 外部引用：Order.OrderItem item = ...;
```

### 2.13 `Any` —— 动态类型（慎用）

```protobuf
import "google/protobuf/any.proto";

message Event {
  string event_type = 1;
  google.protobuf.Any payload = 2;  // 可以是任意 message 类型——通过 pack/unpack
}
```

```java
// 打包——把任意 message 塞进 Any
Order order = Order.newBuilder().setOrderId(10001).build();
Any any = Any.pack(order);

// 拆包——判断类型后还原
if (any.is(Order.class)) {
    Order unpacked = any.unpack(Order.class);
}
```

> ⚠️ 新手提示：`Any` 用起来像 Java 的 `Object`——但不要滥用。如果你知道消息类型是固定的，用 `oneof` 更好——编译器会检查类型安全。`Any` 的类型检查在运行时。

## 三、编译 proto 文件

### 3.1 用 protoc 编译器

```bash
# 下载 protoc：
# https://github.com/protocolbuffers/protobuf/releases

# 编译——生成 Java 代码
protoc \
  --proto_path=src/main/proto \         # proto 文件目录
  --java_out=src/main/java \            # Java 生成目录
  --grpc-java_out=src/main/java \
  src/main/proto/order.proto

# 结果：在 src/main/java/com/example/order/dto/ 下生成：
#   Order.java
#   GetOrderRequest.java
#   OrderServiceGrpc.java               ← gRPC 客户端和服务端的基类
```

### 3.2 Maven 插件——自动编译

```xml
<!-- pom.xml —— 用 Maven 插件自动编译 proto -->
<build>
    <extensions>
        <extension>
            <groupId>kr.motd.maven</groupId>
            <artifactId>os-maven-plugin</artifactId>
            <version>1.7.1</version>
        </extension>
    </extensions>
    <plugins>
        <plugin>
            <groupId>org.xolstice.maven.plugins</groupId>
            <artifactId>protobuf-maven-plugin</artifactId>
            <version>0.6.1</version>
            <configuration>
                <protocArtifact>com.google.protobuf:protoc:3.25.0:exe:${os.detected.classifier}</protocArtifact>
                <pluginId>grpc-java</pluginId>
                <pluginArtifact>io.grpc:protoc-gen-grpc-java:1.60.0:exe:${os.detected.classifier}</pluginArtifact>
            </configuration>
            <executions>
                <execution>
                    <goals>
                        <goal>compile</goal>
                        <goal>compile-custom</goal>
                    </goals>
                </execution>
            </executions>
        </plugin>
    </plugins>
</build>
```

```bash
# mvn compile 时自动执行 protoc → 生成代码在 target/generated-sources/ 下
mvn clean compile
```

## 四、gRPC 核心概念

### 4.1 gRPC 是什么

gRPC = <strong>Google 开源的高性能 RPC 框架，基于 HTTP/2 + Protobuf</strong>。

```
gRPC 的协议栈：
  gRPC 调用逻辑（方法调用、流控制、错误传递）
     ↓
  Protobuf 序列化（把 Java 对象 → 二进制）
     ↓
  HTTP/2 传输（多路复用、头部压缩、双向流）
     ↓
  TCP / TLS
```

### 4.2 HTTP/2 的四个关键能力

gRPC 之所以能支持四种调用模式（Unary、Server Stream、Client Stream、BiDi），是因为 HTTP/2 提供了 HTTP/1.1 没有的能力：

| HTTP/2 特性 | 含义 | gRPC 如何利用 |
|------|------|------|
| <strong>多路复用</strong> | 一个 TCP 连接上同时发送多个请求/响应——互不阻塞 | 客户端可以在同一个连接上并发调多个方法 |
| <strong>Server Push</strong> | 服务端主动推数据——不需要客户端请求 | Server Streaming——服务端推一个结果流给客户端 |
| <strong>双向流</strong> | 客户端和服务端可以同时对发消息 | BiDi Streaming——两端可以独立发送消息 |
| <strong>头部压缩（HPACK）</strong> | 请求和响应的 Header 被压缩传输 | 减少了每个 gRPC 调用的额外开销 |

---

这篇的内容到这里就过去了，下一篇直接用 SpringBoot 接上——四种模式全部用代码跑通。

> 📖 <strong>下一步阅读</strong>：语法和概念都过完了。SpringBoot 中怎么用 gRPC？四种调用模式怎么写？拦截器和 Deadline 怎么配？继续阅读 [<strong>SpringBoot gRPC 全操作指南</strong>]({{< relref "SpringBootGrpc.md" >}})。
