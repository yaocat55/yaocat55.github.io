---
title: "JWT + Redis 双令牌鉴权实战"
date: 2022-09-19T08:42:45+00:00
tags: ["安全认证", "实践教程", "SpringBoot"]
categories: ["SpringSecurity类"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "深入对比纯JWT、纯Redis+Token、JWT+Redis混合三种鉴权方案，给出基于JJWT+Redis+SpringSecurity的完整生产级实现，解决Token主动失效这一核心痛点"
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

# JWT + Redis 双令牌鉴权实战：生产环境下的 Token 主动失效与过期管理方案

## 🔥 一、一个真实的生产事故

先看一段在中小项目中常见的鉴权代码：

```java
// 登录：生成JWT，返回给客户端
public String login(String username, String password) {
    User user = userService.verify(username, password);
    return Jwts.builder()
        .setSubject(user.getId().toString())
        .setExpiration(new Date(System.currentTimeMillis() + 30 * 60 * 1000))
        .signWith(SECRET_KEY)
        .compact();
}

// 拦截器：验证JWT签名和过期时间
public boolean preHandle(HttpServletRequest request, ...) {
    String token = request.getHeader("Authorization");
    Claims claims = Jwts.parserBuilder()
        .setSigningKey(SECRET_KEY).build()
        .parseClaimsJws(token).getBody();
    // Token签名正确且未过期 → 放行
    return true;
}
```

这段代码能跑吗？能。有安全隐患吗？有，而且很严重。

**场景一：用户修改密码后，旧的 Token 仍然有效。**

用户张三的密码泄露了，他修改了密码。但之前签发的 JWT 还在 30 分钟有效期内，攻击者拿着旧 Token 继续访问系统——因为服务端只检查了签名和过期时间，**完全没有能力让一个已签发的 Token 提前失效**。

**场景二：管理员踢人下线无法实现。**

运营人员发现某个账号异常，需要立即强制该用户下线。但 JWT 是无状态的，服务端没有记录"谁当前在线"，无法实现强制登出。

**场景三：用户登出后，Token 依然可用。**

用户点击了"退出登录"，前端删除了 Token。但如果这个 Token 已经被攻击者截获（比如通过日志泄露），攻击者在 Token 过期前仍然可以使用。

这三个场景指向同一个问题：<span style="color:red">**纯 JWT 方案缺少服务端主动控制 Token 生命周期的能力**</span>。

---

## 📊 二、三种鉴权方案全景对比

在给出解决方案之前，先把业界的三种主流方案放在一起对比，理解各自的优势和短板。

### 🔓 2.1 方案一：纯 JWT（无状态方案）

```mermaid
sequenceDiagram
    participant C as 客户端
    participant S as 服务端
    participant JWT as JWT签名算法

    Note over C,S: 登录
    C->>S: 用户名+密码
    S->>JWT: 签名生成Token
    S-->>C: JWT (有效期30分钟)

    Note over C,S: 后续请求
    C->>S: 请求 + JWT
    S->>S: 仅验证签名+过期时间
    S-->>C: 响应

    Note over C,S: 登出
    C->>C: 删除本地Token
    Note over S: ⚠️ 服务端无感知<br/>Token仍然有效直到过期
```

| 维度 | 评价 | 说明 |
|------|:---:|------|
| **性能** | 优秀 | 无IO操作，纯CPU签名验证（微秒级） |
| **水平扩展** | 优秀 | 无状态，任意服务器都能验证 |
| **主动失效** | <span style="color:red">不支持</span> | Token签发后无法撤销，只能等过期 |
| **强制下线** | <span style="color:red">不支持</span> | 无法实现"踢人下线" |
| **在线用户管理** | <span style="color:red">不支持</span> | 不知道谁在线、几台设备登录 |
| **Token泄露应对** | <span style="color:red">无法应对</span> | 只能等Token自动过期 |

### 🗄️ 2.2 方案二：纯 Redis + Token（有状态方案）

每次请求都查 Redis，用一个随机字符串（UUID）作为 Token，Redis 中存储 `token → userInfo`。

```mermaid
sequenceDiagram
    participant C as 客户端
    participant S as 服务端
    participant R as Redis

    Note over C,R: 登录
    C->>S: 用户名+密码
    S->>S: 生成UUID作为Token
    S->>R: SET token:{uuid} → {userId, username, role}<br/>EXPIRE 1800 (30分钟)
    S-->>C: Token (UUID)

    Note over C,R: 后续请求
    C->>S: 请求 + Token
    S->>R: GET token:{uuid}
    alt Redis命中
        S->>R: EXPIRE token:{uuid} 1800 (续期)
        S-->>C: 响应
    else Redis未命中
        S-->>C: 401 请重新登录
    end

    Note over C,R: 强制下线
    S->>R: DEL token:{uuid}
    Note over R: Token立即失效
```

| 维度 | 评价 | 说明 |
|------|:---:|------|
| **性能** | 一般 | 每次请求都查 Redis（毫秒级延迟） |
| **水平扩展** | 一般 | 依赖共享 Redis，所有服务器连同一个 Redis |
| **主动失效** | <span style="color:red">支持</span> | 删除 Redis 中的 Key 即可 |
| **强制下线** | <span style="color:red">支持</span> | 可查询用户所有 Token 并批量删除 |
| **在线用户管理** | <span style="color:red">支持</span> | Redis 中存储了所有在线会话 |
| **Token泄露应对** | <span style="color:red">可应对</span> | 立即删除泄露的 Token |
| **Token可读性** | 差 | Token 是 UUID，本身不含任何信息 |

### ⭐ 2.3 方案三：JWT + Redis 混合方案（推荐）

**核心设计思想**：JWT 负责携带用户信息（无状态验证），Redis 负责管理 Token 的生命周期（有状态控制）。

```mermaid
sequenceDiagram
    participant C as 客户端
    participant S as 服务端
    participant J as JWT签名
    participant R as Redis

    Note over C,R: ====== 登录阶段 ======
    C->>S: 用户名+密码
    S->>S: 验证用户名密码
    S->>J: 生成JWT (jti=唯一ID, 过期30分钟)
    S->>R: SET auth:token:{jti} → {userId, username}<br/>EXPIRE 1800 (与JWT一致)
    S-->>C: {accessToken: JWT, refreshToken}

    Note over C,R: ====== 正常请求（JWT有效+Redis命中）======
    C->>S: 请求 + JWT
    S->>J: ①验证JWT签名+过期时间
    alt JWT无效
        S-->>C: 401 Token无效
    end
    S->>S: ②从JWT Payload中提取jti
    S->>R: ③GET auth:token:{jti}
    alt Redis命中
        S-->>C: 放行（认证通过）
    else Redis未命中
        S-->>C: 401 Token已被撤销
    end

    Note over C,R: ====== 强制下线 ======
    S->>R: DEL auth:token:{jti}
    Note over R: 该JWT即使未过期<br/>下次请求时Redis查不到<br/>→ 返回401
```

这是目前企业生产环境中最主流的方案，它在两种极端之间找到了最佳平衡点。

---

## 🎨 三、JWT + Redis 混合方案的设计细节

### 🧬 3.1 核心数据结构

在进入代码之前，先把方案中用到的关键数据结构理清：

```mermaid
flowchart TD
    classDef startEnd fill:#F48FB1,stroke:#C2185B,stroke-width:2px,color:#212121,font-weight:bold;
    classDef process fill:#F5F5F5,stroke:#9E9E9E,stroke-width:1.5px,color:#212121;
    classDef data fill:#C8E6C9,stroke:#388E3C,stroke-width:1.5px,color:#1B5E20,font-weight:bold;
    classDef highlight fill:#FFCCBC,stroke:#E64A19,stroke-width:1.5px,color:#D84315,font-weight:bold;

    ROOT[JWT + Redis<br/>混合鉴权体系]

    ROOT --> JWT_PART[JWT Token]
    JWT_PART --> J1["Header\n• alg: HS256"]
    JWT_PART --> J2["Payload\n• sub: 用户ID\n• username: 用户名\n• role: 角色\n• jti: Token唯一ID<br/>  (UUID, 每次签发不同)\n• iat: 签发时间\n• exp: 过期时间"]
    JWT_PART --> J3["Signature\n• HMAC-SHA256签名"]

    ROOT --> REDIS_PART[Redis 存储]
    REDIS_PART --> R1["Key: auth:token:{jti}\nValue: JSON(用户摘要)\nTTL: 与JWT exp一致"]

    REDIS_PART --> R2["Key: auth:user:{userId}\nValue: SET{ jti1, jti2, ... }\n记录用户的所有活跃Token"]

    class ROOT startEnd;
    class JWT_PART,REDIS_PART process;
    class J1,J2,J3,R1,R2 data;
```

### 🔍 3.2 JWT 结构实例（解码示例）

以下是一个真实的 JWT Access Token（密钥为 `my-secret-key-for-demo`）：

```
eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMDAxIiwidXNlcm5hbWUiOiJ6aGFuZ3NhbiIsInJvbGUiOiJST0xFX0FETUlOIiwianRpIjoiYTFiMmMzZDQtZTVmNi00YTFiLTgyYzMtZDhlOWYwYWFiM2NjIiwiaWF0IjoxNjYwMTIzNDAwLCJleHAiOjE2NjAxMjUyMDAsInR5cGUiOiJhY2Nlc3MifQ.GzXxp0FJhReXyL8kqWpHN3vYmRK_mBfQ5eVwTtQsd2A
```

用 `.` 分割后得到三段，每段 Base64 解码后的内容如下：

**Header**（第一段 `eyJhbGciOiJIUzI1NiJ9`）：

```json
{
  "alg": "HS256",
  "typ": "JWT"
}
```

`alg: HS256` 表示使用 HMAC-SHA256 签名算法。`typ: JWT` 表示令牌类型。

**Payload**（第二段 `eyJzdWIiOiIxMDAxIiwi...`，中间省略）：

```json
{
  "sub": "1001",
  "username": "zhangsan",
  "role": "ROLE_ADMIN",
  "jti": "a1b2c3d4-e5f6-4a1b-82c3-d8e9f0aab3cc",
  "iat": 1660123400,
  "exp": 1660125200,
  "type": "access"
}
```

| 字段 | 全称 | 含义 | 示例值 | 来源 |
|------|------|------|------|------|
| `sub` | Subject | 主题，约定存放用户 ID | `"1001"` | JWT 标准注册声明 |
| `username` | — | 用户名 | `"zhangsan"` | **自定义私有声明** |
| `role` | — | 角色 | `"ROLE_ADMIN"` | **自定义私有声明** |
| `jti` | JWT ID | Token 唯一标识（UUID） | `"a1b2c3d4-..."` | JWT 标准注册声明，**混合方案的桥梁** |
| `iat` | Issued At | 签发时间（Unix 秒级时间戳） | `1660123400` | JWT 标准注册声明 |
| `exp` | Expiration | 过期时间（Unix 秒级时间戳） | `1660125200` | JWT 标准注册声明 |
| `type` | — | Token 类型标记 | `"access"` | **自定义私有声明**，区分 Access/Refresh Token |

> **注意**：Payload 中的时间戳 `iat` 和 `exp` 是 **Unix 秒级时间戳**（从 1970-01-01 00:00:00 UTC 开始的秒数），这与 Java 中常用的毫秒级时间戳不同。JJWT 的 `setIssuedAt(new Date())` 和 `setExpiration(new Date())` 会自动处理秒级转换。`1660125200 − 1660123400 = 1800` 秒 = 30 分钟，即此 Token 的有效期。

**Signature**（第三段 `GzXxp0FJhReXyL8kqWpHN3vYmRK_mBfQ5eVwTtQsd2A`）：

签名是以下公式的 HMAC-SHA256 计算结果（二进制数据经 Base64 编码后得到）：

```
HMAC-SHA256(
  Base64Url(Header) + "." + Base64Url(Payload),
  secret
)
```

Signature 不是可读文本，无法解码出有意义的信息。服务端收到 Token 后，用相同的 `secret` 对 Header + Payload 重新计算签名，与收到的 Signature 比对。一致 → Token 未被篡改，Payload 中的用户信息可以信任；不一致 → Token 被修改过或伪造，拒绝请求。

> **安全提示**：你可以将上面的 Token 粘贴到任意 Base64 解码工具中验证 Header 和 Payload 的内容，但**绝对不要**在第三方在线工具中粘贴生产环境的真实 Token，Payload 中的信息会被第三方看到。

### 🏷️ 3.3 为什么 JWT 的 Payload 需要 `jti`（JWT ID）

`jti`（JWT ID）是 JWT 规范中的标准声明（RFC 7519），用于唯一标识一个 Token。在混合方案中，`jti` 是连接 JWT 和 Redis 的桥梁：

-  签发 Token 时生成一个 UUID 作为 `jti`
-  Redis 中以 `auth:token:{jti}` 为 Key 存储该 Token 的会话信息
-  需要撤销 Token 时，精确删除 `auth:token:{jti}` 即可

> **注意**：`jti` 必须每次签发都不同（UUID 即可保证），否则无法区分相同用户的不同登录设备。

### 💾 3.4 Redis 中存什么

Redis 中存储两类数据：

| Redis Key 格式 | Value | TTL | 作用 |
|------|------|:---:|------|
| `auth:token:{jti}` | `{"userId":1001,"username":"zhangsan","role":"ROLE_USER"}` | 等于 JWT 的过期时间（30 分钟） | **主键**：Token 存在 = 有效，删除 = 失效 |
| `auth:user:{userId}` | `SET {"jti-abc123", "jti-def456", ...}` | 不做限制或设为更长 | **辅助**：查询某用户的所有活跃 Token，用于"踢出所有设备" |

### 🔑 3.5 Redis 键值对设计推荐

上述表格给出了基本设计，但在实际生产环境中，Value 的数据结构选择会直接影响系统的维护成本和性能。以下给出三种经过生产验证的键值对设计方案。

#### 3.5.1 方案 A：String 存 JSON（推荐大多数项目使用）

**存储结构**：

```
Key:   auth:token:a1b2c3d4-e5f6-4a1b-82c3-d8e9f0aab3cc
Type:  String
Value: {"userId":1001,"username":"zhangsan","role":"ROLE_ADMIN",
        "loginIp":"192.168.1.100","deviceInfo":"Mozilla/5.0...",
        "issuedAt":1660123400000,"jti":"a1b2c3d4-..."}
TTL:   1800（30分钟，与 JWT 的 exp 保持一致）
```

**对应的 Redis 命令**：

```bash
# 登录时写入
SET auth:token:a1b2c3d4-e5f6-4a1b-82c3-d8e9f0aab3cc \
  '{"userId":1001,"username":"zhangsan","role":"ROLE_ADMIN"}' EX 1800

# 每次请求时检查
GET auth:token:a1b2c3d4-e5f6-4a1b-82c3-d8e9f0aab3cc
# 返回: {"userId":1001,...}  → Token 有效，放行
# 返回: (nil)                 → Token 已失效（登出 / 自然过期）

# 登出时删除
DEL auth:token:a1b2c3d4-e5f6-4a1b-82c3-d8e9f0aab3cc
```

| 评价维度 | 结论 |
|------|------|
| 优点 | 实现最简单——Java 中 Jackson 一行序列化，Redis 中一个 GET 完成 |
| 缺点 | 修改单个字段（如更新 `loginIp`）需要整体反序列化 → 修改 → 序列化 → 写回 |
| 适用 | Token 写入后很少修改字段的场景（覆盖 90% 的业务） |

#### 3.5.2 方案 B：Hash 存字段（适合需要频繁更新单字段的系统）

**存储结构**：

```
Key:   auth:token:a1b2c3d4-e5f6-4a1b-82c3-d8e9f0aab3cc
Type:  Hash
Field-Value:
  userId     → "1001"
  username   → "zhangsan"
  role       → "ROLE_ADMIN"
  loginIp    → "192.168.1.100"
  deviceInfo → "Mozilla/5.0 (Windows NT 10.0)..."
  issuedAt   → "1660123400000"
TTL:   1800（对整个 Hash 设置过期）
```

**对应的 Redis 命令**：

```bash
# 登录时写入
HSET auth:token:a1b2c3d4-e5f6-4a1b-82c3-d8e9f0aab3cc \
  userId 1001 username zhangsan role ROLE_ADMIN
EXPIRE auth:token:a1b2c3d4-e5f6-4a1b-82c3-d8e9f0aab3cc 1800

# 每次请求时检查（读全部字段）
HGETALL auth:token:a1b2c3d4-e5f6-4a1b-82c3-d8e9f0aab3cc
# 返回所有 field-value → Token 有效
# 返回 (empty)           → Token 已失效

# 只读某一个字段（如只需要 role 做权限判断）
HGET auth:token:a1b2c3d4-e5f6-4a1b-82c3-d8e9f0aab3cc role
# 返回: "ROLE_ADMIN"

# 更新单个字段（如检测到 IP 变化时更新）
HSET auth:token:a1b2c3d4-e5f6-4a1b-82c3-d8e9f0aab3cc loginIp "10.0.0.1"
```

| 评价维度 | 结论 |
|------|------|
| 优点 | 支持字段级读写，可单独更新某个字段而无需整体反序列化 |
| 缺点 | `HGETALL` 在大 Hash（如 50+ 字段）时性能不如 String GET；序列化配置稍复杂（Spring Data Redis 需分别配置 Hash Key/Value 的序列化器） |
| 适用 | 需要监控用户行为并更新 `loginIp` 等字段的审计系统 |

#### 3.5.3 方案 C：String 存占位符（适合超高并发场景）

**存储结构**：

```
Key:   auth:token:a1b2c3d4-e5f6-4a1b-82c3-d8e9f0aab3cc
Type:  String
Value: "1"（仅占位，用户信息全部从 JWT Payload 中读取）
TTL:   1800
```

**对应的 Redis 命令**：

```bash
# 登录时写入
SET auth:token:a1b2c3d4-e5f6-4a1b-82c3-d8e9f0aab3cc "1" EX 1800

# 每次请求时检查
EXISTS auth:token:a1b2c3d4-e5f6-4a1b-82c3-d8e9f0aab3cc
# 返回: 1 → Token 有效
# 返回: 0 → Token 已失效

# 登出时删除
DEL auth:token:a1b2c3d4-e5f6-4a1b-82c3-d8e9f0aab3cc
```

| 评价维度 | 结论 |
|------|------|
| 优点 | Redis 内存占用最小（~50B/Token）；Redis 仅负责"存活检查"，用户信息全从 JWT 中读 |
| 缺点 | 无法在 Redis 中查询在线用户列表；用户信息变更（如修改角色）需等当前 Token 过期才生效；无法做 IP 审计 |
| 适用 | 超高并发（日活百万级）、对 Redis 内存敏感、用户信息无需在服务端记录的极端场景 |

#### 3.5.4 三种方案对比

| 维度 | A: String JSON | B: Hash 字段级 | C: String 占位符 |
|------|:---:|:---:|:---:|
| 单 Token 内存占用 | ~200B | ~300B | **~50B** |
| 读操作 | `GET` O(1) | `HGETALL` O(N)，N=字段数 | `EXISTS` O(1)，**最快** |
| 字段部分更新 | ❌ 需整体覆盖 | ✅ `HSET` 单字段更新 | ❌ 无字段可更新 |
| 在线用户查询 | ✅ 直接读 Value | ✅ 直接读 Hash | ❌ 无法查询 |
| IP 审计 | ✅ 可记录 | ✅ 可记录并可单独更新 | ❌ 无法记录 |
| 序列化复杂度 | **低**（Jackson 一行） | 中（需配 Hash 序列化） | **极低**（无序列化） |
| 推荐场景 | **中小项目（日活 < 10 万）** | 需要审计/监控的系统 | 超高并发（日活 > 100 万） |

#### 3.5.5 辅助 Key：用户 Token 集合的设计

除主 Key 外，强烈建议维护一个 **用户 → Token 列表** 的辅助 Key，用于"踢出所有设备"和"限制登录设备数"：

```
Key:   auth:user:1001
Type:  Set
Value: {"a1b2c3d4-e5f6-4a1b-82c3-d8e9f0aab3cc",
        "b2c3d4e5-f6a7-4b2c-93d4-e9f0aabb4dd",
        "c3d4e5f6-a7b8-4c3d-a4e5-f0a1b2c3d4e5"}
TTL:   不设过期（或设为 Refresh Token 有效期 × 2）
```

Set 成员为该用户当前所有活跃 Token 的 `jti`。它支持以下运维操作：

```bash
# 1. 查看用户 1001 当前在几台设备上登录
SCARD auth:user:1001
# 返回: 3

# 2. 列出用户 1001 的所有活跃Token的jti
SMEMBERS auth:user:1001
# 返回: a1b2c3d4-..., b2c3d4e5-..., c3d4e5f6-...

# 3. 【踢出所有设备】改密码时触发
#    先拿到所有jti → 逐个删除Token → 删除Set
SMEMBERS auth:user:1001 | xargs -I {} redis-cli DEL auth:token:{}
DEL auth:user:1001

# 4. 限制最多 3 台设备同时登录
#    业务代码中：SCARD > 3 时，SPOP出一个最旧的jti并删除对应Token
```

#### 3.5.6 完整的 Key 命名规范

| Key 模式 | 类型 | TTL | 读写频率 | 说明 |
|------|:---:|:---:|:---:|------|
| `auth:token:{jti}` | String（推荐 A 方案） | = JWT exp | 读高、写低 | **主键**，存在 = 有效，删除 = 失效 |
| `auth:user:{userId}` | Set | 不设或 = Refresh Token exp × 2 | 写中、读低 | 用户所有活跃 jti 集合 |
| `auth:refresh:{jti}` | String | = Refresh Token exp | 读中、写低 | 可选：Refresh Token 白名单（防 Refresh Token 重用） |

### 🔄 3.6 Token 生命周期的五种状态

```mermaid
stateDiagram-v2
    classDef valid fill:#C8E6C9,stroke:#388E3C,stroke-width:2px,color:#1B5E20,font-weight:bold
    classDef invalid fill:#FFCDD2,stroke:#C62828,stroke-width:2px,color:#B71C1C,font-weight:bold
    classDef middle fill:#E1BEE7,stroke:#7B1FA2,stroke-width:2px,color:#212121,font-weight:bold

    [*] --> Active : 登录成功<br/>签发JWT+写入Redis

    state Active {
        [*] --> Normal : JWT有效期内
    }

    Active --> Expired : JWT的exp时间到达<br/>Redis Key自动过期
    Active --> Revoked : 管理员/DEL Redis Key<br/>用户主动登出
    Active --> Refreshed : 用RefreshToken<br/>换取新的AccessToken

    Expired --> [*]
    Revoked --> [*]
    Refreshed --> Active : 签发新JWT<br/>写入新Redis Key

    class Active,Refreshed valid
    class Expired,Revoked invalid
```

---

## 💻 四、完整生产实战：JJWT + Redis + Spring Security

下面给出一个可以直接用于生产环境的完整实现。技术选型：

| 组件 | 选型 | 原因 |
|------|------|------|
| JWT 库 | **JJWT**（`io.jsonwebtoken`） | Java 生态中功能最完整、社区最活跃的 JWT 库 |
| 缓存 | **Redis** | 高性能 KV 存储，天然支持 TTL 过期 |
| 安全框架 | **Spring Security** | 业界标准的 Java 安全框架 |
| Redis 客户端 | **Lettuce**（Spring Boot 默认） | 异步非阻塞，性能优于 Jedis |

### 📋 4.1 Maven 依赖

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

    <!-- Spring Data Redis (默认使用Lettuce) -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-data-redis</artifactId>
    </dependency>

    <!-- JJWT (Java JWT库) -->
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

    <!-- 连接池（Jedis与Lettuce的通用池） -->
    <dependency>
        <groupId>org.apache.commons</groupId>
        <artifactId>commons-pool2</artifactId>
    </dependency>

    <!-- Lombok -->
    <dependency>
        <groupId>org.projectlombok</groupId>
        <artifactId>lombok</artifactId>
        <optional>true</optional>
    </dependency>

    <!-- MyBatis-Plus -->
    <dependency>
        <groupId>com.baomidou</groupId>
        <artifactId>mybatis-plus-boot-starter</artifactId>
        <version>3.5.5</version>
    </dependency>

    <dependency>
        <groupId>com.mysql</groupId>
        <artifactId>mysql-connector-j</artifactId>
        <scope>runtime</scope>
    </dependency>
</dependencies>
```

### ⚙️ 4.2 配置文件（application.yml）

```yaml
server:
  port: 8080

spring:
  datasource:
    url: jdbc:mysql://localhost:3306/mall?useUnicode=true&characterEncoding=utf-8&serverTimezone=Asia/Shanghai
    username: root
    password: 123456
    driver-class-name: com.mysql.cj.jdbc.Driver

  redis:
    host: localhost
    port: 6379
    password:            # 生产环境务必设置密码
    database: 0
    lettuce:
      pool:
        max-active: 16
        max-idle: 8
        min-idle: 4
    timeout: 3000ms

# JWT 配置
jwt:
  secret: a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2  # 生产环境至少256位
  access-token-expire: 30    # Access Token 过期时间（分钟）
  refresh-token-expire: 10080  # Refresh Token 过期时间（分钟，7天）

# Token 存储配置
auth:
  redis:
    key-prefix: "auth:token:"      # Access Token Redis Key 前缀
    user-tokens-prefix: "auth:user:" # 用户所有Token集合 Key前缀
```

### 📂 4.3 代码结构总览

```
src/main/java/com/mallshop/mallsecurity/
├── config/
│   ├── SecurityConfig.java          # Spring Security 核心配置
│   ├── RedisConfig.java             # Redis 序列化配置
│   └── JwtConfig.java               # JWT 配置属性
├── controller/
│   └── AuthController.java          # 登录/登出/刷新Token
├── entity/
│   └── User.java                    # 用户实体
├── filter/
│   └── JwtAuthenticationFilter.java # JWT + Redis 认证过滤器
├── mapper/
│   └── UserMapper.java              # 数据库访问
├── service/
│   ├── UserService.java             # 用户服务
│   └── TokenService.java            # Token 生命周期管理（核心）
├── util/
│   └── JwtUtil.java                 # JJWT 工具类
└── dto/
    ├── LoginRequest.java
    ├── LoginResponse.java
    └── TokenInfo.java               # 存储在Redis中的Token摘要
```

### 🔧 4.4 JJWT 工具类

```java
package com.mallshop.mallsecurity.util;

import io.jsonwebtoken.*;
import io.jsonwebtoken.security.Keys;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import javax.crypto.SecretKey;
import java.nio.charset.StandardCharsets;
import java.util.Date;
import java.util.UUID;

@Component
public class JwtUtil {

    private final SecretKey secretKey;
    private final long accessTokenExpireMs;
    private final long refreshTokenExpireMs;

    public JwtUtil(
            @Value("${jwt.secret}") String secret,
            @Value("${jwt.access-token-expire}") long accessTokenExpireMinutes,
            @Value("${jwt.refresh-token-expire}") long refreshTokenExpireMinutes) {
        // JJWT要求密钥至少256位（32字节）
        this.secretKey = Keys.hmacShaKeyFor(secret.getBytes(StandardCharsets.UTF_8));
        this.accessTokenExpireMs = accessTokenExpireMinutes * 60 * 1000;
        this.refreshTokenExpireMs = refreshTokenExpireMinutes * 60 * 1000;
    }

    /**
     * 生成 Access Token（含 jti）
     */
    public String createAccessToken(Long userId, String username, String role) {
        Date now = new Date();
        Date expiration = new Date(now.getTime() + accessTokenExpireMs);

        return Jwts.builder()
                .setId(UUID.randomUUID().toString())          // jti：Token唯一标识
                .setSubject(userId.toString())                // sub：用户ID
                .claim("username", username)                  // 自定义：用户名
                .claim("role", role)                          // 自定义：角色
                .claim("type", "access")                      // 自定义：Token类型
                .setIssuedAt(now)                             // iat：签发时间
                .setExpiration(expiration)                    // exp：过期时间
                .signWith(secretKey)                          // 签名
                .compact();
    }

    /**
     * 生成 Refresh Token
     */
    public String createRefreshToken(Long userId) {
        Date now = new Date();
        Date expiration = new Date(now.getTime() + refreshTokenExpireMs);

        return Jwts.builder()
                .setId(UUID.randomUUID().toString())
                .setSubject(userId.toString())
                .claim("type", "refresh")
                .setIssuedAt(now)
                .setExpiration(expiration)
                .signWith(secretKey)
                .compact();
    }

    /**
     * 解析JWT（不验证是否在Redis中存在）
     */
    public Claims parseToken(String token) {
        return Jwts.parserBuilder()
                .setSigningKey(secretKey)
                .build()
                .parseClaimsJws(token)
                .getBody();
    }

    /**
     * 获取Token的剩余有效时间（毫秒）
     */
    public long getRemainingTimeMillis(Claims claims) {
        return claims.getExpiration().getTime() - System.currentTimeMillis();
    }

    /**
     * 从Claims中提取常用字段
     */
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

    public boolean isAccessToken(Claims claims) {
        return "access".equals(claims.get("type", String.class));
    }
}
```

> **JJWT 关键 API 说明**：
>
> | 方法 | 作用 |
> |------|------|
> | `Jwts.builder()` | 创建 JWT 构建器 |
> | `.setId(uuid)` | 设置 `jti`（JWT ID），**混合方案的桥梁字段** |
> | `.setSubject(userId)` | 设置 `sub`，约定存放用户 ID |
> | `.claim(key, value)` | 添加自定义字段（username、role、type） |
> | `.setExpiration(date)` | 设置过期时间 |
> | `.signWith(secretKey)` | 使用 HMAC-SHA256 签名 |
> | `Jwts.parserBuilder().setSigningKey(key).build()` | 创建 JWT 解析器 |
> | `.parseClaimsJws(token).getBody()` | 解析并验证，返回 Claims |
> | `Keys.hmacShaKeyFor(bytes)` | 从字节数组创建 HMAC 密钥 |

### 🗄️ 4.5 Redis 配置

```java
package com.mallshop.mallsecurity.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.redis.connection.RedisConnectionFactory;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.data.redis.serializer.GenericJackson2JsonRedisSerializer;
import org.springframework.data.redis.serializer.StringRedisSerializer;

@Configuration
public class RedisConfig {

    @Bean
    public RedisTemplate<String, Object> redisTemplate(
            RedisConnectionFactory connectionFactory) {

        RedisTemplate<String, Object> template = new RedisTemplate<>();
        template.setConnectionFactory(connectionFactory);

        // Key 用 String 序列化（可读性好）
        template.setKeySerializer(new StringRedisSerializer());
        template.setHashKeySerializer(new StringRedisSerializer());

        // Value 用 JSON 序列化（存入Java对象时自动转JSON）
        template.setValueSerializer(new GenericJackson2JsonRedisSerializer());
        template.setHashValueSerializer(new GenericJackson2JsonRedisSerializer());

        template.afterPropertiesSet();
        return template;
    }
}
```

### 📝 4.6 TokenInfo ——存储在 Redis 中的 Token 摘要

```java
package com.mallshop.mallsecurity.dto;

import lombok.AllArgsConstructor;
import lombok.Builder;
import lombok.Data;
import lombok.NoArgsConstructor;

import java.io.Serializable;

/**
 * 存储在 Redis 中的 Token 摘要信息。
 * 每个 Access Token 在 Redis 中对应一条此记录。
 */
@Data
@Builder
@NoArgsConstructor
@AllArgsConstructor
public class TokenInfo implements Serializable {

    /** 用户ID */
    private Long userId;

    /** 用户名 */
    private String username;

    /** 角色 */
    private String role;

    /** Token签发时间（时间戳ms） */
    private Long issuedAt;

    /** 登录IP */
    private String loginIp;

    /** 登录设备标识（User-Agent摘要） */
    private String deviceInfo;

    /** jti，用于关联和查询 */
    private String jti;
}
```

> **生产提示**：`loginIp` 和 `deviceInfo` 不是必须的，但在安全审计和异常登录检测中非常有用。比如发现某个 Token 的 IP 地址突然变化，可能是 Token 泄露的信号。

### ⚙️ 4.7 TokenService ——核心：Token 生命周期管理

这是整个混合方案中最关键的类，封装了 Token 在 Redis 中的增删查操作。

```java
package com.mallshop.mallsecurity.service;

import com.mallshop.mallsecurity.dto.TokenInfo;
import com.mallshop.mallsecurity.util.JwtUtil;
import io.jsonwebtoken.Claims;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.data.redis.core.RedisTemplate;
import org.springframework.stereotype.Service;

import java.util.Set;
import java.util.concurrent.TimeUnit;

@Service
public class TokenService {

    private final RedisTemplate<String, Object> redisTemplate;
    private final JwtUtil jwtUtil;
    private final String tokenKeyPrefix;
    private final String userTokensPrefix;

    public TokenService(
            RedisTemplate<String, Object> redisTemplate,
            JwtUtil jwtUtil,
            @Value("${auth.redis.key-prefix}") String tokenKeyPrefix,
            @Value("${auth.redis.user-tokens-prefix}") String userTokensPrefix) {
        this.redisTemplate = redisTemplate;
        this.jwtUtil = jwtUtil;
        this.tokenKeyPrefix = tokenKeyPrefix;
        this.userTokensPrefix = userTokensPrefix;
    }

    /**
     * 【核心方法】登录成功后：将 Token 存入 Redis
     *
     * @param token   已签发的JWT字符串
     * @param tokenInfo Token的摘要信息
     */
    public void storeAccessToken(String token, TokenInfo tokenInfo) {
        Claims claims = jwtUtil.parseToken(token);
        String jti = jwtUtil.getJti(claims);
        long ttl = jwtUtil.getRemainingTimeMillis(claims);

        if (ttl <= 0) {
            return; // Token 已过期，无需存储
        }

        // 1. 存主记录：auth:token:{jti} → TokenInfo
        String tokenKey = tokenKeyPrefix + jti;
        redisTemplate.opsForValue().set(tokenKey, tokenInfo, ttl, TimeUnit.MILLISECONDS);

        // 2. 维护用户Token集合：auth:user:{userId} → SET {jti1, jti2, ...}
        String userKey = userTokensPrefix + tokenInfo.getUserId();
        redisTemplate.opsForSet().add(userKey, jti);
        // 用户Token集合的过期时间设为Token最长时间的2倍（留冗余）
        redisTemplate.expire(userKey, ttl * 2, TimeUnit.MILLISECONDS);
    }

    /**
     * 【核心方法】每次请求时：检查 Token 在 Redis 中是否存在
     *
     * @param jti Token的jti
     * @return TokenInfo 如果存在，null 如果已失效
     */
    public TokenInfo validateAndGetTokenInfo(String jti) {
        String tokenKey = tokenKeyPrefix + jti;
        return (TokenInfo) redisTemplate.opsForValue().get(tokenKey);
    }

    /**
     * 【主动失效】登出：删除单个 Token
     *
     * @param jti 要删除的Token的jti
     * @param userId 用户ID（用于从集合中移除）
     */
    public void revokeToken(String jti, Long userId) {
        // 1. 删除主记录
        String tokenKey = tokenKeyPrefix + jti;
        redisTemplate.delete(tokenKey);

        // 2. 从用户集合中移除
        String userKey = userTokensPrefix + userId;
        redisTemplate.opsForSet().remove(userKey, jti);
    }

    /**
     * 【主动失效】强制下线：删除某用户的所有 Token
     *
     * @param userId 用户ID
     */
    public void revokeAllUserTokens(Long userId) {
        String userKey = userTokensPrefix + userId;

        // 1. 获取该用户的所有 jti
        Set<Object> jtis = redisTemplate.opsForSet().members(userKey);
        if (jtis == null || jtis.isEmpty()) {
            return;
        }

        // 2. 逐个删除 Token 主记录
        for (Object jtiObj : jtis) {
            String jti = jtiObj.toString();
            String tokenKey = tokenKeyPrefix + jti;
            redisTemplate.delete(tokenKey);
        }

        // 3. 删除用户集合本身
        redisTemplate.delete(userKey);
    }

    /**
     * 【查询】获取用户当前在线的所有设备
     *
     * @param userId 用户ID
     * @return 该用户所有活跃的jti集合
     */
    public Set<Object> getUserActiveTokens(Long userId) {
        String userKey = userTokensPrefix + userId;
        return redisTemplate.opsForSet().members(userKey);
    }
}
```

> **关键设计说明**：
>
> -  第 67 行：`ttl` 与 JWT 的 `exp` 保持一致。当 JWT 自然过期时，Redis 中的 Key 也自动过期，无需手动清理。这保证了 **Redis 中的数据量和 JWT 的有效数量同步**
> -  第 72 ~ 74 行：维护 `auth:user:{userId}` 集合是为了支持"踢出所有设备"——遍历该集合拿到所有 `jti`，逐个删除
> -  第 83 行：每次请求都查询 Redis。这是混合方案的主要开销（一次 Redis GET），但换来了 Token 主动失效的能力
> -  第 122 ~ 136 行：`revokeAllUserTokens` 实现了"改密码后踢出所有设备"的需求

### 🛡️ 4.8 JWT 认证过滤器 ——每次请求的入口

<span style="color:red">这是整个鉴权链路中最核心的代码</span>，它串联了 JWT 验证和 Redis 检查。

```java
package com.mallshop.mallsecurity.filter;

import com.mallshop.mallsecurity.dto.TokenInfo;
import com.mallshop.mallsecurity.service.TokenService;
import com.mallshop.mallsecurity.util.JwtUtil;
import io.jsonwebtoken.Claims;
import io.jsonwebtoken.ExpiredJwtException;
import io.jsonwebtoken.JwtException;
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

    @Autowired
    private TokenService tokenService;

    @Override
    protected void doFilterInternal(HttpServletRequest request,
                                    HttpServletResponse response,
                                    FilterChain filterChain)
            throws ServletException, IOException {

        // 1. 提取Token
        String token = extractToken(request);
        if (!StringUtils.hasText(token)) {
            filterChain.doFilter(request, response);
            return;
        }

        // 2. 解析JWT（验证签名和过期时间）
        Claims claims;
        try {
            claims = jwtUtil.parseToken(token);
        } catch (ExpiredJwtException e) {
            // Token已过期——JWT层面检查失败
            handleAuthFailure(response, 401, "Token已过期，请重新登录");
            return;
        } catch (JwtException e) {
            // Token签名无效——可能是伪造的
            handleAuthFailure(response, 401, "Token无效");
            return;
        }

        // 3. 确认是Access Token（不是Refresh Token）
        if (!jwtUtil.isAccessToken(claims)) {
            handleAuthFailure(response, 401, "请使用Access Token访问");
            return;
        }

        String jti = jwtUtil.getJti(claims);

        // 4. 【关键步骤】Redis检查：Token是否已被主动撤销
        TokenInfo tokenInfo = tokenService.validateAndGetTokenInfo(jti);
        if (tokenInfo == null) {
            // Redis中不存在 → Token已被删除（登出/踢下线/改密码）
            handleAuthFailure(response, 401, "Token已被撤销，请重新登录");
            return;
        }

        // 5. Token有效，设置Spring Security认证状态
        String username = tokenInfo.getUsername();
        String role = tokenInfo.getRole();

        UsernamePasswordAuthenticationToken authentication =
                new UsernamePasswordAuthenticationToken(
                    username,
                    null,
                    Collections.singletonList(new SimpleGrantedAuthority(role))
                );
        SecurityContextHolder.getContext().setAuthentication(authentication);

        // 6. 继续过滤器链
        filterChain.doFilter(request, response);
    }

    /**
     * 从请求头提取 Bearer Token
     */
    private String extractToken(HttpServletRequest request) {
        String bearerToken = request.getHeader("Authorization");
        if (StringUtils.hasText(bearerToken) && bearerToken.startsWith("Bearer ")) {
            return bearerToken.substring(7);
        }
        return null;
    }

    /**
     * 返回统一的JSON错误响应
     */
    private void handleAuthFailure(HttpServletResponse response,
                                   int status, String message) throws IOException {
        response.setContentType("application/json;charset=UTF-8");
        response.setStatus(status);
        response.getWriter().write(
            String.format("{\"code\":%d,\"message\":\"%s\"}", status, message));
    }
}
```

> **过滤器的四层检查**：
>
> 1. **JWT 签名验证**（第 63 ~ 69 行）：验证 Token 是否被篡改，是否已过期。这是 JWT 自身的保护机制，纯 CPU 操作，无 IO
> 2. **Token 类型检查**（第 72 ~ 74 行）：防止用户拿 Refresh Token 当 Access Token 用
> 3. **<span style="color:red">Redis 存活检查</span>**（第 79 ~ 84 行）：**混合方案的核心**——即使 JWT 签名正确且未过期，只要 Redis 中不存在，就视为 Token 已失效
> 4. **权限设置**（第 87 ~ 95 行）：从 Redis 中的 `TokenInfo` 读取用户信息，设置 Spring Security 认证状态

### 🔒 4.9 Spring Security 配置

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

    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder();
    }

    @Bean
    public AuthenticationManager authenticationManager(
            AuthenticationConfiguration config) throws Exception {
        return config.getAuthenticationManager();
    }

    @Bean
    public SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        http
            // 关闭CSRF：前后端分离+JWT方案不需要
            .csrf().disable()

            // 无状态模式：不创建Session
            .sessionManagement()
            .sessionCreationPolicy(SessionCreationPolicy.STATELESS)

            .and()
            .authorizeRequests()
            // 登录、刷新Token——无需认证
            .antMatchers("/api/auth/login", "/api/auth/refresh").permitAll()
            // 登出——需要认证（需要知道是谁在登出）
            .antMatchers("/api/auth/logout").authenticated()
            // 管理员接口——需要ADMIN角色
            .antMatchers("/api/admin/**").hasRole("ADMIN")
            // 其余接口——需要登录
            .anyRequest().authenticated()

            // 注册JWT过滤器
            .and()
            .addFilterBefore(jwtAuthenticationFilter,
                             UsernamePasswordAuthenticationFilter.class)

            // 自定义401/403响应
            .exceptionHandling()
            .authenticationEntryPoint((request, response, authException) -> {
                response.setContentType("application/json;charset=UTF-8");
                response.setStatus(401);
                response.getWriter().write(
                    "{\"code\":401,\"message\":\"请先登录\"}");
            })
            .accessDeniedHandler((request, response, accessDeniedException) -> {
                response.setContentType("application/json;charset=UTF-8");
                response.setStatus(403);
                response.getWriter().write(
                    "{\"code\":403,\"message\":\"权限不足\"}");
            });

        return http.build();
    }
}
```

