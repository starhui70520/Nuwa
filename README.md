# Nuwa

**Nuwa : Remake DeepSeek APP** — 基于 Web 与 Capacitor Android 的跨端 AI 聊天客户端及历史记录迁移工具。

## 目录结构

- [`chat-demo/`](./chat-demo)：Nuwa 核心客户端（React + Rspack + Capacitor Android），支持多服务商 API、引导配置、语音输入与朗读、原生端登录与历史会话导入导出。
- [`extension/`](./extension)：**Nuwa 历史记录迁移助手**（Chrome / Edge Manifest V3 扩展），自动监听导出的 `deepseek_data-*.zip` 并一键导入本地 Nuwa 客户端。

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

### 浏览器迁移扩展

1. 打开 Chrome / Edge 扩展管理页面（`chrome://extensions` 或 `edge://extensions`），开启**开发者模式**。
2. 点击**加载已解压的扩展程序**，选择仓库下的 `extension` 目录。

## 致谢与许可

- 仓库根目录遵循 [LICENSE](./LICENSE)（Apache-2.0）。
- `chat-demo/` 基于 [deepseek-ai/chat-demo](https://github.com/deepseek-ai/chat-demo)（MIT License，见 [`chat-demo/LICENSE`](./chat-demo/LICENSE)）改造开发。
