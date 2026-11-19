import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';

const TRANSCRIPT_FILE = 'nuwa-native-chat.json';
const FILE_NOT_FOUND = 13900002;

export interface NativeStoredMessage {
  role: string;
  content: string;
  reasoning: string;
}

let pendingStorage: Promise<void> = Promise.resolve();

function queueStorageOperation<T>(operation: () => Promise<T>): Promise<T> {
  const result = pendingStorage.then<T>(operation);
  pendingStorage = result.then<void, void>(() => {}, () => {});
  return result;
}

export class NativeChatStorage {
  load(context: common.UIAbilityContext): Promise<NativeStoredMessage[]> {
    return queueStorageOperation<NativeStoredMessage[]>(async (): Promise<NativeStoredMessage[]> => {
      let value: string;
      try {
        value = await fileIo.readText(`${context.filesDir}/${TRANSCRIPT_FILE}`);
      } catch (error) {
        if ((error as BusinessError).code === FILE_NOT_FOUND) {
          return [];
        }
        throw error as Error;
      }

      const messages = JSON.parse(value) as NativeStoredMessage[];
      if (!Array.isArray(messages) || messages.some((message: NativeStoredMessage): boolean =>
        !message || typeof message.role !== 'string' || typeof message.content !== 'string' ||
          typeof message.reasoning !== 'string')) {
        throw new Error('Invalid native chat transcript');
      }
      return messages;
    });
  }

  async save(context: common.UIAbilityContext, messages: NativeStoredMessage[]): Promise<void> {
    const snapshot = JSON.stringify(messages.map<NativeStoredMessage>((message: NativeStoredMessage) => ({
      role: message.role,
      content: message.content,
      reasoning: message.reasoning,
    })));

    await queueStorageOperation<void>(async (): Promise<void> => {
      const path = `${context.filesDir}/${TRANSCRIPT_FILE}`;
      const temporaryPath = `${path}.tmp`;
      try {
        const file = await fileIo.open(temporaryPath,
          fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
        try {
          let remaining = new util.TextEncoder().encodeInto(snapshot).buffer as ArrayBuffer;
          while (remaining.byteLength > 0) {
            const written = await fileIo.write(file.fd, remaining);
            if (written <= 0) {
              throw new Error('Could not write native chat transcript');
            }
            remaining = remaining.slice(written);
          }
          await fileIo.fsync(file.fd);
        } finally {
          await fileIo.close(file);
        }
        await fileIo.rename(temporaryPath, path);
      } catch (error) {
        await fileIo.unlink(temporaryPath).catch(() => {});
        throw error as Error;
      }
    });
  }
}