### 🔑 4.10 登录 / 登出 / 刷新 Token 接口

```java
package com.mallshop.mallsecurity.controller;

import com.mallshop.mallsecurity.dto.*;
import com.mallshop.mallsecurity.service.TokenService;
import com.mallshop.mallsecurity.util.JwtUtil;
import io.jsonwebtoken.Claims;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.security.authentication.AuthenticationManager;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.core.userdetails.UserDetails;
import org.springframework.web.bind.annotation.*;

import javax.servlet.http.HttpServletRequest;
import javax.validation.Valid;
import javax.validation.constraints.NotBlank;

@RestController
@RequestMapping("/api/auth")
public class AuthController {

    @Autowired
    private AuthenticationManager authenticationManager;

    @Autowired
    private JwtUtil jwtUtil;

    @Autowired
    private TokenService tokenService;

    /**
     * 登录
     */
    @PostMapping("/login")
    public LoginResponse login(@Valid @RequestBody LoginRequest request,
                               HttpServletRequest httpRequest) {
        // 1. 认证用户名密码
        Authentication authentication = authenticationManager.authenticate(
                new UsernamePasswordAuthenticationToken(
                    request.getUsername(), request.getPassword()));

        UserDetails userDetails = (UserDetails) authentication.getPrincipal();
        String role = userDetails.getAuthorities().stream()
                .findFirst().get().getAuthority();

        // TODO: 实际项目中从数据库查询userId，这里简化处理
        Long userId = 1001L;
        String username = userDetails.getUsername();

        // 2. 生成 Access Token（含jti）
        String accessToken = jwtUtil.createAccessToken(userId, username, role);
        String refreshToken = jwtUtil.createRefreshToken(userId);

        // 3. 【关键】将Access Token存入Redis
        Claims accessClaims = jwtUtil.parseToken(accessToken);
        String jti = jwtUtil.getJti(accessClaims);
        String ip = getClientIp(httpRequest);

        TokenInfo tokenInfo = TokenInfo.builder()
                .userId(userId)
                .username(username)
                .role(role)
                .jti(jti)
                .issuedAt(System.currentTimeMillis())
                .loginIp(ip)
                .deviceInfo(httpRequest.getHeader("User-Agent"))
                .build();

        tokenService.storeAccessToken(accessToken, tokenInfo);

        return LoginResponse.builder()
                .accessToken(accessToken)
                .refreshToken(refreshToken)
                .tokenType("Bearer")
                .expiresIn(30 * 60L)  // 30分钟，秒
                .build();
    }

    /**
     * 登出——主动删除Redis中的Token
     */
    @PostMapping("/logout")
    public String logout(@RequestHeader("Authorization") String authHeader) {
        // 1. 从请求头提取Token
        String token = authHeader.startsWith("Bearer ")
                ? authHeader.substring(7) : authHeader;

        // 2. 解析JWT获取jti和userId
        Claims claims = jwtUtil.parseToken(token);
        String jti = jwtUtil.getJti(claims);
        Long userId = jwtUtil.getUserId(claims);

        // 3. 【关键】从Redis中删除该Token
        tokenService.revokeToken(jti, userId);

        // 4. 清除Spring Security上下文
        SecurityContextHolder.clearContext();

        return "已登出";
    }

    /**
     * 强制下线——踢出某个用户的所有设备
     */
    @PostMapping("/kick-out/{userId}")
    public String kickOut(@PathVariable Long userId) {
        tokenService.revokeAllUserTokens(userId);
        return "用户 " + userId + " 已被强制下线";
    }

    /**
     * 刷新Token
     */
    @PostMapping("/refresh")
    public LoginResponse refresh(@Valid @RequestBody RefreshRequest request,
                                  HttpServletRequest httpRequest) {
        String refreshToken = request.getRefreshToken();
        Claims claims = jwtUtil.parseToken(refreshToken);

        // 确认是Refresh Token
        if (!"refresh".equals(claims.get("type", String.class))) {
            throw new RuntimeException("请使用Refresh Token刷新");
        }

        Long userId = jwtUtil.getUserId(claims);

        // TODO: 从数据库查用户最新信息
        String username = "zhangsan";
        String role = "ROLE_USER";

        // 签发新的Access Token
        String newAccessToken = jwtUtil.createAccessToken(userId, username, role);
        String newRefreshToken = jwtUtil.createRefreshToken(userId);

        // 新Token存入Redis
        Claims newClaims = jwtUtil.parseToken(newAccessToken);
        String newJti = jwtUtil.getJti(newClaims);

        TokenInfo tokenInfo = TokenInfo.builder()
                .userId(userId)
                .username(username)
                .role(role)
                .jti(newJti)
                .issuedAt(System.currentTimeMillis())
                .loginIp(getClientIp(httpRequest))
                .build();

        tokenService.storeAccessToken(newAccessToken, tokenInfo);

        return LoginResponse.builder()
                .accessToken(newAccessToken)
                .refreshToken(newRefreshToken)
                .tokenType("Bearer")
                .expiresIn(30 * 60L)
                .build();
    }

    private String getClientIp(HttpServletRequest request) {
        String ip = request.getHeader("X-Forwarded-For");
        if (ip == null || ip.isEmpty()) {
            ip = request.getRemoteAddr();
        }
        return ip;
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
    private String tokenType;
    private Long expiresIn;
}

// 刷新Token请求
@Data
public class RefreshRequest {
    @NotBlank(message = "Refresh Token不能为空")
    private String refreshToken;
}
```

