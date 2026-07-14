---
title: "admin-bff 接口全面就绪 + 前端功能规划定稿 + 安全统一"
date: 2023-07-03T11:30:03+00:00
tags: ["工程实践", "SpringCloud", "每日日报"]
categories: ["技术类"]
author: "yaomingye"
showToc: true
TocOpen: false
draft: false
hidemeta: false
comments: false
description: "admin-bff 36个接口全面覆盖前端页面、前端功能规划定稿、RBAC 角色数据初始化、PermitAllProvider 统一配置、7个模块测试通过"
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

## 今日工作

### 1. admin-bff 接口全面检查与补齐

前端功能规划定稿后，逐一比对前端目录树与 admin-bff 实际接口，发现 1 处缺失（商品图片接口），已补齐。

补齐内容：

```
ProductPhotoFeignClient（新建）→ mall-product-client
AdminProductExtraController 新增 productPhoto 5 个 CRUD 接口
```

最终 admin-bff 共 **36 个接口**，覆盖前端全部页面。这是前端开发可以直接对着写的接口清单。

### 2. 前端功能规划定稿

`docs/30-admin前端功能规划.md` 经过多轮讨论最终定稿。核心原则：

**页面按角色可见：**

| 角色 | 可见页面 |
|:----|:---------|
| 超级管理员 | 全部（系统管理/商品/订单/营销/基础数据/评价） |
| 运营部 | 商品管理/营销/首页/基础数据/评价 |
| 客服部 | 订单管理/评价 |
| 财务部 | 订单管理（只读金额） |

**不开发的前端页面：** 菜单管理、角色管理、部门管理、岗位管理、字典管理、定时任务——这些由开发维护 DB，不出现在前端。

权限关系简化为：部门 + 岗位 → 角色 → 菜单，超级管理员只需要在用户管理里选部门/岗位，权限自动带出。

### 3. RBAC 数据初始化

向 `cloud_mall_admin` 数据库写入预设数据：

```
部门：运营部、客服部、财务部
角色：超级管理员（已有）、运营（ops）、客服（service）、财务（finance）
```

岗位表（` auth_job `）待预设，后续补上。

### 4. 商品上下架字段补全

发现 `product` 表**没有上下架字段**——整个商品系统没有上架/下架的概念。已修复：

```sql
ALTER TABLE product ADD COLUMN status tinyint(1) DEFAULT 1 COMMENT '上下架状态 1:上架 0:下架';
```

`ProductEntity` 同步新增 `status` 字段，文档补充商品列表支持按状态筛选。

### 5. admin-bff 精简

砍掉的冗余功能：

```
配送地址管理    → 地址在订单详情页内修改，不需要独立页面
手机号登录      → C 端专用，admin 用账号密码登录
字典管理        → 技术常量，运营不需要配 key-value
行政区域        → C 端收货地址用的，admin 不需要管
短信记录        → admin 使用账号密码登录，没用过短信
```

### 6. 安全配置统一

auth-starter 重构，统一打包：

```
JwtAuthenticationFilter → JWT 验签 + Redis 黑名单（通用过滤器）
PermitAllProvider       → 各服务 C 端白名单扩展点
默认 SecurityFilterChain → 含 JWT 过滤 + 白名单合并（@ConditionalOnMissingBean）
```

6 个有 C 端接口的服务全部配置 PermitAllProvider：

```
mall-product     ✅  /v1/mobile/**
mall-basic      ✅  /v1/mobile/**
mall-customer   ✅  /v1/mobile/**
mall-order      ✅  /v1/mobile/trade/**
mall-pay        ✅  /v1/mobile/pay/**
mall-recommend  ✅  /v1/mobile/** + /mobile/v1/**
```

### 7. 模块测试覆盖

7 个模块测试脚本全部通过：

| 模块 | 测试结果 |
|:----|:--------:|
| mall-admin | 20/20 ✅ |
| mall-product | 28/28 ✅ |
| mall-order | 12/12 ✅ |
| mall-basic | 21/21 ✅ |
| mall-marketing | 21/21 ✅ |
| mall-customer | 8/8 ✅ |
| mall-message | 4/4 ✅ |

未测：pay（未接支付宝）、recommend（推荐算法依赖）。

### 8. 业务缺失

系统目前缺失库存管理和物流模块，导致订单状态流转不完整：

```
待支付 → 已支付 → 已发货（缺物流支撑）→ 已完成
```

库存直接写在 `product` 表的 `stock` 字段里， `reduceStock()` 走 MySQL 行锁，没有独立库存服务。这些留待后续补齐。
