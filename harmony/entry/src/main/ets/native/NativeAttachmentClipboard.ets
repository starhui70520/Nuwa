import { pasteboard } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { localAttachmentUri } from './NativeAttachmentDrop';
import { NATIVE_ATTACHMENT_MAX_COUNT } from './NativeChatAttachments';

export interface NativeClipboardAttachments {
  uris: string[];
  pixelMaps: image.PixelMap[];
  plainText: string;
}

const ATTACHMENT_MIME_TYPES: string[] = [pasteboard.MIMETYPE_PIXELMAP, pasteboard.MIMETYPE_TEXT_URI];
const WEB_LINK = /^https?:\/\/[^/?#\s\\]+(?:[/?#][^\s\\]*)?$/i;

function hasAttachmentMime(board: pasteboard.SystemPasteboard): boolean {
  return ATTACHMENT_MIME_TYPES.some((mimeType: string): boolean => board.hasDataType(mimeType));
}

export function hasNativeClipboardAttachments(): boolean {
  try {
    return hasAttachmentMime(pasteboard.getSystemPasteboard());
  } catch {
    return false;
  }
}

export async function releaseNativeAttachmentClipboard(payload: NativeClipboardAttachments): Promise<void> {
  await Promise.all(payload.pixelMaps.map((bitmap: image.PixelMap): Promise<void> => bitmap.release().catch(() => {})));
}

// Call from the native Paste menu action or keyboard paste event before yielding to another task.
export async function readNativeAttachmentClipboard(ownBundle: string): Promise<NativeClipboardAttachments> {
  const result: NativeClipboardAttachments = { uris: [], pixelMaps: [], plainText: '' };
  const board = pasteboard.getSystemPasteboard();
  if (!hasAttachmentMime(board)) return result;

  const data = await board.getData();
  const uris = new Set<string>();
  const pixelMaps = new Set<image.PixelMap>();
  let webLink = '';
  const recordCount = data.getRecordCount();
  try {
    for (let index = 0; index < recordCount; index++) {
      const record = data.getRecord(index);
      const additional = typeof record.getValidTypes === 'function' ? record.getValidTypes(ATTACHMENT_MIME_TYPES) : [];
      const uri = record.mimeType === pasteboard.MIMETYPE_TEXT_URI ? record.uri :
        (additional.includes(pasteboard.MIMETYPE_TEXT_URI) ? await record.getData(pasteboard.MIMETYPE_TEXT_URI) : '');
      if (typeof uri === 'string') {
        const localUri = localAttachmentUri(uri, ownBundle);
        if (localUri) uris.add(localUri);
        else if (!webLink && uri.length <= 4096 && !/[\u0000-\u001f\u007f]/.test(uri) && WEB_LINK.test(uri)) webLink = uri;
      }
      const value = record.mimeType === pasteboard.MIMETYPE_PIXELMAP ? record.pixelMap :
        (additional.includes(pasteboard.MIMETYPE_PIXELMAP) ? await record.getData(pasteboard.MIMETYPE_PIXELMAP) : undefined);
      const bitmap = value as image.PixelMap | undefined;
      if (bitmap && typeof bitmap.getPixelBytesNumber === 'function' && !pixelMaps.has(bitmap)) {
        pixelMaps.add(bitmap);
        result.pixelMaps.push(bitmap);
      }
      // Keep enough entries for the common importer to reject over-limit pastes without staging files.
      if (uris.size + pixelMaps.size > NATIVE_ATTACHMENT_MAX_COUNT) break;
    }
    result.uris = Array.from(uris);
    if (!result.uris.length && !result.pixelMaps.length) {
      result.plainText = data.getPrimaryText() || webLink;
    }
    return result;
  } catch (error) {
    await releaseNativeAttachmentClipboard(result);
    throw error as Error;
  }
}