---

## 📊 五、三种方案完整对比

### 📊 5.1 维度对比表

```mermaid
flowchart TD
    classDef root fill:#1E88E5,stroke:#0D47A1,stroke-width:2px,color:#FFFFFF,font-weight:bold;
    classDef branch fill:#FFE082,stroke:#FFB300,stroke-width:2px,color:#5D4037,font-weight:bold;
    classDef leaf fill:#F5F5F5,stroke:#BDBDBD,stroke-width:1.5px,color:#212121;
    classDef highlight fill:#FFCCBC,stroke:#E64A19,stroke-width:1.5px,color:#D84315,font-weight:bold;

    ROOT[三种鉴权方案对比]

    ROOT --> PURE_JWT[纯JWT]
    PURE_JWT --> PJ1["验证方式: 仅签名+过期"]
    PURE_JWT --> PJ2["主动失效: ❌不支持"]
    PURE_JWT --> PJ3["性能: ⭐⭐⭐ 无IO"]
    PURE_JWT --> PJ4["扩展性: ⭐⭐⭐ 无状态"]
    PURE_JWT --> PJ5["适用: 低安全要求场景"]

    ROOT --> PURE_REDIS[纯Redis+Token]
    PURE_REDIS --> PR1["验证方式: 每次查Redis"]
    PURE_REDIS --> PR2["主动失效: ✅支持"]
    PURE_REDIS --> PR3["性能: ⭐ 每次IO"]
    PURE_REDIS --> PR4["扩展性: ⭐ 依赖Redis"]
    PURE_REDIS --> PR5["适用: 高安全内网系统"]

    ROOT --> HYBRID[JWT+Redis混合]
    HYBRID --> H1["验证方式: JWT签名+Redis检查"]
    HYBRID --> H2["主动失效: ✅支持"]
    HYBRID --> H3["性能: ⭐⭐ 一次Redis GET"]
    HYBRID --> H4["扩展性: ⭐⭐⭐ 无状态验证"]
    HYBRID --> H5["适用: 互联网生产环境"]
    HYBRID --> H6["Token可读: ✅ Payload含用户信息"]

    class ROOT root;
    class PURE_JWT,PURE_REDIS,HYBRID branch;
    class PJ1,PJ2,PJ3,PJ4,PJ5,PR1,PR2,PR3,PR4,PR5,H1,H2,H3,H4,H5,H6 leaf;
    class HYBRID,H1,H2,H3,H4,H5,H6 highlight;
```

