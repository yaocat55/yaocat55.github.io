---
title: "Spring Security + JWT 企业级鉴权实战"
date: 2022-09-18T07:00:19+00:00
tags: ["安全认证", "实践教程", "SpringBoot"]
categories: ["SpringSecurity类"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "从教程版起步，逐步替换为真实商城项目源码：JJWT+Redis双key Token方案、@NoLogin自动扫描、Filter异常桥接、User→Role→Menu三表联查权限、RSA传输加密+短信双认证+异地登录检测的完整登录流程"
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

# Spring Security + JWT 企业级鉴权实战：从零概念到完整代码实现

> <strong>阅读前提</strong>：本文假设你已经会使用 Spring Boot 写基本的 CRUD 接口。如果你从未接触过 Spring Security，从这篇开始即可。

本文按照"<strong>先搞懂概念 → 教程版完整实现 → 生产版逐项升级 → 验证排错</strong>"的顺序组织。如果你只想快速跑通一个能用的版本，读完 Part 1 后直接看 Part 2 即可；如果你想理解企业级项目的真实做法，需要完整读完。

---

# Part 1：先搞懂要做什么

在写任何代码之前，先把三个问题搞清楚：<strong>认证和授权到底是什么？Spring Security 怎么运作的？JWT 是什么？</strong>

---

## 一、从一个没有防护的接口说起

假设你用 Spring Boot 写了一个用户管理接口：

```java
@RestController
@RequestMapping("/api/admin")
public class AdminController {

    @GetMapping("/users")
    public List<User> listAllUsers() {
        // 返回系统中所有用户信息
        return userService.findAll();
    }

    @DeleteMapping("/users/{id}")
    public String deleteUser(@PathVariable Long id) {
        userService.deleteById(id);
        return "删除成功";
    }
}
```

启动项目后，任何人只要知道 URL，就能直接访问这些接口——不需要登录，不需要权限。这在企业生产环境中是不可接受的。

你需要回答两个核心问题：

1. <strong>你是谁？（认证 Authentication）</strong>——访问者是否已经登录？用户名密码是否正确？
2. <strong>你能做什么？（授权 Authorization）</strong>——登录之后，你有没有权限删除用户？还是只能查看？

Spring Security 就是用来解决这两个问题的框架。

---

## 二、核心概念：认证与授权

### 2.1 认证（Authentication）——"你是谁"

认证就是验证用户身份的过程。最常见的认证方式是<strong>用户名 + 密码</strong>：

```
用户提交用户名密码 → 系统验证是否正确 → 正确则签发凭证（如 JWT） → 用户持凭证访问
```

认证需要回答的问题：<strong>这个人真的是他声称的那个人吗？</strong>

业务上常见的认证方式：

| 方式 | 说明 | 使用场景 |
|------|------|------|
| 用户名 + 密码 | 最基础的认证方式 | 所有系统的标配 |
| 手机验证码 | 通过短信验证 | 移动端登录、快速注册 |
| 邮箱 + 密码 | 类似用户名密码 | 国际化产品 |
| 扫码登录 | 通过已登录设备扫码确认 | Web 端快速登录 |
| 第三方登录 | OAuth2.0（微信 / 企业微信 / 钉钉） | 企业办公、社交产品 |
| 指纹 / 面容 | 生物识别 | App 端便捷登录 |

### 2.2 授权（Authorization）——"你能做什么"

授权发生在认证<strong>之后</strong>。系统已经知道你是谁了，现在需要判断你有没有权限做某件事。

授权需要回答的问题：<strong>这个人有资格执行这个操作吗？</strong>

业务上常见的授权模式：

| 模式 | 说明 | 示例 |
|------|------|------|
| 角色授权（RBAC） | 基于角色控制权限 | `ROLE_ADMIN` 可以删除用户，`ROLE_USER` 不行 |
| 权限码授权 | 基于细粒度权限码 | `user:delete` 权限才能删除用户 |
| 资源级授权 | 基于数据归属 | 只能查看自己部门的订单 |
| 动态授权 | 权限规则存储在数据库中 | 后台管理员可动态配置角色权限 |

### 2.3 认证与授权的关系

```mermaid
flowchart TD
    classDef startEnd fill:#F48FB1,stroke:#C2185B,stroke-width:2px,color:#212121,font-weight:bold;
    classDef condition fill:#E1BEE7,stroke:#7B1FA2,stroke-width:1.5px,color:#212121,font-weight:bold;
    classDef process fill:#F5F5F5,stroke:#9E9E9E,stroke-width:1.5px,color:#212121;
    classDef reject fill:#FFCDD2,stroke:#C62828,stroke-width:1.5px,color:#B71C1C,font-weight:bold;

    START([用户请求接口]) --> COND_AUTH{"是否已认证\n(有合法Token) ?"}
    COND_AUTH -- 否 --> RESP_401([返回 401\n请先登录])
    COND_AUTH -- 是 --> AUTH_DONE[认证通过\n确定用户身份]
    AUTH_DONE --> COND_AUTHZ{"是否有权限\n(角色/权限码) ?"}
    COND_AUTHZ -- 否 --> RESP_403([返回 403\n无权限访问])
    COND_AUTHZ -- 是 --> RESP_OK([正常响应业务数据])

    class START,RESP_401,RESP_OK,RESP_403 startEnd;
    class COND_AUTH,COND_AUTHZ condition;
    class AUTH_DONE process;
```

> <strong>关键理解</strong>：401（Unauthorized）和 403（Forbidden）的区别——401 是"我不知道你是谁，请先登录"；403 是"我知道你是谁，但你没资格做这件事"。前者是认证问题，后者是授权问题。

---

## 三、Spring Security 架构：一张图看懂所有组件

在写代码之前，先理解 Spring Security 的整体结构。不需要看源码，只需要知道每个组件是干什么的。

### 3.1 过滤器链（Filter Chain）

Spring Security 的核心是一组<strong>过滤器链</strong>。每个 HTTP 请求都会依次经过这条链上的所有过滤器，每个过滤器负责一件具体的事情。

```mermaid
flowchart LR
    classDef root fill:#1E88E5,stroke:#0D47A1,stroke-width:2px,color:#FFFFFF,font-weight:bold;
    classDef branch fill:#FFE082,stroke:#FFB300,stroke-width:2px,color:#5D4037,font-weight:bold;
    classDef leaf fill:#F5F5F5,stroke:#BDBDBD,stroke-width:1.5px,color:#212121;
    classDef highlight fill:#FFCCBC,stroke:#E64A19,stroke-width:1.5px,color:#D84315,font-weight:bold;

    ROOT[Spring Security<br/>过滤器链]

    ROOT --> B1[认证相关过滤器]
    B1 --> F1["🔐 UsernamePassword<br/>AuthenticationFilter<br/>处理用户名密码登录"]
    B1 --> F2["🔑 JwtAuthentication<br/>Filter 自定义<br/>从请求头提取JWT<br/>解析并设置认证状态"]

    ROOT --> B2[授权相关过滤器]
    B2 --> F3["✅ FilterSecurity<br/>Interceptor<br/>最终授权决策点<br/>判断是否有权限访问"]
    B2 --> F4["🛡️ ExceptionTranslation<br/>Filter<br/>将认证/授权异常<br/>转换为HTTP响应"]

    ROOT --> B3[安全基础过滤器]
    B3 --> F5["🧱 SecurityContext<br/>PersistenceFilter<br/>安全上下文持久化"]
    B3 --> F6["🚫 CsrfFilter<br/>CSRF防护<br/>前后端分离可关闭"]

    ROOT --> B4[核心组件]
    B4 --> C1["🏗️ AuthenticationManager\n认证管理器 接口\n默认实现: ProviderManager"]
    B4 --> C2["👤 UserDetailsService\n加载用户数据的接口\n你需要实现它"]
    B4 --> C3["🔒 PasswordEncoder\n密码加密器\n常用的: BCryptPasswordEncoder"]
    B4 --> C4["📋 SecurityContextHolder\n持有当前请求的\n认证状态 Authentication"]

    class ROOT root;
    class B1,B2,B3,B4 branch;
    class F1,F3,F5,F6,C1,C2,C3,C4 leaf;
    class F2 highlight;
```

### 3.2 核心组件一句话介绍

| 组件 | 作用 | 你需要做什么 |
|------|------|------|
| `SecurityContextHolder` | 持有当前请求用户的认证信息 | 不需要操作，Spring Security 自动管理 |
| `Authentication` | 代表"当前用户是谁"及其权限列表 | 登录成功后构造这个对象 |
| `UserDetailsService` | 根据用户名从数据库加载用户信息 | <strong>必须实现</strong>：写一个类去数据库查用户 |
| `AuthenticationManager` | 认证管理器，负责调用 `UserDetailsService` 验证用户 | 通常不需要自定义，Spring Security 有默认实现 |
| `PasswordEncoder` | 密码加密器，存库的密码必须加密 | 配置一个 `BCryptPasswordEncoder` Bean |
| `SecurityFilterChain` | 过滤器链配置，定义哪些 URL 需要什么权限 | <strong>最重要</strong>：自定义安全规则 |
| `ProviderManager` | `AuthenticationManager` 的默认实现，管理多个认证方式 | 不需要操作 |

### 3.3 一个请求走完过滤器链的全过程

```mermaid
sequenceDiagram
    participant C as 客户端
    participant F1 as SecurityContext<br/>PersistenceFilter
    participant F2 as JWT认证过滤器<br/>自定义
    participant F3 as FilterSecurity<br/>Interceptor
    participant F4 as ExceptionTranslation<br/>Filter
    participant API as Controller

    C->>F1: HTTP请求
    F1->>F1: 检查SecurityContext<br/>是否已有认证信息
    F1->>F2: 继续

    alt 请求头带了JWT
        F2->>F2: 1.提取Token<br/>2.解析JWT获取用户信息<br/>3.查询用户权限
        F2->>F1: 4.设置Authentication到<br/>SecurityContextHolder
    else 请求头未带JWT
        F2->>F2: 跳过 匿名访问
    end

    F2->>F3: 继续

    alt URL需要认证
        F3->>F3: 检查SecurityContext<br/>中是否有认证信息
        alt 未认证
            F3->>F4: 抛出AuthenticationException
            F4->>C: 返回 401 或跳转登录页
        end
    end

    alt URL需要特定权限
        F3->>F3: 检查当前用户是否有<br/>该URL要求的权限
        alt 权限不足
            F3->>F4: 抛出AccessDeniedException
            F4->>C: 返回 403
        end
    end

    F3->>API: 放行
    API->>C: 正常响应
```

---

## 四、JWT 详解：前后端分离的凭证方案

JWT（JSON Web Token）是当前前后端分离项目中<strong>最主流</strong>的认证凭证格式。Spring Security 默认使用 Session 机制，但在前后端分离架构中，JWT 是完全替代 Session 的方案。

### 4.1 JWT 是什么

JWT 是一串经过签名（Signature）的字符串，用来在两个系统之间安全地传递信息。在鉴权场景中：

-  登录成功后，服务端生成一个 JWT 返回给客户端
-  客户端将它存储起来（通常是 `localStorage` 或 `Cookie`）
-  后续每次请求都在 HTTP Header 中携带这个 JWT
-  服务端验证 JWT 的签名，从中解析出用户身份

### 4.2 JWT 的结构

一个 JWT 字符串长这样：

```
eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMDAxIiwiaWF0IjoxNjYwMTIzNDAwfQ.s5VqEeFv3k0KxJF8wYz7rB1tQpU2hHnOwDcMiLgA9X4
```

用 `.` 分割成三段：

```
Header.Payload.Signature
```

```mermaid
flowchart TD
    classDef startEnd fill:#F48FB1,stroke:#C2185B,stroke-width:2px,color:#212121,font-weight:bold;
    classDef process fill:#F5F5F5,stroke:#9E9E9E,stroke-width:1.5px,color:#212121;
    classDef data fill:#C8E6C9,stroke:#388E3C,stroke-width:1.5px,color:#1B5E20,font-weight:bold;

    JWT[完整的JWT Token]

    JWT --> HEADER[Header 头部]
    HEADER --> H1["alg: HS256\n签名算法"]
    HEADER --> H2["typ: JWT\n令牌类型"]

    JWT --> PAYLOAD[Payload 载荷]
    PAYLOAD --> P1["sub: 用户ID\n主题，标准字段"]
    PAYLOAD --> P2["iat: 签发时间\n标准时间字段"]
    PAYLOAD --> P3["exp: 过期时间\n标准时间字段"]
    PAYLOAD --> P4["自定义字段\n如: username, roles"]

    JWT --> SIG[Signature 签名]
    SIG --> S1["HMACSHA256 \n  base64Url header\n  + '.' +\n  base64Url payload\n  secret\n"]

    class JWT startEnd;
    class HEADER,PAYLOAD,SIG process;
    class H1,H2,P1,P2,P3,P4,S1 data;
```

<strong>三部分的详细说明</strong>：

| 部分 | 内容 | 是否加密 | 说明 |
|------|------|:---:|------|
| <strong>Header</strong> | 签名算法 + Token 类型 | 否（仅 Base64 编码） | 指明用 HS256 还是 RS256 |
| <strong>Payload</strong> | 用户信息 + 过期时间 + 自定义数据 | 否（仅 Base64 编码） | <span style="color:red"><strong>绝对不能放密码等敏感信息</strong></span>，Base64 只是编码不是加密 |
| <strong>Signature</strong> | 签名（防篡改） | 签名校验 | 用 Header 指定的算法，将 Header + Payload + 密钥一起签名。<strong>任何人修改 Payload 都会导致签名不匹配</strong> |

### 4.3 JWT 的验证原理

服务端收到 JWT 后：

1. 用 `.` 分割出 Header、Payload、Signature
2. 用相同的算法和密钥，对 Header.Payload 重新计算签名
3. 对比计算出的签名和收到的 Signature 是否一致
4. 一致 → 数据未被篡改，可以信任 Payload 中的用户信息
5. 不一致 → 数据被篡改过，拒绝请求

> <strong>关键设计</strong>：JWT 不是用来<strong>隐藏数据</strong>的（Payload 任何人 Base64 解码就能看到），而是用来<strong>防止数据被篡改</strong>的。因此 Payload 中绝不能放密码等敏感信息。

### 4.4 JWT vs Session 对比

| 对比维度 | Session（传统方案） | JWT（前后端分离方案） |
|------|------|------|
| 存储位置 | 服务端内存 / Redis | 客户端（localStorage / Cookie） |
| 服务端状态 | <strong>有状态</strong>——服务端必须保存 Session | <strong>无状态</strong>——服务端不保存，密钥验证即可 |
| 扩展性 | 多服务器需要共享 Session（Redis） | 天然支持多服务器，任何服务器都能验证 |
| 注销方式 | 删除服务端 Session 即可 | 需要客户端删除 Token，或服务端维护黑名单 |
| 跨域 | Cookie 跨域受限 | Header 携带，无跨域问题 |
| 适用场景 | 服务端渲染（JSP / Thymeleaf）、单体应用 | 前后端分离、微服务、移动 App |

### 4.5 Access Token + Refresh Token 双令牌机制

企业生产中，JWT 通常采用<strong>双令牌</strong>机制：

| 令牌 | 有效期 | 存储位置 | 作用 |
|------|:---:|------|------|
| <strong>Access Token</strong> | 短（15 ~ 30 分钟） | 客户端内存 | 每次请求携带，用于认证 |
| <strong>Refresh Token</strong> | 长（7 天 ~ 30 天） | HttpOnly Cookie 或安全存储 | Access Token 过期后，用它换取新的 Access Token |

```mermaid
sequenceDiagram
    participant C as 客户端
    participant S as 服务端

    Note over C,S: 阶段一：登录
    C->>S: POST /api/auth/login<br/>用户名 + 密码
    S->>S: 验证用户名密码
    S->>C: 返回 Access Token 30分钟<br/>+ Refresh Token 7天

    Note over C,S: 阶段二：正常请求
    C->>S: GET /api/users<br/>Header: Authorization Bearer {AccessToken}
    S->>S: 验证Access Token签名
    S->>C: 正常响应

    Note over C,S: 阶段三：Access Token过期
    C->>S: GET /api/users<br/>Header: Authorization Bearer {AccessToken}
    S->>C: 401 Token Expired

    Note over C,S: 阶段四：刷新Token
    C->>S: POST /api/auth/refresh<br/>携带Refresh Token
    S->>S: 验证Refresh Token
    S->>C: 返回新的Access Token + 新的Refresh Token

    Note over C,S: 阶段五：Refresh Token也过期
    C->>S: POST /api/auth/refresh<br/>携带Refresh Token
    S->>C: 401 请重新登录
```

> <strong>为什么需要双令牌？</strong> Access Token 短有效期是为了安全——即使泄露，攻击者也只能在 30 分钟内使用；Refresh Token 长有效期是为了用户体验——用户不用频繁输入密码重新登录。Refresh Token 通常存储在 HttpOnly Cookie 中（JS 无法读取），降低被 XSS 攻击窃取的风险。

---

# Part 2：教程版 —— 从零搭建一个能跑的鉴权系统

Part 1 把概念、架构、JWT 原理都讲清楚了。从现在开始，你只需要做一件事：<strong>跟着写代码</strong>。下面每一节都给出了完整的、可运行的代码，你按顺序复制粘贴就能跑通。

教程版的技术选型：
- <strong>Hutool JWT</strong> 生成和解析 Token
- <strong>OncePerRequestFilter</strong> 实现 JWT 认证过滤器
- <strong>单表 t_user</strong> 存储用户和角色
- <strong>用户名 + 密码</strong> 单一认证方式
- <strong>Token Payload 直接存用户信息</strong>（userId + username + role）

---

## 五、教程版完整实现

### 5.1 项目依赖（pom.xml）

```xml
<dependencies>
    <!-- Spring Boot Web -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-web</artifactId>
    </dependency>

    <!-- Spring Security -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-security</artifactId>
    </dependency>

    <!-- Spring Boot Validation -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-validation</artifactId>
    </dependency>

    <!-- Hutool 工具库（包含 JWT 模块） -->
    <dependency>
        <groupId>cn.hutool</groupId>
        <artifactId>hutool-all</artifactId>
        <version>5.8.25</version>
    </dependency>

    <!-- Lombok -->
    <dependency>
        <groupId>org.projectlombok</groupId>
        <artifactId>lombok</artifactId>
        <optional>true</optional>
    </dependency>

    <!-- MyBatis-Plus（数据库操作） -->
    <dependency>
        <groupId>com.baomidou</groupId>
        <artifactId>mybatis-plus-boot-starter</artifactId>
        <version>3.5.5</version>
    </dependency>

    <!-- MySQL 驱动 -->
    <dependency>
        <groupId>com.mysql</groupId>
        <artifactId>mysql-connector-j</artifactId>
        <scope>runtime</scope>
    </dependency>
</dependencies>
```

### 5.2 配置文件（application.yml）

```yaml
server:
  port: 8080

spring:
  datasource:
    url: jdbc:mysql://localhost:3306/mall?useUnicode=true&characterEncoding=utf-8&serverTimezone=Asia/Shanghai
    username: root
    password: 123456
    driver-class-name: com.mysql.cj.jdbc.Driver

# JWT 配置
jwt:
  secret: my-super-secret-key-for-jwt-signing-2024-please-change-in-production
  access-token-expire: 1800000      # 30分钟（毫秒）
  refresh-token-expire: 604800000   # 7天（毫秒）
```

### 5.3 数据库表结构

```sql
CREATE TABLE `t_user` (
    `id`          BIGINT       NOT NULL AUTO_INCREMENT COMMENT '用户ID',
    `username`    VARCHAR(50)  NOT NULL COMMENT '用户名',
    `password`    VARCHAR(200) NOT NULL COMMENT '加密后的密码',
    `role`        VARCHAR(50)  NOT NULL DEFAULT 'ROLE_USER' COMMENT '角色',
    `enabled`     TINYINT(1)   NOT NULL DEFAULT 1 COMMENT '是否启用 1:是 0:否',
    `create_time` DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uk_username` (`username`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='用户表';

-- 插入测试用户（密码都是 123456，BCrypt 加密后的结果）
INSERT INTO t_user (username, password, role) VALUES
('admin', '$2a$10$N.zmdr9k7uOCQb376NoUnuTJ8iAt6Z5EHsM8lE9lBOsl7iAt6Z5Eh', 'ROLE_ADMIN'),
('zhangsan', '$2a$10$N.zmdr9k7uOCQb376NoUnuTJ8iAt6Z5EHsM8lE9lBOsl7iAt6Z5Eh', 'ROLE_USER');
```

### 5.4 代码结构总览

```
src/main/java/com/mallshop/mallsecurity/
├── config/
│   ├── SecurityConfig.java          # Spring Security 核心配置
│   └── JwtConfig.java               # JWT 配置属性
├── controller/
│   └── AuthController.java          # 登录/刷新Token 接口
├── entity/
│   └── User.java                    # 用户实体
├── filter/
│   └── JwtAuthenticationFilter.java # JWT 认证过滤器
├── mapper/
│   └── UserMapper.java              # 数据库访问
├── service/
│   └── UserService.java             # 用户服务
└── util/
    └── JwtUtil.java                 # JWT 工具类（Hutool封装）
```

### 5.5 实体类

```java
package com.mallshop.mallsecurity.entity;

import com.baomidou.mybatisplus.annotation.TableName;
import lombok.Data;

@Data
@TableName("t_user")
public class User {
    private Long id;
    private String username;
    private String password;  // BCrypt加密后的密码
    private String role;      // ROLE_ADMIN 或 ROLE_USER
    private Boolean enabled;  // 是否启用
}
```

### 5.6 JWT 工具类（Hutool 封装）

这是教程版的核心工具类——用 Hutool 生成和解析 JWT，Payload 中 <strong>直接存放 userId、username、role</strong>。

```java
package com.mallshop.mallsecurity.util;

import cn.hutool.jwt.JWT;
import cn.hutool.jwt.JWTUtil;
import java.util.HashMap;
import java.util.Map;

public class JwtUtil {

    // 密钥——教程版直接写在代码里，生产版应放在配置文件中
    private static final String SECRET = "my-super-secret-key-for-jwt-signing-2024-please-change-in-production";

    /**
     * 生成 Access Token（30分钟有效）
     */
    public static String createAccessToken(Long userId, String username, String role) {
        Map<String, Object> payload = new HashMap<>();
        payload.put("userId", userId);
        payload.put("username", username);
        payload.put("role", role);
        // 过期时间：当前时间 + 30分钟
        payload.put("exp", System.currentTimeMillis() + 30 * 60 * 1000);
        return JWTUtil.createToken(payload, SECRET.getBytes());
    }

    /**
     * 生成 Refresh Token（7天有效）
     */
    public static String createRefreshToken(Long userId, String username) {
        Map<String, Object> payload = new HashMap<>();
        payload.put("userId", userId);
        payload.put("username", username);
        payload.put("type", "refresh");
        payload.put("exp", System.currentTimeMillis() + 7 * 24 * 60 * 60 * 1000);
        return JWTUtil.createToken(payload, SECRET.getBytes());
    }

    /**
     * 验证 Token 是否有效（签名正确 + 未过期）
     */
    public static boolean verify(String token) {
        return JWTUtil.verify(token, SECRET.getBytes());
    }

    /**
     * 从 Token 中解析 JWT 对象
     */
    public static JWT parseToken(String token) {
        return JWTUtil.parseToken(token);
    }

    /**
     * 从 Token 中获取用户ID
     */
    public static Long getUserId(String token) {
        JWT jwt = parseToken(token);
        return Long.valueOf(jwt.getPayload("userId").toString());
    }

    /**
     * 从 Token 中获取用户名
     */
    public static String getUsername(String token) {
        JWT jwt = parseToken(token);
        return (String) jwt.getPayload("username");
    }

    /**
     * 从 Token 中获取角色
     */
    public static String getRole(String token) {
        JWT jwt = parseToken(token);
        return (String) jwt.getPayload("role");
    }
}
```

> <strong>Hutool JWT 常用 API 速查</strong>：
>
> | 方法 | 作用 |
> |------|------|
> | `JWTUtil.createToken(map, key)` | 生成 JWT |
> | `JWTUtil.verify(token, key)` | 验证 JWT 签名和有效期 |
> | `JWTUtil.parseToken(token)` | 解析 JWT，读取 Payload |
> | `jwt.getPayload("key")` | 读取 Payload 中指定字段的值 |

### 5.7 JWT 认证过滤器

每当请求到达时，这个过滤器从 Header 中提取 Token，验证并解析，然后将用户信息设置到 Spring Security 的上下文中。

```java
package com.mallshop.mallsecurity.filter;

import cn.hutool.jwt.JWT;
import com.mallshop.mallsecurity.util.JwtUtil;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.filter.OncePerRequestFilter;

import javax.servlet.FilterChain;
import javax.servlet.ServletException;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.Collections;

public class JwtAuthenticationFilter extends OncePerRequestFilter {

    @Override
    protected void doFilterInternal(HttpServletRequest request,
            HttpServletResponse response, FilterChain filterChain)
            throws ServletException, IOException {

        // 1. 从请求头中提取 Token
        String authHeader = request.getHeader("Authorization");
        if (authHeader == null || !authHeader.startsWith("Bearer ")) {
            // 没有 Token，直接放行（后续 SecurityConfig 中的 URL 规则会拦截）
            filterChain.doFilter(request, response);
            return;
        }

        String token = authHeader.substring(7); // 去掉 "Bearer " 前缀

        // 2. 验证 Token
        if (!JwtUtil.verify(token)) {
            filterChain.doFilter(request, response);
            return;
        }

        // 3. 从 Token Payload 中解析用户信息
        String username = JwtUtil.getUsername(token);
        String role = JwtUtil.getRole(token);

        // 4. 构造 Authentication 对象，设置到 SecurityContext
        UsernamePasswordAuthenticationToken authentication =
                new UsernamePasswordAuthenticationToken(
                        username, null,
                        Collections.singletonList(new SimpleGrantedAuthority(role)));
        SecurityContextHolder.getContext().setAuthentication(authentication);

        // 5. 继续过滤器链
        filterChain.doFilter(request, response);
    }
}
```

> <strong>关键理解</strong>：这个过滤器只负责"从 Token 中认出你是谁"，不负责"拒绝没 Token 的请求"。拒绝操作由后面的 `SecurityConfig` 里的 URL 规则完成。这叫<strong>关注点分离</strong>——过滤器做认证，配置做授权。

### 5.8 Spring Security 核心配置

```java
package com.mallshop.mallsecurity.config;

import com.mallshop.mallsecurity.filter.JwtAuthenticationFilter;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.UsernamePasswordAuthenticationFilter;

@Configuration
@EnableWebSecurity
public class SecurityConfig {

    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder();
    }

    @Bean
    public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
        http
            // JWT 方案不需要 CSRF 保护
            .csrf().disable()
            // 不创建 Session（无状态）
            .sessionManagement()
            .sessionCreationPolicy(SessionCreationPolicy.STATELESS)
            .and()
            // URL 授权规则
            .authorizeRequests()
            // 登录和刷新 Token 接口放行
            .antMatchers("/api/auth/login", "/api/auth/refresh").permitAll()
            // 管理员接口需要 ADMIN 角色
            .antMatchers("/api/admin/**").hasRole("ADMIN")
            // 其余所有请求需要认证
            .anyRequest().authenticated()
            .and()
            // 把自定义 JWT 过滤器加到 UsernamePasswordAuthenticationFilter 之前
            .addFilterBefore(new JwtAuthenticationFilter(),
                    UsernamePasswordAuthenticationFilter.class);

        return http.build();
    }
}
```

### 5.9 UserDetailsService 实现

Spring Security 需要知道从哪里加载用户数据。`UserDetailsService` 只有一个方法 `loadUserByUsername`——根据用户名从数据库查用户，返回 Spring Security 能理解的 `UserDetails` 对象。

```java
package com.mallshop.mallsecurity.service;

