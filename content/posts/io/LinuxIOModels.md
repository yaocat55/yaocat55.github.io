---
title: "Linux IO 模型"
date: 2022-09-13T15:28:58+00:00
tags: ["网络编程", "原理解析", "工程实践"]
categories: ["IO操作类"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "阻塞、非阻塞、多路复用、信号驱动、异步 IO 五大模型。通过 Mermaid 图解与 C API 示例，从操作系统原理层面掌握 IO 的本质"
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

# Linux IO 模型：阻塞、非阻塞、多路复用与异步 IO 全解析

## 1 ⚡ 问题切入：一个后端开发者必须回答的问题

假设你在面试中被问到： **"一台 4 核 8GB 的服务器，为什么能支撑 10 万个并发连接？"**

答案的关键不在于 CPU 有多快、内存有多大，而在于 **IO 模型** 。如果每个连接用一个线程、每个线程做阻塞 IO，10 万连接就需要 10 万个线程——每个线程消耗约 1MB 栈空间，仅线程栈就占 100GB 内存，4 核 CPU 也根本无法调度这么多线程。

真正让高并发成为可能的，是 **非阻塞 IO** 和 **IO 多路复用** （I/O Multiplexing，单个线程同时监听多个 IO 事件）。Nginx、Redis、Netty 的高性能都建立在正确的 IO 模型选择之上。

这篇博客从操作系统层面讲解 Linux 五大 IO 模型，聚焦于"数据如何从网卡/磁盘到达你的程序"，为后续理解 Java NIO、Netty、Kafka 等框架打下理论基础。

## 2 💻 硬件架构：一次 IO 操作经历了什么

在讨论 IO 模型之前，必须先理解一次 IO 操作涉及哪些硬件组件以及数据如何流转。

![Linux IO 硬件架构](/images/linux-io-architecture.drawio.svg)

如上图所示，一次典型的网络 IO 读取，数据经过以下路径：

| 步骤 | 操作 | 参与者 | 说明 |
|:---:|------|------|------|
| 1 | 网卡收到数据包 | NIC（网卡） | 硬件中断通知 CPU |
| 2 | DMA 拷贝到内核 | DMA 控制器 → Socket Buffer | 不经过 CPU，直接内存访问 |
| 3 | 内核协议栈处理 | TCP/IP 协议栈 | 解析 TCP 头、重组数据、校验 |
| 4 | CPU 拷贝到用户空间 | Socket Buffer → 用户 Buffer | CPU 执行 `copy_to_user()` |
| 5 | 应用程序读取 | 用户进程 | 从用户 Buffer 读取数据并处理 |

**两个核心概念** ：

- **DMA Copy** （Direct Memory Access，直接内存访问）：硬件设备直接将数据写入内存，不经过 CPU。发生时 CPU 可以做其他事情，仅在传输完成时收到一个中断
- **CPU Copy** ：CPU 执行指令将数据从内核缓冲区复制到用户缓冲区（`copy_to_user()` / `copy_from_user()`），CPU 被占用

整个 IO 过程可以分为 **两个阶段** ：

1. **等待数据** （Wait for Data）：等待网卡收到数据、DMA 传输完成、内核协议栈处理完毕
2. **拷贝数据** （Copy Data）：内核缓冲区 → 用户缓冲区（CPU Copy）

**五大 IO 模型的区别，本质上就是对这两个阶段的处理方式不同** 。

## 3 🗺️ Linux 五大 IO 模型总览

```mermaid
flowchart LR
    %% ==========================================
    %% 五大IO模型分类
    %% ==========================================
    classDef root fill:#1E88E5,stroke:#0D47A1,stroke-width:2px,color:#FFFFFF,font-weight:bold;
    classDef branch fill:#FFE082,stroke:#FFB300,stroke-width:2px,color:#5D4037,font-weight:bold;
    classDef leaf fill:#F5F5F5,stroke:#BDBDBD,stroke-width:1.5px,color:#212121;
    classDef highlight fill:#FFCCBC,stroke:#E64A19,stroke-width:1.5px,color:#D84315,font-weight:bold;

    ROOT[Linux IO 模型\n按两阶段处理方式分类]

    ROOT --> B1(同步IO)
    B1 --> M1["🔵 阻塞IO\n两个阶段都阻塞"]
    B1 --> M2["🟢 非阻塞IO\n阶段1轮询\n阶段2阻塞"]
    B1 --> M3["🟡 IO多路复用\nselect/epoll阻塞\n单线程监听多fd"]
    B1 --> M4["🟣 信号驱动IO\n阶段1信号通知\n阶段2阻塞"]

    ROOT --> B2(异步IO)
    B2 --> M5["🔴 异步IO\n两个阶段都不阻塞\n内核完成后回调"]

    class ROOT root;
    class B1,B2 branch;
    class M1,M2,M4 leaf;
    class M3,M5 highlight;
```

**同步与异步的区分标准** ： **同步 IO** 是指应用程序主动发起 IO 操作并等待（或轮询）其完成，在数据从内核缓冲区拷贝到用户缓冲区期间，应用程序线程参与其中。 **异步 IO** 是指应用程序发起 IO 操作后立即返回，内核完成所有工作（包括拷贝数据到用户空间），然后通知应用程序。

## 4 🔴 阻塞 IO（Blocking IO）

### 4.1 📖 原理

阻塞 IO 是最简单、最直观的模型。应用程序调用 `recv()`，内核在 **两个阶段都阻塞** ：

- 阶段 1（等待数据）：如果 Socket 缓冲区中没有数据，进程/线程被挂起，加入 **等待队列** （Wait Queue，内核数据结构 `wait_queue_head_t`，存储等待此事件的进程列表），直到数据到达后被唤醒
- 阶段 2（拷贝数据）：内核将数据从 Socket 缓冲区拷贝到用户缓冲区，进程/线程在这期间也是阻塞的

```mermaid
sequenceDiagram
    %% ==========================================
    %% 阻塞IO时序图
    %% ==========================================
    participant APP as 应用程序
    participant KERNEL as 内核
    participant NIC as 网卡

    APP->>KERNEL: recv(sockfd, buf, len, 0)

    Note over KERNEL: 将进程加入等待队列
    Note over APP: 🔴 进程阻塞\n等待数据

    NIC->>KERNEL: 数据到达 + DMA 传输
    Note over KERNEL: 数据写入Socket Buffer
    Note over KERNEL: 协议栈处理完成

    KERNEL-->>APP: 唤醒进程
    Note over KERNEL: 🔴 进程仍阻塞\n拷贝数据: Socket Buffer → 用户Buffer
    KERNEL->>APP: recv() 返回 (数据已就绪)

    Note over APP: ✅ 进程继续执行
```

### 4.2 💻 C API 示例

```c
#include <sys/socket.h>
#include <unistd.h>

void blocking_io_example() {
    int sockfd = socket(AF_INET, SOCK_STREAM, 0);
    // ... connect to server ...

    char buf[4096];
    // 阻塞等待：没有数据就一直等，进程被挂起
    ssize_t n = recv(sockfd, buf, sizeof(buf), 0);
    // 只有收到数据或出错时才返回

    if (n > 0) {
        write(STDOUT_FILENO, buf, n); // 处理数据
    }
    close(sockfd);
}
```

**代码解读** ：`recv()` 默认是阻塞的（`flags=0` 表示阻塞模式）。如果 Socket 缓冲区为空，当前进程/线程会被操作系统挂起，直到数据到达。期间 **CPU 可以调度其他进程运行** ，这是阻塞 IO 唯一的性能红利——进程阻塞时不占 CPU。

### 4.3 ⚠️ 特点与瓶颈

| 优点 | 缺点 |
|------|------|
| 编程模型简单，代码易读 | 一个线程只能处理一个连接 |
| 进程阻塞时不占 CPU | 高并发时需要大量线程 |
| 适合连接数少的场景 | 线程切换开销大，内存消耗大 |

<span style="color:red">**后端开发者应该记住**</span> ：传统 Tomcat/BIO 模式就是阻塞 IO——每个请求分配一个线程，请求处理完之前线程一直被占用。当并发连接达到数千时，线程数爆炸，性能急剧下降。

## 5 🟡 非阻塞 IO（Non-Blocking IO）

### 5.1 📖 原理

通过 `fcntl()` 将 Socket 设为 **非阻塞模式** （`O_NONBLOCK`），`recv()` 的行为改变：

- 阶段 1（等待数据）： **立即返回** 。如果数据未就绪，返回 `-1` 且 `errno=EAGAIN`
- 阶段 2（拷贝数据）：如果数据就绪，仍然阻塞完成 CPU Copy

应用程序需要 **主动轮询** （Polling）：反复调用 `recv()` 检查数据是否就绪。

```mermaid
sequenceDiagram
    %% ==========================================
    %% 非阻塞IO时序图
    %% ==========================================
    participant APP as 应用程序
    participant KERNEL as 内核

    loop 轮询阶段
        APP->>KERNEL: recv() (非阻塞)
        KERNEL-->>APP: 返回 -1, errno=EAGAIN
        Note over APP: 进程继续运行\n做其他事情
        Note over APP: 等待一段时间...
    end

    APP->>KERNEL: recv() (非阻塞)
    Note over KERNEL: 数据已就绪
    Note over KERNEL: 🔴 拷贝数据\nSocket Buffer → 用户Buffer
    KERNEL->>APP: recv() 返回 N (成功读取N字节)

    Note over APP: ✅ 处理数据
```

### 5.2 💻 C API 示例

```c
#include <fcntl.h>
#include <errno.h>

void nonblocking_io_example() {
    int sockfd = socket(AF_INET, SOCK_STREAM, 0);

    // 设置为非阻塞模式
    int flags = fcntl(sockfd, F_GETFL, 0);
    fcntl(sockfd, F_SETFL, flags | O_NONBLOCK);

    char buf[4096];
    while (1) {
        ssize_t n = recv(sockfd, buf, sizeof(buf), 0);

        if (n > 0) {
            // 成功读取到数据
            write(STDOUT_FILENO, buf, n);
            break;
        } else if (n == -1 && errno == EAGAIN) {
            // 数据未就绪，做一些其他事情
            // 然后继续轮询
            usleep(1000); // 等1ms再试
        } else {
            // 真正的错误
            break;
        }
    }
    close(sockfd);
}
```

**代码解读** ：设置 `O_NONBLOCK` 后，`recv()` 不再阻塞。数据未就绪时返回 `-1`，需要检查 `errno` 是否为 `EAGAIN` 或 `EWOULDBLOCK`（两者值相同）。如果是，说明只是暂时没有数据；如果是其他值，说明真的出错了。

### 5.3 ⚠️ 问题：轮询浪费 CPU

非阻塞 IO 的最大问题是 **忙轮询** （Busy Polling）：在数据未就绪期间，应用程序反复调用 `recv()`，虽然每次立即返回，但 **频繁的系统调用本身消耗 CPU** 。如果有 1000 个连接要做非阻塞检查，每轮询一遍就是 1000 次系统调用。

```c
// 用 strace 可以看到大量 EAGAIN 返回
// strace -e trace=recvfrom ./nonblocking_app 2>&1 | head -20
//
// recvfrom(3, 0x..., 4096, 0, ...) = -1 EAGAIN
// recvfrom(3, 0x..., 4096, 0, ...) = -1 EAGAIN
// recvfrom(3, 0x..., 4096, 0, ...) = -1 EAGAIN
// ... 大量无效调用 ...
```

这就引出了 IO 多路复用—— **让内核来帮忙检查哪些连接就绪，一次系统调用检查所有连接** 。

## 6 🟢 IO 多路复用（IO Multiplexing）

### 6.1 💡 核心思想

IO 多路复用的核心思想是： **用一个系统调用，让内核同时监控多个文件描述符（fd），当至少一个 fd 就绪时返回，应用程序再对有数据的 fd 做真正的 `read()` / `recv()`** 。

```mermaid
sequenceDiagram
    %% ==========================================
    %% IO多路复用 select/epoll 时序图
    %% ==========================================
    participant APP as 应用程序(单线程)
    participant KERNEL as 内核
    participant FD1 as Socket fd1
    participant FD2 as Socket fd2
    participant FD3 as Socket fd3

    APP->>KERNEL: epoll_wait(epfd, events, max, timeout)
    Note over KERNEL: 监控 fd1, fd2, fd3
    Note over APP: 🔴 线程阻塞在 epoll_wait

    FD1->>KERNEL: fd1 数据到达
    KERNEL-->>APP: epoll_wait 返回\n就绪: [fd1, fd3]

    Note over APP: 🟢 进程恢复运行
    APP->>KERNEL: recv(fd1, ...)
    Note over KERNEL: 拷贝数据(阶段2阻塞)
    KERNEL->>APP: 返回数据

    APP->>KERNEL: recv(fd3, ...)
    KERNEL->>APP: 返回数据

    Note over APP: 处理完所有就绪fd\n重新调用 epoll_wait
```

### 6.2 📈 select / poll / epoll 演进

Linux 提供了三种 IO 多路复用接口，按出现顺序分别是 select、poll、epoll：

```mermaid
flowchart TD
    %% ==========================================
    %% select/poll/epoll 演进
    %% ==========================================
    classDef startEnd fill:#F48FB1,stroke:#C2185B,stroke-width:2px,color:#212121,font-weight:bold;
    classDef process fill:#F5F5F5,stroke:#9E9E9E,stroke-width:1.5px,color:#212121;
    classDef highlight fill:#FFCCBC,stroke:#E64A19,stroke-width:1.5px,color:#D84315,font-weight:bold;
    classDef reject fill:#FFCDD2,stroke:#C62828,stroke-width:1.5px,color:#B71C1C,font-weight:bold;

    START([IO多路复用演进]) --> SELECT

    subgraph S1 ["select (1983, 4.2BSD)"]
        SELECT["🔴 select()\n• fd_set 位图，最多1024个fd\n• O(N)遍历：每次调用重传整个集合\n• 修改传入的fd_set"]
    end

    SELECT --> POLL

    subgraph S2 ["poll (1997, SVR3)"]
        POLL["🟡 poll()\n• pollfd 结构体数组，无数量上限\n• O(N)遍历：每次仍要重传\n• 分离 events 和 revents"]
    end

    POLL --> EPOLL

    subgraph S3 ["epoll (2002, Linux 2.6)"]
        EPOLL["🟢 epoll()\n• 红黑树+就绪链表，无上限\n• O(1)获取就绪事件\n• 事件驱动，fd只需注册一次"]
    end

    class START startEnd;
    class SELECT reject;
    class POLL process;
    class EPOLL highlight;
```

### 6.3 📊 三者的核心区别

| 特性 | select | poll | epoll |
|------|--------|------|-------|
| **数据结构** | `fd_set` 位图（默认 1024 bits） | `struct pollfd[]` 数组 | 内核红黑树 + 就绪链表 |
| **fd 上限** | `FD_SETSIZE`（1024，可重编译） | 无上限（受系统限制） | 无上限（受系统限制） |
| **fd 注册** | 每次调用都传入全部 fd | 每次调用都传入全部 fd | 一次注册（`epoll_ctl`），持久有效 |
| **就绪查找** | O(N) 遍历所有 fd | O(N) 遍历所有 fd | O(1) 直接从就绪链表取 |
| **内核态数据结构** | 每次重新构建 | 每次重新构建 | 红黑树持久，事件驱动回调 |
| **触发方式** | 水平触发 | 水平触发 | 水平触发 + 边缘触发 |

### 6.4 💻 epoll API 示例

```c
#include <sys/epoll.h>

void epoll_example() {
    // 1. 创建 epoll 实例
    int epfd = epoll_create1(0);   // 返回 epoll 文件描述符

    // 2. 注册要监控的 fd
    struct epoll_event ev, events[64];
    ev.events = EPOLLIN;           // 监控可读事件（数据到达）
    ev.data.fd = sockfd;           // 关联的 fd
    epoll_ctl(epfd, EPOLL_CTL_ADD, sockfd, &ev);

    // 3. 事件循环
    while (1) {
        // 阻塞等待事件，timeout=-1 表示无限等待
        int nfds = epoll_wait(epfd, events, 64, -1);

        // 只处理就绪的 fd —— O(1) 级别
        for (int i = 0; i < nfds; i++) {
            if (events[i].events & EPOLLIN) {
                int fd = events[i].data.fd;
                char buf[4096];
                ssize_t n = recv(fd, buf, sizeof(buf), 0);
                if (n > 0) {
                    // 处理数据
                }
            }
        }
    }
    close(epfd);
}
```

**代码解读** ：

1. `epoll_create1(0)` 在内核中创建一个 `eventpoll` 对象，包含一棵 **红黑树** （`rbr`，存储注册的 fd）和一个 **就绪链表** （`rdllist`，存储就绪的事件）
2. `epoll_ctl(epfd, EPOLL_CTL_ADD, sockfd, &ev)` 将 fd 注册到红黑树中，同时向内核协议栈注册一个 **回调函数** （`ep_poll_callback`）——当数据到达时，内核自动将事件加入就绪链表
3. `epoll_wait()` 检查就绪链表，如果有事件直接返回。每次只传递发生事件的那几个 fd（`events` 数组），而不是全部 fd

**epoll 高性能的本质** ： **回调 + 就绪链表** 。fd 注册一次后永久有效，数据到达时由内核回调自动将事件加入就绪链表。`epoll_wait()` 不需要遍历所有监视的 fd，只需要检查就绪链表，真正的 O(1) 获取。

### 6.5 ⚡ 水平触发 vs 边缘触发

```mermaid
stateDiagram-v2
    %% ==========================================
    %% LT vs ET 触发模式
    %% ==========================================
    DATA_READY: 📥 数据到达\nSocket缓冲区有数据

    state "📤 LT(水平触发)\nepoll_wait 持续通知\n直到数据被读完" as LT
    state "📤 ET(边缘触发)\nepoll_wait 仅通知一次\n必须循环读直到EAGAIN" as ET

    DATA_READY --> LT
    DATA_READY --> ET

    LT --> READ1_LT: 应用 read() 部分数据
    READ1_LT --> LT: epoll_wait 再次通知\n(缓冲区还有数据)

    ET --> READ1_ET: 应用 read() 部分数据
    READ1_ET --> LOST: epoll_wait 不再通知\n(若没读完则丢失)
```

| 模式 | 行为 | 要求 | 适用场景 |
|------|------|------|------|
| **水平触发（LT，默认）** | 只要缓冲区有数据，`epoll_wait()` 就反复通知 | 可以一次只读部分数据 | 简单，不易出错 |
| **边缘触发（ET）** | 只在状态变化时（无数据→有数据）通知一次 | 必须循环读，直到 `EAGAIN`，fd 必须设为非阻塞 | 高性能，配合非阻塞 IO |

ET 模式必须用非阻塞 IO + 循环读取，代码更复杂但性能更高——减少了 `epoll_wait` 的调用次数。

## 7 🟣 信号驱动 IO（Signal-Driven IO）

### 7.1 📖 原理

通过 `sigaction()` + `fcntl(F_SETOWN)` + `fcntl(F_SETFL, O_ASYNC)` 设置。当 Socket 数据就绪时，内核发送 `SIGIO` 信号给进程。进程在 **信号处理函数** 中调用 `recv()` 读取数据。

- 阶段 1（等待数据）：进程继续运行，不阻塞。数据就绪时内核发信号
- 阶段 2（拷贝数据）：在信号处理函数中执行 `recv()` 时仍然阻塞

```mermaid
sequenceDiagram
    %% ==========================================
    %% 信号驱动IO时序图
    %% ==========================================
    participant APP as 应用程序
    participant SIG as 信号处理函数
    participant KERNEL as 内核
    participant NIC as 网卡

    APP->>KERNEL: sigaction(SIGIO, handler)
    APP->>KERNEL: fcntl(fd, F_SETFL, O_ASYNC)
    Note over APP: 🟢 进程继续运行\n不阻塞

    NIC->>KERNEL: 数据到达
    KERNEL-->>APP: SIGIO 信号
    Note over APP: 中断当前执行流

    APP->>SIG: 进入信号处理函数
    SIG->>KERNEL: recv(fd, buf, len, 0)
    Note over KERNEL: 🔴 拷贝数据期间阻塞
    KERNEL->>SIG: 返回数据
    SIG-->>APP: 信号处理完成

    Note over APP: ✅ 继续之前的工作
```

### 7.2 💻 C API 示例

```c
#include <signal.h>
#include <fcntl.h>

void sigio_handler(int signo) {
    char buf[4096];
    // 在信号处理函数中执行 recv (复杂且容易出错)
    ssize_t n = recv(global_sockfd, buf, sizeof(buf), 0);
    // ...
}

void signal_driven_io_example() {
    int sockfd = socket(AF_INET, SOCK_STREAM, 0);

    // 注册信号处理函数
    struct sigaction sa = { .sa_handler = sigio_handler };
    sigaction(SIGIO, &sa, NULL);

    // 设置 fd 的所有者（谁接收信号）
    fcntl(sockfd, F_SETOWN, getpid());

    // 启用异步通知
    int flags = fcntl(sockfd, F_GETFL, 0);
    fcntl(sockfd, F_SETFL, flags | O_ASYNC);

    // 进程继续做其他事情，数据到达时自动触发 sigio_handler
    while (1) {
        // 做其他工作...
    }
}
```

### 7.3 ⚠️ 为什么信号驱动 IO 很少用

1. **信号处理函数限制多** ：在信号处理函数中只能调用"异步信号安全"的函数（`recv()` 不是，使用它是一种灰色地带）
2. **信号不可靠** ：多个数据到达时信号可能合并，导致只触发一次
3. **无法知道是哪个 fd 就绪** ：需要遍历所有 fd 检查
4. **调试困难** ：信号的异步特性增加了程序的复杂性

JDK 的 NIO 框架没有采用信号驱动模型，而是使用了 IO 多路复用（`epoll` / `kqueue`）。

## 8 🔵 异步 IO（Asynchronous IO）

### 8.1 📖 原理

Linux 通过 `io_submit()` + `aio_read()` 实现真正的异步 IO。应用程序发起 IO 请求后 **立即返回** ，内核完成 **两个阶段** （等待数据 + 拷贝数据）后，通过 **回调** 或 **信号** 通知应用程序。

- 阶段 1 和阶段 2：内核全部完成， **应用程序完全不被阻塞**

```mermaid
sequenceDiagram
    %% ==========================================
    %% 异步IO时序图
    %% ==========================================
    participant APP as 应用程序
    participant KERNEL as 内核
    participant NIC as 网卡

    APP->>KERNEL: aio_read(&iocb)
    Note over APP: 🟢 立即返回\n进程继续运行

    Note over KERNEL: 内核接管一切
    NIC->>KERNEL: 数据到达

    Note over KERNEL: 阶段1: 等待数据\n(由内核完成)
    Note over KERNEL: 阶段2: 拷贝到用户空间\n(由内核完成)

    KERNEL-->>APP: 回调/信号通知\n数据已在用户缓冲区中

    Note over APP: ✅ 直接使用数据\n无需调用 recv()
```

### 8.2 💻 C API 示例

```c
#include <linux/aio_abi.h>
#include <sys/syscall.h>

void aio_example() {
    aio_context_t ctx = 0;
    // 1. 创建异步IO上下文
    syscall(SYS_io_setup, 128, &ctx);

    // 2. 准备读取缓冲区
    char buf[4096];
    struct iocb cb = {0};
    cb.aio_fildes = fd;          // 文件描述符
    cb.aio_lio_opcode = IOCB_CMD_PREAD;
    cb.aio_buf = (uint64_t)buf;  // 用户缓冲区地址
    cb.aio_nbytes = sizeof(buf);
    cb.aio_offset = 0;

    struct iocb *cbs[] = {&cb};
    // 3. 提交异步读请求 —— 立即返回！
    syscall(SYS_io_submit, ctx, 1, cbs);

    // 4. 进程继续做其他事情...
    // 做业务逻辑、处理其他请求等

    // 5. 查询是否完成（或设置回调/信号通知）
    struct io_event ev;
    syscall(SYS_io_getevents, ctx, 1, 1, &ev, NULL);
    // ev.res 包含实际读取的字节数
    // ev.obj->aio_buf 就是之前传入的 buf，数据已在其中
}
```

### 8.3 🔮 异步 IO 的现状

Linux 原生异步 IO（AIO） **只对 `O_DIRECT` 方式打开的文件有效** ，即绕过 Page Cache 的直接 IO。对于普通文件（使用 Page Cache 缓冲），AIO 实际上仍然是阻塞的。这使得 Linux 原生 AIO 的适用范围很窄（主要用在数据库直接读写裸设备）。

`io_uring`（Linux 5.1+, 2019）是新一代异步 IO 接口，通过 **共享内存环形队列** （Submission Queue + Completion Queue）实现真正的零拷贝异步 IO，比 AIO 更高效、更通用，是 Linux 异步 IO 的未来方向。

## 9 🎯 五大模型对比总结

```mermaid
flowchart TD
    %% ==========================================
    %% 五大模型阶段对比
    %% ==========================================
    classDef startEnd fill:#F48FB1,stroke:#C2185B,stroke-width:2px,color:#212121,font-weight:bold;
    classDef process fill:#F5F5F5,stroke:#9E9E9E,stroke-width:1.5px,color:#212121;
    classDef highlight fill:#FFCCBC,stroke:#E64A19,stroke-width:1.5px,color:#D84315,font-weight:bold;
    classDef block fill:#FFCDD2,stroke:#C62828,stroke-width:1.5px,color:#B71C1C,font-weight:bold;
    classDef nblock fill:#C8E6C9,stroke:#388E3C,stroke-width:1.5px,color:#1B5E20,font-weight:bold;

    %% ==========================================
    %% 决策树
    %% ==========================================
    START([发起IO操作]) --> Q1{阶段1\n等待数据?}

    Q1 -- 自己等 --> Q1A{怎么等?}
    Q1A -->|"死等"| B_IO["🔴 阻塞IO\n两阶段均阻塞\n最简单"]
    Q1A -->|"轮询"| NB_IO["🟡 非阻塞IO\n阶段1轮询\n阶段2阻塞"]
    Q1A -->|"内核帮我看多个fd"| MP_IO["🟢 IO多路复用\nepoll_wait等待\n阶段2逐fd读取"]

    Q1 -- 不用我等 --> Q1B{阶段2\n拷贝数据?}
    Q1B -->|"信号通知后自己拷"| SIG_IO["🟣 信号驱动IO\n阶段1非阻塞\n阶段2阻塞"]
    Q1B -->|"内核全包"| AIO["🟠 异步IO\n两阶段均非阻塞\nio_uring"]

    class START startEnd;
    class Q1,Q1A,Q1B process;
    class B_IO block;
    class NB_IO,SIG_IO process;
    class MP_IO,AIO highlight;
```

| 模型 | 阶段1(等数据) | 阶段2(拷贝) | 关键系统调用 | 复杂度 | 并发能力 | 代表框架 |
|------|:---:|:---:|------|:---:|:---:|------|
| **阻塞IO** | 阻塞 | 阻塞 | `read/recv` | 低 | 低 | 传统Tomcat BIO |
| **非阻塞IO** | 轮询 | 阻塞 | `recv+fcntl` | 中 | 低 | 无（一般不单独用） |
| **多路复用** | select/epoll阻塞 | 逐fd阻塞 | `epoll_wait+recv` | 高 | 高 | Nginx、Redis、Netty |
| **信号驱动** | 非阻塞(信号) | 阻塞 | `sigaction+fcntl` | 极高 | 中 | 几乎不用 |
| **异步IO** | 非阻塞 | 非阻塞 | `aio_read/io_uring` | 极高 | 极高 | io_uring (下一代) |

### 9.1 📌 后端开发者应该记住的结论

1. **阻塞 IO** 只有一个线程一个连接的场景适合，高并发下不可行
2. **非阻塞 IO** 单独使用轮询成本高，需要配合多路复用
3. **IO 多路复用** 是现代高并发服务器的核心——一个线程可以管理数万个连接。epoll 的 O(1) 就绪查找是 Redis 单线程高性能的关键
4. **信号驱动 IO** 实际应用很少，主要在嵌入式或特殊场景
5. **异步 IO** （io_uring）是下一代方向，但目前主流框架仍基于 epoll 多路复用构建

### 9.2 ☕ 在 Java 中的对应

| Linux 模型 | Java 对应 |
|------|------|
| 阻塞 IO | `java.io`（传统 BIO），`InputStream.read()` 阻塞当前线程 |
| IO 多路复用（epoll） | `java.nio.channels.Selector`（NIO），底层在 Linux 上调用 `epoll_wait` |
| 异步 IO | `java.nio.channels.AsynchronousSocketChannel`（AIO, Java 7+），但在 Linux 上层是 epoll + 线程池模拟 |

Java NIO 的 `Selector` 封装了 `epoll`（Linux）/ `kqueue`（macOS）/ `IOCP`（Windows），为 Java 开发者提供了统一的 IO 多路复用 API。而 Netty 框架进一步封装了 NIO，提供了事件驱动的编程模型，是目前 Java 高性能网络编程的事实标准。