### 📋 5.2 详细对比表

| 对比维度 | 纯 JWT | 纯 Redis + UUID Token | <span style="color:red">JWT + Redis（推荐）</span> |
|------|------|------|------|
| **认证方式** | 验证 JWT 签名 + exp | 完整查 Redis | JWT 签名验证（CPU）+ Redis 存活检查（IO） |
| **每次请求开销** | 微秒级（纯 CPU） | 毫秒级（Redis 网络 IO） | 毫秒级（Redis GET 一次） |
| **Token 可读性** | 高（Payload Base64 解码即可读） | 无（UUID 不含任何信息） | **高（JWT Payload 含完整用户信息）** |
| **主动失效** | <span style="color:red">❌ 无法实现</span> | <span style="color:red">✅ 删除 Redis Key</span> | <span style="color:red">✅ 删除 Redis Key</span> |
| **强制下线** | <span style="color:red">❌</span> | <span style="color:red">✅ 批量删 Key</span> | <span style="color:red">✅ 支持"踢出所有设备"</span> |
| **在线状态查询** | <span style="color:red">❌</span> | ✅ `KEYS token:*` | ✅ `auth:user:{userId}` 集合 |
| **水平扩展** | 天然支持（无状态） | 依赖共享 Redis | **JWT 部分无状态 + Redis 共享** |
| **Token 泄露应对** | 无法应对 | 立即删除 | 立即删除 |
| **Redis 故障降级** | 无影响 | <span style="color:red">完全不可用</span> | <span style="color:red">⚠️ 可降级为纯JWT模式</span> |

