import { util } from '@kit.ArkTS';
import { zlib } from '@kit.BasicServicesKit';

export interface NativeBackupZipEntry {
  name: string;
  data: Uint8Array;
}

export interface NativeBackupZipInput {
  size: number;
  read: (offset: number, length: number) => Promise<Uint8Array>;
}

export interface NativeBackupZipStreamEntry {
  name: string;
  size: number;
  crc: number;
  consume: (write: (chunk: Uint8Array) => Promise<void>) => Promise<void>;
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

const ZIP64_SIZE = 0xffffffff;
const ZIP64_COUNT = 0xffff;
const MAX_END_RECORD_BYTES = 22 + 0xffff;
export const MAX_BACKUP_BYTES = 64 * 1024 * 1024;
export const MAX_BACKUP_ENTRY_BYTES = 64 * 1024 * 1024;
// The central directory start and size are independent ZIP32 fields.
export const MAX_FILE_BACKUP_BYTES = 2 * (ZIP64_SIZE - 1) + MAX_END_RECORD_BYTES;
const CHUNK_BYTES = 256 * 1024;
// A JSON escape can occupy six bytes per UTF-16 code unit.
const TEXT_CHUNK_CHARS = 32 * 1024;
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

function accumulateCrc(crc: number, data: Uint8Array): number {
  for (const byte of data) {
    crc = (crc >>> 8) ^ CRC_TABLE[(crc ^ byte) & 0xff];
  }
  return crc;
}

function completeCrc(crc: number): number {
  return (crc ^ 0xffffffff) >>> 0;
}

function crc32(data: Uint8Array): number {
  return completeCrc(accumulateCrc(0xffffffff, data));
}

export function backupZipChecksum(data: Uint8Array): number {
  return crc32(data);
}

function invalidZip(): never {
  throw new Error('历史备份 ZIP 格式无效或文件不完整。');
}

function tooLarge(): never {
  throw new Error('暂不支持超过 64 MB 的历史备份。');
}

function fileBackupTooLarge(): never {
  throw new Error('备份超出 ZIP32 格式上限，暂不支持 ZIP64。');
}

export function memoryBackupInput(data: Uint8Array): NativeBackupZipInput {
  return { size: data.byteLength, read: async (offset: number, length: number): Promise<Uint8Array> =>
    data.subarray(offset, offset + length) };
}

function viewOf(bytes: Uint8Array): DataView {
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
}

async function checkedRead(input: NativeBackupZipInput, offset: number, length: number): Promise<Uint8Array> {
  if (offset < 0 || length < 0 || offset + length > input.size) {
    return invalidZip();
  }
  const data = await input.read(offset, length);
  return data.length === length ? data : invalidZip();
}

export function backupUtf8(value: string): Uint8Array {
  return new util.TextEncoder().encodeInto(value);
}

export function backupText(bytes: Uint8Array): string {
  return util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(bytes);
}

function endOfTextChunk(text: string, start: number): number {
  const end = Math.min(start + TEXT_CHUNK_CHARS, text.length);
  const last = text.charCodeAt(end - 1);
  return end < text.length && last >= 0xd800 && last <= 0xdbff ? end - 1 : end;
}

async function writeBackupText(text: string, write: (chunk: Uint8Array) => Promise<void>,
  escape: boolean = false): Promise<void> {
  const encoder = new util.TextEncoder();
  let start = 0;
  while (start < text.length) {
    const end = endOfTextChunk(text, start);
    const part = text.slice(start, end);
    await write(encoder.encodeInto(escape ? JSON.stringify(part).slice(1, -1) : part));
    start = end;
  }
}

export async function writeBackupJson(value: Object, write: (chunk: Uint8Array) => Promise<void>): Promise<void> {
  // Serialize the metadata separately so ArkTS never allocates a second full-size JSON string for long messages.
  const prefix = 'nuwa-' + util.generateRandomUUID(true) + '-';
  const longTexts: string[] = [];
  const json = JSON.stringify(value, (_key: string, item: Object): Object => {
    if (typeof item !== 'string' || item.length <= TEXT_CHUNK_CHARS) return item;
    const marker = prefix + longTexts.length.toString();
    longTexts.push(item);
    return marker;
  });
  let offset = 0;
  for (let index = 0; index < longTexts.length; index++) {
    const marker = '"' + prefix + index.toString() + '"';
    const position = json.indexOf(marker, offset);
    if (position < 0 || json.indexOf(marker, position + marker.length) >= 0) return invalidZip();
    await writeBackupText(json.slice(offset, position), write);
    await write(Uint8Array.of(34));
    await writeBackupText(longTexts[index], write, true);
    await write(Uint8Array.of(34));
    offset = position + marker.length;
  }
  await writeBackupText(json.slice(offset), write);
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
  const first = Math.max(0, view.byteLength - MAX_END_RECORD_BYTES);
  for (let i = view.byteLength - 22; i >= first; i--) {
    if (view.getUint32(i, true) === END_HEADER &&
      i + 22 + view.getUint16(i + 20, true) === view.byteLength) {
      return i;
    }
  }
  return invalidZip();
}

async function readDirectory(input: NativeBackupZipInput, limit?: number): Promise<ZipDirectory> {
  const tailOffset = Math.max(0, input.size - MAX_END_RECORD_BYTES);
  const tail = viewOf(await checkedRead(input, tailOffset, input.size - tailOffset));
  const end = locateEnd(tail);
  const count = tail.getUint16(end + 10, true);
  const size = tail.getUint32(end + 12, true);
  const start = tail.getUint32(end + 16, true);
  if (tail.getUint16(end + 4, true) !== 0 || tail.getUint16(end + 6, true) !== 0 ||
    tail.getUint16(end + 8, true) !== count || count === ZIP64_COUNT || size === ZIP64_SIZE ||
    start === ZIP64_SIZE || start + size !== tailOffset + end) {
    return invalidZip();
  }
  let cachedAt = 0;
  let cached = new Uint8Array(0);
  const read = async (offset: number, length: number): Promise<Uint8Array> => {
    if (offset + length > cachedAt + cached.length) {
      cached = await checkedRead(input, start + offset, Math.min(CHUNK_BYTES, size - offset));
      cachedAt = offset;
    }
    return cached.subarray(offset - cachedAt, offset - cachedAt + length);
  };
  const entries: DirectoryEntry[] = [];
  const names = new Set<string>();
  let total = 0;
  let offset = 0;
  for (let i = 0; i < count; i++) {
    if (offset + 46 > size) {
      return invalidZip();
    }
    const view = viewOf(await read(offset, 46));
    if (view.getUint32(0, true) !== CENTRAL_HEADER) {
      return invalidZip();
    }
    const flags = view.getUint16(8, true);
    const method = view.getUint16(10, true);
    const length = view.getUint16(28, true);
    const nameStart = offset + 46;
    const metadataLength = length + view.getUint16(30, true);
    const next = nameStart + metadataLength + view.getUint16(32, true);
    if (!length || next > size || (flags & ~(UTF8_FLAG | DESCRIPTOR_FLAG | 6)) !== 0 ||
      (method !== STORED && method !== DEFLATE) || view.getUint16(34, true) !== 0 ||
      ((view.getUint32(38, true) >>> 16) & 0xf000) === 0xa000) {
      return invalidZip();
    }
    const metadata = await read(nameStart, metadataLength);
    validateExtra(viewOf(metadata), length, metadataLength);
    const nameBytes = metadata.slice(0, length);
    if (!(flags & UTF8_FLAG) && nameBytes.some((byte: number): boolean => byte >= 128)) {
      return invalidZip();
    }
    const name = backupPath(backupText(nameBytes));
    const entry: DirectoryEntry = {
      name: name,
      nameBytes: nameBytes,
      flags: flags,
      method: method,
      crc: view.getUint32(16, true),
      compressedSize: view.getUint32(20, true),
      size: view.getUint32(24, true),
      offset: view.getUint32(42, true),
    };
    const identity = name.endsWith('/') ? name.slice(0, -1) : name;
    if (names.has(identity) || entry.offset + 30 > start || entry.size === ZIP64_SIZE ||
      entry.compressedSize === ZIP64_SIZE ||
      (method === STORED && entry.compressedSize !== entry.size) || (name.endsWith('/') && entry.size !== 0)) {
      return invalidZip();
    }
    names.add(identity);
    entries.push(entry);
    total += entry.size;
    if (limit !== undefined && total > limit) {
      return tooLarge();
    }
    offset = next;
  }
  if (offset !== size) {
    return invalidZip();
  }
  entries.sort((a: DirectoryEntry, b: DirectoryEntry): number => a.offset - b.offset);
  return { entries: entries, offset: start };
}

async function verifyDescriptor(input: NativeBackupZipInput, entry: DirectoryEntry, dataEnd: number,
  boundary: number): Promise<void> {
  if (dataEnd + 12 > boundary) {
    invalidZip();
  }
  const view = viewOf(await checkedRead(input, dataEnd, Math.min(16, boundary - dataEnd)));
  const hasSignature = view.getUint32(0, true) === DESCRIPTOR_HEADER;
  const first = hasSignature ? 4 : 0;
  if (first + 12 > view.byteLength || view.getUint32(first, true) !== entry.crc ||
    view.getUint32(first + 4, true) !== entry.compressedSize || view.getUint32(first + 8, true) !== entry.size) {
    invalidZip();
  }
}

async function localData(input: NativeBackupZipInput, entry: DirectoryEntry, boundary: number): Promise<number> {
  if (entry.offset + 30 > boundary) {
    return invalidZip();
  }
  const view = viewOf(await checkedRead(input, entry.offset, 30));
  const nameStart = entry.offset + 30;
  const nameLength = view.getUint16(26, true);
  const extraLength = view.getUint16(28, true);
  const start = nameStart + nameLength + extraLength;
  const end = start + entry.compressedSize;
  if (end > boundary || view.getUint32(0, true) !== LOCAL_HEADER ||
    view.getUint16(6, true) !== entry.flags || view.getUint16(8, true) !== entry.method ||
    nameLength !== entry.nameBytes.length) {
    return invalidZip();
  }
  const metadata = await checkedRead(input, nameStart, nameLength + extraLength);
  if (entry.nameBytes.some((byte: number, index: number): boolean => byte !== metadata[index])) {
    return invalidZip();
  }
  validateExtra(viewOf(metadata), nameLength, metadata.length);
  const descriptor = (entry.flags & DESCRIPTOR_FLAG) !== 0;
  const crc = view.getUint32(14, true);
  const compressed = view.getUint32(18, true);
  const size = view.getUint32(22, true);
  if ((crc !== entry.crc && (!descriptor || crc !== 0)) ||
    (compressed !== entry.compressedSize && (!descriptor || compressed !== 0)) ||
    (size !== entry.size && (!descriptor || size !== 0))) {
    return invalidZip();
  }
  if (descriptor) {
    await verifyDescriptor(input, entry, end, boundary);
  }
  return start;
}

async function inflateRaw(input: NativeBackupZipInput, offset: number, entry: DirectoryEntry,
  write: (chunk: Uint8Array) => Promise<void>): Promise<void> {
  const zip = await zlib.createZip();
  const stream: zlib.ZStream = {};
  if (await zip.inflateInit2(stream, -15) !== zlib.ReturnStatus.OK) {
    return invalidZip();
  }
  try {
    const output = new ArrayBuffer(CHUNK_BYTES);
    let pending = new ArrayBuffer(0);
    let cursor = 0;
    let written = 0;
    while (true) {
      if (!pending.byteLength && cursor < entry.compressedSize) {
        const chunk = await checkedRead(input, offset + cursor, Math.min(CHUNK_BYTES, entry.compressedSize - cursor));
        pending = chunk.byteOffset === 0 && chunk.byteLength === chunk.buffer.byteLength ?
          chunk.buffer as ArrayBuffer : chunk.slice().buffer as ArrayBuffer;
        cursor += chunk.byteLength;
      }
      stream.nextIn = pending;
      stream.availableIn = pending.byteLength;
      stream.nextOut = output;
      stream.availableOut = output.byteLength;
      const result = await zip.inflate(stream, zlib.CompressFlushMode.NO_FLUSH);
      const state = await zip.getZStream();
      const availableIn = state.availableIn;
      const availableOut = state.availableOut;
      if ((result !== zlib.ReturnStatus.OK && result !== zlib.ReturnStatus.STREAM_END) ||
        availableIn === undefined || availableOut === undefined || !Number.isSafeInteger(availableIn) ||
        !Number.isSafeInteger(availableOut) || availableIn < 0 || availableIn > pending.byteLength ||
        availableOut < 0 || availableOut > output.byteLength) {
        return invalidZip();
      }
      const length = output.byteLength - availableOut;
      written += length;
      if (written > entry.size || (result === zlib.ReturnStatus.STREAM_END && written !== entry.size)) {
        return invalidZip();
      }
      if (length) {
        // Keep the emitted bytes valid after the destination buffer is reused.
        await write(new Uint8Array(output.slice(0, length)));
      }
      if (result === zlib.ReturnStatus.STREAM_END) {
        return;
      }
      if (!length && availableIn === pending.byteLength) {
        return invalidZip();
      }
      // The runtime maintains the zlib state. Carry only the unconsumed input into the next call.
      if (availableIn !== pending.byteLength) {
        pending = pending.slice(pending.byteLength - availableIn);
      }
    }
  } finally {
    await zip.inflateEnd(stream).catch(() => {});
  }
}

export async function readBackupZip(data: Uint8Array): Promise<NativeBackupZipEntry[]> {
  if (data.length > MAX_BACKUP_BYTES) {
    return tooLarge();
  }
  const result: NativeBackupZipEntry[] = [];
  await readBackupZipEntries(memoryBackupInput(data), async (entry: NativeBackupZipStreamEntry): Promise<void> => {
    result.push({ name: entry.name, data: await readBackupZipEntry(entry) });
  }, MAX_BACKUP_BYTES);
  return result;
}

export async function readBackupZipEntry(entry: NativeBackupZipStreamEntry): Promise<Uint8Array> {
  if (!Number.isSafeInteger(entry.size) || entry.size < 0) {
    return invalidZip();
  }
  if (entry.size > MAX_BACKUP_ENTRY_BYTES) {
    throw new Error('单个备份条目超过 64 MB 的内存读取上限。');
  }
  let data: Uint8Array | undefined;
  let offset = 0;
  await entry.consume(async (chunk: Uint8Array): Promise<void> => {
    if (offset + chunk.length > entry.size) {
      return invalidZip();
    }
    if (offset === 0 && chunk.length === entry.size) {
      data = chunk;
    } else {
      data = data ?? new Uint8Array(entry.size);
      data.set(chunk, offset);
    }
    offset += chunk.length;
  });
  if (offset !== entry.size) {
    return invalidZip();
  }
  return data ?? new Uint8Array(0);
}

export async function readBackupText(size: number,
  consume: (write: (chunk: Uint8Array) => Promise<void>) => Promise<void>): Promise<string> {
  const decoder = util.TextDecoder.create('utf-8', { fatal: true });
  const parts: string[] = [];
  let remaining = size;
  await consume(async (chunk: Uint8Array): Promise<void> => {
    remaining -= chunk.length;
    if (remaining < 0) return invalidZip();
    parts.push(decoder.decodeToString(chunk, { stream: remaining > 0 }));
  });
  if (remaining !== 0) return invalidZip();
  return parts.join('');
}

export async function readBackupZipText(entry: NativeBackupZipStreamEntry): Promise<string> {
  return readBackupText(entry.size, entry.consume);
}
export async function readBackupZipEntries(input: NativeBackupZipInput,
  visit: (entry: NativeBackupZipStreamEntry) => Promise<void>, limit?: number): Promise<void> {
  if (!Number.isSafeInteger(input.size) || input.size < 22) {
    return invalidZip();
  }
  if (input.size > MAX_FILE_BACKUP_BYTES) {
    return fileBackupTooLarge();
  }
  if (limit !== undefined && input.size > limit) {
    return tooLarge();
  }
  const directory = await readDirectory(input, limit);
  for (let i = 0; i < directory.entries.length; i++) {
    const entry = directory.entries[i];
    const boundary = directory.entries[i + 1]?.offset ?? directory.offset;
    const offset = await localData(input, entry, boundary);
    let consumed = false;
    const consume = async (write: (chunk: Uint8Array) => Promise<void>): Promise<void> => {
      if (consumed) {
        return invalidZip();
      }
      let crc = 0xffffffff;
      const append = async (chunk: Uint8Array): Promise<void> => {
        crc = accumulateCrc(crc, chunk);
        await write(chunk);
      };
      if (entry.method === STORED) {
        for (let cursor = 0; cursor < entry.size; cursor += CHUNK_BYTES) {
          const chunk = await checkedRead(input, offset + cursor, Math.min(CHUNK_BYTES, entry.size - cursor));
          await append(chunk);
        }
      } else {
        await inflateRaw(input, offset, entry, append);
      }
      if (completeCrc(crc) !== entry.crc) {
        return invalidZip();
      }
      consumed = true;
    };
    if (!entry.name.endsWith('/')) {
      await visit({ name: entry.name, size: entry.size, crc: entry.crc, consume: consume });
    }
    if (!consumed) {
      await consume(async (): Promise<void> => {});
    }
  }
}

interface WrittenEntry {
  name: Uint8Array;
  size: number;
  crc: number;
  offset: number;
}

type WriteBackupChunk = (chunk: Uint8Array) => Promise<void>;

function storedLocalHeader(name: Uint8Array): Uint8Array {
  const bytes = new Uint8Array(30 + name.length);
  const view = viewOf(bytes);
  view.setUint32(0, LOCAL_HEADER, true);
  view.setUint16(4, 20, true);
  view.setUint16(6, UTF8_FLAG | DESCRIPTOR_FLAG, true);
  view.setUint16(12, 0x21, true);
  view.setUint16(26, name.length, true);
  bytes.set(name, 30);
  return bytes;
}

function storedDescriptor(size: number, crc: number): Uint8Array {
  const bytes = new Uint8Array(16);
  const view = viewOf(bytes);
  view.setUint32(0, DESCRIPTOR_HEADER, true);
  view.setUint32(4, crc, true);
  view.setUint32(8, size, true);
  view.setUint32(12, size, true);
  return bytes;
}

function storedCentralHeader(entry: WrittenEntry): Uint8Array {
  const bytes = new Uint8Array(46 + entry.name.length);
  const view = viewOf(bytes);
  view.setUint32(0, CENTRAL_HEADER, true);
  view.setUint16(4, 20, true);
  view.setUint16(6, 20, true);
  view.setUint16(8, UTF8_FLAG | DESCRIPTOR_FLAG, true);
  view.setUint16(14, 0x21, true);
  view.setUint32(16, entry.crc, true);
  view.setUint32(20, entry.size, true);
  view.setUint32(24, entry.size, true);
  view.setUint16(28, entry.name.length, true);
  view.setUint32(42, entry.offset, true);
  bytes.set(entry.name, 46);
  return bytes;
}

export class NativeBackupZipWriter {
  private readonly entries: WrittenEntry[] = [];
  private readonly names = new Set<string>();
  private readonly write: (chunk: Uint8Array) => Promise<void>;
  private offset: number = 0;
  private directorySize: number = 0;
  private ended: boolean = false;

