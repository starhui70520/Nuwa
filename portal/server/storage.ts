import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as Minio from 'minio';
import type { PortalManifest, StorageInfo } from './types.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DATA_DIR = path.resolve(__dirname, '../data');
const LOCAL_FILES_DIR = path.join(DATA_DIR, 'files');
const LOCAL_MANIFEST_PATH = path.join(DATA_DIR, 'releases.json');
const MINIO_MANIFEST_KEY = 'metadata/releases.json';

const DEFAULT_MANIFEST: PortalManifest = {
  releases: [],
  ios: {
    status: 'coming_soon',
    url: '',
    note: 'iOS 客户端正在适配中，即将登陆 TestFlight 与 App Store。',
    updatedAt: new Date().toISOString()
  }
};

export class StorageService {
  private client: Minio.Client | null = null;
  private driver: 'minio' | 'local' = 'local';
  private minioConfigured = false;
  private minioConnected = false;
  private initError: string | undefined;
  private bucket = process.env.MINIO_BUCKET || 'nuwa-releases';
  private endpoint = process.env.MINIO_ENDPOINT || '';
  private port = Number(process.env.MINIO_PORT || 9000);
  private useSSL = process.env.MINIO_USE_SSL === 'true';
  private publicUrl = (process.env.MINIO_PUBLIC_URL || '').replace(/\/+$/, '');
  private presignExpiry = Number(process.env.MINIO_PRESIGN_EXPIRY || 3600);

  async init(): Promise<void> {
    await fsp.mkdir(LOCAL_FILES_DIR, { recursive: true });

    const requestedDriver = (process.env.STORAGE_DRIVER || 'minio').toLowerCase();
    const accessKey = process.env.MINIO_ACCESS_KEY || '';
    const secretKey = process.env.MINIO_SECRET_KEY || '';

    if (requestedDriver === 'minio' && this.endpoint && accessKey && secretKey) {
      this.minioConfigured = true;
      try {
        const client = new Minio.Client({
          endPoint: this.endpoint,
          port: this.port,
          useSSL: this.useSSL,
          accessKey,
          secretKey
        });

        const exists = await client.bucketExists(this.bucket);
        if (!exists) {
          await client.makeBucket(this.bucket, 'us-east-1');
        }

        this.client = client;
        this.driver = 'minio';
        this.minioConnected = true;
        this.initError = undefined;
        console.log(`[storage] MinIO connected (${this.endpoint}:${this.port}, bucket=${this.bucket})`);
        return;
      } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        this.initError = message;
        this.minioConnected = false;
        this.driver = 'local';
        console.warn(`[storage] MinIO unavailable (${message}), falling back to local storage at ${DATA_DIR}`);
        return;
      }
    }

    this.driver = 'local';
    console.log(`[storage] Using local storage at ${DATA_DIR}`);
  }

  getInfo(): StorageInfo {
    return {
      driver: this.driver,
      minioConfigured: this.minioConfigured,
      minioConnected: this.minioConnected,
      endpoint: this.endpoint ? `${this.useSSL ? 'https' : 'http'}://${this.endpoint}:${this.port}` : undefined,
      bucket: this.minioConfigured ? this.bucket : undefined,
      error: this.initError
    };
  }

  async readManifest(): Promise<PortalManifest> {
    if (this.driver === 'minio' && this.client) {
      try {
        const stream = await this.client.getObject(this.bucket, MINIO_MANIFEST_KEY);
        const chunks: Buffer[] = [];
        for await (const chunk of stream) {
          chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
        }
        const parsed = JSON.parse(Buffer.concat(chunks).toString('utf-8')) as Partial<PortalManifest>;
        return {
          releases: Array.isArray(parsed.releases) ? parsed.releases : [],
          ios: parsed.ios ?? DEFAULT_MANIFEST.ios
        };
      } catch {
        // Manifest does not exist yet in MinIO
        return structuredClone(DEFAULT_MANIFEST);
      }
    }

    try {
      const raw = await fsp.readFile(LOCAL_MANIFEST_PATH, 'utf-8');
      const parsed = JSON.parse(raw) as Partial<PortalManifest>;
      return {
        releases: Array.isArray(parsed.releases) ? parsed.releases : [],
        ios: parsed.ios ?? DEFAULT_MANIFEST.ios
      };
    } catch {
      return structuredClone(DEFAULT_MANIFEST);
    }
  }

  async writeManifest(manifest: PortalManifest): Promise<void> {
    const payload = JSON.stringify(manifest, null, 2);
    if (this.driver === 'minio' && this.client) {
      const buf = Buffer.from(payload, 'utf-8');
      await this.client.putObject(this.bucket, MINIO_MANIFEST_KEY, buf, buf.length, {
        'Content-Type': 'application/json; charset=utf-8'
      });
      return;
    }

    await fsp.mkdir(DATA_DIR, { recursive: true });
    await fsp.writeFile(LOCAL_MANIFEST_PATH, payload, 'utf-8');
  }

  async uploadPackage(objectKey: string, localTempPath: string, contentType: string): Promise<void> {
    if (this.driver === 'minio' && this.client) {
      await this.client.fPutObject(this.bucket, objectKey, localTempPath, {
        'Content-Type': contentType
      });
      return;
    }

    const destPath = this.resolveLocalFilePath(objectKey);
    await fsp.mkdir(path.dirname(destPath), { recursive: true });
    await fsp.copyFile(localTempPath, destPath);
  }

  async deletePackage(objectKey: string): Promise<void> {
    if (this.driver === 'minio' && this.client) {
      await this.client.removeObject(this.bucket, objectKey);
      return;
    }

    const destPath = this.resolveLocalFilePath(objectKey);
    if (fs.existsSync(destPath)) {
      await fsp.unlink(destPath);
    }
  }

  async getDownloadUrl(objectKey: string, fileName: string): Promise<string> {
    if (this.driver === 'minio' && this.client) {
      if (this.publicUrl) {
        return `${this.publicUrl}/${this.bucket}/${objectKey}`;
      }
      return await this.client.presignedGetObject(this.bucket, objectKey, this.presignExpiry, {
        'response-content-disposition': `attachment; filename="${encodeURIComponent(fileName)}"`
      });
    }

    return `/api/local-files/${encodeURIComponent(objectKey)}?filename=${encodeURIComponent(fileName)}`;
  }

  resolveLocalFilePath(objectKey: string): string {
    const normalized = path.normalize(objectKey).replace(/^(\.\.(\/|\\|$))+/, '');
    const full = path.resolve(LOCAL_FILES_DIR, normalized);
    if (!full.startsWith(LOCAL_FILES_DIR)) {
      throw new Error('Invalid object key');
    }
    return full;
  }
}
