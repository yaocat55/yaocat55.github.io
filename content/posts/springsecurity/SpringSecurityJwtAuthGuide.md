---
title: "Spring Security + JWT 企业级鉴权实战"
date: 2022-09-18T07:00:19+00:00
tags: ["Spring全家桶"]
categories: ["SpringSecurity类"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "从零开始学习Spring Security + JWT企业级鉴权，涵盖认证与授权的核心概念、JWT结构详解、过滤器链架构，以及完整的Spring Boot集成实战代码"
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

## 🤔 一、从一个没有防护的接口说起

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

1. **你是谁？（认证 Authentication）**——访问者是否已经登录？用户名密码是否正确？
2. **你能做什么？（授权 Authorization）**——登录之后，你有没有权限删除用户？还是只能查看？

Spring Security 就是用来解决这两个问题的框架。本文将带你从零开始，用 **Spring Boot + Spring Security + JWT + Hutool** 搭建一套完整的企业级鉴权体系。

> **阅读前提**：本文假设你已经会使用 Spring Boot 写基本的 CRUD 接口。如果你从未接触过 Spring Security，从这篇开始即可。

---

## 📖 二、核心概念：认证与授权

在写代码之前，先把两个最关键的概念搞清楚。

### 🔐 2.1 认证（Authentication）——"你是谁"

认证就是验证用户身份的过程。最常见的认证方式是**用户名 + 密码**：

```
用户提交用户名密码 → 系统验证是否正确 → 正确则签发凭证（如 JWT） → 用户持凭证访问
```

认证需要回答的问题：**这个人真的是他声称的那个人吗？**

业务上常见的认证方式：

| 方式 | 说明 | 使用场景 |
|------|------|------|
| 用户名 + 密码 | 最基础的认证方式 | 所有系统的标配 |
| 手机验证码 | 通过短信验证 | 移动端登录、快速注册 |
| 邮箱 + 密码 | 类似用户名密码 | 国际化产品 |
| 扫码登录 | 通过已登录设备扫码确认 | Web 端快速登录 |
| 第三方登录 | OAuth2.0（微信 / 企业微信 / 钉钉） | 企业办公、社交产品 |
| 指纹 / 面容 | 生物识别 | App 端便捷登录 |

### 🛡️ 2.2 授权（Authorization）——"你能做什么"

授权发生在认证**之后**。系统已经知道你是谁了，现在需要判断你有没有权限做某件事。

授权需要回答的问题：**这个人有资格执行这个操作吗？**

业务上常见的授权模式：

| 模式 | 说明 | 示例 |
|------|------|------|
| 角色授权（RBAC） | 基于角色控制权限 | `ROLE_ADMIN` 可以删除用户，`ROLE_USER` 不行 |
| 权限码授权 | 基于细粒度权限码 | `user:delete` 权限才能删除用户 |
| 资源级授权 | 基于数据归属 | 只能查看自己部门的订单 |
| 动态授权 | 权限规则存储在数据库中 | 后台管理员可动态配置角色权限 |

### 🔗 2.3 认证与授权的关系

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

> **关键理解**：401（Unauthorized）和 403（Forbidden）的区别——401 是"我不知道你是谁，请先登录"；403 是"我知道你是谁，但你没资格做这件事"。前者是认证问题，后者是授权问题。

---

## 🏗️ 三、Spring Security 架构总览

在写代码之前，先理解 Spring Security 的整体结构和核心组件。不需要看源码，只需要知道每个组件是干什么的。

### 🔗 3.1 过滤器链（Filter Chain）

Spring Security 的核心是一组**过滤器链**。每个 HTTP 请求都会依次经过这条链上的所有过滤器，每个过滤器负责一件具体的事情。

```mermaid
flowchart LR
    classDef root fill:#1E88E5,stroke:#0D47A1,stroke-width:2px,color:#FFFFFF,font-weight:bold;
    classDef branch fill:#FFE082,stroke:#FFB300,stroke-width:2px,color:#5D4037,font-weight:bold;
    classDef leaf fill:#F5F5F5,stroke:#BDBDBD,stroke-width:1.5px,color:#212121;
    classDef highlight fill:#FFCCBC,stroke:#E64A19,stroke-width:1.5px,color:#D84315,font-weight:bold;

    ROOT[Spring Security<br/>过滤器链]

    ROOT --> B1[认证相关过滤器]
    B1 --> F1["🔐 UsernamePassword<br/>AuthenticationFilter<br/>处理用户名密码登录"]
    B1 --> F2["🔑 JwtAuthentication<br/>Filter (自定义)<br/>从请求头提取JWT<br/>解析并设置认证状态"]

    ROOT --> B2[授权相关过滤器]
    B2 --> F3["✅ FilterSecurity<br/>Interceptor<br/>最终授权决策点<br/>判断是否有权限访问"]
    B2 --> F4["🛡️ ExceptionTranslation<br/>Filter<br/>将认证/授权异常<br/>转换为HTTP响应"]

    ROOT --> B3[安全基础过滤器]
    B3 --> F5["🧱 SecurityContext<br/>PersistenceFilter<br/>安全上下文持久化"]
    B3 --> F6["🚫 CsrfFilter<br/>CSRF防护<br/>(前后端分离可关闭)"]

    ROOT --> B4[核心组件]
    B4 --> C1["🏗️ AuthenticationManager\n认证管理器(接口)\n默认实现: ProviderManager"]
    B4 --> C2["👤 UserDetailsService\n加载用户数据的接口\n你需要实现它"]
    B4 --> C3["🔒 PasswordEncoder\n密码加密器\n常用的: BCryptPasswordEncoder"]
    B4 --> C4["📋 SecurityContextHolder\n持有当前请求的\n认证状态(Authentication)"]

    class ROOT root;
    class B1,B2,B3,B4 branch;
    class F1,F3,F5,F6,C1,C2,C3,C4 leaf;
    class F2 highlight;
```

### 📋 3.2 核心组件一句话介绍

| 组件 | 作用 | 你需要做什么 |
|------|------|------|
| `SecurityContextHolder` | 持有当前请求用户的认证信息 | 不需要操作，Spring Security 自动管理 |
| `Authentication` | 代表"当前用户是谁"及其权限列表 | 登录成功后构造这个对象 |
| `UserDetailsService` | 根据用户名从数据库加载用户信息 | **必须实现**：写一个类去数据库查用户 |
| `AuthenticationManager` | 认证管理器，负责调用 `UserDetailsService` 验证用户 | 通常不需要自定义，Spring Security 有默认实现 |
| `PasswordEncoder` | 密码加密器，存库的密码必须加密 | 配置一个 `BCryptPasswordEncoder` Bean |
| `SecurityFilterChain` | 过滤器链配置，定义哪些 URL 需要什么权限 | **最重要**：自定义安全规则 |
| `ProviderManager` | `AuthenticationManager` 的默认实现，管理多个认证方式 | 不需要操作 |

### 🔄 3.3 Spring Security 处理一个请求的完整流程

```mermaid
sequenceDiagram
    participant C as 客户端
    participant F1 as SecurityContext<br/>PersistenceFilter
    participant F2 as JWT认证过滤器<br/>(自定义)
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
        F2->>F2: 跳过(匿名访问)
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

## 🔍 四、JWT 详解

JWT（JSON Web Token）是当前前后端分离项目中**最主流**的认证凭证格式。Spring Security 默认使用 Session 机制，但在前后端分离架构中，JWT 是完全替代 Session 的方案。

### ❓ 4.1 JWT 是什么

JWT 是一串经过签名（Signature）的字符串，用来在两个系统之间安全地传递信息。在鉴权场景中：

-  登录成功后，服务端生成一个 JWT 返回给客户端
-  客户端将它存储起来（通常是 `localStorage` 或 `Cookie`）
-  后续每次请求都在 HTTP Header 中携带这个 JWT
-  服务端验证 JWT 的签名，从中解析出用户身份

### 🧬 4.2 JWT 的结构

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
    classDef highlight fill:#FFCCBC,stroke:#E64A19,stroke-width:1.5px,color:#D84315,font-weight:bold;

    JWT[完整的JWT Token]

    JWT --> HEADER[Header 头部]
    HEADER --> H1["alg: HS256\n(签名算法)"]
    HEADER --> H2["typ: JWT\n(令牌类型)"]

    JWT --> PAYLOAD[Payload 载荷]
    PAYLOAD --> P1["sub: 用户ID\n(主题，标准字段)"]
    PAYLOAD --> P2["iat: 签发时间\n(标准时间字段)"]
    PAYLOAD --> P3["exp: 过期时间\n(标准时间字段)"]
    PAYLOAD --> P4["自定义字段\n如: username, roles"]

    JWT --> SIG[Signature 签名]
    SIG --> S1["HMACSHA256(\n  base64Url(header)\n  + '.' +\n  base64Url(payload),\n  secret\n)"]

    class JWT startEnd;
    class HEADER,PAYLOAD,SIG process;
    class H1,H2,P1,P2,P3,P4,S1 data;
```

**三部分的详细说明**：

| 部分 | 内容 | 是否加密 | 说明 |
|------|------|:---:|------|
| **Header** | 签名算法 + Token 类型 | 否（仅 Base64 编码） | 指明用 HS256 还是 RS256 |
| **Payload** | 用户信息 + 过期时间 + 自定义数据 | 否（仅 Base64 编码） | <span style="color:red">**绝对不能放密码等敏感信息**</span>，Base64 只是编码不是加密 |
| **Signature** | 签名（防篡改） | 签名校验 | 用 Header 指定的算法，将 Header + Payload + 密钥一起签名。**任何人修改 Payload 都会导致签名不匹配** |

### 🔏 4.3 JWT 的验证原理

服务端收到 JWT 后：

1. 用 `.` 分割出 Header、Payload、Signature
2. 用相同的算法和密钥，对 Header.Payload 重新计算签名
3. 对比计算出的签名和收到的 Signature 是否一致
4. 一致 → 数据未被篡改，可以信任 Payload 中的用户信息
5. 不一致 → 数据被篡改过，拒绝请求

> **关键设计**：JWT 不是用来**隐藏数据**的（Payload 任何人 Base64 解码就能看到），而是用来**防止数据被篡改**的。因此 Payload 中绝不能放密码等敏感信息。

### ⚖️ 4.4 JWT vs Session 对比

| 对比维度 | Session（传统方案） | JWT（前后端分离方案） |
|------|------|------|
| 存储位置 | 服务端内存 / Redis | 客户端（localStorage / Cookie） |
| 服务端状态 | **有状态**——服务端必须保存 Session | **无状态**——服务端不保存，密钥验证即可 |
| 扩展性 | 多服务器需要共享 Session（Redis） | 天然支持多服务器，任何服务器都能验证 |
| 注销方式 | 删除服务端 Session 即可 | 需要客户端删除 Token，或服务端维护黑名单 |
| 跨域 | Cookie 跨域受限 | Header 携带，无跨域问题 |
| 适用场景 | 服务端渲染（JSP / Thymeleaf）、单体应用 | 前后端分离、微服务、移动 App |

### 🔑 4.5 Access Token + Refresh Token 双令牌机制

企业生产中，JWT 通常采用**双令牌**机制：

| 令牌 | 有效期 | 存储位置 | 作用 |
|------|:---:|------|------|
| **Access Token** | 短（15 ~ 30 分钟） | 客户端内存 | 每次请求携带，用于认证 |
| **Refresh Token** | 长（7 天 ~ 30 天） | HttpOnly Cookie 或安全存储 | Access Token 过期后，用它换取新的 Access Token |

```mermaid
sequenceDiagram
    participant C as 客户端
    participant S as 服务端

    Note over C,S: 阶段一：登录
    C->>S: POST /api/auth/login<br/>用户名 + 密码
    S->>S: 验证用户名密码
    S->>C: 返回 Access Token (30分钟)<br/>+ Refresh Token (7天)

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

> **为什么需要双令牌？** Access Token 短有效期是为了安全——即使泄露，攻击者也只能在 30 分钟内使用；Refresh Token 长有效期是为了用户体验——用户不用频繁输入密码重新登录。Refresh Token 通常存储在 HttpOnly Cookie 中（JS 无法读取），降低被 XSS 攻击窃取的风险。

---

## 💻 五、JWT 在 Java 中的使用方式

在正式集成 Spring Security 之前，先理解如何在 Java 代码中生成和解析 JWT。这里使用 **Hutool** 的 JWT 工具类（`hutool-jwt`），它封装了底层的 JWT 操作，API 非常简洁。

### 📋 5.1 添加依赖

```xml
<!-- Hutool 核心工具（包含JWT模块） -->
<dependency>
    <groupId>cn.hutool</groupId>
    <artifactId>hutool-all</artifactId>
    <version>5.8.25</version>
</dependency>

<!-- Spring Security -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-security</artifactId>
</dependency>

<!-- Spring Boot Web -->
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-web</artifactId>
</dependency>
```

### ✍️ 5.2 使用 Hutool 生成 JWT

```java
import cn.hutool.jwt.JWT;
import cn.hutool.jwt.JWTUtil;
import java.util.HashMap;
import java.util.Map;

public class JwtDemo {

    // 密钥（实际项目中应放在配置文件中，且足够复杂）
    private static final String SECRET = "my-secret-key-for-jwt-signing-2024";

    public static void main(String[] args) {
        // 1. 构建 Payload（载荷）
        Map<String, Object> payload = new HashMap<>();
        payload.put("userId", 1001);             // 用户ID（自定义）
        payload.put("username", "zhangsan");     // 用户名（自定义）
        payload.put("role", "ROLE_ADMIN");       // 角色（自定义）

        // 2. 生成 JWT，有效期30分钟
        String token = JWTUtil.createToken(payload, SECRET.getBytes());

        System.out.println("生成的JWT:");
        System.out.println(token);
        // 输出类似: eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9...
    }
}
```

### ✅ 5.3 使用 Hutool 解析和验证 JWT

```java
public class JwtDemo {

    private static final String SECRET = "my-secret-key-for-jwt-signing-2024";

    public static void main(String[] args) {
        String token = "eyJ0eXAi..."; // 之前生成的Token

        // 1. 验证Token是否有效（签名是否正确，是否过期）
        boolean valid = JWTUtil.verify(token, SECRET.getBytes());
        System.out.println("Token是否有效: " + valid);

        if (valid) {
            // 2. 解析Token，读取Payload中的数据
            JWT jwt = JWTUtil.parseToken(token);

            // 读取自定义字段
            Integer userId = (Integer) jwt.getPayload("userId");
            String username = (String) jwt.getPayload("username");
            String role = (String) jwt.getPayload("role");

            System.out.println("userId: " + userId);
            System.out.println("username: " + username);
            System.out.println("role: " + role);
        }
    }
}
```

### ⏰ 5.4 设置过期时间

Hutool 的 JWT 支持设置过期时间：

```java
public class JwtDemo {

    private static final String SECRET = "my-secret-key-for-jwt-signing-2024";

    // 生成带过期时间的 Access Token（30分钟）
    public static String createAccessToken(Long userId, String username) {
        Map<String, Object> payload = new HashMap<>();
        payload.put("userId", userId);
        payload.put("username", username);
        // 设置过期时间：当前时间 + 30分钟
        payload.put("exp", System.currentTimeMillis() + 30 * 60 * 1000);
        return JWTUtil.createToken(payload, SECRET.getBytes());
    }

    // 生成 Refresh Token（7天）
    public static String createRefreshToken(Long userId) {
        Map<String, Object> payload = new HashMap<>();
        payload.put("userId", userId);
        payload.put("type", "refresh");  // 标记为Refresh Token
        payload.put("exp", System.currentTimeMillis() + 7 * 24 * 60 * 60 * 1000);
        return JWTUtil.createToken(payload, SECRET.getBytes());
    }
}
```

> **Hutool JWT 常用 API 速查**：
>
> | 方法 | 作用 |
> |------|------|
> | `JWTUtil.createToken(map, key)` | 生成 JWT |
> | `JWTUtil.verify(token, key)` | 验证 JWT 签名和有效期 |
> | `JWTUtil.parseToken(token)` | 解析 JWT，读取 Payload |
> | `jwt.getPayload("key")` | 读取 Payload 中指定字段的值 |

---

## 🚀 六、完整实战：Spring Boot + Spring Security + JWT + Hutool

下面是从零搭建一个完整鉴权系统的全部代码。需求如下：

- 用户表存储用户名、加密后的密码、角色
-  登录接口：验证用户名密码，返回 Access Token + Refresh Token
-  所有业务接口需要携带有效的 Access Token 才能访问
-  管理员接口需要 `ROLE_ADMIN` 角色
-  提供刷新 Token 接口

### 📋 6.1 项目依赖（pom.xml）

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

    <!-- Hutool 工具库 -->
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

### ⚙️ 6.2 配置文件（application.yml）

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

### 🗄️ 6.3 数据库表结构

```sql
CREATE TABLE `t_user` (
    `id`          BIGINT       NOT NULL AUTO_INCREMENT COMMENT '用户ID',
    `username`    VARCHAR(50)  NOT NULL COMMENT '用户名',
    `password`    VARCHAR(200) NOT NULL COMMENT '加密后的密码',
    `role`        VARCHAR(50)  NOT NULL DEFAULT 'ROLE_USER' COMMENT '角色',
    `enabled`     TINYINT(1)   NOT NULL DEFAULT 1 COMMENT '是否启用(1:是 0:否)',
    `create_time` DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uk_username` (`username`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='用户表';

-- 插入测试用户（密码都是 123456，BCrypt 加密后的结果）
INSERT INTO t_user (username, password, role) VALUES
('admin', '$2a$10$N.zmdr9k7uOCQb376NoUnuTJ8iAt6Z5EHsM8lE9lBOsl7iAt6Z5Eh', 'ROLE_ADMIN'),
('zhangsan', '$2a$10$N.zmdr9k7uOCQb376NoUnuTJ8iAt6Z5EHsM8lE9lBOsl7iAt6Z5Eh', 'ROLE_USER');
```

### 📂 6.4 代码结构总览

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

### 🏷️ 6.5 实体类

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

### 🔧 6.6 JWT 工具类

```java
package com.mallshop.mallsecurity.util;

import cn.hutool.jwt.JWT;
import cn.hutool.jwt.JWTUtil;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.util.HashMap;
import java.util.Map;

@Component
public class JwtUtil {

    @Value("${jwt.secret}")
    private String secret;

    @Value("${jwt.access-token-expire}")
    private Long accessTokenExpire;

    @Value("${jwt.refresh-token-expire}")
    private Long refreshTokenExpire;

    /**
     * 生成 Access Token
     */
    public String createAccessToken(Long userId, String username, String role) {
        Map<String, Object> payload = new HashMap<>();
        payload.put("userId", userId);
        payload.put("username", username);
        payload.put("role", role);
        payload.put("type", "access");
        payload.put("exp", System.currentTimeMillis() + accessTokenExpire);
        return JWTUtil.createToken(payload, secret.getBytes());
    }

    /**
     * 生成 Refresh Token
     */
    public String createRefreshToken(Long userId) {
        Map<String, Object> payload = new HashMap<>();
        payload.put("userId", userId);
        payload.put("type", "refresh");
        payload.put("exp", System.currentTimeMillis() + refreshTokenExpire);
        return JWTUtil.createToken(payload, secret.getBytes());
    }

    /**
     * 验证Token是否有效
     */
    public boolean verify(String token) {
        try {
            return JWTUtil.verify(token, secret.getBytes());
        } catch (Exception e) {
            return false;
        }
    }

    /**
     * 从Token中获取用户ID
     */
    public Long getUserId(String token) {
        JWT jwt = JWTUtil.parseToken(token);
        return Long.valueOf(jwt.getPayload("userId").toString());
    }

    /**
     * 从Token中获取用户名
     */
    public String getUsername(String token) {
        JWT jwt = JWTUtil.parseToken(token);
        return jwt.getPayload("username").toString();
    }

    /**
     * 从Token中获取角色
     */
    public String getRole(String token) {
        JWT jwt = JWTUtil.parseToken(token);
        return jwt.getPayload("role").toString();
    }

    /**
     * 判断是否为Access Token
     */
    public boolean isAccessToken(String token) {
        JWT jwt = JWTUtil.parseToken(token);
        return "access".equals(jwt.getPayload("type"));
    }
}
```

### 🔒 6.7 JWT 认证过滤器

<span style="color:red">这是整个鉴权体系最核心的代码</span>。它拦截每一个 HTTP 请求，检查是否携带了有效的 JWT。

```java
package com.mallshop.mallsecurity.filter;

import com.mallshop.mallsecurity.util.JwtUtil;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.util.StringUtils;
import org.springframework.web.filter.OncePerRequestFilter;

import javax.servlet.FilterChain;
import javax.servlet.ServletException;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.Collections;

@Component
public class JwtAuthenticationFilter extends OncePerRequestFilter {

    @Autowired
    private JwtUtil jwtUtil;

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain filterChain)
            throws ServletException, IOException {

        // 1. 从请求头中提取 Token
        String token = extractToken(request);

        // 2. 如果没有Token，直接放行（让后续过滤器处理——大概率返回401）
        if (!StringUtils.hasText(token)) {
            filterChain.doFilter(request, response);
            return;
        }

        // 3. 验证Token是否有效
        if (!jwtUtil.verify(token)) {
            filterChain.doFilter(request, response);
            return;
        }

        // 4. Token有效，解析用户信息
        String username = jwtUtil.getUsername(token);
        String role = jwtUtil.getRole(token);

        // 5. 构造 Authentication 对象，设置到 SecurityContext 中
        //    这一步完成后，Spring Security 就知道"当前用户是谁"了
        UsernamePasswordAuthenticationToken authentication =
                new UsernamePasswordAuthenticationToken(
                    username,
                    null,  // 密码不需要（已经有Token了）
                    Collections.singletonList(new SimpleGrantedAuthority(role))
                );

        SecurityContextHolder.getContext().setAuthentication(authentication);

        // 6. 继续执行后续过滤器
        filterChain.doFilter(request, response);
    }

    /**
     * 从请求头中提取 Bearer Token
     */
    private String extractToken(HttpServletRequest request) {
        String bearerToken = request.getHeader("Authorization");
        if (StringUtils.hasText(bearerToken) && bearerToken.startsWith("Bearer ")) {
            return bearerToken.substring(7);  // 去掉 "Bearer " 前缀
        }
        return null;
    }
}
```

> **代码说明**：
> - 第 31 行：`extractToken` 从 `Authorization` 请求头提取 Token，格式是 `Bearer xxx.yyy.zzz`
> - 第 34 ~ 37 行：没有 Token 时直接放行，不设置认证信息。后续 FilterSecurityInterceptor 会检查 URL 是否需要认证，需要则返回 401
> - 第 39 ~ 42 行：Token 无效（签名不对、已过期）也放行，交给后续过滤器处理
> - 第 45 ~ 53 行：Token 有效时，构造 `UsernamePasswordAuthenticationToken` 并设置到 `SecurityContextHolder`。这告诉 Spring Security："当前请求的用户是 xx，角色是 yy"
> - `OncePerRequestFilter`：Spring 提供的基类，保证在一个请求中该过滤器只执行一次

### ⚙️ 6.8 Spring Security 核心配置

<span style="color:red">这是定义安全规则的地方</span>——哪些 URL 需要认证、哪些 URL 需要什么角色。

```java
package com.mallshop.mallsecurity.config;

import com.mallshop.mallsecurity.filter.JwtAuthenticationFilter;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpMethod;
import org.springframework.security.authentication.AuthenticationManager;
import org.springframework.security.config.annotation.authentication.configuration.AuthenticationConfiguration;
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

    @Autowired
    private JwtAuthenticationFilter jwtAuthenticationFilter;

    /**
     * 配置密码加密器
     * BCrypt 是 Spring Security 推荐的加密算法
     */
    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder();
    }

    /**
     * 暴露 AuthenticationManager 为 Bean
     * 在登录接口中需要手动调用它来验证用户名密码
     */
    @Bean
    public AuthenticationManager authenticationManager(
            AuthenticationConfiguration config) throws Exception {
        return config.getAuthenticationManager();
    }

    /**
     * 安全过滤器链配置——整个安全规则的核心
     */
    @Bean
    public SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        http
            // 1. 关闭 CSRF（前后端分离 + JWT 不需要 CSRF 防护）
            .csrf().disable()

            // 2. 设置为无状态模式（不创建 Session，每个请求独立认证）
            .sessionManagement()
            .sessionCreationPolicy(SessionCreationPolicy.STATELESS)

            // 3. 配置 URL 访问规则
            .and()
            .authorizeRequests()
            // 公开接口——不需要认证
            .antMatchers("/api/auth/login", "/api/auth/refresh").permitAll()
            // 管理员接口——需要 ROLE_ADMIN 角色
            .antMatchers("/api/admin/**").hasRole("ADMIN")
            // 其他所有接口——需要认证（登录）即可
            .anyRequest().authenticated()

            // 4. 将 JWT 过滤器添加到 Spring Security 过滤器链中
            //    放在 UsernamePasswordAuthenticationFilter 之前
            .and()
            .addFilterBefore(jwtAuthenticationFilter,
                             UsernamePasswordAuthenticationFilter.class);

        return http.build();
    }
}
```

> **配置逐行解读**：
>
> - **`.csrf().disable()`**：CSRF（跨站请求伪造）攻击通常发生在基于 Session + Cookie 的 Web 应用中。前后端分离 + JWT 的场景下，Token 在 Header 中，不依赖 Cookie，因此不存在 CSRF 风险，可以安全关闭
> - **`SessionCreationPolicy.STATELESS`**：告诉 Spring Security **不要创建 HttpSession**。这是 JWT 方案的关键配置——服务端不保存用户状态，每个请求通过 Token 独立认证
> - **`.antMatchers("/api/auth/login").permitAll()`**：登录接口和刷新 Token 接口**不需要认证**，否则用户连登录都做不了
> - **`.antMatchers("/api/admin/**").hasRole("ADMIN")`**：以 `/api/admin/` 开头的 URL 需要 `ROLE_ADMIN` 角色。注意 `hasRole("ADMIN")` 会自动添加 `ROLE_` 前缀
> - **`.anyRequest().authenticated()`**：除了上面列出的之外，所有接口都需要认证

### 👤 6.9 UserDetailsService 实现

Spring Security 需要一个 `UserDetailsService` 来根据用户名加载用户信息。

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

        // 1. 从数据库查询用户
        User user = userMapper.selectOne(
            new LambdaQueryWrapper<User>()
                .eq(User::getUsername, username)
        );

        if (user == null) {
            throw new UsernameNotFoundException("用户不存在: " + username);
        }

        if (!user.getEnabled()) {
            throw new RuntimeException("用户已被禁用");
        }

        // 2. 将我们的 User 实体转换为 Spring Security 的 UserDetails
        return org.springframework.security.core.userdetails.User
                .withUsername(user.getUsername())
                .password(user.getPassword())            // 数据库中已加密的密码
                .roles(user.getRole().replace("ROLE_", ""))  // 去掉ROLE_前缀
                .disabled(!user.getEnabled())
                .build();
    }
}
```

### 🔑 6.10 登录接口

```java
package com.mallshop.mallsecurity.controller;

