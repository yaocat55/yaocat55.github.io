# MySQL B+树系列 设计文档

**日期**: 2026-06-03
**目标**: 面向 MySQL 新手，从 B+树数据结构切入，深入讲解索引、查询执行、事务、锁与日志、实战优化五篇系列博客

## 目标读者

MySQL 零基础开发者，但需有基本编程概念（变量、函数、数据结构）。

## 视觉策略

- B+树结构、流程类 → draw.io SVG
- 内存/字节布局（页结构、ReadView、UndoLog）→ HTML+CSS 内联
- 简单分类/对比 → Mermaid
- 每篇图量下限见各篇，不设硬上限，以讲清楚为优先

## 第1篇：B+树索引体系（8000~10000字，8~10张图）

章节：为什么是B+树 → B+树完整结构 → InnoDB 页结构(HTML+CSS) → 聚簇索引 → 二级索引/回表 → 联合索引/最左前缀 → SQL 四种操作在B+树上的执行 → 范围查询 → 模糊查询LIKE → 分页LIMIT/OFFSET → 页分裂与页合并 → 总结

# 第2篇：Join原理（4000~5000字，5~6张图）

章节：Join本质 → Nested-Loop Join → Block Nested-Loop Join → Index Nested-Loop Join → Hash Join → 三种Join数据流对比 → Join顺序优化

## 第3篇：事务与MVCC（6000~7000字，5~6张图）

章节：四种隔离级别 → MVCC动机 → 隐藏列 → Undo Log(HTML+CSS) → ReadView(HTML+CSS) → MVCC流程图(draw.io) → RC vs RR 下 ReadView 差异

## 第4篇：锁与日志（5000~6000字，4~5张图）

章节：锁类型(Record/Gap/Next-Key/意向锁) → LBCC → Redo Log WAL → Binlog三种格式 → 两阶段提交(draw.io) → 崩溃恢复

## 第5篇：实战优化（5000~6000字，3~4张图）

章节：EXPLAIN详解 → 慢查询 → 索引优化三板斧 → SQL改写 → NULL陷阱 → 开发检查清单

## 写作风格

blog-create skill 规范：亲切俏皮、工位闲聊口吻、禁止比喻、禁止第一人称、新手术语标注、
`<strong>` 替代 `**`、`~` 范围两侧空格

## 分类

categories: ["数据库类"]