### ⚡ 5.3 性能开销分析

混合方案在纯 JWT 的基础上增加了一次 Redis GET 操作。这个开销在实际生产中的表现：

| 场景 | 单次请求增加延迟 | 影响 |
|------|:---:|------|
| Redis 本地 / 同机房 | 0.1 ~ 0.5 ms | 几乎无感知 |
| Redis 跨机房 | 1 ~ 3 ms | 有轻微影响，可接受 |
| Redis 使用 Pipeline / 连接池 | 分摊连接开销 | 推荐生产中开启连接池 |
| 使用本地缓存（Caffeine）+ Redis 双层 | 本地命中时无 IO | 高频用户的Token几乎无额外开销 |

> **生产优化建议**：如果对 Redis 延迟非常敏感，可以在 `TokenService` 中加一层本地缓存（Caffeine），缓存 Token 的 `jti → TokenInfo`，缓存时间设为 1 ~ 5 秒。这样同一 Token 在短时间内只需查一次 Redis。

---

## 🛡️ 六、Redis 故障时的降级策略

混合方案依赖 Redis，如果 Redis 宕机了怎么办？这是一个必须考虑的生产问题。

```mermaid
flowchart TD
    classDef startEnd fill:#F48FB1,stroke:#C2185B,stroke-width:2px,color:#212121,font-weight:bold;
    classDef condition fill:#E1BEE7,stroke:#7B1FA2,stroke-width:1.5px,color:#212121,font-weight:bold;
    classDef process fill:#F5F5F5,stroke:#9E9E9E,stroke-width:1.5px,color:#212121;
    classDef reject fill:#FFCDD2,stroke:#C62828,stroke-width:1.5px,color:#B71C1C,font-weight:bold;

    REQ([请求到达]) --> JWT_CHECK[JWT签名验证]
    JWT_CHECK --> JWT_OK{"JWT有效 ?"}
    JWT_OK -- 否 --> DENY([401])

    JWT_OK -- 是 --> REDIS_QUERY[查询Redis]
    REDIS_QUERY --> REDIS_OK{"Redis正常 ?"}

    REDIS_OK -- 是 --> EXISTS{"Token在Redis中 ?"}
    EXISTS -- 是 --> ALLOW([放行])
    EXISTS -- 否 --> REVOKED([401 Token已撤销])

    REDIS_OK -- 否(超时/连接失败) --> STRATEGY{"降级策略 ?"}
    STRATEGY -- 严格模式<br/>(银行/金融) --> DENY2([拒绝<br/>安全优先])
    STRATEGY -- 宽松模式<br/>(内容/资讯) --> ALLOW2([放行<br/>可用优先])

    class REQ,ALLOW,ALLOW2 startEnd;
    class JWT_OK,REDIS_OK,EXISTS,STRATEGY condition;
    class JWT_CHECK,REDIS_QUERY process;
    class DENY,DENY2,REVOKED reject;
```

