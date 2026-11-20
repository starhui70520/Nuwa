import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { MAX_FILE_BACKUP_BYTES } from './NativeBackupZip';

const COMPLETED_MIGRATION_ZIP = 'nuwa-native-migration.zip';
const FILE_NOT_FOUND = 13900002;
const activeImports = new Set<string>();
export const NATIVE_MIGRATION_SIZE_ERROR = '导出包超出 ZIP32 格式容量，无法导入';

function completedPath(context: common.UIAbilityContext): string {
  return `${context.filesDir}/${COMPLETED_MIGRATION_ZIP}`;
}

export function nativeMigrationDownloadPath(context: common.UIAbilityContext): string {
  return `${completedPath(context)}.part`;
}

export function hasPendingNativeMigration(context: common.UIAbilityContext): boolean {
  try {
    return fileIo.statSync(completedPath(context)).isFile();
  } catch {
    return false;
  }
}

function unlinkIfPresent(path: string): void {
  try {
    fileIo.unlinkSync(path);
  } catch (error) {
    if ((error as BusinessError).code !== FILE_NOT_FOUND) {
      throw error as Error;
    }
  }
}

export function discardIncompleteNativeMigration(context: common.UIAbilityContext): void {
  unlinkIfPresent(nativeMigrationDownloadPath(context));
}

export function discardPendingNativeMigration(context: common.UIAbilityContext): void {
  const path = completedPath(context);
  if (activeImports.has(path)) {
    throw new Error('正在导入导出包，请稍候');
  }
  unlinkIfPresent(path);
}

export async function completeNativeMigrationDownload(context: common.UIAbilityContext,
  receivedBytes: number): Promise<void> {
  if (hasPendingNativeMigration(context)) {
    throw new Error('已有待导入的导出包，请先重试或放弃');
  }
  const part = nativeMigrationDownloadPath(context);
  const file = await fileIo.open(part, fileIo.OpenMode.READ_WRITE);
  try {
    const stat = await fileIo.stat(file.fd);
    if (!stat.isFile() || stat.size < 4 || (receivedBytes > 0 && stat.size !== receivedBytes)) {
      throw new Error('导出包下载未完成，请重新下载');
    }
    if (stat.size > MAX_FILE_BACKUP_BYTES) {
      throw new Error(NATIVE_MIGRATION_SIZE_ERROR);
    }
    const header = new ArrayBuffer(4);
    if (await fileIo.read(file.fd, header) !== header.byteLength ||
      new DataView(header).getUint32(0, true) !== 0x04034b50) {
      throw new Error('导出的文件不是有效的 ZIP 文件');
    }
    await fileIo.fsync(file.fd);
  } finally {
    await fileIo.close(file);
  }
  // The completed name is also the recovery marker. A partial file stays invisible to the importer.
  await fileIo.rename(part, completedPath(context));
}

export async function consumePendingNativeMigration(context: common.UIAbilityContext,
  merge: (path: string) => Promise<number>): Promise<number | null> {
  const path = completedPath(context);
  if (!hasPendingNativeMigration(context) || activeImports.has(path)) {
    return null;
  }
  activeImports.add(path);
  try {
    const count = await merge(path);
    unlinkIfPresent(path);
    return count;
  } finally {
    activeImports.delete(path);
  }
}
