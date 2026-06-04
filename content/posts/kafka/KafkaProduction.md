---
title: "Kafka 生产环境部署与调优"
date: 2022-11-18T08:00:00+00:00
tags: ["消息队列"]
categories: ["消息队列中间件"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "从单节点 Docker 到 KRaft 三节点集群的完整部署指南：Docker Compose 多 Controller 选举、JVM/OS 调优参数、Producer/Consumer/Broker 层性能优化、Prometheus + Grafana 监控配置、10 项上线前检查清单——Kafka 系列的最后一站。"
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

# Kafka 生产环境部署与调优

> 📖 <strong>前置阅读</strong>：本文是 Kafka 系列的终篇，假设读者已经掌握前五篇的全部内容（核心架构、SpringBoot 集成、Producer 深入、Consumer 深入、Kafka Streams）。

## 一、⚡ 问题切入：单节点 Docker 的瓶颈

第一篇搭的单节点 KRaft Kafka（一个 Controller + Broker 合体进程）只能用来学习——生产环境中：

| 单点 | 后果 |
|------|------|
| <strong>唯一的 Broker 挂了</strong> | 所有消息不可发送/消费——整个 Kafka 瘫痪 |
| <strong>无副本</strong> | Broker 磁盘损坏 → 消息永久丢失 |
| <strong>JVM 内存不足</strong> | Full GC 频繁 → 消息延迟抖动 → Producer 超时失败 |
| <strong>磁盘写满</strong> | Partition 无法写入 → Producer 阻塞或报错 |

<strong>生产最低配</strong>：3 台 Broker + 3 台 Controller（或 3 台合体节点，controller + broker 混合模式），每个 Topic 至少 2 副本。

## 二、KRaft 三节点集群搭建

### 2.1 架构设计

第一篇用的 KRaft 模式是单节点（Controller 和 Broker 运行在一个进程中）。生产环境拆开：

```
KRaft Controller Quorum（3 台——负责元数据管理和选举）：
    Controller-1  (node.id=1)
    Controller-2  (node.id=2)
    Controller-3  (node.id=3)

Broker 集群（3 台——负责数据存储和分发）：
    Broker-1  (node.id=11)
    Broker-2  (node.id=12)
    Broker-3  (node.id=13)

Topic 副本分布（replication.factor=3）：
    Partition-0: Leader=Broker-1, Follower=Broker-2, Broker-3
    Partition-1: Leader=Broker-2, Follower=Broker-3, Broker-1
    Partition-2: Leader=Broker-3, Follower=Broker-1, Broker-2
```

<strong>为什么 Controller 最少 3 台？</strong> KRaft 使用 Raft 共识算法——3 台 Controller 可以容忍 1 台宕机（(3-1)/2 = 1 台）。5 台可以容忍 2 台。

### 2.2 Docker Compose 三节点

```yaml
# docker-compose-kraft.yml
version: '3.8'
services:
  # ========== Controller 节点 ==========
  controller-1:
    image: apache/kafka:3.7.0
    container_name: kafka-controller-1
    environment:
      KAFKA_NODE_ID: 1
      KAFKA_PROCESS_ROLES: controller
      KAFKA_LISTENERS: CONTROLLER://0.0.0.0:29093
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@controller-1:29093,2@controller-2:29093,3@controller-3:29093
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
    ports:
      - "29093:29093"
    volumes:
      - ./data/controller-1:/var/lib/kafka/data

  controller-2:
    image: apache/kafka:3.7.0
    container_name: kafka-controller-2
    environment:
      KAFKA_NODE_ID: 2
      KAFKA_PROCESS_ROLES: controller
      KAFKA_LISTENERS: CONTROLLER://0.0.0.0:29093
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@controller-1:29093,2@controller-2:29093,3@controller-3:29093
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
    ports:
      - "29094:29093"
    volumes:
      - ./data/controller-2:/var/lib/kafka/data

  controller-3:
    image: apache/kafka:3.7.0
    container_name: kafka-controller-3
    environment:
      KAFKA_NODE_ID: 3
      KAFKA_PROCESS_ROLES: controller
      KAFKA_LISTENERS: CONTROLLER://0.0.0.0:29093
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@controller-1:29093,2@controller-2:29093,3@controller-3:29093
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
    ports:
      - "29095:29093"
    volumes:
      - ./data/controller-3:/var/lib/kafka/data

  # ========== Broker 节点 ==========
  broker-1:
    image: apache/kafka:3.7.0
    container_name: kafka-broker-1
    depends_on:
      - controller-1
      - controller-2
      - controller-3
    environment:
      KAFKA_NODE_ID: 11
      KAFKA_PROCESS_ROLES: broker
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9092
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://localhost:9092
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@controller-1:29093,2@controller-2:29093,3@controller-3:29093
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_LOG_DIRS: /var/lib/kafka/data
      KAFKA_NUM_PARTITIONS: 6           # 默认 Partition 数
      KAFKA_DEFAULT_REPLICATION_FACTOR: 3  # 默认副本数
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 3  # __consumer_offsets 的副本数
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 3
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 2
      KAFKA_MIN_INSYNC_REPLICAS: 2      # 最少 ISR 副本数
      KAFKA_LOG_RETENTION_HOURS: 72      # 消息保留 72 小时
      KAFKA_LOG_SEGMENT_BYTES: 1073741824  # 1GB Segment
      KAFKA_AUTO_CREATE_TOPICS_ENABLE: "false"
      KAFKA_HEAP_OPTS: "-Xms4g -Xmx4g"
    ports:
      - "9092:9092"
    volumes:
      - ./data/broker-1:/var/lib/kafka/data

  broker-2:
    image: apache/kafka:3.7.0
    container_name: kafka-broker-2
    depends_on:
      - controller-1
      - controller-2
      - controller-3
    environment:
      KAFKA_NODE_ID: 12
      KAFKA_PROCESS_ROLES: broker
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9093
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://localhost:9093
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@controller-1:29093,2@controller-2:29093,3@controller-3:29093
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_LOG_DIRS: /var/lib/kafka/data
      KAFKA_NUM_PARTITIONS: 6
      KAFKA_DEFAULT_REPLICATION_FACTOR: 3
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 3
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 3
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 2
      KAFKA_MIN_INSYNC_REPLICAS: 2
      KAFKA_LOG_RETENTION_HOURS: 72
      KAFKA_LOG_SEGMENT_BYTES: 1073741824
      KAFKA_AUTO_CREATE_TOPICS_ENABLE: "false"
      KAFKA_HEAP_OPTS: "-Xms4g -Xmx4g"
    ports:
      - "9093:9093"
    volumes:
      - ./data/broker-2:/var/lib/kafka/data

  broker-3:
    image: apache/kafka:3.7.0
    container_name: kafka-broker-3
    depends_on:
      - controller-1
      - controller-2
      - controller-3
    environment:
      KAFKA_NODE_ID: 13
      KAFKA_PROCESS_ROLES: broker
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:9094
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://localhost:9094
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@controller-1:29093,2@controller-2:29093,3@controller-3:29093
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_LOG_DIRS: /var/lib/kafka/data
      KAFKA_NUM_PARTITIONS: 6
      KAFKA_DEFAULT_REPLICATION_FACTOR: 3
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 3
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 3
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 2
      KAFKA_MIN_INSYNC_REPLICAS: 2
      KAFKA_LOG_RETENTION_HOURS: 72
      KAFKA_LOG_SEGMENT_BYTES: 1073741824
      KAFKA_AUTO_CREATE_TOPICS_ENABLE: "false"
      KAFKA_HEAP_OPTS: "-Xms4g -Xmx4g"
    ports:
      - "9094:9094"
    volumes:
      - ./data/broker-3:/var/lib/kafka/data
```

<strong>关键配置解释</strong>：

| 配置 | 含义 | 值 | 原因 |
|------|------|:---:|------|
| `KAFKA_PROCESS_ROLES` | 节点角色 | `controller` / `broker` / `controller,broker`（混合） | 生产建议分离 |
| `KAFKA_CONTROLLER_QUORUM_VOTERS` | 参与 Raft 选举的节点列表 | `1@host1:29093,2@host2:29093,...` | <strong>三个节点名字和端口必须完全一致——每个节点上配置相同</strong> |
| `num.partitions` | 新 Topic 默认 Partition 数 | `6` | 不小于预期消费者实例数 |
| `default.replication.factor` | 新 Topic 默认副本数 | `3` | 容忍 2 台 Broker 宕机 |
| `min.insync.replicas` | 最少 ISR 副本数 | `2` | 配合 `acks=all`——至少 2 个副本确认 |
| `offsets.topic.replication.factor` | `__consumer_offsets` 的副本数 | `3` | Offset 也是数据——不能丢 |
| `log.retention.hours` | 消息保留时间 | `72` | 根据业务需要和磁盘容量调整 |
| `auto.create.topics.enable` | 自动创建 Topic | `false` | 生产环境关闭——Topic 必须手动创建，防止业务代码写错 Topic 名 |

### 2.3 启动与验证

```bash
# 1. 格式化存储目录（每个节点都需格式化——和第一篇单节点一样）
docker run --rm -v $(pwd)/data/controller-1:/var/lib/kafka/data \
  apache/kafka:3.7.0 \
  /opt/kafka/bin/kafka-storage.sh format \
  --config /etc/kafka/server.properties \
  --cluster-id $(uuidgen)
# 重复 controller-2, controller-3, broker-1, broker-2, broker-3

# 2. 启动集群
docker compose -f docker-compose-kraft.yml up -d

# 3. 验证 Controller Quorum
docker exec kafka-controller-1 \
  /opt/kafka/bin/kafka-metadata-quorum.sh --snapshot \
  --bootstrap-server localhost:9092 describe
# 预期输出：3 voters, LeaderId=1

# 4. 验证 Broker 已注册
docker exec kafka-broker-1 \
  /opt/kafka/bin/kafka-metadata-quorum.sh --snapshot \
  --bootstrap-server localhost:9092 describe \
  | grep -E "Broker-11|Broker-12|Broker-13"

# 5. 创建测试 Topic
docker exec kafka-broker-1 \
  /opt/kafka/bin/kafka-topics.sh --create \
  --topic test-topic \
  --bootstrap-server localhost:9092 \
  --partitions 6 \
  --replication-factor 3

# 6. 验证 Topic 的副本分布
docker exec kafka-broker-1 \
  /opt/kafka/bin/kafka-topics.sh --describe \
  --topic test-topic \
  --bootstrap-server localhost:9092

# 预期输出（6 个 Partition × 3 个副本）：
# Partition: 0    Leader: 11   Replicas: 11,12,13   Isr: 11,12,13
# Partition: 1    Leader: 12   Replicas: 12,13,11   Isr: 12,13,11
# ...
```

> ⚠️ 新手提示：`KAFKA_CONTROLLER_QUORUM_VOTERS` 中每个节点的名字（如 `controller-1`）必须能被其他节点通过 Docker 网络解析。如果 Broker 和 Controller 不在同一台宿主机上，需要用真实 IP 或 DNS。`localhost` 在这里不适用——Docker 容器内的 localhost 是容器自己。

### 2.4 手动创建 Topic

```bash
# 创建订单 Topic：6 个 Partition，3 个副本
docker exec kafka-broker-1 \
  /opt/kafka/bin/kafka-topics.sh --create \
  --topic order-topic \
  --bootstrap-server localhost:9092 \
  --partitions 6 \
  --replication-factor 3 \
  --config min.insync.replicas=2 \
  --config retention.ms=259200000   # 72 小时

# 创建紧凑 Topic（维表）
docker exec kafka-broker-1 \
  /opt/kafka/bin/kafka-topics.sh --create \
  --topic product-info-topic \
  --bootstrap-server localhost:9092 \
  --partitions 3 \
  --replication-factor 3 \
  --config cleanup.policy=compact
```

## 三、性能调优

### 3.1 Broker JVM 调优

Kafka Broker 是 Scala/Java 进程——GC 直接决定消息延迟的稳定性：

```bash
# Broker JVM 参数
KAFKA_HEAP_OPTS="-Xms6g -Xmx6g \
  -XX:+UseG1GC \
  -XX:MaxGCPauseMillis=20 \
  -XX:InitiatingHeapOccupancyPercent=35 \
  -XX:G1HeapRegionSize=16m \
  -XX:MetaspaceSize=96m \
  -XX:MinMetaspaceFreeRatio=50 \
  -XX:MaxMetaspaceFreeRatio=80"
```

| 参数 | 含义 | 建议值 |
|------|------|------|
| `-Xms6g -Xmx6g` | 堆内存——生产至少 4G | 4G ~ 8G（超过 8G 收益递减） |
| `-XX:+UseG1GC` | G1 垃圾回收器——低延迟 | 必选 |
| `-XX:MaxGCPauseMillis=20` | 目标 GC 停顿 < 20ms | 20 ~ 50 |
| `-XX:InitiatingHeapOccupancyPercent=35` | 堆使用 35% 开始并发标记 | 35 ~ 45 |

<strong>Kafka 对堆大小不敏感</strong>——它的高性能来自 PageCache（OS 管理的磁盘缓存），不是堆。堆主要存 Producer 的缓冲区和 Consumer Group 元数据。所以 <strong>不要给 Kafka 64G 堆</strong>——留给 OS PageCache 效果更好。

### 3.2 OS 调优

```bash
# 1. 虚拟内存——避免 PageCache 过于激进
sysctl -w vm.swappiness=1         # 尽量不用 swap——PageCache 比 swap 快
sysctl -w vm.dirty_ratio=10       # 脏页比例上限
sysctl -w vm.dirty_background_ratio=5  # 后台刷盘比例

# 2. 文件句柄——Kafka 大量使用文件系统（每个 Segment 一个 fd）
ulimit -n 100000

# 3. 文件系统——推荐 XFS（ext4 也可以）
# mount -o noatime /dev/sdb1 /data/kafka
```

| 参数 | 含义 | 为什么重要 |
|------|------|------|
| `vm.swappiness=1` | 尽量不用 swap | Kafka 的数据在 PageCache 里——swap 到磁盘等于数据读写全部变慢 100 倍 |
| `vm.dirty_ratio` | 脏页占内存上限 | 控制写缓冲——不会因为刷盘阻塞读写 |
| `ulimit -n 100000` | 最大文件句柄数 | 每个 Segment 文件一个 fd + 网络连接——128K 是常见配置 |
| `noatime` | 不记录文件访问时间 | 每次读文件不更新 atime——减少磁盘写入 |

### 3.3 Broker 端配置调优

```properties
# ===== 网络线程 =====
num.network.threads=8          # 处理网络请求的线程数
num.io.threads=16              # 处理磁盘 I/O 的线程数

# ===== PageCache 相关 =====
log.flush.interval.messages=9223372036854775807  # 不要按消息数刷盘——交给 OS
log.flush.interval.ms=9223372036854775807
# Kafka 的持久化靠副本，不靠刷盘——依赖 OS PageCache

# ===== 副本同步 =====
num.replica.fetchers=4         # 复制线程数——增加可以加速副本同步

# ===== 日志清理 =====
log.cleaner.threads=2          # Log Compaction 线程数
log.segment.bytes=1073741824   # 1GB——Segment 大小
log.segment.ms=604800000       # 7 天——Segment 滚动时间

# ===== Socket =====
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600  # 100MB——最大请求大小
```

### 3.4 Producer 端调优（复习 + 生产建议）

```yaml
spring:
  kafka:
    bootstrap-servers: localhost:9092,localhost:9093,localhost:9094
    producer:
      acks: all
      retries: 2147483647        # Integer.MAX_VALUE——依赖 delivery.timeout.ms 控制
      batch-size: 131072         # 128KB
      linger-ms: 5               # 低延迟场景：5ms；高吞吐场景：20ms
      compression-type: lz4
      properties:
        enable.idempotence: true
        max.in.flight.requests.per.connection: 5
        delivery.timeout.ms: 120000   # 2 分钟内完成发送（含重试）
        request.timeout.ms: 30000     # 单次请求超时 30s
```

### 3.5 Consumer 端调优（复习 + 生产建议）

```yaml
spring:
  kafka:
    bootstrap-servers: localhost:9092,localhost:9093,localhost:9094
    consumer:
      group-id: order-consumer-group
      enable-auto-commit: false
      max-poll-records: 100       # 不要太激进——500 可能超 max.poll.interval.ms
      auto-offset-reset: earliest
      properties:
        partition.assignment.strategy:
          org.apache.kafka.clients.consumer.CooperativeStickyAssignor
        session.timeout.ms: 45000
        max.poll.interval.ms: 600000  # 10 分钟——留足处理时间
    listener:
      ack-mode: manual_immediate
```

## 四、监控

### 4.1 Kafka Exporter + Prometheus + Grafana

```yaml
# 在 docker-compose-kraft.yml 中加入 Prometheus Exporter
  kafka-exporter:
    image: danielqsj/kafka-exporter:latest
    container_name: kafka-exporter
    command:
      - "--kafka.server=broker-1:9092"
      - "--kafka.server=broker-2:9093"
      - "--kafka.server=broker-3:9094"
    ports:
      - "9308:9308"

  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
    ports:
      - "9090:9090"

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin123
```

### 4.2 必须盯住的五个指标

| 指标 | Prometheus 查询 | 告警阈值 | 为什么重要 |
|------|------|:---:|------|
| <strong>Consumer Lag</strong> | `kafka_consumergroup_lag` | Lag > 预期消息量的 2 倍 | 最关键的指标——消费跟不上生产 |
| <strong>Under Replicated Partitions</strong> | `kafka_server_replicamanager_underreplicatedpartitions` | > 0 | 有 Partition 副本数不足——可靠性下降 |
| <strong>Active Controller Count</strong> | `kafka_controller_kafkacontroller_activecontrollercount` | ≠ 1 | 没有 Controller 或多于一个——集群异常 |
| <strong>Offline Partitions</strong> | `kafka_controller_kafkacontroller_offlinepartitionscount` | > 0 | 有 Partition 无 Leader——那些 Partition 不可读写 |
| <strong>Disk Usage</strong> | Node Exporter `node_filesystem_avail_bytes` | > 80% | 磁盘满了就写不进去了 |

### 4.3 命令行监控工具

```bash
# Broker 指标——每个 Topic 的 TPS
docker exec kafka-broker-1 \
  /opt/kafka/bin/kafka-broker-api-versions.sh \
  --bootstrap-server localhost:9092

# ConsumerGroup 状态——Lag 查询（最重要）
docker exec kafka-broker-1 \
  /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --group order-consumer-group \
  --describe

# Topic 级别——Partition 分布和 ISR 状态
docker exec kafka-broker-1 \
  /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --describe \
  --topic order-topic

# 查看 Topic 消息量
docker exec kafka-broker-1 \
  /opt/kafka/bin/kafka-run-class.sh \
  kafka.tools.GetOffsetShell \
  --bootstrap-server localhost:9092 \
  --topic order-topic
```

## 五、常见生产故障

| 故障 | 现象 | 排查 |
|------|------|------|
| <strong>消费积压（Lag）</strong> | `kafka-consumer-groups --describe` 的 LAG 持续增长 | ① Consumer 是否在运行 `kafka-consumer-groups --describe` ② `concurrency` 是否小于 Partition 数 ③ 消费逻辑是否有慢调用 ④ 增加 Partition 数 + Consumer 实例 |
| <strong>Producer 发送超时</strong> | `org.apache.kafka.common.errors.TimeoutException` | ① `bootstrap.servers` 中是否有可达的 Broker ② `delivery.timeout.ms` 是否够 ③ `max.block.ms` 是否太短 |
| <strong>Under Replicated</strong> | `kafka-topics --describe` 中 ISR < Replicas | ① Broker 是否有宕机 ② 网络是否稳定（Broker 间通信） ③ `num.replica.fetchers` 是否太少 |
| <strong>Offline Partition</strong> | Producer 发送时报 `NOT_LEADER_OR_FOLLOWER` | ① 查看哪些 Broker 挂了 ② 查看 Controller 日志 ③ `unclean.leader.election.enable=false` 确保不丢数据（但可能牺牲可用性） |
| <strong>磁盘写满</strong> | Broker 日志 `LogDirFailureChannel` | ① `log.retention.hours` 调小 ② 检查 Log Compaction 是否生效 ③ 增加磁盘或清理旧数据 |
| <strong>KRaft 脑裂</strong> | Controller 日志 `NotLeaderException` | ① 检查 `controller.quorum.voters` 配置是否一致 ② 检查网络是否正常——Controller 之间通信不可达 |

## 六、上线前 10 项检查清单

| # | 检查项 | 配置/命令 |
|:--:|--------|----------|
| 1 | Controller Quorum ≥ 3 台 | `docker-compose-kraft.yml` 中 3 个 controller 服务 |
| 2 | Broker ≥ 3 台 | `docker-compose-kraft.yml` 中 3 个 broker 服务 |
| 3 | `auto.create.topics.enable=false` | Broker 配置——Topic 必须手动创建 |
| 4 | 关键 Topic 的 `replication.factor=3` | `kafka-topics --describe` 确认 |
| 5 | `min.insync.replicas=2` | Broker 配置——配合 `acks=all` |
| 6 | Producer 开启幂等 | `enable.idempotence=true` |
| 7 | Consumer 使用 CooperativeSticky | `partition.assignment.strategy=CooperativeStickyAssignor` |
| 8 | Consumer 手动提交 Offset | `enable-auto-commit=false` + `ack-mode=manual_immediate` |
| 9 | 接入 Prometheus + Grafana 或至少盯住 Lag | Kafka Exporter + Prometheus + Grafana Dashboard |
| 10 | Broker JVM 堆 ≥ 4G，OS 文件句柄 ≥ 100K | `KAFKA_HEAP_OPTS="-Xms4g -Xmx4g"` + `ulimit -n 100000` |

## 七、Kafka vs RocketMQ vs RabbitMQ 最终选型

六篇 RabbitMQ + 六篇 RocketMQ + 六篇 Kafka。实际选型时：

| 场景 | 选谁 | 理由 |
|------|:---:|------|
| 需要<strong>消息重放</strong>、事件溯源 | <strong>Kafka</strong> | 核心设计目标——消费后消息不删除 |
| 需要<strong>海量吞吐</strong>（> 100 万 msg/s） | <strong>Kafka</strong> | 零拷贝 + 顺序读写 + 分区并行 |
| 需要<strong>流处理</strong>（聚合、Join、窗口） | <strong>Kafka</strong> | Kafka Streams 原生库——不依赖外部系统 |
| 需要<strong>事务消息</strong>（下单+扣库存+通知） | <strong>RocketMQ</strong> | 半消息 + 回查——原生灵活的事务模型 |
| 需要<strong>灵活路由</strong>（一个消息按多种规则分发） | <strong>RabbitMQ</strong> | Exchange + Binding 模型最灵活 |
| 小团队，运维简单 | <strong>RabbitMQ</strong> | 单 Docker 即可，管理界面直观 |
| Java 技术栈，需要深度定制 | <strong>RocketMQ</strong> | 全部 Java 实现，二次开发方便 |
| 云厂商托管 | 阿里云 → RocketMQ；AWS → MSK (Kafka) | 云厂商决定了用什么 |

## 🎯 总结

Kafka 的生产部署核心在四点：

1. <strong>KRaft 高可用架构</strong>：至少 3 台 Controller（Raft 仲裁） + 3 台 Broker。`process.roles` 生产级建议分离，但混合模式也可以。`controller.quorum.voters` 在所有节点上配置必须一致。

2. <strong>核心可靠性配置</strong>：`replication.factor=3` + `min.insync.replicas=2` + Producer `acks=all` + Producer `enable.idempotence=true`。这四件套是"不丢消息"的底线。

3. <strong>监控盯住五个指标</strong>：Consumer Lag（最重要）、Under Replicated Partitions、Active Controller Count、Offline Partitions、Disk Usage。其中 Lag 是消费端健康度的晴雨表。

4. <strong>调优不是调 JVM</strong>：Kafka 的性能核心在 OS PageCache——留给 OS 足够内存比给 JVM 64G 堆更有效。优先调 `batch.size`、`linger.ms`、`compression.type` 和 `concurrency`——这些参数的收益远超 JVM 参数调整。

---

## 📖 系列总览

Kafka 六篇系列到此结束：

| # | 篇 | 核心收获 |
|:--:|------|---------|
| 1 | [<strong>核心架构与日志存储模型</strong>]({{< relref "KafkaFundamentals.md" >}}) | 分布式提交日志 vs 消息队列的本质差异、Topic-Partition 模型、零拷贝 sendfile、KRaft 架构 |
| 2 | [<strong>SpringBoot 全操作指南</strong>]({{< relref "SpringBootKafka.md" >}}) | KafkaTemplate 三模式发送、@KafkaListener 消费、JSON 序列化全链路、手动 Offset 提交 |
| 3 | [<strong>Producer 深入：分区、ACK 与幂等</strong>]({{< relref "ProducerInternals.md" >}}) | DefaultPartitioner 哈希策略、acks=0/1/all 三级可靠性、幂等生产者 PID+Seq、事务跨 Topic 原子写入 |
| 4 | [<strong>Consumer 深入：位移管理与 Rebalance</strong>]({{< relref "ConsumerInternals.md" >}}) | Offset 自动/手动提交、__consumer_offsets 内部 Topic、Rebalance 触发与策略、CooperativeSticky、多线程消费 |
| 5 | [<strong>Kafka Streams 与高级特性</strong>]({{< relref "KafkaStreams.md" >}}) | KStream vs KTable、有状态聚合与窗口、流-表 Join、Log Compaction、exactly_once_v2 |
| 6 | [<strong>生产环境部署与调优</strong>]({{< relref "KafkaProduction.md" >}}) | KRaft 三 Controller + 三 Broker 集群、JVM/OS 调优、Prometheus 监控、10 项检查清单 |

<strong>建议从 1 到 6 顺序阅读</strong>，每篇以前一篇为前提。学完这六篇，从核心概念到生产部署的全链路都覆盖了。