import com.baomidou.mybatisplus.core.conditions.query.LambdaQueryWrapper;
import com.mallshop.mallsecurity.entity.User;
import com.mallshop.mallsecurity.mapper.UserMapper;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.security.core.userdetails.UserDetails;
import org.springframework.security.core.userdetails.UserDetailsService;
import org.springframework.security.core.userdetails.UsernameNotFoundException;
import org.springframework.stereotype.Service;

@Service
public class UserDetailsServiceImpl implements UserDetailsService {

    @Autowired
    private UserMapper userMapper;

    @Override
    public UserDetails loadUserByUsername(String username)
            throws UsernameNotFoundException {
        // 1. 从数据库查用户
        User user = userMapper.selectOne(
                new LambdaQueryWrapper<User>()
                        .eq(User::getUsername, username));

        if (user == null) {
            throw new UsernameNotFoundException("用户不存在: " + username);
        }

        // 2. 转换为 Spring Security 的 UserDetails
        return org.springframework.security.core.userdetails.User
                .withUsername(user.getUsername())
                .password(user.getPassword())
                .roles(user.getRole().replace("ROLE_", ""))
                .disabled(!user.getEnabled())
                .build();
    }
}
```

### 5.10 登录接口

```java
package com.mallshop.mallsecurity.controller;

