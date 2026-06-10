---
title: "DDD 战术落地——代码怎么写"
date: 2022-12-22T08:00:00+00:00
tags: ["DDD与架构", "实践教程", "工程实践"]
categories: ["架构设计"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "DDD 战术落地的完整代码实现：四层项目结构（interfaces/application/domain/infrastructure）、聚合根完整设计（业务方法 + 不变量 + 领域事件收集）、Repository 接口放在 domain 层——实现在 infrastructure 层、Domain Service vs Application Service 的黄金判断标准——逻辑归谁、防腐层（ACL）隔离外部系统、领域事件的事务性发布与异步消费、Factory 封装复杂创建——以及一个完整的'创建订单'端到端实现。"
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

# DDD 战术落地——代码怎么写

> 📖 <strong>前置阅读</strong>：本文假设读者已理解实体、值对象、聚合根、限界上下文、领域事件的核心概念。如果还不熟悉，建议先阅读 [<strong>DDD 本质——领域驱动设计的核心概念</strong>]({{< relref "DddFundamentals.md" >}})。

## 一、⚡ 概念都懂了——但代码从哪个 package 开始建？

上一篇搞清楚了实体和值对象的区别、聚合根是"一致性边界"——但回到 IDE 中：

```
现有项目结构（MVC——三层）：
  controller/
  ├─ OrderController.java
  service/
  ├─ OrderService.java (3000 行——上帝类)
  mapper/
  ├─ OrderMapper.java
  ├─ UserMapper.java       ← 跨表调用——OrderMapper 也调 UserMapper
  ├─ ProductMapper.java    ← 跨表调用
  model/
  ├─ Order.java            ← 只有 getter/setter——贫血
  ├─ User.java
  ├─ Product.java

问题——现在要改成 DDD——应该怎么建目录？Repository 放哪？Domain Service 放哪？
```

<strong>这篇就是答案——从目录结构开始——到每一层的代码——完整的落地模板。</strong>

## 二、📂 项目结构——DDD 四层架构

### 2.1 四层——不是"三层 + 一层"

```
传统 MVC 三层：
  Controller → Service → Mapper
  → Service 层无限膨胀——3000 行——什么都往里塞

DDD 四层：
  interfaces（接口层）   → 接收请求、返回响应——薄薄一层
  application（应用层）  → 编排业务流程——调 Repository、发事件——没有业务逻辑
  domain（领域层）       → 业务逻辑——聚合根、值对象、Repository 接口、领域事件
  infrastructure（基础设施层）→ 技术实现——Repository 实现、数据库访问、MQ 发送
```

```
order-service/
├── interfaces/                          ← ① 接口层
│   ├── rest/
│   │   └── OrderController.java         # HTTP 接口——接受请求——转给 application 层
│   ├── dto/
│   │   ├── CreateOrderRequest.java      # 入参 DTO
│   │   └── OrderResponse.java           # 出参 DTO
│   └── mq/
│       └── OrderEventListener.java      # MQ 消息消费——转到 application 层
│
├── application/                         ← ② 应用层
│   ├── OrderApplicationService.java     # 编排——调 Repository + 发事件——不包含业务逻辑
│   ├── command/
│   │   └── CreateOrderCommand.java      # 应用层自己的命令对象——DTO 转换后的内部对象
│   └── event/
│       └── OrderEventPublisher.java     # 事件发布接口——实现在 infrastructure
│
├── domain/                              ← ③ 领域层——核心——不依赖任何外部框架
│   ├── model/
│   │   ├── aggregate/
│   │   │   └── Order.java               # 聚合根
│   │   ├── entity/
│   │   │   └── OrderItem.java           # 聚合内部实体
│   │   ├── valueobject/
│   │   │   ├── Money.java               # 值对象——金额
│   │   │   ├── Address.java             # 值对象——地址
│   │   │   └── OrderStatus.java         # 枚举——订单状态
│   │   └── event/
│   │       ├── OrderCreatedEvent.java   # 领域事件
│   │       └── OrderPaidEvent.java
│   ├── repository/
│   │   └── OrderRepository.java         # Repository 接口——只有接口——没有实现
│   └── service/
│       ├── OrderDomainService.java      # 领域服务——跨聚合的逻辑
│       └── PricingService.java          # 领域服务——价格计算策略
│
└── infrastructure/                      ← ④ 基础设施层
    ├── persistence/
    │   ├── OrderRepositoryImpl.java     # Repository 实现——调 JPA/MyBatis
    │   ├── mapper/
    │   │   ├── OrderMapper.java         # MyBatis Mapper
    │   │   └── OrderItemMapper.java
    │   └── converter/
    │       └── OrderConverter.java      # DO ↔ Domain 对象转换
    ├── messaging/
    │   └── RocketMQEventPublisher.java  # 事件发布实现——发到 RocketMQ
    └── external/
        └── UserServiceAdapter.java      # 防腐层——隔离外部 User 服务
```

<strong>依赖方向——只能是单向的</strong>：

```
interfaces → application → domain ← infrastructure
                                  ↑
                              只有 infrastructure 依赖 domain
                              domain 不依赖任何其他层——纯 Java——不依赖 Spring/MyBatis/RocketMQ
```

> ⚠️ 新手提示：依赖方向是最容易搞反的——`domain` 层不能 import `@Service`、`@Autowired`、`@Entity`、`@Table`——domain 层是纯 POJO——不依赖任何框架。你想在聚合根上加 `@Table(name="t_order")` → 这就错了——那是 infrastructure 层的事。

## 三、🏰 聚合根——完整的实现

### 3.1 Order 聚合根——完整代码

```java
// domain/model/aggregate/Order.java
// 聚合根——纯 POJO——不依赖任何框架
// 所有业务逻辑都在这里——Service 层只做编排

public class Order {
    // ========== 字段 ==========
    private Long id;
    private String orderNo;
    private Long userId;                  // 引用 User 聚合——只存 ID
    private Money totalAmount;            // 值对象
    private Address deliveryAddress;      // 值对象
    private OrderStatus status;
    private List<OrderItem> items;        // 聚合内部实体
    private LocalDateTime createdAt;
    private LocalDateTime updatedAt;

    // 领域事件——临时收集——Repository 保存后发布
    private List<DomainEvent> domainEvents = new ArrayList<>();

    // ========== 构造函数——创建聚合时必须满足不变量 ==========
    // 不对外暴露——通过静态工厂方法创建
    private Order(Long userId, Address deliveryAddress, List<OrderItem> items) {
        if (userId == null) {
            throw new IllegalArgumentException("用户 ID 不能为空");
        }
        if (deliveryAddress == null) {
            throw new IllegalArgumentException("收货地址不能为空");
        }
        if (items == null || items.isEmpty()) {
            throw new IllegalArgumentException("订单项不能为空");
        }

        this.userId = userId;
        this.deliveryAddress = deliveryAddress;
        this.items = new ArrayList<>(items);
        this.orderNo = generateOrderNo();
        this.status = OrderStatus.PENDING_PAY;
        this.totalAmount = calculateTotalAmount();
        this.createdAt = LocalDateTime.now();
        this.updatedAt = LocalDateTime.now();

        // 注册领域事件——"订单已创建"
        this.domainEvents.add(new OrderCreatedEvent(
                this.id, this.orderNo, this.userId, this.totalAmount));
    }

    // ========== 静态工厂方法——创建聚合的入口 ==========
    public static Order create(Long userId, Address deliveryAddress,
                                List<OrderItem> items) {
        return new Order(userId, deliveryAddress, items);
    }

    // ========== 业务方法——聚合根的核心——保护不变量 ==========

    // ① 修改收货地址——有业务规则
    public void changeDeliveryAddress(Address newAddress) {
        if (this.status != OrderStatus.PENDING_PAY) {
            throw new BusinessException("只有待支付订单才能修改收货地址");
        }
        if (Duration.between(this.createdAt, LocalDateTime.now()).toMinutes() > 10) {
            throw new BusinessException("下单超过 10 分钟不能修改收货地址");
        }
        this.deliveryAddress = Objects.requireNonNull(newAddress);
        this.updatedAt = LocalDateTime.now();
    }

    // ② 添加订单项——防止重复添加
    public void addItem(OrderItem item) {
        if (this.status != OrderStatus.PENDING_PAY) {
            throw new BusinessException("待支付状态才能修改订单项");
        }
        if (items.stream().anyMatch(i -> i.getProductId().equals(item.getProductId()))) {
            throw new BusinessException("该商品已在订单中");
        }
        this.items.add(item);
        this.totalAmount = calculateTotalAmount();
        this.updatedAt = LocalDateTime.now();
    }

    // ③ 支付——聚合状态的迁移
    public void pay(Money paidAmount) {
        if (this.status != OrderStatus.PENDING_PAY) {
            throw new BusinessException("只有待支付订单才能支付——当前状态：" + this.status);
        }
        if (!this.totalAmount.equals(paidAmount)) {
            throw new BusinessException("支付金额不匹配——应付：" + this.totalAmount
                    + "——实付：" + paidAmount);
        }
        this.status = OrderStatus.PAID;
        this.updatedAt = LocalDateTime.now();

        // 注册领域事件——"订单已支付"
        this.domainEvents.add(new OrderPaidEvent(this.id, this.orderNo, this.userId));
    }

    // ④ 取消——不同状态有不同的取消规则
    public void cancel(String reason) {
        if (this.status == OrderStatus.SHIPPED
                || this.status == OrderStatus.DELIVERED) {
            throw new BusinessException("已发货的订单不能取消——可走退货流程");
        }
        if (this.status == OrderStatus.CANCELLED) {
            throw new BusinessException("订单已取消——不能重复取消");
        }
        this.status = OrderStatus.CANCELLED;
        this.updatedAt = LocalDateTime.now();

        // 注册领域事件——"订单已取消"
        this.domainEvents.add(new OrderCancelledEvent(this.id, this.orderNo, reason));
    }

    // ⑤ 发货——标记发货
    public void ship(String trackingNumber) {
        if (this.status != OrderStatus.PAID) {
            throw new BusinessException("只有已支付订单才能发货");
        }
        this.status = OrderStatus.SHIPPED;
        this.updatedAt = LocalDateTime.now();
        this.domainEvents.add(new OrderShippedEvent(this.id, this.orderNo, trackingNumber));
    }

    // ========== 领域事件收集——Repository 在 save 后调用 ==========
    public List<DomainEvent> pollDomainEvents() {
        List<DomainEvent> events = new ArrayList<>(this.domainEvents);
        this.domainEvents.clear();
        return events;
    }

    // ========== 查询方法——不影响状态 ==========
    public boolean canBeCancelled() {
        return this.status == OrderStatus.PENDING_PAY
                || this.status == OrderStatus.PAID;
    }

    public int getTotalItemCount() {
        return items.stream().mapToInt(OrderItem::getQuantity).sum();
    }

    // ========== 内部辅助 ==========
    private String generateOrderNo() {
        return "ORD" + LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyyMMddHHmmss"))
                + String.format("%04d", new Random().nextInt(10000));
    }

    private Money calculateTotalAmount() {
        return items.stream()
                .map(OrderItem::getSubTotal)
                .reduce(new Money(BigDecimal.ZERO, "CNY"), Money::add);
    }

    // ========== getter——只读——没有 setter ==========
    // 外部不能随意修改聚合的属性——只能通过聚合根的业务方法
    public Long getId() { return id; }
    public String getOrderNo() { return orderNo; }
    public Long getUserId() { return userId; }
    public Money getTotalAmount() { return totalAmount; }
    public Address getDeliveryAddress() { return deliveryAddress; }
    public OrderStatus getStatus() { return status; }
    public List<OrderItem> getItems() { return Collections.unmodifiableList(items); }
    public LocalDateTime getCreatedAt() { return createdAt; }

    // 只有 package-private 的 setter——给 Repository 实现用（在 infrastructure 层）
    void setId(Long id) { this.id = id; }
}
```

### 3.2 聚合根设计的四个检查点

| 检查点 | 验证 | Order 是怎么做的 |
|------|------|------|
| <strong>不变量保护</strong> | 构造函数参数非法时拒绝创建 | userId 不能为 null——items 不能为空 |
| <strong>状态迁移</strong> | 状态只能通过业务方法改变 | 不能 `order.setStatus(PAID)`——必须 `order.pay(amount)` |
| <strong>跨聚合引用</strong> | 只存 ID——不存对象 | `private Long userId`——不是 `private User user` |
| <strong>领域事件</strong> | 聚合状态变化后注册事件 | pay() 后注册 OrderPaidEvent |

## 四、📦 Repository——接口在 domain——实现在 infrastructure

### 4.1 Repository 接口——定义在 domain 层

```java
// domain/repository/OrderRepository.java
// 接口在 domain 层——只定义"领域需要的操作"——不暴露数据库细节
// 不依赖 MyBatis、JPA——纯 Java 接口

public interface OrderRepository {

    // ① 按 ID 查询
    Optional<Order> findById(Long id);

    // ② 按订单号查询
    Optional<Order> findByOrderNo(String orderNo);

    // ③ 查询用户的订单——返回领域对象——不是 DO
    List<Order> findByUserId(Long userId);

    // ④ 保存聚合——保存的是聚合根——连带保存聚合内部的实体
    void save(Order order);

    // ⑤ 删除
    void delete(Order order);

    // ⑥ 查询待支付的超时订单——领域关注的查询条件
    List<Order> findPendingPaymentBefore(LocalDateTime deadline);
}
```

```java
// domain/repository/ProductRepository.java
// Product 是另一个聚合——有自己的 Repository

public interface ProductRepository {
    Optional<Product> findById(Long productId);
    List<Product> findByIds(List<Long> productIds);
    void save(Product product);
}
```

> ⚠️ 新手提示：Repository 不要定义 `findByNameLike(String keyword)` 这种通配符查询方法——那是 DAO 的思维。Repository 是"聚合的仓库"——提供领域需要的入口——不是"能执行的所有 SQL 查询集合"。

### 4.2 Repository 实现——在 infrastructure 层

```java
// infrastructure/persistence/OrderRepositoryImpl.java
// 实现在 infrastructure 层——依赖 MyBatis
// 做两件事：① DO ↔ Domain 转换 ② 调 Mapper

@Repository  // ← Spring 注解只能在 infrastructure 层
public class OrderRepositoryImpl implements OrderRepository {

    @Autowired
    private OrderMapper orderMapper;
    @Autowired
    private OrderItemMapper orderItemMapper;

    @Override
    public Optional<Order> findById(Long id) {
        OrderDO orderDO = orderMapper.selectById(id);
        if (orderDO == null) return Optional.empty();

        List<OrderItemDO> itemDOs = orderItemMapper.selectByOrderId(id);
        return Optional.of(OrderConverter.toDomain(orderDO, itemDOs));
    }

    @Override
    public void save(Order order) {
        // ① 转换为 DO
        OrderDO orderDO = OrderConverter.toDO(order);
        List<OrderItemDO> itemDOs = OrderConverter.toItemDOs(order);

        // ② 如果 ID 为 null——新增；否则——更新
        if (order.getId() == null) {
            orderMapper.insert(orderDO);
            // 回填 ID——聚合根需要 ID
            order.setId(orderDO.getId());
            for (OrderItemDO itemDO : itemDOs) {
                itemDO.setOrderId(orderDO.getId());
                orderItemMapper.insert(itemDO);
            }
        } else {
            orderMapper.updateById(orderDO);
            // 订单项的更新——先删后插（简单实现——生产可以用 merge）
            orderItemMapper.deleteByOrderId(order.getId());
            for (OrderItemDO itemDO : itemDOs) {
                itemDO.setOrderId(order.getId());
                orderItemMapper.insert(itemDO);
            }
        }
    }

    @Override
    public void delete(Order order) {
        orderItemMapper.deleteByOrderId(order.getId());
        orderMapper.deleteById(order.getId());
    }

    // ... 其他方法
}
```

### 4.3 DO ↔ Domain 转换器

```java
// infrastructure/persistence/converter/OrderConverter.java
// 专门负责 DO ↔ Domain 对象的转换
// 转换逻辑集中在一处——不散落在 Service 或 Mapper 中

public class OrderConverter {

    public static OrderDO toDO(Order order) {
        OrderDO orderDO = new OrderDO();
        orderDO.setId(order.getId());
        orderDO.setOrderNo(order.getOrderNo());
        orderDO.setUserId(order.getUserId());
        orderDO.setTotalAmount(order.getTotalAmount().getAmount());  // Money → BigDecimal
        orderDO.setCurrency(order.getTotalAmount().getCurrency());
        orderDO.setProvince(order.getDeliveryAddress().getProvince()); // Address → 字段
        orderDO.setCity(order.getDeliveryAddress().getCity());
        orderDO.setDistrict(order.getDeliveryAddress().getDistrict());
        orderDO.setDetail(order.getDeliveryAddress().getDetail());
        orderDO.setZipCode(order.getDeliveryAddress().getZipCode());
        orderDO.setStatus(order.getStatus().name());
        orderDO.setCreatedAt(order.getCreatedAt());
        return orderDO;
    }

    public static Order toDomain(OrderDO orderDO, List<OrderItemDO> itemDOs) {
        Address address = new Address(
                orderDO.getProvince(), orderDO.getCity(),
                orderDO.getDistrict(), orderDO.getDetail(),
                orderDO.getZipCode());

        List<OrderItem> items = itemDOs.stream()
                .map(OrderConverter::toDomainItem)
                .toList();

        // 用反射或 package-private 构造器重建聚合根
        // 这里可以用 Builder 模式——或者给 Repository 留一个 package-private 的重建方法
        Order order = Order.reconstruct(
                orderDO.getId(), orderDO.getOrderNo(), orderDO.getUserId(),
                new Money(orderDO.getTotalAmount(), orderDO.getCurrency()),
                address, OrderStatus.valueOf(orderDO.getStatus()),
                items, orderDO.getCreatedAt()
        );
        return order;
    }

    private static OrderItem toDomainItem(OrderItemDO itemDO) {
        return new OrderItem(
                itemDO.getId(), itemDO.getProductId(), itemDO.getProductName(),
                new Money(itemDO.getPrice(), itemDO.getCurrency()),
                itemDO.getQuantity());
    }
}
```

```java
// 在 Order 聚合根中——给 Repository 实现留一个重建方法
// domain/model/aggregate/Order.java
public class Order {

    // ... 之前的代码

    // package-private——只给 Repository 实现用——外部不能调
    // DDD 官方称为 "reconstitution"（重建）
    static Order reconstruct(Long id, String orderNo, Long userId,
                              Money totalAmount, Address deliveryAddress,
                              OrderStatus status, List<OrderItem> items,
                              LocalDateTime createdAt) {
        Order order = new Order(userId, deliveryAddress, items);
        order.id = id;
        order.orderNo = orderNo;
        order.totalAmount = totalAmount;
        order.status = status;
        order.createdAt = createdAt;
        return order;
    }
}
```

## 五、🎯 Domain Service vs Application Service——最难的分界线

### 5.1 判断标准——逻辑归谁

```
Application Service（应用服务）——编排——没有业务逻辑
  ① 接收请求——转成领域对象
  ② 调 Repository 查聚合
  ③ 调聚合根的业务方法（业务逻辑在聚合根中）
  ④ 调 Repository 保存聚合
  ⑤ 发布领域事件
  ⑥ 返回结果

Domain Service（领域服务）——业务逻辑——当逻辑不属于任何一个聚合时
  ① 跨聚合的复杂计算
  ② 调用外部服务的编排——但需要领域知识
  ③ 多聚合的协调——但不在一个事务中
```

<strong>黄金判断——问自己三个问题</strong>：

```
问题 1：这个逻辑能放到现有的聚合根里吗？
  → 能 → 放聚合根——不要建 Domain Service
  → "判断用户是否首单" → 可以放在 OrderDomainService.isFirstOrder(userId) —— 因为需要查 OrderRepository 的历史订单——Order 自己不知道

问题 2：这个逻辑涉及多个聚合吗？
  → 是 → Domain Service
  → "计算订单总价时——是否应用首单折扣" → 需要查 OrderRepository + PricingStrategy → Domain Service

问题 3：这个逻辑是"编排"还是"计算/判断"？
  → 编排（第一步做 A 第二步做 B）→ Application Service
  → 计算/判断（有业务规则）→ Domain Service
```

### 5.2 完整示例——同一场景中三者的分工

```java
// ========== Application Service——编排 ==========
// application/OrderApplicationService.java
@Service
public class OrderApplicationService {

    @Autowired
    private OrderRepository orderRepository;
    @Autowired
    private ProductRepository productRepository;
    @Autowired
    private UserRepository userRepository;
    @Autowired
    private OrderDomainService orderDomainService;
    @Autowired
    private OrderEventPublisher eventPublisher;

    @Transactional
    public OrderResponse createOrder(CreateOrderCommand command) {
        // ① 加载聚合——通过 Repository
        List<Product> products = productRepository.findByIds(
                command.getItems().stream()
                        .map(CreateOrderCommand.OrderItemCommand::getProductId)
                        .toList());

        // ② 调用 Domain Service——跨聚合的领域逻辑
        List<OrderItem> orderItems = orderDomainService.createOrderItems(
                command.getItems(), products);

        // ③ 调用 Domain Service——计算价格（可能涉及折扣策略）
        Money totalPrice = orderDomainService.calculatePrice(
                command.getUserId(), orderItems);

        // ④ 创建聚合根——业务逻辑在聚合根构造函数中
        Order order = Order.create(
                command.getUserId(),
                command.getDeliveryAddress(),
                orderItems);

        // ⑤ 持久化——调 Repository
        orderRepository.save(order);

        // ⑥ 发布领域事件——异步
        for (DomainEvent event : order.pollDomainEvents()) {
            eventPublisher.publish(event);
        }

        // ⑦ 返回结果——DTO 转换
        return OrderResponse.from(order);
    }
}
```

```java
// ========== Domain Service——跨聚合的领域逻辑 ==========
// domain/service/OrderDomainService.java
// 注意：Domain Service 是纯 POJO——不加 @Service——不依赖 Spring
// 如果需要 Spring 管理——加 @Service 也可以——但逻辑上它是 domain 层的东西

public class OrderDomainService {

    /**
     * 创建订单项——校验商品状态、库存、生成 OrderItem
     * 这是领域逻辑——因为涉及"商品是否可售"、"价格快照"等业务规则
     * 不属于任何一个聚合根——所以放在 Domain Service
     */
    public List<OrderItem> createOrderItems(
            List<CreateOrderCommand.OrderItemCommand> commands,
            List<Product> products) {

        // 把 Product 列表转为 Map——方便查找
        Map<Long, Product> productMap = products.stream()
                .collect(Collectors.toMap(Product::getId, Function.identity()));

        List<OrderItem> items = new ArrayList<>();
        for (CreateOrderCommand.OrderItemCommand cmd : commands) {
            Product product = productMap.get(cmd.getProductId());
            if (product == null) {
                throw new BusinessException("商品不存在——ID：" + cmd.getProductId());
            }
            if (!product.isOnSale()) {
                throw new BusinessException("商品 " + product.getName() + " 已下架");
            }
            if (!product.hasEnoughStock(cmd.getQuantity())) {
                throw new BusinessException("商品 " + product.getName() + " 库存不足");
            }

            // 创建 OrderItem——价格拍照（快照）——防止商品涨价后历史订单金额被影响
            OrderItem item = new OrderItem(
                    product.getId(),
                    product.getName(),     // ← 快照——商品改名不影响订单
                    product.getPrice(),    // ← 快照——商品涨价不影响订单
                    cmd.getQuantity());
            items.add(item);
        }
        return items;
    }

    /**
     * 计算订单总价——可能包含折扣策略
     * 折扣策略本身是另一个 Domain Service：PricingService
     */
    public Money calculatePrice(Long userId, List<OrderItem> items) {
        Money basePrice = items.stream()
                .map(OrderItem::getSubTotal)
                .reduce(new Money(BigDecimal.ZERO, "CNY"), Money::add);

        // 折扣由 PricingService 处理——PricingService 也是 Domain Service
        return basePrice;  // 这里简化——下一篇讲折扣策略
    }
}
```

```java
// ========== 聚合根——保护不变量 ==========
// domain/model/aggregate/Order.java
// 业务逻辑都在聚合根里——Application Service 不包含业务判断
public class Order {

    public void pay(Money paidAmount) {
        // 业务逻辑：只有待支付才能支付、金额必须匹配
        if (this.status != OrderStatus.PENDING_PAY) {
            throw new BusinessException("只有待支付订单才能支付");
        }
        if (!this.totalAmount.equals(paidAmount)) {
            throw new BusinessException("支付金额不匹配");
        }
        this.status = OrderStatus.PAID;
        this.domainEvents.add(new OrderPaidEvent(this.id, this.orderNo, this.userId));
    }
}
```

<strong>三层分工——一句话</strong>：

| 层 | 职责 | 一句话 | 示例 |
|------|------|------|------|
| <strong>Application Service</strong> | 编排 | "第一步做什么、第二步做什么" | 查用户 → 查商品 → 创建订单 → 保存 → 发事件 |
| <strong>Domain Service</strong> | 跨聚合计算 | "这个计算涉及多个聚合——放不进任何一个里面" | 计算首单折扣（需要查历史订单 + 商品 + 价格策略） |
| <strong>聚合根</strong> | 保护不变量 | "我这个聚合的数据不能变成非法状态" | 支付时校验状态 + 金额——状态转移 |

## 六、🛡️ 防腐层（ACL）——隔离外部系统

### 6.1 问题——外部 UserService 的模型入侵

```
场景：OrderService 创建订单时需要查用户信息——用户是在 UserService（另一个服务）中的

不用防腐层——直接依赖外部模型：
  @Autowired
  private UserClient userClient;  // Feign 接口——外部定义的

  UserDTO user = userClient.getUser(userId);  // UserDTO 是外部定义的——100 个字段
  // 你只用了 userId 和 membershipLevel 两个字段
  // 但哪天 UserDTO 加了 10 个字段——你的编译没问题——运行时却可能受影响
  // 哪天 UserDTO 删了一个字段——你编译失败——虽然你不用这个字段
```

### 6.2 防腐层的实现

```java
// ========== 订单上下文自己的 Buyer 模型 ==========
// domain/model/valueobject/Buyer.java
// 注意：这是 OrderContext 中的 Buyer——不是 UserContext 中的 User
// 只包含订单上下文关心的字段

public class Buyer {
    private Long userId;
    private String nickname;
    private MembershipLevel membershipLevel;  // 值对象——会员等级
    private Address defaultAddress;           // 值对象——默认收货地址

    // 订单上下文的 Buyer 只需要这些——不需要 password、phone、email 等认证信息

    public boolean isVip() {
        return membershipLevel == MembershipLevel.VIP
                || membershipLevel == MembershipLevel.SVIP;
    }
}
```

```java
// ========== 防腐层——翻译外部模型 ==========
// infrastructure/external/UserServiceAdapter.java
// 在 infrastructure 层——依赖外部 Feign 接口
// 把外部 UserDTO 翻译成订单上下文中的 Buyer

@Component
public class UserServiceAdapter {

    @Autowired
    private UserClient userClient;  // Feign——外部服务的接口

    /**
     * 从外部 UserService 获取用户信息——翻译成订单上下文的 Buyer
     * 外部 UserDTO 有 100 个字段 → Buyer 只保留订单需要的 4 个字段
     */
    public Buyer getBuyer(Long userId) {
        UserDTO userDTO = userClient.getUser(userId);
        if (userDTO == null) {
            throw new BusinessException("用户不存在——ID：" + userId);
        }

        // 翻译——外部模型 → 领域模型
        return new Buyer(
                userDTO.getId(),
                userDTO.getNickname(),
                MembershipLevel.fromString(userDTO.getMembershipLevel()),
                new Address(
                        userDTO.getDefaultProvince(),
                        userDTO.getDefaultCity(),
                        userDTO.getDefaultDistrict(),
                        userDTO.getDefaultDetail(),
                        userDTO.getDefaultZipCode()
                )
        );
    }
}
```

```java
// ========== 在 Application Service 中使用防腐层 ==========
// application/OrderApplicationService.java
@Service
public class OrderApplicationService {

    @Autowired
    private UserServiceAdapter userServiceAdapter;  // 防腐层——不是直接注入 UserClient
    @Autowired
    private OrderRepository orderRepository;

    @Transactional
    public OrderResponse createOrder(CreateOrderCommand command) {
        // 通过防腐层获取 Buyer——不直接接触外部 UserDTO
        Buyer buyer = userServiceAdapter.getBuyer(command.getUserId());

        if (!buyer.isVip()) {
            // 非 VIP 的某些限制...
        }

        // ... 其余逻辑
    }
}
```

<strong>防腐层的价值</strong>：外部系统变了——只改防腐层内部——Application Service 和 Domain 层的代码不受影响。外部 UserDTO 加了 50 个字段或删了 10 个字段——你只改 UserServiceAdapter 中的翻译逻辑——业务逻辑不受影响。

## 七、📢 领域事件的事务性发布

### 7.1 问题——事务还没提交就发了事件

```java
@Transactional
public void createOrder(CreateOrderCommand command) {
    Order order = Order.create(...);
    orderRepository.save(order);     // ← 还在事务中——还没 commit

    // ❌ 如果在这里直接发事件——消费者可能读到未提交的数据
    for (DomainEvent event : order.pollDomainEvents()) {
        eventPublisher.publish(event);  // 消费者此时查不到这条订单——还没 commit
    }
}  // ← 事务在这里 commit
```

### 7.2 解决方案一——Spring 的 @TransactionalEventListener

```java
// application/OrderApplicationService.java
@Service
public class OrderApplicationService {

    @Autowired
    private OrderRepository orderRepository;
    @Autowired
    private ApplicationEventPublisher springEventPublisher;

    @Transactional
    public void createOrder(CreateOrderCommand command) {
        Order order = Order.create(...);
        orderRepository.save(order);

        // 用 Spring 的 ApplicationEventPublisher——发到 Spring 内部的事件总线
        for (DomainEvent event : order.pollDomainEvents()) {
            springEventPublisher.publishEvent(event);
        }
    }
}

// ========== 事件处理器——在事务提交后才执行 ==========
@Component
public class OrderEventDispatcher {

    @TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT)
    public void onOrderCreated(OrderCreatedEvent event) {
        // 事务已经提交——订单已经入库——安全发送到 MQ
        rocketMQTemplate.syncSend("order-created-topic", event);
    }

    @TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT)
    public void onOrderPaid(OrderPaidEvent event) {
        rocketMQTemplate.syncSend("order-paid-topic", event);
    }
}
```

### 7.3 解决方案二——Outbox 模式（更可靠——生产推荐）

```java
// Domain 层——事件存储接口
// domain/repository/EventStore.java
public interface EventStore {
    void save(DomainEvent event);
    List<DomainEvent> findUnpublished();
    void markPublished(Long eventId);
}

// Infrastructure 层——事件存储实现
// infrastructure/persistence/EventStoreImpl.java
@Repository
public class EventStoreImpl implements EventStore {

    @Autowired
    private EventMapper eventMapper;

    @Override
    public void save(DomainEvent event) {
        EventDO eventDO = new EventDO();
        eventDO.setEventType(event.getClass().getSimpleName());
        eventDO.setPayload(JsonUtil.toJson(event));  // 序列化事件
        eventDO.setStatus("UNPUBLISHED");
        eventMapper.insert(eventDO);
    }
}

// Application Service——保存事件和聚合在同一个事务中
@Transactional
public void createOrder(CreateOrderCommand command) {
    Order order = Order.create(...);
    orderRepository.save(order);

    // 领域事件和聚合一起保存在同一个数据库中——同一个事务
    for (DomainEvent event : order.pollDomainEvents()) {
        eventStore.save(event);  // ← 存在同一数据库——事务保证一致性
    }
}

// 定时任务——异步扫描未发布的事件——发送到 MQ
@Scheduled(fixedDelay = 1000)
public void publishUnpublishedEvents() {
    List<DomainEvent> events = eventStore.findUnpublished();
    for (DomainEvent event : events) {
        try {
            rocketMQTemplate.syncSend(getTopic(event), event);
            eventStore.markPublished(event.getId());
        } catch (Exception e) {
            log.error("事件发送失败——eventId={}", event.getId(), e);
            // 下次定时任务重试——at-least-once——消费者需要幂等
        }
    }
}
```

> ⚠️ 新手提示：Outbox 模式的本质是——事件和聚合存在一起（同一个数据库——同一个事务——保证了原子性），然后异步从 Outbox 表中读出事件发送到 MQ。比直接发 MQ 可靠——因为如果 MQ 挂了——事务回滚——聚合也没插入——不会出现"聚合已存、事件丢失"的中间状态。

## 八、🏭 Factory——封装复杂的聚合创建

### 8.1 问题——聚合的创建逻辑散落各处

```
Order 的聚合根构造函数是 private 的——通过 static factory method create() 创建

但如果创建逻辑很复杂呢？
  → 先查 User 服务——获取 Buyer 信息
  → 再查 Product 服务——获取商品价格
  → 再查 Pricing 服务——获取折扣策略
  → 计算运费
  → 生成订单号（如果订单号不是随机——而是从序列服务获取）

这些调用放在 Application Service 中——Application Service 就膨胀了
Factory 封装复杂的创建过程——Application Service 只需要一行调用
```

### 8.2 Factory 实现

```java
// domain/factory/OrderFactory.java
// Factory 在 domain 层——但可能依赖 infrastructure 层的防腐层
// 所以其实现在 infrastructure 层——接口在 domain 层

public interface OrderFactory {
    Order createOrder(Long userId, Address deliveryAddress,
                       List<OrderItemCommand> itemCommands);
}

// infrastructure/factory/OrderFactoryImpl.java
@Component
public class OrderFactoryImpl implements OrderFactory {

    @Autowired
    private ProductRepository productRepository;
    @Autowired
    private UserServiceAdapter userServiceAdapter;
    @Autowired
    private OrderDomainService orderDomainService;
    @Autowired
    private OrderNoGenerator orderNoGenerator;  // 订单号生成——可能调 Redis 自增

    @Override
    public Order createOrder(Long userId, Address deliveryAddress,
                              List<OrderItemCommand> itemCommands) {
        // ① 获取买家信息——防腐层
        Buyer buyer = userServiceAdapter.getBuyer(userId);

        // ② 查询商品——校验库存
        List<Long> productIds = itemCommands.stream()
                .map(OrderItemCommand::getProductId).toList();
        List<Product> products = productRepository.findByIds(productIds);

        // ③ 创建订单项——Domain Service
        List<OrderItem> orderItems = orderDomainService.createOrderItems(
                itemCommands, products);

        // ④ 创建订单——调用聚合根的静态工厂方法
        Order order = Order.create(userId, deliveryAddress, orderItems);

        return order;
    }
}
```

```java
// Application Service——用 Factory 简化
@Transactional
public OrderResponse createOrder(CreateOrderCommand command) {
    // 一行——创建聚合
    Order order = orderFactory.createOrder(
            command.getUserId(),
            command.getDeliveryAddress(),
            command.getItems());

    orderRepository.save(order);
    publishDomainEvents(order.pollDomainEvents());
    return OrderResponse.from(order);
}
```

## 🎯 总结

1. <strong>四层架构——依赖方向是铁律</strong>：interfaces → application → domain ← infrastructure。domain 层是纯 POJO——不依赖 Spring、MyBatis、RocketMQ。聚合根、值对象、Repository 接口、领域事件——全在 domain 层——纯 Java。

2. <strong>Repository 接口在 domain——实现在 infrastructure</strong>：domain 定义了"领域需要的聚合入口"（findById/save/delete），infrastructure 用 MyBatis/JPA 实现——并做 DO ↔ Domain 对象转换。不是在 Service 中直接调 Mapper——那样领域逻辑又散落了。

3. <strong>Application Service 编排——Domain Service 跨聚合计算——聚合根保护不变量</strong>：判断"逻辑归谁"的三个问题——"能放聚合根吗？""涉及多个聚合吗？""是编排还是计算/判断？"——答完就知道放哪。

4. <strong>防腐层隔离外部系统——Outbox 保证事件可靠发布</strong>：外部模型通过 Adapter 翻译成领域模型——外部变了只改防腐层。领域事件用 Outbox 模式——和聚合在同一个事务中持久化——定时任务异步发送到 MQ——消费者幂等。

> 📖 <strong>下一步阅读</strong>：代码模板有了——回头看我们之前的 order-service / user-service / product-service——用 DDD 的视角重构它们——什么时候该用 DDD、什么时候 MVC 就够了？继续阅读 [<strong>回顾微服务——用 DDD 重构已有代码</strong>]({{< relref "DddRefactor.md" >}})。
