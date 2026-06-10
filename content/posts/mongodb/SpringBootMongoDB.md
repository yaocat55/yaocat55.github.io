---
title: "SpringBoot MongoDB 全操作指南"
date: 2022-10-27T08:00:00+00:00
tags: ["MongoDB", "实践教程", "SpringBoot"]
categories: ["数据库类"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "一篇覆盖 SpringBoot MongoDB 全部常用操作，含 Entity 映射、MongoTemplate、MongoRepository、Criteria 查询构建、聚合初探、批量写入，以及真实电商项目的双写架构分析与两种 MongoDB 使用模式对照，看完直接上手做项目。"
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
    hidden: false
---

# SpringBoot MongoDB 全操作指南

> 📖 <strong>前置阅读</strong>：本文假设读者已了解 MongoDB 的文档模型、BSON 数据类型和 mongosh 基础操作。如果还不熟悉，建议先阅读 [<strong>MongoDB 核心概念：文档模型、BSON 与查询操作符全解析</strong>]({{< relref "MongoDBFundamentals.md" >}})。

本文按照"<strong>先搞懂操作 → 教程版完整实现 → 生产版架构模式 → 验证排错</strong>"的顺序组织。如果你只想快速上手 MongoTemplate 的 CRUD，读完 Part 1 后直接看 Part 2 即可；如果你想理解真实项目中 MongoDB 是怎么用的，需要完整读完。

---

# Part 1：先搞懂要做什么

---

## 一、目标说明

这篇文章的目标：让读者在<strong>一篇文章</strong>内学会 SpringBoot 项目中所有常用的 MongoDB 操作，读完就能直接写到项目里。

具体来说，读完这篇文章会掌握：

- 用 <strong>@Document / @Id / @Field</strong> 注解定义 MongoDB 文档映射
- 用 <strong>MongoTemplate</strong> 执行 CRUD、复杂查询、更新操作
- 用 <strong>MongoRepository</strong> 做声明式查询（方法命名 + @Query）
- <strong>聚合管道</strong>的 Java 写法初探
- 一个完整的"用户自定义表单"功能从零到一的实现

## 二、前置条件

| 前置项 | 具体要求 | 验证命令 |
|--------|----------|----------|
| JDK | 17+（文中用 17，8+ 均兼容） | `java -version` |
| Maven | 3.6+ | `mvn -v` |
| SpringBoot | 3.x（文中用 3.2.0） | `mvn dependency:tree \| grep spring-boot` |
| MongoDB | 7.0（6.x 也兼容文中所有操作） | `mongosh --eval "db.version()"` |
| 前置知识 | SpringBoot 基础、MongoDB 核心概念（第一篇） | — |

---

# Part 2：教程版 —— 从零掌握 MongoDB 全部操作

下面每一节都给出了完整的、可运行的代码。整个教程版使用同一个技术栈：Spring Boot 3.x + `spring-boot-starter-data-mongodb`，所有操作通过 `MongoTemplate` 和 `MongoRepository` 完成。

---

## 三、环境搭建

### 安装 MongoDB

```bash
# Docker 方式
docker run -d --name mongo7 -p 27017:27017 mongo:7.0

# 验证
docker exec -it mongo7 mongosh --eval "db.version()"
# 预期输出：7.0.x
```

### 创建 SpringBoot 项目

`pom.xml` 添加依赖：

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-mongodb</artifactId>
</dependency>
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-web</artifactId>
</dependency>
<dependency>
    <groupId>org.projectlombok</groupId>
    <artifactId>lombok</artifactId>
    <optional>true</optional>
</dependency>
```

`application.yml` 配置连接：

```yaml
spring:
  data:
    mongodb:
      uri: mongodb://localhost:27017/myapp   # database = myapp
```

连接问题排错：

| 错误信息 | 原因 | 解决 |
|----------|------|------|
| `Connection refused` | MongoDB 没启动 | `docker start mongo7` |
| `Authentication failed` | 开启了认证但没配用户名密码 | uri 加上 `mongodb://user:pass@localhost:27017/myapp` |
| `Timed out after 30000 ms` | 防火墙 / 网络不通 | 检查端口映射 `-p 27017:27017` |

---

## 四、教程版完整实现

### 4.1 Entity 映射 —— 用注解定义文档结构

第一篇里这些操作在 mongosh 中完成：

```javascript
db.users.insertOne({
  name: "张三",
  email: "zhangsan@example.com",
  age: 28
})
```

在 Java 中，要先定义对应的实体类：

```java
import org.springframework.data.annotation.Id;
import org.springframework.data.mongodb.core.mapping.Document;
import org.springframework.data.mongodb.core.mapping.Field;

@Data
@Document(collection = "users")            // 映射到 users Collection
public class User {

    @Id
    private String id;                      // MongoDB 的 _id 字段

    @Field("name")                          // 显式指定字段名（驼峰转 snake 等场景用）
    private String name;

    private String email;                   // 不写 @Field 则字段名 = 属性名

    private Integer age;

    private List<String> tags;

    private Address address;                // 嵌套文档

    @Field("create_time")
    private LocalDateTime createTime;       // 映射到 create_time 字段
}

@Data
public class Address {                      // 嵌套文档不需要 @Document
    private String city;
    private String street;
}
```

<strong>核心注解速查</strong>：

| 注解 | 作用 | 对应 mongosh |
|------|------|-------------|
| `@Document(collection)` | 指定 Collection 名称 | `db.users` |
| `@Id` | 标记 `_id` 字段 | `_id: ObjectId(...)` |
| `@Field("name")` | 指定 MongoDB 中的字段名 | — |
| `@Indexed` | 给字段建索引 | `createIndex({...})` |
| `@CompoundIndex` | 建复合索引 | `createIndex({a:1, b:1})` |
| `@Transient` | 不持久化（忽略此字段） | — |
| `@DBRef` | 引用另一个 Collection 的文档（不推荐） | — |

### 4.2 MongoTemplate —— 核心操作类

`MongoTemplate` 是 Spring Data MongoDB 最核心的操作类（对标 `RedisTemplate` / `ElasticsearchRestTemplate`）。所有 CRUD、复杂查询、聚合都通过它执行。

<strong>4.2.1 文档 CRUD</strong>

```java
@Autowired
private MongoTemplate mongoTemplate;

// === 新增 ===
User user = new User();
user.setName("张三");
user.setEmail("zhangsan@example.com");
user.setAge(28);
user.setTags(List.of("Java", "MongoDB"));
user.setAddress(new Address("北京", "中关村大街"));
user.setCreateTime(LocalDateTime.now());

User saved = mongoTemplate.insert(user);
System.out.println(saved.getId());  // ObjectId 的 hex 字符串

// 批量新增
List<User> users = generateUsers(100);
mongoTemplate.insert(users, User.class);    // 一批全写入

// === 查询：按 ID ===
User found = mongoTemplate.findById("507f1f77bcf86cd799439011", User.class);

// === 查询：全部 ===
List<User> all = mongoTemplate.findAll(User.class);

// === 更新 ===
// updateFirst：更新匹配到的第一条
Query query = new Query(Criteria.where("name").is("张三"));
Update update = new Update().set("age", 29).set("email", "newemail@example.com");
mongoTemplate.updateFirst(query, update, User.class);

// updateMulti：更新所有匹配的
mongoTemplate.updateMulti(
    new Query(Criteria.where("age").lt(20)),
    new Update().set("level", "junior"),
    User.class
);

// upsert：有则更新，没有则新增
mongoTemplate.upsert(
    new Query(Criteria.where("email").is("zhangsan@example.com")),
    new Update().set("name", "张三").set("age", 29),
    User.class
);

// === 删除 ===
mongoTemplate.remove(new Query(Criteria.where("age").lt(18)), User.class);

// === findAndModify：原子读-改-写 ===
User updated = mongoTemplate.findAndModify(
    new Query(Criteria.where("name").is("张三")),
    new Update().inc("age", 1),              // age 原子 +1
    User.class
);
```

> ⚠️ 新手提示：`save()` vs `insert()`——`save()` 做 upsert（ID 存在就覆盖，不存在就新增），`insert()` 做纯新增（ID 重复会抛 `DuplicateKeyException`）。不确定是新增还是更新时用 `save()`。

<strong>4.2.2 Criteria 查询构建</strong>

MongoTemplate 的查询由两个核心类构建——<strong>`Query`（查询条件 + 分页排序）</strong>和 <strong>`Criteria`（单个条件）</strong>。对应 mongosh 里的：

```
mongosh:  db.users.find({ age: { $gt: 25 }, "address.city": "北京" })
Java:     new Query(Criteria.where("age").gt(25).and("address.city").is("北京"))
```

```java
// === 精确匹配 ===
Query query = new Query(Criteria.where("name").is("张三"));

// === 比较操作 ===
Query query = new Query(Criteria.where("age").gt(25));            // >
Query query = new Query(Criteria.where("age").gte(25));           // >=
Query query = new Query(Criteria.where("age").lt(30));            // <
Query query = new Query(Criteria.where("age").ne(28));            // !=
Query query = new Query(Criteria.where("age").in(25, 28, 32));   // IN

// === 逻辑组合：AND（链式 .and） ===
Query query = new Query(
    Criteria.where("age").gt(25)
        .and("address.city").is("北京")
);

// === 逻辑组合：OR ===
Query query = new Query(
    new Criteria().orOperator(
        Criteria.where("age").lt(25),
        Criteria.where("tags").is("Java")
    )
);

// === 数组查询 ===
Query query = new Query(Criteria.where("tags").is("Java"));       // 数组包含
Query query = new Query(Criteria.where("tags").all("Java", "MongoDB"));  // 包含所有
Query query = new Query(Criteria.where("tags").size(2));          // 数组长度

// === 元素存在性 ===
Query query = new Query(Criteria.where("age").exists(true));
Query query = new Query(Criteria.where("gender").exists(false));

// === 正则匹配 ===
Query query = new Query(Criteria.where("name").regex("^张"));

// === 嵌套文档字段 ===
Query query = new Query(Criteria.where("address.city").is("北京"));
```

<strong>分页、排序</strong>：

```java
Query query = new Query(Criteria.where("age").gt(20))
    .with(Sort.by(Sort.Direction.DESC, "age"))  // 按 age 降序
    .skip(0)                                     // 跳过前 N 条
    .limit(10);                                  // 返回 N 条

List<User> users = mongoTemplate.find(query, User.class);

// 配合 Pageable
Pageable pageable = PageRequest.of(0, 10, Sort.by("age").descending());
Query query = new Query(Criteria.where("age").gt(20)).with(pageable);
long total = mongoTemplate.count(query, User.class);   // 总数
```

<strong>字段投影（只查部分字段）</strong>：

```java
Query query = new Query(Criteria.where("age").gt(25));
query.fields()
    .include("name", "email")    // 只返回这些字段
    .exclude("_id");              // 排除 _id

List<User> users = mongoTemplate.find(query, User.class);
```

### 4.3 MongoRepository —— 声明式查询

对于简单查询，MongoRepository 提供方法名即查询的便捷方式——和 Spring Data JPA / ES 完全一样：

```java
@Repository
public interface UserRepository extends MongoRepository<User, String> {

    // === 精确匹配 ===
    List<User> findByName(String name);
    User findByEmail(String email);

    // === 比较 ===
    List<User> findByAgeGreaterThan(int age);           // age > ?
    List<User> findByAgeBetween(int from, int to);      // age between ? and ?

    // === 多条件 ===
    List<User> findByNameAndAge(String name, int age);
    List<User> findByNameOrEmail(String name, String email);

    // === 排序 ===
    List<User> findByAgeGreaterThanOrderByAgeDesc(int age);

    // === 分页 ===
    Page<User> findByAgeGreaterThan(int age, Pageable pageable);

    // === 数组 ===
    List<User> findByTagsIn(List<String> tags);

    // === 存在性 ===
    List<User> findByGenderExists(boolean exists);

    // === regex ===
    List<User> findByNameRegex(String regex);
}
```

<strong>方法命名规则速查</strong>：

| 后缀 | 操作符 | 示例 |
|------|--------|------|
| `GreaterThan` | `$gt` | `findByAgeGreaterThan` |
| `LessThan` | `$lt` | `findByAgeLessThan` |
| `Between` | `$gte + $lte` | `findByAgeBetween` |
| `In` | `$in` | `findByTagsIn` |
| `Exists` | `$exists` | `findByGenderExists` |
| `Regex` | `$regex` | `findByNameRegex` |
| `OrderByXxxAsc/Desc` | `sort` | `findByAgeOrderByNameDesc` |

<strong>@Query 注解 —— 手写 MongoDB 查询 JSON</strong>：

```java
@Repository
public interface UserRepository extends MongoRepository<User, String> {

    // ?0 = 第一个参数，?1 = 第二个参数
    @Query("{ 'age': { $gt: ?0 }, 'address.city': ?1 }")
    List<User> findByAgeAndCity(int age, String city);

    // 只返回部分字段
    @Query(value = "{ 'age': { $gt: ?0 } }",
           fields = "{ 'name': 1, 'email': 1 }")
    List<User> findNamesByAge(int age);
}
```

<strong>Repository vs MongoTemplate 怎么选？</strong>

| 维度 | Repository | MongoTemplate |
|------|:---:|:---:|
| 简单查询 | 方法名一行搞定 | 需手写 Criteria |
| 复杂查询（多条件 OR / 数组） | @Query 写 JSON 字符串 | Criteria 链式 API，类型安全 |
| 更新 / upsert / findAndModify | 不支持（只能查） | 完整支持 |
| 聚合 | 不支持 | 完整支持 |
| 推荐场景 | 简单 CRUD | 复杂查询 + 更新 + 聚合 |

实际项目中<strong>混用</strong>：简单的"按 ID 查"、"按 email 查"用 Repository，复杂条件查询 + 更新 + 聚合用 MongoTemplate。

### 4.4 聚合管道初探

MongoDB 的聚合管道（Aggregation Pipeline）是其最强大的数据分析能力。Java API 同样以 builder 方式构建：

```java
import org.springframework.data.mongodb.core.aggregation.*;

// 需求：按城市分组，统计每个城市的用户数、平均年龄
Aggregation agg = Aggregation.newAggregation(
    Aggregation.match(Criteria.where("age").gt(20)),              // $match：过滤
    Aggregation.group("address.city")                              // $group：按城市分组
        .count().as("userCount")                                   //   统计数量
        .avg("age").as("avgAge")                                   //   平均年龄
        .max("age").as("maxAge"),                                  //   最大年龄
    Aggregation.sort(Sort.by(Sort.Direction.DESC, "userCount")),   // $sort：按用户数降序
    Aggregation.limit(5)                                           // $limit：取前 5
);

AggregationResults<CityStat> results = mongoTemplate.aggregate(
    agg, "users", CityStat.class);
List<CityStat> stats = results.getMappedResults();
```

对应 mongosh 中的等价操作：

```javascript
db.users.aggregate([
  { $match: { age: { $gt: 20 } } },
  { $group: { _id: "$address.city", userCount: { $count: {} }, avgAge: { $avg: "$age" }, maxAge: { $max: "$age" } } },
  { $sort: { userCount: -1 } },
  { $limit: 5 }
])
```

### 4.5 常用方法速查表

| 方法 | 说明 | 典型场景 |
|------|------|----------|
| `mongoTemplate.insert(obj)` | 新增（ID 重复抛异常） | 确保不覆盖已有数据 |
| `mongoTemplate.save(obj)` | 新增或覆盖（upsert） | 不确定是增还是改 |
| `mongoTemplate.findById(id, clazz)` | 按 ID 查询 | 详情页 |
| `mongoTemplate.find(query, clazz)` | 条件查询 | 列表搜索 |
| `mongoTemplate.findOne(query, clazz)` | 查一条 | 唯一条件查询 |
| `mongoTemplate.updateFirst(query, update, clazz)` | 更新第一条匹配的 | 精确更新 |
| `mongoTemplate.updateMulti(query, update, clazz)` | 更新所有匹配的 | 批量更新 |
| `mongoTemplate.upsert(query, update, clazz)` | 有则更新无则新增 | 幂等写入 |
| `mongoTemplate.findAndModify(query, update, clazz)` | 原子读-改-写 | 计数器、状态变更 |
| `mongoTemplate.remove(query, clazz)` | 条件删除 | 清理数据 |
| `mongoTemplate.aggregate(agg, collection, clazz)` | 聚合管道 | 统计、分析 |

### 4.6 教程版小结

到这里，你已经掌握了 Spring Data MongoDB 的全部基础操作。核心公式只有一个：

```
MongoTemplate 负责执行 → Query + Criteria 负责描述条件 → @Document 负责映射结果
```

<strong>教程版的问题</strong>——也是你必须继续读 Part 3 的原因：

| 问题 | 后果 |
|------|------|
| `_id` 是 MongoDB 自动生成的 `ObjectId`，和 MySQL 主键不一致 | 同一个数据在 MySQL 和 MongoDB 里有两个不同的 ID，关联查困难 |
| 没有审计字段（创建人、创建时间） | 不知道谁在什么时候写了这条数据 |
| 所有数据只存 MongoDB | 但商品基本字段要参与 JOIN + 事务，MongoDB 做不了 |
| 单条 `insert` 就够了 | 生产环境需要批量写入、事务保证、异常回滚 |

这 4 个问题，正是 Part 3 要逐一解决的。

---

# Part 3：生产版 —— 真实项目中的 MongoDB 实战模式

Part 2 教了 MongoDB 怎么操作。Part 3 回答另一个问题：<strong>MongoDB 在真实项目中是怎么用的？</strong>

答案是两种截然不同的模式——<strong>双写辅助</strong>和<strong>纯 MongoDB 主存储</strong>。下面先介绍模式一涉及的生产级基础设施（Entity 设计、写入链路、查询链路、双写架构），再介绍模式二（自定义表单），最后给出两种模式的选型对照。

> 以下代码均来自真实 mall 商城项目 `mall_server`，包路径 `com.mall`。每个代码块都是完整的、可直接参考的。

---

## 五、生产版 Entity 设计

真实项目的 Entity 和教程版有两个本质区别：<strong>继承 BaseEntity 拿审计字段</strong>，以及<strong>手动生成雪花算法主键</strong>。

### 5.1 公共基类 BaseEntity

项目中所有数据表（MySQL 和 MongoDB）都继承自同一个基类：

```java
package com.mall.common.entity;

@Data
@AllArgsConstructor
@NoArgsConstructor
public class BaseEntity implements Serializable {
    private Long id;              // 雪花算法主键（不是 ObjectId）
    private Long createUserId;
    private String createUserName;
    private Date createTime;
    private Long updateUserId;
    private String updateUserName;
    private Date updateTime;
    private Integer isDel;        // 软删除标记（0:正常 1:删除）
}
```

### 5.2 商品详情 Entity（MongoDB）

```java
package com.mall.domain.mongo.entity;

@Document(collection = "ProductDetailEntity")
@Data
@AllArgsConstructor
@NoArgsConstructor
public class ProductDetailEntity extends BaseEntity {

    @Indexed                             // 按 productId 查询，必须建索引
    private Long productId;

    private String detail;               // 富文本 HTML，几 KB ~ 几十 KB
}
```

<strong>两个设计决策</strong>：

<strong>① 为什么 `_id` 用雪花算法 Long 而不是 ObjectId？</strong>

雪花算法生成的 `Long` 型 ID 全局有序、比 `ObjectId` 短、可以直接当 MySQL 主键复用。注意 `mongoTemplate.insert()` 在 `_id` 已赋值时不再自动生成——所以要先手动设 `id`。

<strong>② 为什么给 `productId` 加 `@Indexed`？</strong>

商品详情的查询永远按 `productId` 来——"某个商品的详情是什么"。不加索引的话，Collection 数据量上来后每次都是全表扫描。dev 环境开启 `auto-index-creation: true` 让 Spring 自动建索引，prod 环境关掉，由 DBA 手动管理。

### 5.3 审计字段自动填充 —— FillUserUtil

教程版写数据时，谁创建、什么时间创建全都不管。生产版每条数据都要带审计信息：

```java
package com.mall.common.util;

public abstract class FillUserUtil {

    private static final Long DEFAULT_USER_ID = 1L;
    private static final String DEFAULT_USER_NAME = "系统管理员";

    /**
     * 填充创建用户信息——从 SecurityContext 拿当前登录用户
     */
    public static void fillCreateUserInfo(BaseEntity baseEntity) {
        Authentication authentication = SecurityContextHolder.getContext().getAuthentication();
        if (authentication.getPrincipal() instanceof String) {
            // 未登录用户（如定时任务）→ 使用默认值
            baseEntity.setCreateUserId(DEFAULT_USER_ID);
            baseEntity.setCreateUserName(DEFAULT_USER_NAME);
        } else {
            JwtUserEntity jwtUserEntity = (JwtUserEntity) authentication.getPrincipal();
            baseEntity.setCreateUserId(jwtUserEntity.getId());
            baseEntity.setCreateUserName(jwtUserEntity.getUsername());
        }
        baseEntity.setCreateTime(new Date());
    }

    /**
     * 填充修改用户信息
     */
    public static void fillUpdateUserInfo(BaseEntity baseEntity) {
        JwtUserEntity jwtUserEntity = (JwtUserEntity)
            SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        baseEntity.setUpdateUserId(jwtUserEntity.getId());
        baseEntity.setUpdateUserName(jwtUserEntity.getUsername());
        baseEntity.setUpdateTime(new Date());
    }
}
```

<strong>调用方式</strong>——在任何 insert/update 之前，一行搞定：

```java
ProductDetailEntity entity = new ProductDetailEntity();
entity.setProductId(productId);
entity.setDetail(htmlContent);
entity.setId(idGenerateHelper.nextId());          // 雪花算法生成 Long 型 _id
FillUserUtil.fillCreateUserInfo(entity);           // 自动填充创建人 + 创建时间
mongoTemplate.insert(entity, ProductDetailEntity.class);
```

---

## 六、生产版写入与查询链路

### 6.1 写入链路 —— ProductCommandService.saveProductDetail()

商品新增时，MySQL 写入商品基本字段，MongoDB 写入商品详情（富文本）。二者包在同一个事务中：

```java
// ProductCommandService.doGenerate() —— 简化版
transactionTemplate.execute((status -> {
    productHelper.batchInsert(productEntityList);         // ① MySQL：商品基本表
    if (CollectionUtils.isNotEmpty(realAddList)) {
        saveProductDetail(realAddList);                   // ② MongoDB：商品详情
        saveProductAttribute(realAddList);                // ③ MySQL：商品属性
        productPhotoService.savePhoto(realAddList);       // ④ MySQL：商品照片
    }
    return Boolean.TRUE;
}));
```

`saveProductDetail()` 的实现：

```java
private void saveProductDetail(List<ProductEntity> addList) {
    // 只有填了"商品详情"的商品才写 MongoDB（空详情没必要存）
    List<ProductEntity> detailList = addList.stream()
        .filter(x -> StringUtils.hasLength(x.getDetail()))
        .collect(Collectors.toList());
    if (CollectionUtils.isEmpty(detailList)) {
        return;
    }

    List<ProductDetailEntity> addDetailList = detailList.stream().map(x -> {
        ProductDetailEntity entity = new ProductDetailEntity();
        entity.setProductId(x.getId());
        entity.setDetail(x.getDetail());
        entity.setId(idGenerateHelper.nextId());       // 雪花算法手动生成主键
        FillUserUtil.fillCreateUserInfo(entity);        // 自动填充审计字段
        return entity;
    }).collect(Collectors.toList());
    mongoTemplate.insert(addDetailList, ProductDetailEntity.class);
}
```

<strong>三个与教程版的区别</strong>：

| 区别 | 教程版 | 生产版 | 原因 |
|------|------|------|------|
| <strong>主键生成</strong> | MongoDB 自动生成 `ObjectId` | `idGenerateHelper.nextId()` 雪花算法 | Long 型 ID 全局有序、可以作为 MySQL 主键复用 |
| <strong>事务保证</strong> | 无 | `TransactionTemplate` 编程式事务 | ShardingSphere 分库分表下 `@Transactional` 不生效，只能用编程式事务 |
| <strong>批量写入</strong> | 逐条 `insert()` | `mongoTemplate.insert(List)` 批量 | 一次网络往返写入全部文档，100 条 ≈ 1 次网络 IO vs 100 次 |

> ⚠️ 坦白讲：`TransactionTemplate` 对 MongoDB 的回滚是"最佳努力"级别的——如果 MongoDB insert 成功了但后续 MySQL 操作抛异常，MongoDB 的数据不会被自动回滚。真正需要强一致性的场景，应该引入<strong>事务消息</strong>或者把 MongoDB 写入放在事务的最后一步。

### 6.2 查询链路 —— ProductSearchService.fillDetail()

商品列表查出来后，需要把详情（富文本）从 MongoDB 填充到 `ProductEntity` 上：

```java
// ProductSearchService.fillDetail()
public void fillDetail(ProductEntity productEntity) {
    Query query = new Query(Criteria.where("productId").is(productEntity.getId()));
    List<ProductDetailEntity> entities = mongoTemplate.find(query, ProductDetailEntity.class);
    if (CollectionUtils.isEmpty(entities)) {
        return;  // 不是所有商品都有详情
    }
    productEntity.setDetail(entities.get(0).getDetail());
}
```

这里 `productId` 上有 `@Indexed` 索引，查询走 `IXSCAN` 而不是全表扫描。对比教学用的 `findById()`（按 `_id` 查），<strong>真实业务中按业务键查询远比按 MongoDB 自带 `_id` 查询更常见</strong>。所以要养成给业务键加索引的习惯。

### 6.3 删除链路 —— 注意孤儿数据

修改商品时的删除逻辑：

```java
// ProductCommandService.deleteProductDetail()
private void deleteProductDetail(ProductEntity productEntity) {
    ProductDetailQuery query = new ProductDetailQuery();
    query.setProductId(productEntity.getId());
    List<ProductDetailEntity> entities = productDetailMapper.searchByCondition(query);
    if (CollectionUtils.isNotEmpty(entities)) {
        List<Long> idList = entities.stream()
            .map(ProductDetailEntity::getId).collect(Collectors.toList());
        productDetailMapper.deleteByIds(idList, deleteEntity);
        // ⚠️ 只从 MySQL 删了，MongoDB 里的文档还在！
    }
}
```

MySQL 逻辑删除后，MongoDB 里的对应文档成了<strong>孤儿数据</strong>。不过项目里 MongoDB 的 `detail` 字段只在查询时通过 `fillDetail()` 填充——MySQL 里标记删除后，查询链路不会走到 `fillDetail()`，所以孤儿数据在业务上不可见。换句话说：<strong>业务正确性依赖的是 MySQL 状态而非 MongoDB</strong>，MongoDB 只是"影子存储"。

> ⚠️ 写过的都懂——这种"业务正确性靠 MySQL 把关、MongoDB 只做辅助"的模式在中小项目里很常见。优点是 MongoDB 写入可以更随意（丢了也不影响核心业务），缺点是数据清理时要记得两边一起清，不然磁盘慢慢被孤儿数据撑满。

---

## 七、架构模式一：MySQL + MongoDB 双写辅助（商品详情）

现在把上面的片段串成完整架构。为什么商品详情要同时写 MySQL 和 MongoDB？

商品详情是一大段富文本 HTML（`<img>`、`<table>`、样式标签……），单条轻松几 KB 到几十 KB。这玩意有两个矛盾的需求：

| 需求 | 数据库偏好 | 原因 |
|------|:---:|------|
| 商品基本字段（名称、价格、库存）要分库分表 + JOIN + 事务 | <strong>MySQL</strong> | ShardingSphere 中间件、关联查询、ACID 保证 |
| 商品详情（大段 HTML）结构不规则、不参与 JOIN、偶尔改 | <strong>MongoDB</strong> | 文档模型天然适合长文本，不占 MySQL 表空间 |

所以双写不是过度设计——是<strong>关系型干关系型的活，文档型干文档型的活</strong>。MySQL 存 `id, product_id, detail` 的瘦记录，MongoDB 存完整 HTML。

<strong>数据流全景</strong>：

```mermaid
flowchart TD
    A[管理后台录入商品详情] --> B{填写了富文本详情?}
    B -->|是| C[TransactionTemplate 开启事务]
    B -->|否| D[只写 MySQL 基本字段]
    C --> E[MySQL: INSERT mall_product]
    C --> F[MongoDB: mongoTemplate.insert ProductDetailEntity]
    E --> G{MySQL 写入失败?}
    G -->|是| H[事务回滚, MongoDB 写入跟着回滚]
    G -->|否| I[事务提交, 两边数据一致]

    J[用户端查看商品] --> K[ES 搜索 + MySQL 查基本字段]
    K --> L[ProductSearchService.fillDetail]
    L --> M[MongoDB: mongoTemplate.find by productId]
    M --> N[填充 detail 字段返回前端]
```

<strong>一句话总结</strong>：MongoDB 的角色是<strong>MySQL 的"大字段卸载器"</strong>——把富文本这种又大又不参与 JOIN 的数据挪走，MySQL 专心干事务和关联的活。MongoDB 文档丢了？重新编辑一次商品就写回来了。MySQL 的 `mall_product_detail` 表才是"真相来源"。

---

## 八、架构模式二：纯 MongoDB 主存储（自定义表单）

前面是"MongoDB 当辅助"。现在看另一种模式——<strong>当数据天生不适合关系型时，让 MongoDB 独挑大梁</strong>。

用一个完整的"用户自定义表单"功能把这个模式串起来。这是第一篇开头提出的那个让 MySQL 头疼的场景——<strong>字段完全由用户定义，每个客户的表单字段都不一样</strong>。

### 8.1 Entity 定义

```java
@Data
@Document(collection = "dynamic_forms")
public class DynamicForm {
    @Id
    private String id;

    private String formId;        // 表单模板 ID（区分不同客户的表单）
    private Map<String, Object> fields;  // 所有自定义字段都在这
    // {
    //   "姓名": "张三",
    //   "手机号": "13800000000",
    //   "是否过敏": true,
    //   "兴趣爱好": ["篮球", "足球"],
    //   "紧急联系人": { "姓名": "张父", "电话": "13900000000" }
    // }

    @Field("submit_time")
    private LocalDateTime submitTime;
}
```

### 8.2 Service 实现

```java
@Service
public class DynamicFormService {

    @Autowired
    private MongoTemplate mongoTemplate;

    /**
     * 提交表单数据——任何字段都能存，不需要改表结构
     */
    public DynamicForm submit(String formId, Map<String, Object> fields) {
        DynamicForm form = new DynamicForm();
        form.setFormId(formId);
        form.setFields(fields);
        form.setSubmitTime(LocalDateTime.now());
        return mongoTemplate.insert(form);
    }

    /**
     * 跨字段搜索——查找所有表单中"姓名"字段 = 张三的记录
     * 对比 MySQL：需要 JOIN 所有 EAV 表，或者用 JSON_CONTAINS 走全表扫描
     */
    public List<DynamicForm> searchByField(String fieldName, Object value) {
        Query query = new Query(
            Criteria.where("fields." + fieldName).is(value)
        );
        return mongoTemplate.find(query, DynamicForm.class);
    }

    /**
     * 统计某个表单中各选项的频率——如"兴趣爱好"有哪些选项，各选了多少次
     */
    public List<FieldStat> fieldStats(String formId, String fieldName) {
        Aggregation agg = Aggregation.newAggregation(
            Aggregation.match(Criteria.where("formId").is(formId)),
            Aggregation.unwind("fields." + fieldName),    // 拆开数组
            Aggregation.group("fields." + fieldName)
                .count().as("count"),
            Aggregation.sort(Sort.by(Sort.Direction.DESC, "count"))
        );
        return mongoTemplate.aggregate(
            agg, "dynamic_forms", FieldStat.class).getMappedResults();
    }
}
```

这个场景下 MongoDB 的优势非常明显——<strong>无论客户定义多少字段，数据库完全不用改</strong>。新增字段？直接多传一个 key。去掉字段？不传就是了。不需要 ALTER TABLE，不需要 EAV 表，不需要处理几十个 NULL 列。

---

## 九、两种模式选型对照

| 维度 | 商品详情（模式一） | 自定义表单（模式二） |
|------|------|------|
| 模式 | MySQL + MongoDB 双写辅助 | 纯 MongoDB |
| MongoDB 角色 | MySQL 的大字段卸载器 | 唯一存储 |
| 为什么这样选 | 基本字段要 JOIN + 事务，detail 只是展示 | 字段完全由用户定义，MySQL 扛不住 |
| 数据一致性 | MySQL 是真相来源，MongoDB 丢了可恢复 | MongoDB 就是真相来源，丢了就是真丢了 |
| 事务保证 | TransactionTemplate 尽力保证，不强一致 | 不跨数据源，不需要分布式事务 |

分界线在于：<strong>如果数据需要与关系型表做 JOIN 或需要事务保证，MongoDB 就做辅助；如果数据天生灵活、自包含、不参与关联查询，让 MongoDB 做主存储</strong>。

---

# Part 4：验证与排错

---

## 十、常见问题排查表

| 现象 | 可能原因 | 排查方法 |
|------|----------|----------|
| 查询返回 null | 字段名写错（Java 驼峰 vs MongoDB snake） | 加 `@Field("xxx")` 显式指定字段名 |
| 更新后字段全丢了 | `Update` 没写 `$set` 或用 `save()` 传了不完整的对象 | 用 `Update.set()` 方法而非直接 new 对象 |
| `_class` 字段出现 | Spring Data 默认写入类型信息 | `mongoTemplate` 配置 `remove _class` 或在 Entity 上加 `@TypeAlias` |
| 插入抛出 `DuplicateKeyException` | `_id` 重复 | 不手动设 `_id`，让 MongoDB 自动生成 |
| 数组字段查不到 | 查法不对——`is("Java")` 查的是数组包含，不是整个数组 | 检查用的是 `is()` 还是 `all()` |
| `mongoTemplate` 查询慢 | 没建索引 | `getIndexes()` 确认，`explain()` 看走没走索引 |
| 聚合结果为空 | 分组字段名写错 / 用了嵌套文档字段但没写点号 | 检查 `$group._id` 的字段路径 |
| 双写场景 MySQL 有数据 MongoDB 没有 | `saveProductDetail` 里 `StringUtils.hasLength` 过滤掉了 | 确认商品编辑时填了"详情"字段 |
| 修改商品详情后 MySQL 更新了 MongoDB 还是旧的 | `update` 走 `deleteProductDetail` 删 MySQL 记录再重新 insert——但 MongoDB 没删旧文档 | 加上 `mongoTemplate.remove()` 清理旧文档 |
| `@Indexed` 在 prod 环境不生效 | prod 关了 `auto-index-creation: true` | 联系 DBA 手动建索引 |

---

## 十一、总结

<strong>这篇覆盖的全部内容</strong>：

- <strong>@Document / @Id / @Field 注解</strong>：Java 对象与 MongoDB 文档的映射
- <strong>MongoTemplate</strong>：CRUD（insert/save/find/updateFirst/updateMulti/upsert/findAndModify/remove）、Criteria 查询构建（比较/逻辑/数组/嵌套/正则）、分页排序、字段投影
- <strong>MongoRepository</strong>：方法命名规则自动生成查询 + `@Query` 手写 JSON
- <strong>聚合管道初探</strong>：`$match → $group → $sort → $limit` 的 Java 写法
- <strong>BaseEntity 继承 + FillUserUtil 审计填充</strong>：生产级 Entity 设计的完整代码
- <strong>TransactionTemplate 事务 + 批量写入</strong>：ShardingSphere 分库分表下的编程式事务保证
- <strong>两种 MongoDB 使用模式</strong>：双写辅助（商品详情）vs 纯 MongoDB 主存储（自定义表单），含选型对照表

<strong>下一步建议</strong>：

继续阅读 [<strong>MongoDB 聚合管道深入</strong>]({{< relref "MongoDBAggregation.md" >}})，掌握 `$unwind` / `$project` / `$lookup` / `$facet` 等高级聚合阶段，以及复杂的多表关联和数据分析场景。
