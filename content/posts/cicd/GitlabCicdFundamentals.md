---
title: "GitLab CI/CD 搭建与 Pipeline 语法精讲"
date: 2022-12-24T08:00:00+00:00
tags: ["运维与可观测"]
categories: ["CICD类"]
author: "yaomingye"
showToc: true
TocOpen: true
draft: false
hidemeta: false
comments: false
description: "从零搭建 GitLab CI/CD：GitLab + Runner Docker Compose 部署、Runner 注册与执行原理（shell vs docker executor）、.gitlab-ci.yml 语法精讲（stages/jobs/script/cache/artifacts/variables/needs/rules）、预定义变量（CI_COMMIT_SHA 等）、制品传递原理、Maven 依赖缓存策略——以及第一个可运行的 Pipeline：编译 → 跑单测 → 看绿色对号。"
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

# GitLab CI/CD 搭建与 Pipeline 语法精讲

## 一、⚡ 周五下午 5 点上线——你手动执行了 15 步操作——到第 12 步出错了

回想一下你现在的发布流程：

```
发布一个微服务的流程：
  ① git pull latest
  ② mvn clean package -DskipTests（"测试先跳过——着急"）
  ③ 手动改 application-prod.yml 中的配置（"这个值上次没改对"）
  ④ docker build -t order-service:v1.2.3 .
  ⑤ docker tag order-service:v1.2.3 harbor.internal/order-service:v1.2.3
  ⑥ docker push harbor.internal/order-service:v1.2.3
  ⑦ ssh root@k8s-master
  ⑧ kubectl set image deployment/order-service order-service=harbor.internal/order-service:v1.2.3
  ⑨ kubectl rollout status deployment/order-service
  ⑩ curl 验证——啊——404——服务没起来
  ⑪ kubectl logs——发现是 application.yml 中的 Nacos 地址配错了
  ⑫ kubectl rollout undo——回滚
  ⑬ 改配置——重新来——docker build + push + deploy
  ⑭ 又发现 product-service 没同步上线——接口报错了
  ⑮ 告警响了——用户已经在群里骂了
  
  → 每次发布都像拆炸弹——不知道哪一步会出问题
```

<strong>CI/CD 要解决的就是：把人从 15 步中解放出来——每次 git push——自动编译、自动测试、自动构建镜像、自动部署——15 步变成 1 步。</strong>

## 二、🧩 GitLab CI/CD 的核心——不是什么——而是什么

### 2.1 不是什么

```
❌ GitLab CI/CD 不是 Jenkins——不需要单独部署一个 Jenkins Server
❌ GitLab CI/CD 不是 GitHub Actions——不需要 .github/workflows/ 目录
❌ GitLab CI/CD 不是代码——它是 YAML——描述你要做什么

GitLab CI/CD 的本质：
  → GitLab（代码托管）内置了 CI/CD 引擎
  → 你在项目根目录放一个 .gitlab-ci.yml——GitLab 读到后自动执行
  → Runner（执行器）是独立的进程——GitLab 把任务发给 Runner 执行
```

### 2.2 核心组件——四个角色

```
┌───────────────────────────────────────────────────────────────┐
│                     GitLab CI/CD 架构                          │
│                                                               │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐   │
│  │   GitLab      │────→│    Runner    │────→│  Docker/Shell │   │
│  │   Server      │     │   (执行器)   │     │  (实际环境)   │   │
│  │               │     │              │     │              │   │
│  │ ① 存代码      │     │ ③ 拉代码      │     │ ⑤ mvn compile│   │
│  │ ② 读 .yml    │     │ ④ 执行 job    │     │ ⑥ mvn test   │   │
│  │ ⑦ 展示结果    │     │              │     │ ⑧ docker build│  │
│  └──────────────┘     └──────────────┘     └──────────────┘   │
│                                                               │
│  ┌──────────────┐                                             │
│  │ .gitlab-ci.yml│    ← 你写的 Pipeline 定义文件               │
│  │ (项目根目录)   │      stages → jobs → 脚本                   │
│  └──────────────┘                                             │
└───────────────────────────────────────────────────────────────┘
```

