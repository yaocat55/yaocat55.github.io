# CatBlog — 基于 Hugo + PaperMod 的深度定制博客

> 一只会写代码的猫的博客 🐱

**在线地址：** [https://yaocat55.github.io/](https://yaocat55.github.io/)

---


### 首页（Profile Mode）

![首页截图](./homepage.png)

### 阅读页（浅色模式）

![浅色模式阅读页截图](./read.png)


### 阅读页（深色模式）

![深色模式阅读页截图](./read_dark.png)

---

## 基础信息

| 项目 | 说明 |
|------|------|
| **框架** | [Hugo](https://gohugo.io/) |
| **主题** | [PaperMod](https://github.com/adityatelange/hugo-PaperMod)（Git Submodule） |
| **部署** | GitHub Pages（`yaocat55.github.io`） |
| **语言** | 中文（zh） |
| **内容** | 技术博客，涵盖后端、数据库、系统设计 |

---

## 修改总览

在 PaperMod 默认主题基础上，从 **布局、样式、功能、交互** 四个维度做了以下定制：

| 维度 | 修改项 | 涉及文件 |
|------|--------|----------|
| 布局 | 文章页 Mermaid 支持 / 自定义 baseof | `layouts/_default/single.html`, `layouts/_default/baseof.html` |
| 布局 | 自定义首页 Profile 模板 | `layouts/partials/index_profile.html` |
| 布局 | B 站视频短代码（封面预览/分P/弹幕/BV复制） | `layouts/shortcodes/bilibili.html` |
| 布局 | Mermaid 代码块渲染钩子 | `layouts/_default/_markup/render-codeblock-mermaid.html` |
| 样式 | 完整主题配色 + 智能代码高亮 + 毛玻璃全站联动 + 背景图像层 | `assets/css/extended/custom.css` |
| 布局 | 列表/归档/搜索/标签/分类页面模板覆盖 | `layouts/_default/list.html` |
| 布局 | 导航栏模板覆盖（全透明） | `layouts/partials/header.html` |
| 资源 | 深浅模式背景图 | `static/images/bg-light.webp`, `static/images/bg-dark.webp` |
| 功能 | Mermaid（白底适配）/ KaTeX / 图片缩放 / D2 SVG 灯箱 / 字体 | `layouts/partials/extend_head.html` |
| 功能 | Live2D 看板娘 / 猫爪特效 / Cat Radio | `layouts/partials/extend_footer.html`, `layouts/partials/music-player.html` |
| 工具 | D2 图表编译脚本 + Markdown AST 校验 | `scripts/render-d2.mjs`, `scripts/validate-markdown.mjs` |

---

## 一、布局层修改

### 1.1 文章单页模板 (`layouts/_default/single.html`)

覆盖 PaperMod 默认 `single.html`，新增 Mermaid 图表支持：

- 检测页面是否包含 Mermaid 图表（通过 `.Page.Store.Get "hasMermaid"`）
- 若包含则自动加载 Mermaid ESM 模块，并跟随 PaperMod 主题自动切换亮/暗配色
- 保留 PaperMod 原有的面包屑、元信息、封面、目录、标签、分享等全部功能

### 1.2 B 站视频短代码 (`layouts/shortcodes/bilibili.html`)

自定义 Hugo Shortcode，在文章中嵌入 B 站视频：

```markdown
{{</* bilibili bvid="BV1xx411c7mD" */>}}
```

- 支持参数：`bvid`（必填）、`page`（分 P）、`danmaku`（弹幕开关）、`theme`、`autoplay`
- 封面预览模式：点击封面后才加载 iframe 播放器，节省流量
- 通过 B 站 API 自动获取视频标题和分 P 列表
- 分 P 下拉菜单，切换分 P 无需刷新页面
- 弹幕开关实时控制
- 一键复制 BV 号按钮
- 响应式 16:9 容器，自适应宽度

### 1.3 Mermaid 渲染钩子 (`layouts/_default/_markup/render-codeblock-mermaid.html`)

将 ` ```mermaid ` 代码块渲染为 `<pre class="mermaid">`，并通过 `.Page.Store` 标记页面，触发 single.html 中的 Mermaid 初始化脚本。

### 1.4 基础 HTML 骨架 (`layouts/_default/baseof.html`)

覆盖 PaperMod 默认 `baseof.html`：
- 在 `<body>` 底部注入 `extend_footer.html`（看板娘 + 猫爪特效）和 `music-player.html`（Cat Radio）
- 保留 PaperMod 原有的 header、main、footer 结构和主题切换逻辑

---

## 二、样式层修改 (`assets/css/extended/custom.css`)

共约 **1600 行**，覆盖 PaperMod 默认样式，分为约 20 个模块：

### 2.1 字体系统

- **正文字体：** Inter → system-ui 字体栈（含 PingFang SC / Microsoft YaHei / Noto Sans CJK SC 中文字体回退）
- **代码字体：** JetBrains Mono → Fira Code → Cascadia Code → SF Mono → Monaco
- 通过 fonts.loli.net 加载 Inter + JetBrains Mono（见 `extend_head.html`）

### 2.2 浅色主题 — 柔和护眼配色

| 角色 | 色值 | 说明 |
|------|------|------|
| 背景 | `#c8d0b4` | 柔绿底 |
| 卡片 | `#f0ecd8` | 米白 |
| 标题 | `#3a6b28` | 深草绿 |
| 正文 | `#1e2a16` | 深绿灰，保证阅读舒适 |
| 链接 | `#3a6b28` | 醒目草绿 |
| 代码块背景 | `#dce4cc` | 浅绿底 |
| body-bg | `#c0c8a8` | 比背景稍深 |

### 2.3 深色主题 — Material Design 3 暗色配色

| 角色 | 色值 | 说明 |
|------|------|------|
| 背景 | `#1c1e1c` | 深灰绿底 |
| 卡片 | `#2c2f2c` | 稍亮分层 |
| 标题 | `#ffc66d` / `#88c0d0` / `#b48ead` / `#a3be8c` | h1-h4 多彩标题 |
| 正文 | `#e0e3da` | 柔和高可读 |
| 链接 | `#c9b86a` | 金色链接 |
| 代码块背景 | `#252725` | 略亮于背景 |

### 2.4 智能代码高亮（按语言分 IDE 配色）

| 语言 | 浅色模式 | 深色模式 |
|------|----------|----------|
| Java / Kotlin / Go / Maven / XML | IDEA Light 配色 | IDEA Darcula 配色 |
| TypeScript / JavaScript / JSX / TSX | VS Code Light 配色 | VS Code Dark+ 配色 |
| Bash / Shell / Zsh | Catppuccin Mocha 配色（暗底） | Catppuccin Mocha 配色（暗底） |

每种语言覆盖了 Chroma 高亮的所有 token 类型（注释、关键字、字符串、数字、函数名、类名、操作符等）。

### 2.5 背景图像系统

- `body::before` 伪元素承载背景图，与 body 处于同一层叠上下文
- 浅色模式：`bg-light.webp`，opacity 0.30
- 深色模式：`bg-dark.webp`，opacity 0.30
- 主题切换时 0.6s 平滑过渡
- body 保持 MD3 纯色底色，`body::before` 叠加纹理

### 2.6 毛玻璃联动体系

利用 `backdrop-filter: blur()` 穿透透明容器捕获 `body::before` 背景图层：

| 组件 | 透明度 | blur | 说明 |
|------|--------|------|------|
| `.header` 导航栏 | 30% + blur | 12px | 半透明毛玻璃，无边框 |
| `.post-entry` / `.first-entry` 列表卡片 | 50% | 20px | hover 50% 加深阴影 |
| `.widget-box` 首页卡片 | 55% | 20px | 天气/快讯/GitHub |
| `.archive-entry` 归档条目 | 全透明 | — | hover 50% 浮出 |
| `.searchbox` 搜索框 | 全透明 | — | 无边框 |
| `.highlight` 代码块 | 50% | — | 统一半透明，含语言特定配色 |
| `.toc` 目录 | 50% | 8px | 半透明毛玻璃 |
| `blockquote` 引用块 | 50% | 8px | 半透明毛玻璃 |
| 移动端 (≤768px) | 纯色(卡片) | 关闭 | 省电防卡顿；main 透明化，背景图无缝贯穿 |

### 2.7 深浅模式字体渲染统一

- 浅色模式：`-webkit-font-smoothing: antialiased`（文字显细）
- 深色模式：`-webkit-font-smoothing: auto`（亚像素渲染，避免暗底亮字变宽导致换行）

### 2.8 其他样式模块

| 模块 | 主要修改 |
|------|----------|
| 文章卡片 | 圆角 16px、阴影、hover 上浮 2px（单篇文章保持纯色保护阅读） |
| 标题系统 | h1-h4 独立配色（浅色/深色各不同）、h2 底部边框、h3 hover 平移 |
| 代码块 | 圆角 12px、自定义滚动条、hover 阴影、按语言 IDE 主题适配 |
| 行内代码 | 浅色绿底/深色半透明白底 |
| 表格 | 斑马纹、hover 高亮行、移动端横向滚动 |
| 引用块 | 半透明毛玻璃、左侧彩色条、hover 上浮 |
| 列表 | marker 主题色、hover 平移、嵌套缩进 |
| 图片 | 居中圆角阴影、hover 放大 1.01x |
| 目录 (TOC) | 三断点响应式（大屏固定侧边栏 / 中屏 / 移动端折叠）、半透明毛玻璃 |
| 标签云 | 胶囊形状、hover 上浮变色 |
| 搜索框 | 全透明无边框、圆角 16px |
| 代码复制按钮 | hover 显示、主题适配 |
| 个人头像 | 圆形 150px、hover 放大 1.03x |
| 脚注 | 渐变色顶部分隔线、代码字体编号 |
| 打印样式 | 隐藏装饰、黑白输出 |
| 无障碍 | `prefers-reduced-motion` 支持 |

---

## 三、功能增强 (`layouts/partials/extend_head.html`)

（还包含大屏 TOC 固定侧边栏定位、图片缩放容器等 CSS 样式）

### 3.1 Mermaid 图表

- CDN 加载 Mermaid（jsdelivr）
- **统一白色背景**——`.mermaid` 和 `.lightbox-content` 固定 `#ffffff`，深浅模式通用
- `theme: 'default'`，不再维护双主题 `themeVariables`
- 自动将 Hugo 生成的 `.language-mermaid` 代码块转换为 Mermaid 能识别的 `.mermaid` 容器

### 3.2 图片 & Mermaid & D2 SVG 灯箱缩放

- 点击文章内图片 / Mermaid 图表 / D2 SVG 展开全屏灯箱
- **inline SVG（Mermaid）**：使用 `viewBox` 计算初始缩放，改 `width`/`height` 实现缩放
- **`<img>` 元素（D2 SVG）**：使用 `naturalWidth`/`naturalHeight` 计算初始缩放，容器自适应撑开
- 滚轮缩放 + 移动端双指捏合，缩放范围 0.3x ~ 6.0x
- 按 `Esc` 或点击灯箱空白区域关闭

### 3.3 KaTeX 数学公式

- CDN 加载 KaTeX 0.16.11 + auto-render
- 支持 `$...$`（行内）和 `$$...$$`（块级）
- 自动跳过 `<pre>`、`<code>`、代码高亮块等——避免与代码块中的 `$` 冲突
- 通过一次性初始化守卫防止重复渲染

### 3.4 字体加载

- fonts.loli.net 预连接 + 异步加载 Inter 和 JetBrains Mono
- 通过 `font-display: swap` 确保文字在字体加载期间可见

---

## 四、交互增强 (`layouts/partials/extend_footer.html` + `music-player.html`)

### 4.1 Live2D 看板娘

- 使用 [live2d-widget-v3](https://github.com/letere-gzj/live2d-widget-v3) 库
- 自定义模型资源（CDN 托管）
- 仅在桌面端（≥768px）加载，移动端自动跳过
- 强制固定在右下角
- 支持拖拽、切换模型、切换皮肤、截图等工具
- 提示框主题适配

### 4.2 猫爪点击特效 🐾

- 点击页面任意位置生成猫爪 emoji 动画
- 浅色模式：绿色爪印 `#2f7d32`
- 深色模式：荧光绿爪印带发光效果 `#9cffb5`
- 随机旋转角度，向上飘散后消失（1.8s）

### 4.3 Cat Radio 音乐播放器

- 固定在右下角（看板娘左侧）的悬浮音乐播放器（独立 `music-player.html` partial）
- 内置 8 首背景音乐（`/music/` 目录下 mp3 文件）
- 左键点击：播放/暂停
- 右键点击：顺序切歌（下一首）
- 自动播放下一首
- 3 秒定时保存播放进度到 localStorage，支持页面切换后断点续播
- 深色/浅色模式适配
- 移动端自动隐藏歌名标签
- 页面可见性变化时自动恢复播放

---

## 五、配置文件关键设置 (`hugo.toml`)

| 设置 | 值 | 说明 |
|------|-----|------|
| `theme` | `PaperMod` | 通过 Git Submodule 引入 |
| `pygmentsUseClasses` | `true` | 配合自定义 CSS 按语言配色 |
| `markup.goldmark.renderer.unsafe` | `true` | 允许 Markdown 中使用原始 HTML |
| `markup.tableOfContents.startLevel` | `2` | 目录从 h2 开始 |
| `markup.tableOfContents.endLevel` | `3` | 目录到 h3 结束 |
| `params.profileMode.enabled` | `true` | 首页使用个人档模式 |
| `params.defaultTheme` | `auto` | 跟随系统自动切换亮暗 |
| `outputs.home` | `["HTML","RSS","JSON"]` | 支持搜索 JSON 索引 |

### Profile Mode 配置

首页展示猫猫 GIF、标题、副标题 + 5 个导航按钮（文章、标签、分类、搜索、GitHub）。

### 社交图标

GitHub → 邮件 → RSS 三个社交图标。

---

## 目录结构（自定义部分）

```
yaocat55.github.io/
├── assets/
│   └── css/
│       └── extended/
│           └── custom.css          # 核心：深度定制样式 + 毛玻璃 + 背景图
├── content/
│   ├── diagrams/                   # D2 图表源文件（.gitignore）
│   └── posts/                      # Markdown 博客文章
├── layouts/
│   ├── _default/
│   │   ├── baseof.html             # 基础 HTML 骨架
│   │   ├── list.html               # 列表/标签/分类页（PaperMod 覆盖）
│   │   ├── single.html             # 文章页 + Mermaid 支持
│   │   └── _markup/
│   │       └── render-codeblock-mermaid.html  # Mermaid 渲染钩子
│   ├── partials/
│   │   ├── extend_head.html        # Mermaid/KaTeX/字体/灯箱缩放/D2 SVG
│   │   ├── extend_footer.html      # Live2D/猫爪特效
│   │   ├── header.html             # 导航栏（PaperMod 覆盖，全透明）
│   │   ├── index_profile.html      # 首页 Profile 模板
│   │   └── music-player.html       # Cat Radio 音乐播放器
│   └── shortcodes/
│       └── bilibili.html           # B 站视频短代码
├── scripts/
│   ├── check-format.sh             # Markdown 格式检查
│   ├── validate-mermaid.mjs        # Mermaid 语法校验
│   ├── validate-markdown.mjs       # Markdown AST 校验（markdown-it）
│   ├── render-d2.mjs               # D2 .d2 → SVG 编译（+ SVGO 压缩）
│   └── d2.exe                      # D2 CLI 二进制
├── static/
│   ├── images/
│   │   ├── bg-light.webp           # 浅色模式背景图
│   │   ├── bg-dark.webp            # 深色模式背景图
│   │   └── d2/                     # D2 编译产出的 SVG 图表（提交 git）
│   └── music/                      # Cat Radio 音乐文件
├── hugo.toml                       # 站点配置
└── themes/
    └── PaperMod/                   # 上游主题（Git Submodule）
```

---

## 与上游 PaperMod 的差异原则

- **不直接修改 `themes/PaperMod/` 内的任何文件**，所有定制通过 Hugo 的模板覆盖机制实现
- `layouts/` 下的文件会覆盖主题同名模板
- `assets/css/extended/custom.css` 通过 PaperMod 的扩展 CSS 机制自动加载
- `layouts/partials/extend_head.html` 和 `extend_footer.html` 是 PaperMod 预留的注入点
