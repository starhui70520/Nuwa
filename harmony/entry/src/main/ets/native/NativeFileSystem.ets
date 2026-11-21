import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';

const FILE_ALREADY_EXISTS = 13900015;

export async function ensureNativeDirectory(path: string): Promise<void> {
  try {
    await fileIo.mkdir(path, true);
  } catch (error) {
    if ((error as BusinessError).code !== FILE_ALREADY_EXISTS) throw error as Error;
    const existing = await fileIo.stat(path).catch(() => undefined);
    if (!existing?.isDirectory()) throw error as Error;
  }
}