降级策略的代码实现：

```java
@Component
public class JwtAuthenticationFilter extends OncePerRequestFilter {

    // ... 其他代码 ...

    @Override
    protected void doFilterInternal(...) {
        // ... JWT验证 ...

        // Redis检查（带降级）
        TokenInfo tokenInfo;
        try {
            tokenInfo = tokenService.validateAndGetTokenInfo(jti);
        } catch (Exception e) {
            // Redis不可用时的降级策略
            log.error("Redis异常，启用降级", e);
            if (authProperties.isStrictMode()) {
                // 严格模式：拒绝请求（金融、交易系统）
                handleAuthFailure(response, 503, "服务暂时不可用");
                return;
            } else {
                // 宽松模式：放行（JWT已通过签名验证）
                tokenInfo = TokenInfo.builder()
                    .userId(jwtUtil.getUserId(claims))
                    .username(jwtUtil.getUsername(claims))
                    .role(jwtUtil.getRole(claims))
                    .build();
            }
        }

        // ... 设置认证状态 ...
    }
}
```

配置项：

```yaml
auth:
  redis:
    fallback-mode: lenient    # strict=严格模式（Redis故障拒绝）
                              # lenient=宽松模式（Redis故障降级为纯JWT）
```

---

## 📝 七、生产环境额外建议

