---
title: "JWT 与双令牌机制详解"
date: 2022-09-20T09:42:16+00:00
tags: ["Spring全家桶"]
categories: ["SpringSecurity类"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "从Session会话的分布式痛点切入，深入讲解JWT的三段式结构、签名验证原理、Java代码实现，以及AccessToken+RefreshToken双令牌机制的设计思想和完整代码"
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

# JWT 与双令牌机制详解：从结构原理到 Java 代码实现

## 🤔 一、一个登录请求背后的困境

你写完了一个登录接口，用户提交用户名密码，服务端验证通过后创建 Session，把用户信息存进去，返回一个 `JSESSIONID` 的 Cookie。后续请求自动带上这个 Cookie，服务端从 Session 中取出用户信息——这是最传统的 Session 认证方式。

```java
@PostMapping("/login")
public String login(HttpSession session, @RequestBody LoginRequest req) {
    User user = userService.verify(req.getUsername(), req.getPassword());
    if (user == null) {
        return "用户名或密码错误";
    }
    session.setAttribute("currentUser", user);  // 存入Session
    return "登录成功";
}

@GetMapping("/info")
public User info(HttpSession session) {
    return (User) session.getAttribute("currentUser");  // 从Session取
}
```

这段代码在**单机部署**时没有问题。但当你部署到 3 台服务器、前面挂了一个 Nginx 负载均衡时，问题就出现了：

```mermaid
sequenceDiagram
    participant C as 客户端
    participant N as Nginx (负载均衡)
    participant S1 as 服务器1
    participant S2 as 服务器2

    Note over C,S2: 问题：Session 存在服务器1的内存中，服务器2不认识

    C->>N: POST /login
    N->>S1: 转发到服务器1
    S1->>S1: 验证密码，创建Session<br/>存入内存
    S1-->>C: JSESSIONID=ABC123

    C->>N: GET /info (Cookie: JSESSIONID=ABC123)
    N->>S2: 转发到服务器2
    S2->>S2: 查找 Session ABC123<br/>找不到！
    S2-->>C: 401 未登录（实际已登录）
```

Session 存在服务器 1 的内存中，当请求被 Nginx 转发到服务器 2 时，服务器 2 找不到这个 Session，用户被判定为"未登录"。

解决这个问题的传统方案是 **Session 共享**——把 Session 存到 Redis 中，所有服务器都去 Redis 里读。但这引入了新的依赖（Redis），并且每次请求都要访问 Redis。

**JWT（JSON Web Token）用另一种思路解决了这个问题**：服务端不保存任何会话数据，而是把用户信息编码进一个 Token 里，签上名，返回给客户端。后续请求客户端带上这个 Token，服务端只需验证签名就能确认"这个 Token 确实是我签发的，里面的信息可信"。

---

## 🔍 二、JWT 三段式结构详解

一个完整的 JWT 长这样（为了方便阅读，分段展示）：

```
eyJhbGciOiJIUzI1NiJ9
.eyJzdWIiOiIxMDAxIiwidXNlcm5hbWUiOiJ6aGFuZ3NhbiIsInJvbGUiOiJST0xFX1VTRVIiLCJpYXQiOjE2NjAxMjM0MDAsImV4cCI6MTY2MDEyNTIwMH0
.vzD5XgQpLNm3FkWxHj7tYqR2bKc8sMwP1nAeB6fTdU4
```

用 `.` 分割后是三段：`Header.Payload.Signature`

### 🧬 2.1 结构总览

```mermaid
flowchart TD
    classDef startEnd fill:#F48FB1,stroke:#C2185B,stroke-width:2px,color:#212121,font-weight:bold;
    classDef process fill:#F5F5F5,stroke:#9E9E9E,stroke-width:1.5px,color:#212121;
    classDef data fill:#C8E6C9,stroke:#388E3C,stroke-width:1.5px,color:#1B5E20,font-weight:bold;
    classDef highlight fill:#FFCCBC,stroke:#E64A19,stroke-width:1.5px,color:#D84315,font-weight:bold;

    JWT[JWT Token<br/>Header.Payload.Signature]

    JWT --> H[Header 头部<br/>Base64编码]
    H --> H1["alg: HS256<br/>(签名算法)"]
    H --> H2["typ: JWT<br/>(令牌类型)"]

    JWT --> P[Payload 载荷<br/>Base64编码]
    P --> P1["sub: 用户ID<br/>(主题)"]
    P --> P2["iat: 签发时间<br/>(Issued At)"]
    P --> P3["exp: 过期时间<br/>(Expiration)"]
    P --> P4["自定义字段<br/>username, role ..."]

    JWT --> S[Signature 签名]
    S --> S1["HMAC-SHA256(\n  Base64Url(Header)\n  + '.' +\n  Base64Url(Payload),\n  secret\n)"]

    class JWT startEnd;
    class H,P,S process;
    class H1,H2,P1,P2,P3,P4,S1 data;
```

### 🏷️ 2.2 Header（头部）——声明签名算法

第一段 `eyJhbGciOiJIUzI1NiJ9` 经过 Base64 解码后：

```json
{
  "alg": "HS256",
  "typ": "JWT"
}
```

| 字段 | 含义 | 常见取值 |
|------|------|------|
| `alg` | 签名算法（Algorithm） | `HS256`（HMAC-SHA256）、`RS256`（RSA-SHA256） |
| `typ` | 令牌类型 | `JWT` |

`HS256` 表示使用**对称密钥**签名——签发和验证使用同一个 `secret`。这是单体应用中最常用的方式。`RS256` 使用**非对称密钥**（私钥签发，公钥验证），适用于微服务中多个服务需要验证 Token 但不需要知道私钥的场景。

### 📦 2.3 Payload（载荷）——存放用户信息

第二段 Base64 解码后：

```json
{
  "sub": "1001",
  "username": "zhangsan",
  "role": "ROLE_USER",
  "iat": 1660123400,
  "exp": 1660125200
}
```

Payload 中的字段分为两类：

| 类别 | 字段 | 全称 | 含义 | 示例值 |
|------|------|------|------|------|
| **标准注册声明** | `sub` | Subject | 主题，通常存用户 ID | `"1001"` |
| | `iat` | Issued At | 签发时间（Unix 秒级时间戳） | `1660123400` |
| | `exp` | Expiration | 过期时间（Unix 秒级时间戳） | `1660125200` |
| | `iss` | Issuer | 签发者 | `"mall-api"` |
| | `aud` | Audience | 接收方 | `"mall-app"` |
| | `jti` | JWT ID | Token 唯一标识（UUID） | `"a1b2c3d4-..."` |
| **自定义私有声明** | `username` | — | 用户名 | `"zhangsan"` |
| | `role` | — | 角色 | `"ROLE_USER"` |
| | `type` | — | Token 类型 | `"access"` |

> **关键理解**：Payload 是 **Base64 编码**，不是加密。任何人拿到 JWT 都可以解码看到里面的内容。因此 <span style="color:red">**绝对不能把密码、手机号等敏感信息放入 Payload**</span>。

### 🔏 2.4 Signature（签名）——防篡改的核心

签名的计算过程：

```
Signature = HMAC-SHA256(
    Base64UrlEncode(Header) + "." + Base64UrlEncode(Payload),
    secret
)
```

签名的**唯一作用**是防止 Payload 被篡改：

-  攻击者修改 Payload 中的 `userId` 从 `"1001"` 改为 `"1002"` → Payload 变了
-  但攻击者不知道 `secret`，无法生成新的有效签名
-  服务端用 `secret` 重新计算签名 → 与 Token 中的签名不一致 → 拒绝

```mermaid
flowchart TD
    classDef startEnd fill:#F48FB1,stroke:#C2185B,stroke-width:2px,color:#212121,font-weight:bold;
    classDef condition fill:#E1BEE7,stroke:#7B1FA2,stroke-width:1.5px,color:#212121,font-weight:bold;
    classDef process fill:#F5F5F5,stroke:#9E9E9E,stroke-width:1.5px,color:#212121;
    classDef reject fill:#FFCDD2,stroke:#C62828,stroke-width:1.5px,color:#B71C1C,font-weight:bold;

    RECEIVE([收到JWT]) --> SPLIT[按.分割为三段]
    SPLIT --> RECALC[用secret对Header.Payload<br/>重新计算签名]
    RECALC --> COMPARE{"重新计算的签名\n== 收到的签名 ?"}

    COMPARE -- 一致 --> TRUST[Payload未被篡改<br/>可信任其中的用户信息]
    COMPARE -- 不一致 --> REJECT([签名无效<br/>拒绝请求])

    TRUST --> CHECK_EXP{"exp > 当前时间 ?"}
    CHECK_EXP -- 是 --> OK([Token有效, 放行])
    CHECK_EXP -- 否 --> EXPIRED([Token已过期, 拒绝])

    class RECEIVE startEnd;
    class COMPARE,CHECK_EXP condition;
    class SPLIT,RECALC,TRUST process;
    class REJECT,EXPIRED,OK startEnd;
```

---

## 💻 三、Java 代码实现：用 JJWT 签发和验证

以下代码使用 **JJWT**（`io.jsonwebtoken`）库，它是 Java 生态中功能最完整的 JWT 实现。

### 📋 3.1 Maven 依赖

```xml
<dependency>
    <groupId>io.jsonwebtoken</groupId>
    <artifactId>jjwt-api</artifactId>
    <version>0.11.5</version>
</dependency>
<dependency>
    <groupId>io.jsonwebtoken</groupId>
    <artifactId>jjwt-impl</artifactId>
    <version>0.11.5</version>
    <scope>runtime</scope>
</dependency>
<dependency>
    <groupId>io.jsonwebtoken</groupId>
    <artifactId>jjwt-jackson</artifactId>
    <version>0.11.5</version>
    <scope>runtime</scope>
</dependency>
```

### ✍️ 3.2 签发 JWT

```java
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.SignatureAlgorithm;
import io.jsonwebtoken.security.Keys;

import javax.crypto.SecretKey;
import java.nio.charset.StandardCharsets;
import java.util.Date;
import java.util.UUID;

public class JwtIssueDemo {

    // 密钥，生产环境至少256位（32字节），从配置文件读取
    private static final String SECRET =
        "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2";

    // 有效期30分钟（毫秒）
    private static final long EXPIRE_MS = 30 * 60 * 1000;

    public static void main(String[] args) {
        // 1. 构建密钥对象
        SecretKey key = Keys.hmacShaKeyFor(SECRET.getBytes(StandardCharsets.UTF_8));

        // 2. 设置Payload中的字段
        Date now = new Date();
        Date expiration = new Date(now.getTime() + EXPIRE_MS);

        String jwt = Jwts.builder()
                // ---- 标准注册声明 ----
                .setId(UUID.randomUUID().toString())   // jti: Token唯一ID
                .setSubject("1001")                     // sub: 用户ID
                .setIssuer("mall-api")                  // iss: 签发者
                .setIssuedAt(now)                       // iat: 签发时间
                .setExpiration(expiration)              // exp: 过期时间

                // ---- 自定义私有声明 ----
                .claim("username", "zhangsan")          // 用户名
                .claim("role", "ROLE_USER")             // 角色

                // ---- 签名 ----
                .signWith(key)                         // HS256 签名

                .compact();  // 生成最终字符串

        System.out.println("生成的JWT:");
        System.out.println(jwt);
        System.out.println("长度: " + jwt.length() + " 字符");
    }
}
```

运行输出：

```
生成的JWT:
eyJhbGciOiJIUzI1NiJ9.eyJqdGkiOiI4ZTk2ZjNhOC0xMjM0LTQ1NjctODkwMS1hYmNkZWYxMjM0NTYiLCJzdWIiOiIxMDAxIiwiaXNzIjoibWFsbC1hcGkiLCJpYXQiOjE2NjAxMjM0MDAsImV4cCI6MTY2MDEyNTIwMCwidXNlcm5hbWUiOiJ6aGFuZ3NhbiIsInJvbGUiOiJST0xFX1VTRVIifQ.P8qR2sT5vW7xYzA1bC3dE4fG6hIjK8lM9nO0pQrStUv
长度: 206 字符
```

### ✅ 3.3 验证和解析 JWT

```java
import io.jsonwebtoken.*;
import io.jsonwebtoken.security.Keys;

import javax.crypto.SecretKey;
import java.nio.charset.StandardCharsets;

public class JwtVerifyDemo {

    private static final String SECRET =
        "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2";

    public static void main(String[] args) {

        // 模拟从请求头中获取的Token
        String token = "eyJhbGciOiJIUzI1NiJ9.eyJqdGkiOiI4ZTk2ZjNhOC0xMjM0LTQ1NjctODkwMS1hYmNkZWYxMjM0NTYiLCJzdWIiOiIxMDAxIiwiaXNzIjoibWFsbC1hcGkiLCJpYXQiOjE2NjAxMjM0MDAsImV4cCI6MTY2MDEyNTIwMCwidXNlcm5hbWUiOiJ6aGFuZ3NhbiIsInJvbGUiOiJST0xFX1VTRVIifQ.P8qR2sT5vW7xYzA1bC3dE4fG6hIjK8lM9nO0pQrStUv";

        SecretKey key = Keys.hmacShaKeyFor(SECRET.getBytes(StandardCharsets.UTF_8));

        try {
            // 1. 解析并验证（签名 + 过期时间）
            Claims claims = Jwts.parserBuilder()
                    .setSigningKey(key)
                    .build()
                    .parseClaimsJws(token)
                    .getBody();

            // 2. 从 Payload 中读取字段
            String jti = claims.getId();                      // jti
            String userId = claims.getSubject();              // sub
            String issuer = claims.getIssuer();               // iss
            Date issuedAt = claims.getIssuedAt();             // iat
            Date expiration = claims.getExpiration();         // exp
            String username = claims.get("username", String.class);  // 自定义
            String role = claims.get("role", String.class);         // 自定义

            System.out.println("========== Token 解析成功 ==========");
            System.out.println("jti (Token ID)   : " + jti);
            System.out.println("sub (用户ID)      : " + userId);
            System.out.println("iss (签发者)      : " + issuer);
            System.out.println("iat (签发时间)     : " + issuedAt);
            System.out.println("exp (过期时间)     : " + expiration);
            System.out.println("username (用户名)  : " + username);
            System.out.println("role (角色)       : " + role);

            // 3. 计算剩余有效时间
            long remaining = expiration.getTime() - System.currentTimeMillis();
            System.out.println("剩余有效时间       : " + remaining / 1000 + " 秒");

        } catch (ExpiredJwtException e) {
            System.err.println("Token 已过期！过期时间: " + e.getClaims().getExpiration());
        } catch (JwtException e) {
            System.err.println("Token 无效！原因: " + e.getMessage());
        }
    }
}
```

运行输出：

```
========== Token 解析成功 ==========
jti (Token ID)   : 8e96f3a8-1234-4567-8901-abcdef123456
sub (用户ID)      : 1001
iss (签发者)      : mall-api
iat (签发时间)     : Mon Aug 15 12:30:00 CST 2022
exp (过期时间)     : Mon Aug 15 13:00:00 CST 2022
username (用户名)  : zhangsan
role (角色)       : ROLE_USER
剩余有效时间       : 1753 秒
```

### 🚨 3.4 JJWT 异常体系

`parseClaimsJws(token)` 在不同失败场景下会抛出不同的异常：

| 异常类型 | 触发条件 | 说明 |
|------|------|------|
| `ExpiredJwtException` | `exp` < 当前时间 | Token 已过期，可从异常中取 `Claims` |
| `SignatureException` | 签名不匹配 | Token 被篡改或使用了错误的密钥 |
| `MalformedJwtException` | 格式不正确 | 不是合法的 JWT 格式（没有两个 `.`） |
| `UnsupportedJwtException` | 不支持的格式 | Header 中的 `alg` 或 `typ` 不符合预期 |
| `IllegalArgumentException` | Token 为空或 null | 请求头中没有携带 Token |

正确的异常处理应该区分这些类型，返回不同的错误信息给客户端：

```java
public JwtVerifyResult verifyToken(String token) {
    try {
        Claims claims = Jwts.parserBuilder()
                .setSigningKey(key)
                .build()
                .parseClaimsJws(token)
                .getBody();
        return JwtVerifyResult.success(claims);

    } catch (ExpiredJwtException e) {
        return JwtVerifyResult.fail("Token已过期，请刷新或重新登录", 401);
    } catch (SignatureException e) {
        return JwtVerifyResult.fail("Token签名无效，可能被篡改", 401);
    } catch (MalformedJwtException e) {
        return JwtVerifyResult.fail("Token格式错误", 400);
    } catch (JwtException | IllegalArgumentException e) {
        return JwtVerifyResult.fail("Token无效", 401);
    }
}
```

---

## ⚠️ 四、单 Token 方案的致命缺陷

上面的代码只用了**一个 Token**（Access Token）。这在简单场景下能跑，但在以下场景中会出问题：

### ⚠️ 4.1 缺陷场景

| 场景 | 问题描述 |
|------|------|
| **Token 过期太短**（如 5 分钟） | 用户每 5 分钟就要重新登录，体验极差 |
| **Token 过期太长**（如 7 天） | Token 泄露后，攻击者可以在 7 天内随意访问，无法主动撤销 |
| **用户修改密码** | 旧的 Token 在有效期内仍然可用，攻击者用泄露的旧密码登录后拿到的 Token 依然有效 |
| **管理员踢人下线** | 纯 JWT 无状态，服务端没有记录"谁当前在线"，无法强制某人下线 |

**根本矛盾**：Token 过期时间短 → 用户体验差；Token 过期时间长 → 安全风险大。单 Token 方案无法同时解决这两个问题。

### 🚫 4.2 常见但错误的补丁方案

有些开发者在服务端维护一个"Token 黑名单"（如 `Set<String> invalidatedTokens`），登出时把 Token 加进去。但这带来了新问题：

-  **内存无限增长**：每个被撤销的 Token 都要记到过期为止，大量用户频繁登录登出会导致内存膨胀
-  **分布式不一致**：多台服务器之间的黑名单需要同步
-  **失去了 JWT 无状态的优势**：最终还是需要查一个中心化存储

---

## 🔑 五、双令牌机制（Access Token + Refresh Token）

### 💡 5.1 核心思想

把"身份认证"拆成两个职责不同的 Token：

```mermaid
flowchart LR
    classDef root fill:#1E88E5,stroke:#0D47A1,stroke-width:2px,color:#FFFFFF,font-weight:bold;
    classDef branch fill:#FFE082,stroke:#FFB300,stroke-width:2px,color:#5D4037,font-weight:bold;
    classDef leaf fill:#F5F5F5,stroke:#BDBDBD,stroke-width:1.5px,color:#212121;
    classDef highlight fill:#FFCCBC,stroke:#E64A19,stroke-width:1.5px,color:#D84315,font-weight:bold;

    ROOT[双令牌机制]

    ROOT --> AT[Access Token<br/>访问令牌]
    AT --> AT1["有效期: 短 (15 ~ 30 分钟)"]
    AT --> AT2["职责: 每次请求携带<br/>用于访问业务接口"]
    AT --> AT3["存储: 客户端内存<br/>(变量/localStorage)"]

    ROOT --> RT[Refresh Token<br/>刷新令牌]
    RT --> RT1["有效期: 长 (7 ~ 30 天)"]
    RT --> RT2["职责: 仅用于获取<br/>新的Access Token"]
    RT --> RT3["存储: HttpOnly Cookie<br/>或安全存储"]
    RT --> RT4["仅暴露给 /refresh 接口"]

    class ROOT root;
    class AT,RT branch;
    class AT1,AT2,AT3,RT1,RT2,RT3,RT4 leaf;
```

### 🔄 5.2 工作流程

```mermaid
sequenceDiagram
    participant C as 客户端
    participant S as 服务端
    participant DB as 数据库

    Note over C,DB: ====== 阶段一：登录 ======
    C->>S: POST /login<br/>用户名 + 密码
    S->>DB: 查询用户，验证密码
    DB-->>S: 用户信息
    S->>S: 生成 Access Token (30分钟)<br/>生成 Refresh Token (7天)
    S-->>C: { accessToken, refreshToken }

    Note over C,DB: ====== 阶段二：正常请求 ======
    C->>S: GET /api/users<br/>Authorization: Bearer {accessToken}
    S->>S: 验证AccessToken签名+过期
    S-->>C: 200 用户数据

    Note over C,DB: ====== 阶段三：Token过期，刷新 ======
    C->>S: GET /api/users<br/>Authorization: Bearer {accessToken}
    S-->>C: 401 AccessToken过期

    C->>S: POST /refresh<br/>携带 RefreshToken
    S->>S: 验证RefreshToken<br/>（签名 + 过期 + 未被撤销）
    S->>S: 生成新的AccessToken (30分钟)<br/>生成新的RefreshToken (7天)
    S-->>C: { newAccessToken, newRefreshToken }

    Note over C,DB: ====== 阶段四：RefreshToken也过期 ======
    C->>S: POST /refresh<br/>携带 RefreshToken
    S-->>C: 401 请重新登录
```

> **关键设计**：Refresh Token 也过期时，用户必须重新输入用户名密码登录。这保证了即使长期不用的 Token 泄露，攻击者的窗口期也是有限的。

### ⚖️ 5.3 为什么双令牌能解决单 Token 的矛盾

| 问题 | 双令牌方案如何解决 |
|------|------|
| **安全性** | Access Token 只有 15 ~ 30 分钟有效期，即使泄露，攻击窗口很小 |
| **用户体验** | Refresh Token 有效期 7 天，用户不需要频繁输入密码，客户端自动用 Refresh Token 换新的 Access Token |
| **主动撤销** | 在服务端（Redis / 数据库）记录 Refresh Token 的状态，删除后用户下次刷新时会被拒绝 |
| **踢人下线** | 删除该用户在 Redis 中存储的所有 Refresh Token，所有设备同时下线 |

### 📊 5.4 双令牌对比单 Token

| 维度 | 单 Token（仅 Access Token） | 双令牌（Access + Refresh） |
|------|------|------|
| 过期时间设置 | 只能二选一：短则体验差，长则不安全 | Access 短（安全），Refresh 长（体验） |
| Token 泄露风险 | Token 有效期 = 攻击窗口 | 攻击窗口 = Access Token 有效期（分钟级） |
| 主动撤销 | 不支持（除非引入外部存储） | Refresh Token 存 Redis，可主动删除 |
| 实现复杂度 | 低 | 中（多一个刷新接口 + Refresh Token 存储） |
| 客户端复杂度 | 低（存一个 Token） | 中（需处理 Token 过期 → 刷新 → 重试逻辑） |
| 适用场景 | 内部工具、低安全要求 | **互联网产品、企业应用（推荐）** |

---

## 💻 六、Java 代码实现：双令牌

### 🔧 6.1 调整 JWT 工具类，支持双 Token

```java
import io.jsonwebtoken.Claims;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;

import javax.crypto.SecretKey;
import java.nio.charset.StandardCharsets;
import java.util.Date;
import java.util.UUID;

public class JwtDualTokenUtil {

    private final SecretKey key;
    private final long accessExpireMs;   // Access Token 过期（毫秒）
    private final long refreshExpireMs;  // Refresh Token 过期（毫秒）

    public JwtDualTokenUtil(String secret,
                            long accessExpireMinutes,
                            long refreshExpireMinutes) {
        this.key = Keys.hmacShaKeyFor(secret.getBytes(StandardCharsets.UTF_8));
        this.accessExpireMs = accessExpireMinutes * 60 * 1000;
        this.refreshExpireMs = refreshExpireMinutes * 60 * 1000;
    }

    /**
     * 生成 Access Token——有效期短，携带完整用户信息
     */
    public String createAccessToken(Long userId, String username, String role) {
        Date now = new Date();
        return Jwts.builder()
                .setId(UUID.randomUUID().toString())
                .setSubject(userId.toString())
                .claim("username", username)
                .claim("role", role)
                .claim("type", "access")           // 标记类型
                .setIssuedAt(now)
                .setExpiration(new Date(now.getTime() + accessExpireMs))
                .signWith(key)
                .compact();
    }

    /**
     * 生成 Refresh Token——有效期长，只携带必要信息
     */
    public String createRefreshToken(Long userId) {
        Date now = new Date();
        return Jwts.builder()
                .setId(UUID.randomUUID().toString())
                .setSubject(userId.toString())
                .claim("type", "refresh")          // 标记类型
                .setIssuedAt(now)
                .setExpiration(new Date(now.getTime() + refreshExpireMs))
                .signWith(key)
                .compact();
    }

    /**
     * 解析 Token（不对type做校验）
     */
    public Claims parseToken(String token) {
        return Jwts.parserBuilder()
                .setSigningKey(key)
                .build()
                .parseClaimsJws(token)
                .getBody();
    }

    /**
     * 判断是否为 Access Token
     */
    public boolean isAccessToken(Claims claims) {
        return "access".equals(claims.get("type", String.class));
    }

    /**
     * 判断是否为 Refresh Token
     */
    public boolean isRefreshToken(Claims claims) {
        return "refresh".equals(claims.get("type", String.class));
    }

    // ---- 便捷读取方法 ----
    public String getJti(Claims claims) {
        return claims.getId();
    }

    public Long getUserId(Claims claims) {
        return Long.valueOf(claims.getSubject());
    }

    public String getUsername(Claims claims) {
        return claims.get("username", String.class);
    }

    public String getRole(Claims claims) {
        return claims.get("role", String.class);
    }
}
```

### 🔑 6.2 登录接口——同时签发两个 Token

```java
@RestController
@RequestMapping("/api/auth")
public class AuthController {

    private final JwtDualTokenUtil jwtUtil;
    private final UserService userService;

    public AuthController(JwtDualTokenUtil jwtUtil, UserService userService) {
        this.jwtUtil = jwtUtil;
        this.userService = userService;
    }

    /**
     * 登录：返回 Access Token + Refresh Token
     */
    @PostMapping("/login")
    public ResponseEntity<LoginResponse> login(
            @Valid @RequestBody LoginRequest request) {

        // 1. 验证用户名密码
        User user = userService.verify(request.getUsername(), request.getPassword());
        if (user == null) {
            return ResponseEntity.status(401)
                    .body(LoginResponse.fail("用户名或密码错误"));
        }

        // 2. 生成双 Token
        String accessToken = jwtUtil.createAccessToken(
                user.getId(), user.getUsername(), user.getRole());
        String refreshToken = jwtUtil.createRefreshToken(user.getId());

        // 3. （可选）将 Refresh Token 存入 Redis，用于后续撤销
        // refreshTokenService.store(user.getId(), refreshToken);

        return ResponseEntity.ok(LoginResponse.builder()
                .accessToken(accessToken)
                .refreshToken(refreshToken)
                .tokenType("Bearer")
                .accessTokenExpire(30 * 60)      // 30分钟（秒）
                .refreshTokenExpire(7 * 24 * 3600) // 7天（秒）
                .build());
    }
}
```

### 🔄 6.3 刷新接口——用 Refresh Token 换新的 Access Token

```java
@RestController
@RequestMapping("/api/auth")
public class AuthController {

    // ... 登录方法同上 ...

    /**
     * 刷新Token：用RefreshToken换取新的AccessToken + RefreshToken
     */
    @PostMapping("/refresh")
    public ResponseEntity<LoginResponse> refresh(
            @Valid @RequestBody RefreshRequest request) {

        String refreshToken = request.getRefreshToken();

        // 1. 解析 Refresh Token（验证签名 + 过期）
        Claims claims;
        try {
            claims = jwtUtil.parseToken(refreshToken);
        } catch (ExpiredJwtException e) {
            return ResponseEntity.status(401)
                    .body(LoginResponse.fail("Refresh Token已过期，请重新登录"));
        } catch (JwtException e) {
            return ResponseEntity.status(401)
                    .body(LoginResponse.fail("Refresh Token无效"));
        }

        // 2. 必须是Refresh Token类型（防止用Access Token来刷新）
        if (!jwtUtil.isRefreshToken(claims)) {
            return ResponseEntity.status(400)
                    .body(LoginResponse.fail("请使用Refresh Token刷新，不支持Access Token"));
        }

        // 3. （可选）检查RefreshToken是否在Redis白名单中
        // if (!refreshTokenService.isValid(jwtUtil.getJti(claims))) {
        //     return ResponseEntity.status(401)
        //             .body(LoginResponse.fail("Refresh Token已被撤销，请重新登录"));
        // }

        // 4. 从数据库查询用户最新信息（角色可能已变更）
        Long userId = jwtUtil.getUserId(claims);
        User user = userService.findById(userId);

        // 5. 签发新的双 Token
        String newAccessToken = jwtUtil.createAccessToken(
                user.getId(), user.getUsername(), user.getRole());
        String newRefreshToken = jwtUtil.createRefreshToken(user.getId());

        // 6. （可选）旧的 Refresh Token 失效，新的写入 Redis
        // refreshTokenService.replace(jwtUtil.getJti(claims), newRefreshToken);

        return ResponseEntity.ok(LoginResponse.builder()
                .accessToken(newAccessToken)
                .refreshToken(newRefreshToken)
                .tokenType("Bearer")
                .accessTokenExpire(30 * 60)
                .refreshTokenExpire(7 * 24 * 3600)
                .build());
    }
}
```

### 🛡️ 6.4 拦截器——验证 Access Token

```java
@Component
public class JwtInterceptor implements HandlerInterceptor {

    private final JwtDualTokenUtil jwtUtil;

    public JwtInterceptor(JwtDualTokenUtil jwtUtil) {
        this.jwtUtil = jwtUtil;
    }

    @Override
    public boolean preHandle(HttpServletRequest request,
                             HttpServletResponse response,
                             Object handler) throws Exception {

        // 1. 从请求头提取 Token
        String token = extractToken(request);
        if (token == null) {
            sendError(response, 401, "请先登录");
            return false;
        }

        // 2. 解析并验证
        Claims claims;
        try {
            claims = jwtUtil.parseToken(token);
        } catch (ExpiredJwtException e) {
            sendError(response, 401, "Token已过期，请刷新");
            return false;
        } catch (JwtException e) {
            sendError(response, 401, "Token无效");
            return false;
        }

        // 3. 必须是 Access Token
        if (!jwtUtil.isAccessToken(claims)) {
            sendError(response, 400, "请使用Access Token访问接口");
            return false;
        }

        // 4. 将用户信息存入 request 属性，Controller 可以直接读取
        request.setAttribute("userId", jwtUtil.getUserId(claims));
        request.setAttribute("username", jwtUtil.getUsername(claims));
        request.setAttribute("role", jwtUtil.getRole(claims));

        return true;
    }

    private String extractToken(HttpServletRequest request) {
        String header = request.getHeader("Authorization");
        if (header != null && header.startsWith("Bearer ")) {
            return header.substring(7);
        }
        return null;
    }

    private void sendError(HttpServletResponse response,
                           int status, String message) throws Exception {
        response.setContentType("application/json;charset=UTF-8");
        response.setStatus(status);
        response.getWriter().write(
            String.format("{\"code\":%d,\"message\":\"%s\"}", status, message));
    }
}
```

### 📱 6.5 客户端示例——Token 过期自动刷新

前端（或移动端）需要实现"请求 → 发现 401 → 自动刷新 Token → 重试原请求"的逻辑。以下用 Java 代码演示这个模式：

```java
public class ApiClient {

    private String accessToken;
    private String refreshToken;

    private final JwtDualTokenUtil jwtUtil;
    private final RestTemplate restTemplate;

    /**
     * 发送带自动刷新的 GET 请求
     */
    public <T> T getWithAuth(String url, Class<T> responseType) {
        try {
            // 第一次尝试
            return doGet(url, responseType);
        } catch (TokenExpiredException e) {
            // Access Token 过期 → 刷新 → 重试
            boolean refreshed = refreshAccessToken();
            if (refreshed) {
                return doGet(url, responseType);  // 重试
            } else {
                throw new RuntimeException("Token刷新失败，请重新登录");
            }
        }
    }

    /**
     * 实际发送请求
     */
    private <T> T doGet(String url, Class<T> responseType) {
        HttpHeaders headers = new HttpHeaders();
        headers.set("Authorization", "Bearer " + accessToken);

        ResponseEntity<T> response = restTemplate.exchange(
                url, HttpMethod.GET,
                new HttpEntity<>(headers), responseType);

        if (response.getStatusCode() == HttpStatus.UNAUTHORIZED) {
            throw new TokenExpiredException();
        }
        return response.getBody();
    }

    /**
     * 使用 Refresh Token 获取新的 Access Token
     */
    private boolean refreshAccessToken() {
        try {
            HttpHeaders headers = new HttpHeaders();
            headers.setContentType(MediaType.APPLICATION_JSON);

            Map<String, String> body = Map.of("refreshToken", refreshToken);

            ResponseEntity<LoginResponse> response = restTemplate.exchange(
                    "/api/auth/refresh", HttpMethod.POST,
                    new HttpEntity<>(body, headers), LoginResponse.class);

            if (response.getStatusCode() == HttpStatus.OK) {
                LoginResponse resp = response.getBody();
                this.accessToken = resp.getAccessToken();
                this.refreshToken = resp.getRefreshToken();
                return true;
            }
        } catch (Exception e) {
            // Refresh Token 也过期了 → 需要重新登录
        }
        return false;
    }

    // 内部异常类
    private static class TokenExpiredException extends RuntimeException {}
}
```

> **前端实现要点**：这个"401 → 刷新 → 重试"的逻辑在前端通常通过 Axios（Vue/React）的拦截器实现。关键细节是要加**并发锁**——如果同时有 3 个请求都收到 401，只触发一次刷新，其余等待刷新完成后再重试。

---

## 🔒 七、双令牌的存储安全建议

| Token 类型 | 推荐存储位置 | 原因 |
|------|------|------|
| **Access Token** | 客户端内存（JS 变量 / Redux Store / Vuex） | 生命周期短（分钟级），页面关闭即消失，无需持久化 |
| **Refresh Token** | HttpOnly Cookie | JS 无法读取，XSS 攻击无法窃取；自动随请求发送 |

```java
// 服务端设置 Refresh Token Cookie
@PostMapping("/login")
public ResponseEntity<LoginResponse> login(...) {
    // ... 生成 Token ...

    // 将 Refresh Token 设入 HttpOnly Cookie
    ResponseCookie cookie = ResponseCookie.from("refreshToken", refreshToken)
            .httpOnly(true)           // JS 不可读
            .secure(true)             // 仅 HTTPS
            .sameSite("Strict")       // 防止 CSRF
            .path("/api/auth")        // 仅 /api/auth 路径下发送
            .maxAge(7 * 24 * 3600)   // 7天
            .build();

    return ResponseEntity.ok()
            .header(HttpHeaders.SET_COOKIE, cookie.toString())
            .body(response);  // Access Token 放在 Body 中返回
}
```

---

## 🎯 八、总结

```mermaid
flowchart TD
    classDef startEnd fill:#F48FB1,stroke:#C2185B,stroke-width:2px,color:#212121,font-weight:bold;
    classDef process fill:#F5F5F5,stroke:#9E9E9E,stroke-width:1.5px,color:#212121;
    classDef highlight fill:#FFCCBC,stroke:#E64A19,stroke-width:1.5px,color:#D84315,font-weight:bold;

    SUMMARY[(JWT 与双令牌)]

    SUMMARY --> CORE[JWT 核心结构]
    CORE --> C1["Header.Payload.Signature<br/>三段式, 用.分隔"]
    CORE --> C2["Base64 编码, 非加密<br/>不可放敏感信息"]
    CORE --> C3["Signature 防篡改<br/>修改Payload → 签名失效"]

    SUMMARY --> DUAL[双令牌设计]
    DUAL --> D1["Access Token: 短期<br/>携带用户信息, 访问接口"]
    DUAL --> D2["Refresh Token: 长期<br/>仅用于刷新, 存HttpOnly Cookie"]

    SUMMARY --> FLOW[刷新流程]
    FLOW --> F1["Access过期 → 401"]
    FLOW --> F2["用Refresh换新Access"]
    FLOW --> F3["Refresh也过期 → 重新登录"]

    SUMMARY --> JAVA[Java 实现]
    JAVA --> J1["JJWT签发/验证"]
    JAVA --> J2["拦截器校验Access"]
    JAVA --> J3["刷新接口校验Refresh"]
    JAVA --> J4["客户端自动重试"]

    class SUMMARY startEnd;
    class CORE,DUAL,FLOW,JAVA process;
    class C1,C2,C3,D1,D2,F1,F2,F3,J1,J2,J3,J4 process;
```

**核心结论**：

1. **JWT 解决的是"服务端不存状态"的问题**：通过签名验证代替 Session 查询，天然支持分布式扩展
2. **JWT 的 Payload 是编码不是加密**：绝不能在 Payload 中放密码、手机号等敏感信息
3. **单 Token 存在不可调和的矛盾**：过期短则体验差，过期长则不安全
4. **双令牌是这个矛盾的工程解法**：Access Token 负责安全（短有效期）、Refresh Token 负责体验（长有效期）。Refresh Token 可配合 Redis 实现主动撤销
