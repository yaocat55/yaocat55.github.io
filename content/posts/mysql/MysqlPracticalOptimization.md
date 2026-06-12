---
title: "MySQL 实战优化：从 EXPLAIN 到 NULL 陷阱"
date: 2022-12-31T11:30:03+00:00
tags: ["MySQL", "实践教程", "故障排查"]
categories: ["数据库类"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "面向日常开发的 MySQL 优化实战：EXPLAIN 字段逐一解读、索引优化三板斧、SQL 改写技巧、慢查询定位，以及 UNIQUE 多 NULL、COUNT/NOT IN 等经典 NULL 陷阱的彻底拆解。"
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

# 从 EXPLAIN 到 NULL 陷阱——优化其实有章可循

> 📌 <strong>前置知识</strong>：这篇是系列最后一篇，面向日常开发的实战视角。前四篇的理论基础——B+树、索引结构、MVCC、锁机制——这篇会直接引用而不重复展开。建议至少读过第一篇 B+树索引体系再看这篇。

## 1. EXPLAIN：优化器的自白

EXPLAIN 是 SQL 优化的第一工具。它不会替你优化 SQL，但它告诉你 MySQL 打算<strong>怎么</strong>优化你的 SQL——用了哪个索引、扫描多少行、做了什么额外操作。理解了它的输出，慢查询的根因通常一目了然。

```sql
EXPLAIN SELECT * FROM users WHERE name = 'Zhang' AND age > 20 ORDER BY id;
```

输出如下（省略部分列）：

```text
+----+------+---------------+------+---------+-------+------+-------------------+
| id | type | possible_keys | key  | key_len | ref   | rows | Extra             |
+----+------+---------------+------+---------+-------+------+-------------------+
|  1 | ref  | idx_name      | idx  | 102     | const |  120 | Using index cond  |
+----+------+---------------+------+---------+-------+------+-------------------+
```

<strong>逐字段解读</strong>：

| 字段 | 含义 | 关键值 |
|------|------|------|
| `id` | SELECT 的序号（多表查询时有多个） | 同一 id = 从上到下执行；id 不同 = 从大到小执行 |
| `type` | <strong>访问类型</strong>——最重要的字段 | `ALL`(全表)→`index`(索引全扫)→`range`(范围)→`ref`(等值)→`eq_ref`(唯一等值)→`const`(主键常量)→`NULL`(最优) |
| `possible_keys` | 候选索引（可能被用到的） | 如果为 NULL = 没有可用索引 |
| `key` | <strong>实际使用的索引</strong> | 如果为 NULL = 没用索引（注意和 possible_keys 区分） |
| `key_len` | 使用的索引长度（字节数） | 帮你判断用了联合索引的几列 |
| `ref` | 索引列与什么比较 | `const` = 常量值，`users.id` = 另一表的列 |
| `rows` | <strong>估算扫描的行数</strong> | 小则靠索引、大则全表/大范围 |
| `filtered` | 索引扫描后还需要过滤的行百分比 | 100% = 完全匹配索引；< 10% = 大量回表后丢弃 |
| `Extra` | <strong>额外信息</strong>——关键线索 | 见下表 |

<strong>Extra 字段的常见值</strong>：

| Extra 值 | 含义 | 评价 |
|------|------|:---:|
| `Using index` | 覆盖索引——只读索引不读数据页 | ✅ 最优 |
| `Using index condition` | 索引条件下推（ICP） | ✅ 良好 |
| `Using where` | Server 层额外过滤 | ⚠ 一般——部分行被索引扫出后又丢弃 |
| `Using temporary` | 用了临时表（常见于 GROUP BY / DISTINCT / UNION） | ⚠ 需关注 |
| `Using filesort` | 额外排序操作（没用到索引的有序性） | ❌ 需优化 |
| `Using join buffer` | Join 用了 Join Buffer（被驱动表没索引） | ❌ 加索引 |
| `NULL` | 直接索引定位返回，没有任何额外操作 | ✅ 最好 |

<strong>type 递进关系</strong>：

```mermaid
flowchart LR
    ALL_desc["ALL 全表扫描 ❌"] --> INDEX_desc["index 索引全扫描 ⚠"]
    INDEX_desc --> RANGE_desc["range 索引范围扫描 ⚠"]
    RANGE_desc --> REF_desc["ref 非唯一索引等值 ✅"]
    REF_desc --> EQREF_desc["eq_ref 唯一索引等值 ✅"]
    EQREF_desc --> CONST_desc["const 主键常量 ✅✅"]

    classDef startEnd fill:#F48FB1,stroke:#C2185B,stroke-width:2px,color:#212121,font-weight:bold
    classDef process fill:#F5F5F5,stroke:#9E9E9E,stroke-width:1.5px,color:#212121
    classDef data fill:#C8E6C9,stroke:#388E3C,stroke-width:1.5px,color:#1B5E20,font-weight:bold
    classDef reject fill:#FFCDD2,stroke:#C62828,stroke-width:1.5px,color:#B71C1C,font-weight:bold

    class ALL_desc reject
    class INDEX_desc,RANGE_desc process
    class REF_desc,EQREF_desc data
    class CONST_desc data
```

> ⚠️ <strong>新手提示</strong>：`type = ALL` 不一定是坏事——如果表只有 50 行，全表扫描比索引查找 + 回表更快。`rows` 和实际返回行数差距很大时，说明索引选择可能不对——优化器的统计信息过期了。

## 2. 慢查询定位：找到瓶颈的第一现场

<strong>开启慢查询日志</strong>：

```sql
-- 查看当前状态
SHOW VARIABLES LIKE 'slow_query%';
SHOW VARIABLES LIKE 'long_query_time';

-- 开启慢查询日志（开发环境）
SET GLOBAL slow_query_log = ON;
SET GLOBAL long_query_time = 0.5;  -- 超过 0.5 秒就算慢（生产环境按实际定）
SET GLOBAL log_queries_not_using_indexes = ON;  -- 记录没用索引的查询
```

<strong>慢查询日志分析工具</strong>：

- `mysqldumpslow`（MySQL 自带）：统计出现最频繁的慢查询、平均耗时、总耗时
- `pt-query-digest`（Percona Toolkit）：更详细的分析——哪些查询占用了最多的时间、哪些表的慢查询最多、哪些时间段是高峰

<strong>常见慢查询模式</strong>：

```sql
-- 🔴 全表扫描：没有 WHERE 条件
SELECT * FROM orders;

-- 🔴 深分页：LIMIT 1000000, 10（跳过 100 万行）
SELECT * FROM orders ORDER BY id LIMIT 1000000, 10;

-- 🔴 左模糊：LIKE '%abc'
SELECT * FROM users WHERE name LIKE '%Zhang';

-- 🔴 函数破坏索引：WHERE 条件对索引列做了运算
SELECT * FROM orders WHERE YEAR(create_time) = 2024;  -- 索引失效
-- 改为：
SELECT * FROM orders WHERE create_time >= '2024-01-01' AND create_time < '2025-01-01';
```

## 3. 索引优化三板斧：覆盖索引、ICP、避免失效

### 第一板斧：覆盖索引

```sql
-- ❌ 回表：二级索引叶子只有 name + id，age 在主键索引
SELECT id, name, age FROM users WHERE name = 'Zhang';

-- ✅ 覆盖：建联合索引包含 SELECT 的所有列
ALTER TABLE users ADD INDEX idx_name_age(name, age);
SELECT id, name, age FROM users WHERE name = 'Zhang';  -- Extra: Using index
```

覆盖索引的判断标准：EXPLAIN 的 `Extra` 显示 `Using index` 且 `key` 不为 NULL。

### 第二板斧：索引条件下推（ICP）

MySQL 5.6 引入。在引擎层（扫描索引时）就过滤掉不满足条件的行，只对符合条件的行回表。

```sql
-- 联合索引 idx_ab(a, b)
-- 没有 ICP：索引扫出所有 a >= 10 的行 → 每行都回表 → Server 层过滤 b = 20
-- 有 ICP：索引扫出所有 a >= 10 的行 → 引擎层直接过滤 b = 20 → 只对 b=20 的回表
SELECT * FROM t WHERE a >= 10 AND b = 20;
-- Extra: Using index condition（说明 ICP 生效）
```

### 第三板斧：避免索引失效

| 失效场景 | 示例 | 原因 |
|------|------|------|
| 索引列上做运算 | `WHERE YEAR(date_col) = 2024` | MySQL 无法用索引查找函数结果 |
| 隐式类型转换 | `WHERE phone = 13800138000`（phone 是 VARCHAR） | MySQL 把字符串转为数字，索引失效 |
| 前导模糊 | `LIKE '%abc'` | B+树按前缀排序，无法定位后缀 |
| OR 跨索引 | `OR idx_a=1 OR idx_b=2` | 两个索引分开，无法合并（MySQL 5.6+ union 优化可补救） |
| 联合索引跳最左列 | `INDEX(a,b)` 但 `WHERE b=2` | B+树先按 a 排序，跳过 a 则 b 无序 |
| 不等于 | `WHERE status != 'done'` | 不等于意味着"除了它以外的所有值"，无法精确定位 |

## 4. SQL 改写：同样的意图，不同量级的性能

<strong>① JOIN 替代子查询</strong>：

MySQL 的 `IN` 子查询在 MySQL 5.6 之前性能惨不忍睹（对驱动表每一行都执行一次子查询）。5.6+ 做了`semi-join` 优化，但 JOIN 写法通常仍然更可控。

```sql
-- ❌ 子查询（老版本 MySQL）
SELECT * FROM orders WHERE user_id IN (SELECT id FROM users WHERE age > 20);

-- ✅ JOIN
SELECT o.* FROM orders o JOIN users u ON o.user_id = u.id WHERE u.age > 20;
```

<strong>② LIMIT 优化</strong>（第一篇第 10 节已详述）：

```sql
-- ❌ 深分页
SELECT * FROM orders ORDER BY id LIMIT 1000000, 10;

-- ✅ 游标分页
SELECT * FROM orders WHERE id > 1000000 ORDER BY id LIMIT 10;
```

<strong>③ COUNT 的性能真相</strong>：

```sql
-- COUNT(*) 与 COUNT(col) 的区别
-- COUNT(*)：统计所有行（包括 NULL），InnoDB 选最小的索引扫
-- COUNT(col)：统计 col IS NOT NULL 的行
-- COUNT(1) = COUNT(*)：MySQL 优化为等效操作

-- 大表查总行数不要直接 COUNT(*)，用近似值
SELECT TABLE_ROWS FROM information_schema.tables WHERE TABLE_NAME = 'orders';
-- 或者用计数器（Redis）或汇总表
```

<strong>④ SELECT * 的三重危害</strong>：

1. <strong>网络开销</strong>：把 TEXT/BLOB 列、不必要的列全部传输
2. <strong>覆盖索引失效</strong>：`SELECT *` 总是包含不在索引中的列，强制回表
3. <strong>Join Buffer 效率低</strong>：`SELECT *` 让 Join Buffer 可装的行数急剧减少

```sql
-- ❌ 全表扫描 + 全部列传输
SELECT * FROM orders WHERE status = 'pending';

-- ✅ 只取需要的列 + 覆盖索引
ALTER TABLE orders ADD INDEX idx_status_id(status, id, amount);
SELECT id, amount, create_time FROM orders WHERE status = 'pending';
```

## 5. NULL 陷阱：UNIQUE 允许多个 NULL 的十个坑

这是 MySQL 中一个著名的反直觉行为，围绕 NULL 设计上的特殊性展开。

### 坑一：UNIQUE 约束允许多个 NULL

```sql
CREATE TABLE users (
    id INT PRIMARY KEY,
    email VARCHAR(100) UNIQUE  -- UNIQUE 约束
);

-- 这两条都能成功插入
INSERT INTO users VALUES (1, NULL);
INSERT INTO users VALUES (2, NULL);  -- 不报错！UNIQUE 认为 NULL ≠ NULL
```

<strong>原因</strong>：SQL 标准规定 NULL 是"未知值"，两个未知值互不相等。因此 UNIQUE 约束允许插入任意多个 NULL——因为它们都不"相等"。

> ⚠️ <strong>新手提示</strong>：如果你的业务逻辑需要 email 唯一且不能为空，建表时要加 `NOT NULL`：`email VARCHAR(100) NOT NULL UNIQUE`。否则上线后会出现多个用户 email 都是 NULL 且谁也查不着谁的情况。

### 坑二：NULL 与任何值的比较都是 NULL（三值逻辑）

```sql
SELECT NULL = NULL;   -- NULL（不是 TRUE！）
SELECT NULL <> NULL;  -- NULL（不是 FALSE！）
SELECT 1 = NULL;      -- NULL
SELECT 1 > NULL;      -- NULL
```

NULL 参与的布尔运算结果不是 TRUE 或 FALSE，而是 <strong>NULL（UNKNOWN，第三种逻辑值）</strong>。WHERE 子句只接收 TRUE 的结果，NULL 和 FALSE 都会被过滤掉。

### 坑三：NOT IN 中的 NULL 让整个查询返回空集

```sql
SELECT * FROM users WHERE id NOT IN (1, 2, NULL);
-- 返回空集！（即使有很多 id=3, id=4 的行）

-- 实际等价逻辑：
SELECT * FROM users WHERE id <> 1 AND id <> 2 AND id <> NULL;
-- id <> NULL 结果是 NULL（不是 TRUE），AND NULL 还是 NULL
-- WHERE 只接受 TRUE，所以所有行都被过滤了
```

这是 NOT IN 最危险的坑。改用 `NOT EXISTS` 或显式排除 NULL：

```sql
-- ✅ NOT EXISTS（不受 NULL 影响）
SELECT * FROM users u WHERE NOT EXISTS (
    SELECT 1 FROM blacklist b WHERE u.id = b.id
);

-- ✅ 排除 NULL
SELECT * FROM users WHERE id NOT IN (
    SELECT id FROM blacklist WHERE id IS NOT NULL
);
```

### 坑四：COUNT 忽略 NULL

```sql
SELECT COUNT(email) FROM users;     -- 只统计 email IS NOT NULL 的行
SELECT COUNT(*) FROM users;         -- 统计所有行（包括 NULL）
```

### 坑五：DISTINCT 中 NULL 算一个值

```sql
SELECT DISTINCT email FROM users;
-- 如果有多个 NULL email 行，结果中只返回一个 NULL
```

UNIQUE 约束允许多个 NULL，但 DISTINCT 把多个 NULL 归为一个——同一个 NULL 在不同上下文里时而"相等"时而"不相等"。

### 坑六：GROUP BY 中 NULL 归为一组

```sql
SELECT email, COUNT(*) FROM users GROUP BY email;
-- 所有 email IS NULL 的行被归到同一个组
```

### 坑七：ORDER BY 中 NULL 的排序

```sql
-- MySQL 默认：NULL 被认为"最小"，排在 ASC 的最前面
SELECT * FROM users ORDER BY email ASC;   -- NULL 在最前面
SELECT * FROM users ORDER BY email DESC;  -- NULL 在最后面
```

### 坑八：CONCAT 遇到 NULL 返回 NULL

```sql
SELECT CONCAT('Hello, ', NULL);  -- NULL
-- 任何字符串和 NULL 拼接的结果都是 NULL
-- 用 COALESCE 替代：
SELECT CONCAT('Hello, ', COALESCE(name, 'Unknown'));
```

### 坑九：SUM/AVG 自动忽略 NULL

```sql
-- 如果 10 行中有 3 行的 amount 是 NULL
SELECT SUM(amount) FROM orders;   -- 只加 7 个非 NULL 值
SELECT AVG(amount) FROM orders;   -- 7 个非 NULL 值的平均
-- 不是 10 个值的平均！容易误算
```

### 坑十：<=> 运算符（NULL 安全的等于）

```sql
SELECT NULL <=> NULL;  -- 1（TRUE！）
SELECT 1 <=> NULL;     -- 0

-- 等价于传统的：
SELECT NULL IS NULL;   -- 1
```

`<=>` 是 MySQL 特有的 NULL 安全等于运算符——NULL 和 NULL 比较返回 TRUE。在需要精确匹配（包括 NULL 值）时使用。

> ⚠️ <strong>新手提示</strong>：如果列需要"互不相等"的业务语义，<strong>直接定义 NOT NULL + 设默认值</strong>是最省心的做法。比如 `status VARCHAR(20) NOT NULL DEFAULT 'active'`。用 NULL 来实现"可选字段"看似方便，实际是给未来的自己和同事挖坑。

## 6. 日常开发 SQL 检查清单

上线前花 5 分钟走一遍这个清单，能捕获绝大部分慢查询和潜在故障：

- [ ] EXPLAIN 的 type 不是 ALL（除非表确实很小）
- [ ] EXPLAIN 的 Extra 没有 Using filesort 或 Using temporary
- [ ] 被驱动表的 Join 列有索引（INLJ）
- [ ] 深分页用游标分页替代 LIMIT OFFSET
- [ ] WHERE 条件中对索引列没有做函数/运算/隐式类型转换
- [ ] LIKE 没有前导 `%`
- [ ] 没在循环里执行 SQL（N+1 查询问题）
- [ ] `SELECT *` 只在真正需要的场景下使用
- [ ] UNIQUE 列加了 NOT NULL（如业务要求不可空）
- [ ] 没在 NOT IN 子查询中使用可能含 NULL 的列
- [ ] `innodb_flush_log_at_trx_commit = 1` 且 `sync_binlog = 1`（生产环境）

## 7. 总结

这篇是整个 MySQL B+树系列的收尾。五篇的关系是：

<strong>第一篇（B+树）</strong>是地基——聚簇索引、二级索引、页结构是后续所有机制的物理载体。

<strong>第二篇（Join）</strong>是连接——单表查询升级为多表连接，B+树查找从一次变成"外层每行触发一次内层查找"。

<strong>第三篇（MVCC）</strong>是隔离——多版本并发控制让读不阻塞写，ReadView + Undo Log 在不加锁的情况下实现了读一致性。

<strong>第四篇（锁与日志）</strong>是保障——锁补上 MVCC 不管的写-写冲突，Redo Log + Binlog 保证已提交的数据断电不丢。

<strong>第五篇（实战优化）</strong>是落地——EXPLAIN 读懂、索引用好、SQL 改写对、NULL 绕开，把前四篇的理论变成日常开发的直觉和习惯。

每篇独立可读，合在一起是从 B+树叶子的物理结构到 SQL 优化清单的完整思维链路。建议把第一篇和第五篇结合起来反复读——第五篇的每个优化决策背后都是第一篇的原理在支撑。
