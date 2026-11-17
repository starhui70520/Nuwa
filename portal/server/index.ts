import crypto from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import cors from 'cors';
import dotenv from 'dotenv';
import express, { type NextFunction, type Request, type Response } from 'express';
import multer from 'multer';
import { StorageService } from './storage.js';
import type { IosStatus, Platform, ReleaseItem } from './types.js';

dotenv.config();

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT || 3100);
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || 'rankchord-admin';
const TOKEN_SECRET = crypto.createHash('sha256').update(`nuwa-portal:${ADMIN_PASSWORD}`).digest('hex');

const storage = new StorageService();
const uploadDir = path.join(os.tmpdir(), 'nuwa-portal-uploads');
fs.mkdirSync(uploadDir, { recursive: true });

const upload = multer({
  dest: uploadDir,
  limits: {
    fileSize: 500 * 1024 * 1024 // 500 MB
  }
});

function createAdminToken(): string {
  const issuedAt = Date.now().toString();
  const sig = crypto.createHmac('sha256', TOKEN_SECRET).update(issuedAt).digest('hex');
  return `${issuedAt}.${sig}`;
}

function verifyAdminToken(token: string): boolean {
  const parts = token.split('.');
  if (parts.length !== 2) return false;
  const [issuedAt, sig] = parts;
  if (!issuedAt || !sig) return false;
  const expected = crypto.createHmac('sha256', TOKEN_SECRET).update(issuedAt).digest('hex');
  if (sig.length !== expected.length) return false;
  if (!crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(expected))) return false;
  const ageMs = Date.now() - Number(issuedAt);
  return Number.isFinite(ageMs) && ageMs >= 0 && ageMs < 7 * 24 * 60 * 60 * 1000;
}

function requireAdmin(req: Request, res: Response, next: NextFunction): void {
  const authHeader = req.headers.authorization || '';
  const token = authHeader.startsWith('Bearer ') ? authHeader.slice(7).trim() : '';
  if (!token || !verifyAdminToken(token)) {
    res.status(401).json({ error: '未授权或登录已过期，请重新登录管理后台。' });
    return;
  }
  next();
}

async function computeSha256(filePath: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(filePath);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolve(hash.digest('hex')));
    stream.on('error', reject);
  });
}

function sanitizeFileName(name: string): string {
  return name.replace(/[^a-zA-Z0-9._-]/g, '_');
}

function getLatestByPlatform(releases: ReleaseItem[]): Record<Platform, ReleaseItem | null> {
  const published = releases.filter((r) => r.published);
  const pick = (platform: Platform): ReleaseItem | null => {
    const list = published.filter((r) => r.platform === platform);
    if (list.length === 0) return null;
    const explicit = list.find((r) => r.isLatest);
    if (explicit) return explicit;
    return [...list].sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime())[0] ?? null;
  };
  return {
    android: pick('android'),
    harmony: pick('harmony')
  };
}