| 组件 | 作用 | 部署在哪 |
|------|------|------|
| <strong>GitLab Server</strong> | 存代码 + 解析 `.gitlab-ci.yml` + 调度 Runner + 展示结果 | 一台服务器——Docker 部署 |
| <strong>GitLab Runner</strong> | 执行 job——拉代码、跑脚本、上传 artifacts | 另起一个容器——独立于 GitLab Server |
| <strong>`.gitlab-ci.yml`</strong> | 你写的 Pipeline 定义——描述"做什么" | 项目根目录——和代码一起提交 |
| <strong>Executor</strong> | Runner 用哪种方式执行 job——Shell / Docker / Kubernetes | Runner 注册时指定 |

## 三、🔧 搭建 GitLab + Runner——Docker Compose

### 3.1 完整的 Docker Compose

```yaml
version: '3.8'
services:

  # ===== GitLab Server =====
  gitlab:
    image: gitlab/gitlab-ce:16.5.0-ce.0
    container_name: gitlab
    hostname: gitlab.local               # ← 访问的域名——设成本机 IP 或域名
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'http://gitlab.local'
        # 关闭不需要的服务——省内存
        prometheus_monitoring['enable'] = false
        alertmanager['enable'] = false
        gitlab_rails['gitlab_default_theme'] = 2
    ports:
      - "80:80"         # HTTP——浏览器访问
      - "443:443"       # HTTPS
      - "2222:22"       # SSH——git clone 用 SSH 的话
    volumes:
      - gitlab-config:/etc/gitlab
      - gitlab-log:/var/log/gitlab
      - gitlab-data:/var/opt/gitlab
    restart: unless-stopped

  # ===== GitLab Runner =====
  gitlab-runner:
    image: gitlab/gitlab-runner:alpine-v16.5.0
    container_name: gitlab-runner
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock   # ← Runner 需要调 Docker
      - gitlab-runner-config:/etc/gitlab-runner
    restart: unless-stopped

volumes:
  gitlab-config:
  gitlab-log:
  gitlab-data:
  gitlab-runner-config:
```

```bash
# 启动
docker-compose up -d

# GitLab 启动需要 2-3 分钟——耐心等待
# 查看启动状态
docker logs -f gitlab

# 看到这行表示 GitLab 已就绪：
# ==> /var/log/gitlab/gitlab-rails/production.log <==
# Started GET "/" for ...

# 获取初始 root 密码
docker exec -it gitlab cat /etc/gitlab/initial_root_password
# 复制密码——登录后尽快修改
```

### 3.2 注册 Runner——Runner 和 GitLab 配对

```bash
# 注册 Runner——把 Runner 绑定到 GitLab
# 第一步：在 GitLab UI 中获取 Registration Token
# 打开 http://gitlab.local → Admin Area → CI/CD → Runners → 复制 Registration Token

# 第二步：执行注册命令
docker exec -it gitlab-runner gitlab-runner register

# 交互式问答：
# Enter the GitLab instance URL:
http://gitlab.local                        ← GitLab 地址

# Enter the registration token:
GR1348941xxxxxxxxxxxx                       ← 刚才复制的 Token

# Enter a description for the runner:
docker-runner                               ← Runner 描述——随便起

# Enter tags for the runner (comma-separated):
docker,spring-boot                          ← 标签——后续 .gitlab-ci.yml 中通过 tag 指定用哪个 Runner

# Enter optional maintenance note:
（回车跳过）

# Enter an executor:
docker                                     ← ← ← 最重要——选 docker executor
# 可选：shell, docker, kubernetes, docker+machine
# docker executor：每个 job 起一个干净容器——互不干扰——推荐

# Enter the default Docker image:
maven:3.9-eclipse-temurin-17               ← 默认镜像——Maven + JDK 17
```

```bash
# 注册完成后——验证
docker exec -it gitlab-runner cat /etc/gitlab-runner/config.toml

# 期望看到：
# [[runners]]
#   name = "docker-runner"
#   url = "http://gitlab.local"
#   token = "xxxxxxxxxxxx"
#   executor = "docker"
#   [runners.docker]
#     image = "maven:3.9-eclipse-temurin-17"

# 回到 GitLab UI——Runners 页面——应该看到这个 Runner 是绿色的圆形图标——表示已连接
```

