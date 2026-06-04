---
title: "MySQL 锁与日志系统：从并发控制到崩溃恢复"
date: 2022-12-30T11:30:03+00:00
tags: ["数据存储"]
categories: ["数据库类"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "拆解 InnoDB 六种锁类型（Record/Gap/Next-Key/意向锁）、死锁检测机制、Redo Log 与 Binlog 的两阶段提交过程，以及崩溃恢复如何利用日志保证数据不丢。"
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

# MySQL 锁与日志系统：从并发控制到崩溃恢复

> 📌 <strong>前置知识</strong>：前三篇分别讲了 B+树索引、Join 原理、MVCC。这篇讲两个主题——锁（LBCC，基于锁的并发控制）和日志（Redo Log + Binlog）——它们分别在"正确性"和"持久性"上补足了 MVCC 的短板。MVCC 解决读-写冲突，锁解决写-写冲突；日志保证写入的数据断电不丢。

## 1. 锁的类型：InnoDB 到底有哪些锁

MVCC 让读者不需要锁就能看到一致的数据版本。但当两个事务<strong>同时修改同一行</strong>时，多版本帮不上忙——因为最终只能有一个版本成为"当前版本"。这就需要锁来协调写-写冲突。

InnoDB 的锁按粒度分为两级：<strong>表级锁</strong>和<strong>行级锁</strong>。

### 表级锁

| 锁类型 | SQL 关键字 | 行为 |
|------|------|------|
| 表共享锁（S） | `LOCK TABLE t READ` | 自己可读不可写，其他人可读不可写 |
| 表排他锁（X） | `LOCK TABLE t WRITE` | 自己可读写，其他人连读都不行 |
| 意向共享锁（IS） | 自动加 | "我打算对其中某行加 S 锁"——在行上加 S 锁前必须先在表上加 IS |
| 意向排他锁（IX） | 自动加 | "我打算对其中某行加 X 锁"——在行上加 X 锁前必须先在表上加 IX |
| AUTO-INC 锁 | 自增列插入 | 插入自增主键时确保值连续递增 |

<strong>意向锁</strong>是 InnoDB 实现多粒度锁的关键。加行锁之前先加表级意向锁，这样其他事务要加表锁时只需检查表的意向锁就能知道该表是否有行锁，不需要逐行检查。比如事务 A 对某行加了 X 锁（先在表级加 IX 锁），事务 B 想 `LOCK TABLE t WRITE`（加表级 X 锁），B 一检查发现表上有 IX 锁，直接等待，不需要扫描所有的行。

### 行级锁（三种）

<strong>Record Lock（记录锁）</strong>：锁定索引记录本身。精确地锁住 B+树叶子中的某一条索引记录。

<strong>Gap Lock（间隙锁）</strong>：锁定索引记录之间的<strong>间隙</strong>，但不锁记录本身。间隙锁阻止在该间隙插入新记录——这就是 RR 下解决<strong>幻读</strong>的机制。间隙锁之间不冲突——两个事务可以在同一个间隙上同时持有 Gap Lock。

<strong>Next-Key Lock（临键锁）</strong>：Record Lock + Gap Lock 的组合。锁定一条记录<strong>以及它前面的间隙</strong>。InnoDB 在 RR 级别默认使用 Next-Key Lock，同时阻止"这条记录被修改"和"这个间隙被插入"，从根本上杜绝了幻读。

![三种行锁在B+树叶子上的覆盖范围](/images/mysql-lock-types-comparison.svg)

> ⚠️ <strong>新手提示</strong>：行锁实际上是<strong>索引记录锁</strong>——它是加在 B+树索引记录上，而不是数据行上。如果 WHERE 条件没有索引（全表扫描），MySQL 会把所有行都加上锁，等效于锁表。这就是"没索引的 UPDATE 会锁表"的真相。

<strong>行锁的加锁规则</strong>（在 RR 级别下）：

```sql
-- 以下假设表有 id 主键索引，id 值为 5, 10, 15, 20, 25

-- 等值命中：在 id=10 的索引记录上加 Record Lock
SELECT * FROM t WHERE id = 10 FOR UPDATE;

-- 等值未命中：在 (5,15) 间隙上加 Gap Lock（因为 12 不存在，要防插入）
SELECT * FROM t WHERE id = 12 FOR UPDATE;

-- 范围查询：id ≥ 15 的所有记录加 Next-Key Lock（防修改 + 防插入）
SELECT * FROM t WHERE id >= 15 FOR UPDATE;
```

## 2. 死锁：并发竞争的终极难题

两个事务互相等待对方持有的锁时，就形成了死锁。

```text
事务 A: UPDATE t SET x=1 WHERE id=5;   -- 持有 id=5 的 X 锁
         UPDATE t SET x=1 WHERE id=10;  -- 等待 id=10 的 X 锁（被 B 持有）

事务 B: UPDATE t SET x=2 WHERE id=10;  -- 持有 id=10 的 X 锁
         UPDATE t SET x=2 WHERE id=5;   -- 等待 id=5 的 X 锁（被 A 持有）

→ A 等 B，B 等 A → 死锁
```

InnoDB 的<strong>死锁检测</strong>机制：

- 维护一个 <strong>等待图（Wait-for Graph）</strong>：节点 = 事务，边 = "事务 A 等待事务 B 的锁"
- 每次事务请求锁被阻塞时，检查等待图中是否出现了<strong>环（Cycle）</strong>
- 如果检测到环，选择<strong>回滚代价最小</strong>的事务（通常是 UNDO 日志量最小的那个）回滚，释放其持有的锁
- 被回滚的事务收到 `Deadlock found when trying to get lock; try restarting transaction` 错误

> ⚠️ <strong>新手提示</strong>：死锁在生产环境很常见。减少死锁的几个做法——按相同的顺序访问表和行（如所有事务都先操作 id=5 再操作 id=10）、尽量让事务短小精悍（减少锁持有时间）、在事务中尽早获取所有需要的锁（如用 `SELECT ... FOR UPDATE` 提前锁定）。

如果死锁检测太频繁导致 CPU 飙高（等待图很大时检测环的复杂度很高），可以通过 `innodb_deadlock_detect = OFF` 关闭死锁检测，配合 `innodb_lock_wait_timeout`（锁等待超时时间）来替代。

## 3. Redo Log：WAL 与崩溃恢复的基石

Redo Log 是 InnoDB 特有的日志，目的是<strong>保证已提交事务的持久性（Durability）</strong>——通俗点说就是：如果数据库突然断电，重启后能把已提交但未落盘的数据靠日志恢复出来。

Redo Log 的设计核心是 <strong>WAL（Write-Ahead Logging，预写日志）</strong>：<strong>先把修改记录到日志，再写数据页</strong>。为什么这样做？因为写日志是顺序写（追加到文件末尾），而直接写数据页是随机写（分散在不同页面的不同位置）。顺序写入磁盘的速度比随机写快 1 ~ 2 个数量级。

### Redo Log 的结构

<strong>Redo Log Buffer（内存）</strong>：日志先写到内存中的 buffer。`innodb_log_buffer_size` 控制大小，默认 16MB。

<strong>Redo Log File（磁盘）</strong>：buffer 中的日志在三种时机会刷到磁盘（称为 `innodb_flush_log_at_trx_commit` 控制）：
- `0`：每秒刷一次，MySQL 崩溃可能丢失 1 秒的数据
- `1`：每次提交立即刷盘（默认，最安全）
- `2`：每次提交写入 OS cache，每秒刷盘（MySQL 崩溃不丢，但 OS 崩溃丢 1 秒）

<strong>Redo Log 是循环写的</strong>。两个日志文件轮流使用，写满了就从头覆盖。LSN（Log Sequence Number，日志序列号）是全局递增的，用来标记哪些日志已经刷到数据页、哪些还没有。

![Redo Log 循环写与 checkpoint 机制](/images/mysql-redo-log-cycle.svg)

<strong>Checkpoint</strong> 是 Redo Log 策略的关键。Checkpoint 表示"LSN 小于此值的所有修改都已经刷到数据页了"。这样崩溃恢复时只需要<strong>从上次 Checkpoint 之后的 Redo Log 开始重放</strong>，而不是从头扫描整个日志。而脏页（已修改但未刷到磁盘的数据页）统一由后台线程刷盘——Checkpoint 只是标记进度，真正的刷脏页是异步发生的。

<strong>Redo Log 日志记录的格式</strong>：

```text
┌────────────┬──────────────┬──────────────┬─────────────┐
│ 日志类型     │ Table ID     │ Page No      │ 修改内容     │
│ (1B)        │ (4B)         │ (4B)         │ (可变长)     │
└────────────┴──────────────┴──────────────┴─────────────┘
```

每条 Redo Log 记录是对某个<strong>物理页</strong>的某个偏移量的修改——比如"页号 100 的偏移量 200 处，写 4 字节值 42"。这就是为什么 Redo Log 恢复很快——<strong>直接按物理页号重放修改，不需要重新走 SQL 语义</strong>。

## 4. Binlog：MySQL Server 层的归档日志

Binlog（Binary Log，二进制日志）是 MySQL Server 层（不是 InnoDB 特有）的日志，记录的是<strong>逻辑操作</strong>而非物理页修改。主要用途：

- <strong>主从复制</strong>：从库通过重放主库的 Binlog 达到数据一致
- <strong>数据恢复</strong>：全量备份 + 增量 Binlog = 指定时间点的数据

<strong>三种 Binlog 格式</strong>：

| 格式 | 记录内容 | 优点 | 缺点 |
|------|------|------|------|
| STATEMENT | SQL 语句原文 | 日志体积小 | 非确定性函数（NOW()/UUID()）导致主从不一致 |
| ROW | 每行被修改前后的值 | 精确、不会不一致 | 日志体积大（UPDATE 100 万行 = 100 万行 Binlog） |
| MIXED | 通常用 STATEMENT，非确定性操作用 ROW | 折中方案 | — |

MySQL 8.0 默认使用 ROW 格式。ROW 虽然日志量大，但保证主从绝对一致，是现代标准做法。

## 5. 两阶段提交：Redo Log 与 Binlog 的协作

Redo Log 实现崩溃恢复（物理层），Binlog 实现主从复制（逻辑层）。但一个 UPDATE 同时产生 Redo Log 和 Binlog——如果两者写入之间 MySQL 崩溃了，就会出现 Redo Log 有的 Binlog 没有（或反之），导致主从数据不一致。

<strong>两阶段提交（2PC，Two-Phase Commit）</strong>解决了这个问题：

![两阶段提交流程图](/images/mysql-two-phase-commit.svg)

<strong>Prepare 阶段</strong>：写入 Redo Log 并标记为 `PREPARE` 状态。不标记为 COMMIT。

<strong>Commit 阶段</strong>：
- 写入 Binlog
- Binlog 写入成功后，将 Redo Log 标记为 `COMMIT` 状态

<strong>崩溃恢复时的决策逻辑</strong>：

```
if Redo Log 中有 PREPARE 状态的记录:
    if 对应的 Binlog 已完整写入:
        提交（将 Redo Log 标记为 COMMIT）
    else:
        回滚（丢弃 PREPARE 状态的 Redo Log）
else:
    不处理（未到 PREPARE 阶段的事务视为未提交）
```

这个决策逻辑保证了：<strong>Binlog 和 Redo Log 在"事务是否提交"上永远一致</strong>。要么都提交，要么都回滚。

> ⚠️ <strong>新手提示</strong>：两阶段提交不是慢的根源——Prepare 和 Commit 之间的时间是 Binlog 写入的时间，而 Binlog 是顺序写，速度很快。真正影响事务响应时间的是 Redo Log 的刷盘策略（`innodb_flush_log_at_trx_commit`）和 Binlog 的刷盘策略（`sync_binlog`）。

## 6. 崩溃恢复：日志怎么把数据救回来

假设数据库在运行中突然断电，内存中的数据全部丢失。重启后的恢复过程：

![崩溃恢复流程图](/images/mysql-crash-recovery.svg)

<strong>第一步：Redo Log 重放</strong>。从上次 Checkpoint 开始，扫描 Redo Log 中的每一条日志记录。根据每条日志的物理页号（Page No），将修改重放到对应的数据页上。这一步把"已写日志但未写数据页"的修改全部补上了。

<strong>第二步：Undo Log 回滚</strong>。Redo Log 重放后，所有未提交事务的修改也被重放到了数据页上。所以接下来要根据 Undo Log，回滚那些<strong>在崩溃前未提交的事务</strong>。怎么判断？检查每条重放日志对应的事务的 Binlog——如果有 PREPARE 但没 COMMIT，且 Binlog 中找不到完整记录，就回滚。

<strong>第一步与第二步的关系</strong>：Redo 保证"不丢数据"（已提交的不丢失），Undo 保证"不多数据"（未提交的滚回去）。

<strong>相关参数</strong>：

```ini
# Redo Log 刷盘策略
innodb_flush_log_at_trx_commit = 1  # 每次提交刷盘（最安全）

# Binlog 刷盘策略
sync_binlog = 1  # 每次提交刷盘（最安全）

# 两阶段提交相关
innodb_support_xa = 1  # 开启 XA 事务支持（MySQL 5.7+ 默认）

# Redo Log 大小
innodb_log_file_size = 50331648  # 每个 Redo Log 文件 48MB
innodb_log_files_in_group = 2    # 2 个文件循环使用
```

> ⚠️ <strong>新手提示</strong>：很多开发在开发环境把 `innodb_flush_log_at_trx_commit` 设为 0 或 2 来追求写入速度。这没问题——开发机崩了不心疼。但生产环境<strong>必须设为 1</strong>。哪怕每次刷盘多花几毫秒，也比数据丢失强。同理 `sync_binlog = 1`——除非你的业务可以接受"最近 1 秒的数据可以丢"。

## 7. 总结

这篇的内容分两条线：

<strong>锁这条线</strong>——LBCC 解决 MVCC 管不了的写-写冲突。Record Lock 锁记录、Gap Lock 锁间隙、Next-Key Lock 两样都锁。死锁检测靠等待图中的环检测，代价最小的被回滚。没索引的 UPDATE 会锁全表——这是开发阶段就应该避免的坑。

<strong>日志这条线</strong>——Redo Log 物理层崩溃恢复、Binlog 逻辑层主从复制、两阶段提交保证两者一致。WAL 用顺序写替代随机写，Checkpoint 标记恢复起点。崩溃后 Redo 重放已提交的、Undo 回滚未提交的。

<strong>锁保证了事务的正确性（C），日志保证了数据的持久性（D）</strong>。加上 MVCC 提供的隔离性（I），MySQL InnoDB 的 ACID 拼图只剩原子性（A）——而原子性本质也靠 Undo Log 回滚未提交事务来保证。

下一篇是这个系列的最后一篇——<strong>MySQL 实战优化</strong>：EXPLAIN 怎么读、SQL 怎么改写、索引怎么用、以及臭名昭著的 NULL 陷阱。
