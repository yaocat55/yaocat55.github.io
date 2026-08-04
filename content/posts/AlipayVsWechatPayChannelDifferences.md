---
title: "微信支付 vs 支付宝：聚合支付渠道集成中的十一处暗坑"
date: 2023-10-31T11:30:03+00:00
tags: ["支付系统", "微信支付", "对比分析"]
categories: ["技术类"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "聚合支付系统集成两渠道时踩过的坑：prepay返回值语义不同、二次签名自己做、回调验证逻辑完全不同、金额单位一个用分一个用元、对账单字段差异等。全文对照支付宝和微信在SDK、下单、签名、回调、退款、对账六大环节的具体差异。"
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

# 渠道集成的痛：微信和支付宝处处不一样

聚合支付系统要同时对接支付宝和微信支付。初看两边的官方文档，觉得差不多——都是「下单→拿凭证→前端拉起→回调通知」这个流程。真到写代码的时候才发现，每一步都不一样，甚至同是微信生态，App 和小程序之间还有差异。

这篇文章把两渠道在 SDK 选型、下单参数、签名机制、回调处理、退款流程、对账单格式六个环节的具体差异整理出来，顺便也记录微信 App 和小程序之间那几处让人想砸键盘的细节。

---

## 一、SDK 选型和核心对象

先看 SDK 本身的差异，这决定了后面所有代码怎么组织。

| | 支付宝 | 微信支付 |
|------|------|------|
| Maven artifact | `alipay-sdk-java:4.40.308.ALL` | `wechatpay-java:0.2.17` |
| 核心对象 | `DefaultAlipayClient` （就是 HTTP 客户端） | `RSAAutoCertificateConfig` （配置 + 签名 + 证书管理） |
| HTTP 层 | 自带老版 HttpClient | 自带 OkHttp，可注入自定义实例 |
| 证书管理 | 无（公钥手动配） | `AutoCertificateService` 自动下载平台证书 + 后台线程轮换 |
| Service 封装 | 无，裸调 `client.execute(request)` | `AppService` / `JsapiService` / `RefundService` 封装请求-响应对映 |

> ⚠️ 新手提示：支付宝的 `DefaultAlipayClient` 就是个 HTTP 客户端，一行 `new` 就行。微信的 `RSAAutoCertificateConfig` 是重量级对象——创建时会初始化证书下载、后台轮询线程，要通过工厂 + Caffeine 缓存复用，别每次请求都 new。

两者最大的思维差异：**支付宝把 SDK 当 HTTP 工具用，微信把 SDK 当基础设施用。**

---

## 二、prepay 返回值的语义鸿沟

这是两渠道最大的坑，也是实现聚合支付时第一个需要认真区分的地方。

```mermaid
flowchart LR
    subgraph alipay["支付宝 prepay"]
        a1["alipay.trade.app.pay"] --> a2["orderStr（已签名的完整字符串）"]
        a2 -->|"前端原样透传"| a3["SDK 拉起支付"]
    end

    subgraph wechat["微信 prepay"]
        w1["/v3/pay/transactions/app"] --> w2["prepay_id（只是个标识）"]
        w2 --> w3["服务端二次签名"]
        w3 --> w4["签好的参数字典"]
        w4 -->|"前端调起 SDK"| w5["SDK 拉起支付"]
    end

    classDef alipayStyle fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#e5e7eb
    classDef wechatStyle fill:#2a1147,stroke:#a855f7,stroke-width:2px,color:#ede9fe
    class a1,a2,a3 alipayStyle
    class w1,w2,w3,w4,w5 wechatStyle
```

**支付宝的 `orderStr` 是成品**——里面已经含了 `sign` （服务端私钥签好的），前端拿到后**原样丢**给 SDK，一行到底：

```java
// 支付宝
response.getBody();  // 这就是 orderStr，前端直接用
```

**微信的 `prepay_id` 是半成品**——需要服务端再做一次签名：

```java
// 微信：SDK 下单拿到 prepay_id
String prepayId = response.getPrepayId();

// 然后服务端得自己拼签名串 + RSA-SHA256 签名
String signStr = appId + "\n" + partnerId + "\n" + prepayId + "\n" + nonceStr + "\n" + timeStamp;
String sign = sha256withRSA(signStr, merchantPrivateKey);
// 最后返回一组参数给前端
```

> ⚠️ 很多人会误以为 `prepay_id` 就是前端拉起的凭证，但实际上微信 SDK 需要的是**一组参数**，其中包含了 `prepay_id` + 签名。服务端签名这一步 SDK 不帮你做，必须自己写。

---

## 三、二次签名：App 和小程序也不一样

同是微信支付，App 和小程序的签名串格式还不同——这是踩坑最多的地方。

### App 支付签名串（5 行）

```
appId
partnerId
prepayId
nonceStr
timeStamp
```

签名后返回的字段名： `sign` ，包字段名： `packageValue` 。

### 小程序支付签名串（4 行，不含 partnerId）

```
appId
timeStamp
nonceStr
prepay_id=wx...
```

签名后返回的字段名： `paySign` （不是 `sign` ！），包字段名： `package` 。

| | App 支付 | 小程序支付 |
|------|------|------|
| 行数 | 5 | 4 |
| 是否含 partnerId | ✅ | ❌ |
| prepay_id 格式 | 裸值 `wx...` | `prepay_id=wx...` |
| 签名字段名 | `sign` | `paySign` |
| 包字段名 | `packageValue` | `package` |
| 包字段值 | `"Sign=WXPay"` | `"prepay_id=wx..."` |

> 这六个差异中，**签名字段名不同**是最容易搞混的——代码里写死一个 `sign` 字段，小程序那边就永远调不起支付。

```mermaid
flowchart TD
    subgraph app["App 支付"]
        as1["signStr = appId\\npartnerId\\nprepayId\\nnonceStr\\ntimeStamp"] --> as2["SHA256withRSA 签名"]
        as2 --> as3["返回: {appId, partnerId, prepayId, nonceStr, timeStamp, packageValue, sign}"]
    end

    subgraph mini["小程序支付"]
        ms1["signStr = appId\\ntimeStamp\\nnonceStr\\nprepay_id=xx"] --> ms2["SHA256withRSA 签名"]
        ms2 --> ms3["返回: {appId, timeStamp, nonceStr, package, signType, paySign}"]
    end

    classDef appStyle fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#e5e7eb
    classDef miniStyle fill:#2a1147,stroke:#a855f7,stroke-width:2px,color:#ede9fe
    class as1,as2,as3 appStyle
    class ms1,ms2,ms3 miniStyle
```

Java 里实现 SHA256withRSA 签名本身很直接，关键是处理好商户私钥 PEM 的 PKCS8 和 PKCS1 两种格式都能解析（微信给的 `apiclient_key.pem` 是 PKCS8）：

```java
String keyContent = privateKeyPem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replaceAll("\\s", "");
byte[] keyBytes = Base64.getDecoder().decode(keyContent);

Signature sig = Signature.getInstance("SHA256withRSA");
sig.initSign(keyFactory.generatePrivate(new PKCS8EncodedKeySpec(keyBytes)));
sig.update(signStr.getBytes(StandardCharsets.UTF_8));
String sign = Base64.getEncoder().encodeToString(sig.sign());
```

---

## 四、金额单位：元 vs 分

这是个容易出生产事故的差异：

| | 支付宝 | 微信 |
|------|:---:|:---:|
| API 金额单位 | **元**（字符串 ` "399.00"` ） | **分**（整数 `39900` ） |
| 内部存储单位 | 分 | 分 |
| prepay 提交时 | `fenToYuan()` 分→元 | 直接传分 |
| 回调回来后 | `yuanToFen()` 元→分 | 直接写分 |

> ⚠️ 支付宝的回调 `total_amount` 也是元，解析回调时要转分再入库。忘了这一步，库里就多了一笔 "39900元" 的单子。

---

## 五、回调处理：验签逻辑完全不同

```mermaid
flowchart TD
    subgraph alipay_cb["支付宝回调"]
        ac1["POST /v1/notify/alipay"] --> ac2["request.getParameterMap()"]
        ac2 --> ac3["AlipaySignature.rsaCheckV1()"]
        ac3 -->|"RSA2 公钥验签"| ac4{"验签通过？"}
        ac4 -->|"是"| ac5["提取 trade_no/total_amount"]
        ac4 -->|"否"| ac6["return 'failure'"]
    end

    subgraph wechat_cb["微信回调"]
        wc1["POST /v1/notify/wechat"] --> wc2["读取 raw body + 四个头"]
        wc2 --> wc3["NotificationParser.parse()"]
        wc3 -->|"验签+AES-256-GCM 解密"| wc4{"验签通过？"}
        wc4 -->|"是"| wc5["得到 Transaction 对象"]
        wc4 -->|"否"| wc6["return FAIL JSON"]
    end

    classDef alipayStyle fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#e5e7eb
    classDef wechatStyle fill:#2a1147,stroke:#a855f7,stroke-width:2px,color:#ede9fe
    classDef failStyle fill:#450a0a,stroke:#dc2626,stroke-width:2px,color:#fecaca
    class ac1,ac2,ac3,ac4,ac5 alipayStyle
    class wc1,wc2,wc3,wc4,wc5 wechatStyle
    class ac6,wc6 failStyle
```

| | 支付宝 | 微信 |
|------|------|------|
| 验签方式 | `AlipaySignature.rsaCheckV1(params, publicKey)` | `NotificationParser.parse(headers, body)` |
| 参数来源 | `request.getParameterMap()` | HTTP 请求头 + raw body |
| 证书 | 支付宝公钥字符串 | 平台证书（SDK 自动管理） |
| 解密 | 无需（明文） | AES-256-GCM 解密 |
| 成功应答 | `"success"` 字符串 | `{"code":"SUCCESS"}` JSON |
| 重试 | 支付宝固定间隔 | 最多 15 次，24 小时内梯度递增 |

微信的回调一步完成验签 + 解密，返回的就是明文 `Transaction` 对象，这比支付宝多了一层安全但实现也更复杂。

---

## 六、SDK 的职责边界

两渠道的 SDK 覆盖范围不同，这是做聚合时需要自己补齐的部分：

| 环节 | 支付宝 SDK | 微信 SDK | 谁做 |
|------|:---:|:---:|------|
| APIv3 请求签名 | N/A | ✅ `Authorization` 头 | SDK |
| 下单接口 | ✅ `sdkExecute()` | ✅ `prepay()` | SDK |
| 回调验签 | ✅ `rsaCheckV1()` | ✅ `NotificationParser.parse()` | SDK |
| 回调解密 | N/A | ✅ | SDK |
| prepay 二次签名 | N/A（不需要） | ❌ | **自己写** |
| 平台证书管理 | N/A（不适用） | ✅ `AutoCertificateService` | SDK |
| 对账单下载 | 返回 URL，自己下载 | 返回 URL，自己下载 | **自己写** |
| 对账单解析 | ❌（不提供） | ❌（不提供） | **自己写** |

总结就是：**SDK 帮你搞定和渠道的通信、签名、验签，但 prepay 的二次签名和对账单的下载解析这些「业务层面」的活儿都得自己干。**

---

## 七、退款流程差异

两渠道退款接口参数结构也有不同：

| | 支付宝 | 微信 |
|------|------|------|
| 退款接口 | `alipay.trade.refund` | `POST /v3/refund/domestic/refunds` |
| 退款单号字段 | `out_request_no` | `out_refund_no` |
| 金额字段 | `refund_amount` （元） | `amount.refund` （分） |
| 退款原因 | `refund_reason` | `reason` |
| 退款查询接口 | `alipay.trade.fastpay.refund.query` | `GET /v3/refund/domestic/refunds/{out_refund_no}` |

差异不大，主要注意金额单位的转换。

---

## 八、对账单 CSV 差异

这是对账系统要直接面对的差异，也是设计 `BillRow` 中间结构的依据。

| | 支付宝 | 微信 |
|------|------|------|
| 文件编码 | **GBK** | UTF-8 |
| 压缩格式 | `.csv.zip` （需先解压） | 纯 `.csv` |
| 分隔符 | 英文逗号 | 英文逗号 |
| 反引号前缀 | `\`` （防 Excel 科学记数） | `\`` （同） |
| 列数 | 23 列 | 29 列 |
| `income` （净入账） | 直接有「商家实收」列 | **没有**，须「金额减手续费」自己算 |
| 区分支付/退款行 | 「业务类型」列 | 「交易状态」列 |
| 汇总行 | 文件末尾 | 文件末尾（以 `\`` 开头） |
| 下载链接时效 | 30 秒 | 5 分钟 |

> ⚠️ 最坑的差异：支付宝有「商家实收」字段可以直接用，微信没有——得自己拿「应结订单金额」减「手续费」算出来。退款行的微信手续费是负数（代表退回的手续费），不注意这个对账结果就偏了。

---

## 九、总结：架构设计上的应对

面对这么多差异，在聚合支付系统中怎么做才能挖坑不深？

1. **渠道策略模式（Strategy Pattern）**：一个 `PayChannelStrategy` 接口，支付宝和微信各一个实现。所有渠道特有逻辑封在策略内部，对账引擎和支付核心只看接口契约。

2. **工厂模式复用 SDK 对象**： `AlipayClientFactory` 缓存 `DefaultAlipayClient` ， `WechatConfigFactory` 缓存 `RSAAutoCertificateConfig` 。都用 Caffeine 本地缓存，TTL 30min，配置变更时淘汰重建。

3. **金额统一以分存储**：不管渠道传什么单位，入库前全转成分。换算只在策略内部发生。

4. **对账单归一化**：两渠道 CSV 解析后归一化为 `BillRow` 通用结构，对账引擎不碰渠道原始字段。

5. **回调独立路由**：`/v1/notify/alipay` 和 `/v1/notify/wechat` 各自独立，验签逻辑完全不同，没必要强行统一。

> 一句话总结：**渠道的差异永远存在，我们的任务是把它封在策略层，不让它向上蔓延到对账和业务逻辑。**
