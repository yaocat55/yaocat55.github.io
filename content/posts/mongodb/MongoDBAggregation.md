---
title: "MongoDB 聚合管道深入"
date: 2022-10-28T08:00:00+00:00
tags: ["MongoDB", "实践教程", "数据存储"]
categories: ["数据库类"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "深入讲解 MongoDB Aggregation Pipeline 的各阶段操作符——$match/$group/$sort/$project/$unwind/$lookup/$facet/$bucket，附带完整 mongosh 与 Java 代码对照。"
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

# 聚合管道实战：从入门到精通

> 📖 <strong>前置阅读</strong>：本文是 MongoDB 系列的<strong>进阶篇</strong>，假设读者已经掌握了 MongoDB 文档模型和 SpringBoot 基本操作。如果还没有，建议先阅读前两篇：
> - [<strong>MongoDB 核心概念：文档模型、BSON 与查询操作符全解析</strong>]({{< relref "MongoDBFundamentals.md" >}}) —— 介绍篇
> - [<strong>SpringBoot MongoDB 全操作指南</strong>]({{< relref "SpringBootMongoDB.md" >}}) —— 实战篇

## 一、⚡ 问题切入：查询能查出结果，但分析不出来

先看一个业务需求。你有一个电商订单 Collection：

```javascript
// 一条订单文档
{
  _id: ObjectId("..."),
  userId: 1001,
  total: NumberDecimal("6999.00"),
  status: "paid",
  items: [
    { productName: "华为Mate60 Pro", category: "手机", price: NumberDecimal("6999.00"), quantity: 1 }
  ],
  createTime: ISODate("2024-01-15T10:30:00Z")
}
```

产品经理要你给出以下数据：
- 每个用户的总消费金额
- 每月订单量趋势
- 销量最高的 10 个商品分类
- 每个用户的平均客单价
- 哪些商品经常一起购买（关联分析）

用 `find` 可以查出原始数据，但统计计算全得拉到 Java 内存里自己算——5 万条订单光加载到内存就需要 2 秒，再算就 5 秒起步。

这就是聚合管道的用武之地——<strong>把计算下推到 MongoDB 服务器端完成</strong>，只返回结果，不传原始数据。

## 二、🧱 聚合管道是什么

### 2.1 核心概念

<strong>聚合管道（Aggregation Pipeline）</strong> 是一组按顺序执行的数据处理阶段（Stage）。每个 Stage 接收上一阶段的输出，做一次数据变换，把结果传给下一阶段。

```mermaid
flowchart LR
classDef stage fill:#450a0a,stroke:#dc2626,stroke-width:1.5px,color:#fecaca,font-weight:bold;
classDef data fill:#052e16,stroke:#16a34a,stroke-width:1.5px,color:#bbf7d0,font-weight:bold;
classDef result fill:#0f172a,stroke:#3b82f6,stroke-width:2px,color:#bfdbfe,font-weight:bold;

    COLLECTION[(orders\n50000 文档)]
    COLLECTION --> S1[$match\n过滤: status=paid]
    S1 --> S2[$group\n分组: 按 userId]
    S2 --> S3[$sort\n排序: 总金额降序]
    S3 --> S4[$limit\n取前 10]
    S4 --> RESULT([10 条聚合结果])

    class S1,S2,S3,S4 stage;
    class COLLECTION data;
    class RESULT result;
```

关键点：
- <strong>顺序执行</strong>：`$match` → `$group` → `$sort` → `$limit`，前一个的输出是后一个的输入
- <strong>管道（Pipeline）</strong>：和 Linux 的 `cat orders.log | grep "paid" | sort | head -10` 一个思路
- <strong>下推计算</strong>：50000 条文档在 MongoDB 服务器端被逐步过滤和聚合，最终只把 10 条结果返回给应用程序

### 2.2 聚合管道 vs find

| 能力 | `find` | 聚合管道 |
|------|:---:|:---:|
| 条件过滤 | 支持 | `$match` |
| 分组统计（GROUP BY） | 不支持 | `$group` |
| 多表关联（JOIN） | 不支持 | `$lookup` |
| 字段计算/重命名 | 不支持 | `$project` |
| 数组拆分 | 不支持 | `$unwind` |
| 分桶统计 | 不支持 | `$bucket` / `$bucketAuto` |
| 排序 / 分页 | sort + skip + limit | `$sort` + `$skip` + `$limit` |

聚合管道就是 MongoDB 的 <strong>SQL + GROUP BY + JOIN + HAVING + 窗口函数</strong> 的合体。

## 三、🔧 核心 Stage 详解

以下所有示例基于一个电商订单 Collection：

```javascript
// 示例数据
db.orders.insertMany([
  { userId: 1, name: "张三", total: NumberDecimal("6999.00"), status: "paid",
    items: [{ product: "手机", cat: "电子", price: NumberDecimal("6999.00"), qty: 1 }],
    createTime: ISODate("2024-01-15T10:30:00Z") },
  { userId: 1, name: "张三", total: NumberDecimal("150.00"), status: "paid",
    items: [{ product: "数据线", cat: "配件", price: NumberDecimal("50.00"), qty: 3 }],
    createTime: ISODate("2024-01-20T14:00:00Z") },
  { userId: 2, name: "李四", total: NumberDecimal("12000.00"), status: "paid",
    items: [
      { product: "MacBook", cat: "电脑", price: NumberDecimal("10000.00"), qty: 1 },
      { product: "鼠标", cat: "配件", price: NumberDecimal("200.00"), qty: 1 }
    ],
    createTime: ISODate("2024-02-05T09:00:00Z") },
  { userId: 3, name: "王五", total: NumberDecimal("300.00"), status: "cancelled",
    items: [{ product: "书", cat: "图书", price: NumberDecimal("30.00"), qty: 10 }],
    createTime: ISODate("2024-02-10T16:00:00Z") }
])
```

### 3.1 `$match` —— 过滤

等价 SQL 的 `WHERE`。<strong>建议放在管道最前面</strong>，先过滤缩小数据范围，减少后续阶段的计算量。

```javascript
db.orders.aggregate([
  { $match: {
      status: "paid",
      total: { $gte: NumberDecimal("100") }
  } }
])
```

```java
Aggregation agg = Aggregation.newAggregation(
    Aggregation.match(
        Criteria.where("status").is("paid")
            .and("total").gte(100)
    )
);
```

`$match` 可以走索引，和 `find` 的查询条件一样。能用索引的过滤条件应该放在管道最前面——MongoDB 优化器会尝试在 `$match` 阶段利用索引。

### 3.2 `$group` —— 分组聚合

等价 SQL 的 `GROUP BY`。聚合管道<strong>最核心、最常用</strong>的阶段。

```javascript
// 按 userId 分组，统计每个用户的订单数、消费总额、最大单笔消费
db.orders.aggregate([
  { $match: { status: "paid" } },
  { $group: {
      _id: "$userId",                        // 分组依据（$字段名 = 引用字段值）
      orderCount: { $count: {} },            // 计数
      totalSpent: { $sum: "$total" },        // 求和
      avgOrder: { $avg: "$total" },          // 平均值
      maxOrder: { $max: "$total" },          // 最大值
      firstOrder: { $first: "$createTime" }  // 每组第一个
  } },
  { $sort: { totalSpent: -1 } }
])
// 返回：
// [
//   { _id: 2, orderCount: 1, totalSpent: NumberDecimal("12000.00"), avgOrder: NumberDecimal("12000.00"), maxOrder: AmountDecimal("12000.00") },
//   { _id: 1, orderCount: 2, totalSpent: NumberDecimal("7149.00"), ... }
// ]
```

`$group` 的 `_id` 是分组依据——`_id: "$userId"` 表示按 userId 字段分组。如果 `_id: null` 则表示所有文档分到同一组（全量统计）。

`$group` 支持的累加器速查：

| 累加器 | 含义 | 示例 |
|--------|------|------|
| `$count` | 计数 | `count: { $count: {} }` （MongoDB 5.0+） |
| `$sum` | 求和 | `total: { $sum: "$total" }` |
| `$avg` | 平均值 | `avg: { $avg: "$total" }` |
| `$max` / `$min` | 最大值 / 最小值 | `max: { $max: "$total" }` |
| `$first` / `$last` | 每组第一个 / 最后一个 | `first: { $first: "$name" }` |
| `$push` | 把值推入数组（保留所有值） | `allNames: { $push: "$name" }` |
| `$addToSet` | 推入数组但去重 | `unique: { $addToSet: "$name" }` |

`$push` 和 `$addToSet` 可以把每组的所有值收集到一个数组里——适合"每个用户买过的所有商品名"这种需求。但注意：<strong>每组的文档不能超过 16MB</strong>（BSON 单文档大小限制），数据量大时别随便 `$push`。

<strong>按多个字段分组</strong>：

```javascript
// 按 userId + 状态 分组
{ $group: {
    _id: { user: "$userId", status: "$status" },
    count: { $count: {} }
} }
```

```java
// Java 代码
Aggregation agg = Aggregation.newAggregation(
    Aggregation.match(Criteria.where("status").is("paid")),
    Aggregation.group("userId")
        .count().as("orderCount")
        .sum("total").as("totalSpent")
        .avg("total").as("avgOrder"),
    Aggregation.sort(Sort.by(Sort.Direction.DESC, "totalSpent"))
);
```

### 3.3 `$sort`、`$skip`、`$limit` —— 排序与分页

和 `find` 的 sort / skip / limit 完全一样，只是放在了聚合管道中：

```javascript
db.orders.aggregate([
  { $match: { status: "paid" } },
  { $sort: { total: -1 } },            // 按 total 降序
  { $skip: 10 },                       // 跳过前 10 条
  { $limit: 10 }                       // 返回 10 条
])
```

> ⚠️ 新手提示：`$sort` 的位置很关键——在 `$group` 之前排序是对原始文档排序，在 `$group` 之后排序是对聚合结果排序。大多数分析场景是把 `$sort` 放在 `$group` 之后。

### 3.4 `$project` —— 字段重塑

等价 SQL 的 `SELECT a, b, c AS d`。可以对字段做三件事：<strong>保留/排除、重命名、计算新字段</strong>。

```javascript
db.orders.aggregate([
  { $project: {
      userName: "$name",                  // 重命名：name → userName
      total: 1,                           // 保留 total
      items: 0,                           // 排除 items（不返回）
      status: 1,
      // 计算新字段
      isBigOrder: { $gte: ["$total", NumberDecimal("5000")] },  // 是否大单
      month: { $month: "$createTime" },    // 提取月份（1-12）
      year: { $year: "$createTime" },      // 提取年份
      daysAgo: {                            // 距今多少天
        $dateDiff: {
          startDate: "$createTime",
          endDate: new Date(),
          unit: "day"
        }
      }
  } }
])
```

`$project` 里可以用大量表达式操作符：

| 操作符类型 | 操作符 | 示例 |
|-----------|--------|------|
| 算术 | `$add`、`$subtract`、`$multiply`、`$divide`、`$mod` | `{ total: { $multiply: ["$price", "$qty"] } }` |
| 比较 | `$eq`、`$ne`、`$gt`、`$gte`、`$lt`、`$lte` | `{ isBig: { $gte: ["$total", 5000] } }` |
| 逻辑 | `$and`、`$or`、`$not`、`$cond` | `{ level: { $cond: { if: { $gte: ["$total", 10000] }, then: "VIP", else: "普通" } } }` |
| 字符串 | `$concat`、`$toUpper`、`$substr`、`$split` | `{ upper: { $toUpper: "$name" } }` |
| 日期 | `$year`、`$month`、`$dayOfMonth`、`$dateDiff` | `{ year: { $year: "$createTime" } }` |
| 类型转换 | `$toString`、`$toInt`、`$toDate`、`$toDecimal` | `{ numStr: { $toString: "$_id" } }` |

```java
// Java 代码
Aggregation agg = Aggregation.newAggregation(
    Aggregation.project()
        .and("name").as("userName")
        .andInclude("total", "status")
        .andExclude("items")
        .and(ConditionalOperators.Cond.when(
            ComparisonOperators.valueOf("total").greaterThanEqualToValue(5000))
            .then("大单").otherwise("小单"))
        .as("orderLevel")
);
```

### 3.5 `$unwind` —— 拆开数组

把一个数组字段<strong>拆成多行</strong>——数组中每个元素变成独立的一行，其他字段重复。

```javascript
// 原始文档：订单有 2 个商品在一个 items 数组中
// { userId: 2, items: [ {product:"A", qty:1}, {product:"B", qty:1} ] }

// 拆开后变成 2 行——每个商品一行
db.orders.aggregate([
  { $unwind: "$items" }
])
// 返回：
// { userId: 2, items: { product: "A", qty: 1 } }
// { userId: 2, items: { product: "B", qty: 1 } }
```

拆开后就可以按商品维度做分组统计了：

```javascript
// 统计每个商品的销量
db.orders.aggregate([
  { $unwind: "$items" },
  { $group: {
      _id: "$items.product",
      totalSold: { $sum: "$items.qty" },
      revenue: { $sum: { $multiply: ["$items.price", "$items.qty"] } }
  } },
  { $sort: { totalSold: -1 } }
])
```

```java
Aggregation agg = Aggregation.newAggregation(
    Aggregation.unwind("items"),
    Aggregation.group("items.product")
        .sum("items.qty").as("totalSold")
        .sum("items.price").as("revenue"),
    Aggregation.sort(Sort.by(Sort.Direction.DESC, "totalSold"))
);
```

`$unwind` 的 `preserveNullAndEmptyArrays`：如果数组为空或字段不存在，默认会丢弃这条文档。设为 `true` 则保留（并置 items 为 null）：

```javascript
{ $unwind: { path: "$items", preserveNullAndEmptyArrays: true } }
```

### 3.6 `$lookup` —— 左连接（JOIN）

MongoDB 不鼓励 JOIN，但现实中有时确实需要跨 Collection 关联。`$lookup` 实现 <strong>LEFT OUTER JOIN</strong>：

```javascript
// orders Collection
// { _id: 1, userId: 1, total: 6999 }

// users Collection
// { _id: 1, name: "张三", email: "zhangsan@example.com" }

db.orders.aggregate([
  { $lookup: {
      from: "users",                       // 要关联的 Collection
      localField: "userId",                // orders 的关联字段
      foreignField: "_id",                 // users 的关联字段
      as: "userInfo"                       // 结果存入这个字段（数组，即使只有一条）
  } },
  { $unwind: "$userInfo" },               // 拆开数组（一对一关系时拆成单个对象）
  { $project: {
      total: 1,
      userName: "$userInfo.name",          // 拿到 users 中的字段
      userEmail: "$userInfo.email"
  } }
])
```

`$lookup` 的管道子查询写法（MongoDB 3.6+，更灵活）：

```javascript
{ $lookup: {
    from: "users",
    let: { userId: "$userId" },
    pipeline: [
      { $match: { $expr: { $eq: ["$_id", "$$userId"] } } },
      { $project: { name: 1, email: 1, _id: 0 } }
    ],
    as: "userInfo"
} }
```

对于绝大多数场景，<strong>能用嵌入解决的就不要用 $lookup</strong>。`$lookup` 的性能是 O(n×m) 级别的——如果 orders 有 10 万条，users 有 5 万条，最坏情况需要遍历 50 亿次。被关联的 `users` 字段（`foreignField`）必须有索引。

```java
Aggregation agg = Aggregation.newAggregation(
    Aggregation.lookup("users", "userId", "_id", "userInfo"),
    Aggregation.unwind("userInfo"),
    Aggregation.project()
        .andInclude("total")
        .and("userInfo.name").as("userName")
        .and("userInfo.email").as("userEmail")
);
```

### 3.7 `$facet` —— 并行多维度分析

一次查询同时输出多个维度的统计结果——<strong>一次查询替代多次聚合</strong>：

```javascript
db.orders.aggregate([
  { $facet: {
      // 维度一：按状态统计
      byStatus: [
        { $group: { _id: "$status", count: { $count: {} }, totalAmount: { $sum: "$total" } } }
      ],
      // 维度二：按月统计
      byMonth: [
        { $group: {
            _id: { $dateToString: { format: "%Y-%m", date: "$createTime" } },
            count: { $count: {} },
            totalAmount: { $sum: "$total" }
        } },
        { $sort: { _id: 1 } }
      ],
      // 维度三：Top 3 用户
      topUsers: [
        { $group: { _id: "$userId", totalSpent: { $sum: "$total" } } },
        { $sort: { totalSpent: -1 } },
        { $limit: 3 }
      ]
  } }
])
// 一次查询返回三个维度的统计——仪表盘页面靠这一个请求就够了
```

### 3.8 `$bucket` —— 自定义分桶

按自定义区间分组：

```javascript
// 按订单金额分桶
db.orders.aggregate([
  { $bucket: {
      groupBy: "$total",                                // 分桶依据
      boundaries: [0, 100, 500, 2000, 5000, 50000],    // 区间边界：[0,100) [100,500) ...
      default: "50000+",                                // 超出最大边界的统一归类
      output: {
        count: { $count: {} },
        totalAmount: { $sum: "$total" }
      }
  } }
])
// 返回：
// [
//   { _id: 0, count: 0, total: 0 },
//   { _id: 100, count: 1, total: NumberDecimal("300.00") },
//   { _id: 500, count: 1, total: NumberDecimal("150.00") },
//   { _id: 2000, count: 0, total: 0 },
//   { _id: 5000, count: 2, total: NumberDecimal("18999.00") }
// ]
```

`$bucketAuto`：不手写区间，让 MongoDB 自动均分区间。适合先探数据分布再决定区间。

## 四、🎯 完整案例：电商数据分析仪表盘

用一个完整的分析案例把所有阶段串起来。产品经理要的"运营仪表盘"：

```javascript
// ======== 一个聚合查询，输出所有仪表盘数据 ========
db.orders.aggregate([
  // ═══════════════════════════════
  // $facet 实现并行多维度分析
  // ═══════════════════════════════
  { $facet: {

    // ---- 面板 1：核心指标（全量统计）----
    "kpi": [
      { $group: {
          _id: null,
          totalOrders: { $count: {} },
          totalRevenue: { $sum: "$total" },
          avgOrderValue: { $avg: "$total" },
          maxOrder: { $max: "$total" }
      } },
      { $project: { _id: 0 } }
    ],

    // ---- 面板 2：每月趋势（按月份统计订单量和金额）----
    "monthlyTrend": [
      { $group: {
          _id: { $dateToString: { format: "%Y-%m", date: "$createTime" } },
          orders: { $count: {} },
          revenue: { $sum: "$total" }
      } },
      { $sort: { _id: 1 } }
    ],

    // ---- 面板 3：商品分类排行（需要 $unwind + $group）----
    "categoryRanking": [
      { $unwind: "$items" },
      { $group: {
          _id: "$items.cat",
          sold: { $sum: "$items.qty" },
          revenue: { $sum: { $multiply: ["$items.price", "$items.qty"] } }
      } },
      { $sort: { sold: -1 } },
      { $limit: 10 }
    ],

    // ---- 面板 4：订单金额分布（$bucket 分桶）----
    "orderDistribution": [
      { $bucket: {
          groupBy: "$total",
          boundaries: [0, 200, 500, 2000, 5000, 20000, 100000],
          default: "100000+",
          output: {
            count: { $count: {} },
            revenue: { $sum: "$total" }
          }
      } }
    ]
  } }
])
```

```java
// Java 代码 —— 一次请求拿到所有数据
Aggregation agg = Aggregation.newAggregation(
    Aggregation.facet()
        .and(Aggregation.group().count().as("totalOrders")
                .sum("total").as("totalRevenue")
                .avg("total").as("avgOrderValue"))
            .as("kpi")
        .and(Aggregation.group(
                DateOperators.dateFromString("$createTime").toString("%Y-%m"))
                .count().as("orders")
                .sum("total").as("revenue"),
            Aggregation.sort(Sort.by("_id").ascending()))
            .as("monthlyTrend")
        .and(Aggregation.unwind("items"),
            Aggregation.group("items.cat")
                .sum("items.qty").as("sold")
                .sum("items.price").as("revenue"),
            Aggregation.sort(Sort.by(Sort.Direction.DESC, "sold")),
            Aggregation.limit(10))
            .as("categoryRanking")
);

AggregationResults<Dashboard> results = mongoTemplate.aggregate(
    agg, "orders", Dashboard.class);
Dashboard dashboard = results.getUniqueMappedResult();
```

数据量上去后（十万级订单），这个聚合查询可能需要几百毫秒。对于仪表盘场景，建议用<strong>定时任务预计算</strong>——每小时跑一次聚合，把结果缓存到另一个 Collection，前端直接读缓存，从几百毫秒降到 1 毫秒。

## 五、⚡ 聚合管道性能优化

<strong>1. `$match` 放在最前面</strong>

这是最重要的一条。`$match` 能利用索引，把管道入口的数据量从百万级降到几千级，后续所有阶段的计算量都跟着降。

<strong>2. `$project` 尽早执行</strong>

在 `$group` 之前先 `$project` 只保留需要的字段。字段越少，`$group` 需要处理的数据量越小：

```javascript
// 优化前：group 处理完整的 20 个字段
db.orders.aggregate([
  { $group: { _id: "$userId", total: { $sum: "$total" } } }
])

// 优化后：只留 group 需要的字段
db.orders.aggregate([
  { $project: { userId: 1, total: 1 } },
  { $group: { _id: "$userId", total: { $sum: "$total" } } }
])
```

<strong>3. 允许 MongoDB 使用磁盘</strong>

聚合管道默认必须在 <strong>100MB 内存</strong>内完成。超大数据量聚合时，加 `allowDiskUse: true` 让 MongoDB 把中间结果暂写到磁盘：

```javascript
db.orders.aggregate([...], { allowDiskUse: true })
```

```java
// Java
mongoTemplate.aggregate(
    agg.withOptions(AggregationOptions.builder().allowDiskUse(true).build()),
    "orders", Result.class);
```

<strong>4. `$lookup` 关联字段必须有索引</strong>

`$lookup` 对 `foreignField` 没有索引会退化为全 Collection 扫描。确保被关联的 Collection 的关联字段上有索引。

## 六、🎯 总结

本文从"能查出数据但分析不出来"的困境出发，深入 MongoDB 聚合管道的各阶段操作符：

1. <strong>`$match`</strong>：过滤，等价 WHERE。放在管道最前面，能用索引。

2. <strong>`$group`</strong>：分组聚合，等价 GROUP BY。支持 `$count / $sum / $avg / $max / $min / $first / $last / $push / $addToSet` 等累加器。

3. <strong>`$project`</strong>：字段重塑，等价 SELECT。支持算术、比较、逻辑、字符串、日期、类型转换等表达式操作符。

4. <strong>`$unwind`</strong>：数组拆行——每个元素一行。是"按商品维度分析订单"必须经过的阶段。

5. <strong>`$lookup`</strong>：左连接，等价 LEFT JOIN。能不用就不用，优先嵌入。如果必须用，被关联字段要有索引。

6. <strong>`$facet`</strong>：并行多维度分析，一次查询输出多组统计结果。仪表盘页面的最佳实践。

7. <strong>`$bucket`</strong>：自定义区间分桶。适合订单金额分布、用户年龄分布等场景。

> 📖 <strong>下一步阅读</strong>：聚合能用了、分析能做完了。下一步是确保这些查询在生产环境里跑得快——索引怎么设计、`explain()` 怎么读、Schema 嵌入还是引用、事务怎么用。继续阅读 [<strong>MongoDB 索引、事务与性能调优</strong>]({{< relref "MongoDBProductionOptimization.md" >}})，掌握索引策略、性能分析和 Schema 设计。
