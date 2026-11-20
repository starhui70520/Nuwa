import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo, statfs } from '@kit.CoreFileKit';
import { NativeBackupZipInput, NativeBackupZipStreamEntry } from './NativeBackupZip';
import { ensureNativeDirectory } from './NativeFileSystem';

const IO_CHUNK = 256 * 1024;
const IMAGE_DIRECTORY = 'nuwa-history-images';
const PRUNE_AFTER_MS = 24 * 60 * 60 * 1_000;
const FILE_SYSTEM_FULL = 13900025;

interface RetainedImage {
  blobId?: string;
}

interface RetainedArchive {
  images?: RetainedImage[];
  source?: RetainedImage;
}

class NativeBackupSpaceError extends Error {
  constructor() {
    super('设备存储空间不足，请清理空间后重试。');
  }
}

export function isBackupSpaceError(error: Error): boolean {
  return error instanceof NativeBackupSpaceError || (error as BusinessError)?.code === FILE_SYSTEM_FULL;
}

export async function ensureBackupSpace(directory: string, requiredBytes: number): Promise<void> {
  let available = -1;
  try {
    available = await statfs.getFreeSize(directory);
  } catch {
    // If space cannot be queried, the filesystem still enforces its own write limit.
  }
  if (available >= 0 && requiredBytes > available) throw new NativeBackupSpaceError();
}

function validBlobId(id: string): boolean {
  return /^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/i.test(id);
}

function imageDirectory(context: common.UIAbilityContext): string {
  return context.filesDir + '/' + IMAGE_DIRECTORY;
}

export function backupImagePath(context: common.UIAbilityContext, id: string): string {
  if (!validBlobId(id)) {
    throw new Error('备份中的图片原件标识无效。');
  }
  return imageDirectory(context) + '/' + id;
}

async function readExactly(fd: number, offset: number, length: number): Promise<Uint8Array> {
  if (length === 0) {
    return new Uint8Array(0);
  }
  fileIo.lseek(fd, offset);
  const output = new Uint8Array(length);
  let copied = 0;
  while (copied < length) {
    const chunk = new ArrayBuffer(Math.min(IO_CHUNK, length - copied));
    const count = await fileIo.read(fd, chunk);
    if (count <= 0) {
      throw new Error('备份数据读取未完成。');
    }
    output.set(new Uint8Array(chunk, 0, count), copied);
    copied += count;
  }
  return output;
}

export async function withBackupInput<T>(uri: string, action: (input: NativeBackupZipInput) => Promise<T>): Promise<T> {
  const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
  try {
    const stat = await fileIo.stat(file.fd);
    if (!stat.isFile() || !Number.isSafeInteger(stat.size) || stat.size < 0) {
      throw new Error('无法读取此备份文件。');
    }
    return await action({
      size: stat.size,
      read: (offset: number, length: number): Promise<Uint8Array> => readExactly(file.fd, offset, length),
    });
  } finally {
    await fileIo.close(file);
  }
}

async function writeBytes(fd: number, bytes: Uint8Array): Promise<void> {
  let offset = 0;
  while (offset < bytes.length) {
    const end = Math.min(offset + IO_CHUNK, bytes.length);
    const start = bytes.byteOffset + offset;
    const content = bytes.buffer.slice(start, start + end - offset) as ArrayBuffer;
    const written = await fileIo.write(fd, content);
    if (written <= 0) {
      throw new Error('备份数据写入未完成。');
    }
    offset += written;
  }
}

export async function writeBackupFile(uri: string, create: boolean,
  action: (write: (chunk: Uint8Array) => Promise<void>) => Promise<void>): Promise<void> {
  const flags = fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC | (create ? fileIo.OpenMode.CREATE : 0);
  const file = await fileIo.open(uri, flags);
  try {
    await action((chunk: Uint8Array): Promise<void> => writeBytes(file.fd, chunk));
    await fileIo.fsync(file.fd);
  } finally {
    await fileIo.close(file);
  }
}

export async function copyBackupFile(from: string, to: string): Promise<void> {
  await withBackupInput<void>(from, async (input: NativeBackupZipInput): Promise<void> => {
    await writeBackupFile(to, false, async (write: (chunk: Uint8Array) => Promise<void>): Promise<void> => {
      for (let offset = 0; offset < input.size; offset += IO_CHUNK) {
        await write(await input.read(offset, Math.min(IO_CHUNK, input.size - offset)));
      }
    });
  });
}

export async function stageBackupImage(context: common.UIAbilityContext,
  entry: NativeBackupZipStreamEntry): Promise<string> {
  return stageBackupBlob(context, entry.size, (write: (chunk: Uint8Array) => Promise<void>): Promise<void> =>
    entry.consume(write));
}

export async function stageBackupBlob(context: common.UIAbilityContext, size: number,
  action: (write: (chunk: Uint8Array) => Promise<void>) => Promise<void>): Promise<string> {
  await ensureBackupSpace(context.filesDir, size);
  const id = util.generateRandomUUID(true);
  await ensureNativeDirectory(imageDirectory(context));
  const path = backupImagePath(context, id);
  try {
    await writeBackupFile(path, true, action);
    return id;
  } catch (error) {
    await fileIo.unlink(path).catch(() => {});
    throw error as Error;
  }
}

export async function removeBackupImage(context: common.UIAbilityContext, id: string): Promise<void> {
  await fileIo.unlink(backupImagePath(context, id)).catch(() => {});
}

export function backupImageIds(archiveJson?: string): string[] {
  if (!archiveJson || !archiveJson.includes('"blobId":')) {
    return [];
  }
  let archive: RetainedArchive;
  try {
    archive = JSON.parse(archiveJson) as RetainedArchive;
  } catch {
    return [];
  }
  const ids: string[] = [];
  if (typeof archive.source?.blobId === 'string' && validBlobId(archive.source.blobId)) {
    ids.push(archive.source.blobId);
  }
  if (Array.isArray(archive.images)) {
    for (const image of archive.images) {
      if (typeof image?.blobId === 'string' && validBlobId(image.blobId)) {
        ids.push(image.blobId);
      }
    }
  }
  return ids;
}

export async function pruneBackupImages(context: common.UIAbilityContext, retained: Set<string>): Promise<void> {
  const paths = await fileIo.listFile(imageDirectory(context)).catch((): string[] => []);
  const cutoff = Date.now() - PRUNE_AFTER_MS;
  for (const id of paths) {
    if (!validBlobId(id) || retained.has(id)) {
      continue;
    }
    const stat = await fileIo.stat(backupImagePath(context, id)).catch((): fileIo.Stat | undefined => undefined);
    if (stat && stat.mtime * 1_000 < cutoff) {
      await removeBackupImage(context, id);
    }
  }
}