async function main() {
  await storage.init();

  const app = express();
  app.use(cors());
  app.use(express.json());

  app.get('/api/health', (_req, res) => {
    res.json({
      ok: true,
      storage: storage.getInfo(),
      timestamp: new Date().toISOString()
    });
  });

  app.get('/api/releases', async (_req, res) => {
    const manifest = await storage.readManifest();
    const published = manifest.releases
      .filter((r) => r.published)
      .sort((a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime());

    res.json({
      latest: getLatestByPlatform(published),
      releases: published,
      ios: manifest.ios,
      storageDriver: storage.getInfo().driver
    });
  });

  app.get('/api/releases/:id/download', async (req, res) => {
    const manifest = await storage.readManifest();
    const item = manifest.releases.find((r) => r.id === req.params.id && r.published);
    if (!item) {
      res.status(404).json({ error: '版本不存在或已下线' });
      return;
    }

    item.downloads += 1;
    await storage.writeManifest(manifest);

    const url = await storage.getDownloadUrl(item.objectKey, item.fileName);
    if (req.query.mode === 'json') {
      res.json({ url, fileName: item.fileName });
      return;
    }
    res.redirect(302, url);
  });

  app.get('/api/local-files/:objectKey', (req, res) => {
    if (storage.getInfo().driver !== 'local') {
      res.status(404).end();
      return;
    }
    try {
      const objectKey = decodeURIComponent(String(req.params.objectKey));
      const filePath = storage.resolveLocalFilePath(objectKey);
      if (!fs.existsSync(filePath)) {
        res.status(404).json({ error: '文件不存在' });
        return;
      }
      const downloadName = typeof req.query.filename === 'string' ? req.query.filename : path.basename(filePath);
      res.download(filePath, downloadName);
    } catch {
      res.status(400).json({ error: '非法文件路径' });
    }
  });

  app.post('/api/admin/login', (req, res) => {
    const password = typeof req.body?.password === 'string' ? req.body.password : '';
    if (password !== ADMIN_PASSWORD) {
      res.status(401).json({ error: '管理密码错误' });
      return;
    }
    res.json({ token: createAdminToken() });
  });

  app.get('/api/admin/releases', requireAdmin, async (_req, res) => {
    const manifest = await storage.readManifest();
    const sorted = [...manifest.releases].sort(
      (a, b) => new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime()
    );
    res.json({
      releases: sorted,
      ios: manifest.ios,
      storage: storage.getInfo()
    });
  });

  app.post('/api/admin/releases', requireAdmin, upload.single('file'), async (req, res) => {
    const tempFile = req.file;
    if (!tempFile) {
      res.status(400).json({ error: '请上传安装包文件' });
      return;
    }

    try {
      const platform = req.body?.platform as Platform;
      const version = String(req.body?.version || '').trim();
      const versionCode = Number(req.body?.versionCode || 1);
      const changelog = String(req.body?.changelog || '').trim();
      const isLatest = req.body?.isLatest === 'true' || req.body?.isLatest === true;
      const published = req.body?.published !== 'false';

      if (platform !== 'android' && platform !== 'harmony') {
        res.status(400).json({ error: '不支持的平台类型' });
        return;
      }
      if (!version) {
        res.status(400).json({ error: '请填写版本号，例如 0.1.2' });
        return;
      }

      const originalName = Buffer.from(tempFile.originalname, 'latin1').toString('utf8');
      const safeName = sanitizeFileName(originalName || `nuwa-${platform}-${version}`);
      const objectKey = `releases/${platform}/${version}/${Date.now()}-${safeName}`;
      const sha256 = await computeSha256(tempFile.path);
      const contentType = tempFile.mimetype || 'application/octet-stream';

      await storage.uploadPackage(objectKey, tempFile.path, contentType);

      const manifest = await storage.readManifest();
      if (isLatest) {
        for (const rel of manifest.releases) {
          if (rel.platform === platform) {
            rel.isLatest = false;
          }
        }
      }

      const newRelease: ReleaseItem = {
        id: crypto.randomUUID(),
        platform,
        version,
        versionCode: Number.isFinite(versionCode) ? versionCode : 1,
        fileName: safeName,
        objectKey,
        fileSize: tempFile.size,
        sha256,
        changelog: changelog || `Nuwa ${version} 正式发布。`,
        isLatest,
        published,
        downloads: 0,
        createdAt: new Date().toISOString()
      };

      manifest.releases.unshift(newRelease);
      await storage.writeManifest(manifest);

      res.status(201).json({ release: newRelease });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      res.status(500).json({ error: `发布失败: ${message}` });
    } finally {
      await fsp.unlink(tempFile.path).catch(() => {});
    }
  });

  app.patch('/api/admin/releases/:id', requireAdmin, async (req, res) => {
    const manifest = await storage.readManifest();
    const target = manifest.releases.find((r) => r.id === req.params.id);
    if (!target) {
      res.status(404).json({ error: '版本不存在' });
      return;
    }

    if (typeof req.body?.published === 'boolean') {
      target.published = req.body.published;
    }
    if (typeof req.body?.changelog === 'string') {
      target.changelog = req.body.changelog;
    }
    if (typeof req.body?.version === 'string' && req.body.version.trim()) {
      target.version = req.body.version.trim();
    }
    if (typeof req.body?.versionCode === 'number') {
      target.versionCode = req.body.versionCode;
    }
    if (req.body?.isLatest === true) {
      for (const rel of manifest.releases) {
        if (rel.platform === target.platform) {
          rel.isLatest = rel.id === target.id;
        }
      }
    }

    await storage.writeManifest(manifest);
    res.json({ release: target });
  });

  app.delete('/api/admin/releases/:id', requireAdmin, async (req, res) => {
    const manifest = await storage.readManifest();
    const index = manifest.releases.findIndex((r) => r.id === req.params.id);
    if (index === -1) {
      res.status(404).json({ error: '版本不存在' });
      return;
    }

    const [removed] = manifest.releases.splice(index, 1);
    await storage.deletePackage(removed.objectKey).catch((err) => {
      console.warn('[storage] failed to remove object:', err);
    });
    await storage.writeManifest(manifest);
    res.json({ ok: true });
  });

  app.put('/api/admin/ios', requireAdmin, async (req, res) => {
    const status = req.body?.status as IosStatus;
    const url = typeof req.body?.url === 'string' ? req.body.url.trim() : '';
    const note = typeof req.body?.note === 'string' ? req.body.note.trim() : '';

    if (status !== 'coming_soon' && status !== 'testflight' && status !== 'appstore') {
      res.status(400).json({ error: '无效的 iOS 状态' });
      return;
    }

    const manifest = await storage.readManifest();
    manifest.ios = {
      status,
      url,
      note: note || manifest.ios.note,
      updatedAt: new Date().toISOString()
    };
    await storage.writeManifest(manifest);
    res.json({ ios: manifest.ios });
  });

  if (process.env.NODE_ENV === 'production') {
    const clientDir = path.resolve(__dirname, '../client');
    app.use(express.static(clientDir));
    app.get('*', (_req, res) => {
      res.sendFile(path.join(clientDir, 'index.html'));
    });
  }

  app.listen(PORT, () => {
    console.log(`[nuwa-portal] Server running on http://localhost:${PORT}`);
  });
}

main().catch((err) => {
  console.error('[nuwa-portal] Fatal startup error:', err);
  process.exit(1);
});