import com.mallshop.mallsecurity.util.JwtUtil;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.security.authentication.AuthenticationManager;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.*;

import javax.validation.Valid;
import java.util.HashMap;
import java.util.Map;

@RestController
@RequestMapping("/api/auth")
public class AuthController {

    @Autowired
    private AuthenticationManager authenticationManager;

    @PostMapping("/login")
    public Map<String, Object> login(@Valid @RequestBody LoginRequest request) {
        // 1. 调用 Spring Security 认证
        UsernamePasswordAuthenticationToken authToken =
                new UsernamePasswordAuthenticationToken(
                        request.getUsername(), request.getPassword());
        Authentication authentication =
                authenticationManager.authenticate(authToken);

        // 2. 认证成功，从数据库查用户信息
        org.springframework.security.core.userdetails.User userDetails =
                (org.springframework.security.core.userdetails.User)
                        authentication.getPrincipal();
        String role = userDetails.getAuthorities().iterator().next().getAuthority();

        // 3. 生成双令牌
        String accessToken = JwtUtil.createAccessToken(
                1L, userDetails.getUsername(), role);
        String refreshToken = JwtUtil.createRefreshToken(
                1L, userDetails.getUsername());

        // 4. 返回
        Map<String, Object> result = new HashMap<>();
        result.put("accessToken", accessToken);
        result.put("refreshToken", refreshToken);
        result.put("tokenType", "Bearer");
        result.put("expiresIn", 1800);
        return result;
    }

