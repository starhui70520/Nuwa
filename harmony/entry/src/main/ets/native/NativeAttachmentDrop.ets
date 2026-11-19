import { unifiedDataChannel, uniformDataStruct, uniformTypeDescriptor } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileUri } from '@kit.CoreFileKit';

const TYPES = uniformTypeDescriptor.UniformDataType;
const MAX_URI_LENGTH = 4096;
const DATA_NOT_FOUND = 190001;
const DATA_RETRY_MS = 1500;

export const NATIVE_ATTACHMENT_DROP_TYPES: uniformTypeDescriptor.UniformDataType[] = [
  TYPES.FILE_URI, TYPES.FILE, TYPES.IMAGE, TYPES.AUDIO, TYPES.VIDEO, TYPES.ZIP_ARCHIVE,
];

export const NATIVE_COMPOSER_DROP_TYPES: uniformTypeDescriptor.UniformDataType[] = [
  ...NATIVE_ATTACHMENT_DROP_TYPES, TYPES.PLAIN_TEXT, TYPES.HTML, TYPES.HYPERLINK,
];

function hasNativeDropType(event: DragEvent, types: uniformTypeDescriptor.UniformDataType[]): boolean {
  // The native drag summary has been returned both as a record and as an array of [type, size] pairs.
  const summary = event.getSummary()?.summary as Record<string, number> | Array<Array<string | number>> | undefined;
  if (!summary) return false;
  if (Array.isArray(summary)) {
    return types.some((type: uniformTypeDescriptor.UniformDataType): boolean =>
      summary.some((entry: Array<string | number>): boolean => entry[0] === type));
  }
  return types.some((type: uniformTypeDescriptor.UniformDataType): boolean =>
    summary[type] !== undefined);
}

export function hasNativeAttachmentDropType(event: DragEvent): boolean {
  return hasNativeDropType(event, NATIVE_ATTACHMENT_DROP_TYPES);
}

export function hasNativeBackupDropType(event: DragEvent): boolean {
  return hasNativeDropType(event, [TYPES.ZIP_ARCHIVE]);
}

export function nativeBackupDropUri(uris: string[]): string | undefined {
  return uris.find((uri: string): boolean => {
    try {
      const name = uri.startsWith('/') ? uri.slice(uri.lastIndexOf('/') + 1) : new fileUri.FileUri(uri).name;
      return name.toLowerCase().endsWith('.zip');
    } catch {
      return false;
    }
  });
}

function safeLocalPath(path: string): boolean {
  return !/[\u0000-\u001f\u007f\\]/.test(path) && !path.split('/').includes('..');
}

function localAttachmentUri(value: string, ownBundle: string): string {
  if (typeof value !== 'string' || !value || value.length > MAX_URI_LENGTH ||
    /[\u0000-\u001f\u007f\\]/.test(value)) return '';
  if (value.startsWith('/storage/')) return safeLocalPath(value) ? value : '';
  const parts = /^file:\/\/([a-z0-9._-]*)(\/[^?#\s]+)(?:\?[^#\s]*)?$/i.exec(value);
  if (!parts) return '';
  const authority = parts[1].toLowerCase();
  try {
    const path = decodeURIComponent(parts[2]);
    // Cross-app drag data must never resolve to a path in Nuwa's own sandbox.
    if (!safeLocalPath(path) || (!!authority && authority === ownBundle.toLowerCase()) ||
      ((!authority || authority === 'localhost') && !path.startsWith('/storage/'))) return '';
    return value;
  } catch {
    return '';
  }
}

function fileUriValue(value: unifiedDataChannel.ValueType): string {
  if (typeof value === 'string') return value;
  if (!value || typeof value !== 'object') return '';
  const file = value as uniformDataStruct.FileUri;
  return file.fileType !== TYPES.FOLDER && typeof file.oriUri === 'string' ? file.oriUri : '';
}

function recordAttachmentUri(record: unifiedDataChannel.UnifiedRecord): string {
  switch (record.getType()) {
    case TYPES.FILE_URI:
    case TYPES.ZIP_ARCHIVE: return fileUriValue(record.getValue());
    case TYPES.FILE: return (record as unifiedDataChannel.File).uri;
    case TYPES.IMAGE: return (record as unifiedDataChannel.Image).imageUri;
    case TYPES.AUDIO: return (record as unifiedDataChannel.Audio).audioUri;
    case TYPES.VIDEO: return (record as unifiedDataChannel.Video).videoUri;
    case TYPES.FOLDER: return '';
  }
  // A newer UDMF record can include a file URI as an alternative to its primary representation.
  if (typeof record.getTypes === 'function' && record.getTypes().includes(TYPES.FILE_URI)) {
    return fileUriValue(record.getEntry(TYPES.FILE_URI));
  }
  return '';
}

export function nativeAttachmentDropUris(data: unifiedDataChannel.UnifiedData, ownBundle: string): string[] {
  const uris = new Set<string>();
  for (const record of data.getRecords()) {
    const uri = localAttachmentUri(recordAttachmentUri(record), ownBundle);
    if (uri) uris.add(uri);
  }
  return Array.from(uris);
}

export async function readNativeAttachmentDrop(event: DragEvent, ownBundle: string): Promise<string[]> {
  let data: UnifiedData;
  try {
    data = event.getData();
  } catch (error) {
    if ((error as BusinessError)?.code !== DATA_NOT_FOUND) throw error as Error;
    // Large drag payloads can reach the destination before UDMF's local data is ready.
    await new Promise<void>((resolve): void => { setTimeout((): void => { resolve(); }, DATA_RETRY_MS); });
    data = event.getData();
  }
  return data ? nativeAttachmentDropUris(data, ownBundle) : [];
}
