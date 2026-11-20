import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import avif from 'libnuwa_avif.so';

const MAX_AVIF_SIDE = 8192;
const MAX_AVIF_PIXELS = 16 * 1024 * 1024;
export const NATIVE_AVIF_PREVIEW_SUFFIX = '.avif-preview.png';
const pendingPreviews = new Map<string, Promise<boolean>>();
let previewQueue: Promise<void> = Promise.resolve();

export function existingNativeAvifPreview(originalPath: string): string {
  const preview = originalPath + NATIVE_AVIF_PREVIEW_SUFFIX;
  try {
    if (fileIo.accessSync(preview)) {
      const stat = fileIo.statSync(preview);
      if (stat.isFile() && stat.size > 0) return preview;
    }
  } catch {
    // A preview is optional and can be removed together with its original.
  }
  return '';
}

async function decodeAndPack(originalPath: string, previewPath: string): Promise<boolean> {
  const cached = await fileIo.stat(previewPath).catch((): fileIo.Stat | undefined => undefined);
  if (cached?.isFile() && cached.size > 0) return true;

  let pixels: image.PixelMap | undefined;
  let packer: image.ImagePacker | undefined;
  let temporary = '';
  try {
    const frame = await avif.decodeAvif(originalPath);
    if (!frame) return false;
    const width = frame.width;
    const height = frame.height;
    const rgba = frame.rgba;
    if (!Number.isSafeInteger(width) || !Number.isSafeInteger(height) || width < 1 || height < 1 ||
      Math.max(width, height) > MAX_AVIF_SIDE || width * height > MAX_AVIF_PIXELS || rgba.byteLength !== width * height * 4) {
      return false;
    }
    pixels = await image.createPixelMap(rgba, {
      size: { width: width, height: height },
      srcPixelFormat: image.PixelMapFormat.RGBA_8888,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      alphaType: image.AlphaType.UNPREMUL,
    });
    packer = image.createImagePacker();
    temporary = previewPath + '.' + util.generateRandomUUID(true) + '.tmp';
    const file = await fileIo.open(temporary, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      await packer.packToFile(pixels, file.fd, { format: 'image/png', quality: 100 });
      if ((await fileIo.stat(file.fd)).size <= 0) return false;
      await fileIo.fsync(file.fd);
    } finally {
      await fileIo.close(file);
    }
    if (!(await fileIo.stat(originalPath)).isFile()) return false;
    await fileIo.rename(temporary, previewPath);
    temporary = '';
    // The original may be deleted while the software decoder is running.
    const original = await fileIo.stat(originalPath).catch((): fileIo.Stat | undefined => undefined);
    if (!original?.isFile()) {
      await fileIo.unlink(previewPath).catch(() => {});
      return false;
    }
    return true;
  } finally {
    if (temporary) await fileIo.unlink(temporary).catch(() => {});
    await pixels?.release().catch(() => {});
    await packer?.release().catch(() => {});
  }
}

export function writeNativeAvifPreview(originalPath: string, previewPath: string): Promise<boolean> {
  const pending = pendingPreviews.get(previewPath);
  if (pending) return pending;
  // Each decode can hold a full RGBA frame. Share one decode-and-pack slot across callers.
  const operation = previewQueue.then(async (): Promise<boolean> => {
    try {
      return await decodeAndPack(originalPath, previewPath);
    } catch {
      return false;
    } finally {
      pendingPreviews.delete(previewPath);
    }
  });
  pendingPreviews.set(previewPath, operation);
  previewQueue = operation.then((): void => {});
  return operation;
}