    @PostMapping("/refresh")
    public Map<String, Object> refresh(@RequestBody Map<String, String> body) {
        String refreshToken = body.get("refreshToken");
        if (!JwtUtil.verify(refreshToken)) {
            throw new RuntimeException("Refresh Token 无效或已过期");
        }
        // 用 Refresh Token 中的信息生成新的 Access Token
        String username = JwtUtil.getUsername(refreshToken);
        String role = JwtUtil.getRole(refreshToken);
        Long userId = JwtUtil.getUserId(refreshToken);

        String newAccessToken = JwtUtil.createAccessToken(userId, username, role);
        String newRefreshToken = JwtUtil.createRefreshToken(userId, username);

        Map<String, Object> result = new HashMap<>();
        result.put("accessToken", newAccessToken);
        result.put("refreshToken", newRefreshToken);
        result.put("tokenType", "Bearer");
        result.put("expiresIn", 1800);
        return result;
    }
}

// 登录请求体
class LoginRequest {
    private String username;
    private String password;
    // getters & setters...
}
```

### 5.11 测试接口

```java
@RestController
@RequestMapping("/api/admin")
public class AdminController {

    @GetMapping("/dashboard")
    public String dashboard() {
        // 只有 ROLE_ADMIN 角色能访问
        return "管理员仪表盘——敏感数据";
    }
}

@RestController
@RequestMapping("/api/user")
public class UserController {

    @GetMapping("/info")
    public String userInfo() {
        // 登录用户均可访问
        return "用户个人信息";
    }
}
```

### 5.12 教程版小结

到这里，你已经有了一个完整可跑的鉴权系统。核心流程是：

```
登录 → 验证用户名密码 → 生成 JWT（Payload 里存 userId+username+role）→ 返回给客户端
请求 → JwtAuthFilter 提取 Token → 解析 Payload 拿角色 → 设置 SecurityContext → SecurityConfig 判断 URL 权限
```

<strong>教程版的问题</strong>——也是你必须继续读 Part 3 的原因：

| 问题 | 后果 |
|------|------|
| Token Payload 存了 userId+role，Base64 任何人可解码 | 用户信息泄露 |
| Token 签发后无法主动失效 | 管理员改了权限，旧 Token 仍然有效 |
| 角色直接存在 t_user.role 字段 | 无法支持"一个用户多个角色" |
| 登录接口在 SecurityConfig 里硬编码放行 | 每加一个公开接口都要改配置 |
| Filter 中异常直接写 response | 错误格式不统一，前端要处理两套 |
| 密码明文传输 | HTTP 中间人攻击风险 |

这 6 个问题，正是 Part 3 要逐一解决的。

---

# Part 3：生产版 —— 从教程到企业级的 6 个升级

下面每个升级都是独立的：<strong>教程版做了 X → 生产版改为 Y → 原因是 Z</strong>。你可以按顺序逐个应用到自己的项目里。

---

## 六、升级一：JJWT + Redis 双 key Token 方案

<strong>痛点</strong>：教程版用 Hutool 把 userId、username、role 全部塞进 Token Payload。任何人拿到 Token，Base64 解码就能看到这些信息。而且 Token 一旦签发，在过期之前无法让它失效。

### 6.1.1 核心思路

<strong>生产版的做法</strong>：Token 里只存最少信息（username），完整的用户详情存在 Redis 里。

```
Token Payload: { sub: "zhangsan", exp: 1234567890 }
Redis token:zhangsan → JWT 字符串（用于对比验证）
Redis user:zhangsan  → JwtUserEntity 的 JSON（完整用户信息）
```

### 6.1.2 为什么选择 JJWT 而不是 Hutool

| | Hutool JWT | JJWT（`io.jsonwebtoken`） |
|------|:---:|:---:|
| 引入方式 | `cn.hutool:hutool-all` | `io.jsonwebtoken:jjwt` |
| 功能定位 | 工具库附带（JWT 只是 Hutool 200+ 模块之一） | 专注 JWT——完整的构建/解析/验证 API |
| 签名算法 | 默认 HS256，切换不便 | 显式指定 `SignatureAlgorithm.HS512` |
| Token 构建 | `JWTUtil.createToken(map, key)` | `Jwts.builder().setSubject().setExpiration().signWith().compact()`——链式调用，每一步语义清晰 |
| Payload 策略 | 把 userId、role、username 全塞进去 | <strong>只存 `sub`（用户名）和 `exp`（过期时间）</strong>——用户详情放 Redis |

### 6.1.3 添加 JJWT 依赖

```xml
<!-- JJWT -->
<dependency>
    <groupId>io.jsonwebtoken</groupId>
    <artifactId>jjwt</artifactId>
    <version>0.9.1</version>
</dependency>
```

### 6.1.4 TokenHelper 完整代码

```java
@Slf4j
@Component
public class UserTokenHelper {

    private static final String TOKEN_PREFIX = "token:";
    private static final String USER_PREFIX = "user:";

    @Getter
    @Value("${mall.mgt.tokenSecret:123456test}")
    private String tokenSecret;
    @Value("${mall.mgt.tokenExpireTimeInRecord:3600}")
    private int tokenExpireTimeInRecord;

    @Autowired
    protected RedisUtil redisUtil;

    /**
     * 生成 Token 并存入 Redis
     * @param username  用户名（作为 Token 的 subject）
     * @param json      用户完整信息的 JSON（存入 Redis）
     */
    public String generateToken(String username, String json) {
        // 生成 JWT——只存 sub + exp，不存任何业务字段
        String token = Jwts.builder()
                .setSubject(username)
                .setExpiration(new Date(System.currentTimeMillis()
                        + tokenExpireTimeInRecord * 1000))
                .signWith(SignatureAlgorithm.HS512, tokenSecret)
                .compact();

        // 双 key 写入 Redis——TTL 与 Token 一致
        redisUtil.set(getTokenKey(username), token, tokenExpireTimeInRecord);
        redisUtil.set(getUserKey(username), json, tokenExpireTimeInRecord);
        return token;
    }

    /**
     * 从 Token 中解析用户名
     */
    public String getUsernameFromToken(String token) {
        Claims claims = getClaimsFromToken(token);
        if (Objects.isNull(claims)) {
            return null;
        }
        return claims.getSubject();
    }

    /**
     * 解析 JWT Claims——验证签名 + 检查过期
     */
    public Claims getClaimsFromToken(String token) {
        Claims claims;
        try {
            claims = Jwts.parser()
                    .setSigningKey(getTokenSecret())
                    .parseClaimsJws(token)
                    .getBody();
        } catch (Exception e) {
            // 签名无效/过期 → 直接抛 BusinessException → GlobalExceptionHandler 统一处理
            throw new BusinessException(HttpStatus.FORBIDDEN.value(), "请先登录");
        }
        return claims;
    }

    protected String getTokenKey(String username) {
        return String.format("%s%s", TOKEN_PREFIX, username);
    }

    protected String getUserKey(String username) {
        return String.format("%s%s", USER_PREFIX, username);
    }
}
```

继承自 `UserTokenHelper` 的业务层 `TokenHelper`：

```java
@Slf4j
@Component
public class TokenHelper extends UserTokenHelper {

    /**
     * 生成 Token——调用父类方法，传入 UserDetails 序列化后的 JSON
     */
    public String generateToken(UserDetails userDetails) {
        return super.generateToken(
                userDetails.getUsername(),
                JSON.toJSONString(userDetails)  // FastJSON 序列化整个 UserDetails
        );
    }