import com.mallshop.mallsecurity.util.JwtUtil;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.security.authentication.AuthenticationManager;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.*;

import javax.validation.Valid;
import javax.validation.constraints.NotBlank;

@RestController
@RequestMapping("/api/auth")
public class AuthController {

    @Autowired
    private AuthenticationManager authenticationManager;

    @Autowired
    private JwtUtil jwtUtil;

    /**
     * 登录接口
     */
    @PostMapping("/login")
    public LoginResponse login(@Valid @RequestBody LoginRequest request) {
        // 1. 构造认证令牌（未认证状态）
        UsernamePasswordAuthenticationToken authToken =
                new UsernamePasswordAuthenticationToken(
                    request.getUsername(), request.getPassword());

        // 2. 调用 AuthenticationManager 进行认证
        //    内部会调用 UserDetailsService.loadUserByUsername()
        //    并用 PasswordEncoder 验证密码
        Authentication authentication = authenticationManager.authenticate(authToken);

        // 3. 认证成功，生成 JWT
        //    从认证结果中获取用户信息
        org.springframework.security.core.userdetails.User userDetails =
                (org.springframework.security.core.userdetails.User) authentication.getPrincipal();

        String role = userDetails.getAuthorities().stream()
                .findFirst().get().getAuthority();  // "ROLE_ADMIN" 或 "ROLE_USER"

        // 注意：这里 userId 需要从数据库查，UserDetails 中没有存 userId
        // 实际项目中你可以自定义 UserDetails 包含 userId
        // 为简化起见，这里从 username 生成
        String accessToken = jwtUtil.createAccessToken(999L, userDetails.getUsername(), role);
        String refreshToken = jwtUtil.createRefreshToken(999L);

        return LoginResponse.builder()
                .accessToken(accessToken)
                .refreshToken(refreshToken)
                .tokenType("Bearer")
                .expiresIn(1800L)  // 30分钟
                .build();
    }

