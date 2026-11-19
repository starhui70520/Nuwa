import { util } from '@kit.ArkTS';
import { zlib } from '@kit.BasicServicesKit';

export interface NativeBackupZipEntry {
  name: string;
  data: Uint8Array;
}

interface DirectoryEntry {
  name: string;
  nameBytes: Uint8Array;
  flags: number;
  method: number;
  crc: number;
  compressedSize: number;
  size: number;
  offset: number;
}

interface ZipDirectory {
  entries: DirectoryEntry[];
  offset: number;
}

export const MAX_BACKUP_BYTES = 64 * 1024 * 1024;
const LOCAL_HEADER = 0x04034b50;
const CENTRAL_HEADER = 0x02014b50;
const END_HEADER = 0x06054b50;
const DESCRIPTOR_HEADER = 0x08074b50;
const UTF8_FLAG = 0x800;
const DESCRIPTOR_FLAG = 8;
const STORED = 0;
const DEFLATE = 8;

function crcTable(): Uint32Array {
  const table = new Uint32Array(256);
  for (let index = 0; index < table.length; index++) {
    let value = index;
    for (let bit = 0; bit < 8; bit++) {
      value = (value >>> 1) ^ ((value & 1) ? 0xedb88320 : 0);
    }
    table[index] = value;
  }
  return table;
}

const CRC_TABLE = crcTable();