### 3.3 Runner 的执行原理——docker executor 做了什么

```
当你 git push 到 GitLab——触发 Pipeline：
  
  ① GitLab 解析 .gitlab-ci.yml——把 job 放入队列
  
  ② Runner 轮询 GitLab——发现有新 job
  
  ③ Runner 起一个 Docker 容器——用你注册时指定的 image
     → docker run maven:3.9-eclipse-temurin-17
  
  ④ Runner 在容器内执行操作：
     → git clone 你的项目代码到容器内
     → 执行 job 定义的 script
     → 收集 artifacts（如果有）
  
  ⑤ Job 执行完——容器被销毁——干净的环境——下次 job 又是全新的容器
  
  关键：每个 job 是独立容器——job A 安装的东西不会影响 job B
       → 如果需要共享——用 cache 和 artifacts
```

## 四、📝 .gitlab-ci.yml 语法精讲——一切从这里开始

### 4.1 最小可运行的 Pipeline

```yaml
# .gitlab-ci.yml —— 放在项目根目录
# 这是最小可运行的 Pipeline

stages:                    # ← 定义阶段——按顺序执行
  - build                  # 第一阶段：编译
  - test                   # 第二阶段：测试（build 过了才执行 test）

variables:                 # ← 全局变量——所有 job 都能用
  MAVEN_OPTS: "-Dmaven.repo.local=$CI_PROJECT_DIR/.m2/repository"

# ===== build 阶段的 job =====
compile-job:               # ← job 名字——随便起——显示在 Pipeline 页面
  stage: build             # ← 这个 job 属于 build 阶段
  image: maven:3.9-eclipse-temurin-17  # ← 在什么镜像中执行
  script:                  # ← 要执行的命令——核心
    - mvn compile
  tags:
    - docker               # ← 指定用哪个 Runner（注册 Runner 时填的 tag）

# ===== test 阶段的 job =====
unit-test-job:
  stage: test
  image: maven:3.9-eclipse-temurin-17
  script:
    - mvn test
  tags:
    - docker
```

```bash
# 提交这个文件——git push——打开 GitLab → CI/CD → Pipelines
git add .gitlab-ci.yml
git commit -m "add ci pipeline"
git push origin main

# 浏览器打开：http://gitlab.local/<your-group>/<your-project>/-/pipelines
# 看到 Pipeline 在运行——compile-job → unit-test-job——依次执行
```

### 4.2 stages——Pipeline 的阶段顺序

```yaml
# Stage 控制 job 的执行顺序——同一 stage 的 job 可以并行
# 后一个 stage 必须等前一个 stage 的全部 job 完成才能开始

stages:
  - build        # ① 编译——必须最先
  - test         # ② 测试——编译过了才能测
  - analysis     # ③ 代码扫描——测试过了才扫
  - package      # ④ 打包镜像——都过了才打镜像
  - deploy       # ⑤ 部署——最后
```

```yaml
# 同一个 stage 的多个 job 会并行执行
stages:
  - test

# 这两个 job 同在 test stage——并行执行——节省时间
unit-test:
  stage: test
  script: mvn test

integration-test:
  stage: test
  script: mvn verify -Pintegration
```

### 4.3 预定义变量——CI/CD 环境自带的信息