    /**
     * 从 Redis 中获取用户详情——供 JwtTokenFilter 使用
     */
    public UserDetails getUserDetailsFromUsername(String username) {
        String userDetailJson = redisUtil.get(getUserKey(username));
        if (!StringUtils.hasLength(userDetailJson)) {
            return null;
        }
        return JSON.parseObject(userDetailJson, JwtUserEntity.class);
    }
}
```

### 6.1.5 Redis 双 key 的作用

| Redis Key | Value | 作用 |
|------|------|------|
| `token:zhangsan` | JWT 字符串 | 支持"踢人下线"——删掉这个 key，Token 就失效了 |
| `user:zhangsan` | `JwtUserEntity` 的 JSON | 过滤器拿到用户名后，从这里取完整的用户信息（id、roles、authorities） |

<strong>注销（logout）的实现</strong>：

```java
public void delToken(String token) {
    String username = getUsernameFromToken(token);
    redisUtil.del(getTokenKey(username));   // 删除 token → Token 验证失败
    redisUtil.del(getUserKey(username));   // 删除 user → 用户信息丢失
}
```

两个 key 一起删——不管 JWT 本身的 `exp` 还有多久，<strong>Redis 里没有就是没有</strong>。不需要黑名单、不需要 JWT 版本号，Redis 的 TTL 就是 Token 的生命周期。

### 6.1.6 教程版 vs 生产版对比

|  | 教程版（Hutool） | 生产版（JJWT + Redis） |
|------|:---:|:---:|
| JWT 库 | Hutool `JWTUtil` | JJWT `Jwts.builder()` |
| Token 里存什么 | userId + username + role + type + exp | <strong>只存 `sub`(username) + `exp`</strong> |
| 用户信息在哪 | Token Payload（Base64，可解码） | Redis `user:{username}` key |
| 主动失效 | 需要额外维护黑名单 | 删除 Redis key 即刻失效 |
| 过期控制 | JWT `exp` 字段 | JWT `exp` + Redis key TTL（双重控制） |
| 防篡改 | 签名校验 | 签名校验 + Token 值对比（Redis 中存了一份正确的） |

---

## 七、升级二：SecurityConfig —— @NoLogin 自动扫描 + 双 Provider + 方法级权限

<strong>痛点</strong>：教程版的 SecurityConfig 只有 4 行 permitAll，每次新增公开接口都要手动加 `.antMatchers()`。而且不支持 `@PreAuthorize` 方法级权限注解。

### 7.1 生产版 SecurityConfig 完整代码

```java
@Configuration(proxyBeanMethods = false)
@EnableWebSecurity
@EnableGlobalMethodSecurity(prePostEnabled = true, securedEnabled = true)  // ① 开启方法级权限注解
public class SpringSecurityConfig implements ApplicationContextAware {

    private ApplicationContext applicationContext;

    @Override
    public void setApplicationContext(ApplicationContext ctx) {
        this.applicationContext = ctx;
    }

    // ===== 认证提供者 =====

    @Bean
    public SmsAuthenticationProvider smsAuthenticationProvider() {
        return new SmsAuthenticationProvider(
                applicationContext.getBean(UserDetailsServiceImpl.class),
                applicationContext.getBean(RedisUtil.class),
                applicationContext.getBean(UserMapper.class));
    }

    @Bean
    public DaoAuthenticationProvider daoAuthenticationProvider() {
        DaoAuthenticationProvider provider = new DaoAuthenticationProvider();
        provider.setPasswordEncoder(passwordEncoder());
        provider.setUserDetailsService(
                applicationContext.getBean(UserDetailsServiceImpl.class));
        return provider;
    }

    // ② AuthenticationManager 管理两个 Provider——密码登录 + 短信登录
    @Bean
    public AuthenticationManager authenticationManager() {
        List<AuthenticationProvider> providers = new ArrayList<>();
        providers.add(smsAuthenticationProvider());   // 短信验证码登录
        providers.add(daoAuthenticationProvider());   // 用户名密码登录
        return new ProviderManager(providers);
    }

    // ③ 去掉 ROLE_ 前缀——权限码直接是 "admin:user:delete" 而不是 "ROLE_admin:user:delete"
    @Bean
    public GrantedAuthorityDefaults grantedAuthorityDefaults() {
        return new GrantedAuthorityDefaults("");
    }

    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder();
    }

    // ===== 安全过滤器链 =====

    @Bean
    SecurityFilterChain filterChain(HttpSecurity httpSecurity) throws Exception {
        // ④ 启动时扫描所有 @NoLogin 注解，构建免登录 URL 集合
        initNoLogin(applicationContext);

        return httpSecurity
                .csrf().disable()           // JWT 方案不需要 CSRF
                .headers().frameOptions().disable()  // 允许 iframe（Druid 监控页需要）
                .and()
                .sessionManagement()
                .sessionCreationPolicy(SessionCreationPolicy.STATELESS)

                .and()
                .authorizeRequests()
                // 静态资源
                .antMatchers(HttpMethod.GET,
                        "/*.html", "/**/*.html", "/**/*.css", "/**/*.js",
                        "/websocket/**", "/job/**", "/init/**").permitAll()
                // Swagger 文档
                .antMatchers("/swagger-ui.html", "/swagger-resources/**",
                        "/webjars/**", "/*/api-docs").permitAll()
                // Druid 监控 + 头像
                .antMatchers("/druid/**", "/avatar/**").permitAll()
                // OPTIONS 预检请求
                .antMatchers(HttpMethod.OPTIONS, "/**").permitAll()
                // ⑤ @NoLogin 注解标记的接口——运行时动态构建的 permitAll 列表
                .antMatchers(NoLoginMap.getNoLoginUrlSet()
                        .toArray(new String[0])).permitAll()
                // 其余所有请求需要认证
                .anyRequest().authenticated()
                .and()
                .apply(new JwtTokenConfigurer())  // ⑥ 注册自定义 JWT 过滤器
                .and()
                .build();
    }

    /**
     * ⑦ 自动扫描：启动时遍历所有 @RequestMapping，收集标了 @NoLogin 的 URL
     */
    private void initNoLogin(ApplicationContext applicationContext) {
        RequestMappingHandlerMapping mapping = applicationContext
                .getBean(RequestMappingHandlerMapping.class);
        Map<RequestMappingInfo, HandlerMethod> handlerMethods =
                mapping.getHandlerMethods();

        Set<String> noLoginUrls = new HashSet<>();
        for (Map.Entry<RequestMappingInfo, HandlerMethod> entry
                : handlerMethods.entrySet()) {
            HandlerMethod handlerMethod = entry.getValue();
            NoLogin noLogin = handlerMethod.getMethodAnnotation(NoLogin.class);
            if (null != noLogin) {
                noLoginUrls.addAll(entry.getKey()
                        .getPatternsCondition().getPatterns());
            }
        }
        NoLoginMap.initSet(noLoginUrls);
    }
}
```

### 7.2 五个独特设计逐一解释

| 设计 | 教程版 | 生产版 | 为什么 |
|------|------|------|------|
| <strong>① @EnableGlobalMethodSecurity</strong> | 未启用 | `prePostEnabled = true` | 开启后可以在 Controller 方法上用 `@PreAuthorize("hasAuthority('user:delete')")` 做细粒度权限控制——不在 SecurityConfig 里写死角色规则 |
| <strong>② 双 AuthenticationProvider</strong> | 只有一个默认的 `DaoAuthenticationProvider` | `SmsAuthenticationProvider` + `DaoAuthenticationProvider` | 支持两种登录方式——短信验证码和用户名密码。`ProviderManager` 按注册顺序依次尝试，哪个 `supports()` 返回 true 就用哪个 |
| <strong>③ GrantedAuthorityDefaults("")</strong> | 没有配置（默认 "ROLE_"） | 显式去前缀 | `hasRole("ADMIN")` 背后会自动加 `ROLE_` → 实际校验的权限码是 `ROLE_ADMIN`。去掉前缀后权限码直接是 `admin:user:delete` 格式——和数据库中存的完全一致，不混淆 |
| <strong>④ initNoLogin() 自动扫描</strong> | 在 `SecurityConfig` 中硬编码 `.antMatchers("/api/auth/login").permitAll()` | 启动时扫描所有 `@RequestMapping`，找出标了 `@NoLogin` 的 | 新增一个公开接口不需要改 SecurityConfig——只需要在方法上加 `@NoLogin`。符合开闭原则（对扩展开放、对修改关闭） |
| <strong>⑤ 7 类 permitAll 规则</strong> | 只有登录 + 刷新接口 | 静态资源 + Swagger + Druid + WebSocket + OPTIONS + Job 回调 + NoLogin | 真实生产项目不仅有业务接口——监控、文档、WebSocket 都要在安全配置里声明。OPTIONS 预检请求必须放行否则前端 CORS 失败 |

---

## 八、升级三：JWT Filter —— 异常桥接 + NoLoginMap 跳过

<strong>痛点</strong>：教程版的 `OncePerRequestFilter` 在处理异常时只能直接在 response 上写 JSON。但这样做绕过了 `@RestControllerAdvice`，导致错误响应格式和正常接口不一致——前端要处理两套错误格式。

### 8.1 生产版 JwtTokenFilter

```java
public class JwtTokenFilter extends GenericFilterBean {

    public final static String FILTER_ERROR = "filterError";
    public final static String FILTER_ERROR_PATH = "/throw-error";

    @Override
    public void doFilter(ServletRequest servletRequest,
            ServletResponse servletResponse, FilterChain filterChain)
            throws IOException, ServletException {

        HttpServletRequest httpServletRequest = (HttpServletRequest) servletRequest;

        // ① NoLoginMap 判断：标了 @NoLogin 的接口 → 直接放行
        if (!NoLoginMap.notExist(httpServletRequest.getRequestURI())) {
            filterChain.doFilter(httpServletRequest, servletResponse);
            return;
        }

        // ② 从 Authorization 头提取 Token
        String token = TokenUtil.getTokenForAuthorization(httpServletRequest);

        if (Objects.isNull(token)) {
            if (NoLoginMap.notExist(httpServletRequest.getRequestURI())) {
                // ③ 需要登录但没有 Token → 转发给 FilterExceptionController
                handleException((HttpServletRequest) servletRequest,
                        (HttpServletResponse) servletResponse,
                        new BusinessException(HttpStatus.FORBIDDEN.value(), "请先登录"));
            } else {
                filterChain.doFilter(httpServletRequest, servletResponse);
            }
            return;
        }

        // ④ 通过 SpringBeanUtil 获取 TokenHelper（Filter 不是 Spring Bean，不能 @Autowired）
        TokenHelper tokenHelper = SpringBeanUtil.getBean("tokenHelper");

        if (Objects.nonNull(tokenHelper)) {
            try {
                // ⑤ 从 Token 解析用户名 → 从 Redis 获取完整 UserDetails
                String username = tokenHelper.getUsernameFromToken(token);
                if (StringUtils.hasLength(username)
                        && SecurityContextHolder.getContext().getAuthentication() == null) {
                    UserDetails userDetails =
                            tokenHelper.getUserDetailsFromUsername(username);  // 从 Redis 取
                    if (Objects.nonNull(userDetails)) {
                        UsernamePasswordAuthenticationToken authentication =
                                new UsernamePasswordAuthenticationToken(
                                        userDetails, null,
                                        userDetails.getAuthorities());
                        authentication.setDetails(
                                new WebAuthenticationDetailsSource()
                                        .buildDetails(httpServletRequest));
                        SecurityContextHolder.getContext()
                                .setAuthentication(authentication);
                    }
                }
                filterChain.doFilter(httpServletRequest, servletResponse);
            } catch (BusinessException e) {
                // ⑥ Token 解析异常 → 转发给 FilterExceptionController
                handleException((HttpServletRequest) servletRequest,
                        (HttpServletResponse) servletResponse, e);
            }
        } else {
            filterChain.doFilter(httpServletRequest, servletResponse);
        }
    }