### 🔄 7.1 Token 刷新时的旧 Token 处理

当用户用 Refresh Token 刷新 Access Token 时，**建议立即撤销旧的 Access Token**，防止旧 Token 在有效期内被滥用：

```java
@PostMapping("/refresh")
public LoginResponse refresh(@RequestBody RefreshRequest request) {
    // ... 验证Refresh Token ...

    // 如果请求中携带了旧的Access Token，撤销它
    String oldAccessToken = request.getOldAccessToken();
    if (StringUtils.hasText(oldAccessToken)) {
        try {
            Claims oldClaims = jwtUtil.parseToken(oldAccessToken);
            String oldJti = jwtUtil.getJti(oldClaims);
            tokenService.revokeToken(oldJti, userId);
        } catch (Exception e) {
            // 旧Token可能已经过期，忽略
        }
    }

    // ... 签发新Token ...
}
```

### 🧹 7.2 定时清理 Redis 中的过期数据

虽然 Redis Key 设置了 TTL 会自动过期，但 `auth:user:{userId}` 集合中可能残留已过期的 `jti`。建议加一个定时任务做兜底清理：

```java
@Component
public class TokenCleanupTask {

    @Autowired
    private RedisTemplate<String, Object> redisTemplate;

    @Value("${auth.redis.key-prefix}")
    private String tokenKeyPrefix;

    @Value("${auth.redis.user-tokens-prefix}")
    private String userTokensPrefix;

    /**
     * 每天凌晨4点清理一次
     * 遍历所有用户的Token集合，删除Redis中已经不存在的jti引用
     */
    @Scheduled(cron = "0 0 4 * * ?")
    public void cleanExpiredJtiReferences() {
        Set<String> userKeys = redisTemplate.keys(userTokensPrefix + "*");
        if (userKeys == null) return;

        int cleaned = 0;
        for (String userKey : userKeys) {
            Set<Object> jtis = redisTemplate.opsForSet().members(userKey);
            if (jtis == null) continue;

            for (Object jtiObj : jtis) {
                String jti = jtiObj.toString();
                String tokenKey = tokenKeyPrefix + jti;
                // Token主记录不存在 → jti已过期，从集合中移除
                if (Boolean.FALSE.equals(redisTemplate.hasKey(tokenKey))) {
                    redisTemplate.opsForSet().remove(userKey, jti);
                    cleaned++;
                }
            }
        }
        log.info("Token清理完成，清理了 {} 条过期引用", cleaned);
    }
}
```

