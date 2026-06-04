---
title: "SpringBoot MongoDB 全操作指南"
date: 2022-10-27T08:00:00+00:00
tags: ["数据存储"]
categories: ["数据库类"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "一篇覆盖 SpringBoot MongoDB 全部常用操作，含 Entity 映射、MongoTemplate、MongoRepository、Criteria 查询构建、聚合初探与批量写入，看完直接上手做项目。"
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

## 第一步：目标说明

这篇文章的目标：让读者在<strong>一篇文章</strong>内学会 SpringBoot 项目中所有常用的 MongoDB 操作，读完就能直接写到项目里。

具体来说，读完这篇文章会掌握：

- 用 <strong>@Document / @Id / @Field</strong> 注解定义 MongoDB 文档映射
- 用 <strong>MongoTemplate</strong> 执行 CRUD、复杂查询、更新操作
- 用 <strong>MongoRepository</strong> 做声明式查询（方法命名 + @Query）
- <strong>聚合管道</strong>的 Java 写法初探
- 一个完整的"用户自定义表单"功能从零到一的实现

## 第二步：前置条件

| 前置项 | 具体要求 | 验证命令 |
|--------|----------|----------|
| JDK | 17+（文中用 17，8+ 均兼容） | `java -version` |
| Maven | 3.6+ | `mvn -v` |
| SpringBoot | 3.x（文中用 3.2.0） | `mvn dependency:tree \| grep spring-boot` |
| MongoDB | 7.0（6.x 也兼容文中所有操作） | `mongosh --eval "db.version()"` |
| 前置知识 | SpringBoot 基础、MongoDB 核心概念（第一篇） | — |

## 第三步：环境搭建

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
      # 或分开写：
      # host: localhost
      # port: 27017
      # database: myapp
```

连接问题排错：

| 错误信息 | 原因 | 解决 |
|----------|------|------|
| `Connection refused` | MongoDB 没启动 | `docker start mongo7` |
| `Authentication failed` | 开启了认证但没配用户名密码 | uri 加上 `mongodb://user:pass@localhost:27017/myapp` |
| `Timed out after 30000 ms` | 防火墙 / 网络不通 | 检查端口映射 `-p 27017:27017` |

## 第四步：分步实践

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
// insert 返回的对象的 id 已被 MongoDB 自动填充
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
// 返回的是修改前的文档（如果想返回修改后的，加 FindAndModifyOptions）
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
// tags 数组包含 "Java"（等价于 mongosh: { tags: "Java" }）
Query query = new Query(Criteria.where("tags").is("Java"));

// tags 数组包含所有指定值
Query query = new Query(Criteria.where("tags").all("Java", "MongoDB"));

// tags 数组长度 = 2
Query query = new Query(Criteria.where("tags").size(2));

// 数组中至少一个元素满足多个条件
Query query = new Query(Criteria.where("items").elemMatch(
    Criteria.where("productName").is("华为手机").and("price").gt(5000)
));

// === 元素存在性 ===
Query query = new Query(Criteria.where("age").exists(true));     // 有 age 字段
Query query = new Query(Criteria.where("gender").exists(false));  // 没有 gender 字段

// === 正则匹配 ===
Query query = new Query(Criteria.where("name").regex("^张"));    // name 以"张"开头

// === 嵌套文档字段 ===
Query query = new Query(Criteria.where("address.city").is("北京"));
```

<strong>分页、排序</strong>：

```java
// 分页 + 排序
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
// 返回的 User 对象中只有 name 和 email 有值，其他字段为 null
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

对于复杂查询，可以直接在注解里写 MongoDB 的查询 JSON：

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

    // 更新操作（要搭配 @Modifying）
    // 注意：需要额外注入 MongoTemplate 执行 update
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

// 需求：按城市分组，统计每个城市的用户数、平均年龄、最年长的用户名
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

`$group` 中的 `_id` 是分组依据，`_id: "$address.city"` 表示按 address 嵌套文档的 city 字段分组，`$` 前缀表示引用文档中的字段值。聚合管道的详细用法（`$project`、`$unwind`、`$lookup` 等）在第三篇单独展开。

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

## 第五步：真实业务场景串联

用一个完整的"用户自定义表单"功能把学到的操作串起来。这是第一篇开头提出的那个让 MySQL 头疼的场景：

```java
// === 1. Entity 定义 ===
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
    //   "紧急联系人": {
    //     "姓名": "张父",
    //     "电话": "13900000000"
    //   }
    // }

    @Field("submit_time")
    private LocalDateTime submitTime;
}
```

```java
// === 2. Service 实现 ===
@Service
public class DynamicFormService {

    @Autowired
    private MongoTemplate mongoTemplate;

    /**
     * 提交表单数据（任何字段都能存，不需要改表结构）
     */
    public DynamicForm submit(String formId, Map<String, Object> fields) {
        DynamicForm form = new DynamicForm();
        form.setFormId(formId);
        form.setFields(fields);
        form.setSubmitTime(LocalDateTime.now());
        return mongoTemplate.insert(form);
    }

    /**
     * 查询某个表单的所有提交数据
     */
    public List<DynamicForm> findByFormId(String formId, int page, int size) {
        Query query = new Query(Criteria.where("formId").is(formId))
            .with(Sort.by(Sort.Direction.DESC, "submitTime"))
            .skip(page * size)
            .limit(size);
        return mongoTemplate.find(query, DynamicForm.class);
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
     * 统计某个表单中各选项（多选字段）的频率
     * 比如"兴趣爱好"有哪些选项，各选了多少次
     */
    public List<FieldStat> fieldStats(String formId, String fieldName) {
        Aggregation agg = Aggregation.newAggregation(
            Aggregation.match(Criteria.where("formId").is(formId)),
            Aggregation.unwind("fields." + fieldName),    // 拆开数组
            Aggregation.group("fields." + fieldName)
                .count().as("count"),
            Aggregation.sort(Sort.by(Sort.Direction.DESC, "count"))
        );
        AggregationResults<FieldStat> results = mongoTemplate.aggregate(
            agg, "dynamic_forms", FieldStat.class);
        return results.getMappedResults();
    }
}
```

```java
// === 3. Controller 层 ===
@RestController
@RequestMapping("/api/forms")
public class DynamicFormController {

    @Autowired
    private DynamicFormService formService;

    @PostMapping("/{formId}/submit")
    public DynamicForm submit(@PathVariable String formId,
                              @RequestBody Map<String, Object> fields) {
        return formService.submit(formId, fields);
    }

    @GetMapping("/{formId}/records")
    public List<DynamicForm> listRecords(@PathVariable String formId,
                                          @RequestParam(defaultValue = "0") int page,
                                          @RequestParam(defaultValue = "20") int size) {
        return formService.findByFormId(formId, page, size);
    }

    @GetMapping("/{formId}/search")
    public List<DynamicForm> search(@PathVariable String formId,
                                     @RequestParam String field,
                                     @RequestParam String value) {
        return formService.searchByField(field, value);
    }
}
```

这个场景下 MongoDB 的优势非常明显——<strong>无论客户定义多少字段，数据库完全不用改</strong>。新增字段？直接多传一个 key。去掉字段？不传就是了。不需要 ALTER TABLE，不需要 EAV 表，不需要处理几十个 NULL 列。

## 第六步：常见问题排查表

| 现象 | 可能原因 | 排查方法 |
|------|----------|----------|
| 查询返回 null | 字段名写错（Java 驼峰 vs MongoDB snake） | 加 `@Field("xxx")` 显式指定字段名 |
| 更新后字段全丢了 | `Update` 没写 `$set` 或用 `save()` 传了不完整的对象 | 用 `Update.set()` 方法而非直接 new 对象 |
| `_class` 字段出现 | Spring Data 默认写入类型信息 | `mongoTemplate` 配置 `remove _class` 或在 Entity 上加 `@TypeAlias` |
| 插入抛出 `DuplicateKeyException` | `_id` 重复 | 不手动设 `_id`，让 MongoDB 自动生成 |
| 数组字段查不到 | 查法不对——`is("Java")` 查的是数组包含，不是整个数组 | 检查用的是 `is()` 还是 `all()` |
| `mongoTemplate` 查询慢 | 没建索引 | `getIndexes()` 确认，`explain()` 看走没走索引 |
| 聚合结果为空 | 分组字段名写错 / 用了嵌套文档字段但没写点号 | 检查 `$group._id` 的字段路径 |

## 第七步：总结与下一步

<strong>这篇覆盖的全部内容</strong>：

- <strong>@Document / @Id / @Field 注解</strong>：Java 对象与 MongoDB 文档的映射
- <strong>MongoTemplate</strong>：CRUD（insert/save/find/updateFirst/updateMulti/upsert/findAndModify/remove）、Criteria 查询构建（比较/逻辑/数组/嵌套/正则）、分页排序、字段投影
- <strong>MongoRepository</strong>：方法命名规则自动生成查询 + `@Query` 手写 JSON
- <strong>聚合管道初探</strong>：`$match → $group → $sort → $limit` 的 Java 写法
- <strong>完整用户自定义表单案例</strong>：MongoDB 对异构数据场景的天然优势

<strong>下一步建议</strong>：

继续阅读 [<strong>MongoDB 聚合管道深入</strong>]({{< relref "MongoDBAggregation.md" >}})，掌握 `$unwind` / `$project` / `$lookup` / `$facet` 等高级聚合阶段，以及复杂的多表关联和数据分析场景。
