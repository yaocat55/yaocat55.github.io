---
title: "分布式事务本质——CAP、BASE 与四大方案"
date: 2022-12-27T08:00:00+00:00
tags: ["分布式事务", "原理解析", "工程实践"]
categories: ["分布式事务中间件"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "分布式事务的本质不是背八股文中的 CAP——搞懂为什么 @Transactional 在微服务中失效、CAP 到底在说什么（P 是前提——只能在 C 和 A 之间取舍——但实际情况是'不同程度的取舍'——不是二选一）、BASE 最终一致性的核心——补偿而不是回滚、XA 两阶段提交为什么不能用（性能黑洞 + 单点故障）、四种方案的本质区别（XA-同步回滚 / AT-自动补偿 / TCC-手动补偿 / Saga-长事务编排 / 事务消息-异步确保）——以及选型决策框架。"
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

# 分布式事务本质

## 一、⚡ @Transactional 在生产中失效——不是代码写错了——是底层就不是一回事

先看一个场景——最经典的"下单扣库存"：

```java
// 单体应用——一个 @Transactional 搞定
@Service
public class OrderService {

    @Transactional
    public void createOrder(CreateOrderRequest request) {
        // ① 创建订单
        orderMapper.insert(order);

        // ② 扣库存
        product.setStock(product.getStock() - quantity);
        productMapper.updateById(product);

        // ③ 扣余额
        account.setBalance(account.getBalance().subtract(totalAmount));
        accountMapper.updateById(account);

        // 这三个操作在同一个数据库中——同一个事务——要么全成功——要么全回滚
    }
}
```

```
拆成微服务后——同样的流程——@Transactional 失效：

  order-service ──→ 创建订单（自己的数据库）
  product-service ──→ 扣库存（product 数据库）
  account-service ──→ 扣余额（account 数据库）

  每个服务有独立的数据库——三个 @Transactional 是三个独立的事务
  → 订单创建成功——库存扣减成功——但扣余额失败
  → 订单已创建——库存已扣——余额没变——钱还在——但东西已经扣了
  → 数据不一致——用户赚了——公司亏了
```

<strong>分布式事务的本质问题：多个数据库（或服务）的操作——怎么保证"要么全成功、要么全回滚"？</strong>

## 二、🧩 CAP 定理——不是在 C 和 A 之间二选一——P 已经是前提了

### 2.1 CAP 到底在说什么

```
CAP 说的是：在一个分布式系统中——网络分区（P: Partition Tolerance）是不可避免的——
当网络出现分区时——一致性（C: Consistency）和可用性（A: Availability）只能二选一

不是"我选 C 还是选 A"——而是"网络出问题的时候——我优先保 C 还是保 A"
```

```
场景——网络分区发生了：order-service 和 product-service 之间的网络断了

order-service ──╳── product-service
   (能工作)              (能工作——但彼此联系不上)

现在来了一个请求——创建订单——要扣库存

选择 C（一致性）：
  order-service 说："我联系不上 product-service——不能扣库存——这个订单不接"
  → 整个系统拒绝服务——不会出现数据不一致
  → 但用户看到的是——"服务不可用"

选择 A（可用性）：
  order-service 说："联系不上 product-service——但我先接了订单——库存待会儿再扣"
  → 系统继续服务——用户不受影响
  → 但可能出现超卖——"库存不足但订单创建了"——数据不一致

这就是 CAP 的真正含义——网络出问题时——你保哪个？
```

### 2.2 为什么 P 是前提——没得选

```
网络分区（P）不是一个"选择项"——它是分布式系统的物理现实

你没法选择"不要 P"——因为：
  → 你管不了网线——交换机随时可能坏
  → 你管不了光纤——施工队随时可能挖断
  → 你管不了 DNS——解析随时可能超时
  → 你管不了 GC——JVM Full GC 导致 40 秒无响应 = 网络断了 40 秒

只要服务部署在不同的机器上——网络故障就是必然事件——不是小概率事件
→ P 必须选——没得商量

所以 CAP 的实质是：
  → 选 CP：网络出问题时——停服务——保一致性（Nacos CP 模式——银行转账）
  → 选 AP：网络出问题时——继续服务——容忍短暂不一致（Nacos AP 模式——微服务注册）
```

### 2.3 实际上的 CAP——不是黑白——是灰度

```
真实的系统不是"纯 CP"或"纯 AP"——是"不同场景下不同的取舍"

同一个电商系统：
  下单流程 → 选 AP（挂了也要接单——库存扣减异步补偿）
  支付流程 → 选 CP（钱不能错——银行挂了就不支付——不能让用户扣两次钱）
  商品浏览 → 选 AP（少展示几个商品——总比整个页面打不开强）
  用户注册 → 选 CP（一个人不能注册两个账号——冲突了就让用户重试）

不是"整个系统选 C 还是 A"——是"每个业务场景单独选"
```

## 三、🔄 BASE——分布式事务不是 ACID——是另一种东西

### 3.1 ACID vs BASE——思维模型的转换

```
ACID（单体数据库事务）：
  Atomicity   —— 原子性——要么全做——要么全不做
  Consistency —— 一致性——事务前后——数据满足所有约束
  Isolation   —— 隔离性——并发事务互不影响
  Durability  —— 持久性——提交了就不丢

BASE（分布式事务）：
  Basically Available —— 基本可用——挂了也尽量服务——可能降级
  Soft state         —— 软状态——数据有中间状态——不是"要么成功要么失败"——有"进行中"
  Eventually consistent —— 最终一致性——不要求立刻一致——要求一段时间后一致

核心差异：
  ACID 的思维：操作要么全成功——要么全回滚——状态是瞬时的——没有中间状态
  BASE 的思维：操作可能部分成功——有一个"进行中"的软状态——最终通过补偿达到一致
```

```
类比——理解 ACID 和 BASE 的区别：

ACID = 转账——从 ATM 转账 100 元：
  → 扣余额 → 记录流水 → 对方加余额
  → 三步在一个事务中——要么全完成——要么全不完成
  → 不存在"扣了余额但对方没收到"的中间状态

BASE = 网购——你在淘宝买了一个商品：
  → 你付款了（支付宝扣了钱）
  → 商品还没发货（库存还没扣）
  → 商家确认了（库存扣了）
  → 快递送达了（物流状态变了）
  → 你确认收货了（钱打给商家了）

  整个流程持续 3 天——中间有无数个"进行中"的状态
  → 付款了但没发货——这是一个合理的中间状态
  → 最终——3 天后——钱到商家——货到你手里——一致了
  → 中间任何一个环节出错——退款的退款——退货的退货——补偿链
```

<strong>分布式事务不是 ACID 的扩展——它是一个完全不同的思维模型：从事务回滚变成业务补偿。</strong>

## 四、💀 XA 两阶段提交——理论完美——实践死亡

### 4.1 XA 2PC 的工作原理

```
XA 2PC（两阶段提交）——分布式事务的"教科书答案"

阶段一：Prepare（准备）
  ① 协调者问所有参与者："你们准备好提交了吗？"
  ② 每个参与者执行操作——但不提交——锁住资源——回复"准备好了"

阶段二：Commit / Rollback（提交/回滚）
  ③ 协调者收到所有参与者回复
     → 全部准备好了 → 发 Commit——所有人都提交
     → 有一个没准备好 → 发 Rollback——所有人都回滚
```

### 4.2 为什么不能用——三个致命问题

```
致命问题一：性能黑洞——数据库锁住所有的行——等协调者
  order-service 锁 order 表——等协调者回复
  product-service 锁 product 表——等协调者回复
  account-service 锁 account 表——等协调者回复
  → 协调者说"提交"之前——所有行都锁着——其他请求全等

致命问题二：单点故障——协调者挂了——所有人挂
  Prepare 阶段完成——协调者正准备发 Commit——挂了
  → 三个服务的数据库行还锁着——不知道要提交还是回滚
  → 协调者重启之前——这些行永远锁着——其他事务全阻塞
  → 这个状态叫"悬挂"——XA 的死穴

致命问题三：没有补偿能力——只能回滚——不能重试
  库存扣减——回滚就是加回来——可以
  但"发送短信"——回滚怎么回？把短信收回来？做不到
  但"发送短信"失败——应该重试发——而不是回滚——XA 只有回滚——没有重试
```

<strong>结论：XA 2PC 在生产中基本不能用——性能太差——风险太高。只有银行核心系统这种"一致性压倒一切、并发量极低"的场景才可能用。</strong>

## 五、🗺️ 四大方案全景——从同步回滚到异步确保

### 5.1 一张图看懂四种方案的本质区别

```
                       分布式事务方案
                            │
            ┌───────────────┼───────────────┐
            ▼               ▼               ▼
      同步型（回滚）      补偿型（逆向操作）   异步型（最终一致）
            │               │               │
      ┌─────┴─────┐   ┌─────┴─────┐   ┌─────┴─────┐
      │  XA 2PC   │   │ Seata AT │   │ TCC       │   │ 事务消息  │
      │           │   │           │   │           │   │           │
      │ 数据库帮你 │   │ 框架帮你  │   │ 你写补偿  │   │ MQ 确保   │
      │ 回滚      │   │ 自动补偿  │   │ 逻辑      │   │ 投递      │
      │           │   │           │   │           │   │           │
      │ 锁死你    │   │ undo_log  │   │ Try/      │   │ half msg  │
      │           │   │ 自动回滚  │   │ Confirm/  │   │ + check   │
      │            │   │           │   │ Cancel    │   │           │
      └─────────────┘   └─────────────┘   └─────────────┘   └─────────────┘
                              │
                              ▼
                         Saga 模式
                     （长事务编排）
                      编排型/协同型
                      状态机驱动补偿
```

### 5.2 四种方案一句话

| 方案 | 一句话 | 回滚方式 | 代码侵入 | 性能 | 适用 |
|------|------|:---:|:---:|:---:|------|
| <strong>XA 2PC</strong> | 数据库帮你回滚——锁住等所有人 | 数据库自动 | 无 | 极差 | 银行核心——基本不用 |
| <strong>Seata AT</strong> | 框架帮你回滚——undo_log 自动生成反向 SQL | Seata 自动 | 极小——加注解 | 好 | 普通业务——推荐 |
| <strong>TCC</strong> | 你写回滚逻辑——Try/Confirm/Cancel——每个服务自己实现 | 你写 Cancel | 大——每个接口写三套 | 好 | 有严格资源预留需求的场景 |
| <strong>Saga</strong> | 长事务编排——正向执行——失败逆补偿——状态机驱动 | 你写补偿 | 中——只写正向+逆向 | 好 | 流程长——多步跨天 |
| <strong>事务消息</strong> | MQ 保证消息投递——消费者本地事务 + 幂等 | 重试 + 幂等 | 中 | 好 | 异步解耦——推荐 |

### 5.3 选型决策——一张流程图

```mermaid
flowchart TD
    Start["我需要分布式事务吗？"] --> Q1{"涉及几个数据库/服务？"}
    
    Q1 -->|"1 个"| NoNeed["不需要——本地 @Transactional 够了"]
    Q1 -->|"> 1 个"| Q2{"这几个操作必须是\n同步的——还是可以异步？"}
    
    Q2 -->|"可以异步"| MQ["事务消息 + 本地消息表\n最终一致性\nRocketMQ 事务消息"]
    Q2 -->|"必须同步"| Q3{"操作能自动回滚吗？\n就是 UPDATE/INSERT/DELETE"}
    
    Q3 -->|"能——都是 DB 操作"| AT["Seata AT\n框架自动补偿\n代码侵入最小"]
    Q3 -->|"不能——例如调了第三方 API"| Q4{"流程有多长？\n超过 3 步吗？"}
    
    Q4 -->|"短——3 步以内"| TCC["TCC\n手动 Try/Confirm/Cancel\n代码侵入大——但控制力强"]
    Q4 -->|"长——可能跨天"| Saga["Saga\n状态机编排\n正向执行 + 逆补偿"]
    

classDef style_NoNeed fill:#052e16,stroke:#16a34a,stroke-width:2px,color:#bbf7d0;
classDef style_AT fill:#0f172a,stroke:#3b82f6,stroke-width:2px,color:#bfdbfe;
classDef style_MQ fill:#431407,stroke:#ea580c,stroke-width:2px,color:#fed7aa;
classDef style_TCC fill:#450a0a,stroke:#dc2626,stroke-width:2px,color:#fecaca;
classDef style_Saga fill:#2a1147,stroke:#a855f7,stroke-width:2px,color:#ede9fe;
class NoNeed style_NoNeed;
class AT style_AT;
class MQ style_MQ;
class TCC style_TCC;
class Saga style_Saga;```

## 六、💡 最重要的认知——分布式事务不是技术问题——是业务问题

### 6.1 业务上可以容忍"短暂不一致"吗？

```
场景：下单后——库存扣了——但余额没扣——5 分钟后自动补偿成功

技术问题：这 5 分钟内——数据是不一致的
业务问题：这 5 分钟内——用户能做什么？会造成损失吗？

如果业务上能容忍 5 分钟的不一致 → 用最终一致性方案——轻松——成本低
如果业务上不能容忍任何不一致 → 必须用强一致性方案——重——贵——慢

例子：
  电商下单扣库存 → 可以容忍 5 分钟（用户的感知是"系统繁忙——请稍后"）
  银行转账 → 不能容忍任何不一致（一秒钟都不行——必须 T+0 确认）
  机票预订 → 可以容忍——"出票中"是正常的——用户理解
  
关键：不是技术决定用什么方案——是业务决定了可以容忍什么程度的不一致
```

### 6.2 大多数情况下——最终一致性就够了

```
真实的生产数据——阿里双 11：
  → 订单创建和库存扣减——不是强一致的
  → 订单创建后——库存通过异步消息扣减
  → 99.99% 的情况下——1 秒内完成
  → 极少数情况下——库存扣减失败——订单自动取消——退款
  → 用户体验：极少数人看到"订单已退款"——不是"系统不可用"

如果用强一致性：
  → 订单服务等库存服务——库存服务等支付服务——支付服务等风控服务
  → 整个链路任何一个环节慢了——所有人都等着
  → 双 11 峰值——锁等待 + 超时重试——数据库瘫痪

最终一致性不是"技术不行"的妥协——是"高并发下的理性选择"
```

## 🎯 总结

1. <strong>分布式事务的本质是 BASE——不是 ACID 的延伸</strong>：ACID 认为"要么全成功要么全失败——没有中间状态"——BASE 认为"有中间状态——最终通过补偿达到一致"。不是技术变了——是物理规律变了——网络分区不可避免——同步等待不现实。

2. <strong>CAP 不是选 C 还是选 A——是网络出问题了——你优先保哪个</strong>：网络正常时——C 和 A 都有。网络出问题时——保 C（停服务——等数据一致）还是保 A（继续服务——容忍短暂不一致）。每个业务场景单独选——不是整个系统选一个。

3. <strong>XA 2PC 不能用——三个致命问题</strong>：数据库行锁住等协调者（性能黑洞）——协调者挂了所有人锁死（单点故障）——只能回滚不能重试（没有补偿能力）。只有银行核心系统的极低并发场景才可能用。

4. <strong>四种方案的本质区别——谁写回滚逻辑</strong>：XA 是数据库回滚，Seata AT 是框架自动生成反向 SQL 回滚，TCC 是你手动写 Cancel 回滚，事务消息是重试 + 幂等——不涉及回滚。从自动到手动——控制力递增——复杂度也递增。

> 📖 <strong>下一步阅读</strong>：概念搞清楚了——Seata AT 怎么落地？undo_log 表干了什么？全局锁是什么？怎么集成到 order-service + product-service + account-service？继续阅读 [<strong>Seata AT 模式——undo_log 与二阶段原理</strong>]({{< relref "DtSeataAT.md" >}})。
