---
title: "RocketMQ 生产环境部署与调优"
date: 2022-11-12T08:00:00+00:00
tags: ["RocketMQ", "实践教程", "消息队列"]
categories: ["消息队列中间件"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "从单机 Docker 到双主双从高可用集群的完整部署指南：Docker Compose 四节点搭建、Dashboard 可视化监控、JVM/OS/应用层调优参数、10 项上线前检查清单——RocketMQ 系列的最后一站。"
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

# RocketMQ 生产环境部署与调优

> 📖 <strong>前置阅读</strong>：本文是 RocketMQ 系列的终篇，假设读者已经掌握前五篇的全部内容（核心架构、SpringBoot 集成、高级消息类型、可靠性、消费者模式）。

## 一、⚡ 问题切入：单机 Docker 的瓶颈

第一篇搭的单机 RocketMQ（一个 NameServer + 一个 Broker）只能用来学习——生产环境中：

| 单点 | 后果 |
|------|------|
| <strong>一台 NameServer 挂了</strong> | Producer/Consumer 无法获取路由——<strong>整个 MQ 瘫痪</strong> |
| <strong>一台 Broker 挂了</strong> | 所有消息不可用——消息无法发送/消费 |
| <strong>JVM 内存不足</strong> | Full GC 频繁 → 消息延迟抖动 → 超时重试雪崩 |
| <strong>磁盘写满</strong> | CommitLog 无法写入 → 生产者阻塞 |

<strong>生产最低配</strong>：2 台 NameServer + 至少 2 台 Broker（主从）。

## 二、双主双从高可用集群搭建

### 2.1 架构设计

```
NameServer 集群：2 台（互不通信，各自独立）
Broker 集群：2 组主从（Master-A + Slave-A、Master-B + Slave-B）

            NameServer-1          NameServer-2
           (192.168.1.10:9876)   (192.168.1.11:9876)
                  ↑                       ↑
        ┌─────────┴───────┬───────────────┘
        │                 │
   Broker-A (Master)  Broker-A (Slave)
   192.168.1.20:10911  192.168.1.21:10911
   brokerId=0           brokerId=1

   Broker-B (Master)  Broker-B (Slave)
   192.168.1.22:10911  192.168.1.23:10911
   brokerId=0           brokerId=1
```

<strong>路由发现</strong>：Producer/Consumer 配置<strong>所有的 NameServer 地址</strong>——只要有一台 NameServer 活着，路由就能工作。

### 2.2 Docker Compose 双主双从

```yaml
# docker-compose-cluster.yml
version: '3.8'
services:
  # ========== NameServer 集群 ==========
  namesrv1:
    image: apache/rocketmq:5.1.4
    container_name: rocketmq-namesrv1
    command: sh mqnamesrv
    ports:
      - "9876:9876"
    environment:
      - JAVA_OPT_EXT=-Xms512m -Xmx512m

  namesrv2:
    image: apache/rocketmq:5.1.4
    container_name: rocketmq-namesrv2
    command: sh mqnamesrv
    ports:
      - "9877:9876"
    environment:
      - JAVA_OPT_EXT=-Xms512m -Xmx512m

  # ========== Broker-A Master ==========
  broker-a-m:
    image: apache/rocketmq:5.1.4
    container_name: rocketmq-broker-a-m
    command: sh mqbroker -c /home/rocketmq/conf/broker-a-m.conf
    ports:
      - "11911:11911"   # remoting
      - "11909:11909"   # VIP channel
    volumes:
      - ./conf/broker-a-m.conf:/home/rocketmq/rocketmq-5.1.4/conf/broker-a-m.conf
      - ./data/broker-a-m:/home/rocketmq/store
    environment:
      - JAVA_OPT_EXT=-Xms2g -Xmx2g

  # ========== Broker-A Slave ==========
  broker-a-s:
    image: apache/rocketmq:5.1.4
    container_name: rocketmq-broker-a-s
    command: sh mqbroker -c /home/rocketmq/conf/broker-a-s.conf
    ports:
      - "12911:12911"
      - "12909:12909"
    volumes:
      - ./conf/broker-a-s.conf:/home/rocketmq/rocketmq-5.1.4/conf/broker-a-s.conf
      - ./data/broker-a-s:/home/rocketmq/store
    environment:
      - JAVA_OPT_EXT=-Xms2g -Xmx2g

  # ========== Dashboard ==========
  dashboard:
    image: apacherocketmq/rocketmq-dashboard:1.0.1
    container_name: rocketmq-dashboard
    ports:
      - "8080:8080"
    environment:
      - JAVA_OPTS=-Drocketmq.namesrv.addr=namesrv1:9876;namesrv2:9876
```

关键配置文件：

```properties
# conf/broker-a-m.conf —— Master-A
brokerClusterName = DefaultCluster
brokerName = broker-a           # Broker组名——同一组的Master和Slave用同一个名字
brokerId = 0                    # 0=Master, 非0=Slave
brokerRole = SYNC_MASTER        # 同步主从
flushDiskType = ASYNC_FLUSH     # 异步刷盘（可靠性交给主从同步）
namesrvAddr = namesrv1:9876;namesrv2:9876   # 两个 NameServer
listenPort = 11911
storePathRootDir = /home/rocketmq/store
storePathCommitLog = /home/rocketmq/store/commitlog
autoCreateTopicEnable = false   # 生产环境关闭——Topic 必须手动创建
```

```properties
# conf/broker-a-s.conf —— Slave-A
brokerClusterName = DefaultCluster
brokerName = broker-a           # 和 Master 同一个 brokerName
brokerId = 1                    # 非 0 表示 Slave
brokerRole = SLAVE
flushDiskType = ASYNC_FLUSH
namesrvAddr = namesrv1:9876;namesrv2:9876
listenPort = 12911
storePathRootDir = /home/rocketmq/store
```

> ⚠️ 新手提示：Master 和 Slave 必须使用<strong>相同的 `brokerName`</strong>——这是 RocketMQ 识别它们属于同一组主从的唯一方式。Master 的 `brokerId=0`，Slave 的 `brokerId` 为任意非 0 整数。

### 2.3 手动创建 Topic

生产环境建议关闭 `autoCreateTopicEnable`，手动创建 Topic：

```bash
# 进入 Broker 容器创建 Topic
docker exec -it rocketmq-broker-a-m sh mqadmin updateTopic \
  -n namesrv1:9876 \
  -t order-topic \          # Topic 名称
  -c DefaultCluster \       # 集群名
  -w 8 \                    # 写 Queue 数
  -r 8                      # 读 Queue 数（通常和写一致）

# 验证
docker exec -it rocketmq-broker-a-m sh mqadmin topicList \
  -n namesrv1:9876
```

## 三、Dashboard 监控

RocketMQ Dashboard 是一个 Web 管理界面，功能比 RabbitMQ 管理界面更丰富：

```
访问 http://192.168.1.20:8080
```

<strong>核心页面</strong>：

| Tab | 看什么 | 为什么要看 |
|-----|--------|-----------|
| <strong>Cluster</strong> | Broker 列表、主从关系、同步状态 | Broker 是否存活、主从同步是否正常 |
| <strong>Topic</strong> | 每个 Topic 的消息量、TPS、Queue 分布 | 哪些 Topic 流量异常 |
| <strong>Consumer</strong> | 消费者组列表、消费 TPS、积压量 (Diff) | <strong>最关键的指标——Diff 持续增长 = 消费跟不上生产</strong> |
| <strong>Message</strong> | 按 msgId/key/Topic 查询消息内容 | 排查"这条消息去哪了" |
| <strong>Message Trace</strong> | 消息的生产→存储→消费全链路轨迹 | 排查延迟瓶颈在哪个环节 |

<strong>必须盯住的三根线</strong>：

| 指标 | Dashboard 看哪里 | 告警阈值 |
|------|-----------------|:---:|
| 消费积压 (Diff) | Consumer → Diff 列 | Diff > Topic 日均消息量的 2 倍 |
| Broker TPS | Topic → 各 Broker 的 TPS | 接近 Broker 单机上限（约 5 万/s） |
| 磁盘使用 | Cluster → Broker 详情 → 磁盘使用 | > 80% |

## 四、性能调优

### 4.1 JVM 调优

RocketMQ Broker 是 Java 进程——GC 停顿直接影响消息延迟：

```bash
# Broker 的 JVM 参数（docker-compose 中 environment 段）
JAVA_OPT_EXT=-Xms4g -Xmx4g \
  -XX:+UseG1GC \                           # 用 G1 GC（低延迟）
  -XX:G1HeapRegionSize=16m \               # G1 region 大小
  -XX:MaxGCPauseMillis=200 \               # 目标 GC 停顿 < 200ms
  -XX:InitiatingHeapOccupancyPercent=45 \  # 堆使用 45% 开始并发标记
  -XX:+PrintGCDetails \
  -XX:+PrintGCDateStamps
```

### 4.2 OS 调优

```bash
# 虚拟内存——防止 CommitLog 写入时 OOM
sysctl -w vm.min_free_kbytes=1048576

# 最大文件句柄数——CommitLog 和 ConsumeQueue 需要大量文件描述符
ulimit -n 65536
```

### 4.3 应用层——SpringBoot 生产者调优

```yaml
rocketmq:
  name-server: namesrv1:9876;namesrv2:9876
  producer:
    group: order-producer-group
    # 发送超时（ms）——同步发送时最关键
    send-message-timeout: 5000
    # 重试次数——生产端重试，不是消费端
    retry-times-when-send-failed: 3
    retry-times-when-send-async-failed: 3
    # 客户端线程池大小
    compress-message-body-threshold: 4096
    # 消息体超过此大小自动压缩
    max-message-size: 4194304
```

### 4.4 应用层——SpringBoot 消费者调优

```java
@RocketMQMessageListener(
    topic = "order-topic",
    consumerGroup = "order-consumer-group",
    consumeThreadNumber = 30,           // 消费线程数——不是越大越好
    consumeMessageBatchMaxSize = 32,    // 每次拉取最多 32 条
    maxReconsumeTimes = 5              // 最大重试次数——不要总用默认 16 次
)
```

| 参数 | 调大 | 调小 | 默认值 |
|------|------|------|:---:|
| `consumeThreadNumber` | 计算密集型消费 | I/O 密集型消费（如调外部 API） | 20 |
| `consumeMessageBatchMaxSize` | 消息体小，批处理收益大 | 消息体大或消费耗时不可控 | 32 |
| `maxReconsumeTimes` | — | 快速失败而不是长时间重试 | 16 |

> ⚠️ 新手提示：`consumeThreadNumber` 不要设成几百——消费线程是需要 CPU 时间片的。RocketMQ 建议<strong>最多 64 个线程</strong>。实际经验：20 ~ 40 足够覆盖绝大多数场景。

## 五、常见生产故障

| 故障 | 现象 | 排查 |
|------|------|------|
| <strong>消费积压（Lag）</strong> | Dashboard Consumer Diff 持续增长 | ① 消费线程数是否够 ② 消费逻辑是否有慢调用 ③ 增加 Queue 数 ④ 增加消费者实例 |
| <strong>消息延迟抖动</strong> | 生产 TPS 周期性下降 | ① Broker GC 日志检查 ② 是否到磁盘写入瓶颈 ③ `vmstat 1` 看 IO 等待 |
| <strong>No route info</strong> | 生产者发送报错 "No route info of this topic" | ① Topic 是否手动创建了 ② Broker 的 `autoCreateTopicEnable=true` 是否已开 ③ NameServer 地址配全了吗 |
| <strong>Rebalance 风暴</strong> | 消费者日志频繁 Rebalance | ① 消费者实例是否频繁重启 ② 网络是否稳定（心跳 30s，超时 2min）③ `clientCallbackExecutorThreads` 是否太小 |
| <strong>消费失败循环</strong> | 同一条消息反复重试 | ① 代码 Bug——同一输入不可能重试成功 ② `maxReconsumeTimes` 设小一些 ③ 检查为啥不满足进死信的条件 |
| <strong>磁盘写满</strong> | Broker 日志 "disk full" | ① `fileReservedTime` 调小（默认 72h）② 扩大磁盘 ③ 监控盘使用率 |

## 六、上线前 10 项检查清单

| # | 检查项 | 配置/命令 |
|:--:|--------|----------|
| 1 | NameServer 至少 2 台 | Docker Compose 中起两个实例 |
| 2 | 关键 Topic 的 Broker 配主从 | `brokerRole=SYNC_MASTER` |
| 3 | `autoCreateTopicEnable=false` | Topic 必须手动创建——防止业务代码写错 Topic 名 |
| 4 | 关键业务的 Queue 数 ≥ 预期最大消费者实例数 | 创建时一步到位——Queue 只增不减 |
| 5 | 消费者 `maxReconsumeTimes` 按业务设（不是默认 16） | 不重要的业务 3~5 次够了 |
| 6 | 配好死信消费者 | 监听 `%DLQ%{consumerGroup}`，进死信就告警 |
| 7 | NameServer 地址用分号分隔配全 | `namesrv1:9876;namesrv2:9876` |
| 8 | 接入 Prometheus + Grafana 或 Dashboard | 最少盯住消费积压 (Diff) |
| 9 | Broker JVM 堆内存 ≥ 2G | `-Xms2g -Xmx2g` |
| 10 | Broker 磁盘使用率告警 < 80% | Monitor 脚本定时检查 |

## 七、RocketMQ vs RabbitMQ 最终选型

六篇学完了 RabbitMQ，六篇学完了 RocketMQ。实际选型时：

| 场景 | 选谁 | 理由 |
|------|:---:|------|
| 有事务消息需求（下单+扣库存+通知） | <strong>RocketMQ</strong> | RabbitMQ 没有原生实现 |
| 需要海量吞吐（> 10万 msg/s） | <strong>RocketMQ</strong> | CommitLog 顺序写碾压随机写 |
| 路由逻辑极度灵活（一个消息按多种规则分发给不同消费者） | <strong>RabbitMQ</strong> | Exchange + Binding 模型比 Topic+Tag 灵活 |
| 小团队，运维简单 | <strong>RabbitMQ</strong> | 单 Docker 即可，管理界面直观 |
| Java 技术栈，需要深度定制 | <strong>RocketMQ</strong> | 全部 Java 实现，二次开发方便 |
| 云厂商托管 | 阿里云 → RocketMQ；AWS → RabbitMQ | 云厂商决定了用什么 |

## 🎯 总结

RocketMQ 的生产部署核心在三点：

1. <strong>高可用架构</strong>：至少 2 个 NameServer（互不通信）+ 至少 1 组主从 Broker（`SYNC_MASTER`）。NameServer 地址用分号分隔全配——只要有一台活着路由就能工作。

2. <strong>Dashboard 监控</strong>：消费积压 (Diff) 是最关键的指标——持续增长说明消费跟不上生产。Dashboard 的 Message Trace 可以追踪一条消息的完整生命周期。

3. <strong>调优常识</strong>：Broker JVM 用 G1GC + 堆 ≥ 2G，OS 调大文件句柄，消费线程 20 ~ 40 足够，`maxReconsumeTimes` 不超过业务容忍上限。

---

## 📖 系列总览

RocketMQ 六篇系列到此结束：

| # | 篇 | 核心收获 |
|:--:|------|---------|
| 1 | [<strong>核心架构与消息模型</strong>]({{< relref "RocketMQFundamentals.md" >}}) | NameServer 去中心化路由、CommitLog 顺序写、Topic+Queue+Tag 三级分类 |
| 2 | [<strong>SpringBoot 全操作指南</strong>]({{< relref "SpringBootRocketMQ.md" >}}) | RocketMQTemplate 三模式发送、@RocketMQMessageListener 消费、订单消息实战 |
| 3 | [<strong>顺序/延迟/事务消息</strong>]({{< relref "AdvancedMessages.md" >}}) | 18 级延迟、半消息 + 回查事务消息、顺序消费的挂起重试 |
| 4 | [<strong>消息可靠性与容错</strong>]({{< relref "MessageReliability.md" >}}) | 刷盘策略、主从同步、16 次递增重试、%DLQ% 死信、幂等 |
| 5 | [<strong>消费者模式与过滤器</strong>]({{< relref "ConsumerPatterns.md" >}}) | 集群/广播、Push(长轮询Pull)、Tag/SQL92 过滤、Rebalance |
| 6 | [<strong>生产环境部署与调优</strong>]({{< relref "ProductionDeployment.md" >}}) | 双主双从集群、Dashboard 监控、JVM/OS 调优、10 项检查清单 |

<strong>建议从 1 到 6 顺序阅读</strong>，每篇以前一篇为前提。学完这六篇，从基本概念到生产部署的全链路都覆盖了。