  constructor(write: (chunk: Uint8Array) => Promise<void>) {
    this.write = write;
  }

  async add(path: string, input: NativeBackupZipInput): Promise<number> {
    if (!Number.isSafeInteger(input.size) || input.size < 0) {
      return invalidZip();
    }
    return this.addEntry(path, input.size, async (append: WriteBackupChunk): Promise<void> => {
      for (let cursor = 0; cursor < input.size; cursor += CHUNK_BYTES) {
        const size = Math.min(CHUNK_BYTES, input.size - cursor);
        await append(await checkedRead(input, cursor, size));
      }
    });
  }

  async addJson(path: string, value: Object): Promise<number> {
    return this.addEntry(path, 0, (append: WriteBackupChunk): Promise<void> => writeBackupJson(value, append));
  }

  private async addEntry(path: string, minimumSize: number,
    writePayload: (append: WriteBackupChunk) => Promise<void>): Promise<number> {
    const name = backupPath(path);
    const encoded = backupUtf8(name);
    if (this.ended || this.names.has(name) || name.endsWith('/') || encoded.length > 0xffff ||
      backupText(encoded) !== name) {
      return invalidZip();
    }
    const directorySize = this.directorySize + 46 + encoded.length;
    const overhead = 30 + encoded.length + 16; // Local header and data descriptor.
    const maxPayloadSize = ZIP64_SIZE - this.offset - overhead;
    if (directorySize >= ZIP64_SIZE || minimumSize >= maxPayloadSize ||
      this.entries.length + 1 >= ZIP64_COUNT) {
      return fileBackupTooLarge();
    }
    await this.write(storedLocalHeader(encoded));
    let crc = 0xffffffff;
    let size = 0;
    await writePayload(async (chunk: Uint8Array): Promise<void> => {
      size += chunk.length;
      if (size >= maxPayloadSize) {
        return fileBackupTooLarge();
      }
      crc = accumulateCrc(crc, chunk);
      await this.write(chunk);
    });
    const checksum = completeCrc(crc);
    await this.write(storedDescriptor(size, checksum));
    this.entries.push({ name: encoded, size: size, crc: checksum, offset: this.offset });
    this.offset += overhead + size;
    this.directorySize = directorySize;
    this.names.add(name);
    return checksum;
  }

  async finish(): Promise<void> {
    if (this.ended) {
      return invalidZip();
    }
    this.ended = true;
    for (const entry of this.entries) {
      await this.write(storedCentralHeader(entry));
    }
    const bytes = new Uint8Array(22);
    const view = viewOf(bytes);
    view.setUint32(0, END_HEADER, true);
    view.setUint16(8, this.entries.length, true);
    view.setUint16(10, this.entries.length, true);
    view.setUint32(12, this.directorySize, true);
    view.setUint32(16, this.offset, true);
    await this.write(bytes);
  }
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
  if (size > MAX_BACKUP_BYTES || entries.length >= ZIP64_COUNT) {
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
