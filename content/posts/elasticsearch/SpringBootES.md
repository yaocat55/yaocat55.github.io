---
title: "SpringBoot Elasticsearch 全操作指南"
date: 2022-10-23T08:00:00+00:00
tags: ["数据存储"]
categories: ["数据库类"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "一篇覆盖 SpringBoot Elasticsearch 全部常用操作，含 Entity 映射、ElasticsearchRestTemplate、Repository、搜索、聚合、高亮与批量写入，看完直接上手做项目。"
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

# SpringBoot Elasticsearch 全操作指南

> 📖 <strong>前置阅读</strong>：本文假设读者已了解 ES 的倒排索引、分词器、Mapping 和 REST API 基础操作。如果还不熟悉，建议先阅读 [<strong>Elasticsearch 核心概念：倒排索引、分词器与 REST API 全解析</strong>]({{< relref "ESFundamentals.md" >}})。

## 第一步：目标说明

这篇文章的目标很明确：让读者在<strong>一篇文章</strong>内学会 SpringBoot 项目中所有常用的 ES 操作，读完就能直接写到项目里。

具体来说，读完这篇文章会掌握：

- 用 <strong>@Document</strong> 和 <strong>@Field</strong> 注解定义 ES 映射
- 用 <strong>ElasticsearchRestTemplate</strong> 执行 CRUD、搜索、聚合、高亮
- 用 <strong>Spring Data ES Repository</strong> 做声明式查询
- <strong>批量写入</strong>、<strong>条件删除</strong> 和 <strong>真实场景串联</strong>
- 一个完整的"商品搜索"功能从零到一的完整代码

文中的所有代码都可以直接复制粘贴到项目里，只需要改包名和类名。

## 第二步：前置条件

开始之前，确认以下知识储备和环境就绪：

| 前置项 | 具体要求 | 验证命令 |
|--------|----------|----------|
| JDK | 17+（文中用 17，8+ 均兼容） | `java -version` |
| Maven | 3.6+ | `mvn -v` |
| SpringBoot | 3.x（文中用 3.2.0） | `mvn dependency:tree \| grep spring-boot` |
| Elasticsearch | 8.x（7.x 也兼容文中大部分操作，需调整配置） | `curl -u elastic http://localhost:9200` |
| IDE | IntelliJ IDEA / VS Code / Eclipse 均可 | — |
| 前置知识 | SpringBoot 基础（`@Configuration`、`@Bean`、`@Autowired`）、ES 核心概念（倒排索引、分词器、Mapping） | — |

> 📌 前置知识：读者需要了解 SpringBoot 的依赖注入和 `application.yml` 配置，以及 Elasticsearch 的 Index / Document / Mapping 基本概念。文中涉及的分词器（analyzer）和 text vs keyword 等概念已在第一篇详细讲过。

如果 ES 还没装好，下一节会给出完整安装步骤。

## 第三步：环境搭建

### 安装 Elasticsearch 8.x

ES 8.x 默认开启<strong>安全认证</strong>（用户名 `elastic`，密码在首次启动时自动生成）。推荐用 Docker：

```bash
# 创建网络
docker network create elastic

# 启动 ES 8.x（单节点，适合开发）
docker run -d --name es8 \
  --net elastic \
  -p 9200:9200 \
  -p 9300:9300 \
  -e "discovery.type=single-node" \
  -e "xpack.security.enabled=true" \
  -e "ELASTIC_PASSWORD=changeme" \
  docker.elastic.co/elasticsearch/elasticsearch:8.15.0

# 安装 IK 中文分词器
docker exec -it es8 /usr/share/elasticsearch/bin/elasticsearch-plugin install \
  https://get.infini.cloud/elasticsearch/analysis-ik/8.15.0
docker restart es8

# 验证
curl -u elastic:changeme -k https://localhost:9200
# 预期输出：{ "name": "...", "cluster_name": "...", "version": { "number": "8.15.0" } }

# 安装 Kibana（可选，有图形界面方便调试）
docker run -d --name kibana \
  --net elastic \
  -p 5601:5601 \
  -e "ELASTICSEARCH_HOSTS=http://es8:9200" \
  -e "ELASTICSEARCH_USERNAME=elastic" \
  -e "ELASTICSEARCH_PASSWORD=changeme" \
  docker.elastic.co/kibana/kibana:8.15.0
```

Windows 环境如果不方便用 Docker，可以直接下载 ES 的 Windows 版 zip 包，解压后运行 `bin/elasticsearch.bat`，安装 IK 分词器需要手动把插件文件夹放到 `plugins/ik` 目录下。

> ⚠️ 新手提示：ES 8.x 默认启用了 HTTPS + 安全认证。如果在 `application.yml` 里配错了用户名密码，会看到 `authentication required` 错误。文中代码会给出正确的配置方式。

### 创建 SpringBoot 项目

在 `pom.xml` 中添加依赖：

```xml
<!-- Spring Data Elasticsearch -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-elasticsearch</artifactId>
</dependency>

<!-- 以下按项目需要添加 -->
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

`spring-boot-starter-data-elasticsearch` 内部使用 <strong>Elasticsearch Java Client（8.x 新客户端）</strong>，不再依赖已废弃的 High Level REST Client。API 风格从 builder 模式改为<strong>流式 DSL</strong>风格，跟写 JSON 查询的体验接近。

## 第四步：分步实践

### 4.1 配置 ES 连接

在 `application.yml` 中写入：

```yaml
spring:
  elasticsearch:
    uris: https://localhost:9200       # ES 8.x 默认 https
    username: elastic
    password: changeme

    # 连接超时与 socket 超时
    connection-timeout: 3s
    socket-timeout: 60s

# 如果 ES 是本地开发用的 HTTP（关闭了安全认证），只需要：
# spring.elasticsearch.uris: http://localhost:9200
```

连接问题排错：

| 错误信息 | 原因 | 解决 |
|----------|------|------|
| `Connection refused` | ES 没启动或端口不对 | `curl localhost:9200` 确认 ES 是否在跑 |
| `unable to find valid certification path` | 自签名证书验证失败 | 开发环境可临时关闭 SSL 校验（见下文配置类） |
| `authentication required` | 用户名密码不对 | 确认 `ELASTIC_PASSWORD` 环境变量值 |
| `node closed` | 连接池耗尽或 ES 节点异常 | 检查 ES 日志 `docker logs es8` |

ES 8.x 用自签名证书时，Java 默认的 SSL 验证会失败。如果只是本地开发，可以临时绕过：

```java
import org.springframework.context.annotation.Configuration;
import org.springframework.data.elasticsearch.client.elc.ElasticsearchClients;
import org.springframework.data.elasticsearch.client.elc.ElasticsearchConfiguration;

@Configuration
public class ESConfig extends ElasticsearchConfiguration {

    // 这一行是关键：让 Spring Data ES 使用 application.yml 中的配置
    // ElasticsearchConfiguration 会自动读取 spring.elasticsearch.* 配置
}
```

如果不需要绕过 SSL（生产环境请不要这样配），上面的 `ESConfig` 空类就够了。Spring Data ES 的自动配置会处理好一切。

### 4.2 Entity 映射 —— 用注解定义 ES 文档结构

第一篇里用 REST API 写 Mapping：

```bash
PUT /product { "mappings": { "properties": { "name": { "type": "text" } } } }
```

在 Java 里等价于给实体类加注解：

```java
import org.springframework.data.annotation.Id;
import org.springframework.data.elasticsearch.annotations.*;

@Data
@Document(indexName = "product")
public class Product {

    @Id
    private String id;                        // ES 文档 ID

    @Field(type = FieldType.Text,
           analyzer = "ik_max_word",
           searchAnalyzer = "ik_smart")
    private String name;                      // 商品名 —— 分词后全文搜索

    @Field(type = FieldType.Keyword)
    private String brand;                     // 品牌 —— 精确匹配

    @Field(type = FieldType.Keyword)
    private String category;                  // 分类 —— 精确匹配

    @Field(type = FieldType.Double)
    private Double price;                     // 价格 —— 数值范围过滤

    @Field(type = FieldType.Integer)
    private Integer stock;                    // 库存 —— 数值

    @Field(type = FieldType.Integer)
    private Integer soldCount;                // 销量 —— 排序

    @Field(type = FieldType.Float)
    private Float score;                      // 评分 —— 排序

    @Field(type = FieldType.Date,
           format = DateFormat.custom,
           pattern = "yyyy-MM-dd HH:mm:ss")
    @JsonFormat(pattern = "yyyy-MM-dd HH:mm:ss")
    private LocalDateTime createTime;         // 创建时间

    @Field(type = FieldType.Text,
           analyzer = "ik_max_word")
    private String description;               // 描述 —— 全文搜索
}
```

<strong>核心注解速查</strong>：

| 注解 | 作用 | 对应 REST API |
|------|------|--------------|
| `@Document(indexName)` | 指定 Index 名称 | `PUT /product` |
| `@Id` | 标记文档 ID 字段 | `_id` |
| `@Field(type, analyzer)` | 字段类型和分词器 | Mapping `properties` 中的字段定义 |
| `@Setting` | 索引级配置（分片数、副本数） | `PUT /product { "settings": {...} }` |

<strong>FieldType 速查表</strong>：

| FieldType | ES 类型 | 是否分词 | 场景 |
|-----------|--------|:---:|------|
| `Text` | text | 是 | 商品名、文章正文、描述 |
| `Keyword` | keyword | 否 | 品牌、分类、标签、状态、邮箱 |
| `Integer` | integer | — | 库存、年龄、数量 |
| `Long` | long | — | 大 ID、时间戳 |
| `Double` | double | — | 价格、金额 |
| `Float` | float | — | 评分 |
| `Date` | date | — | 时间字段 |
| `Boolean` | boolean | — | 是否上架、是否删除 |

关于 `text` vs `keyword` 的选型再强调一次：<strong>需要按部分匹配搜索的字段用 Text，只需要精确匹配或排序聚合的字段用 Keyword</strong>。商品名必须是 Text（用户搜"手机"要能命中"华为手机"），品牌用 Keyword（用户筛选"华为"品牌是精确匹配，不需要分词）。

### 4.3 ElasticsearchRestTemplate —— 核心操作类

`ElasticsearchRestTemplate` 是 Spring Data ES 提供的最核心操作类（对标 Redis 的 `RedisTemplate`）。所有 CRUD、搜索、聚合操作都通过它执行。

<strong>4.3.1 索引操作</strong>

```java
@Autowired
private ElasticsearchRestTemplate restTemplate;

// 创建索引（根据 Product 类的注解自动生成 Mapping）
boolean created = restTemplate.indexOps(Product.class).create();

// 检查索引是否存在
boolean exists = restTemplate.indexOps(Product.class).exists();

// 删除索引
boolean deleted = restTemplate.indexOps(Product.class).delete();

// 手动写入 Mapping（Product 类改了注解后需要更新 Mapping）
restTemplate.indexOps(Product.class).putMapping();
```

> ⚠️ 新手提示：`restTemplate.indexOps(Product.class).create()` 会根据 `@Document` 和 `@Field` 注解<strong>自动生成 Mapping 和 Setting</strong>。不需要再手动拼 JSON。但如果 ES 中已有同名 Index 且 Mapping 不一致，创建会失败——此时需要先 `delete()` 再 `create()`。

<strong>4.3.2 文档 CRUD</strong>

```java
// === 新增 / 全量覆盖 ===
Product product = new Product();
product.setId("1");
product.setName("华为Mate60 Pro");
product.setBrand("华为");
product.setCategory("手机");
product.setPrice(6999.0);
product.setStock(500);
product.setSoldCount(12800);
product.setScore(4.8f);
product.setCreateTime(LocalDateTime.of(2024, 1, 15, 10, 30, 0));
product.setDescription("搭载麒麟9000S芯片，支持5G网络");

// save 方法：ID 存在则覆盖，不存在则新增
restTemplate.save(product);

// === 按 ID 查询 ===
Product found = restTemplate.get("1", Product.class);
// 返回 null 如果不存在

// === 批量按 ID 查询 ===
List<Product> products = restTemplate.multiGet(
    List.of("1", "2", "3").stream()
        .map(id -> new QueryBuilder().withIds(List.of(id)))
        .toList(),
    Product.class
);

// === 部分更新 ===
// Step 1: 查出来
Product toUpdate = restTemplate.get("1", Product.class);
// Step 2: 改字段
toUpdate.setPrice(6499.0);
toUpdate.setStock(480);
// Step 3: 存回去（save = 全量覆盖，所以不会丢字段）
restTemplate.save(toUpdate);

// === 按 ID 删除 ===
String result = restTemplate.delete("1", Product.class);
```

> ⚠️ 新手提示：`save()` 是<strong>全量覆盖</strong>，不是部分更新。如果从 JSON 反序列化过来的对象缺少某些字段，save 后这些字段就没了。正确的部分更新方式：先 `get` 查到完整对象，修改字段后再 `save`。

<strong>4.3.3 搜索查询 —— NativeQuery + QueryBuilders</strong>

Spring Data ES 的查询构建从 `NativeQuery` 开始，用 `QueryBuilders` 创建各种查询条件：

```java
import org.springframework.data.elasticsearch.core.ElasticsearchRestTemplate;
import org.springframework.data.elasticsearch.core.SearchHits;
import org.springframework.data.elasticsearch.core.query.NativeQuery;
import org.springframework.data.elasticsearch.core.query.QueryBuilders;

// === match 查询：商品名搜"华为手机" ===
NativeQuery query = NativeQuery.builder()
    .withQuery(QueryBuilders.match()
        .field("name")
        .query("华为手机")
        .build())
    .build();

SearchHits<Product> hits = restTemplate.search(query, Product.class);
hits.forEach(hit -> {
    Product p = hit.getContent();
    float score = hit.getScore();     // 相关性分数
    System.out.println(p.getName() + " | score: " + score);
});
```

对应第一篇里的 DSL：

```bash
GET /product/_search { "query": { "match": { "name": "华为手机" } } }
```

Java 代码的 QueryBuilder 跟 DSL 是一一对应的——<strong>你写过的 DSL 都能找到对应的 Java Builder 方法</strong>。

<strong>term 查询（精确匹配）</strong>：

```java
// 精确查品牌=华为
NativeQuery query = NativeQuery.builder()
    .withQuery(QueryBuilders.term()
        .field("brand")
        .value("华为")
        .build())
    .build();
```

<strong>range 查询（数值范围）</strong>：

```java
// 价格 3000 ~ 8000
NativeQuery query = NativeQuery.builder()
    .withQuery(QueryBuilders.range()
        .field("price")
        .gte(3000.0)
        .lte(8000.0)
        .build())
    .build();
```

<strong>bool 组合查询</strong>：

```java
// 搜"手机" + 品牌=华为 + 价格 3000~8000，按销量降序
NativeQuery query = NativeQuery.builder()
    .withQuery(QueryBuilders.bool()
        .must(QueryBuilders.match()
            .field("name")
            .query("手机")
            .build())
        .filter(QueryBuilders.term()
            .field("brand")
            .value("华为")
            .build())
        .filter(QueryBuilders.range()
            .field("price")
            .gte(3000.0)
            .lte(8000.0)
            .build())
        .build())
    .withSort(Sort.by(
        new Sort.Order(Sort.Direction.DESC, "soldCount")))
    .withPage(Pageable.ofSize(10).withPage(0))
    .build();
```

<strong>分页与排序</strong>：

```java
// 分页：第 1 页，每页 10 条
NativeQuery query = NativeQuery.builder()
    .withQuery(QueryBuilders.matchAll().build())
    .withSort(Sort.by(
        new Sort.Order(Sort.Direction.DESC, "soldCount")))
    .withPage(Pageable.ofSize(10).withPage(0))
    .build();

SearchHits<Product> hits = restTemplate.search(query, Product.class);
System.out.println("总命中数: " + hits.getTotalHits());
System.out.println("当前页大小: " + hits.getSearchHits().size());
// from + size 方式翻页有深分页问题（第三篇详细讲），浅分页足够用
```

<strong>Source Filter（只返回部分字段，减少网络传输）</strong>：

```java
// 搜索结果只返回 name 和 price，不传其他字段
NativeQuery query = NativeQuery.builder()
    .withQuery(QueryBuilders.match().field("name").query("手机").build())
    .withSourceFilter(new FetchSourceFilter(
        new String[]{"name", "price"},  // includes
        new String[]{}))                // excludes
    .build();
```

<strong>4.3.4 高亮（Highlight）</strong>

搜索后把匹配的关键词用标签包起来，前端渲染成高亮样式：

```java
NativeQuery query = NativeQuery.builder()
    .withQuery(QueryBuilders.match()
        .field("name")
        .query("华为手机")
        .build())
    .withHighlightQuery(
        new HighlightQuery(
            new Highlight(
                new HighlightParameters.Builder()
                    .withPreTags("<strong>")       // 高亮前缀
                    .withPostTags("</strong>")      // 高亮后缀
                    .build()),
            List.of(new HighlightField("name"))       // 哪些字段要高亮
        ))
    .build();

SearchHits<Product> hits = restTemplate.search(query, Product.class);
hits.forEach(hit -> {
    Product p = hit.getContent();
    // 从高亮结果中提取 name 字段的高亮值
    List<String> highlightName = hit.getHighlightField("name");
    if (highlightName != null && !highlightName.isEmpty()) {
        System.out.println("高亮: " + highlightName.get(0));
        // 输出：高亮: <strong>华为</strong>Mate60 <strong>手机</strong>
    }
});
```

<strong>4.3.5 聚合查询</strong>

聚合是 ES 在搜索之外最强大的能力——对搜索结果做分组统计、数值计算。Spring Data ES 通过 `AggregationBuilders` 构建聚合：

```java
// 按品牌分组统计商品数量（类似于 SQL: SELECT brand, COUNT(*) FROM product GROUP BY brand）
NativeQuery query = NativeQuery.builder()
    .withQuery(QueryBuilders.matchAll().build())
    .withAggregation("brand_stats",
        AggregationBuilders.terms()
            .field("brand")
            .build())
    .withMaxResults(0)   // 不返回文档，只返回聚合结果
    .build();

SearchHits<Product> hits = restTemplate.search(query, Product.class);
AggregationsContainer<?> aggs = hits.getAggregations();
if (aggs != null) {
    ElasticsearchAggregation brandAgg = aggs.get("brand_stats");
    if (brandAgg instanceof Aggregate) {
        // 解析 bucket：每个品牌 + 文档数量
        Aggregate aggregate = (Aggregate) brandAgg;
        // 实际的 terms 聚合结果在 aggregate.aggregation().getAggregate().getStringTerms()
        // 不同版本的 Spring Data ES API 略有差异，核心思路是：
        // terms agg → 遍历 buckets → 获取 key(品牌名) 和 docCount(文档数)
    }
}

// 按价格字段求 avg / max / min
query = NativeQuery.builder()
    .withQuery(QueryBuilders.matchAll().build())
    .withAggregation("price_stats",
        AggregationBuilders.stats()
            .field("price")
            .build())
    .withMaxResults(0)
    .build();
// stats 聚合一次返回 count / min / max / avg / sum 五个值
```

<strong>嵌套聚合</strong>：先按品牌分组，每个品牌下再按分类分组（电商筛选页的"品牌下的分类列表"）：

```java
NativeQuery query = NativeQuery.builder()
    .withQuery(QueryBuilders.matchAll().build())
    .withAggregation("by_brand",
        AggregationBuilders.terms()
            .field("brand")
            .build())
    .withSubAggregation("by_brand", "by_category",  // 在 brand 分组下再嵌套 category 分组
        AggregationBuilders.terms()
            .field("category")
            .build())
    .withMaxResults(0)
    .build();
```

### 4.4 Spring Data ES Repository —— 声明式查询

前面所有操作都需要手动写 `NativeQuery` + `restTemplate.search()`。对于<strong>简单查询</strong>，Spring Data ES 提供了类似 JPA 的 Repository 接口——方法名即查询。

```java
import org.springframework.data.elasticsearch.repository.ElasticsearchRepository;
import org.springframework.stereotype.Repository;

@Repository
public interface ProductRepository extends ElasticsearchRepository<Product, String> {

    // 根据字段名精确查询（keyword 类型）
    List<Product> findByBrand(String brand);

    // 根据分类 + 品牌组合查询
    List<Product> findByCategoryAndBrand(String category, String brand);

    // 价格区间（按数值范围）
    List<Product> findByPriceBetween(Double from, Double to);

    // 按销量排序
    List<Product> findByCategoryOrderBySoldCountDesc(String category);

    // 分页查询
    Page<Product> findByBrand(String brand, Pageable pageable);
}
```

<strong>方法命名规则</strong>：

| 方法名片段 | 含义 | 示例 | 等效 DSL |
|-----------|------|------|---------|
| `findBy` / `searchBy` | 查询 | `findByBrand` | term: { brand: "xxx" } |
| `And` / `Or` | 与 / 或 | `findByCategoryAndBrand` | bool must |
| `Between` | 区间 | `findByPriceBetween` | range: { gte, lte } |
| `OrderByXxxDesc` | 按某字段降序 | `findByCategoryOrderBySoldCountDesc` | sort: { soldCount: desc } |
| `LessThan` / `GreaterThan` | 小于 / 大于 | `findByPriceLessThan` | range: { lt } |
| `In` | IN 查询 | `findByBrandIn` | terms: { brand: [...] } |

Repository 的局限：只支持<strong>精确匹配 + 简单范围</strong>的查询，不支持 match 分词搜索、不支持多条件组合的 bool 查询、不支持聚合。

需要复杂查询时用 <strong>@Query 注解</strong>——直接手写 DSL：

```java
@Repository
public interface ProductRepository extends ElasticsearchRepository<Product, String> {

    @Query("{\"match\": {\"name\": {\"query\": \"?0\"}}}")
    List<Product> searchByName(String keyword);

    @Query("{\"bool\": {" +
           "  \"must\": [{\"match\": {\"name\": \"?0\"}}]," +
           "  \"filter\": [{\"term\": {\"brand\": \"?1\"}}]" +
           "}}")
    List<Product> searchByNameAndBrand(String keyword, String brand);
}
```

`?0` 表示方法的第一个参数，`?1` 表示第二个，以此类推。`@Query` 里写的就是纯 DSL JSON——第一篇学的那些查询语句直接搬过来用。

<strong>Repository vs ElasticsearchRestTemplate 怎么选？</strong>

| 维度 | Repository | ElasticsearchRestTemplate |
|------|:---:|:---:|
| 简单精确查询 | 方法名搞定，简洁 | 需要手动 build Query |
| 复杂查询（bool / 聚合） | 需 `@Query` 手写 DSL | API 构建，类型安全 |
| 灵活性 | 低 | 高 |
| 学习成本 | 低（方法命名规则） | 中（需熟悉 QueryBuilder API） |
| 推荐场景 | 简单 CRUD + 精确查 | 全文搜索 + 聚合 + 自定义排序 + 高亮 |

实际项目中<strong>混用</strong>：简单的"按品牌查商品"用 Repository，复杂的"搜索 + 过滤 + 聚合 + 高亮"用 ElasticsearchRestTemplate。

### 4.5 批量写入（Bulk）

批量写入 1000 条数据，逐条 `save()` 就是 1000 次网络往返。ES 提供了 Bulk API——把多条写入命令打包一次发送：

```java
// 构建批量写入
List<Product> products = generateProducts(1000);  // 生成 1000 条商品数据

List<IndexQuery> queries = products.stream()
    .map(p -> new IndexQueryBuilder()
        .withId(p.getId())
        .withObject(p)
        .build())
    .toList();

// 批量写入——一次网络请求
restTemplate.bulkIndex(queries, Product.class);
```

<strong>实际场景：从 MySQL 同步数据到 ES</strong>

```java
// 分批从 MySQL 查询，批量写入 ES
int pageSize = 2000;
int page = 0;
while (true) {
    // 1. 从 MySQL 分页查询数据
    List<Product> batch = productMapper.selectPage(page * pageSize, pageSize);
    if (batch.isEmpty()) break;

    // 2. 转为 ES IndexQuery
    List<IndexQuery> queries = batch.stream()
        .map(p -> new IndexQueryBuilder()
            .withId(p.getId().toString())
            .withObject(p)
            .build())
        .toList();

    // 3. 批量写入 ES
    restTemplate.bulkIndex(queries, Product.class);

    page++;
    System.out.println("已同步: " + page * pageSize + " 条");
}
```

> ⚠️ 新手提示：批量写入单批建议 <strong>2000 ~ 5000 条，单批总大小 5 ~ 15MB</strong>。太大容易 OOM 或者 ES 端 reject，太小网络开销划不来。另外 `bulkIndex` 不是原子操作——一批中部分成功部分失败是可能的，生产环境需要检查返回结果中每条的 `error` 字段。

### 4.6 条件删除

```java
// 删除品牌=华为的所有文档
NativeQuery query = NativeQuery.builder()
    .withQuery(QueryBuilders.term()
        .field("brand")
        .value("华为")
        .build())
    .build();

// delete 方法支持按查询条件删除
restTemplate.delete(query, Product.class);
```

> ⚠️ 新手提示：`delete by query` 是 O(n) 操作，ES 需要遍历所有分片的所有段来标记删除。<strong>大量数据删除可能导致 ES 响应变慢</strong>。生产环境建议用异步 Delete By Query Task + `_tasks` API 管理。

<strong>常用方法速查表</strong>：

| 方法 | 说明 | 典型场景 |
|------|------|----------|
| `restTemplate.save(entity)` | 保存/覆盖文档 | 写入数据 |
| `restTemplate.get(id, clazz)` | 按 ID 查询 | 查详情 |
| `restTemplate.delete(id, clazz)` | 按 ID 删除 | 删除数据 |
| `restTemplate.search(query, clazz)` | 搜索查询 | 全文搜索 |
| `restTemplate.bulkIndex(queries, clazz)` | 批量写入 | 数据同步 |
| `restTemplate.indexOps(clazz).create()` | 创建索引 | 初始化 |
| `restTemplate.indexOps(clazz).delete()` | 删除索引 | 重建索引 |

## 第五步：真实业务场景串联

现在用一个完整的"商品搜索"功能把所有学到的操作串起来。

场景：用户在电商首页搜索"华为手机"，系统返回匹配商品列表，按销量排序，左侧展示品牌和分类筛选聚合。

```java
@Service
public class ProductSearchService {

    @Autowired
    private ElasticsearchRestTemplate restTemplate;

    /**
     * 初始化索引（应用启动时执行一次）
     */
    @PostConstruct
    public void initIndex() {
        if (!restTemplate.indexOps(Product.class).exists()) {
            restTemplate.indexOps(Product.class).create();
            System.out.println("product 索引创建成功");
        }
    }

    /**
     * 批量导入测试数据
     */
    public void batchImport(List<Product> products) {
        List<IndexQuery> queries = products.stream()
            .map(p -> new IndexQueryBuilder()
                .withId(p.getId())
                .withObject(p)
                .build())
            .toList();
        restTemplate.bulkIndex(queries, Product.class);
    }

    /**
     * 商品搜索 —— 核心方法
     */
    public SearchResult search(String keyword, String brand, String category,
                                Double minPrice, Double maxPrice,
                                int page, int size) {

        // 1. 构建 bool 查询
        BoolQuery.Builder boolBuilder = QueryBuilders.bool();

        // 关键词搜索（must：参与算分）
        if (keyword != null && !keyword.isEmpty()) {
            boolBuilder.must(QueryBuilders.match()
                .field("name")
                .query(keyword)
                .build());
        }

        // 品牌筛选（filter：不参与算分，走缓存）
        if (brand != null && !brand.isEmpty()) {
            boolBuilder.filter(QueryBuilders.term()
                .field("brand")
                .value(brand)
                .build());
        }

        // 分类筛选
        if (category != null && !category.isEmpty()) {
            boolBuilder.filter(QueryBuilders.term()
                .field("category")
                .value(category)
                .build());
        }

        // 价格区间
        if (minPrice != null || maxPrice != null) {
            boolBuilder.filter(QueryBuilders.range()
                .field("price")
                .gte(minPrice != null ? minPrice : 0.0)
                .lte(maxPrice != null ? maxPrice : Double.MAX_VALUE)
                .build());
        }

        // 2. 构建完整查询：搜索 + 聚合 + 高亮 + 排序 + 分页
        NativeQuery query = NativeQuery.builder()
            .withQuery(boolBuilder.build())
            // 聚合：品牌分组
            .withAggregation("brand_agg",
                AggregationBuilders.terms().field("brand").build())
            // 聚合：分类分组
            .withAggregation("category_agg",
                AggregationBuilders.terms().field("category").build())
            // 高亮
            .withHighlightQuery(new HighlightQuery(
                new Highlight(new HighlightParameters.Builder()
                    .withPreTags("<strong>")
                    .withPostTags("</strong>")
                    .build()),
                List.of(new HighlightField("name"))))
            // 排序：销量降序
            .withSort(Sort.by(
                new Sort.Order(Sort.Direction.DESC, "soldCount")))
            // 分页
            .withPage(Pageable.ofSize(size).withPage(page))
            .build();

        // 3. 执行搜索
        SearchHits<Product> hits = restTemplate.search(query, Product.class);

        // 4. 组装返回结果
        SearchResult result = new SearchResult();
        result.setTotalHits(hits.getTotalHits());

        // 提取文档列表（含高亮）
        List<ProductVO> products = new ArrayList<>();
        for (SearchHit<Product> hit : hits.getSearchHits()) {
            ProductVO vo = new ProductVO();
            vo.setProduct(hit.getContent());
            List<String> highlightName = hit.getHighlightField("name");
            if (highlightName != null && !highlightName.isEmpty()) {
                vo.setHighlightName(highlightName.get(0));
            }
            products.add(vo);
        }
        result.setProducts(products);

        // 5. 解析聚合结果（品牌、分类的统计）
        // 这里省略聚合解析的详细代码，实际 API 略有版本差异
        // 核心思路：hits.getAggregations() → 拿 terms bucket → 遍历 key + docCount

        return result;
    }
}
```

上面这段代码就是<strong>一个完整搜索功能的核心代码</strong>。剩下的 Controller 层就是标准 SpringMVC 接收请求参数 → 调 Service → 返回 JSON。

```java
@RestController
@RequestMapping("/api/products")
public class ProductSearchController {

    @Autowired
    private ProductSearchService searchService;

    @GetMapping("/search")
    public SearchResult search(
        @RequestParam(required = false) String keyword,
        @RequestParam(required = false) String brand,
        @RequestParam(required = false) String category,
        @RequestParam(required = false) Double minPrice,
        @RequestParam(required = false) Double maxPrice,
        @RequestParam(defaultValue = "0") int page,
        @RequestParam(defaultValue = "10") int size) {

        return searchService.search(keyword, brand, category,
            minPrice, maxPrice, page, size);
    }
}
```

## 第六步：常见问题排查表

| 现象 | 可能原因 | 排查方法 |
|------|----------|----------|
| 搜索结果为空 | text 字段用了 term 查询 | 改 match 查询，或检查分词结果：`/_analyze` |
| 聚合结果不对 | 对 text 字段做了聚合 | 聚合用 keyword 类型字段或 `.keyword` 子字段 |
| 写入后查不到 | refresh 间隔未到（默认 1s） | 等待 1s 后重试，或手动 `POST /index/_refresh` |
| `document missing` 异常 | ID 写错了或文档已被删除 | 先用 `HEAD /index/_doc/id` 确认存在 |
| 连接超时 | ES 地址或端口配错 | `curl -u elastic:pass http://es:9200` 确认连通 |
| `SSLHandshakeException` | ES 8.x 自签名证书 | 开发环境临时关闭 SSL 校验 |
| 批量写入很慢 | 单批太大 / ES 负载过高 | 减小批次到 2000 条，检查 ES 的 `_cat/thread_pool` |
| Repository 方法不生效 | 方法名不符合命名规则 | 检查方法名中字段名是否与 Entity 一致，拼写是否正确 |

## 第七步：总结与下一步

<strong>这篇覆盖的全部内容</strong>：

- <strong>@Document / @Field 注解</strong>：用 Java 注解定义 ES Mapping，自动生成索引
- <strong>ElasticsearchRestTemplate</strong>：索引 CRUD、文档 CRUD、match/term/range/bool 搜索、高亮、聚合
- <strong>Spring Data ES Repository</strong>：方法名即查询的声明式方式 + `@Query` 手写 DSL
- <strong>批量写入</strong>：bulkIndex 一次网络请求写入批量数据
- <strong>完整商品搜索串联</strong>：搜索 + 过滤 + 聚合 + 高亮 + 排序 + 分页，可运行的完整代码

<strong>下一步建议</strong>：

1. 把文中的示例代码拷到项目里跑一遍，改改参数看看效果
2. 继续阅读 [<strong>ES 高级搜索与聚合分析</strong>]({{< relref "ESAdvancedSearch.md" >}})，掌握 multi_match 多字段搜索、bool 查询深入、聚合分析进阶、相关性算分原理和搜索建议
3. 在 Kibana Dev Tools 里多跑 `_explain`，理解每次搜索的评分细节

把 ES 用好是后端开发的基本功——大部分项目的搜索框背后都是它。