```yaml
# GitLab 提供了大量预定义变量——不需要你设置——自动可用
# 完整列表：https://docs.gitlab.com/ee/ci/variables/predefined_variables.html

# 最常用的 15 个：
variables:
  # 项目相关
  # CI_PROJECT_DIR = /builds/group/project        ← Runner 拉代码的目录
  # CI_PROJECT_NAME = order-service                ← 项目名
  # CI_PROJECT_PATH = mygroup/order-service        ← 项目路径

  # 提交相关
  # CI_COMMIT_SHA = abc123def456...                ← 完整的 commit SHA
  # CI_COMMIT_SHORT_SHA = abc123de                 ← 前 8 位
  # CI_COMMIT_BRANCH = main                        ← 当前分支
  # CI_COMMIT_TAG = v1.2.3                         ← 如果有 tag——没有则为空
  # CI_COMMIT_MESSAGE = fix: fix order bug         ← commit message

  # Pipeline 相关
  # CI_PIPELINE_ID = 12345                         ← Pipeline ID
  # CI_PIPELINE_URL = http://gitlab/.../pipelines/12345
  # CI_JOB_ID = 67890                              ← 当前 job ID

  # 环境
  # CI_REGISTRY = registry.gitlab.local            ← GitLab 内置的容器镜像仓库地址
  # CI_REGISTRY_USER = gitlab-ci-token             ← 自动创建的认证用户
  # CI_REGISTRY_PASSWORD = [auto-generated]        ← 自动创建的密码
```

```yaml
# 实战用法——根据分支决定不同的行为
docker-build:
  stage: package
  script:
    # 用 commit SHA 作为镜像 tag——每个构建唯一
    - docker build -t order-service:$CI_COMMIT_SHORT_SHA .
    # 如果是 main 分支——也打 latest tag
    - |
      if [ "$CI_COMMIT_BRANCH" = "main" ]; then
        docker tag order-service:$CI_COMMIT_SHORT_SHA order-service:latest
      fi
```

### 4.4 cache——job 之间共享依赖——避免重复下载

```yaml
# 没有 cache——每个 job 重新下载依赖——慢
# compile-job → 跑完容器销毁 → test-job 起新容器 → Maven 重新下载所有 jar → 5 分钟

# 有 cache——缓存 .m2 目录——复用依赖——快
stages:
  - build
  - test

variables:
  MAVEN_OPTS: "-Dmaven.repo.local=$CI_PROJECT_DIR/.m2/repository"
  # ↑ 把 Maven 本地仓库指向项目目录下——而不是 /root/.m2——方便 cache

# 全局 cache——所有 job 共用
cache:
  key: maven-cache-${CI_COMMIT_REF_SLUG}   # ← cache key——一个分支一个缓存
  paths:
    - .m2/repository/                       # ← 缓存这个目录
  policy: pull-push                         # ← 默认：拉 + 推——job 开始前拉缓存——结束后推缓存

compile:
  stage: build
  image: maven:3.9-eclipse-temurin-17
  script:
    - mvn compile
  cache:
    key: ${CI_COMMIT_REF_SLUG}
    paths:
      - .m2/repository/
    policy: pull-push     # ← 推拉——这个 job 会更新缓存

unit-test:
  stage: test
  image: maven:3.9-eclipse-temurin-17
  script:
    - mvn test
  cache:
    key: ${CI_COMMIT_REF_SLUG}
    paths:
      - .m2/repository/
    policy: pull          # ← 只拉——只读——不更新缓存——因为 test 不会下载新依赖
```

<strong>cache vs artifacts——核心区别</strong>：

| 维度 | cache | artifacts |
|------|------|------|
| <strong>用途</strong> | 加速构建——缓存依赖 | 传递构建产物——jar / war / 报告 |
| <strong>内容</strong> | `.m2/repository`, `node_modules` | `target/*.jar`, `target/surefire-reports/` |
| <strong>跨 Pipeline 共享</strong> | ✅ 是——同一个 cache key 的 Pipeline 都能用 | ❌ 否——只在同一个 Pipeline 的 job 间传递 |
| <strong>一定会传吗</strong> | ❌ 不保证——Runner 可能没命中缓存 | ✅ 保证——job 成功就一定有 |
| <strong>Web 下载</strong> | ❌ 不提供下载 | ✅ 在 GitLab UI 中可下载 |

### 4.5 artifacts——job 间传递文件——最关键的概念