### 🔒 7.3 安全性增强清单

| 措施 | 说明 |
|------|------|
| 密钥定期轮换 | `jwt.secret` 定期更换，旧密钥签发的 Token 自然过期后下线旧密钥 |
| Token 绑定设备指纹 | `TokenInfo` 中存入 `User-Agent` / IP，敏感操作时校验是否匹配 |
| Refresh Token 存储在 HttpOnly Cookie | 防止 XSS 窃取 Refresh Token |
| 异地登录检测 | Redis 中对比同一用户的登录 IP，异常时告警 |
| 限制单用户最大登录设备数 | `auth:user:{userId}` 集合超过阈值时删除最旧的 Token |

---

## 🎯 八、总结

```mermaid
flowchart TD
    classDef startEnd fill:#F48FB1,stroke:#C2185B,stroke-width:2px,color:#212121,font-weight:bold;
    classDef process fill:#F5F5F5,stroke:#9E9E9E,stroke-width:1.5px,color:#212121;
    classDef highlight fill:#FFCCBC,stroke:#E64A19,stroke-width:1.5px,color:#D84315,font-weight:bold;
    classDef branch fill:#FFE082,stroke:#FFB300,stroke-width:2px,color:#5D4037,font-weight:bold;

    SUMMARY[(JWT+Redis<br/>混合鉴权)]
    SUMMARY --> WHY[为什么需要混合方案]
    WHY --> W1["纯JWT: Token签发后<br/>无法撤销"]
    WHY --> W2["纯Redis: 每次请求<br/>都查Redis,性能差"]

    SUMMARY --> HOW[混合方案如何实现]
    HOW --> H1["JWT加入jti<br/>作为Token唯一标识"]
    HOW --> H2["Redis存储<br/>auth:token:{jti} → TokenInfo<br/>TTL = JWT过期时间"]
    HOW --> H3["认证流程:<br/>①验证JWT签名<br/>②Redis GET jti<br/>③均通过→放行"]

    SUMMARY --> WHAT[获得了什么能力]
    WHAT --> WH1["✅ 主动撤销Token<br/>(登出/改密码/踢人)"]
    WHAT --> WH2["✅ 在线状态查询<br/>(用户几台设备在线)"]
    WHAT --> WH3["✅ JWT自解释性<br/>(Payload含用户信息)"]
    WHAT --> WH4["✅ 性能可控<br/>(一次Redis GET的开销)"]
    WHAT --> WH5["✅ Redis故障可降级<br/>(降级为纯JWT)"]

    class SUMMARY startEnd;
    class WHY,HOW,WHAT branch;
    class W1,W2,H1,H2,H3,WH1,WH2,WH3,WH4,WH5 process;
    class H2 highlight;
```

**一句话总结**：纯 JWT 解决了"高性能无状态认证"，纯 Redis + Token 解决了"主动控制 Token 生命周期"。JWT + Redis 混合方案通过 `jti` 作为桥梁，同时获得了 **JWT 的无状态验证能力** 和 **Redis 的有状态控制能力**，是当前企业生产环境中最推荐的鉴权架构。
