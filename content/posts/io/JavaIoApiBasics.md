---
title: "Java IO API 基础入门"
date: 2022-09-07T14:21:50+00:00
tags: ["网络编程", "入门指南", "Java并发"]
categories: ["IO操作类"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "Java IO API 基础入门，涵盖 File 类、字节流（FileInputStream/FileOutputStream）与字符流（FileReader/FileWriter）的核心用法与常见陷阱"
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

# Java IO API 基础入门：File 类、字节流与字符流使用指南

## 1 📁 File 类（文件路径操作）

`java.io.File` 是 Java IO 包中最基础的类，它表示文件系统中的一个 **路径** （文件或目录），提供创建、删除、判断、遍历等操作。核心概念：`File` 对象只是一个 **路径的抽象表示** ，创建 `File` 对象时不会检查文件或目录在磁盘上是否真实存在。

### 1.1 🏗️ 构造器与路径表示

| 构造器 | 说明 |
|--------|------|
| `new File("path")` | 接收一个路径字符串，支持相对路径和绝对路径 |
| `new File("parent", "child")` | 接收父路径和子路径，自动拼接分隔符 |

```java
File f1 = new File("D:/data/test.txt");          // 绝对路径
File f2 = new File("./data/test.txt");           // 相对路径（相对于项目根目录）
File f3 = new File("D:/data", "test.txt");       // 父路径 + 子路径
```

<span style="color:red">**关键陷阱**</span> ：`new File("path")` 只是在内存中构造了一个路径对象，**不会检查文件是否真实存在** ，也不会创建文件。这意味着即使路径指向一个不存在的文件，构造器也不会抛异常。

### 1.2 🔍 文件/目录判断

判断一个路径在磁盘上是否存在、是文件还是目录：

| 方法 | 返回值 | 说明 |
|------|--------|------|
| `exists()` | `boolean` | 路径对应的文件或目录是否存在 |
| `isFile()` | `boolean` | 是否存在且是文件（不是目录） |
| `isDirectory()` | `boolean` | 是否存在且是目录（不是文件） |

```java
File file = new File("D:/data/test.txt");

if (file.exists()) {
    System.out.println(file.isFile() ? "是文件" : "是目录");
} else {
    System.out.println("路径不存在");
}
```

注意事项：
- `isFile()` 和 `isDirectory()` 的返回值互相排斥，一个路径不可能同时为 `true`
- 如果路径不存在，两者都返回 `false`
- 调用 `isFile()` / `isDirectory()` 之前，通常需要先调用 `exists()` 确认路径存在

### 1.3 📂 文件操作：创建、删除、创建多级目录

| 方法 | 返回值 | 说明 |
|------|--------|------|
| `createNewFile()` | `boolean` | 创建新文件。已存在则返回 `false`，IO 异常则抛 `IOException` |
| `delete()` | `boolean` | 删除文件或空目录。非空目录无法删除，返回 `false` |
| `mkdir()` | `boolean` | 创建单级目录。父目录不存在时创建失败，返回 `false` |
| `mkdirs()` | `boolean` | 创建多级目录，不存在的父目录也会一并创建 |

```java
// 创建多级目录 + 创建文件
File dir = new File("D:/data/sub/logs");
if (!dir.exists()) {
    boolean ok = dir.mkdirs();      // 创建 D:/data/sub/logs/ 三级目录
    System.out.println(ok ? "目录创建成功" : "目录创建失败");
}

File file = new File(dir, "app.log");
if (!file.exists()) {
    file.createNewFile();           // 在目录下创建新文件
}
```

<span style="color:red">**重要区分**</span> ：
- `mkdir()` 只能创建一层目录，父目录必须存在，否则失败
- `mkdirs()` 会递归创建所有不存在的父目录，**日常开发中优先用 `mkdirs()`**
- `delete()` 只能删除空目录，删除非空目录会返回 `false`（需要用递归或 `Files.walk()` 替代）

### 1.4 📋 列表遍历

列出目录下的所有文件和子目录：

| 方法 | 返回值 | 说明 |
|------|--------|------|
| `list()` | `String[]` | 返回目录下所有文件和子目录的 **名称** （只有文件名，不含路径） |
| `listFiles()` | `File[]` | 返回目录下所有文件和子目录的 **File 对象** （含完整路径） |

```java
File dir = new File("D:/data");

// 方式一：只获取文件名
String[] names = dir.list();
for (String name : names) {
    System.out.println(name);
}

// 方式二：获取 File 对象
File[] files = dir.listFiles();
for (File f : files) {
    System.out.println(f.getAbsolutePath() + " " + (f.isFile() ? "[文件]" : "[目录]"));
}
```

**配合 FilenameFilter 过滤** ：

```java
// 只列出 .txt 文件
File[] txtFiles = dir.listFiles(new FilenameFilter() {
    @Override
    public boolean accept(File dir, String name) {
        return name.endsWith(".txt");
    }
});

// Java 8 Lambda 简化写法
File[] txtFiles = dir.listFiles((d, name) -> name.endsWith(".txt"));
```

<span style="color:red">**注意**</span> ：`list()` 和 `listFiles()` 如果调用的对象不是目录或目录不存在，都返回 `null`（不会抛异常），遍历前应判空。

### 1.5 🛠️ 常用工具方法

| 方法 | 返回值 | 说明 |
|------|--------|------|
| `getName()` | `String` | 文件名（不含路径） |
| `getAbsolutePath()` | `String` | 绝对路径字符串 |
| `getParent()` | `String` | 父目录路径 |
| `length()` | `long` | 文件大小（字节数） |
| `lastModified()` | `long` | 最后修改时间的毫秒值 |
| `renameTo(File dest)` | `boolean` | 重命名/移动文件 |

<span style="color:red">**length() 陷阱**</span> ：返回类型是 `long`，最大值 $2^{63} - 1$ 约 8 EB（艾字节），理论上够用。但需要注意：
- 目录的 `length()` 返回值 **未定义** （不同 OS 实现不同），不要依赖
- 如果文件不存在，返回 `0`（不抛异常），需要用 `exists()` 先判断

```java
File file = new File("D:/data/test.txt");
if (file.exists() && file.isFile()) {
    long bytes = file.length();
    System.out.println("文件大小: " + bytes + " 字节");
}
```

## 2 💾 字节流基础（处理图片/音频/任意文件）

字节流以 **byte** 为单位读写数据，可以处理任意类型的文件（图片、音频、视频、文本等）。它不关心数据的编码或格式，只是原样传输字节。

### 2.1 🏗️ 核心类与构造器

| 类 | 用途 | 构造器示例 |
|----|------|-----------|
| `FileInputStream` | 从文件读取字节 | `new FileInputStream("a.jpg")` |
| `FileOutputStream` | 向文件写入字节 | `new FileOutputStream("copy.jpg")` |

两个类的构造器都会尝试打开文件：
- `FileInputStream`：文件不存在时抛 `FileNotFoundException`
- `FileOutputStream`：文件不存在时 **自动创建** （前提是父目录存在）。第二个参数 `boolean append` 控制追加模式（`true` = 追加，`false` = 覆盖）

```java
// 读取
FileInputStream fis = new FileInputStream("D:/data/a.jpg");

// 写入（覆盖模式）
FileOutputStream fos = new FileOutputStream("D:/data/copy.jpg");

// 写入（追加模式）
FileOutputStream fosAppend = new FileOutputStream("D:/data/copy.jpg", true);
```

### 2.2 📋 核心方法

| 方法 | 说明 |
|------|------|
| `read()` | 每次读取一个字节，返回 `0 ~ 255` 的 int 值。读到流末尾返回 `-1` |
| `read(byte[] b)` | 每次读取多个字节到缓冲区，返回实际读取的字节数。返回 `-1` 表示流末尾 |
| `write(int b)` | 写入一个字节（只写低 8 位） |
| `write(byte[] b)` | 写入缓冲区中全部字节 |
| `write(byte[] b, int off, int len)` | 写入缓冲区中从 `off` 开始的 `len` 个字节 |
| `close()` | 关闭流，释放系统资源 |

**日常使用模式** ：

```java
// 逐字节读取（效率低，仅演示）
try (FileInputStream fis = new FileInputStream("D:/data/a.jpg")) {
    int b;
    while ((b = fis.read()) != -1) {
        // 处理每个字节 b
    }
}
```

**注意** ：`read()` 返回 `int` 而不是 `byte`，是因为需要用 `-1` 表示流末尾。如果返回 `byte`，`0xFF`（即 `-1`）这个合法字节值就会和"流结束"信号冲突。因此返回值范围是 `0 ~ 255`（有效字节），`-1` 表示读完。

### 2.3 🖼️ 读取图片文件的前 10 个字节

```java
try (FileInputStream fis = new FileInputStream("D:/data/a.jpg")) {
    byte[] buffer = new byte[10];
    int bytesRead = fis.read(buffer);
    System.out.println("实际读取了 " + bytesRead + " 个字节");
    for (int i = 0; i < bytesRead; i++) {
        System.out.printf("%02X ", buffer[i] & 0xFF);  // 以十六进制打印
    }
}
```

### 2.4 📦 实现简单文件复制

```java
public static void copyFile(String src, String dest) throws IOException {
    try (FileInputStream fis = new FileInputStream(src);
         FileOutputStream fos = new FileOutputStream(dest)) {

        byte[] buffer = new byte[4096];   // 4KB 缓冲区
        int bytesRead;

        while ((bytesRead = fis.read(buffer)) != -1) {
            fos.write(buffer, 0, bytesRead);
        }
    }
}

// 调用
copyFile("D:/data/a.jpg", "D:/data/copy.jpg");
```

**关键点** ：
- 使用 **4KB 缓冲区** （4096 字节），一次读写多个字节，性能远优于逐字节读写
- 使用 **try-with-resources** （`try (...)`）自动关闭流，无需手动 `close()`
- `fis.read(buffer)` 返回实际读取的字节数，`fos.write(buffer, 0, bytesRead)` 只写入实际读取的部分，避免写入上一次残留的脏数据

## 3 📝 字符流基础（处理文本文件）

字符流以 **char** 为单位读写数据，专用于处理文本文件。底层仍然使用字节流，但会自动完成 **字节 ↔ 字符** 的编码解码转换。

### 3.1 🏗️ 核心类与构造器

| 类 | 用途 | 构造器示例 |
|----|------|-----------|
| `FileReader` | 从文件读取字符 | `new FileReader("a.txt")` |
| `FileWriter` | 向文件写入字符 | `new FileWriter("out.txt")` |

```java
// 读取文本文件
FileReader reader = new FileReader("D:/data/a.txt");

// 写入文本文件
FileWriter writer = new FileWriter("D:/data/out.txt");

// 追加模式写入
FileWriter appender = new FileWriter("D:/data/out.txt", true);
```

### 3.2 📋 核心方法

| 方法 | 说明 |
|------|------|
| `read()` | 每次读取一个字符，返回 `0 ~ 65535` 的 int 值。读到流末尾返回 `-1` |
| `read(char[] cbuf)` | 每次读取多个字符到缓冲区，返回实际读取的字符数 |
| `write(int c)` | 写入一个字符 |
| `write(char[] cbuf)` | 写入字符数组全部内容 |
| `write(String str)` | 写入字符串 |
| `write(String str, int off, int len)` | 写入字符串的一部分 |
| `close()` | 关闭流 |

### 3.3 📖 读取文本文件并打印

```java
try (FileReader reader = new FileReader("D:/data/a.txt")) {
    char[] buffer = new char[1024];
    int charsRead;

    while ((charsRead = reader.read(buffer)) != -1) {
        System.out.print(new String(buffer, 0, charsRead));
    }
}
```

### 3.4 ✍️ 写入文本内容

```java
try (FileWriter writer = new FileWriter("D:/data/out.txt")) {
    writer.write("Hello, Java IO!\n");
    writer.write("第二行内容\n");
    writer.write("第三行内容");
}
```

### 3.5 ⚠️ 默认编码陷阱

这是使用 `FileReader` / `FileWriter` 时 **最容易踩的坑** 。

`FileReader` 和 `FileWriter` 使用的是 **JVM 默认编码** （通常是操作系统默认编码），而不是 UTF-8。在 Windows 中文环境下默认编码通常是 **GBK** ，而在 Linux 服务器上通常是 **UTF-8** 。

**后果** ：同样的代码在不同操作系统上运行时，中文可能乱码。

**示例** ：

```java
// --- 在 Windows 中文系统上（默认 GBK）---
try (FileWriter writer = new FileWriter("test.txt")) {
    writer.write("你好");   // 以 GBK 编码写入
}

// --- 在 Linux 服务器上（默认 UTF-8）---
try (FileReader reader = new FileReader("test.txt")) {
    // 以 UTF-8 解码读取——但文件是 GBK 编码的！中文乱码！
}
```

**解决方案** ：指定字符编码，使用 `InputStreamReader` 和 `OutputStreamWriter` 替代：

```java
// 写入时指定 UTF-8 编码
try (OutputStreamWriter writer = new OutputStreamWriter(
         new FileOutputStream("D:/data/out.txt"), StandardCharsets.UTF_8)) {
    writer.write("你好，世界！");
}

// 读取时指定 UTF-8 编码
try (BufferedReader reader = new BufferedReader(
         new InputStreamReader(
         new FileInputStream("D:/data/out.txt"), StandardCharsets.UTF_8))) {
    String line;
    while ((line = reader.readLine()) != null) {
        System.out.println(line);
    }
}
```

<span style="color:red">**记住这个规则**</span> ：只要是涉及中文或其他非 ASCII 字符的文本文件，**不要直接使用** `FileReader` / `FileWriter`，用 `InputStreamReader` / `OutputStreamWriter` 并显式指定编码。

## 4 🎯 总结

### 4.1 📊 三类 API 适用场景对比

| 场景 | 使用 API | 原因 |
|------|----------|------|
| 判断文件/目录是否存在、创建目录、遍历文件列表 | `File` | 路径操作，不涉及内容读写 |
| 复制图片、音频、视频、任意二进制文件 | `FileInputStream` + `FileOutputStream` | 字节级读写，不关心编码 |
| 读写纯文本文件（.txt、.json、.csv 等） | `InputStreamReader` + `OutputStreamWriter` + 指定编码 | 字符级读写，需要关注编码 |
| 简单测试/学习用的文本读写（无中文） | `FileReader` + `FileWriter` | 极简 API，但默认编码不安全 |

### 4.2 🚨 常见陷阱速查

| 陷阱 | 说明 | 规避方式 |
|------|------|----------|
| `new File("path")` 不检查存在 | 构造器只创建内存对象 | 用 `exists()` 判断 |
| `listFiles()` 返回 `null` | 路径不是目录时返回 `null` | 遍历前判空 |
| `length()` 对目录无效 | 目录大小未定义 | 只对 `isFile()` 为 `true` 的对象调用 |
| `read()` 返回 `int` 而非 `byte` | 用 `-1` 区分流末尾 | `while((b=fis.read())!=-1)` |
| `FileReader` / `FileWriter` 用默认编码 | 跨平台中文乱码 | 用 `InputStreamReader` / `OutputStreamWriter` 指定 UTF-8 |

### 4.3 ♻️ try-with-resources 关闭流

从 Java 7 开始，所有 IO 流类都实现了 `AutoCloseable` 接口，可以直接用 try-with-resources 语法自动关闭：

```java
// 传统写法（不推荐）
FileInputStream fis = null;
try {
    fis = new FileInputStream("a.txt");
    // ...
} catch (IOException e) {
    e.printStackTrace();
} finally {
    if (fis != null) {
        try {
            fis.close();
        } catch (IOException e) {
            e.printStackTrace();
        }
    }
}

// try-with-resources 写法（推荐）
try (FileInputStream fis = new FileInputStream("a.txt")) {
    // 使用 fis...
}  // fis.close() 自动调用，无需 finally 块
```

try-with-resources 保证 `close()` 一定会被调用（即使发生异常），且代码更简洁。