```yaml
# 场景：compile-job 编译出了 target/classes/
#       test-job 需要 target/classes/ 才能跑测试
#       但每个 job 是独立容器——compile-job 的 target/ 在 test-job 中不存在
#
# 解决：compile-job 把 target/ 作为 artifacts 上传——test-job 自动下载

compile:
  stage: build
  image: maven:3.9-eclipse-temurin-17
  script:
    - mvn compile
  artifacts:
    paths:
      - target/classes/           # ← 上传 target/classes/ 目录
    expire_in: 1 hour             # ← 1 小时后自动删除——省空间

unit-test:
  stage: test
  image: maven:3.9-eclipse-temurin-17
  script:
    - mvn test                    # ← 自动拿到了 compile-job 的 target/classes/
  artifacts:
    when: always                  # ← 无论成功失败——都上传测试报告
    paths:
      - target/surefire-reports/  # ← 上传测试报告——在 GitLab UI 中可下载
    expire_in: 7 days
```

```yaml
# 另一个经典场景——构建镜像的 job 需要 jar 包
# build-jar job 打包 → docker-build job 拿 jar 构建镜像

build-jar:
  stage: package
  image: maven:3.9-eclipse-temurin-17
  script:
    - mvn package -DskipTests
  artifacts:
    paths:
      - target/*.jar              # ← 上传 jar 包
    expire_in: 1 hour

docker-build:
  stage: package
  image: docker:24-dind           # ← 使用带 Docker daemon 的镜像
  script:
    - docker build -t order-service:$CI_COMMIT_SHORT_SHA .
    # Dockerfile 中的 COPY target/*.jar app.jar 直接可用——因为 jar 已经作为 artifact 传过来了
  needs:
    - build-jar                   # ← 等待 build-jar 完成并拿到它的 artifacts
```

### 4.6 needs——打破 stage 顺序——并行执行

```yaml
# 默认：stage 之间是串行的——build → test → deploy
# 用 needs：可以让特定 job 不等待其他 job——提前执行

stages:
  - build
  - test
  - deploy

# 默认行为——等待整个 test stage 完成
deploy-to-dev:
  stage: deploy
  script: ./deploy.sh dev
  # 默认需要前面 stage test 的所有 job 完成

# ❌ 慢——test stage 中有 5 个 test job——都完成才 deploy

# 使用 needs——只需要 unit-test 完成就能 deploy
deploy-to-dev:
  stage: deploy
  needs:
    - unit-test       # ← 只等 unit-test——不等 integration-test
  script: ./deploy.sh dev

# ✅ 快——unit-test 通过立刻 deploy——integration-test 还在跑也没关系
```

### 4.7 rules——条件执行——什么时候跑这个 job

```yaml
# 场景：测试 job 只在 MR 和 main 分支跑——其他分支不需要
#      部署 job 只在 main 分支跑

unit-test:
  stage: test
  script: mvn test
  rules:
    # 只在 merge request 或 main 分支或 tag 时执行
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == "main"
    - if: $CI_COMMIT_TAG
    # 其他情况——不执行

deploy-to-prod:
  stage: deploy
  script: ./deploy.sh prod
  rules:
    # 只打 tag 时部署——v1.0.0, v1.1.0 等
    - if: $CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/
```

```yaml
# 完整的条件控制
build-and-test:
  stage: test
  script: mvn test
  rules:
    # ① MR 触发——总是跑
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    # ② main 分支——push 后跑
    - if: $CI_COMMIT_BRANCH == "main"
    # ③ 开发分支——只在特定文件变化时跑
    - if: $CI_COMMIT_BRANCH =~ /^feature\//
      changes:                         # ← 只看这些文件/目录是否变更
        - src/**/*
        - pom.xml
    # ④ 不匹配任何规则——默认不执行
    - when: never
```

### 4.8 before_script / after_script——job 的前置和后置操作

```yaml
# before_script——在 script 之前执行——准备环境
# after_script——在 script 之后执行——清理——即使 script 失败也会执行

# 全局的前置/后置——每个 job 都会执行
default:
  before_script:
    - echo "=== Pipeline: $CI_PIPELINE_ID, Job: $CI_JOB_NAME ==="
    - java -version
    - mvn --version

# job 级别——覆盖全局
deploy:
  stage: deploy
  before_script:
    - echo "准备部署——目标环境: $DEPLOY_ENV"
    - apt-get update && apt-get install -y openssh-client
  script:
    - scp target/*.jar deployer@server:/app/
    - ssh deployer@server "sudo systemctl restart order-service"
  after_script:
    - echo "部署完成——健康检查"
    - curl -f http://server:8081/actuator/health || echo "健康检查失败！"
```