    /**
     * 刷新Token接口
     */
    @PostMapping("/refresh")
    public LoginResponse refresh(@Valid @RequestBody RefreshRequest request) {
        String refreshToken = request.getRefreshToken();

        // 1. 验证Refresh Token是否有效
        if (!jwtUtil.verify(refreshToken)) {
            throw new RuntimeException("Refresh Token无效或已过期");
        }

        // 2. 确认是Refresh Token（不是Access Token）
        if (!jwtUtil.isAccessToken(refreshToken)) {
            Long userId = jwtUtil.getUserId(refreshToken);
            String username = jwtUtil.getUsername(refreshToken);
            String role = jwtUtil.getRole(refreshToken);

            // 3. 生成新的 Access Token 和 Refresh Token
            String newAccessToken = jwtUtil.createAccessToken(userId, username, role);
            String newRefreshToken = jwtUtil.createRefreshToken(userId);

            return LoginResponse.builder()
                    .accessToken(newAccessToken)
                    .refreshToken(newRefreshToken)
                    .tokenType("Bearer")
                    .expiresIn(1800L)
                    .build();
        }

        throw new RuntimeException("请使用Refresh Token刷新");
    }
}
```

请求 / 响应 DTO：

```java
// 登录请求
@Data
public class LoginRequest {
    @NotBlank(message = "用户名不能为空")
    private String username;

