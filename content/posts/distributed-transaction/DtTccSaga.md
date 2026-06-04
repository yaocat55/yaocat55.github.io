---
title: "TCC + Saga——补偿型分布式事务"
date: 2022-12-29T08:00:00+00:00
tags: ["分布式架构"]
categories: ["分布式事务中间件"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "TCC 和 Saga 的完整落地：为什么 AT 搞不定'发优惠券'这种操作（第三方 API 无法自动回滚）、TCC 的 Try/Confirm/Cancel 三阶段——每个接口写三套逻辑、空回滚和悬挂的成因与解决（操作记录的幂等表）、Seata TCC 模式代码实战（@TwoPhaseBusinessAction 注解）、Saga 的编排型（orchestration）vs 协同型（choreography）——状态机驱动补偿链——以及 TCC vs Saga 的选型决策框架。"
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

# TCC + Saga——补偿型分布式事务

> 📖 <strong>前置阅读</strong>：本文假设读者已理解 Seata AT 模式的原理和局限。如果还不熟悉，建议先阅读 [<strong>Seata AT 模式——undo_log 与二阶段原理</strong>]({{< relref "DtSeataAT.md" >}})。

## 一、⚡ AT 能回滚库存——但能回滚一条"已发出的短信"吗？

AT 模式的局限——上一篇说了：

```
AT 的自动回滚依赖 undo_log——生成反向 SQL
  INSERT → DELETE（undo_log 记录自增 ID——反向就是 DELETE）
  UPDATE → UPDATE（undo_log 记录前置镜像——反向就是把值改回去）

但以下操作——数据库回滚不了：
  ① 发了优惠券——HTTP POST 到营销系统的 API——数据库回滚不了 HTTP 调用
  ② 发了短信——调了阿里云短信 API——阿里云不会因为你的"反向 SQL"就收回短信
  ③ 调了第三方支付——Payment API 已经扣了钱——不能"生成反向 HTTP"退钱
  ④ 给 Redis 写了一个计数器——Redis 没有 undo_log——AT 管不了
```

<strong>TCC 和 Saga 就是为这而生的——手动补偿——操作本身和撤回操作都由你写代码实现。</strong>

## 二、🔄 TCC——Try / Confirm / Cancel——你自己管理回滚

### 2.1 TCC 的本质——每个操作配一个"撤销操作"

```
TCC 把每个业务操作拆成三个方法：

  Try（尝试）    —— 预留资源——但不真正执行
  Confirm（确认） —— 真正执行——Try 预留的资源生效
  Cancel（取消）  —— 释放 Try 预留的资源——回滚

和 AT 的区别：
  AT：你写一套代码——Seata 自动生成"撤销操作"（反向 SQL）
  TCC：你写三套代码——Try（正向）、Confirm（确认）、Cancel（撤销）
       → 写了三套代码——能处理任何类型的操作——不再局限于数据库
```

### 2.2 示例——"创建订单 + 发优惠券 + 扣积分"——用 TCC

```java
// ===== 场景：下单时——创建订单 + 发优惠券 + 扣积分 =====
// 订单是 DB 操作——但发优惠券是 HTTP API——扣积分也是 HTTP API
// AT 回滚不了 HTTP API——用 TCC

// ===== 订单服务——TCC 接口 =====
public interface OrderTccAction {

    /**
     * Try：预创建订单——状态为 PENDING——库存还没扣——订单还不能支付
     * @param businessContext 在 TM 端传入的参数——和 @BusinessActionContextParameter 对应
     */
    @TwoPhaseBusinessAction(
        name = "order-create",                     // TCC 资源名
        commitMethod = "confirmCreateOrder",       // Confirm 方法
        rollbackMethod = "cancelCreateOrder"       // Cancel 方法
    )
    boolean tryCreateOrder(
        @BusinessActionContextParameter(paramName = "userId") Long userId,
        @BusinessActionContextParameter(paramName = "items") List<OrderItemDto> items,
        @BusinessActionContextParameter(paramName = "totalAmount") BigDecimal totalAmount
    );

    /**
     * Confirm：把订单从 PENDING 变为 CREATED——正式生效
     */
    boolean confirmCreateOrder(BusinessActionContext context);

    /**
     * Cancel：把 PENDING 的订单变为 CANCELLED——释放预占
     */
    boolean cancelCreateOrder(BusinessActionContext context);
}
```

```java
// ===== 订单服务——TCC 实现 =====
@Service
public class OrderTccActionImpl implements OrderTccAction {

    @Autowired
    private OrderMapper orderMapper;

    @Override
    @Transactional
    public boolean tryCreateOrder(Long userId, List<OrderItemDto> items,
                                   BigDecimal totalAmount) {
        // ① 预创建订单——状态为 PENDING——不是正式订单
        Order order = new Order();
        order.setOrderNo(generateOrderNo());
        order.setUserId(userId);
        order.setTotalAmount(totalAmount);
        order.setStatus(OrderStatus.PENDING);  // ← PENDING——不是正式订单——不可支付
        order.setCreatedAt(LocalDateTime.now());
        orderMapper.insert(order);

        // ② 把 orderId 存入 BusinessActionContext——Confirm/Cancel 会用到
        // Seata 自动把方法返回值之外的参数存入 Context
        // 这里通过 RootContext 手动放
        RootContext.bind("orderId_" + RootContext.getXID(), order.getId());

        return true;  // Try 成功——等待 TC 通知 Confirm 或 Cancel
    }

    @Override
    @Transactional
    public boolean confirmCreateOrder(BusinessActionContext context) {
        // ① 从 Context 中取出 orderId
        Long orderId = (Long) context.getActionContext()
                .get("orderId_" + context.getXid());

        // ② 把订单状态从 PENDING → CREATED——正式生效
        Order order = orderMapper.selectById(orderId);
        if (order == null || order.getStatus() != OrderStatus.PENDING) {
            // 幂等——如果已经 Confirm 过了——不再处理
            return true;
        }
        order.setStatus(OrderStatus.CREATED);
        orderMapper.updateById(order);
        return true;
    }

    @Override
    @Transactional
    public boolean cancelCreateOrder(BusinessActionContext context) {
        Long orderId = (Long) context.getActionContext()
                .get("orderId_" + context.getXid());

        Order order = orderMapper.selectById(orderId);
        if (order == null) {
            // 空回滚——Try 还没执行——Cancel 先到了——不做处理
            return true;
        }
        if (order.getStatus() == OrderStatus.CANCELLED) {
            // 幂等——已经取消过了
            return true;
        }
        order.setStatus(OrderStatus.CANCELLED);
        orderMapper.updateById(order);
        return true;
    }
}
```

```java
// ===== 优惠券服务——TCC 接口（HTTP API——AT 回滚不了）=====
public interface CouponTccAction {

    @TwoPhaseBusinessAction(
        name = "coupon-grant",
        commitMethod = "confirmGrantCoupon",
        rollbackMethod = "cancelGrantCoupon"
    )
    boolean tryGrantCoupon(
        @BusinessActionContextParameter(paramName = "userId") Long userId,
        @BusinessActionContextParameter(paramName = "couponType") String couponType
    );

    boolean confirmGrantCoupon(BusinessActionContext context);

    boolean cancelGrantCoupon(BusinessActionContext context);
}

@Service
public class CouponTccActionImpl implements CouponTccAction {

    @Autowired
    private CouponService couponService;  // 这个 Service 调外部营销 API

    @Override
    public boolean tryGrantCoupon(Long userId, String couponType) {
        // Try：预占优惠券——调营销 API——标记为用户——但未激活
        Coupon coupon = couponService.reserveCoupon(userId, couponType);
        // 外部 API 返回了 couponId
        RootContext.bind("couponId_" + RootContext.getXID(), coupon.getId());
        return true;
    }

    @Override
    public boolean confirmGrantCoupon(BusinessActionContext context) {
        // Confirm：激活优惠券——用户可用
        Long couponId = (Long) context.getActionContext()
                .get("couponId_" + context.getXid());
        couponService.activateCoupon(couponId);  // HTTP PUT /coupons/{id}/activate
        return true;
    }

    @Override
    public boolean cancelGrantCoupon(BusinessActionContext context) {
        // Cancel：回收优惠券——把预留的优惠券放回库存
        Long couponId = (Long) context.getActionContext()
                .get("couponId_" + context.getXid());
        if (couponId == null) {
            return true;  // 空回滚——Try 还没执行完
        }
        couponService.recycleCoupon(couponId);  // HTTP DELETE /coupons/{id}
        return true;
    }
}
```

```java
// ===== TM——全局事务发起方——调各个 TCC 接口 =====
@Service
public class OrderApplicationService {

    @Autowired
    private OrderTccAction orderTccAction;
    @Autowired
    private CouponTccAction couponTccAction;
    @Autowired
    private PointTccAction pointTccAction;

    @GlobalTransactional
    public Order createOrderWithCoupon(CreateOrderRequest request) {
        // ① Try：预创建订单
        boolean orderTry = orderTccAction.tryCreateOrder(
                request.getUserId(), request.getItems(), request.getTotalAmount());
        if (!orderTry) throw new BusinessException("预创建订单失败");

        // ② Try：预发优惠券——不是数据库操作——是 HTTP 调外部 API
        boolean couponTry = couponTccAction.tryGrantCoupon(
                request.getUserId(), "FIRST_ORDER");
        if (!couponTry) throw new BusinessException("预发优惠券失败");

        // ③ Try：预扣积分——也是 HTTP 调外部 API
        boolean pointTry = pointTccAction.tryDeductPoints(
                request.getUserId(), 100);
        if (!pointTry) throw new BusinessException("预扣积分失败");

        // ④ 所有 Try 成功——TM 通知 TC 进 Confirm
        // TC 依次调每个 RM 的 confirmXxx()
        // → orderTccAction.confirmCreateOrder() ——订单 PENDING→CREATED
        // → couponTccAction.confirmGrantCoupon() ——优惠券激活
        // → pointTccAction.confirmDeductPoints()  ——积分确认扣除

        return ...;  // 返回订单信息
    }
    // 如果任何一个 Try 抛异常——TC 依次调每个 RM 的 cancelXxx()
    // → orderTccAction.cancelCreateOrder() ——订单 PENDING→CANCELLED
    // → couponTccAction.cancelGrantCoupon() ——优惠券回收
    // → pointTccAction.cancelDeductPoints()  ——积分退回
}
```

### 2.3 TCC 的两个致命陷阱——空回滚与悬挂

```
陷阱一：空回滚——Try 没执行——Cancel 先到了

  时间线：
  ① TM 调 Order TCC 的 Try——网络超时——TM 不知道 Try 成功了没有
  ② TM 决定回滚——发起 Cancel
  ③ Cancel 到达 order-service——但此时 Try 还没收到（网络延迟）——或者 Try 正在执行
  ④ Cancel 执行时——订单不存在（Try 还没创建）——Cancel 失败
  
  这叫"空回滚"——Cancel 先于 Try 到达

  解决——控制记录表：
    在 Cancel 中——如果查不到订单——不能报错——记录一条"Cancel 已执行"的空记录
    当 Try 终于到达时——先查"Cancel 是否已执行"——如果是——Try 不再执行

陷阱二：悬挂——Try 超时后——Cancel 执行了——Try 又到了

  时间线：
  ① TM 调 Try——Try 执行中——卡住了（GC 停顿——网络延迟）
  ② TM 等 10 秒超时——发起 Cancel
  ③ Cancel 到达——顺利执行——订单状态改为 CANCELLED
  ④ 第 30 秒——Try 终于执行完了——订单 INSERT 进去了——状态是 PENDING
  ⑤ 结果：Cancel 已经执行了——但 Try 把数据又写进去了——这个 Try"悬挂"了
  
  这叫"悬挂"——Try 在 Cancel 之后到达——Cancel 的撤销效果被 Try 覆盖了

  解决——同样用控制记录表：
    Cancel 执行时——记录一条"xid=xxx 已 Cancel"
    Try 执行前——先查"xid=xxx 是否已 Cancel"——如果是——拒绝执行
```

```sql
-- ===== TCC 防悬挂 + 空回滚控制表——每个参与 TCC 的服务都建一张 =====
CREATE TABLE tcc_operation_record (
    id           BIGINT AUTO_INCREMENT PRIMARY KEY,
    xid          VARCHAR(128) NOT NULL COMMENT '全局事务 ID',
    branch_id    BIGINT NOT NULL COMMENT '分支事务 ID',
    action_name  VARCHAR(64) NOT NULL COMMENT 'TCC 资源名——order-create/coupon-grant',
    status       TINYINT NOT NULL COMMENT '1-Try 2-Confirm 3-Cancel',
    created_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uk_xid_branch_action (xid, branch_id, action_name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;
```

```java
// ===== 改进后的 TCC 实现——带防悬挂 + 空回滚 =====
@Service
public class OrderTccActionImpl implements OrderTccAction {

    @Autowired
    private TccOperationRecordMapper recordMapper;

    @Override
    @Transactional
    public boolean tryCreateOrder(Long userId, List<OrderItemDto> items,
                                   BigDecimal totalAmount) {
        String xid = RootContext.getXID();
        Long branchId = RootContext.getBranchId();

        // ① 防悬挂——检查 Cancel 是否已执行
        TccOperationRecord cancelRecord = recordMapper.selectOne(
                xid, branchId, "order-create", 3);  // status=3 = Cancel
        if (cancelRecord != null) {
            // Cancel 先到了——Try 不能再执行——这就是"悬挂"——拒绝
            return false;
        }

        // ② 记录 Try
        TccOperationRecord tryRecord = new TccOperationRecord();
        tryRecord.setXid(xid);
        tryRecord.setBranchId(branchId);
        tryRecord.setActionName("order-create");
        tryRecord.setStatus(1);  // Try
        recordMapper.insert(tryRecord);

        // ③ 执行业务逻辑
        Order order = new Order();
        // ... 创建订单——状态 PENDING
        orderMapper.insert(order);
        RootContext.bind("orderId_" + xid, order.getId());
        return true;
    }

    @Override
    @Transactional
    public boolean cancelCreateOrder(BusinessActionContext context) {
        String xid = context.getXid();
        Long branchId = context.getBranchId();

        // ① 幂等——检查 Cancel 是否已执行
        TccOperationRecord existingRecord = recordMapper.selectOne(
                xid, branchId, "order-create", 3);
        if (existingRecord != null) {
            return true;  // Cancel 已经执行过了——幂等——直接返回
        }

        // ② 记录 Cancel——在查订单之前——防止空回滚
        TccOperationRecord cancelRecord = new TccOperationRecord();
        cancelRecord.setXid(xid);
        cancelRecord.setBranchId(branchId);
        cancelRecord.setActionName("order-create");
        cancelRecord.setStatus(3);  // Cancel
        recordMapper.insert(cancelRecord);

        // ③ 空回滚处理——查不到订单——不能报错
        Long orderId = (Long) context.getActionContext().get("orderId_" + xid);
        if (orderId == null) {
            return true;  // Try 没执行——空回滚——正常
        }
        Order order = orderMapper.selectById(orderId);
        if (order == null) {
            return true;  // Try 没执行完——空回滚——正常
        }
        if (order.getStatus() == OrderStatus.CANCELLED) {
            return true;  // 幂等
        }

        // ④ 执行业务撤销
        order.setStatus(OrderStatus.CANCELLED);
        orderMapper.updateById(order);
        return true;
    }
}
```

> ⚠️ 新手提示：空回滚和悬挂是 TCC 的两个经典坑——90% 的 TCC 实现都有这两个问题。解决方案就是一张操作记录表——在 Cancel 执行前先记一笔"Cancel 已执行"——在 Try 执行前先查"Cancel 是否已执行"。记录表的唯一键 `(xid, branch_id, action_name)` 天然防并发——并发的 Try 和 Cancel 只有一个能插入成功。

## 三、📖 Saga——长事务编排——状态机驱动的补偿链

### 3.1 Saga 的本质——把每一步和它的补偿串起来

```
TCC 的问题：每个操作要写 3 套代码——Try/Confirm/Cancel——代码量翻 3 倍
Saga 的思路：只写 2 套——正向操作 + 补偿操作——用一个编排器串起来

Saga = 一系列有序的事务——每个事务有对应的补偿事务
  → T1 → T2 → T3 → ... → Tn
  → 如果 Ti 失败——从 Ti-1 开始逆序执行补偿：
     Ci-1 → Ci-2 → ... → C1

和 TCC 的最大区别：
  TCC：Try 阶段不真正执行——Confirm 才执行——Try 可以 Cancel
  Saga：每一步直接执行——不预留——失败了执行补偿操作"弥补"
  → TCC 是"预留——确认"——Saga 是"执行——反悔"
```

```
场景：下单满一年自动续费——这是一个跨天的长流程

  T1: 创建续费订单         C1: 取消续费订单
  T2: 扣款（调支付接口）    C2: 退款（调支付接口）
  T3: 发送续费成功短信       C3: 发送"续费已取消"短信（补偿通知）
  T4: 更新会员过期时间      C4: 恢复原来的会员过期时间
  
  如果用 TCC——Try 阶段就要预留资源——但支付接口预留不了——预留了就要扣钱
  所以 TCC 在这个场景不合适——用 Saga——直接执行——失败了补偿
```

### 3.2 Saga 的两种编排方式——协同型 vs 编排型

```
方式一：协同型（Choreography）——无中心协调器——事件驱动
  每个服务完成自己的事务后——发事件——下一个服务监听到事件——继续执行

  order-service 创建订单 → 发 OrderCreated 事件
  payment-service 监听 → 扣款 → 发 PaymentCompleted 事件
  sms-service 监听 → 发短信 → 发 SmsSent 事件

  优点：松散耦合——不需要中心化协调器
  缺点：流程隐式分布在各个服务——看不到全貌——改流程要改多个服务

方式二：编排型（Orchestration）——有中心协调器——状态机驱动
  一个 Saga Orchestrator 串起所有步骤——每一步调哪个服务——失败了做哪个补偿

  协调器（SagaOrchestrator）：
    Step1: 调 order-service → 成功 → Step2
                                → 失败 → end
    Step2: 调 payment-service → 成功 → Step3
                                → 失败 → 补偿 Step1
    Step3: 调 sms-service → 成功 → end
                                → 失败 → 补偿 Step2 → 补偿 Step1

  优点：流程显式——在协调器中一目了然——改流程只改协调器
  缺点：协调器成了新的单点——虽然可以高可用部署

推荐：编排型——流程可见性 > 松散耦合的优势——尤其是复杂流程
```

### 3.3 编排型 Saga 的代码实现

```java
// ===== Saga 协调器——状态机驱动的长事务编排 =====
@Service
public class RenewMemberSagaOrchestrator {

    @Autowired
    private OrderService orderService;
    @Autowired
    private PaymentService paymentService;
    @Autowired
    private SmsService smsService;
    @Autowired
    private MemberService memberService;

    /**
     * 续费会员的完整流程——6 步——每步有补偿
     * Saga 状态机：
     *   START → CREATE_ORDER → DEDUCT_PAYMENT → SEND_SMS → UPDATE_MEMBER → END
     *     ↑          ↓               ↓              ↓            ↓
     *     └── cancel_order ←── refund ←── (skip) ←── restore_expiry
     */
    public void execute(RenewMemberRequest request) {
        SagaState state = SagaState.START;
        String orderId = null;
        String paymentId = null;

        try {
            // Step 1：创建续费订单
            orderId = orderService.createRenewOrder(request.getUserId(), request.getAmount());
            state = SagaState.ORDER_CREATED;

            // Step 2：扣款——调支付接口
            paymentId = paymentService.deduct(request.getUserId(), request.getAmount());
            state = SagaState.PAYMENT_DEDUCTED;

            // Step 3：发短信通知
            smsService.sendRenewSuccess(request.getUserId(), request.getAmount());
            state = SagaState.SMS_SENT;

            // Step 4：更新会员过期时间
            memberService.extendExpiry(request.getUserId(), 365);
            state = SagaState.COMPLETED;

        } catch (Exception e) {
            log.error("续费流程失败——当前状态: {}——开始补偿", state, e);
            compensate(state, orderId, paymentId, request);
        }
    }

    private void compensate(SagaState failedState, String orderId,
                             String paymentId, RenewMemberRequest request) {
        switch (failedState) {
            case PAYMENT_DEDUCTED:
            case SMS_SENT:
                // 已经扣了钱——要退款
                try {
                    paymentService.refund(paymentId, request.getAmount());
                    log.info("补偿：退款成功——paymentId={}", paymentId);
                } catch (Exception e) {
                    log.error("补偿失败：退款失败——需要人工介入——paymentId={}", paymentId, e);
                    // ← 补偿也失败了——记录到异常表——人工处理
                }
                // fall through——继续取消订单

            case ORDER_CREATED:
                // 取消订单
                try {
                    orderService.cancelOrder(orderId);
                    log.info("补偿：订单取消成功——orderId={}", orderId);
                } catch (Exception e) {
                    log.error("补偿失败：取消失败——需要人工介入——orderId={}", orderId, e);
                }
                break;

            case START:
            case COMPLETED:
                // 不需要补偿
                break;
        }
    }
}

enum SagaState {
    START,
    ORDER_CREATED,
    PAYMENT_DEDUCTED,
    SMS_SENT,
    COMPLETED
}
```

### 3.4 Seata Saga 模式——用状态机 DSL 替代手写编排器

```json
// Seata Saga 提供了声明式的状态机 DSL——不需要手写上面的 Java 代码
// 把流程定义成一个 JSON 文件——Seata 自动执行和补偿

{
  "Name": "renew-member-saga",
  "Comment": "会员续费 Saga",
  "StartState": "CreateOrder",
  "Version": "1.0",
  "States": {
    "CreateOrder": {
      "Type": "ServiceTask",
      "ServiceName": "orderService.createRenewOrder",
      "Next": "DeductPayment",
      "CompensateState": "CancelOrder"
    },
    "DeductPayment": {
      "Type": "ServiceTask",
      "ServiceName": "paymentService.deduct",
      "Next": "SendSms",
      "CompensateState": "RefundPayment"
    },
    "SendSms": {
      "Type": "ServiceTask",
      "ServiceName": "smsService.sendRenewSuccess",
      "Next": "UpdateMember",
      "CompensateState": "SendCancelSms"
    },
    "UpdateMember": {
      "Type": "ServiceTask",
      "ServiceName": "memberService.extendExpiry",
      "Next": "Succeed"
    },

    "CancelOrder": {
      "Type": "ServiceTask",
      "ServiceName": "orderService.cancelOrder",
      "Next": "Fail"
    },
    "RefundPayment": {
      "Type": "ServiceTask",
      "ServiceName": "paymentService.refund",
      "Next": "CancelOrder"
    },
    "SendCancelSms": {
      "Type": "ServiceTask",
      "ServiceName": "smsService.sendCancelSms",
      "Next": "RefundPayment"
    },

    "Succeed": { "Type": "Succeed" },
    "Fail": { "Type": "Fail" }
  }
}
```

## 四、⚖️ AT vs TCC vs Saga——选型决策

| 维度 | AT | TCC | Saga |
|------|:---:|:---:|:---:|
| <strong>回滚方式</strong> | 框架自动反向 SQL | 你写 Cancel | 你写补偿操作——逆序执行 |
| <strong>代码量</strong> | 1x（只写正向） | 3x（Try + Confirm + Cancel） | 2x（正向 + 补偿） |
| <strong>支持非 DB 操作</strong> | ❌——只支持关系型 DB | ✅——任何操作 | ✅——任何操作 |
| <strong>预留资源</strong> | 不需要——一阶段提交 | 需要——Try 预留 | 不需要——直接执行 |
| <strong>数据一致性</strong> | 强——全局锁保证 | 强——预留保证 | 弱——补偿可能失败 |
| <strong>适用场景</strong> | 纯 DB 操作——下单扣库存 | 有资源预留需求——秒杀/选座 | 长流程——续费/退款/审批 |

<strong>选型口诀</strong>：
- 所有操作都是 DB 的 INSERT/UPDATE/DELETE → <strong>用 AT——最简单</strong>
- 涉及到调外部 API——第三方接口——Redis——且需要资源预留 → <strong>用 TCC</strong>
- 涉及到长流程——步骤多——可能跨天——且每一步都可以接受"先做——错了再改" → <strong>用 Saga</strong>

## 🎯 总结

1. <strong>TCC = Try/Confirm/Cancel——每步三套代码——换来的是"什么操作都能补偿"</strong>：AT 只能回滚 DB 操作——TCC 可以补偿 HTTP API 调用、Redis 操作、第三方支付。代价是代码量翻 3 倍——以及空回滚和悬挂两个经典陷阱。解决方案：一张操作记录表——在 Cancel 执行前先记一笔——在 Try 执行前先查 Cancel 是否已执行。

2. <strong>Saga = 直接执行 + 逆序补偿——长事务编排模式</strong>：不需要预留资源——每一步直接执行——失败了从当前步开始逆序补偿。推荐编排型——用一个协调器串起所有步骤——流程一目了然。Seata Saga 提供声明式状态机 DSL——JSON 定义流程——避免手写补偿链。

3. <strong>补偿可能失败——需要人工干预机制</strong>：退款接口超时、取消订单失败——补偿也有可能失败。需要异常记录表 + 定时任务重试 + 人工介入界面。> 95% 的情况下补偿成功——剩下的 5% 需要人工处理——这是 BASE 的代价。

4. <strong>AT → TCC → Saga——复杂度递增——控制力递增</strong>：AT 最简单——但只支持 DB。TCC 最灵活——但代码量最大。Saga 适合长流程——但一致性最弱。90% 的场景用 AT + 事务消息就够了——只有 AT 处理不了的才上 TCC 或 Saga。

> 📖 <strong>下一步阅读</strong>：TCC 和 Saga 都是同步型的——如果场景允许异步——事务消息（RocketMQ 事务消息 + 本地消息表）是最简单的分布式事务方案——代码侵入最小——性能最好。继续阅读 [<strong>事务消息 + 本地消息表 + 生产踩坑</strong>]({{< relref "DtMessageAndProduction.md" >}})。