    /**
     * ⑦ Filter 不能直接返回 JSON——通过 forward 交给 Controller
     */
    private void handleException(HttpServletRequest request,
            HttpServletResponse response, BusinessException e)
            throws ServletException, IOException {
        request.setAttribute(FILTER_ERROR, e);
        request.getRequestDispatcher(FILTER_ERROR_PATH).forward(request, response);
    }
}
```

### 8.2 Filter 注册方式：JwtTokenConfigurer

```java
public class JwtTokenConfigurer
        extends SecurityConfigurerAdapter<DefaultSecurityFilterChain, HttpSecurity> {

    @Override
    public void configure(HttpSecurity httpSecurity) {
        JwtTokenFilter jwtTokenFilter = new JwtTokenFilter();
        // 插在 UsernamePasswordAuthenticationFilter 之前
        httpSecurity.addFilterBefore(jwtTokenFilter,
                UsernamePasswordAuthenticationFilter.class);
    }
}
```

SecurityConfig 中通过 `.apply(new JwtTokenConfigurer())` 注册——而不是 `@Component` 自动注入。这样保证 Filter 在 Spring Security 链中正确初始化。

### 8.3 FilterExceptionController —— 异常桥接

```java
@Slf4j
@RestController
public class FilterExceptionController {

    @RequestMapping(FILTER_ERROR_PATH)  // "/throw-error"
    public void handleException(HttpServletRequest request) {
        Object exception = request.getAttribute(FILTER_ERROR);
        if (exception instanceof BusinessException) {
            BusinessException businessException = (BusinessException) exception;
            throw businessException;  // 重新抛出 → GlobalExceptionHandler 捕获
        }
        throw new BusinessException(
                HttpStatus.INTERNAL_SERVER_ERROR.value(),
                "服务器内部错误，请联系系统管理员！");
    }
}
```

### 8.4 教程版 vs 生产版对比

| 差异 | 教程版 | 生产版 | 为什么 |
|------|------|------|------|
| <strong>Filter 基类</strong> | `OncePerRequestFilter` | `GenericFilterBean` | 更灵活的控制——不强制每次请求只执行一次 |
| <strong>Filter 注册方式</strong> | `@Component` 自动注入后 `addFilterBefore(jwtFilter, ...)` | `JwtTokenConfigurer` 中 `new JwtTokenFilter()` 手动 new | 保证初始化顺序——避免 `@Component` 在其他 FilterConfig 之前加载导致注入问题 |
| <strong>UserDetails 来源</strong> | Token Payload 中解析 role | <strong>Redis `user:{username}` key 中取完整 `JwtUserEntity`</strong> | 权限可能在 Token 有效期内被管理员修改——从 Redis 取保证实时性 |
| <strong>NoLoginMap 跳过</strong> | 没有这层——Filter 对每个请求都检查 Token | `NoLoginMap.notExist(uri)` 先判断是否需要登录 | `@NoLogin` 注解的方法应该在 Filter 层就跳过 JWT 校验 |
| <strong>异常处理</strong> | catch 块直接 `response.getWriter().write("{\"code\":401}")` | <strong>forward 到 FilterExceptionController</strong> → Controller 重新 throw → `@RestControllerAdvice` 捕获 | Filter 不在 Spring MVC 上下文中，`@RestControllerAdvice` 无法捕获 Filter 中抛出的异常！forward 桥接是标准做法 |

> ⚠️ 新手提示：这是 Spring Security + 统一 JSON 返回格式组合中最容易踩的坑。直接 `response.getWriter().write(...)` 也能用，但 <strong>不走 GlobalExceptionHandler 的响应格式跟其他接口不一致</strong>，前端要处理两套错误格式。

---

## 九、升级四：RBAC 三表联查权限

<strong>痛点</strong>：教程版从 `t_user.role` 一个字段拿角色。真实系统是 RBAC 模型——<strong>用户 → 角色 → 菜单权限</strong>，权限来自三张表。

### 9.1 三表关系

```
t_user ──< t_user_role >── t_role ──< t_role_menu >── t_menu
                                  │
                                  └── permission 字段（角色自身的权限码）
                                                        │
                                  t_menu.permission 字段（菜单关联的权限码）
```

### 9.2 UserDetailsService 实现

```java
@Service("userDetailsService")
public class UserDetailsServiceImpl implements UserDetailsService {

    @Autowired
    private UserMapper userMapper;
    @Autowired
    private RoleMapper roleMapper;
    @Autowired
    private MenuMapper menuMapper;

    @Override
    public UserDetails loadUserByUsername(String username) {
        // ① 查用户
        UserEntity userEntity = userMapper.findByUserName(username);
        if (Objects.isNull(userEntity)) {
            return null;  // 返回 null → DaoAuthenticationProvider 抛出 BadCredentialsException
        }

        // ② 查用户拥有的角色 → 查角色关联的菜单权限
        List<SimpleGrantedAuthority> authorities = new ArrayList<>();
        fillUserAuthority(userEntity, authorities);

        // ③ 提取角色名列表（用于前端菜单展示）
        List<String> roles = authorities.stream()
                .map(SimpleGrantedAuthority::getAuthority)
                .collect(Collectors.toList());

        // ④ 返回自定义 UserDetails——除了权限，还带了 userId 和 roles
        return new JwtUserEntity(userEntity.getId(), username,
                userEntity.getPassword(), authorities, roles);
    }

    private void fillUserAuthority(UserEntity userEntity,
            List<SimpleGrantedAuthority> authorities) {
        // ⑤ 查用户关联的角色
        List<RoleEntity> roleEntities =
                roleMapper.findRoleByUserId(userEntity.getId());
        if (CollectionUtils.isEmpty(roleEntities)) {
            return;
        }

        // ⑥ 收集角色自身的权限码（如 "admin:user:list"）
        Set<String> permissionSet = roleEntities.stream()
                .filter(x -> StringUtils.hasLength(x.getPermission()))
                .map(RoleEntity::getPermission)
                .collect(Collectors.toSet());

        // ⑦ 查角色关联的菜单 → 收集菜单的权限码（如 "user:delete"）
        fillRoleMenu(roleEntities, permissionSet);

        if (CollectionUtils.isNotEmpty(permissionSet)) {
            authorities.addAll(permissionSet.stream()
                    .map(SimpleGrantedAuthority::new)
                    .collect(Collectors.toList()));
        }
    }

    private void fillRoleMenu(List<RoleEntity> roleEntities,
            Set<String> permissionSet) {
        List<Long> roleIdList = roleEntities.stream()
                .map(RoleEntity::getId).collect(Collectors.toList());
        List<MenuEntity> menuList =
                menuMapper.findMenuByRoleIdList(roleIdList);
        if (CollectionUtils.isEmpty(menuList)) {
            return;
        }
        for (MenuEntity menuEntity : menuList) {
            if (StringUtils.hasLength(menuEntity.getPermission())) {
                // ⑧ 菜单权限可能是逗号分隔的多个权限码，如 "user:add,user:delete"
                Set<String> menuPermSet = Arrays
                        .stream(menuEntity.getPermission().split(","))
                        .collect(Collectors.toSet());
                permissionSet.addAll(menuPermSet);
            }
        }
    }
}
```

### 9.3 自定义 UserDetails —— JwtUserEntity

```java
@Data
@NoArgsConstructor
@AllArgsConstructor
public class JwtUserEntity implements UserDetails {

    private Long id;                              // 用户ID——后续填充审计字段时用
    private String username;
    @JsonIgnore
    private String password;                      // 密码不序列化到 Redis 的 JSON 中
    private List<SimpleGrantedAuthority> authorities;  // 权限码集合
    private List<String> roles;                   // 角色名集合（前端菜单用）

    @Override
    public boolean isAccountNonExpired() { return true; }
    @Override
    public boolean isAccountNonLocked() { return true; }
    @Override
    public boolean isCredentialsNonExpired() { return true; }
    @Override
    public boolean isEnabled() { return true; }
}
```

比教程版多出来的关键字段是 `id` 和 `roles`——`id` 用于填充数据库审计字段（createUserId/updateUserId），`roles` 用于前端根据角色展示不同菜单。

---

## 十、升级五：双认证 Provider（密码 + 短信）

<strong>痛点</strong>：教程版只有用户名密码一种登录方式。真实项目通常需要支持短信验证码登录。

### 10.1 短信验证码登录的 SmsAuthenticationProvider

```java
public class SmsAuthenticationProvider implements AuthenticationProvider {