    @NotBlank(message = "密码不能为空")
    private String password;
}

// 登录响应
@Data
@Builder
public class LoginResponse {
    private String accessToken;
    private String refreshToken;
    private String tokenType;    // "Bearer"
    private Long expiresIn;      // Access Token 过期时间（秒）
}

// 刷新Token请求
@Data
public class RefreshRequest {
    @NotBlank(message = "Refresh Token不能为空")
    private String refreshToken;
}
```

### 🧪 6.11 测试接口

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

---

## 📊 七、完整鉴权流程时序图

整合了上述所有组件，一个完整的请求鉴权流程如下：

```mermaid
sequenceDiagram
    participant C as 客户端
    participant JWT as JwtAuthFilter
    participant SEC as SecurityConfig<br/>(URL规则)
    participant AM as AuthManager
    participant UDS as UserDetailsService
    participant DB as 数据库
    participant API as Controller

    Note over C,API: ====== 登录流程 ======
    C->>API: POST /api/auth/login<br/>{username, password}
    API->>AM: authenticate(username, password)
    AM->>UDS: loadUserByUsername(username)
    UDS->>DB: SELECT * FROM t_user WHERE username=?
    DB-->>UDS: 用户数据
    UDS-->>AM: UserDetails(含加密密码)
    AM->>AM: PasswordEncoder.matches<br/>(输入的密码, 库中的密码)
    AM-->>API: 认证成功 → Authentication对象
    API->>API: 生成AccessToken + RefreshToken
    API-->>C: {accessToken, refreshToken}

    Note over C,API: ====== 带Token的业务请求 ======
    C->>JWT: GET /api/admin/dashboard<br/>Header: Bearer xxx.yyy.zzz
    JWT->>JWT: 提取Token → 验证签名 → 解析Payload
    JWT->>JWT: 构造Authentication对象<br/>(username, role)
    JWT->>JWT: SecurityContextHolder<br/>.setAuthentication(...)
    JWT->>SEC: 继续过滤器链

    SEC->>SEC: 检查URL规则<br/>/api/admin/** → hasRole(ADMIN)
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

## 🧪 八、实际测试

### 🚫 8.1 无 Token 访问受保护接口 → 401

```bash
# 请求
curl -X GET http://localhost:8080/api/user/info

# 响应
HTTP 401 Unauthorized
```

### 🔑 8.2 登录获取 Token

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

### ✅ 8.3 携带 Token 访问受保护接口 → 200

```bash
# 请求
curl -X GET http://localhost:8080/api/user/info \
  -H "Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9..."

# 响应
HTTP 200
"用户个人信息"
```

### 🚫 8.4 普通用户访问管理员接口 → 403

```bash
# 用 zhangsan(ROLE_USER) 的 Token 访问管理员接口
curl -X GET http://localhost:8080/api/admin/dashboard \
  -H "Authorization: Bearer {zhangsan的Token}"

# 响应
HTTP 403 Forbidden
```

### 🔄 8.5 Token 过期后刷新

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

## 🔧 九、企业生产环境补充配置

### 🚨 9.1 自定义认证失败和权限不足的响应

Spring Security 默认的 401 和 403 响应是 HTML 页面或很简略的文本，前后端分离项目中需要返回统一的 JSON 格式。

```java
@Configuration
@EnableWebSecurity
public class SecurityConfig {

    // ... 之前的配置 ...

    @Bean
    public SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        http
            // ... 之前的配置 ...

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

### 🌐 9.2 允许跨域（CORS）

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

    /**
     * 跨域配置
     */
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