## 五、🧪 第一个可运行的完整 Pipeline

把前面的内容组合起来——给 order-service 写一个完整的 Pipeline：

```yaml
# order-service/.gitlab-ci.yml
stages:
  - build
  - test
  - package

variables:
  MAVEN_OPTS: "-Dmaven.repo.local=$CI_PROJECT_DIR/.m2/repository -Dorg.slf4j.simpleLogger.log.org.apache.maven.cli.transfer.Slf4jMavenTransferListener=WARN"

# ===== 全局缓存——Maven 依赖 =====
cache:
  key: maven-${CI_COMMIT_REF_SLUG}
  paths:
    - .m2/repository/

# ===== Stage 1: 编译 =====
compile:
  stage: build
  image: maven:3.9-eclipse-temurin-17
  script:
    - mvn compile -q
  artifacts:
    paths:
      - target/classes/
    expire_in: 1 hour
  tags:
    - docker

# ===== Stage 2: 测试 =====
unit-test:
  stage: test
  image: maven:3.9-eclipse-temurin-17
  script:
    - mvn test
  artifacts:
    when: always
    paths:
      - target/surefire-reports/
    expire_in: 7 days
    reports:
      junit: target/surefire-reports/TEST-*.xml    # ← 测试报告——GitLab 自动展示
  tags:
    - docker

# ===== Stage 3: 打包 =====
package:
  stage: package
  image: maven:3.9-eclipse-temurin-17
  script:
    - mvn package -DskipTests
  artifacts:
    paths:
      - target/*.jar
    expire_in: 1 hour
  only:
    - main          # 只有 main 分支打包
    - tags          # 或者有 tag
  tags:
    - docker
```

```bash
# 提交——推送到 GitLab
git add .gitlab-ci.yml
git commit -m "add CI pipeline"
git push origin main

# 打开 GitLab CICD → Pipelines——看到 Pipeline 运行
# 绿色对号 = 全部成功
# 红色叉号 = 有 job 失败——点进去看日志

# 点 unit-test job → 看到测试结果：
# Tests: 23 passed, 0 failed, 0 skipped
# 下载 target/surefire-reports/ 看详细报告
```

## 🎯 总结

1. <strong>GitLab CI/CD = GitLab Server（调度） + Runner（执行） + .gitlab-ci.yml（定义）</strong>：GitLab 内置 CI/CD 引擎——不需要 Jenkins Server。Runner 是独立进程——推荐 docker executor——每个 job 起干净容器——互不影响。

2. <strong>stages 控制阶段顺序——同一个 stage 的 job 并行执行</strong>：`stages: [build, test, deploy]`——build 阶段的所有 job 完成后才进入 test 阶段。artifact 是 job 间传递文件的关键机制——compile 上传 `target/classes/`——test 自动下载。

3. <strong>cache 加速构建——artifacts 传递产物——needs 打破顺序</strong>：cache 缓存 `.m2/repository`——避免每次重新下载 Maven 依赖。artifacts 传递 jar 包/测试报告——同一个 Pipeline 内可用。needs 让部署 job 不等其他 test job——提到最前面执行。

4. <strong>预定义变量 + rules 条件控制——按分支/文件变化/事件触发</strong>：`$CI_COMMIT_BRANCH` 区分 main 和 feature——`rules: if/changes/when` 精确控制哪些情况执行——MR 才跑测试——main 才打包——tag 才部署。

> 📖 <strong>下一步阅读</strong>：Pipeline 能跑了——但只是编译和测试。真正的 CI/CD 要构建 Docker 镜像、推送到 Harbor 镜像仓库、代码质量扫描（SonarQube）——以及多模块微服务项目怎么处理？继续阅读 [<strong>流水线实战——编译到镜像推送</strong>]({{< relref "GitlabCicdPipeline.md" >}})。
