export type Platform = 'android' | 'harmony';

export type IosStatus = 'coming_soon' | 'testflight' | 'appstore';

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

export interface StorageInfo {
  driver: 'minio' | 'local';
  minioConfigured: boolean;
  minioConnected: boolean;
  endpoint?: string;
  bucket?: string;
  error?: string;
}

export interface PublicReleasesResponse {
  latest: Record<Platform, ReleaseItem | null>;
  releases: ReleaseItem[];
  ios: IosConfig;
  storageDriver: 'minio' | 'local';
}

export interface AdminReleasesResponse {
  releases: ReleaseItem[];
  ios: IosConfig;
  storage: StorageInfo;
}
