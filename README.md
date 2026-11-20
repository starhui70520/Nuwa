# Nuwa

**Nuwa : Remake DeepSeek APP** — 基于 Web 与 Capacitor Android 的跨端 AI 聊天客户端及历史记录迁移工具。

## 目录结构

- [`chat-demo/`](./chat-demo)：Nuwa 核心客户端（React + Rspack + Capacitor Android），支持多服务商 API、引导配置、语音输入与朗读、原生端登录与历史会话导入导出。
- [`harmony/`](./harmony)：Nuwa HarmonyOS 鸿蒙原生客户端。
- [`extension/`](./extension)：**Nuwa 历史记录迁移助手**（Chrome / Edge Manifest V3 扩展），自动监听导出的 `deepseek_data-*.zip` 并一键导入本地 Nuwa 客户端。
- [`portal/`](./portal)：**Nuwa 应用分发中心**（React + Vite + Express + MinIO），用于发布 Android / HarmonyOS 安装包与配置 iOS 跳转。

## 快速开始

### Web 开发与构建

环境要求：Node.js 22.12+ 与 `pnpm`。

```bash
cd chat-demo
pnpm install
pnpm dev
```

构建静态产物：

```bash
cd chat-demo
pnpm build
```

### Android 构建（Capacitor）

```bash
cd chat-demo
pnpm build
npx cap sync android
npx cap open android
```

### HarmonyOS 原生构建

安装带原生工具链的 HarmonyOS CLI 26.0.0.821、Java 17、Node.js 22.12 或更新版本、`curl` 和 `tar`。初始化 HarmonyOS SDK 环境后运行以下命令。鸿蒙主界面使用原生 ArkUI，构建借助 `chat-demo` 的依赖生成 Mermaid、KaTeX、Prism 和 Markdown 渲染资源。英文听写模型和原生库在构建前按固定版本下载并校验，运行时可离线识别。

```bash
cd chat-demo
pnpm install --frozen-lockfile
node ../harmony/scripts/stage-mermaid.mjs
node ../harmony/scripts/stage-katex.mjs
node ../harmony/scripts/stage-prism.mjs
node ../harmony/scripts/stage-markdown.mjs
cd ../harmony
node scripts/prepare-offline-english.mjs
ohpm install --all
hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
```

### 浏览器迁移扩展

1. 打开 Chrome / Edge 扩展管理页面（`chrome://extensions` 或 `edge://extensions`），开启**开发者模式**。
2. 点击**加载已解压的扩展程序**，选择仓库下的 `extension` 目录。

## 致谢与许可

- 仓库根目录遵循 [LICENSE](./LICENSE)（Apache-2.0）。
- `chat-demo/` 基于 [deepseek-ai/chat-demo](https://github.com/deepseek-ai/chat-demo)（MIT License，见 [`chat-demo/LICENSE`](./chat-demo/LICENSE)）改造开发。