    @Override
    public Authentication authenticate(Authentication authentication) {
        String phone = (String) authentication.getPrincipal();
        String captcha = (String) authentication.getCredentials();

        // ① 验证短信验证码
        String smsCodeKey = getSmsCodePrefixKey(phone, SmsTypeEnum.LOGIN);
        String smsCode = redisUtil.get(smsCodeKey);
        AssertUtil.hasLength(smsCode, "该短信验证码已失效");
        AssertUtil.isTrue(smsCode.trim().equals(captcha), "短信验证码错误");

        try {
            // ② 根据手机号查用户——没有就自动注册
            List<UserEntity> userEntities = userMapper.searchByPhone(phone);
            UserEntity userEntity;
            if (CollectionUtils.isEmpty(userEntities)) {
                userEntity = registerUser(phone);  // 自动注册
            } else {
                userEntity = userEntities.get(0);
            }

            // ③ 走正常的 UserDetailsService 加载权限
            UserDetails userDetails = userDetailsService
                    .loadUserByUsername(userEntity.getUserName());

            // ④ 返回已认证的 Token
            return new SmsAuthenticationToken(
                    userDetails, null, userDetails.getAuthorities());
        } finally {
            redisUtil.del(smsCodeKey);  // 用完即删
        }
    }

    @Override
    public boolean supports(Class<?> authentication) {
        // ⑤ 只有 SmsAuthenticationToken 才交给我处理
        return SmsAuthenticationToken.class.isAssignableFrom(authentication);
    }
}
```

`SmsAuthenticationToken` 继承自 `AbstractAuthenticationToken`——和 `UsernamePasswordAuthenticationToken` 是平级关系。`ProviderManager` 按注册顺序依次询问每个 Provider 的 `supports()`，谁支持就交给谁处理。

### 10.2 ProviderManager 的调度逻辑

```
登录请求 → ProviderManager.authenticate()
  → 问 SmsAuthenticationProvider.supports() → 是 SmsAuthenticationToken 吗？
    → 是 → SmsAuthenticationProvider.authenticate() 处理
    → 否 → 问 DaoAuthenticationProvider.supports() → 是 UsernamePasswordAuthenticationToken 吗？
      → 是 → DaoAuthenticationProvider.authenticate() 处理
      → 否 → 抛出 ProviderNotFoundException
```

---

## 十一、升级六：完整登录流程安全加固

<strong>痛点</strong>：教程版的登录只做了用户名密码验证。生产环境还需要：验证码防刷、RSA 传输加密、异地登录检测、登录错误锁定。

### 11.1 完整登录代码

```java
@Slf4j
@Service
public class UserAuthService {

    @Autowired
    private UserMapper userMapper;
    @Autowired
    private TokenHelper tokenHelper;
    @Autowired
    private PasswordUtil passwordUtil;        // RSA 密码解密
    @Autowired
    private RedisUtil redisUtil;
    @Autowired
    private AuthenticationManager authenticationManager;
    @Autowired
    private GeoIpHelper geoIpHelper;          // IP 归属地查询

    @Value("${mall.mgt.tokenExpireTimeInRecord:3600}")
    private int tokenExpireTimeInRecord;

    /**
     * 用户名密码登录
     */
    public TokenEntity login(AuthUserEntity authUserEntity) {
        // ① 登录锁定检查
        checkUserIsLocked(authUserEntity.getUsername());

        try {
            // ② 验证图形验证码
            String code = redisUtil.get(getCaptchaKey(authUserEntity.getUuid()));
            AssertUtil.hasLength(code, "该验证码已失效");
            AssertUtil.isTrue(code.trim()
                    .equals(authUserEntity.getCode().trim()), "验证码错误");

            // ③ RSA 解密前端传来的加密密码
            String decodePassword = passwordUtil
                    .decodeRsaPassword(authUserEntity);

            // ④ 调用 Spring Security 认证链路
            UsernamePasswordAuthenticationToken authToken =
                    new UsernamePasswordAuthenticationToken(
                            authUserEntity.getUsername(), decodePassword);
            Authentication authentication =
                    authenticationManager.authenticate(authToken);
            SecurityContextHolder.getContext()
                    .setAuthentication(authentication);

            JwtUserEntity jwtUserEntity =
                    (JwtUserEntity) authentication.getPrincipal();

            // ⑤ 异地登录检测——如果本次登录城市与上次不同，发告警邮件
            HttpServletRequest request = ((ServletRequestAttributes)
                    RequestContextHolder.getRequestAttributes()).getRequest();
            String ip = IpUtil.getIpAddr(request);
            CityDTO cityDTO = geoIpHelper.getCity(ip);
            if (Objects.nonNull(cityDTO)) {
                userGeoIpService.validateRemoteLogin(
                        jwtUserEntity.getId(), cityDTO.getCity());
            }

            // ⑥ 生成 JWT + 存入 Redis——通过升级一的 TokenHelper
            String token = tokenHelper.generateToken(jwtUserEntity);
            redisUtil.del(getCaptchaKey(authUserEntity.getUuid()));  // 用完即删

            // ⑦ 返回 TokenEntity（含 username、token、roles、过期时间）
            List<String> roleList = jwtUserEntity.getAuthorities().stream()
                    .map(SimpleGrantedAuthority::getAuthority)
                    .collect(Collectors.toList());
            return new TokenEntity(jwtUserEntity.getUsername(),
                    token, roleList, tokenExpireTimeInRecord);

        } catch (Exception e) {
            // ⑧ 登录失败 → 记录错误次数 → 超过阈值锁定账户
            if (e instanceof BusinessException
                    || e instanceof BadCredentialsException) {
                recordLoginErrorUser(authUserEntity.getUsername());
            }
            throw new BusinessException("用户名或密码错误");
        }
    }

    // ⑨ Redis INCR 原子递增登录错误次数
    private void recordLoginErrorUser(String key) {
        String loginErrorKey = LOGIN_ERROR_USER_PREFIX + key;
        Long count = redisUtil.increment(loginErrorKey);  // 原子操作
        if (count == 1) {
            redisUtil.expire(loginErrorKey, lockedUserTime);
        }
        if (count > MAX_LOGIN_ERROR_COUNT) {
            redisUtil.set(LOCKED_USER_PREFIX + key, "true", lockedUserTime);
            throw new BusinessException("该用户已被锁定");
        }
    }

    private void checkUserIsLocked(String key) {
        String value = redisUtil.get(LOCKED_USER_PREFIX + key);
        if (StringUtils.hasLength(value)) {
            throw new BusinessException("该用户已被锁定");
        }
    }

