---
title: "BFF 层接口规范化踩坑记：从 Object 到 DTO 的全面改造"
date: 2023-07-05T11:30:03+00:00
tags: ["工程实践", "SpringCloud", "每日日报"]
categories: ["技术类"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "一次 BFF 层的全面改造经验总结：接口规范、ShardingSphere 跨分片查询、CQRS 统计数据取舍、Nacos 服务发现 IP 踩坑"
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
    relative: true
    hidden: false
---

## BFF 重构：接口规范化流水账

### 从 "Object e" 和 "Map c" 说起

项目里有一个 BFF 层，最初的写法长这样：

```java
@PostMapping("/xxx/insert")
public ApiResult<Integer> insert(@RequestBody Object e) { ... }

@PostMapping("/xxx/page")
public ApiResult<ResponsePageEntity<?>> page(@RequestBody Map c) { ... }
```

看起来很省事对吧？一个 `Object` 通吃所有入参，一个 `Map` 搞定所有查询条件。但问题在于——Swagger 上完全看不到请求体结构，前端看着文档只能看到 `{}`，根本不知道要传什么字段。

于是这轮干了一件脏活累活：把 BFF 层所有接口的 `@RequestBody Object` 和 `@RequestBody Map` 全换成了具体的 DTO 类。总共涉及约 **50 处**改动，覆盖了认证、用户、商品、订单、营销等全部模块。

改完之后的效果：

```java
@PostMapping("/xxx/insert")
public ApiResult<Integer> insert(@RequestBody XxxDTO entity) { ... }

@PostMapping("/xxx/page")
public ApiResult<ResponsePageEntity<?>> page(@RequestBody XxxConditionDTO c) { ... }
```

前端看 Swagger 终于能看到每个字段的名、类型、枚举值、示例——不需要反复在群里问"这个接口传什么"了。

### 顺手做的：Swagger 分组

之前 Swagger 的分组是按后端模块分的（"商品扩展数据"、"基础扩展数据"），前端根本不知道哪个组对应哪个页面。改为按前端页面分：认证、系统管理、商品管理、订单管理、营销管理……直接对应侧边栏菜单。

### FeignClient 返回类型的大坑

在改接口的过程中遇到一个经典错误：

```
Cannot deserialize value of type `int` from Object value
```

排查后发现是 `FeignClient` 定义的方法返回  `int` ，但后端控制器实际返回的是一个  `RowsDTO`  对象（ `{"rows":  1}` ）。Feign 在反序列化时看到 JSON 对象开头是 `{` ，但期望的是  `int` ，直接报错。

```java
// 错误的写法
// FeignClient
int insert(@RequestBody XxxEntity entity);

// 后端控制器实际返回的是 RowsDTO，不是 int
public RowsDTO insert(@RequestBody XxxEntity entity) {
    return new RowsDTO(xxxService.insert(entity));
}
```

修复方案： `FeignClient`  统一返回  `RowsDTO`  ，然后再调用 `.getRows()` 获取实际行数。虽然多了一个 `.getRows()` 调用，但至少反序列化不会炸了。

这个坑在项目初期就埋下了 ——当时写  `int`  返回值可能是图省事，但后来后端统一改成了  `RowsDTO` ，FeignClient 却没同步更新，直到这次才全部对齐。

## 分库分表的广播查询陷阱

### 背景

订单模块用了 ShardingSphere 做分库分表：8 个库 × 32 张分表。设计上是 CQRS 模式，读走 ES，写走 MySQL。管理后台的订单列表一直查的是 ES，所以 MySQL 分表的问题从来没暴露出来。

这次要给工作台加统计数据，需要从 MySQL 做聚合查询（SUM、COUNT、GROUP BY）。结果一查就报：

```
Table 'db_0.t_order_1' doesn't exist
```

### 根因

ShardingSphere 的路由配置写成：

```yaml
actualDataNodes: db_${0..7}.t_order_${0..31}
```

这个配置的意思是："每个库都有 t_order_0 到 t_order_31 共 32 张表"。但实际建表时只建了部分分表（按 `id % 8` 分散到各库），导致每个库只有 4 张表。正常的带分片键查询没问题，但做全表广播（比如 `COUNT(*)`）时，ShardingSphere 会生成所有 256 种组合，发现 `db_0.t_order_1` 不存在就直接报错。

### 修复

把缺的 224 张分表全补上，每个库建了完整的 32 张表。ShardingSphere 的广播查询就能正常工作了。

### 教训

分库分表的初始化脚本一定要跑到全，不要只跑部分。否则带 `{0..N}` 范围配置的广播查询一定踩坑。

## 统计数据：写在 ES 还是 MySQL 的哲学问题

仪表盘需要统计订单总数、今日订单、销售额等数据。查 MySQL 走 ShardingSphere 需要全表广播，性能差；查 ES 可以快速聚合，但 ES 里没有支付金额数据（只在 MySQL）。

最后的方案是**各取所长**：

| 数据 | 来源 | 原因 |
|------|------|------|
| 订单总数 | ES | ES 有全量数据， `count()`  毫秒级返回 |
| 销售额 | MySQL | ES 没有支付金额字段 |
| 订单状态统计 | MySQL | 状态字段两边都有，但 MySQL 更准确 |
| 今日注册用户 | MySQL | 用户表数据量小，直接查 |

CQRS 模式下的统计数据**不能只用单边数据源**，需要按字段特性分开取。这也意味着统计接口必须容忍部分数据源的暂时不可用——每个查询都用 try-catch 兜底，任何一个源挂了，其他数据还能正常返回。

## Nacos 服务发现的 IP 玄学

本地开发时反复遇到 Feign 调用超时的问题：

```
Connect timed out executing POST http://service-name/api/xxx
```

查 Nacos 控制台发现服务注册的 IP 是  `192.168.x.x` ——本机的局域网 IP。问题在于本机访问自己的局域网 IP 经常因为防火墙、网卡切换、VPN 等原因连不上，但  `127.0.0.1`  绝对不会超时。

解决方案：本地开发时在每服务的 `application.yml` 加一行：

```yaml
spring:
  cloud:
    nacos:
      discovery:
        ip: 127.0.0.1
```

生产环境不要配这个字段，让 Nacos 自动获取网卡 IP 即可。

就是这行配置，当初因为 sed 脚本写错加到了 `springdoc.discovery` 下面而不是 `nacos.discovery` 下面，导致一个服务启动时 YAML 解析失败。排查了半天才发现是加错了位置——自动化脚本一时爽，执行结果火葬场。

## 一点点感触

- **Swagger 文档不是给后端自己看的，是给前端看的** —— BFF 层的每一个 DTO、每一个字段的  `@Schema`  注释、每一条  `allowableValues` ，都是在给前端省时间。
- **FeignClient 的返回值类型必须和后端控制器一致** —— `int` 配 `RowsDTO` 这种"我觉得能通"的侥幸心理迟早爆雷。
- **分库分表要么别用，要用就把初始化脚本跑完** —— 跑一半比不跑更坑人，因为正常的查询可能没事，全表广播一触发就崩。
- **本地开发写死  `127.0.0.1` ，生产环境交给 Nacos 自动获取** —— 这条规则本来就很简单，但代价是排查了好几次 "Connect timed out" 才总结出来的。

文末附送一个 `.http` 测试脚本的小技巧：用 IDEA 的 HTTP Client 写测试脚本，前端拿到后点绿色箭头就能逐个接口验证，不用等后端帮忙测。110 条用例覆盖了所有增删改查，请求体的示例都是正确的，照着调就行。