function crc32(data: Uint8Array): number {
  let crc = 0xffffffff;
  for (const byte of data) {
    crc = (crc >>> 8) ^ CRC_TABLE[(crc ^ byte) & 0xff];
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function invalidZip(): never {
  throw new Error('历史备份 ZIP 格式无效或文件不完整。');
}

function tooLarge(): never {
  throw new Error('暂不支持超过 64 MB 的历史备份。');
}

export function backupUtf8(value: string): Uint8Array {
  return new util.TextEncoder().encodeInto(value);
}

export function backupText(bytes: Uint8Array): string {
  return util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(bytes);
}

export function backupPath(value: string): string {
  const name = value.normalize('NFC');
  const trimmed = name.endsWith('/') ? name.slice(0, -1) : name;
  if (!trimmed || /^[A-Za-z]:/.test(trimmed) || trimmed.includes('\\') || trimmed.includes('\0') ||
    trimmed.split('/').some((part: string): boolean => !part || part === '.' || part === '..')) {
    invalidZip();
  }
  return name;
}

function validateExtra(view: DataView, start: number, end: number): void {
  let offset = start;
  while (offset < end) {
    if (offset + 4 > end || view.getUint16(offset, true) === 1) {
      invalidZip();
    }
    offset += 4 + view.getUint16(offset + 2, true);
  }
  if (offset !== end) {
    invalidZip();
  }
}

function locateEnd(view: DataView): number {
  const first = Math.max(0, view.byteLength - 65_557);
  for (let i = view.byteLength - 22; i >= first; i--) {
    if (view.getUint32(i, true) === END_HEADER &&
      i + 22 + view.getUint16(i + 20, true) === view.byteLength) {
      return i;
    }
  }
  return invalidZip();
}

function readDirectory(data: Uint8Array, view: DataView): ZipDirectory {
  const end = locateEnd(view);
  const count = view.getUint16(end + 10, true);
  const size = view.getUint32(end + 12, true);
  const start = view.getUint32(end + 16, true);
  if (view.getUint16(end + 4, true) !== 0 || view.getUint16(end + 6, true) !== 0 ||
    view.getUint16(end + 8, true) !== count || count === 0xffff || start + size !== end) {
    return invalidZip();
  }
  const entries: DirectoryEntry[] = [];
  const names = new Set<string>();
  let total = 0;
  let offset = start;
  for (let i = 0; i < count; i++) {
    if (offset + 46 > end || view.getUint32(offset, true) !== CENTRAL_HEADER) {
      return invalidZip();
    }
    const flags = view.getUint16(offset + 8, true);
    const method = view.getUint16(offset + 10, true);
    const length = view.getUint16(offset + 28, true);
    const nameStart = offset + 46;
    const extraStart = nameStart + length;
    const extraEnd = extraStart + view.getUint16(offset + 30, true);
    const next = extraEnd + view.getUint16(offset + 32, true);
    if (!length || next > end || (flags & ~(UTF8_FLAG | DESCRIPTOR_FLAG | 6)) !== 0 ||
      (method !== STORED && method !== DEFLATE) || view.getUint16(offset + 34, true) !== 0) {
      return invalidZip();
    }
    validateExtra(view, extraStart, extraEnd);
    const nameBytes = data.subarray(nameStart, extraStart);
    if (!(flags & UTF8_FLAG) && nameBytes.some((byte: number): boolean => byte >= 128)) {
      return invalidZip();
    }
    const name = backupPath(backupText(nameBytes));
    const entry: DirectoryEntry = {
      name: name,
      nameBytes: nameBytes,
      flags: flags,
      method: method,
      crc: view.getUint32(offset + 16, true),
      compressedSize: view.getUint32(offset + 20, true),
      size: view.getUint32(offset + 24, true),
      offset: view.getUint32(offset + 42, true),
    };
    if (names.has(name) || entry.offset + 30 > start ||
      (method === STORED && entry.compressedSize !== entry.size) || (name.endsWith('/') && entry.size !== 0)) {
      return invalidZip();
    }
    names.add(name);
    entries.push(entry);
    total += entry.size;
    if (total > MAX_BACKUP_BYTES) {
      return tooLarge();
    }
    offset = next;
  }
  if (offset !== end) {
    return invalidZip();
  }
  entries.sort((a: DirectoryEntry, b: DirectoryEntry): number => a.offset - b.offset);
  return { entries: entries, offset: start };
}

function verifyDescriptor(view: DataView, entry: DirectoryEntry, dataEnd: number, boundary: number): void {
  if (dataEnd + 12 > boundary) {
    invalidZip();
  }
  const hasSignature = view.getUint32(dataEnd, true) === DESCRIPTOR_HEADER;
  const first = hasSignature ? dataEnd + 4 : dataEnd;
  if (first + 12 > boundary || view.getUint32(first, true) !== entry.crc ||
    view.getUint32(first + 4, true) !== entry.compressedSize || view.getUint32(first + 8, true) !== entry.size) {
    invalidZip();
  }
}

function localData(data: Uint8Array, view: DataView, entry: DirectoryEntry, boundary: number): Uint8Array {
  const header = entry.offset;
  const nameStart = header + 30;
  const extraStart = nameStart + view.getUint16(header + 26, true);
  const start = extraStart + view.getUint16(header + 28, true);
  const end = start + entry.compressedSize;
  if (end > boundary || view.getUint32(header, true) !== LOCAL_HEADER ||
    view.getUint16(header + 6, true) !== entry.flags || view.getUint16(header + 8, true) !== entry.method ||
    extraStart - nameStart !== entry.nameBytes.length ||
    entry.nameBytes.some((byte: number, index: number): boolean => byte !== data[nameStart + index])) {
    return invalidZip();
  }
  validateExtra(view, extraStart, start);
  const descriptor = (entry.flags & DESCRIPTOR_FLAG) !== 0;
  const crc = view.getUint32(header + 14, true);
  const compressed = view.getUint32(header + 18, true);
  const size = view.getUint32(header + 22, true);
  if ((crc !== entry.crc && (!descriptor || crc !== 0)) ||
    (compressed !== entry.compressedSize && (!descriptor || compressed !== 0)) ||
    (size !== entry.size && (!descriptor || size !== 0))) {
    return invalidZip();
  }
  if (descriptor) {
    verifyDescriptor(view, entry, end, boundary);
  }
  return data.subarray(start, end);
}

async function inflateRaw(compressed: Uint8Array, size: number): Promise<Uint8Array> {
  const zip = await zlib.createZip();
  const output = new Uint8Array(size);
  let written = 0;
  const stream: zlib.ZStream = {
    nextIn: compressed.slice().buffer as ArrayBuffer,
    availableIn: compressed.byteLength,
  };
  const initialized = await zip.inflateBackInit({}, 15, new ArrayBuffer(32 * 1024));
  if (initialized !== zlib.ReturnStatus.OK) {
    return invalidZip();
  }
  try {
    const result = await zip.inflateBack(stream,
      (_description: object): ArrayBuffer => new ArrayBuffer(0), new Object(),
      (_description: object, chunk: ArrayBuffer, length: number): number => {
        if (length < 0 || length > chunk.byteLength || written + length > size) {
          return 1;
        }
        output.set(new Uint8Array(chunk, 0, length), written);
        written += length;
        return 0;
      }, new Object());
    if (result !== zlib.ReturnStatus.STREAM_END || written !== size) {
      return invalidZip();
    }
    return output;
  } finally {
    await zip.inflateBackEnd({});
  }
}

export async function readBackupZip(data: Uint8Array): Promise<NativeBackupZipEntry[]> {
  if (data.length > MAX_BACKUP_BYTES) {
    return tooLarge();
  }
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  const directory = readDirectory(data, view);
  const result: NativeBackupZipEntry[] = [];
  for (let i = 0; i < directory.entries.length; i++) {
    const entry = directory.entries[i];
    const boundary = directory.entries[i + 1]?.offset ?? directory.offset;
    const compressed = localData(data, view, entry, boundary);
    const content = entry.method === STORED ? compressed : await inflateRaw(compressed, entry.size);
    if (content.length !== entry.size || crc32(content) !== entry.crc) {
      return invalidZip();
    }
    if (!entry.name.endsWith('/')) {
      result.push({ name: entry.name, data: content });
    }
  }
  return result;
}

export function writeBackupZip(entries: NativeBackupZipEntry[]): Uint8Array {
  const names = new Set<string>();
  let localSize = 0;
  let directorySize = 0;
  const paths = entries.map((entry: NativeBackupZipEntry): Uint8Array => {
    const name = backupPath(entry.name);
    const bytes = backupUtf8(name);
    if (names.has(name) || name.endsWith('/') || bytes.length > 0xffff || backupText(bytes) !== name) {
      return invalidZip();
    }
    names.add(name);
    localSize += 30 + bytes.length + entry.data.length;
    directorySize += 46 + bytes.length;
    return bytes;
  });
  const size = localSize + directorySize + 22;
  if (size > MAX_BACKUP_BYTES || entries.length >= 0xffff) {
    return tooLarge();
  }
  const output = new Uint8Array(size);
  const view = new DataView(output.buffer);
  let local = 0;
  let central = localSize;
  entries.forEach((entry: NativeBackupZipEntry, index: number): void => {
    const name = paths[index];
    const length = entry.data.length;
    const crc = crc32(entry.data);
    view.setUint32(local, LOCAL_HEADER, true);
    view.setUint16(local + 4, 20, true);
    view.setUint16(local + 6, UTF8_FLAG, true);
    view.setUint16(local + 12, 0x21, true);
    view.setUint32(local + 14, crc, true);
    view.setUint32(local + 18, length, true);
    view.setUint32(local + 22, length, true);
    view.setUint16(local + 26, name.length, true);
    output.set(name, local + 30);
    output.set(entry.data, local + 30 + name.length);
    view.setUint32(central, CENTRAL_HEADER, true);
    view.setUint16(central + 4, 20, true);
    view.setUint16(central + 6, 20, true);
    view.setUint16(central + 8, UTF8_FLAG, true);
    view.setUint16(central + 14, 0x21, true);
    view.setUint32(central + 16, crc, true);
    view.setUint32(central + 20, length, true);
    view.setUint32(central + 24, length, true);
    view.setUint16(central + 28, name.length, true);
    view.setUint32(central + 42, local, true);
    output.set(name, central + 46);
    local += 30 + name.length + length;
    central += 46 + name.length;
  });
  view.setUint32(central, END_HEADER, true);
  view.setUint16(central + 8, entries.length, true);
  view.setUint16(central + 10, entries.length, true);
  view.setUint32(central + 12, directorySize, true);
  view.setUint32(central + 16, localSize, true);
  return output;
}
