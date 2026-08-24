---
title: "K8s 破坏性练习：7 天把「会做」练成「会排障」"
date: 2024-02-20T11:30:03+00:00
tags: ["容器技术", "实践教程", "Kubernetes"]
categories: ["教程"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "从照教程到会实战之间隔着排障能力。7 天破坏性练习：每天一个破坏动作（删 Pod、删 ConfigMap、改探针、塞爆资源、破坏 selector、驱逐节点、改抓取配置），实测症状 + 排查路径 + 修复，把诊断思维练成本能。"
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

# 把环境弄坏再修好：排障能力是练出来的

前十六篇文章给了完整的概念和可复现的教程，但有个问题必须诚实回答：**照着教程跑一遍，不等于会实战**。教程给的每个坑都带答案（症状+解法），实战遇到的 90% 报错是没见过的——教程教的是"会做"（照着 recipe 做菜），实战考的是"会排障"（菜坏了知道哪不对）。

排障能力怎么练？等真实故障喂太慢，而且线上事故不敢乱动。有一个免费的、安全的、反馈极快的方法——**破坏性练习：故意把环境弄坏，再自己修好**。kind 集群里怎么炸都行，成本为零，几分钟一个循环。

这篇是 7 天训练营：每天一个破坏动作，全部在本系列集群上实测过（症状真实，非杜撰），做完你就从"会做"跨进"会排障"的门。

## 1. 原理：为什么破坏性练习有效

- **反馈循环极快**：破坏 → 症状 → 假设 → 验证 → 修复，几分钟一圈（真实故障要等，事故不敢练）；
- **症状库积累**：排障快的人不是更聪明，是"见过的错误模式更多"——每个练习都在往你的模式库里存一个"症状→原因"映射；
- **安全失败**：kind 里 Pod 随便炸、节点随便驱逐，没有任何生产代价——这是练习环境存在的全部意义。

```mermaid
%% 破坏性练习的反馈循环
flowchart LR
    classDef root fill:#0f172a,stroke:#3b82f6,stroke-width:2.5px,color:#bfdbfe,font-weight:bold;
    classDef process fill:#1e1e24,stroke:#6b7280,stroke-width:2px,color:#e5e7eb;
    classDef data fill:#052e16,stroke:#16a34a,stroke-width:2px,color:#bbf7d0,font-weight:bold;

    A["① 破坏\n故意制造故障"]
    B["② 观察症状\n记录报错/状态"]
    C["③ 提出假设\n这个症状最可能是什么"]
    D["④ 验证\ndescribe / logs / 实验"]
    E["⑤ 修复\n恢复原状"]
    F["⑥ 复盘\n症状→原因 存入模式库"]

    A --> B --> C --> D --> E --> F
    F -.->|"下次见到同症状"| C

    class A,B process;
    class C,F data;
    class D,E root;
```

**排障黄金圈**（所有练习共用）：

```bash
kubectl describe <资源>   # 事件、状态、条件——先看"系统怎么说"
kubectl logs <pod>        # 应用怎么说——再看"程序怎么说"
kubectl exec <pod> -- ...  # 进现场——最后亲手验证
```

## 2. 7 天训练营

### Day 1：随机删 Pod——看控制器自愈

**破坏动作**：

```bash
POD=$(kubectl get pods -l app=demo-app -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod $POD --wait=false
```

**预期症状**（实测）：Pod 被删，几秒后自动出现新 Pod（ ` 4q8ss ` 被 ` 588nk ` 取代），Deployment 的副本数纹丝不动：

```text
demo-app-79f7ffb74b-588nk   Running   (新 Pod, 随机后缀)
demo-app-79f7ffb74b-sl6rg   Running
demo-app-79f7ffb74b-wjff8   Running
```

**学到什么**：Deployment 控制器在持续执行"期望 3 副本"的收敛——删一个补一个。这是整个 K8s 自愈机制的最小演示，也是"声明式 + 控制回路"思想（见系列《为什么是 K8s》）的活体标本。

**修复**：无需修复——这就是设计行为。练习意义在于**亲眼确认**它发生。

### Day 2：删 ConfigMap——配置丢失排障

**破坏动作**：

```bash
kubectl delete cm demo-app-config
kubectl delete pod <任一运行中的 demo-app pod>   # 触发新 Pod
```

**预期症状**（实测）：**已运行的 Pod 不受影响**（环境变量是启动时注入的），但新起的 Pod 卡在 ` CreateContainerConfigError ` ：

```text
demo-app-79f7ffb74b-j5hgq   CreateContainerConfigError
demo-app-79f7ffb74b-sl6rg   Running
demo-app-79f7ffb74b-wjff8   Running
```

` kubectl describe ` 事件会给出明确原因（ ` configmap "demo-app-config" not found ` ）。

**排查路径**：先看哪个 Pod 异常（ ` get pods ` ）→ ` describe ` 看事件 → 发现是 envFrom 引用的 ConfigMap 没了。

**修复**：重建同名 ConfigMap（内容一致即可）：

```bash
kubectl create cm demo-app-config --from-literal=APP_MESSAGE=hello --from-literal=APP_MODE=production
```

新 Pod 自动恢复 Running。

**学到什么**：**配置是外部依赖**——删了它，跑着的没事（已注入），新来的起不来。这也是为什么 ConfigMap 要在 Helm 里和 Deployment 一起版本化（见课 8）。

### Day 3：改 liveness 探针到不存在的路径——CrashLoopBackOff

**破坏动作**：把 liveness 探针的路径改成不存在的（如 ` /actuator/health/nowhere ` ）。

**预期症状**（课 4 实测）：Pod 启动成功（startup 通过）→ liveness 探测 404 → kubelet 判定不健康 → 杀进程重启 → `RESTARTS` 计数上涨，Pod 进入 CrashLoopBackOff 循环。

**排查路径**： ` kubectl get pods ` 看 RESTARTS 列 → ` kubectl describe ` 看 ` Liveness probe failed: HTTP probe failed with statuscode: 404 ` → ` kubectl logs ` 确认应用其实正常。

**修复**：把探针路径改回 ` /actuator/health/liveness ` 。

**学到什么**：**探针配置错了，健康的应用也会被反复杀死**——"探针是控制回路"的另一面：回路按你给的规则执行，规则错，杀错无辜。

### Day 4：塞爆 requests——调度失败与 Pending

**破坏动作**：给 Deployment 设置远超集群容量的 requests（如 4Gi × 4 副本，集群两个 worker 总共约 12.8Gi）：

**预期症状**（课 5 实测）：部分 Pod 一直 ` Pending ` ， ` kubectl describe ` 事件显示调度失败原因：

```text
FailedScheduling: 1 node(s) had untolerated taint(s), 2 Insufficient memory
```

**排查路径**：Pending 先看 `describe` 的 Events（调度器会把拒绝原因写进去）→ 确认是 requests 超量还是节点污点。

**修复**：调低 requests 或删掉多余副本。

**学到什么**：**requests 是调度承诺**——承诺超出容量，调度器宁可让你等着也不违约。资源账本的概念（课 5）在这里变成看得见的 Pending。

### Day 5：破坏 Service selector——流量静默全断

**破坏动作**：

```bash
kubectl patch svc demo-app-svc -p '{"spec":{"selector":{"app":"wrong-label"}}}'
```

**预期症状**（实测）：Pod 全部正常，但 **endpoints 变空**，流量静默全断（应用本身毫无报错）：

```text
NAME           ENDPOINTS   AGE
demo-app-svc   <none>      39m
```

**排查路径**：先查 Service（ ` kubectl get svc ` ）→ 发现 endpoints 空 → 对比 ` spec.selector ` 和 Pod 标签是否匹配——**selector 写错是 endpoints 空最常见的原因**。

**修复**：把 selector 改回 ` app: demo-app ` ，endpoints 立刻恢复：

```text
NAME           ENDPOINTS
demo-app-svc   10.244.1.55:8080,10.244.2.60:8080,10.244.2.61:8080
```

**学到什么**：**Service 是"标签选择器 + 端口"的静态配置，Pod 是动态的**——选择器错了不会报错，只会静默断流。这个症状（应用活着、流量没了）值得刻进模式库。

### Day 6：drain 节点——驱逐与重新调度

**破坏动作**：

```bash
kubectl drain learn-worker2 --ignore-daemonsets --delete-emptydir-data
```

**预期症状**（实测）：节点先 ` cordon ` （拒绝新调度），然后其上的 Pod 逐个被驱逐（evicted）并重新调度到其他节点，节点最终 ` SchedulingDisabled ` ：

```text
pod/nginx-demo-7b8c7bdc44-q9bdn evicted
pod/grafana-cfb7dc6bb-695l9 evicted
pod/demo-app-79f7ffb74b-2dbcx evicted
node/learn-worker2 drained
```

驱逐后所有 Pod 挤到 learn-worker 继续 Running（应用无感知——滚动重建期间如果你正打流量，会看到优雅停机三层配合在工作）。

**修复**：

```bash
kubectl uncordon learn-worker2    # 恢复调度(已驱逐的 Pod 不会自动迁回)
```

**学到什么**：**drain = 节点维护的标准姿势**（换硬件、打补丁、退役前都要先 drain）——它把"把 Pod 从节点上安全挪走"做成了原子操作，配合优雅停机（课 5）实现维护零断连。生产里云厂商节点池的"节点维护"就是自动 drain。

### Day 7：改 Prometheus 抓取配置——指标消失排障

**破坏动作**：把 Prometheus 的抓取目标端口改成不存在的（ ` demo-app-svc:8080 ` → ` :9999 ` ），然后触发配置重载：

```bash
kubectl exec deploy/prometheus -- kill -HUP 1    # Prometheus 支持 SIGHUP 重载配置
```

**预期症状**（实测）：先 ` unknown ` （重载后首次抓取未完成），一个抓取周期后变 ` down ` ，错误信息精确指出问题：

```text
k8s-demo-app | down | Get "http://demo-app-svc:9999/actuator/prometheus": context deadline exceeded
```

**排查路径**：监控没数据 → 先看 `/api/v1/targets` 的 target 健康状态（而不是先怀疑应用）→ `down` + 错误 URL → 检查抓取配置 → 发现端口被改错。

**修复**：改回 8080 → 再 ` kill -HUP 1 ` → target 恢复 ` up ` 。

**学到什么**：**排障顺序是先看采集端再看应用端**——target 状态是"采集链路健康"的第一手证据。这个练习顺带学会了 Prometheus 的 SIGHUP 热重载（改配置不用重启进程）。

## 3. 练习心法

- **先记录症状再动手修**：看到报错别急着改，先截图/抄下原文——症状就是模式库的索引；
- **一次只改一个变量**：破坏一个东西、验证一个假设，别同时动两处；
- **每轮必复盘**：练完用一句话写下"这个症状 = 这个原因"，写不出来等于没练。

## 4. 自测标准：练完怎么算过关

7 天练完，用三个问题自测：

1. **陌生报错的第一反应**：是 ` kubectl describe ` / ` logs ` 查事件，而不是搜整段报错？——是则有了诊断思维；
2. **深夜告警独立定位**：Pod 反复重启，能不能不看教程定位到"探针/资源/镜像/配置"四选一？——是则核心排障链路通了；
3. **敢不敢上真云**：在 ACK 上花几块钱把应用真实部署一遍（SLB/ARMS/节点池都是真的）？——敢则心态过关。

三个"是"，恭喜——教程给了你"会做"，这 7 天练出了"会排障"，剩下的交给真实环境继续喂。

## 5. 总结

破坏性练习是把教程转化为能力的最短路径：**每天 15 分钟，一个破坏动作，一个症状，一条模式**。Day 1-7 覆盖了 K8s 最常出问题的七个环节——控制器、配置、探针、调度、服务发现、节点、可观测性——正好把系列前八课的知识点全部"反向"练了一遍。

练完一轮可以循环加难度：把两个破坏组合（如"drain 节点 + 同时改探针"），或者换成自己的真实应用。**故障不会提前打招呼，但见过的症状都会**——这就是练习的全部意义。

（本篇无图片/视频占位。）
