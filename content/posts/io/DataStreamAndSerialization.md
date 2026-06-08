---
title: "Java IO 进阶"
date: 2022-09-09T14:50:18+00:00
tags: ["基础技术"]
categories: ["IO操作类"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "Java IO 进阶：掌握 DataInputStream/DataOutputStream 读写基本类型、PrintStream/PrintWriter 打印流、以及对象序列化与反序列化的核心用法与常见陷阱"
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

# Java IO 进阶：基本类型 IO、打印流与对象序列化实用指南

## 1 🎮 问题场景：从保存游戏分数说起

假设你正在开发一个本地小游戏，需要把玩家的最高分（`int`）、胜率（`double`）和昵称（`String`）保存到文件，下次启动时读回来。用前面学过的 `FileWriter` 写文本当然可以，但你需要手动处理类型转换——写的时候 `int` → `String`，读的时候 `String` → `int`，格式稍微不一致就解析失败。

有没有办法直接把 `int` 按固定 4 字节的二进制格式写入，读的时候也按 `int` 原样读出？这就是 **基本类型 IO** 要解决的问题。

更进一步，如果整个游戏状态是一个复杂的 Java 对象（玩家信息、关卡进度、道具列表），能不能 **一键保存整个对象，一键读回** ？这就是 **对象序列化** 要解决的问题。

本篇覆盖 Java IO 的第四个进阶阶段，依次讲解三种机制：

| 机制 | 用途 | 一句话描述 |
|------|------|----------|
| DataInputStream / DataOutputStream | 读写基本类型和字符串 | 按固定字节数的二进制格式读写，必须按序操作 |
| PrintStream / PrintWriter | 格式化文本输出 | 不抛异常，日常 `System.out.println()` 就在用它 |
| ObjectInputStream / ObjectOutputStream | 对象序列化与反序列化 | 一键将整个对象转为字节流保存或传输 |

## 2 💾 基本类型 IO：DataOutputStream / DataInputStream

### 2.1 ❓ 是什么

`DataOutputStream` 和 `DataInputStream` 是 **装饰器流** （包装已有的 `OutputStream` / `InputStream`），提供直接读写 Java 基本类型和 `String` 的能力。数据以 **平台无关的二进制格式** 写入——比如 `writeInt(42)` 始终写 4 个字节，无论在什么操作系统上，读出来的值都不变。

<span style="color:red">**核心约束**</span> ：读的顺序必须和写的顺序完全一致。写的时候是 `int → double → String`，读的时候也必须是 `int → double → String`。因为 **文件中没有类型标记**——全是二进制字节，读的 API 只是机械地按指定的字节数解析。如果用 `readDouble()` 去读一个用 `writeInt()` 写入的 4 字节数据，会读到错误的数值。

### 2.2 🛠️ 怎么用

**写入基本类型与字符串**：

```java
try (DataOutputStream dos = new DataOutputStream(
        new FileOutputStream("data.bin"))) {
    dos.writeInt(100);           // int: 4 字节
    dos.writeDouble(3.14);       // double: 8 字节
    dos.writeBoolean(true);      // boolean: 1 字节
    dos.writeUTF("hello");       // String: 变长编码（前 2 字节为长度）
}
```

**读回（必须按写入顺序）**：

```java
try (DataInputStream dis = new DataInputStream(
        new FileInputStream("data.bin"))) {
    int value = dis.readInt();        // 先读 int
    double pi = dis.readDouble();     // 再读 double
    boolean flag = dis.readBoolean(); // 再读 boolean
    String text = dis.readUTF();      // 最后读 String
    // value=100, pi=3.14, flag=true, text="hello"
}
```

<span style="color:red">**常见错误**</span> ：如果写入顺序是 `writeInt → writeDouble → writeUTF`，读取顺序却是 `readUTF → readInt → readDouble`，不会抛异常，但读出的数据是乱码——因为 `readUTF` 把 `int` 的前 2 字节当作字符串长度来解析。

### 2.3 📋 常用方法一览

| 方法 | 写入/读取类型 | 占用字节数 |
|------|:---:|:---:|
| `writeInt()` / `readInt()` | `int` | 4 字节 |
| `writeLong()` / `readLong()` | `long` | 8 字节 |
| `writeDouble()` / `readDouble()` | `double` | 8 字节 |
| `writeFloat()` / `readFloat()` | `float` | 4 字节 |
| `writeShort()` / `readShort()` | `short` | 2 字节 |
| `writeByte()` / `readByte()` | `byte` | 1 字节 |
| `writeBoolean()` / `readBoolean()` | `boolean` | 1 字节 |
| `writeChar()` / `readChar()` | `char` | 2 字节 |
| `writeUTF()` / `readUTF()` | `String` | 变长（前 2 字节为 UTF-8 编码的字节长度） |

### 2.4 🏗️ 实际开发中的应用场景

- **网络协议** ：自定义二进制协议时，协议头可以用 `DataOutputStream` 写入固定字节数的字段（消息长度、类型标识），接收端用 `DataInputStream` 按约定顺序解析
- **游戏存档** ：分数、坐标、生命值等数值直接以二进制形式存储，比纯文本更紧凑
- **跨语言数据交换的底层**：虽然上层常用 Protobuf、Thrift 等框架，但它们本质上也是把数据序列化为一种平台无关的二进制格式，理解 `DataInputStream` / `DataOutputStream` 有助于理解这些框架的底层原理

## 3 🖨️ 打印流：PrintStream / PrintWriter

### 3.1 ❓ 是什么

打印流是 Java 中最常用的输出流之一。它的核心特征是 **不抛 `IOException`** ——所有写操作在内部捕获异常，出错了静默处理，你可以通过 `checkError()` 方法检查是否发生过错误。

Java 提供两个版本：

| 类 | 面向 | 典型实例 |
|------|------|------|
| `PrintStream` | 字节流（`OutputStream` 的子类） | `System.out`、`System.err` |
| `PrintWriter` | 字符流（`Writer` 的子类） | `response.getWriter()`（Servlet）、`new PrintWriter(file)` |

`System.out` 就是一个全局的 `PrintStream` 实例，所以你在任何地方写 `System.out.println()` 都不需要处理异常——这正是打印流的设计目的：让日常输出变得简单。

### 3.2 🛠️ 怎么用

**PrintStream（字节流版本）**：

```java
// System.out 就是 PrintStream，日常最常用的输出方式
System.out.println("Hello");          // 输出并换行
System.out.print("no newline");       // 只输出，不换行
System.out.printf("value=%d\n", 42);  // 格式化输出（类似 C 的 printf）

// 也可以自己创建，包装文件
try (PrintStream ps = new PrintStream("log.txt")) {
    ps.println("第一条日志");
    ps.printf("用户ID: %d, 姓名: %s\n", 1001, "张三");
    // 不需要 try-catch IOException
}
```

**PrintWriter（字符流版本）**：

```java
// 包装文件输出
try (PrintWriter pw = new PrintWriter("output.txt")) {
    pw.println("Hello World");
    pw.printf("pi = %.2f\n", 3.14159);
}

// Servlet 场景
// PrintWriter writer = response.getWriter();
// writer.println("<html>...</html>");
```

### 3.3 🔄 关键行为：自动刷新（autoFlush）

构造 `PrintStream` 或 `PrintWriter` 时，可以传入第二个参数 `autoFlush` 设为 `true`：

```java
PrintWriter pw = new PrintWriter(
    new FileWriter("log.txt"), true  // autoFlush=true
);
```

当 `autoFlush` 为 `true` 时，每次调用 `println()`、`printf()` 或 `format()` 后自动执行 `flush()`，确保数据立即写入底层设备。这在实时日志场景中很重要——如果缓冲区的数据因程序崩溃而没来得及 `flush`，日志就丢了。

### 3.4 ⚠️ 错误处理：checkError()

因为 `print()` / `println()` 等方法不抛异常，你无法用 `try-catch` 知道到底有没有写成功。这时用 `checkError()` 查询状态：

```java
PrintWriter pw = new PrintWriter("maybe_fail.txt");
pw.println("some data");
if (pw.checkError()) {
    // 之前某次写操作失败了（比如磁盘已满）
    System.err.println("写入失败！");
}
```

`checkError()` 返回 `true` 的条件：内部 `IOException` 被捕获后，流会设置一个内部错误标志，`checkError()` 就是读这个标志。 **注意** ：一旦出错，这个标志不会被清除，后续的写入操作也无法恢复。

### 3.5 📊 PrintStream vs PrintWriter 对比

| 特性 | PrintStream | PrintWriter |
|------|:---:|:---:|
| 继承体系 | 继承 `OutputStream`（字节流） | 继承 `Writer`（字符流） |
| 编码处理 | 使用平台默认编码，可能跨平台不一致 | 可指定字符编码 |
| `println(String)` 内部实现 | 将字符串转为字节数组后写入 | 直接写入字符 |
| 国际化的场景 | 需要额外处理编码 | 推荐使用，编码可控 |
| 典型实例 | `System.out` | `new PrintWriter(response.getWriter())` |

<span style="color:red">**选型建议**</span> ：写文本文件或涉及字符编码的场景，优先用 `PrintWriter`，因为可以显式指定编码。控制台输出直接用 `System.out` 即可。

## 4 📦 对象序列化：ObjectOutputStream / ObjectInputStream

### 4.1 ❓ 是什么

**序列化** （Serialization）是把一个 Java 对象的状态（即它的所有字段值）转换为字节序列的过程。**反序列化** （Deserialization）则是把这个字节序列重新还原为内存中的 Java 对象。

一句话理解：序列化就是 **"把对象存到硬盘或通过网络发出去"** ，反序列化就是 **"从硬盘或网络把对象读回来"**。

这有什么用？

- **持久化** ：把对象保存到文件，程序重启后读回，恢复状态
- **网络传输** ：在 RMI（远程方法调用）、早期的 EJB 中，对象通过网络传来传去，底层就是序列化
- **深拷贝** ：把一个对象序列化再立刻反序列化，得到的是一个内容相同但引用独立的全新对象
- **Session 持久化** ：Tomcat 等容器在关闭时会序列化 Session 中的对象，启动时反序列化恢复

### 4.2 🛠️ 怎么用

**第一步：让类实现 `Serializable` 接口**。

`Serializable` 是一个 **标记接口** （没有任何方法）。它只是告诉 JVM："这个类的对象可以被序列化"。不实现这个接口就调用 `writeObject()`，JVM 直接抛 `NotSerializableException`。

```java
class Player implements java.io.Serializable {
    // serialVersionUID 强烈建议显式定义（原因见下节）
    private static final long serialVersionUID = 1L;

    private String name;
    private int score;
    private transient String password;  // transient 跳过序列化

    public Player(String name, int score, String password) {
        this.name = name;
        this.score = score;
        this.password = password;
    }

    @Override
    public String toString() {
        return "Player{name='" + name + "', score=" + score
                + ", password='" + password + "'}";
    }
}
```

**第二步：用 `ObjectOutputStream.writeObject()` 序列化**：

```java
Player player = new Player("张三", 9999, "secret123");

try (ObjectOutputStream oos = new ObjectOutputStream(
        new FileOutputStream("player.ser"))) {
    oos.writeObject(player);  // 一键保存整个对象
}
```

**第三步：用 `ObjectInputStream.readObject()` 反序列化**：

```java
try (ObjectInputStream ois = new ObjectInputStream(
        new FileInputStream("player.ser"))) {
    Player restored = (Player) ois.readObject();  // 返回值是 Object，需要强转
    System.out.println(restored);
    // Player{name='张三', score=9999, password='null'}
    // password 是 null，因为被 transient 跳过了
}
```

### 4.3 🔑 serialVersionUID：版本控制的关键

`serialVersionUID` 是序列化机制中的 **版本号**。JVM 在反序列化时，会比较字节流中的 `serialVersionUID` 和当前类的 `serialVersionUID` 是否一致：

- **一致** → 正常反序列化
- **不一致** → 抛 `InvalidClassException`

如果你不显式定义 `serialVersionUID`，JVM 会在编译时根据类的结构（类名、字段、方法签名等）自动计算一个哈希值。这意味着：

<span style="color:red">**只要类发生任何改动（新增字段、修改方法签名、甚至仅仅是重新编译），自动计算的值就可能变化，导致之前序列化的文件全部无法读取。**</span>

```java
// 显式定义：类改了字段，但只要 version 不变，旧数据仍然可读（新字段取默认值）
private static final long serialVersionUID = 1L;

// 不定义：依赖 JVM 自动计算，类一改版本号就变，旧数据全废
```

**最佳实践** ：任何实现了 `Serializable` 的类， **必须显式定义 `serialVersionUID`** 。可以用 IDE 自动生成（IntelliJ IDEA 中按 `Alt + Enter` 选择 "Add 'serialVersionUID' field"）。

### 4.4 🔒 transient：敏感字段的安全阀

`transient` 关键字用于标记 **不需要被序列化的字段**。被标记的字段在序列化时被跳过，反序列化后恢复为该类型的默认值（引用类型为 `null`，数值为 `0`，`boolean` 为 `false`）。

**典型场景**：

- **密码、密钥**：明文密码不应该被写进文件或通过网络传输
- **连接、流、线程**：`Socket`、`Connection`、`Thread` 这些对象依赖于运行时资源，序列化了也毫无意义
- **缓存/临时计算结果**：反序列化后可以重新计算，不需要保存
- **Spring 中注入的 Bean**：Spring 容器管理的依赖注入，序列化后无法恢复依赖引用

```java
class User implements Serializable {
    private static final long serialVersionUID = 1L;

    private String username;
    private transient String password;      // 密码不入库
    private transient Thread workerThread;  // 线程无法序列化
    private int loginCount;                 // 正常序列化
}
```

### 4.5 🔍 序列化机制的三个关键细节

**（1）`static` 字段不会被序列化**

序列化只保存 **对象的状态**，而 `static` 字段属于类（Class 对象），不属于某个具体实例。因此 `static` 字段的值不会写入字节流。反序列化后，`static` 字段的值是当前 JVM 中该类加载时的初始值，而非序列化时的值。

**（2）引用传递与对象图**

如果你序列化的对象内部引用了其他对象，被引用的对象也会被级联序列化——前提是这些被引用的类也实现了 `Serializable`。这形成了完整的 **对象图** 序列化。同一个对象被多次引用时，序列化机制会记录引用关系，反序列化后不会变成两个独立对象。

```java
class SaveData implements Serializable {
    private Player player;       // Player 也必须 implements Serializable
    private List<Item> items;    // List 中的 Item 也必须 implements Serializable
}
```

**（3）`readObject()` 不调用构造器**

反序列化时，JVM 直接从字节流中恢复对象的状态，**不会调用该类的构造器**。这意味着如果在构造器中做了初始化逻辑（如建立数据库连接、验证参数合法性），反序列化得到的对象会跳过这些逻辑。如果你需要在反序列化时执行额外的初始化，可以实现 `readObject()` 私有方法（不是重写，而是一个回调）：

```java
private void readObject(ObjectInputStream in)
        throws IOException, ClassNotFoundException {
    in.defaultReadObject();  // 先执行默认反序列化
    // 然后可以在此做额外初始化，比如重新建立连接
}
```

### 4.6 🚨 序列化与反序列化常见异常速查

| 异常 | 原因 | 解决方法 |
|------|------|------|
| `NotSerializableException` | 类没有实现 `Serializable` 接口 | 让类实现 `Serializable`，或用 `transient` 跳过该字段 |
| `InvalidClassException` | `serialVersionUID` 不匹配 | 显式定义 `serialVersionUID`，或确保新旧类结构兼容 |
| `EOFException` | 流已读完，或者文件被截断 | 检查文件完整性，确保读和写的对象数量一致 |
| `StreamCorruptedException` | 流数据格式损坏（可能混入了其他数据） | 确保读取顺序正确，文件没有被其他程序修改 |

## 5 🎯 总结

本篇覆盖了 Java IO 的三种进阶机制，从精确控制二进制字节的 `DataInputStream` / `DataOutputStream`，到日常输出最常用的 `PrintStream` / `PrintWriter`，再到一键保存/恢复对象的序列化机制。以下是这三种机制的核心对比：

| 维度 | Data流 | 打印流 | 对象序列化 |
|------|------|------|------|
| 目标数据 | 基本类型 + String | 任意文本 | 完整 Java 对象 |
| 数据格式 | 二进制（固定字节数） | 文本（可读） | 二进制（私有格式） |
| 读回方式 | 必须按写入顺序读取 | 不涉及（单向输出） | `readObject()` 一键恢复 |
| 异常处理 | 可能抛 `IOException` | 不抛异常，用 `checkError()` | 可能抛多种异常（见上表） |
| 跨平台 | 是（平台无关二进制格式） | 取决于编码 | 是（JVM 私有二进制格式） |
| 版本兼容 | 无版本机制，顺序变了就乱 | 不涉及 | 靠 `serialVersionUID` 控制 |
| 典型场景 | 二进制协议、游戏存档 | 日志、控制台、HTTP 响应 | 对象持久化、RMI、Session 存储 |

**选择建议**：

- 读写基本类型数据的二进制文件 → **`DataInputStream` / `DataOutputStream`**
- 写日志、打印调试信息、输出格式化文本 → **`PrintStream`（控制台）/ `PrintWriter`（文件、网络）**
- 保存或传输完整 Java 对象 → **`ObjectInputStream` / `ObjectOutputStream`**，记得实现 `Serializable`、定义 `serialVersionUID`、敏感字段用 `transient`
