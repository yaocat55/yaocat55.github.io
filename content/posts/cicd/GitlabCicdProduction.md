---
title: "GitLab CI/CD 多环境部署与生产实践"
date: 2022-12-26T08:00:00+00:00
tags: ["CI/CD", "实践教程", "容器技术"]
categories: ["CICD类"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "多环境 CI/CD 完整落地：dev（自动部署）→ staging（自动部署 + 自动化测试）→ prod（人工审批 + 手动触发）、GitLab Environments 管理部署历史与一键回滚、K8s Deployment 滚动更新集成、环境变量分层管理（CI Variables + ConfigMap + Secret）、Helm 简化部署模板、审批卡点（Manual Action）、部署后自动健康检查——以及版本回滚的三种方式、发布规范与 Checklist。"
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

# 从 dev 一路跑到 prod——点个按钮就上线

> 📖 <strong>前置阅读</strong>：本文假设读者已搭建 GitLab CI/CD 流水线（编译 → 测试 → 扫描 → 构建镜像 → 推送 Harbor），并已将微服务部署在 Kubernetes 上。如果还不熟悉，建议先阅读 [<strong>搭建与 Pipeline 语法精讲</strong>]({{< relref "GitlabCicdFundamentals.md" >}}) 和 [<strong>流水线实战</strong>]({{< relref "GitlabCicdPipeline.md" >}})。

## 一、⚡ 镜像推到 Harbor 了——但你还得手动 SSH 上去 kubectl apply——这叫啥 CI/CD？

前两篇搭好了 CI/CD Pipeline——代码 push → 编译 → 测试 → 扫描 → 构建镜像 → 推送到 Harbor。

但 Pipeline 到这里就停了——后面的部署还是人来操作：

```
当前状态（半自动）：
  ✅ 代码 push → 自动编译、测试、扫描、构建镜像、推送 Harbor
  ❌ 然后——SSH 到跳板机 → kubectl set image → 看有没有报错
  ❌ 然后——curl 验证——发现不对——kubectl rollout undo
  ❌ 然后——staging 和 prod 没有隔离——改了什么全凭记忆力
  
  → CI 有了——CD 没做——半吊子自动化
```

<strong>真正的 CD——镜像推送到 Harbor 后——自动部署到 dev——验证通过——自动部署到 staging——人工审批——部署到 prod。人对生产的操作只剩下"点一个按钮"。</strong>

## 二、🗺️ 多环境部署架构——dev / staging / prod

### 2.1 三个环境的流转

```mermaid
flowchart LR
    MR["Merge Request\n→ feature → main"] --> Dev["① dev 环境\n自动部署\n每次 push 到 main"]
    Dev --> Staging["② staging 环境\n自动部署\n跑自动化回归测试"]
    Staging --> Manual["③ 人工审批\n点按钮确认"]
    Manual --> Prod["④ prod 环境\n部署\n滚动更新"]
    Prod --> Health["⑤ 健康检查\n自动 curl 验证\n失败自动回滚"]
    

classDef style_Manual fill:#450a0a,stroke:#dc2626,stroke-width:2px,color:#fecaca;
classDef style_Prod fill:#450a0a,stroke:#dc2626,stroke-width:2px,color:#fecaca;
class Manual style_Manual;
class Prod style_Prod;```

| 环境 | 触发方式 | 部署策略 | 谁在验证 | 数据库 |
|------|------|------|------|------|
| <strong>dev</strong> | 每次 push main 自动触发 | 直接替换——一个 Pod——资源最少 | 开发者自己 | 独立的 dev DB——测试数据 |
| <strong>staging</strong> | dev 部署成功后自动触发 | 滚动更新——2 个 Pod——模拟生产 | 自动回归测试 + QA 手动验证 | 脱敏的生产数据副本 |
| <strong>prod</strong> | 人工审批——在 GitLab UI 中点按钮 | 滚动更新——3+ Pod——不能停服务 | 所有人在线盯着——出问题秒回滚 | 生产 DB——绝对不能错 |

### 2.2 GitLab Environments——在 GitLab 中管理部署历史

```yaml
# GitLab 内置的 Environment 功能——每个环境自动记录部署历史
# 在 GitLab UI → Deployments → Environments 中能看到所有环境的部署记录

deploy-to-dev:
  stage: deploy-dev
  environment:
    name: dev                         # ← 环境名——显示在 GitLab UI 中
    url: http://order-service.dev.internal/actuator/health  # ← 环境 URL——可点击
  script:
    - kubectl set image deployment/order-service order-service=$IMAGE_NAME:$CI_COMMIT_SHORT_SHA -n dev

deploy-to-staging:
  stage: deploy-staging
  environment:
    name: staging
    url: https://order-service.staging.internal
  script:
    - kubectl set image deployment/order-service order-service=$IMAGE_NAME:$CI_COMMIT_SHORT_SHA -n staging

deploy-to-prod:
  stage: deploy-prod
  environment:
    name: production
    url: https://order-service.internal
  script:
    - kubectl set image deployment/order-service order-service=$IMAGE_NAME:$CI_COMMIT_SHORT_SHA -n production
```

## 三、📝 完整的多环境 Pipeline

### 3.1 完整 yml——5 个部署阶段

```yaml
# .gitlab-ci.yml——完整版
stages:
  - compile          # 编译
  - test             # 测试
  - quality          # SonarQube
  - package          # 打包 + 构建镜像 + 推送 Harbor
  - deploy-dev       # 部署 dev
  - deploy-staging   # 部署 staging
  - test-staging     # 自动化回归测试
  - deploy-prod      # 部署 prod（人工审批）

# ===== 之前的 compile/test/quality/package/push 阶段省略——同上一篇 =====

# ===== Stage: 部署 dev——每次 push main 自动部署 =====
deploy-to-dev:
  stage: deploy-dev
  image: bitnami/kubectl:1.28
  environment:
    name: dev
    url: http://order-service.dev.internal/actuator/health
  script:
    # ① 配 kubeconfig——从 GitLab CI/CD Variables 中拿
    - echo "$KUBECONFIG_DEV" > /tmp/kubeconfig
    - export KUBECONFIG=/tmp/kubeconfig
    
    # ② 滚动更新——更新 Deployment 的镜像
    - kubectl set image deployment/order-service
        order-service=$IMAGE_NAME:$CI_COMMIT_SHORT_SHA
        -n dev --record
    
    # ③ 等待滚动更新完成
    - kubectl rollout status deployment/order-service -n dev --timeout=120s
    
    # ④ 健康检查——curl 验证新 Pod 是否正常响应
    - sleep 5  # 等 Service 选到新 Pod
    - |
      HEALTH=$(curl -s -o /dev/null -w "%{http_code}" http://order-service.dev.internal/actuator/health)
      if [ "$HEALTH" != "200" ]; then
        echo "❌ 健康检查失败——状态码: $HEALTH"
        kubectl rollout undo deployment/order-service -n dev
        exit 1
      fi
      echo "✅ 健康检查通过——dev 部署成功"
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
  tags:
    - docker

# ===== Stage: 部署 staging——dev 成功后才执行 =====
deploy-to-staging:
  stage: deploy-staging
  image: bitnami/kubectl:1.28
  environment:
    name: staging
    url: https://order-service.staging.internal
  script:
    - echo "$KUBECONFIG_STAGING" > /tmp/kubeconfig
    - export KUBECONFIG=/tmp/kubeconfig
    
    # Staging 用更高的副本数——模拟生产
    - kubectl scale deployment/order-service --replicas=2 -n staging
    - kubectl set image deployment/order-service
        order-service=$IMAGE_NAME:$CI_COMMIT_SHORT_SHA -n staging
    - kubectl rollout status deployment/order-service -n staging --timeout=120s
    
    - sleep 5
    - |
      HEALTH=$(curl -s -o /dev/null -w "%{http_code}" https://order-service.staging.internal/actuator/health)
      if [ "$HEALTH" != "200" ]; then
        echo "❌ Staging 健康检查失败"
        kubectl rollout undo deployment/order-service -n staging
        exit 1
      fi
      echo "✅ Staging 部署成功"
  needs:
    - deploy-to-dev            # 必须等 dev 部署成功——不需要等其他 job
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
  tags:
    - docker

# ===== Stage: staging 自动化回归测试 =====
auto-regression-test:
  stage: test-staging
  image: maven:3.9-eclipse-temurin-17
  script:
    # 跑自动化测试——打 staging 环境
    - mvn test -Pstaging -Dstaging.base-url=https://order-service.staging.internal
  artifacts:
    when: always
    paths:
      - target/surefire-reports/
  needs:
    - deploy-to-staging
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
  tags:
    - docker

# ===== Stage: 部署 prod——人工审批‼️ =====
deploy-to-prod:
  stage: deploy-prod
  image: bitnami/kubectl:1.28
  environment:
    name: production
    url: https://order-service.internal
  script:
    - echo "$KUBECONFIG_PROD" > /tmp/kubeconfig
    - export KUBECONFIG=/tmp/kubeconfig
    
    # 记录当前镜像——回滚用
    - |
      CURRENT_IMAGE=$(kubectl get deployment order-service -n production
          -o jsonpath='{.spec.template.spec.containers[0].image}')
      echo "当前镜像: $CURRENT_IMAGE"
      echo "新镜像: $IMAGE_NAME:$CI_COMMIT_SHORT_SHA"
    
    # 滚动更新
    - kubectl set image deployment/order-service
        order-service=$IMAGE_NAME:$CI_COMMIT_SHORT_SHA
        -n production --record
    
    # 等待——生产环境给更长的超时——3 分钟
    - kubectl rollout status deployment/order-service -n production --timeout=180s
    
    - sleep 10
    - |
      for i in 1 2 3; do
        HEALTH=$(curl -s -o /dev/null -w "%{http_code}" https://order-service.internal/actuator/health)
        if [ "$HEALTH" = "200" ]; then
          echo "✅ 健康检查通过（第 $i 次）"
          exit 0
        fi
        echo "⚠️ 健康检查失败（第 $i 次）——等待 10 秒重试"
        sleep 10
      done
      echo "❌ 健康检查连续失败 3 次——自动回滚"
      kubectl rollout undo deployment/order-service -n production
      exit 1
    
  # ← ‼️ 关键——人工审批——在 GitLab UI 中手动点击才执行
  when: manual
  # 只允许 main 分支部署——但需要手动触发
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
      when: manual
  tags:
    - docker

# ===== 回滚 job——紧急情况一键回滚 =====
rollback-prod:
  stage: deploy-prod
  image: bitnami/kubectl:1.28
  environment:
    name: production
    url: https://order-service.internal
  script:
    - echo "$KUBECONFIG_PROD" > /tmp/kubeconfig
    - export KUBECONFIG=/tmp/kubeconfig
    - |
      echo "回滚前版本:"
      kubectl rollout history deployment/order-service -n production --revision=3
    - kubectl rollout undo deployment/order-service -n production
    - kubectl rollout status deployment/order-service -n production --timeout=120s
  when: manual
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
      when: manual
  tags:
    - docker
```

### 3.2 Pipeline 的实际执行流程

```
push 代码到 main → Pipeline 触发：

┌────────────────────────────────────────────────────────────┐
│ 自动执行部分                                                 │
│                                                             │
│  compile ──→ test ──→ sonarqube ──→ package/docker-build    │
│                                          │                  │
│                              ┌───────────┴───────────┐      │
│                              ▼                       ▼      │
│                        deploy-to-dev          deploy-to-staging
│                              │                       │      │
│                              ▼                       ▼      │
│                        健康检查通过             auto-regression-test
│                              │                       │      │
│                              └───────────┬───────────┘      │
│                                          ▼                  │
│                                    Pipeline 暂停             │
│                                    等待手动触发              │
└────────────────────────────────────────────────────────────┘

                                     ↓ 人工操作
                            ┌──────────────────┐
                            │ 产品经理/QA 确认   │
                            │ staging 验证 OK    │
                            │ 点击 ▶️ 按钮       │
                            └──────────────────┘
                                     ↓
┌────────────────────────────────────────────────────────────┐
│ deploy-to-prod ▶️ (手动触发)                                │
│   → 滚动更新 → 健康检查                                      │
│   → 成功：记录部署历史                                       │
│   → 失败：自动回滚                                           │
└────────────────────────────────────────────────────────────┘
```

## 四、📦 Kubernetes Deployment 配合 CI/CD

### 4.1 Deployment 模板——配合滚动更新

```yaml
# k8s/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
  namespace: production
  labels:
    app: order-service
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0       # ← 滚动更新时——不能有不可用的 Pod——保证服务不中断
      maxSurge: 1             # ← 滚动更新时——最多额外创建 1 个 Pod
  
  # selector 不变——不管怎么更新 Pod template
  selector:
    matchLabels:
      app: order-service
  
  template:
    metadata:
      labels:
        app: order-service
        version: "${VERSION}"   # ← 每次部署注入新版本
      annotations:
        # 每次都变——让 K8s 知道 template 变了——触发滚动更新
        commit: "${CI_COMMIT_SHORT_SHA}"
    spec:
      containers:
        - name: order-service
          image: ${IMAGE_NAME}:${CI_COMMIT_SHORT_SHA}   # ← CI/CD 中替换
          imagePullPolicy: Always
          ports:
            - containerPort: 8081
          
          # 健康检查——配合 CI/CD 中的 curl 验证
          livenessProbe:
            httpGet:
              path: /actuator/health/liveness
              port: 8081
            initialDelaySeconds: 30
            periodSeconds: 10
          
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: 8081
            initialDelaySeconds: 10
            periodSeconds: 5
          
          # 资源限制
          resources:
            requests:
              memory: "512Mi"
              cpu: "250m"
            limits:
              memory: "1Gi"
              cpu: "500m"
          
          # 从 ConfigMap 拿配置——不同环境用不同的 ConfigMap
          envFrom:
            - configMapRef:
                name: order-service-config
            - secretRef:
                name: order-service-secret
```

### 4.2 环境变量分层——CI Variables → ConfigMap → Secret

```
配置的三个来源——按敏感度分层：

① GitLab CI/CD Variables（最敏感——不进 K8s）
   - HARBOR_PASSWORD
   - KUBECONFIG_PROD
   - SONAR_TOKEN
   - WECHAT_WEBHOOK_KEY
   → 只在 CI/CD 运行时可见——不进 K8s

② K8s Secret（敏感——但服务需要）
   - spring.datasource.password
   - spring.redis.password
   - nacos.config.password
   → 存在 K8s Secret 中——Pod 启动时注入环境变量

③ K8s ConfigMap（不敏感——纯配置）
   - spring.profiles.active=prod
   - spring.cloud.nacos.server-addr=nacos.prod.internal:8848
   - logging.level.root=WARN
   → 存在 K8s ConfigMap 中——不同环境不同值
```

```yaml
# k8s/configmap.yaml——dev 环境
apiVersion: v1
kind: ConfigMap
metadata:
  name: order-service-config
  namespace: dev
data:
  SPRING_PROFILES_ACTIVE: "dev"
  SPRING_CLOUD_NACOS_DISCOVERY_SERVER-ADDR: "nacos.dev.internal:8848"
  LOGGING_LEVEL_COM_EXAMPLE: "DEBUG"

---
# k8s/configmap.yaml——prod 环境（不同的值）
apiVersion: v1
kind: ConfigMap
metadata:
  name: order-service-config
  namespace: production
data:
  SPRING_PROFILES_ACTIVE: "prod"
  SPRING_CLOUD_NACOS_DISCOVERY_SERVER-ADDR: "nacos.prod.internal:8848"
  LOGGING_LEVEL_COM_EXAMPLE: "WARN"
```

## 五、🔄 版本回滚——三种方式

### 方式一：GitLab UI 一键回滚（最推荐）

```yaml
# 上面的 rollback-prod job——在 GitLab UI 中直接点 ▶️ 就回滚
rollback-prod:
  stage: deploy-prod
  environment:
    name: production
  script:
    - kubectl rollout undo deployment/order-service -n production
  when: manual
```

```
操作：GitLab → CI/CD → Pipelines → 找到上一次成功的 Pipeline → 
      找到 rollback-prod job → 点 ▶️ → Kubectl rollout undo → 回滚完成
      耗时：5 秒
```

### 方式二：kubectl rollout undo（命令行回滚）

```bash
# 查看部署历史——找到要回滚的版本
kubectl rollout history deployment/order-service -n production

# 输出：
# REVISION  CHANGE-CAUSE
# 1         <none>
# 2         kubectl set image deployment/order-service order-service=...:abc123 --record
# 3         kubectl set image deployment/order-service order-service=...:def456 --record  ← 当前——有问题

# 回滚到上一个版本
kubectl rollout undo deployment/order-service -n production

# 回滚到指定版本
kubectl rollout undo deployment/order-service -n production --to-revision=1
```

### 方式三：kubectl set image——手动指定旧镜像

```bash
# 直接用旧镜像——快速但不推荐——因为你可能不记得旧镜像 tag
kubectl set image deployment/order-service \
  order-service=harbor.local:5000/order-service:abc123 \
  -n production
```

### 回滚的最佳实践

```yaml
# deploy-to-prod job 中——自动记录回滚所需信息
deploy-to-prod:
  script:
    # ...
    - |
      # 把当前镜像信息保存为 dotenv artifact——供回滚 job 使用
      echo "PREVIOUS_IMAGE=$CURRENT_IMAGE" > rollout.env
  artifacts:
    reports:
      dotenv: rollout.env   # ← 自动传递给同一 Pipeline 的后续 job

rollback-prod:
  needs:
    - deploy-to-prod        # 可以拿到上一个 job 的 dotenv 变量
  script:
    # 拿到 deploy-to-prod 记录的镜像
    - echo "回滚到: $PREVIOUS_IMAGE"
    - kubectl set image deployment/order-service order-service=$PREVIOUS_IMAGE -n production
```

## 六、🚀 Helm——简化 K8s 部署模板

### 6.1 为什么需要 Helm——3 个环境 × 5 个服务 = 15 份几乎一样的 yaml

```
手动管理 K8s yaml 的痛苦：
  dev/    deployment.yaml  ← 几乎一样——只有 replicas/namespace/env 不同
  staging/deployment.yaml  ← 几乎一样
  prod/   deployment.yaml  ← 几乎一样
  
  → 改一个字段——同步到 3 个环境——漏了一个就出问题
```

```bash
# Helm——用模板 + values 分离"结构"和"环境差异"
# 一个 templates/ 目录 + 每个环境一个 values.yaml

order-service-helm/
├── Chart.yaml              # Chart 元信息
├── values.yaml             # 默认 values（dev 基准）
├── values-staging.yaml     # staging 覆盖值
├── values-prod.yaml        # prod 覆盖值
└── templates/
    ├── deployment.yaml     # ← 模板——用 {{ .Values.xxx }} 占位
    ├── service.yaml
    └── configmap.yaml
```

### 6.2 Helm template 示例

```yaml
# templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Values.appName }}
  namespace: {{ .Values.namespace }}
spec:
  replicas: {{ .Values.replicaCount }}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: {{ .Values.rollingUpdate.maxUnavailable }}
      maxSurge: {{ .Values.rollingUpdate.maxSurge }}
  selector:
    matchLabels:
      app: {{ .Values.appName }}
  template:
    metadata:
      labels:
        app: {{ .Values.appName }}
        version: "{{ .Values.image.tag }}"
    spec:
      containers:
        - name: {{ .Values.appName }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          ports:
            - containerPort: {{ .Values.containerPort }}
          resources:
            requests:
              memory: {{ .Values.resources.requests.memory }}
              cpu: {{ .Values.resources.requests.cpu }}
            limits:
              memory: {{ .Values.resources.limits.memory }}
              cpu: {{ .Values.resources.limits.cpu }}
          envFrom:
            - configMapRef:
                name: {{ .Values.appName }}-config
            - secretRef:
                name: {{ .Values.appName }}-secret
```

```yaml
# values-dev.yaml
replicaCount: 1
namespace: dev
image:
  repository: harbor.local:5000/order-service
  tag: latest
resources:
  requests:
    memory: "256Mi"
    cpu: "100m"
  limits:
    memory: "512Mi"
    cpu: "250m"
rollingUpdate:
  maxUnavailable: 1   # dev 可以短暂不可用——省钱
  maxSurge: 1

---
# values-prod.yaml
replicaCount: 3
namespace: production
image:
  repository: harbor.local:5000/order-service
  tag: ""             # CI/CD 中通过 --set 注入
resources:
  requests:
    memory: "512Mi"
    cpu: "250m"
  limits:
    memory: "1Gi"
    cpu: "500m"
rollingUpdate:
  maxUnavailable: 0   # prod 绝对不能中断服务
  maxSurge: 1
```

```yaml
# CI/CD 中使用 Helm 部署
deploy-with-helm:
  stage: deploy-dev
  image: alpine/helm:3.13
  script:
    - |
      helm upgrade order-service ./order-service-helm \
        --install \
        --namespace dev \
        --values ./order-service-helm/values-dev.yaml \
        --set image.tag=$CI_COMMIT_SHORT_SHA \
        --wait \
        --timeout 120s
```

## 七、📋 发布 Checklist——生产部署前必查

```yaml
# 在 deploy-to-prod 前加一个 checklist job——不跑完不让部署

pre-deploy-checklist:
  stage: deploy-prod
  script:
    - echo "===== 部署前检查清单 ====="
    
    # ① 确认所有测试通过
    - |
      if [ "$TEST_RESULT" != "PASSED" ]; then
        echo "❌ 测试未通过——禁止部署"
        exit 1
      fi
      echo "✅ 测试通过"
    
    # ② 确认 SonarQube Quality Gate
    - |
      QG_STATUS=$(curl -s -u $SONAR_TOKEN: \
        "$SONAR_HOST_URL/api/qualitygates/project_status?projectKey=order-service" \
        | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
      if [ "$QG_STATUS" != "OK" ]; then
        echo "❌ SonarQube Quality Gate 失败——禁止部署"
        exit 1
      fi
      echo "✅ Quality Gate 通过"
    
    # ③ 确认是工作日（非周五下午 5 点后）
    - |
      DAY=$(date +%u)    # 1=Mon, 5=Fri
      HOUR=$(date +%H)
      if [ "$DAY" -eq 5 ] && [ "$HOUR" -ge 17 ]; then
        echo "⚠️ 周五下午 5 点后——不建议部署——如有紧急情况请找 Leader 审批"
        # exit 1  # 如果硬性禁止——取消注释
      fi
      echo "✅ 时间窗口 OK"
    
    # ④ 确认 staging 健康
    - |
      STAGING_HEALTH=$(curl -s -o /dev/null -w "%{http_code}" \
        https://order-service.staging.internal/actuator/health)
      if [ "$STAGING_HEALTH" != "200" ]; then
        echo "❌ Staging 环境不健康——请检查"
        exit 1
      fi
      echo "✅ Staging 环境健康"
    
    echo "===== 所有检查通过——可以部署到生产 ====="
  when: manual
  # 这个 job 也需要手动触发——如果失败——后面的 deploy-to-prod 不会执行
```

## 🎯 总结

1. <strong>多环境部署 = dev（自动）→ staging（自动 + 回归测试）→ prod（人工审批 + 手动触发）</strong>：GitLab `when: manual` 实现人工审批——在 UI 中点一个按钮才部署生产。GitLab Environments 自动记录每次部署历史——哪次部署了哪个 commit——一键回滚。

2. <strong>K8s 滚动更新 + CI/CD 健康检查——部署失败自动回滚</strong>：`kubectl rollout status` 等待更新完成——`curl` 健康检查验证新 Pod 正常——失败则 `kubectl rollout undo` 自动回滚——把对生产的影响降到最低。

3. <strong>配置三分层——CI Variables（密码）→ K8s Secret（服务机密）→ K8s ConfigMap（环境配置）</strong>：Harbor 密码、Kubeconfig 在 CI Variables 中——不进入 K8s。数据库密码在 K8s Secret 中——Pod 通过 Secret 引用。Nacos 地址、日志级别在 ConfigMap 中——不同环境不同值。

4. <strong>Helm 解决多环境 yaml 重复——模板化 + values 覆盖</strong>：一个 `templates/deployment.yaml`——`values-dev.yaml` / `values-staging.yaml` / `values-prod.yaml` 分别覆盖——改一次模板——所有环境受益。

> 📖 <strong>系列回顾</strong>：GitLab CI/CD 三部曲到此结束——
> 1. [<strong>搭建与 Pipeline 语法精讲</strong>]({{< relref "GitlabCicdFundamentals.md" >}}) —— GitLab + Runner 搭建、stages/jobs/artifacts/cache/needs/rules
> 2. [<strong>流水线实战——编译到镜像推送</strong>]({{< relref "GitlabCicdPipeline.md" >}}) —— 编译 + 测试 + SonarQube + Docker Build + Push Harbor
> 3. <strong>多环境部署与生产实践</strong>（本文） —— dev/staging/prod 多环境、K8s 部署、版本回滚、Helm
>
> 📖 <strong>下一步预告</strong>：微服务拆完了、CI/CD 跑起来了——但下单流程跨 5 个服务——怎么保证数据一致性？下一系列——分布式事务：Seata AT/TCC/Saga + RocketMQ 事务消息 + 本地消息表。讲清楚本质是什么、怎么不踩坑、怎么做。
