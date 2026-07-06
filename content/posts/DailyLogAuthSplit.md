---
title: "今日日报：auth拆分、模块更名、RSA删除、全量编译"
date: 2023-06-21T11:30:03+00:00
tags: ["工程实践", "SpringCloud", "每日日报"]
categories: ["每日日报"]
author: "yaomingye"
showToc: false
TocOpen: false
draft: false
hidemeta: false
comments: false
description: "今日日报：auth 模块业务拆分、四组模块更名、RSA 密码加密层删除、全量编译验证"
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

### 1. auth 模块拆分与清理

- `mall-auth` 服务整体删除：业务代码（用户管理/RBAC/收货地址）全部迁入 `mall-admin` ，仅 JWT + Redis 黑名单功能原属 auth，现已整合进 mall-admin
- `mall-auth-client` 删除：所有调用方（mall-basic、mall-marketing、mall-message、mall-product、mall-order、mall-order-client）依赖全部切换至 `mall-admin-client`
- `mall-auth-api-starter` 保留不动（AuthApiInterceptor + FeignAuthInterceptor 全项目在用）

### 2. 模块更名（四组）

| 原名 | 新名 | 说明 |
|------|------|------|
| `mall-admin-api` | `mall-admin-bff` | BFF 聚合层 |
| `mall-mobile-api` | `mall-mobile-bff` | BFF 聚合层 |
| `mall-member` | `mall-customer` | C 端业务服务 |
| `mall-member-client` | `mall-customer-client` | Feign 接口 |

- 对应 Nacos 注册名同步更新：mall-admin-bff, mall-mobile-bff, mall-customer-api
- Gateway 路由同步：新增 /api/customer/**, /api/admin-api/**, /api/admin/**, /api/mobile/** 路由
- Nacos 配置：新建 mall-customer-api-dev.yaml, mall-admin-api-dev.yaml，删除旧名配置

### 3. 删除 RSA 密码加密层

原登录流程：前端 JS RSA 加密 → 后端 RSA 私钥解密 → BCrypt 校验

HTTPS 已提供传输层加密，业务代码不再需要第二层 RSA，直接删除：

```java
// 删除前
String decodePassword = passwordUtil.decodeRsaPassword(userLoginDTO.getPassword());
UsernamePasswordAuthenticationToken token =
    new UsernamePasswordAuthenticationToken(userLoginDTO.getUsername(), decodePassword);

// 删除后
UsernamePasswordAuthenticationToken token =
    new UsernamePasswordAuthenticationToken(userLoginDTO.getUsername(), userLoginDTO.getPassword());
```

同时清理由此引入的 RSA 私钥硬编码和 `PasswordUtil.decodeRsaPassword()` 方法。

### 4. docs/ 清理

- 删除所有无序号重复文件
- 已完成文档标注（已完成）后缀
- 整理后 19 个文件，按创建时间排序

### 5. 验证

- 全量 Maven 编译通过，零错误

## 提交

```
73f4aaf refactor: auth拆分 + 模块更名 + RSA删除
```