    /**
     * 注销——删除 Redis 中的 Token 和用户信息
     */
    public void logout(HttpServletRequest request) {
        String token = TokenUtil.getTokenForAuthorization(request);
        AssertUtil.hasLength(token, "请重新登录");
        tokenHelper.delToken(token);  // 同时删除 token:xxx 和 user:xxx
    }
}
```

### 11.2 登录流程 6 个安全环节

| 环节 | 教程版 | 生产版 | 作用 |
|------|------|------|------|
| 密码传输 | 明文密码 | <strong>RSA 加密传输</strong> → 后端私钥解密 | 防止 HTTP 明文传输密码被中间人截获 |
| 验证码 | 无 | <strong>算术验证码</strong> + Redis TTL 保证时效性 | 防止暴力破解、机器人登录 |
| 认证方式 | 仅用户名密码 | <strong>用户名密码 + 短信验证码</strong>（双 Provider） | 支持多种登录场景 |
| 安全防护 | 无 | <strong>Redis INCR 登录错误计数</strong> → 超过阈值自动锁定 | 防止暴力破解 |
| 风控 | 无 | <strong>IP 归属地</strong> → 异地登录检测 | 账号异常登录告警 |
| Token 存储 | 仅生成返回 | <strong>Redis 双 key 存储</strong> → 支持主动失效 | 管理员改权限立即生效、支持踢人下线 |

---

# Part 4：验证与排错

---

## 十二、完整鉴权流程时序图

整合了上述所有组件，一个完整的请求鉴权流程如下：

```mermaid
sequenceDiagram
    participant C as 客户端
    participant JWT as JwtAuthFilter
    participant SEC as SecurityConfig<br/>URL规则
    participant AM as AuthManager
    participant UDS as UserDetailsService
    participant DB as 数据库
    participant API as Controller

    Note over C,API: ====== 登录流程 ======
    C->>API: POST /api/auth/login<br/>{username, password}
    API->>AM: authenticate username, password
    AM->>UDS: loadUserByUsername username
    UDS->>DB: SELECT * FROM t_user WHERE username=?
    DB-->>UDS: 用户数据
    UDS-->>AM: UserDetails 含加密密码
    AM->>AM: PasswordEncoder.matches<br/>输入的密码, 库中的密码
    AM-->>API: 认证成功 → Authentication对象
    API->>API: 生成AccessToken + RefreshToken
    API-->>C: {accessToken, refreshToken}

    Note over C,API: ====== 带Token的业务请求 ======
    C->>JWT: GET /api/admin/dashboard<br/>Header: Bearer xxx.yyy.zzz
    JWT->>JWT: 提取Token → 验证签名 → 解析Payload
    JWT->>JWT: 构造Authentication对象<br/>username, role
    JWT->>JWT: SecurityContextHolder<br/>.setAuthentication(...)
    JWT->>SEC: 继续过滤器链

    SEC->>SEC: 检查URL规则<br/>/api/admin/** → hasRole ADMIN
    SEC->>SEC: 从SecurityContext<br/>获取当前用户role
    alt 角色匹配
        SEC->>API: 放行
        API-->>C: 200 正常数据
    else 角色不匹配
        SEC-->>C: 403 Forbidden
    end

    Note over C,API: ====== 无Token的请求 ======
    C->>JWT: GET /api/user/info<br/>无 Authorization Header
    JWT->>JWT: 无Token, 直接放行
    JWT->>SEC: 继续过滤器链
    SEC->>SEC: 检查URL规则<br/>anyRequest().authenticated()
    SEC->>SEC: SecurityContext中<br/>无认证信息
    SEC-->>C: 401 Unauthorized
```

---

## 十三、接口测试

### 13.1 无 Token 访问受保护接口 → 401

```bash
# 请求
curl -X GET http://localhost:8080/api/user/info

# 响应
HTTP 401 Unauthorized
```

### 13.2 登录获取 Token

```bash
# 请求
curl -X POST http://localhost:8080/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"123456"}'

# 响应
{
  "accessToken": "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9...",
  "refreshToken": "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9...",
  "tokenType": "Bearer",
  "expiresIn": 1800
}
```

### 13.3 携带 Token 访问受保护接口 → 200

```bash
# 请求
curl -X GET http://localhost:8080/api/user/info \
  -H "Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9..."

# 响应
HTTP 200
"用户个人信息"
```

### 13.4 普通用户访问管理员接口 → 403

```bash
# 用 zhangsan(ROLE_USER) 的 Token 访问管理员接口
curl -X GET http://localhost:8080/api/admin/dashboard \
  -H "Authorization: Bearer {zhangsan的Token}"

# 响应
HTTP 403 Forbidden
```

### 13.5 Token 过期后刷新

```bash
# 请求
curl -X POST http://localhost:8080/api/auth/refresh \
  -H "Content-Type: application/json" \
  -d '{"refreshToken":"eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9..."}'

# 响应
{
  "accessToken": "新的AccessToken",
  "refreshToken": "新的RefreshToken",
  "tokenType": "Bearer",
  "expiresIn": 1800
}
```

---

## 十四、补充配置

### 14.1 自定义认证失败和权限不足的响应

Spring Security 默认的 401 和 403 响应是 HTML 页面或很简略的文本，前后端分离项目中需要返回统一的 JSON 格式。

```java
@Configuration
@EnableWebSecurity
public class SecurityConfig {

    @Bean
    public SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        http
            // 自定义认证失败处理（未登录）
            .exceptionHandling()
            .authenticationEntryPoint((request, response, authException) -> {
                response.setContentType("application/json;charset=UTF-8");
                response.setStatus(HttpServletResponse.SC_UNAUTHORIZED);
                response.getWriter().write(
                    "{\"code\":401,\"message\":\"请先登录\"}");
            })
            // 自定义授权失败处理（权限不足）
            .accessDeniedHandler((request, response, accessDeniedException) -> {
                response.setContentType("application/json;charset=UTF-8");
                response.setStatus(HttpServletResponse.SC_FORBIDDEN);
                response.getWriter().write(
                    "{\"code\":403,\"message\":\"权限不足, 无法访问\"}");
            });

        return http.build();
    }
}
```

### 14.2 允许跨域（CORS）

前后端分离项目中，前端（如 `localhost:3000`）和后端（`localhost:8080`）不在同一个端口，需要配置跨域：

```java
@Configuration
@EnableWebSecurity
public class SecurityConfig {

    @Bean
    public SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        http
            // 开启跨域
            .cors().configurationSource(corsConfigurationSource())
            .and()
            // ... 其他配置 ...;

        return http.build();
    }

    @Bean
    public CorsConfigurationSource corsConfigurationSource() {
        CorsConfiguration config = new CorsConfiguration();
        config.setAllowedOrigins(Arrays.asList("http://localhost:3000"));
        config.setAllowedMethods(Arrays.asList("GET", "POST", "PUT", "DELETE", "OPTIONS"));
        config.setAllowedHeaders(Arrays.asList("*"));
        config.setAllowCredentials(true);

        UrlBasedCorsConfigurationSource source = new UrlBasedCorsConfigurationSource();
        source.registerCorsConfiguration("/**", config);
        return source;
    }
}
```

### 14.3 密码加密工具（生成 BCrypt 密文）

```java
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;

public class PasswordGenerator {
    public static void main(String[] args) {
        BCryptPasswordEncoder encoder = new BCryptPasswordEncoder();
        // 每次生成的密文不同，但都能匹配"123456"
        String encoded = encoder.encode("123456");
        System.out.println(encoded);
    }
}
```

### 14.4 忽略某些 URL（如 Swagger、静态资源）

```java
@Bean
public WebSecurityCustomizer webSecurityCustomizer() {
    // 完全忽略某些 URL（不经过过滤器链）
    return (web) -> web.ignoring()
        .antMatchers("/favicon.ico", "/error");
}
```

---

## 十五、常见问题排查

| 问题现象 | 可能原因 | 解决方向 |
|------|------|------|
| Filter 中抛出的异常没有被 `@RestControllerAdvice` 捕获 | Filter 在 Servlet 容器层，不在 Spring MVC 上下文 | 参考第八章的 `FilterExceptionController` 桥接模式——forward 到 Controller 再重新 throw |
| 所有请求都返回 401 | JWT 过滤器没有正确设置 `SecurityContext` | 检查 `SecurityContextHolder.getContext().setAuthentication()` 是否执行；另外检查 Redis 中的 `user:{username}` key 是否存在 |
| `@Async` 方法中获取不到当前用户 | `SecurityContextHolder` 默认是线程绑定的 | 子线程需要手动传递 `SecurityContext` |
| 登录接口返回 403 或 401 | 登录接口需要 `.permitAll()`，或 CSRF 未关闭 | 在 `SecurityFilterChain` 中放行；如果用 `@NoLogin` 注解，确认 `initNoLogin()` 在启动时执行了 |
| Token 解析报错 | 密钥不一致、Token 格式错误、Redis 中 Token 已过期 | Token 解析失败可能是因为 Redis TTL 到期导致 `token:{username}` key 被自动删除了——此时虽然 JWT 本身未过期但在 Redis 找不到了 |
| 角色校验不生效 | `hasRole("ADMIN")` 会自动加 `ROLE_` 前缀 | 如果用了 `GrantedAuthorityDefaults("")`（见第七章），<strong>已去掉 ROLE_ 前缀</strong>——此时应该用 `hasAuthority("admin:user:delete")` 而不是 `hasRole("ADMIN")` |
| `@PreAuthorize` 注解不生效 | 没有开启 `@EnableGlobalMethodSecurity` | 在 SecurityConfig 上加 `@EnableGlobalMethodSecurity(prePostEnabled = true)`（见第七章） |
| 新增了公开接口但仍要求登录 | 忘记加 `@NoLogin` 注解，或 `initNoLogin()` 扫描时机问题 | 确认方法上有 `@NoLogin` 注解；如果是动态注册的 Controller，可能不会被扫描到——改为显式 `.antMatchers()` 配置 |

---

## 十六、总结

本文按照"<strong>先搞懂概念 → 教程版完整实现 → 生产版逐项升级 → 验证排错</strong>"的顺序，完整讲解了 Spring Security + JWT 企业级鉴权体系。

### 16.1 教程版 vs 生产版 全貌对比

| 模块 | 教程做法 | 生产做法 | 为什么不同 |
|------|------|------|------|
| JWT 工具 | Hutool `JWTUtil.createToken(payload, key)` | JJWT `Jwts.builder().signWith(HS512)` + Redis 双 key | Token Payload 只存 username——安全性；Redis 存储完整 UserDetails——支持主动失效 |
| Token 主动失效 | 没有（依赖 JWT 自然过期） | 删 Redis key 即刻失效 | 支持"踢人下线"——管理后台修改角色后立即生效 |
| JWT Filter | `OncePerRequestFilter` + 直接写 response | `GenericFilterBean` + `FilterExceptionController` forward 桥接 | Filter 异常不被 `@ControllerAdvice` 捕获——forward 到 Controller 重新 throw 以输出统一 JSON |
| SecurityConfig | 4 行 permitAll | 7 类 permitAll + `@NoLogin` 自动扫描 + `@EnableGlobalMethodSecurity` | 生产项目需要：监控页放行、预检放行、动态 URL 放行、方法级权限注解 |
| 权限加载 | `t_user.role` 字段 | User → Role → Menu 三表联查 | 真实 RBAC 模型——权限码来自角色的 `permission` 字段 + 菜单的 `permission` 字段 |
| 登录流程 | 用户名密码明文 → 签发 Token | 验证码校验 + RSA 解密 + 短信双认证 + 异地登录检测 + 登录锁定 | 安全不是"有没有登录"，而是"登录的人是不是真的是他" |
| 密码加密 | 仅 BCrypt 存储 | BCrypt 存储 + RSA 传输加密 | 防止 HTTP 明文传输密码被中间人截获 |

### 16.2 关键配置速查（生产版）

| 配置项 | 代码 | 作用 |
|------|------|------|
| 关闭 Session | `.sessionManagement().sessionCreationPolicy(STATELESS)` | JWT 方案核心 |
| 关闭 CSRF | `.csrf().disable()` | 前后端分离不需要 CSRF |
| 去除 ROLE_ 前缀 | `new GrantedAuthorityDefaults("")` | 权限码和数据库一致，不混淆 |
| 开启方法级权限 | `@EnableGlobalMethodSecurity(prePostEnabled = true)` | Controller 方法上可用 `@PreAuthorize` |
| 自动扫描免登录 | `initNoLogin(applicationContext)` | 加 `@NoLogin` 注解即放行，不改 SecurityConfig |
| 注册自定义 Filter | `.apply(new JwtTokenConfigurer())` | 在 SecurityConfigurerAdapter 中 new Filter 保证初始化顺序 |
| Filter 异常转发 | `request.setAttribute("filterError", e)` + forward | Filter 异常 → Controller 重新 throw → 统一 JSON 输出 |

### 16.3 学习路径建议

1. 读 Part 1，理解认证/授权的两个核心问题（"你是谁" + "你能做什么"）
2. 读 Part 2，跟着教程版代码从头写一遍，跑通 401、403、200 三种响应
3. 读 Part 3，理解教程版与生产版的 6 个差异，按顺序逐个升级——<strong>建议从升级一（JJWT+Redis）开始</strong>
4. 加上 `@NoLogin` 注解 + `initNoLogin()` 自动扫描，体会"开闭原则"的实际应用
5. 最后加上 `FilterExceptionController` 桥接——你会发现"统一 JSON 返回格式"的最后一公里终于打通了