### 🔐 9.3 密码加密工具（生成 BCrypt 密文）

开发时，可以使用 Hutool 的工具类或直接写一个 main 方法来生成 BCrypt 加密后的密码，用于插入测试数据。

```java
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;

public class PasswordGenerator {
    public static void main(String[] args) {
        BCryptPasswordEncoder encoder = new BCryptPasswordEncoder();
        // 每次生成的密文不同，但都能匹配"123456"
        String encoded = encoder.encode("123456");
        System.out.println(encoded);
        // 输出示例: $2a$10$N.zmdr9k7uOCQb376NoUnuTJ8iAt6Z5EHsM8lE9lBOsl7iKjxZf5e
    }
}
```

### 📄 9.4 忽略某些 URL（如 Swagger、静态资源）

```java
@Bean
public SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
    http
        .authorizeRequests()
        // Swagger UI 不需要认证
        .antMatchers("/swagger-ui/**", "/v3/api-docs/**").permitAll()
        // 静态资源
        .antMatchers("/static/**", "/public/**").permitAll()
        // ... 其他规则 ...;

    return http.build();
}

@Bean
public WebSecurityCustomizer webSecurityCustomizer() {
    // 完全忽略某些 URL（不经过过滤器链）
    return (web) -> web.ignoring()
        .antMatchers("/favicon.ico", "/error");
}
```

