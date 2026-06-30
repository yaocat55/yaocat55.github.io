---
title: "微服务文档重构：API 分组、BFF 聚合与文档拆迁"
date: 2023-03-16T11:30:03+00:00
tags: ["工程实践", "SpringBoot", "实践教程"]
categories: ["技术类"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "一天之内干了什么：从 Swagger 文档三层分组到 BFF 聚合接口，再到 README 大瘦身——串起来就是一套微服务文档治理的组合拳。"
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

# 今天干了啥：分组、聚合、拆文档

今天没写啥牛逼的业务代码，大部分时间在跟文档和接口结构较劲。记个流水账。

## 一、发现 doc.html 不对劲

打开一个微服务的 Knife4j 文档页，下拉框里赫然列着七八个其他服务的分组。一点就 404，明摆着是隔壁服务跑这儿串门了。

第一反应是 knife4j 的配置问题，加了一堆 `enableXxx: false` ，重启——纹丝不动。后来发现 knife4j 基础 starter 压根没有跨服务聚合功能。真正的原因藏在 SpringDoc 的配置链路里，某些共享配置文件往 swagger-config 端点的 `urls` 字段里塞了外部的分组 URL。

最后在每个服务的本地 `application.yml` 把 springdoc 配置全写死，用本地覆盖干掉了注入。顺便把相关的配置说明写进系统设计文档了。

**产出：** 一篇踩坑博客 + 配置修复。

## 二、给接口文档分了三个层

之前所有微服务的接口都在一个组里，前端要看、后端也要看、微服务 Feign 调用也混在一起。这次给每个服务分了三个 Swagger 分组：

- 前端接口（给前端的）
- 后台接口（给管理后台的）
- 内部接口（给其他微服务调用的）

每个服务各自独立，不再相互干扰。

三个分组的接口在代码上也做了物理隔离——新建了 `controller/internal/` 包，只给微服务间 Feign 调用用。顺便把原来跟前端接口冲突的方法也挪过去了，URL 统一加 `/v1/internal/` 前缀，从根上避免路由冲突。

## 三、把前端需要的接口聚合到 BFF 层

之前前端写个页面经常要调好几个微服务，商品详情页调了 5 次接口。虽然 BFF 层之前就已经做了一些聚合（首页聚合、商品详情聚合、下单预览聚合），但管理后台这边基本还是透传状态。

给管理后台 BFF 加了两个聚合接口：
- 用户编辑页：一次查出用户信息 + 角色列表 + 部门树 + 岗位列表
- 商品编辑页：一次查出商品详情 + 分类树（品牌和单位的数据等后续补 Feign 客户端）

同时给两个 BFF 服务都加上了 Swagger 文档。以后前端重写，只看这两个 BFF 的文档就够了，不用再翻 8 个微服务的接口。

## 四、捋清楚前端到底调了哪些后端接口

这个项目前端有两个：一个小程序（UniApp），一个管理后台（Vue）。之前一直没有一份完整的文档说明前端每个页面调了后端的哪些接口。

花了点时间用 grep 把两个前端项目扫了一遍，列了 50 多个 API 调用，每个都去后端代码里 grep 确认接口路径和 Controller 方法。最后还真找出 4 个前端写了但后端不存在的接口。

结果写成了一份映射文档，以后谁要改接口不用两边来回翻。

## 五、给 README 减肥

原来的 README 太长了，什么数据库每个表名、Nacos 配置清单、多仓库拆分方案全都往里塞。拆成了 5 个独立文档放 `docs/` 目录下，README 只留核心概览。

顺便修了一个 `.gitignore` 的坑——之前把整个 `docs/` 目录都排除掉了，导致加的文档提交不上去，改成只排除设计文档目录。

## 总结

一天下来代码量不大，全是结构性的活儿。Swagger 分组隔离、BFF 聚合接口、前端接口映射文档、README 瘦身——串起来就是一套微服务文档治理的组合拳。下次有人问"怎么知道调哪个接口"，直接甩 BFF 的文档地址就行。

---

> **占位：** 无
