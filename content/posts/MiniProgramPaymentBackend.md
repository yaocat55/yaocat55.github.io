---
title: "小程序支付后端从零构建：wx.pay 全流程、幂等实践与客户端定位"
date: 2023-10-23T11:30:03+00:00
tags: ["微信支付", "小程序", "实践教程"]
categories: ["教程"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "没有商户号也能学会的支付后端：本文用 Java + Spring Boot 跑通 wx.pay 的统一下单、二次签名与异步回调，详解乐观锁、唯一索引与 Redis 令牌组成的三层幂等防御，并拆解客户端与后端在支付体系中的真实分工。"
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

# 支付后端从 0 到 1：流程、幂等和那位备胎

提起微信支付，不少后端新同学的第一反应是"这不就是调个 API 嘛"。真上手才发现，光一个异步回调就能把人折腾到怀疑人生：明明用户付了钱，订单状态却一直不更新；回调来了两次，积分发了双份；个人主体小程序连商户号都申请不下来，只能对着文档干瞪眼。

这篇文章把 wx.pay 的后端流程从头到尾拆开：登录拿 openid、统一下单换 prepay_id、二次签名、异步回调验签与解密，再到怎么用乐观锁把幂等做扎实。最后用一点篇幅聊聊"备胎信使"理论——搞明白客户端在支付里到底说了不算什么，很多困惑会迎刃而解。

> 📌 前置知识：会写 Spring Boot 接口，看得懂 SQL，理解基本的 HTTP 与 JSON。不需要任何支付经验，本文的代码保证从空项目能直接搭起来。

## 第 1 步 目标说明：这一篇到底讲什么

### 1.1 为什么写这篇文章

支付是少数几个"看起来简单、出错要命"的领域。某开发者的第一版支付代码只有一百多行，跑起来却发现三个大坑：

1. 客户端调起支付后立刻回调了 success，后端却还没收到微信的异步通知，订单一直挂在"待支付"；
2. 通知重试机制下同一个回调被处理了两次，用户积分翻倍；
3. 本地调得好好的，上线后微信的回调根本进不来——因为内网地址微信访问不了。

这三件事分别对应流程、幂等、回调三个话题，也是本文的主线。提前把这些想明白，能省下大把试错时间。

### 1.2 小程序开发的"三驾马车"

一个完整的小程序业务，后端主要跟三样东西打交道：

| 能力 | 前端 API | 后端职责 | 类比 |
|------|----------|----------|------|
| 身份识别 | ` wx.login ` | 用 code 换 openid，建立用户账号 | 进门刷脸 |
| 交易闭环 | ` wx.requestPayment ` | 统一下单、签名、回调处理 | 柜台结账 |
| 消息触达 | ` wx.requestSubscribeMessage ` + 服务端发送 | 存 access_token，发订阅消息 | 售后电话 |

三者独立又协作：登录建立身份，支付产生交易，订阅消息把交易结果送达用户。

### 1.3 本文核心议题

围绕上面三驾马车，重点回答四个问题：

- ` wx.pay ` 的完整后端流程是什么？预支付、二次签名、异步回调各是干什么的。
- 如何保证支付幂等，防止重复扣款、重复加积分？
- 客户端在支付中到底扮演什么角色？哪些事它说了不算？
- 个人开发者没有商户资质，怎么照样把后端逻辑练熟？

### 1.4 阅读本文的收获

读完你会得到一份可以直接抄的 Java 实现：登录接口、统一下单、二次签名、回调处理器，以及一套幂等的三层防御。还会得到一个重要认知：支付后端的核心逻辑与商户号无关，没资质也能先把逻辑写对，拿到商户号只是替换一个 API 地址的事。

## 第 2 步 前置条件：先认识小程序全家桶

动手写代码之前，先把小程序生态里后端需要打交道的接口盘一遍。大部分接口的流程都是同构的：前端拿一个"凭证"，交给后端，后端拿它去微信服务器换结果。

### 2.1 用户与账户：wx.login 与 getPhoneNumber

#### wx.login：身份的起点

` wx.login ` 是几乎所有小程序的第一行代码。它不返回用户信息，只返回一个临时登录凭证 ` code ` ，真正的用户身份要靠后端拿 code 去微信换。

```mermaid
flowchart TD
    classDef root fill:#0f172a,stroke:#3b82f6,stroke-width:2.5px,color:#bfdbfe,font-weight:bold;
    classDef process fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#e5e7eb;
    classDef data fill:#052e16,stroke:#16a34a,stroke-width:2px,color:#bbf7d0,font-weight:bold;
    classDef startEnd fill:#701a4c,stroke:#e11d48,stroke-width:2.5px,color:#fce7f3,font-weight:bold;

    subgraph client["小程序端"]
        C1([调用 wx.login]) --> C2[获得临时 code]
        C2 --> C3[wx.request 把 code 发给后端]
    end
    subgraph backend["后端服务器"]
        B1[接收 code] --> B2[拼接 appid + secret + code]
        B2 --> B3[调用 code2Session 接口]
        B3 -->|"校验 errcode == 0"| B4[(存储 openid 与 session_key)]
        B4 --> B5[生成业务 token 返回前端]
    end
    subgraph wechat["微信服务器"]
        W1[验证 code 一次性且有效]
    end
    C3 -->|"HTTP 携带 code"| B1
    B3 <-->|"HTTPS"| W1
    B5 -->|"token"| C1

    class C1,C3 client
    class B1,B2,B3,B5 process
    class B4 data
    class W1 startEnd
```

前端就三行：

```javascript
// 前端：小程序端
wx.login({
  success: (res) => {
    if (res.code) {
      wx.request({
        url: '/api/auth/login',
        method: 'POST',
        data: { code: res.code },
        success: (resp) => {
          // 拿到后端返回的业务 token，存起来后续请求带上
          getApp().globalData.token = resp.data.data;
        }
      });
    }
  }
});
```

后端收到 code 后，拼接 appid 和 appsecret 调微信的 ` code2Session ` 接口。接口地址固定是 ` https://api.weixin.qq.com/sns/jscode2session ` ，GET 请求：

```java
// 后端：封装微信接口调用
@Component
public class WechatApi {

    private final String APP_ID = "wx1234567890abcdef";    // 小程序 appid
    private final String APP_SECRET = "abc123def456";      // 小程序 appsecret，只在后端

    /**
     * 用临时 code 换取 openid 和 session_key。
     * 调用成功时返回 openid 与 session_key；
     * code 无效或过期时 errcode 非 0。
     */
    public Code2SessionResp code2Session(String code) {
        String url = "https://api.weixin.qq.com/sns/jscode2session"
                + "?appid=" + APP_ID
                + "&secret=" + APP_SECRET
                + "&js_code=" + code
                + "&grant_type=authorization_code";

        HttpClient client = HttpClient.newHttpClient();
        HttpRequest request = HttpRequest.newBuilder(URI.create(url)).GET().build();
        String json;
        try {
            json = client.send(request, HttpResponse.BodyHandlers.ofString()).body();
        } catch (Exception e) {
            throw new BizException("调用微信登录接口失败");
        }

        JSONObject obj = JSON.parseObject(json);
        if (obj.getInteger("errcode") != null && obj.getInteger("errcode") != 0) {
            // 常见 errcode 40029：code 无效；45011：频率限制
            throw new BizException("微信登录失败: " + obj.getString("errmsg"));
        }
        return new Code2SessionResp(obj.getString("openid"), obj.getString("session_key"));
    }
}
```

登录 Controller 里，拿到 openid 后先查库再建号，最后签发自己的业务 token（JWT 或 Redis session 都行）：

```java
@RestController
@RequestMapping("/api/auth")
@RequiredArgsConstructor
public class AuthController {

    private final WechatApi wechatApi;
    private final UserService userService;
    private final TokenService tokenService;

    @PostMapping("/login")
    public Result<String> login(@RequestBody LoginRequest req) {
        // 1. code 换 openid
        Code2SessionResp resp = wechatApi.code2Session(req.getCode());
        // 2. 查库或建号（以 openid 为业务主键）
        User user = userService.findOrCreateByOpenid(resp.getOpenid());
        // 3. 签发业务 token
        return Result.ok(tokenService.generate(user));
    }
}
```

关于返回的数据，有两点容易踩：

> ⚠️ 新手提示： ` session_key ` 不要返回给前端。它用来解密手机号等敏感数据，属于服务端机密，返回给前端等于把门钥匙挂在门上。同时 ` code ` 是一次性的，有效期只有 5 分钟，用一次作废，别缓存复用。

#### getPhoneNumber：解密手机号

需要用户手机号时，前端用 ` wx.login ` 重新拿 code 换新的 ` session_key ` ，再配合 ` getPhoneNumber ` 拿到加密的 ` encryptedData ` 和 ` iv ` 。后端用 ` session_key ` 做 AES 解密。注意流程顺序：**先 login 刷新 session_key，再解密手机号**，否则可能用旧密钥解新数据。

```java
// 解密微信加密数据：AES-128-CBC
public class WxBizDataCrypt {

    public static String decrypt(String sessionKey, String encryptedData, String iv) throws Exception {
        byte[] keyBytes = Base64.getDecoder().decode(sessionKey);
        byte[] ivBytes = Base64.getDecoder().decode(iv);
        byte[] cipherBytes = Base64.getDecoder().decode(encryptedData);

        Cipher cipher = Cipher.getInstance("AES/CBC/PKCS5Padding");
        SecretKeySpec keySpec = new SecretKeySpec(keyBytes, "AES");
        cipher.init(Cipher.DECRYPT_MODE, keySpec, new IvParameterSpec(ivBytes));
        String plain = new String(cipher.doFinal(cipherBytes), StandardCharsets.UTF_8);

        // 微信要求末尾带 appid 作完整性校验
        JSONObject obj = JSON.parseObject(plain);
        if (!APP_ID.equals(obj.getString("watermark").getString("appid"))) {
            throw new BizException("数据校验失败");
        }
        return obj.getString("phoneNumber");   // 例如 "13800138000"
    }
}
```

> ⚠️ 新手提示： ` getPhoneNumber ` 需要小程序完成微信认证（年费 300 元），个人主体不支持。认证前只能先做成"跳过手机号"，别让逻辑卡死。

#### 登录选型

小程序常见三种登录方案：一键登录（wx.login + getPhoneNumber）、纯手机号登录、账号密码登录。对多数业务，推荐第一种：wx.login 建立身份，getPhoneNumber 补手机号，最贴近微信生态，用户无感。

### 2.2 交易与支付：wx.requestPayment

交易是本文主角。前端拉起收银台的接口叫 ` wx.requestPayment ` ，它需要的五个参数全都由后端生成，前端拿到什么传什么，不能自己造：

```javascript
// 前端：参数由后端返回，原样传给 wx.requestPayment
wx.requestPayment({
  timeStamp: '1743000000',      // 秒级时间戳，字符串
  nonceStr: 'abc123def456',     // 随机字符串
  package: 'prepay_id=wx20260731143000123456789012345678',
  signType: 'RSA',              // APIv3 固定 RSA
  paySign: 'xxx...',            // 二次签名，防篡改的关键
  success: () => { console.log('支付成功'); },
  fail: (err) => { console.log('支付失败', err); }
});
```

后端的配套接口围绕一个核心：统一下单（微信官方的 ` JSAPI 下单 ` ），地址为 ` POST https://api.mch.weixin.qq.com/v3/pay/transactions/jsapi ` 。此外还有订单查询、退款、关闭订单等。整套流程详见第 3 步。

一个贯穿始终的细节是**金额单位是分**，且是整数：99.99 元写成 ` 9999 ` 。原因很朴素——浮点数运算会有精度误差，0.1 + 0.2 在二进制里都不精确，而钱不允许不精确。定好"所有金额传分"，前后端都省心。

### 2.3 消息触达：订阅消息

支付成功后给用户发个"已发货"之类的通知，走订阅消息。用户要先在页面里点一次订阅授权（ ` wx.requestSubscribeMessage ` ），后端才能给他发。后端发送需要两个前置：用户订阅过对应模板 + 有有效的 ` access_token ` 。

```java
// 发送订阅消息
public void sendSubscribeMsg(String openid, Map<String, Object> data) {
    String url = "https://api.weixin.qq.com/cgi-bin/message/subscribe/send"
            + "?access_token=" + getAccessToken();

    JSONObject body = new JSONObject();
    body.put("touser", openid);
    body.put("template_id", "tpl_456");
    body.put("page", "pages/order/detail");
    body.put("data", new JSONObject()
            .put("thing1", new JSONObject().put("value", "您的订单已发货"))
            .put("time2", new JSONObject().put("value", "2026-07-31 14:30")));

    httpPost(url, body.toString());
}
```

` access_token ` 有效期 2 小时，且同一小程序所有接口共用同一个 token，建议缓存并在过期前刷新，避免每次请求都去取：

```java
public String getAccessToken() {
    // Redis 缓存，key = wx:access_token，过期时间略小于 7200 秒
    String cached = redis.get("wx:access_token");
    if (cached != null) {
        return cached;
    }
    String url = "https://api.weixin.qq.com/cgi-bin/token?grant_type=client_credential"
            + "&appid=" + APP_ID + "&secret=" + APP_SECRET;
    String token = JSON.parseObject(httpGet(url)).getString("access_token");
    redis.setex("wx:access_token", 7000, token);
    return token;
}
```

### 2.4 辅助功能与选型

` chooseAddress ` 是纯前端接口，直接读微信全局维护的收货地址库，跨小程序共享，后端只负责接收存储，没有服务端调用：

```javascript
wx.chooseAddress({
  success: (res) => {
    console.log(res.userName, res.telNumber, res.provinceName);
  }
});
```

其余的"选择发票"、"获取用户信息"等接口，要么已过时（ ` wx.getUserInfo ` 改版成头像昵称填写），要么使用场景有限，暂不展开。

### 2.5 资质全景：个人 vs 企业

很多新手卡在资质上。先看清楚能力边界，能省掉一整天的白折腾：

| 能力 | 个人主体小程序 | 企业/个体工商户小程序 |
|------|:---:|:---:|
| ` wx.login ` 登录 | ✅ 可用 | ✅ 可用 |
| ` chooseAddress ` 地址 | ✅ 可用 | ✅ 可用 |
| ` getPhoneNumber ` 手机号 | ❌ 需认证 | ✅ 认证后可 |
| 订阅消息 | ❌ 需认证 | ✅ 认证后可 |
| ` wx.pay ` 支付 | ❌ 需商户号 | ✅ 开通商户号后可 |

企业主体需要：营业执照 + 每年 300 元认证费 + 开通微信支付商户号。申请路径：微信公众平台 → 微信支付 → 接入微信支付。

对学习阶段的建议：先把 wx.login 和支付后端逻辑练熟（逻辑与资质无关），等有企业资质了再把手机号、订阅消息、真实支付逐一打开。

### 2.6 术语速查表

下文代码里会反复出现这些词，先混个脸熟：

| 术语 | 含义 | 示例 | 备注 |
|------|------|------|------|
| AppID / AppSecret | 小程序身份标识 | ` wx1234567890abcdef ` / ` abc123... ` | 公众平台 → 开发管理 → 开发设置 |
| openid | 用户在某小程序下的唯一标识 | ` oUpF8uMuAJO_M2pxb1Q9zNjWeS6o ` | 后端换登录的主要产物 |
| unionid | 用户在开放平台下的唯一标识 | ` o6_bmasdasdsad6_2sgVt7hMZOPfL ` | 跨应用统一身份，需绑定开放平台 |
| session_key | 会话密钥，解密敏感数据 | ` tiihtNczf5v6AKRyjwEUhQ== ` | Base64，登录态失效即变 |
| access_token | 后端调微信 API 的凭证 | ` 94_abc123def456... ` | 7200 秒有效期，需缓存 |
| 商户号 MCHID | 微信支付商户身份 | ` 1900000109 ` | 商户平台 → 账户中心 |
| APIv2 密钥 | 旧版对称签名密钥 | ` 0123456789abcdef... ` （32 位） | 新商户默认用 APIv3 |
| APIv3 密钥 | 新版非对称签名 | 证书序列号 + PEM 私钥 | 本文默认 APIv3 |
| out_trade_no | 商户订单号 | ` ORDER_20260731_123456 ` | 商户自定义，全局唯一 |
| transaction_id | 微信支付单号 | ` 4200001234567890123456789012 ` | 微信生成，回调里拿 |
| prepay_id | 预支付会话标识 | ` wx20260731143000123456789012345678 ` | 统一下单返回的核心凭证 |

> 📌 前置知识：APIv3 与 APIv2 是微信支付的两代签名体系。v2 用 32 位字符串密钥做对称签名，v3 用证书 + 私钥做 RSA 非对称签名。新项目一律用 v3，下面的代码全部基于 v3。

### 2.7 环境搭建

#### Spring Boot 脚手架

后端用 Spring Boot 3.2 + JDK 17，最小依赖如下（建一个空 Spring 项目，把这一段贴进 pom.xml 即可）：

```xml
<dependencies>
    <!-- Web：写接口必需 -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-web</artifactId>
    </dependency>
    <!-- MyBatis Plus：操作数据库 -->
    <dependency>
        <groupId>com.baomidou</groupId>
        <artifactId>mybatis-plus-boot-starter</artifactId>
        <version>3.5.7</version>
    </dependency>
    <!-- MySQL 驱动 -->
    <dependency>
        <groupId>com.mysql</groupId>
        <artifactId>mysql-connector-j</artifactId>
        <scope>runtime</scope>
    </dependency>
    <!-- Redis：令牌、access_token 缓存 -->
    <dependency>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-starter-data-redis</artifactId>
    </dependency>
    <!-- JSON：解析微信请求/响应 -->
    <dependency>
        <groupId>com.alibaba</groupId>
        <artifactId>fastjson2</artifactId>
        <version>2.0.51</version>
    </dependency>
    <dependency>
        <groupId>org.projectlombok</groupId>
        <artifactId>lombok</artifactId>
        <optional>true</optional>
    </dependency>
</dependencies>
```

> ⚠️ 新手提示：微信 APIv3 的签名与验签只依赖 JDK 自带的 ` java.security ` 和 ` javax.crypto ` ，不需要额外装加密库。本文刻意不用微信官方 SDK，把签名、解密的每一步都摊开给你看，这样出问题才好排查。生产环境想省事可以直接换官方 SDK。

#### 微信开发者工具

小程序端不需要真机也能联调：下载微信开发者工具，导入项目，在"详情 → 本地设置"里勾选"不校验合法域名"。这样本地接口（如 ` http://localhost:8080 ` ）就能直接访问，免去先配 HTTPS 域名的麻烦。

#### 内网穿透

支付回调要求 notify_url 必须公网可达，但开发环境在本地。两种常见解法：

| 工具 | 用法 | 特点 |
|------|------|------|
| ngrok | ` ngrok http 8080 ` | 免费版生成临时域名，重启会变 |
| natapp | ` natapp -authtoken=xxx ` | 需购买隧道，域名稳定，可配自定义域名 |

启动后把生成的外网地址（形如 ` https://abc.ngrok.io ` ）填到统一下单的 ` notify_url ` 里。回调通知会先到穿透工具，再转发到本地 8080，联调体验和线上几乎一致。

## 第 3 步 分步实践：wx.pay 全流程深度解析

到了本文的重头戏。先看全局时序，再拆成"统一下单 → 二次签名 → 异步回调"三步，每步配可直接运行的代码。

### 3.1 完整时序图：从用户点击到回调完成

支付涉及三个角色：小程序端（客户端）、你的后端、微信服务器。全程分三个阶段：预支付、调起支付、结果通知。

```mermaid
flowchart TD
    classDef startEnd fill:#701a4c,stroke:#e11d48,stroke-width:2.5px,color:#fce7f3,font-weight:bold;
    classDef root fill:#0f172a,stroke:#3b82f6,stroke-width:2.5px,color:#bfdbfe,font-weight:bold;
    classDef process fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#e5e7eb;
    classDef data fill:#052e16,stroke:#16a34a,stroke-width:2px,color:#bbf7d0,font-weight:bold;
    classDef condition fill:#2a1147,stroke:#a855f7,stroke-width:2px,color:#ede9fe,font-weight:bold;
    classDef reject fill:#450a0a,stroke:#dc2626,stroke-width:2px,color:#fecaca,font-weight:bold;

    subgraph client["小程序端"]
        C1[提交订单\ngoodsId 101\nquantity 2]
        C2[收到 prepay 参数]
        C3[wx.requestPayment 拉起收银台]
        C4[用户输入密码]
        C5[同步回调 success]
    end
    subgraph backend["后端"]
        B1[校验订单 生成 out_trade_no]
        B2[调用统一下单 API]
        B3[生成二次签名 paySign]
        B4[接收异步回调]
        B5{验签与解密}
        B6[幂等处理 更新订单状态]
        B7{处理成功}
    end
    subgraph wechat["微信服务器"]
        W1[返回 prepay_id 与 trade_type]
        W2[校验金额 扣除用户资金]
        W3[发送异步回调通知]
    end

    C1 -->|"1. 提交订单"| B1
    B1 -->|"2. 生成订单"| B2
    B2 -->|"3. 下单请求"| W1
    W1 -->|"4. prepay_id"| B2
    B2 -->|"5. prepay_id"| B3
    B3 -->|"6. 返回参数"| C2
    C2 -->|"7. 调起支付"| C3
    C3 --> C4
    W2 -->|"8. 异步通知"| B4
    B4 --> B5
    B5 -->|"通过"| B6
    B6 --> B7
    B7 -->|"成功 返回 SUCCESS"| W3
    W3 -->|"微信停止重试"| B4
    C4 -->|"11. 同步 success"| C5

    class C1,C2,C3,C4,C5 client
    class B1,B2,B3,B4,B6 process
    class B5,B7 condition
    class W1,W2,W3 startEnd
```

时序拆解（对应图中编号）：

| 编号 | 阶段 | 动作 | 谁发起 | 谁处理 |
|:---:|------|------|:---:|------|
| 1 ~ 2 | 预支付 | 小程序提交订单，后端校验并落库 | 小程序端 | 后端 |
| 3 ~ 5 | 预支付 | 后端调统一下单，拿 prepay_id，生成二次签名 | 后端 | 微信/后端 |
| 6 ~ 7 | 调起支付 | 后端返回参数，小程序拉起收银台 | 后端 | 小程序端 |
| 8 ~ 10 | 结果通知 | 微信异步回调，后端验签解密、幂等更新、应答 | 微信 | 后端 |
| 11 | 结果通知 | 小程序拿同步结果（仅供参考） | 微信客户端 | 小程序端 |

几个关键点先记住，后面逐一展开：

- 用户的钱是微信直接扣的，后端全程不碰密码；
- **支付结果以微信的异步回调为准**，小程序端的 success 回调只是"客户端视角"，可能滞后、可能被风控推翻；
- 统一下单和回调里，后端和微信之间是"一签一验"：下单用商户私钥签名，回调用微信平台证书验签。

### 3.2 Step 1：统一下单

统一下单（JSAPI 下单）是支付的第一枪：后端拿订单信息换一个 ` prepay_id ` 。这个接口的完整调用是"签名 + HTTP + 解析"三件套，最容易被忽略的恰恰是签名。

#### 3.2.1 APIv3 签名规则

微信 APIv3 要求每个请求带一个 HTTP Header，内容是对"请求方法 + 路径 + 时间戳 + 随机串 + 请求体"做 RSA 签名的结果。签名串的格式是：

```text
POST
/v3/pay/transactions/jsapi
1743000000
nonce_str
{ "appid": "wx1234567890", "mchid": "1900000109", ... }
```

注意： ` POST ` 和路径之后没有空行，请求体那行后面有一个 ` \n ` 结尾。用商户私钥对这个串做 SHA256 的 RSA 签名，然后把签名放进 ` Authorization ` Header。完整的 Header 长这样：

```http
Authorization: WECHATPAY2-SHA256-RSA2048 mchid="1900000109",nonce_str="abc123def456",timestamp="1743000000",signature="xxx"
```

用 Java 实现签名工具类，这个类后面二次签名、验签都会复用：

```java
// 签名工具：统一下单签名、二次签名、回调验签共用
@Component
public class WxPaySign {

    /** 商户私钥：PEM 内容从商户平台下载，妥善保管，严禁提交到 git */
    private final PrivateKey merchantPrivateKey;

    /** 平台证书：用于验签微信的回调，微信会定期更换，需留意更新 */
    private final PublicKey platformPublicKey;

    public WxPaySign() throws Exception {
        this.merchantPrivateKey = loadPrivateKey("apiclient_key.pem");
        this.platformPublicKey = loadPublicKey("wechatpay_public_key.pem");
    }

    /** 读取 PEM 文件里的 RSA 私钥 */
    private PrivateKey loadPrivateKey(String pemPath) throws Exception {
        String content = readAll(pemPath)
                .replace("-----BEGIN PRIVATE KEY-----", "")
                .replace("-----END PRIVATE KEY-----", "")
                .replaceAll("\\s", "");
        byte[] der = Base64.getDecoder().decode(content);
        PKCS8EncodedKeySpec spec = new PKCS8EncodedKeySpec(der);
        return KeyFactory.getInstance("RSA").generatePrivate(spec);
    }

    /** 读取 PEM 文件里的平台公钥 */
    private PublicKey loadPublicKey(String pemPath) throws Exception {
        String content = readAll(pemPath)
                .replace("-----BEGIN PUBLIC KEY-----", "")
                .replace("-----END PUBLIC KEY-----", "")
                .replaceAll("\\s", "");
        byte[] der = Base64.getDecoder().decode(content);
        X509EncodedKeySpec spec = new X509EncodedKeySpec(der);
        return KeyFactory.getInstance("RSA").generatePublic(spec);
    }

    /** 构造 APIv3 请求签名串：method + 路径 + 时间戳 + 随机串 + 请求体 */
    public String buildSignMessage(String method, String urlPath, String timestamp,
                                   String nonceStr, String body) {
        return method + "\n" + urlPath + "\n" + timestamp + "\n" + nonceStr + "\n" + body + "\n";
    }

    /** 用商户私钥做 SHA256withRSA 签名，输出 Base64 */
    public String sign(String message) throws Exception {
        Signature signature = Signature.getInstance("SHA256withRSA");
        signature.initSign(merchantPrivateKey);
        signature.update(message.getBytes(StandardCharsets.UTF_8));
        return Base64.getEncoder().encodeToString(signature.sign());
    }

    /** 组装 Authorization Header */
    public String buildAuthorization(String method, String urlPath, String body) throws Exception {
        String timestamp = String.valueOf(System.currentTimeMillis() / 1000);
        String nonceStr = UUID.randomUUID().toString().replace("-", "");
        String message = buildSignMessage(method, urlPath, timestamp, nonceStr, body);
        String signature = sign(message);
        return "WECHATPAY2-SHA256-RSA2048 mchid=\"" + mchid
                + "\",nonce_str=\"" + nonceStr
                + "\",timestamp=\"" + timestamp
                + "\",signature=\"" + signature + "\"";
    }
}
```

> 📌 前置知识：RSA 是"公钥加密、私钥签名"的非对称体系。你请求微信时用**你的私钥**签名，微信用你的**公钥/证书**验签；反过来微信发回调时用**微信的私钥**签名，你拿**微信的平台证书**验签。方向别搞反，这是新手最常见的翻车点。

#### 3.2.2 统一下单的请求与响应

请求体是最容易出错的，字段名大小写、单位都必须对齐：

```json
{
  "appid": "wx1234567890",
  "mchid": "1900000109",
  "description": "测试商品",
  "out_trade_no": "ORDER_20260731_143000_12345",
  "notify_url": "https://abc.ngrok.io/api/pay/callback",
  "amount": {
    "total": 9999,
    "currency": "CNY"
  },
  "payer": {
    "openid": "oUpF8uMuAJO_M2pxb1Q9zNjWeS6o"
  }
}
```

| 字段 | 含义 | 示例 | 注意 |
|------|------|------|------|
| ` out_trade_no ` | 商户订单号 | ` ORDER_20260731_143000_12345 ` | 全局唯一，幂等的基础 |
| ` amount.total ` | 金额，单位分 | ` 9999 ` | 整数，表示 99.99 元 |
| ` notify_url ` | 回调地址 | ` https://abc.ngrok.io/... ` | 公网 HTTPS |
| ` payer.openid ` | 付款人 openid | ` oUpF8u... ` | 下单前先登录拿到 |

调用代码（HTTP 客户端 + 签名 + 解析）：

```java
// 统一下单
public String createOrder(Order order, String openid) throws Exception {
    String urlPath = "/v3/pay/transactions/jsapi";
    String body = buildJsapiBody(order, openid);   // 组上表 JSON

    // 1. 构造签名 Header
    String authorization = wxPaySign.buildAuthorization("POST", urlPath, body);

    // 2. 发送请求
    HttpClient client = HttpClient.newHttpClient();
    HttpRequest request = HttpRequest.newBuilder()
            .uri(URI.create("https://api.mch.weixin.qq.com" + urlPath))
            .header("Authorization", authorization)
            .header("Content-Type", "application/json")
            .header("Accept", "application/json")
            .header("Wechatpay-Serial", platformCertSerialNo)  // 平台证书序列号
            .POST(HttpRequest.BodyPublishers.ofString(body, StandardCharsets.UTF_8))
            .build();
    HttpResponse<String> resp = client.send(request, HttpResponse.BodyHandlers.ofString());

    // 3. 非 2xx 说明下单失败，解析错误码
    if (resp.statusCode() != 200) {
        JSONObject err = JSON.parseObject(resp.body());
        // 常见：ORDER_PAID（订单已支付）、PARAM_ERROR、NO_AUTH（无权限）
        throw new BizException("下单失败: " + err.getString("message"));
    }

    // 4. 响应里只有两个关键字段：prepay_id 和 trade_type
    JSONObject respJson = JSON.parseObject(resp.body());
    return respJson.getString("prepay_id");   // 例如 wx20260731143000123456789012345678
}
```

> ⚠️ 新手提示：响应体里没有 ` return_code ` / ` result_code ` 这对老概念——那是 APIv2 时代的字段。v3 的规则更直接：HTTP 状态码 2xx 代表请求成功，非 2xx 时 body 里是 ` code ` + ` message ` 的错误信息。

拿到 ` prepay_id ` 之后，**订单还没被支付**。它只是"你向微信申请了一个支付会话"，真正扣钱要等用户在小程序里完成支付。

### 3.3 Step 2：生成二次签名（paySign）

` prepay_id ` 不能直接给前端用，还要拿它再签一次名。原因是： ` wx.requestPayment ` 需要五个参数，其中 ` package ` 是 ` prepay_id=xxx ` ，而 ` timeStamp ` 、 ` nonceStr ` 、 ` paySign ` 必须由后端现算，前端如果自己瞎编参数，微信验签必然失败。这层"二次签名"是防篡改的关键——它把金额、订单号这些信息"焊死"在签名里，改任何一个字节签名就失效。

二次签名的消息串与下单不同，格式是：

```text
appId=wx1234567890
timeStamp=1743000000
nonceStr=abc123def456
package=prepay_id=wx20260731143000123456789012345678
```

每行是 ` key=value ` ，没有多余的空行和换行分隔，直接拼接。签名算法和下单一致（SHA256withRSA），只是签的是这段不同的消息。

```java
// 二次签名：返回给 wx.requestPayment 的五个参数
public Map<String, String> buildPaySign(String appId, String prepayId) throws Exception {
    String timestamp = String.valueOf(System.currentTimeMillis() / 1000);
    String nonceStr = UUID.randomUUID().toString().replace("-", "").substring(0, 16);
    String packageStr = "prepay_id=" + prepayId;

    // 注意：与下单签名串不同，这里每行是 key=value
    String message = "appId=" + appId + "\n"
            + "timeStamp=" + timestamp + "\n"
            + "nonceStr=" + nonceStr + "\n"
            + "package=" + packageStr + "\n";

    String paySign = wxPaySign.sign(message);

    Map<String, String> params = new LinkedHashMap<>();
    params.put("timeStamp", timestamp);
    params.put("nonceStr", nonceStr);
    params.put("package", packageStr);
    params.put("signType", "RSA");
    params.put("paySign", paySign);
    return params;
}
```

> ⚠️ 新手提示： ` timeStamp ` 是**秒级**时间戳（10 位），不是毫秒级的 13 位。前端 ` Date.now() ` 出来的是毫秒，别直接塞进去。这也是一个经典排错点：报 ` INVALID_REQUEST ` 十有八九是这里。

返回给前端的完整 JSON：

```json
{
  "timeStamp": "1743000000",
  "nonceStr": "abc123def456",
  "package": "prepay_id=wx20260731143000123456789012345678",
  "signType": "RSA",
  "paySign": "MIIBlQ...Base64 签名结果..."
}
```

前端拿到直接透传给 ` wx.requestPayment ` 。**整个流程里，前端唯一需要做判断的是"什么时候调起支付"，而不是"支付参数长什么样"**。

### 3.4 Step 3：处理异步回调

用户付完钱，微信会向 ` notify_url ` 发一个 POST 通知。这是整个流程里最容易出错、也最不能出错的一环。

#### 3.4.1 回调请求长什么样

请求体是加密的， ` resource.ciphertext ` 里才是真实数据：

```json
{
  "id": "EVT_123456",
  "create_time": "2026-07-31T14:30:00+08:00",
  "resource_type": "encrypt-resource",
  "event_type": "TRANSACTION.SUCCESS",
  "summary": "支付成功",
  "resource": {
    "original_type": "transaction",
    "algorithm": "AEAD_AES_256_GCM",
    "ciphertext": "加密的支付结果数据...",
    "associated_data": "transaction",
    "nonce": "abc123"
  }
}
```

解密要用 **APIv3 密钥**（不是商户私钥，也不是平台证书）对 ` ciphertext ` 做 AES-256-GCM 解密， ` associated_data ` 和 ` nonce ` 是 GCM 模式的参数。解密后的明文才是能用的数据：

```json
{
  "out_trade_no": "ORDER_20260731_123456",
  "transaction_id": "4200001234567890123456789012",
  "trade_type": "JSAPI",
  "trade_state": "SUCCESS",
  "amount": { "total": 9999, "currency": "CNY" },
  "success_time": "2026-07-31T14:30:00+08:00",
  "payer": { "openid": "oUpF8u..." }
}
```

#### 3.4.2 验签与解密

验签、解密、幂等处理，顺序一步都不能乱。验签防止伪造回调（如果校验通过，才代表这条通知真的是微信发的）；解密把加密数据还原成明文。

```java
// 回调处理器：验签 -> 解密 -> 幂等更新
@RestController
@RequestMapping("/api/pay")
@RequiredArgsConstructor
public class PayCallbackController {

    private final WxPaySign wxPaySign;
    private final OrderService orderService;

    @PostMapping("/callback")
    public String callback(@RequestBody String rawBody,
                           @RequestHeader("Wechatpay-Serial") String serial,
                           @RequestHeader("Wechatpay-Signature") String signature,
                           @RequestHeader("Wechatpay-Timestamp") String timestamp,
                           @RequestHeader("Wechatpay-Nonce") String nonce) {

        // 1. 验签：用微信平台公钥校验签名，防伪造
        //    消息串格式：timestamp\nnonce\nrawBody\n
        String message = timestamp + "\n" + nonce + "\n" + rawBody + "\n";
        boolean valid = wxPaySign.verifyPlatform(message, signature);
        if (!valid) {
            log.warn("回调验签失败");
            return failure();  // 返回失败，微信会重试
        }

        // 2. 解密：拿到明文支付结果
        JSONObject resource = JSON.parseObject(rawBody)
                .getJSONObject("resource");
        String ciphertext = resource.getString("ciphertext");
        String associatedData = resource.getString("associated_data");
        String nonceStr = resource.getString("nonce");
        String plain = decryptAesGcm(apiV3Key, ciphertext, associatedData, nonceStr);

        JSONObject data = JSON.parseObject(plain);
        String outTradeNo = data.getString("out_trade_no");
        String transactionId = data.getString("transaction_id");
        String tradeState = data.getString("trade_state");
        Integer totalFee = data.getJSONObject("amount").getInteger("total");

        // 3. 只处理成功态；其他状态直接应答成功（没必要重试）
        if (!"SUCCESS".equals(tradeState)) {
            return success();
        }

        // 4. 幂等更新（核心，见第 4 步）：乐观锁 + 唯一索引
        boolean first = orderService.handlePaid(outTradeNo, transactionId, totalFee);
        if (first) {
            // 5. 业务处理：扣库存、加积分、发订阅消息
            orderService.postPaidBusiness(outTradeNo);
        }
        return success();
    }

    /** 应答成功：HTTP 200 + 特定 body，微信收到后停止重试 */
    private String success() {
        return "{\"code\":\"SUCCESS\",\"message\":\"成功\"}";
    }

    /** 应答失败：返回非 2xx，微信按频率递增重试（最多 15 次） */
    private String failure() {
        throw new BizException("处理失败");
    }
}
```

AES-256-GCM 解密的具体实现：

```java
// AES-256-GCM 解密：APIv3 回调数据专用
private String decryptAesGcm(String apiV3Key, String ciphertext,
                             String associatedData, String nonce) throws Exception {
    byte[] key = apiV3Key.getBytes(StandardCharsets.UTF_8);  // 32 位密钥
    byte[] cipherBytes = Base64.getDecoder().decode(ciphertext);

    Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
    SecretKeySpec keySpec = new SecretKeySpec(key, "AES");
    GCMParameterSpec spec = new GCMParameterSpec(128,
            nonce.getBytes(StandardCharsets.UTF_8));
    cipher.init(Cipher.DECRYPT_MODE, keySpec, spec);
    if (associatedData != null && !associatedData.isEmpty()) {
        cipher.updateAAD(associatedData.getBytes(StandardCharsets.UTF_8));
    }
    return new String(cipher.doFinal(cipherBytes), StandardCharsets.UTF_8);
}
```

> ⚠️ 新手提示：**验签失败不能把 body 里的 ` ciphertext ` 拿来解密直接当结果用**。平台证书验证的是"这条通知确实是微信发的"，如果跳过它，任何人都能往你的回调接口 POST 一个假的"支付成功"，订单就白发货了。

#### 3.4.3 应答规则与重试

回调处理完必须给微信一个明确的应答，这决定了微信是否重试：

| 应答 | HTTP 状态 | Body | 微信行为 |
|------|:---:|------|----------|
| 处理成功 | 200 | ` {"code":"SUCCESS","message":"成功"} ` | 停止重试 |
| 处理失败 | 非 2xx | 任意 | 递增间隔重试 |

微信最多重试 15 次，间隔递增：15s、15s、30s、3m、10m、20m、30m、30m、30m、60m、3h、3h、3h、6h、6h。所以幂等性处理尤其重要——同一个回调会来很多次，每次都必须无副作用地应答"已处理"。

> ⚠️ 新手提示：回调处理要**在 5 秒内返回响应**，超过会被视为失败并重试。所以耗时的业务动作（发消息、调第三方）不要放在应答之前同步执行，可以先更新订单状态、立即应答，再把"发消息"丢进消息队列或异步线程去干。这也是为什么上面代码把"幂等更新"和"业务处理"拆成了两步。

### 3.5 与 App 支付的核心差异

小程序支付和 App 支付（支付宝/微信 App SDK）后端逻辑 90% 相同，差异主要在客户端侧：

| 维度 | App 支付（SDK 模式） | 小程序支付 |
|------|----------------------|------------|
| 统一下单 | 后端换 prepay_id | 后端换 prepay_id（相同） |
| 异步回调 | 后端接收验签（相同） | 后端接收验签（相同） |
| 第三方 SDK | 集成支付宝 SDK / 微信 SDK | 无，直接 ` wx.requestPayment ` |
| 二次签名 | SDK 内部处理 | 后端生成后传给前端 |
| 调起方式 | ` AlipayClient.pay() ` / ` WXApi.sendReq() ` | ` wx.requestPayment(...) ` |
| 降级能力 | 无 App 时降级 H5 | 不支持降级 |

再看应用内支付组件：支付宝现在支持在 App 内弹浮层支付，无感跳转；微信仍会跳微信 App，但跳转很迅速。本质都一样——**支付界面是支付平台渲染的封闭黑盒**，移动端拿到什么付什么，无法改写。

### 3.6 客户端到底是什么角色：备胎信使

把第 3 步整套流程走完，一个反直觉的事实浮现出来：**客户端（App/小程序）在整个支付里几乎不承担任何安全职责**。

- 客户端只负责传话：提交订单、调起支付、把结果告诉用户；
- 金额防篡改靠后端签名，密码校验靠支付平台，客户端两头都不沾；
- 支付结果以异步回调为准，客户端拿到的 success 只是"前端视角"，后端才是最终裁判。

用一句话概括：客户端是"备胎信使"，后端是"定海神针"。搞清楚这个定位，就能理解为什么所有核心逻辑都必须放后端——用户密码输入框是微信客户端渲染的，小程序连截屏都做不到，安全就在这一层层的"不信任"里建立起来。这部分在第 6 步再展开。

## 第 4 步 深入细节：如何优雅地保证幂等性

### 4.1 什么是幂等性

幂等（Idempotent）的定义很朴素：**同一个请求被处理多次，产生的结果与处理一次完全相同**。

支付场景把它翻译成人话：微信回调来了 3 次，订单只从"待支付"变"已支付"一次，积分只加一次，发货通知只发一次。任何一次重复处理造成副作用，都是事故。

为什么微信会重复回调？网络抖动、你的服务临时不可用、应答超时，任何一个原因都会触发微信的重试机制。所以"回调只来一次"是幻觉，**回调一定重试**才是需要接受的前提。

### 4.2 四种方案深度剖析

#### 4.2.1 分布式锁

原理：对订单号加一把 Redis 锁（SETNX），拿到锁的处理，拿不到的拒绝。逻辑直白：

```java
// 分布式锁：Redis SETNX + 过期时间
String lockKey = "pay:lock:" + outTradeNo;
Boolean locked = stringRedisTemplate.opsForValue()
        .setIfAbsent(lockKey, "1", Duration.ofSeconds(30));
if (Boolean.TRUE.equals(locked)) {
    try {
        doPay();
    } finally {
        stringRedisTemplate.delete(lockKey);   // 记得释放
    }
} else {
    throw new BizException("订单正在处理中，请勿重复提交");
}
```

- 优点：通用性强，能挡住复杂的并发竞争；
- 缺点：每次支付都要打一次 Redis，网络 IO 开销不小；锁过期时间没设好还会出现"锁提前失效"的边界问题；
- 结论：支付场景下有点杀鸡用牛刀。它解决的是"多线程抢同一个资源"的问题，而支付回调的场景是"同一个回调重复到达"，有更轻的办法。

#### 4.2.2 数据库唯一索引

原理：给支付流水表建唯一索引，处理回调时先插入一条流水，插入冲突就说明这条订单已经处理过了。

```sql
CREATE UNIQUE INDEX uk_pay_record_out_trade_no
    ON pay_record (out_trade_no);
```

```java
try {
    payRecordMapper.insert(record);   // 主键冲突会抛 DuplicateKeyException
    doPay();
} catch (DuplicateKeyException e) {
    log.info("流水已存在，重复回调，忽略处理");
    return "已处理";
}
```

- 优点：数据库 ACID 兜底，最可靠；
- 缺点：每笔支付多一次 Insert IO；流水表高频写入，批量插入时有压力；
- 结论：可靠但非最优。它适合做"日志记录、支付流水"这种天然具备"一次写入"语义的表，作为兜底层很合适。

#### 4.2.3 乐观锁（状态机）—— 最推荐

原理：把订单状态当作版本号。 ` UPDATE ` 时在 ` WHERE ` 里带上"当前状态必须是 PENDING"，数据库行锁保证只有一个更新能成功，再根据"影响行数"判断是谁抢到了这次处理权。

```sql
-- 乐观锁：只有状态还是 PENDING 时才能更新为 PAID
-- 影响行数 = 1 说明这次更新生效；= 0 说明订单已是其他状态，重复回调
UPDATE orders
SET status = 'PAID',
    pay_time = NOW(),
    transaction_id = '4200001234567890123456789012'
WHERE out_trade_no = 'ORDER_20260731_123456'
  AND status = 'PENDING';
```

```java
// MyBatis：乐观锁更新，返回影响行数
int rows = orderMapper.updateStatusToPaid(outTradeNo, transactionId);
if (rows == 1) {
    // 第一次处理：更新成功，可以放心做后续业务
    doBusiness();
    log.info("订单 {} 首次处理为已支付", outTradeNo);
} else {
    // 重复回调：订单已是 PAID，直接应答成功，无副作用
    log.warn("订单 {} 已处理，重复回调，忽略", outTradeNo);
    return "SUCCESS";
}
```

对应 Mapper XML：

```xml
<update id="updateStatusToPaid">
    UPDATE orders
    SET status = 'PAID',
        pay_time = NOW(),
        transaction_id = #{transactionId}
    WHERE out_trade_no = #{outTradeNo}
      AND status = 'PENDING'
</update>
```

这个方案的巧妙之处：**更新状态这件事本身就是幂等判定**。谁先把状态从 PENDING 改成 PAID，谁就赢得了处理权；后面来的都看到状态已是 PAID，自然知道"不用再干"。一次 Update 同时完成了"改状态"和"判定幂等"两件事，没有额外开销。

- 优点：性能最高，一次 SQL 搞定，天然防并发；
- 缺点：只适用于"状态单向流转"的场景；
- 结论：支付回调场景的最优解。 ` PENDING → PAID ` 是一次性的单向变更，正好卡在乐观锁的能力范围内。

#### 4.2.4 Redis 令牌机制

原理：下单时生成一次性 Token 存 Redis，支付时删除它，删成功了才允许处理。删除的原子性（DEL 成功 = 1）保证"这个订单只能被处理一次"。

```java
// 下单时：生成一次性令牌
String token = UUID.randomUUID().toString();
stringRedisTemplate.opsForValue()
        .set("pay:token:" + token, outTradeNo, Duration.ofMinutes(5));

// 支付时：删除令牌，删成功才放行
Long deleted = stringRedisTemplate.opsForValue()
        .getOperations().execute((RedisCallback<Long>) conn ->
                conn.del(("pay:token:" + token).getBytes()));
if (deleted != null && deleted == 1) {
    doPay();
} else {
    throw new BizException("请勿重复支付");
}
```

- 优点：内存级操作，性能极高，还能顺带防止"按钮被连点"；
- 缺点：无法保证绝对原子。极端场景下会误判：删 Token 成功 → JVM GC 暂停 → 用户又点了一次 → Token 已删被拒 → GC 恢复后订单已创建但用户以为失败；
- 结论：适合做前置拦截（提升体验），不能单独当资金安全防线。

### 4.3 方案横向对比

| 方案 | 实现难度 | 性能开销 | 可靠性 | 适用场景 |
|------|:---:|:---:|:---:|------|
| 分布式锁 | 中 | 高 | 高 | 复杂资源竞争 |
| 唯一索引 | 低 | 中 | 最高 | 日志、支付流水 |
| 乐观锁 | 低 | 极低 | 高 | 订单状态流转 |
| Redis 令牌 | 中 | 极低 | 中 | 前置拦截、防重复点击 |

### 4.4 最佳实践：三层防御体系

单个方案各有短板，生产上把它们叠起来，各管一段：

```mermaid
flowchart TD
    classDef startEnd fill:#701a4c,stroke:#e11d48,stroke-width:2.5px,color:#fce7f3,font-weight:bold;
    classDef condition fill:#2a1147,stroke:#a855f7,stroke-width:2px,color:#ede9fe,font-weight:bold;
    classDef process fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#e5e7eb;
    classDef data fill:#052e16,stroke:#16a34a,stroke-width:2px,color:#bbf7d0,font-weight:bold;
    classDef reject fill:#450a0a,stroke:#dc2626,stroke-width:2px,color:#fecaca,font-weight:bold;
    classDef highlight fill:#431407,stroke:#ea580c,stroke-width:2px,color:#fed7aa,font-weight:bold;

    A[用户点击支付] --> B{第一层 按钮防抖}
    B -->|"禁用按钮 loading"| C{第二层 Redis 令牌}
    C -->|"DEL 成功"| D{第三层 乐观锁}
    C -->|"Token 不存在"| E[拒绝重复请求]
    D -->|"影响行数 = 1"| F[更新为 PAID 执行业务]
    D -->|"影响行数 = 0"| G[订单已处理 直接应答]
    F --> H[(订单表 唯一索引兜底)]

    class A startEnd
    class B,C,D condition
    class E,G reject
    class F process
    class H data
```

- **第一层（前端）**：按钮防抖。用户点击后立刻禁用按钮 + 显示 loading，挡住手抖和连点。这不是安全防线，是体验优化——它挡不住脚本攻击，但能把 90% 的误操作挡在门外：

```javascript
// 前端：按钮防抖
pay() {
  if (this.paying) return;      // 正在支付，直接忽略
  this.paying = true;
  wx.showLoading({ title: '支付中' });
  wx.requestPayment({
    ...this.payParams,
    complete: () => {
      this.paying = false;
      wx.hideLoading();
    }
  });
}
```

- **第二层（后端前置）**：Redis 令牌。拦掉绝大多数重复请求，用户手抖、接口重放基本在这里被吞掉，体验最好。但如 4.2.4 所述，它不保证绝对原子，不能单独扛资金安全。
- **第三层（后端核心）**：乐观锁 + 唯一索引。这才是最终防线。乐观锁保证"状态只变一次"，唯一索引保证"流水只记一条"。两者叠用，资金安全才有兜底。

三层分工清晰：前两层负责"少干活"，第三层负责"不出错"。任何一层都能独立运行，叠加起来才谈得上"万无一失"。

## 第 5 步 绊脚石：资质、回调与调试

### 5.1 资质问题：绕不开的硬门槛

支付跑通之前，资质是一堵实打实的墙：

- **个人主体小程序无法开通微信支付**。调统一下单时常见报错： ` 商户号未开通该产品权限 ` 或 ` NO_AUTH ` 。不是代码问题，是主体资格问题，代码怎么改都没用。
- **企业/个体工商户需要营业执照 + 每年 300 元认证费 + 开通商户号**。申请路径：微信公众平台 → 微信支付 → 接入微信支付。
- **没有商户号怎么办**：用模拟数据把签名、幂等、回调处理的逻辑全部测熟。等有资质了，把 Mock 的微信 API 调用换成真实调用即可。第 7 步有完整的练手方案。

### 5.2 回调通知的那些坑

回调是支付联调里事故率最高的环节，常见坑逐个数：

**坑一：notify_url 必须是公网 HTTPS。** ` http://localhost:8080/pay/callback ` 在微信眼里就是个无效地址。开发阶段用内网穿透（ngrok / natapp）把本地服务暴露出去，见第 2 步的环境搭建。

**坑二：回调会重试，且可能延迟。** 微信的回调可能 3 ~ 10 秒才到（甚至更久），不是付完钱立刻就有。重试最多 15 次，间隔递增（15s/15s/30s/3m/10m/20m/30m/30m/30m/60m/3h/3h/3h/6h/6h）。所以前端收到 success 别急着说"完成"，轮询一下订单状态更稳妥。

**坑三：应答必须快。** 5 秒内没返回 2xx，微信就认为失败开始重试。耗时业务放异步。

**坑四：验签失败先查证书。** 微信会定期更换平台证书。报验签失败时，先检查证书是否最新、证书序列号是否和请求 Header 里的 ` Wechatpay-Serial ` 对上、签名算法是否混用了 v2/v3。

**坑五：日志要打全。** 回调调试时信息即正义：

```java
log.info("收到支付回调: outTradeNo={}, transactionId={}, totalFee={}",
        outTradeNo, transactionId, totalFee);
```

明文、密文、验签结果、应答 body，全部记录，出问题才查得到。

### 5.3 开发调试的最佳实践

| 手段 | 说明 | 需要什么 |
|------|------|----------|
| 本地日志 | 记录请求与回调全链路 | 无，最基础 |
| 微信支付沙箱 | 模拟真实支付环境 | 需商户号 |
| 模拟回调脚本 | 用 curl 直接打回调接口 | 无，本文推荐 |
| 单元测试 | 覆盖签名、验签、幂等 | 无，最重要 |

没有商户号时，**模拟回调**是最有价值的调试手段：直接用 curl 把伪造的"支付成功"打到自己的回调接口，验证幂等逻辑是否真的挡住了重复处理。

```bash
curl -X POST http://localhost:8080/api/pay/callback \
  -H "Content-Type: application/json" \
  -d '{"out_trade_no":"ORDER_20260731_123456","transaction_id":"4200001234567890123456789012","total_fee":9999}'
```

连发两次，第二次应该返回"已处理"，积分只加一次。这就是对乐观锁最直观的验证。

配套的单元测试至少覆盖三个点：

```java
@Test
void testSignAndVerify() {
    // 用固定私钥签名，再验签，应通过
}

@Test
void testIdempotency() {
    // 同一订单处理两次，第二次应被乐观锁拦截
}

@Test
void testDuplicateCallback() {
    // 模拟回调连发两次，流水表只有一条记录
}
```

## 第 6 步 原理简述：客户端、后端与支付平台的三角关系

### 6.1 备胎信使理论：客户端到底在干什么

支付的核心矛盾是：**参与交易的三个角色里，只有客户端是不可信的一方**。支付平台的资金流转需要信任，后端要用自己的逻辑补足信任，而客户端——它既不该信，也不能让它承担关键职责。

把这个关系翻译成一个场景化的理论，叫"备胎信使"：

**第一幕，追求者的自我修养。** 客户端精心集成 SDK、调用 ` wx.requestPayment ` ，准备信物（提交订单、调起支付）。但到了最关键的一步——用户输入密码——它全程旁观。密码输入框由微信客户端渲染，小程序端既读不到输入内容，也无法监听或截屏。

**第二幕，备胎的觉悟。** 客户端认清自己只是数据中转：从用户这搬到后端，再从后端搬到支付平台。拿到回执（ ` wx.requestPayment ` 的 success）后第一时间转交给用户。仅此而已。

**第三幕，最大的绿帽。** 支付平台偷偷绕开客户端，直接找后端确认结果——异步回调直达服务器。客户端告诉用户"支付成功"了，后端却可能因为风控拦截而认定"未成功"。**同步结果仅供参考，以异步回调为准**，这句话是这段关系的核心注释。

三个角色的信任边界，用一张图说清：

```mermaid
flowchart TD
    classDef root fill:#0f172a,stroke:#3b82f6,stroke-width:2.5px,color:#bfdbfe,font-weight:bold;
    classDef process fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#e5e7eb;
    classDef data fill:#052e16,stroke:#16a34a,stroke-width:2px,color:#bbf7d0,font-weight:bold;
    classDef reject fill:#450a0a,stroke:#dc2626,stroke-width:2px,color:#fecaca,font-weight:bold;

    U((用户))
    C[客户端 备胎信使]
    B[后端 定海神针]
    P[(支付平台)]

    U -->|"提交订单"| C
    C -->|"透传参数 调起支付"| P
    P -->|"异步回调直达"| B
    B -->|"验签 幂等 记状态"| B
    B -->|"应答 SUCCESS"| P
    C -.->|"success 仅供参考"| U

    class U root
    class C process
    class B root
    class P data
```

看懂这张图就懂了支付安全的一半：**钱的流向只发生在用户和支付平台之间，后端通过异步回调当裁判，客户端只负责传话**。密码不经过客户端，金额由签名锁死，结果以回调为准——三方各守其位，谁也骗不了谁。

### 6.2 为什么这样设计：安全至上

这套"不信任客户端"的设计不是凭空而来的，每一环都有明确的安全目的：

| 设计 | 目的 |
|------|------|
| 签名在服务端完成 | 客户端无法篡改金额。改了 ` total_fee ` ，签名立刻失效，微信直接拒单 |
| 密码在支付平台内部验证 | 客户端不可见，无法窃取、无法伪造输入 |
| 异步回调直达后端 | 客户端被破解也伪造不了支付成功的通知，因为回调不经由客户端 |

三者合起来，把"资金安全"这件事从客户端彻底剥离：客户端能做的最坏破坏，无非是让用户付不了款，但永远骗不到"已付款"。

### 6.3 开发者启示录

落到日常开发，这层理论有三个直接结论：

1. **核心逻辑必须放后端。** 金额计算、状态变更、库存扣减，任何涉及钱的判断都不该出现在小程序端代码里。
2. **后端是定海神针。** 验签（确认回调来自微信）、幂等（防止重复扣款）、业务处理（更新订单、扣库存、发消息），三件事全是后端的事。
3. **少做事，少背锅；传好话，不添乱。** 客户端把自己该传的传对，把不该承担的交给后端，反而最不容易出问题。

## 第 7 步 学习路线：没有资质，怎么练手

### 7.1 能做什么：无需商户号

没有商户号，反而能更专注地练核心逻辑。这些事全都不依赖微信：

**1. 设计完整的订单数据模型。** 订单表 + 流水表是支付的地基：

```sql
CREATE TABLE orders (
    id             BIGINT PRIMARY KEY AUTO_INCREMENT,
    out_trade_no   VARCHAR(64)  NOT NULL UNIQUE,
    status         VARCHAR(20)  NOT NULL,     -- PENDING / PAID / CLOSED
    amount         INT          NOT NULL,     -- 单位分
    openid         VARCHAR(64)  NOT NULL,
    created_at     DATETIME     NOT NULL
);

CREATE TABLE pay_records (
    id             BIGINT PRIMARY KEY AUTO_INCREMENT,
    out_trade_no   VARCHAR(64)  NOT NULL UNIQUE,
    transaction_id VARCHAR(64),
    total_fee      INT          NOT NULL,
    pay_time       DATETIME
);
```

**2. 实现统一下单的签名逻辑。** 不真实调微信，只测"签名串构造 → RSA 签名 → Header 组装"，用 Mock 的 body 就能验证签名正确性。

**3. 实现二次签名生成。** 输入一个假 prepay_id，验证输出的五个参数结构和 paySign 是否符合 ` wx.requestPayment ` 的格式要求。

**4. 实现回调验签和幂等处理。** 用 Postman / curl 把伪造的"支付成功"数据打到自己的回调接口，验证乐观锁是否真的能拦住第二次处理。

**5. 写单元测试。** 覆盖签名、验签、幂等三个最容易翻车的点（见 5.3 节）。

### 7.2 不能做什么：需商户号

这三件事离开商户号跑不通，也别硬跑：

- 真实调用统一下单 API（返回的会一直是 ` NO_AUTH ` ）；
- 真实拉起 ` wx.requestPayment ` （没有商户配置，前端调不起来）；
- 接收微信的真实异步回调（微信压根不会向没有商户号的你发通知）。

它们只是"API 地址 + 凭证"的差异，不影响你验证逻辑。

### 7.3 推荐的学习路径

按阶段推进，每阶段都能独立验收：

| 阶段 | 做什么 | 验收标准 |
|------|--------|----------|
| 一 | 用 Mock 数据跑通全套后端逻辑 | 统一下单、二次签名、回调处理全链路走通 |
| 二 | 用 Postman 模拟前端请求 | 下单接口、查询订单接口返回正确 |
| 三 | 内网穿透 + 模拟回调，测幂等 | curl 连发两次回调，第二次被乐观锁拦截 |
| 四 | 有商户号后替换真实 API | 把 Mock 调用换成 ` api.mch.weixin.qq.com ` 的真实地址 |

阶段四是最爽的：你会发现前面三个阶段的代码**一行都不用改逻辑**，只是把请求地址和凭证换掉。

### 7.4 写在最后：学习心态

没吃过猪肉，但可以先看猪跑。支付后端 90% 的逻辑（订单、幂等、回调处理）与商户号无关——签名是标准 RSA，解密是标准 AES-GCM，幂等是标准乐观锁，全部可以在没有一分钱真实交易的情况下练到滚瓜烂熟。等到有资质的那天，你要做的只是把 Mock 换成真实 API。

## 第 8 步 结语：支付不神秘，安全是王道

把全文串一遍，三条主线各自收敛：

- **流程**：wx.pay 的后端三步曲——统一下单换 prepay_id，二次签名防篡改，回调验签解密定结果。每一步的代码在本文都可以直接抄。
- **幂等**：前置令牌 + 乐观锁 + 唯一索引的三层防御。前端挡误操作，Redis 挡重放，数据库挡真正的重复。
- **角色**：后端是定海神针，客户端是工具人。密码你碰不到，签名你造不了，回调绕着你走——这就是支付为什么安全。

最后送上一句实践里总结的话：**支付不神秘，安全是王道。后端开发者要做定海神针，而不是工具人。**

没有资质不是借口，先把逻辑写出来跑通，剩下的只是时间问题。
