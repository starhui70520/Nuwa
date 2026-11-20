import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { ensureNativeDirectory } from './NativeFileSystem';
import { NativeMathPicture } from './NativeMathRenderQueue';

const MAX_PICTURE_DATA_URI_LENGTH = 260_000;
const MATH_PICTURE_ROOT = 'nuwa-formula-pictures';
const initializedRoots = new Map<string, Promise<void>>();

export interface NativeStoredMathPicture {
  source: string;
  width: number;
  height: number;
  depth: number;
}

async function writeFully(fd: number, bytes: Uint8Array): Promise<void> {
  let offset = 0;
  while (offset < bytes.byteLength) {
    const chunk = bytes.buffer.slice(bytes.byteOffset + offset,
      bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
    const written = await fileIo.write(fd, chunk);
    if (!Number.isSafeInteger(written) || written <= 0) {
      throw new Error('Math image write did not complete');
    }
    offset += written;
  }
}

function validPicture(picture: NativeMathPicture): boolean {
  return !!picture && typeof picture.png === 'string' && picture.png.length > 0 &&
    picture.png.length <= MAX_PICTURE_DATA_URI_LENGTH &&
    /^data:image\/png;base64,[A-Za-z0-9+/=]+$/.test(picture.png) &&
    Number.isInteger(picture.width) && picture.width > 0 && picture.width <= 2800 &&
    Number.isInteger(picture.height) && picture.height > 0 && picture.height <= 1000 &&
    Number.isFinite(picture.depth) && picture.depth >= 0 && picture.depth <= picture.height;
}

/** Owns ephemeral rendered formula PNGs for one Markdown renderer/cache lifetime. */
export class NativeMathPictureFiles {
  private readonly root: string;
  private directory?: string;
  private directoryTask?: Promise<string>;
  private closed: boolean = false;
  private disposeTask?: Promise<void>;
  private readonly owned = new Set<string>();
  private readonly inFlight = new Set<Promise<NativeStoredMathPicture | null>>();
  private readonly cleanups = new Set<Promise<void>>();

  constructor(temporaryDirectory: string) {
    this.root = temporaryDirectory + '/' + MATH_PICTURE_ROOT;
  }

  store(picture: NativeMathPicture): Promise<NativeStoredMathPicture | null> {
    if (this.closed || !validPicture(picture)) return Promise.resolve(null);
    const task = this.writePicture(picture);
    this.inFlight.add(task);
    return task.finally((): void => { this.inFlight.delete(task); });
  }

  release(source: string): Promise<void> {
    if (this.closed) return Promise.resolve();
    const path = this.pathFromSource(source);
    if (!path || !this.owned.has(path)) return Promise.resolve();
    this.owned.delete(path);
    const task = fileIo.unlink(path).catch(() => {});
    this.cleanups.add(task);
    return task.finally((): void => { this.cleanups.delete(task); });
  }

  dispose(): Promise<void> {
    if (this.disposeTask) return this.disposeTask;
    this.closed = true;
    this.disposeTask = this.finishDispose();
    return this.disposeTask;
  }

  private async finishDispose(): Promise<void> {
    while (this.inFlight.size > 0 || this.cleanups.size > 0) {
      await Promise.all([...Array.from(this.inFlight), ...Array.from(this.cleanups)]);
    }
    const directory = this.directory;
    if (directory) await fileIo.rmdir(directory).catch(() => {});
    this.owned.clear();
    this.directory = undefined;
    this.directoryTask = undefined;
  }

  private pathFromSource(source: string): string | undefined {
    const directory = this.directory;
    if (!directory || !source.startsWith('file://')) return undefined;
    const path = source.slice('file://'.length);
    return path.startsWith(directory + '/') ? path : undefined;
  }

  private async getDirectory(): Promise<string> {
    if (this.directory) return this.directory;
    if (!this.directoryTask) {
      const task = this.getRoot().then(async (): Promise<string> => {
        const path = this.root + '/' + util.generateRandomUUID(true);
        await ensureNativeDirectory(path);
        return path;
      });
      this.directoryTask = task;
      try {
        this.directory = await task;
      } catch (error) {
        if (this.directoryTask === task) this.directoryTask = undefined;
        throw error as Error;
      }
    } else {
      this.directory = await this.directoryTask;
    }
    return this.directory;
  }

  private getRoot(): Promise<void> {
    const existing = initializedRoots.get(this.root);
    if (existing) return existing;
    const task = (async (): Promise<void> => {
      // A fresh process owns this dedicated cache root; remove crash leftovers before
      // any renderer instance can publish a new UUID child.
      await fileIo.rmdir(this.root).catch(() => {});
      await ensureNativeDirectory(this.root);
    })();
    initializedRoots.set(this.root, task);
    void task.catch((): void => {
      if (initializedRoots.get(this.root) === task) initializedRoots.delete(this.root);
    });
    return task;
  }

  private async writePicture(picture: NativeMathPicture): Promise<NativeStoredMathPicture | null> {
    let temporary = '';
    let finalPath = '';
    let target: fileIo.File | undefined;
    try {
      const directory = await this.getDirectory();
      if (this.closed) return null;
      const id = util.generateRandomUUID(true);
      temporary = directory + '/' + id + '.part';
      finalPath = directory + '/' + id + '.png';
      const encoded = picture.png.slice('data:image/png;base64,'.length);
      const bytes = new util.Base64Helper().decodeSync(encoded);
      if (bytes.byteLength === 0) return null;
      target = await fileIo.open(temporary,
        fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      await writeFully(target.fd, bytes);
      await fileIo.close(target);
      target = undefined;
      if (this.closed) return null;
      await fileIo.rename(temporary, finalPath);
      temporary = '';
      if (this.closed) {
        await fileIo.unlink(finalPath).catch(() => {});
        return null;
      }
      this.owned.add(finalPath);
      return {
        source: 'file://' + finalPath,
        width: picture.width,
        height: picture.height,
        depth: picture.depth,
      };
    } catch {
      return null;
    } finally {
      if (target) await fileIo.close(target).catch(() => {});
      if (temporary) await fileIo.unlink(temporary).catch(() => {});
      if (finalPath && !this.owned.has(finalPath)) await fileIo.unlink(finalPath).catch(() => {});
    }
  }
}
