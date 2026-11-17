export type Platform = 'android' | 'harmony';

export type IosStatus = 'coming_soon' | 'testflight' | 'appstore';
export type HarmonyStatus = 'coming_soon' | 'appgallery';

export interface ReleaseItem {
  id: string;
  platform: Platform;
  version: string;
  versionCode: number;
  fileName: string;
  objectKey: string;
  fileSize: number;
  sha256: string;
  changelog: string;
  isLatest: boolean;
  published: boolean;
  downloads: number;
  createdAt: string;
}

export interface IosConfig {
  status: IosStatus;
  url: string;
  note: string;
  updatedAt: string;
}

export interface HarmonyConfig {
  status: HarmonyStatus;
  url: string;
  note: string;
  updatedAt: string;
}

export interface ArticleItem {
  id: string;
  slug: string;
  title: string;
  summary: string;
  content: string;
  tags: string[];
  coverUrl: string;
  author: string;
  published: boolean;
  featured: boolean;
  publishedAt: string;
  updatedAt: string;
}

export interface PortalManifest {
  releases: ReleaseItem[];
  ios: IosConfig;
  harmony: HarmonyConfig;
  articles: ArticleItem[];
}

export interface StorageInfo {
  driver: 'minio' | 'local';
  minioConfigured: boolean;
  minioConnected: boolean;
  endpoint?: string;
  bucket?: string;
  error?: string;
}
