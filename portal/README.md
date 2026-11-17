# Nuwa 应用分发中心（RankChord）

基于 **React + Vite + Express + MinIO** 的全栈应用分发平台，用于发布 Nuwa（女娲）Android (`.apk`)、HarmonyOS (`.hap` / `.app`) 安装包，并支持 iOS 跳转配置（App Store / TestFlight / 敬请期待）。

## 核心特性

- **MinIO 对象存储**：安装包直接上传至 MinIO Bucket（`releases/<platform>/<version>/...`），版本元数据 `metadata/releases.json` 同样持久化在 MinIO 中（无额外数据库依赖），下载时自动生成 MinIO 预签名链接（或拼接自定义 `MINIO_PUBLIC_URL`）。
- **本地开发自动回退**：未启动 MinIO 时自动回退到 `data/` 本地存储，方便前端/交互预览。
- **多端自适应分发页 (`/`)**：自动识别访客系统（Android / HarmonyOS / iOS），高亮推荐安装包，支持扫码下载、SHA-256 一键复制、历史版本筛选与更新日志展示。
- **发布管理后台 (`/admin`)**：密码鉴权、带进度条的大文件上传、自动计算 SHA-256、版本上下架/设为最新/删除、iOS 跳转链接在线配置。

## 本地开发

```bash
cd portal
cp .env.example .env
pnpm install
pnpm dev
```

- 前端开发地址：`http://localhost:5173`
- 后端 API 地址：`http://localhost:3100`
- 管理后台地址：`http://localhost:5173/admin`（默认密码 `rankchord-admin`，可在 `.env` 中修改 `ADMIN_PASSWORD`）

## 生产构建与部署

### 方式一：Node.js 直接部署

```bash
cd portal
pnpm install
pnpm build
pnpm start
```

生产模式下后端单端口（默认 `3100`）同时托管静态前端与 `/api/*` 接口。

### 方式二：Docker Compose（自带 MinIO + Portal）

```bash
cd portal
docker compose up -d --build
```

- 分发站点：`http://localhost:3100`
- MinIO Console：`http://localhost:9001`