---

## 🔍 十、常见问题排查

| 问题现象 | 可能原因 | 解决方向 |
|------|------|------|
| 所有请求都返回 401 | JWT 过滤器没有正确设置 `SecurityContext` | 检查 `SecurityContextHolder.getContext().setAuthentication()` 是否执行 |
| `@Async` 方法中获取不到当前用户 | `SecurityContextHolder` 默认是线程绑定的 | 子线程需要手动传递 `SecurityContext` |
| 登录接口返回 403 或 401 | 登录接口需要 `.permitAll()`，或 CSRF 未关闭 | 在 `SecurityFilterChain` 中放行 `/api/auth/**` |
| Token 解析报错 | 密钥不一致、Token 格式错误 | 检查 `jwt.secret` 配置和生成时的密钥是否一致 |
| 角色校验不生效 | `hasRole("ADMIN")` 会自动加 `ROLE_` 前缀，库中存的是 `ROLE_ADMIN` | 使用 `hasRole("ADMIN")`（不加 ROLE_ 前缀），或用 `hasAuthority("ROLE_ADMIN")` |

---

## 🎯 十一、总结

本文从零开始搭建了一套完整的企业级 Spring Security + JWT 鉴权体系，核心要点回顾：

```mermaid
flowchart TD
    classDef startEnd fill:#F48FB1,stroke:#C2185B,stroke-width:2px,color:#212121,font-weight:bold;
    classDef process fill:#F5F5F5,stroke:#9E9E9E,stroke-width:1.5px,color:#212121;
    classDef highlight fill:#FFCCBC,stroke:#E64A19,stroke-width:1.5px,color:#D84315,font-weight:bold;
    classDef branch fill:#FFE082,stroke:#FFB300,stroke-width:2px,color:#5D4037,font-weight:bold;

    SUMMARY[(SpringSecurity<br/>+ JWT 鉴权体系)]
    SUMMARY --> P1[认证 Authentication]
    P1 --> P1A["登录时验证用户名密码<br/>成功 → 签发JWT"]
    P1 --> P1B["每次请求在Header中<br/>携带 Access Token"]

    SUMMARY --> P2[授权 Authorization]
    P2 --> P2A["基于角色 hasRole('ADMIN')<br/>或基于权限码 hasAuthority()"]

    SUMMARY --> P3[JWT 双令牌机制]
    P3 --> P3A["Access Token: 短期<br/>(15 ~ 30分钟)"]
    P3 --> P3B["Refresh Token: 长期<br/>(7天 ~ 30天)"]

    SUMMARY --> P4[7个核心组件]
    P4 --> P4A["JwtAuthFilter<br/>拦截请求, 解析JWT"]
    P4 --> P4B["SecurityFilterChain<br/>配置URL权限规则"]
    P4 --> P4C["UserDetailsService<br/>从DB加载用户"]
    P4 --> P4D["PasswordEncoder<br/>BCrypt密码加密"]
    P4 --> P4E["AuthenticationManager<br/>执行认证"]
    P4 --> P4F["SecurityContextHolder<br/>持有当前用户状态"]
    P4 --> P4G["JwtUtil<br/>生成/验证/解析JWT"]

    class SUMMARY startEnd;
    class P1,P2,P3,P4 branch;
    class P1A,P1B,P2A,P3A,P3B,P4A,P4B,P4C,P4D,P4E,P4F,P4G process;
```

**关键配置速查**：

| 配置项 | 代码 | 作用 |
|------|------|------|
| 关闭 Session | `.sessionManagement().sessionCreationPolicy(STATELESS)` | JWT 方案核心——不创建 Session |
| 关闭 CSRF | `.csrf().disable()` | 前后端分离不需要 CSRF |
| 公开接口 | `.antMatchers("/api/auth/**").permitAll()` | 登录和刷新接口不需要认证 |
| 角色限制 | `.antMatchers("/api/admin/**").hasRole("ADMIN")` | 管理员接口需要 ADMIN 角色 |
| 需认证 | `.anyRequest().authenticated()` | 其余接口需要登录 |
| 自定义过滤器 | `.addFilterBefore(jwtFilter, UsernamePasswordAuthenticationFilter.class)` | 将 JWT 过滤器插入过滤器链 |

**学习路径建议**：

1. 先照本文把完整代码跑起来，理解"每一行代码的作用"而不是"背后怎么实现"
2. 测试 401、403、200 三种响应，建立认证/授权的直观感受
3. 尝试修改角色（加一个 `ROLE_MANAGER`），看看怎么用 `hasRole` 控制
4. 工作中遇到 "这个接口只让 xx 角色访问"的需求时，回来查本文的配置即可
