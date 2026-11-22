import { common } from '@kit.AbilityKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { url, util } from '@kit.ArkTS';
import { zlib } from '@kit.BasicServicesKit';
import { fileIo, fileUri, picker } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { http } from '@kit.NetworkKit';
import { existingNativeAvifPreview, NATIVE_AVIF_PREVIEW_SUFFIX, writeNativeAvifPreview } from './NativeAvifPreview';
import { ensureBackupSpace, withBackupInput } from './NativeBackupFiles';
import { NativeChatConfig } from './NativeChatClient';
import { NativeBackupZipInput } from './NativeBackupZip';
import type { NativeClipboardAttachments } from './NativeAttachmentClipboard';
import { recordNativeFeedbackLog } from './NativeFeedbackService';
import { ensureNativeDirectory } from './NativeFileSystem';

export interface NativeAttachment {
  id: string;
  name: string;
  size: number;
  isImage: boolean;
  mimeType: string;
  purpose: string | null;
  createdAt: number;
  serverId: string | null;
  serverBinding?: string;
  archiveId?: string;
  nativeAvifPreview?: boolean;
  local: boolean;
}

export interface NativeAttachmentQuota {
  kind: 'count' | 'storage';
  limit: string;
}

type NativeAttachmentValidationKind = 'format' | 'size' | 'count' | 'unreadable';

export class NativeAttachmentValidationError extends Error {
  readonly kind: NativeAttachmentValidationKind;
  readonly limit: number;

  constructor(kind: NativeAttachmentValidationKind, limit: number = 0) {
    super(limit > 0 ? `${kind}: ${limit}` : kind);
    this.kind = kind;
    this.limit = limit;
  }
}

export class NativeAttachmentUploadError extends Error {
  readonly retryable: boolean;
  readonly status?: number;
  readonly contentRejected: boolean;
  readonly quota?: NativeAttachmentQuota;

  constructor(detail: string, retryable: boolean, status?: number, contentRejected: boolean = false,
    quota?: NativeAttachmentQuota) {
    super(detail);
    this.retryable = retryable;
    this.status = status;
    this.contentRejected = contentRejected;
    this.quota = quota;
  }
}

function attachmentQuota(result: string): NativeAttachmentQuota | undefined {
  const message = result.slice(0, 8192);
  const count = /User file count limit exceeded.*?limit (\d+)/i.exec(message);
  if (count) return { kind: 'count', limit: count[1] };
  const storage = /User storage quota exceeded.*?limit (\d+(?:\.\d+)?) GB/i.exec(message);
  return storage ? { kind: 'storage', limit: storage[1] } : undefined;
}

function rejectedAttachmentContents(result: string): boolean {
  const message = result.slice(0, 8192);
  return /You have uploaded an (unsupported|invalid) (file|image)|The image is too large to process|password-protected|Failed to recognize the file/i.test(message);
}

interface UploadErrorDetail {
  message?: string;
}

interface UploadErrorPayload {
  error?: UploadErrorDetail;
  message?: string;
}

function extractUploadErrorMessage(raw: string): string {
  const trimmed = raw.trim();
  if (!trimmed) return '';
  try {
    const parsed = JSON.parse(trimmed) as UploadErrorPayload;
    const candidate = parsed?.error?.message ?? parsed?.message ?? '';
    if (typeof candidate === 'string' && candidate.trim()) {
      return candidate.replace(/[\r\n\t]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 200);
    }
  } catch {
    // Non-JSON response body: keep sanitized plain snippet.
  }
  return trimmed.replace(/[\r\n\t]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 200);
}

function formatUploadHttpError(status: number, serverMessage: string, contentRejected: boolean,
  quota?: NativeAttachmentQuota): string {
  if (quota?.kind === 'count') {
    return '上传失败：已上传文件数达到上限（' + quota.limit + ' 个），请清理历史文件后重试';
  }
  if (quota?.kind === 'storage') {
    return '上传失败：已上传文件占用空间达到上限（' + quota.limit + 'GB），请清理历史文件后重试';
  }
  if (contentRejected) {
    return serverMessage ? '上传失败：服务端无法解析该文件（' + serverMessage + '）' : '上传失败：服务端无法解析该文件';
  }
  if (status === 401) return '上传失败：API Key 无效或已过期（HTTP 401）';
  if (status === 402) return '上传失败：账户余额不足（HTTP 402）';
  if (status === 413) {
    return serverMessage ? '上传失败：文件体积超过服务端限制（HTTP 413）：' + serverMessage :
      '上传失败：文件体积超过服务端限制（HTTP 413）';
  }
  if (status === 429) return '上传失败：请求过于频繁（HTTP 429），请稍后再试';
  if (status >= 500) return '上传失败：服务器繁忙（HTTP ' + status.toString() + '），请稍后再试';
  return serverMessage ? '上传失败（HTTP ' + status.toString() + '）：' + serverMessage :
    '上传失败（HTTP ' + status.toString() + '）';
}

interface UploadFile {
  localPath: string;
  mimeType: string;
  name: string;
  temporary: boolean;
}

interface UploadData {
  id?: string;
}

interface AttachmentTransfer {
  config: NativeChatConfig;
  canceled: boolean;
  request?: http.HttpRequest;
  result?: Promise<string>;
}

interface AttachmentJob {
  run: () => Promise<string>;
  resolve: (serverId: string) => void;
  reject: (error: Error) => void;
}

const DIRECTORY = 'nuwa-attachments';
const ACCOUNT_ORIGIN = 'https://api.deepseek.com';
export const NATIVE_ATTACHMENT_MAX_COUNT = 50;
const MAX_BYTES = 64 * 1024 * 1024;
const IO_CHUNK = 256 * 1024;
const MAX_ACTIVE_UPLOADS = 3;
// The decoded RGBA surface can use four bytes per pixel. Convert one image at a time.
const MAX_UPLOAD_DECODE_PIXELS = 32 * 1024 * 1024;
const MAX_UPLOAD_DECODE_SIDE = 65536;
const MAX_IMAGE_UPLOAD_DIMENSION = 4096;
const API_SUPPORTED_UPLOAD_IMAGE_MIMES = ['image/jpeg', 'image/png', 'image/gif', 'image/webp'];
const EXIF_ORIENTATIONS = [
  'top-left', 'top-right', 'bottom-right', 'bottom-left', 'left-top', 'right-top', 'right-bottom', 'left-bottom',
];
const EXIF_ROTATIONS = [0, 0, 0, 180, 0, 270, 90, 90, 270];
const MAX_PREVIEW_SIDE = 8192;
const MAX_PREVIEW_PIXELS = 16 * 1024 * 1024;
const NATIVE_PREVIEW_MIMES = ['image/bmp', 'image/tiff', 'image/avif'];
const ARCHIVE_PREVIEW_MIMES = ['image/png', 'image/jpeg', 'image/gif', 'image/webp', ...NATIVE_PREVIEW_MIMES];
const BINARY_MIME = 'application/octet-stream';
const FILE_TYPES: Set<string> = new Set<string>([
  'wxml wxss wxs axml acss sjs swan ttml ttss qml qss pdf png jpg jpeg svg svgz bmp gif webp ico xbm dib',
  'pjp tif pjpeg avif apng tiff jfif txt md csv tsv html json log dot go h c cpp cxx cc cs java js css jsp',
  'php py py3 asp yaml yml ini conf ts tsx doc docx ppt pptx xls xlsx abap asc ash ampl mod g4 apib apl',
  'dyalog asax ascx ashx asmx aspx axd dats hats sats as adb ada ads agda als apacheconf vhost cls',
  'applescript scpt arc ino asciidoc adoc aj asm a51 inc nasm aug ahk ahkl au3 awk auk gawk mawk nawk bat',
  'cmd befunge bison bb decls bmx bsv boo b bf brs bro cats idc w cake cshtml csx c++ cp h++ hh hpp hxx inl',
  'ipp tcc tpp c-objdump chs clp cmake in cob cbl ccp cobol cpy capnp mss ceylon chpl ch ck cirru clw icl',
  'dcl click clj boot cl2 cljc cljs hl cljscm cljx hic coffee _coffee cjsx cjs cts mjs mts cson iced cfm',
  'cfml cfc lisp asd cl l lsp ny podsl sexp cps coq v cppobjdump c++-objdump c++objdump cpp-objdump',
  'cxx-objdump creole cr feature cu cuh cy pyx pxd pxi d di d-objdump com dm zone arpa darcspatch dpatch',
  'dart diff patch dockerfile djs dylan dyl intr lid E ecl eclxml sch brd epj e ex exs elm el emacs desktop',
  'em emberscript erl es escript hrl xrl yrl fs fsi fsx fx flux f90 f f03 f08 f77 f95 for fpp factor fy',
  'fancypack fan fth 4th forth fr frt ftl g gco gcode gms gap gd gi tst s ms glsl fp frag frg fsh fshader',
  'geo geom glslv gshader shader vert vrx vsh vshader gml kid ebuild eclass po pot glf gp gnu gnuplot plot',
  'plt golo gs gst gsx vark grace gradle gf graphql gv man 1in 1m 1x 3in 3m 3qt 3x me n rno roff groovy grt',
  'gtpl gvy gsp hcl tf hlsl fxh hlsli htm st xht xhtml mustache jinja eex erb deface phtml http haml',
  'handlebars hbs hb hs hsc hx hxsl hy pro dlm ipf cfg prefs properties irclog weechatlog idr lidr ni i7x',
  'iss io ik thy ijs flex jflex geojson lock topojson json5 jsonld jq jsx jade j _js bones es6 jake jsb',
  'jscad jsfl jsm jss njs pac ssjs sublime-build sublime-commands sublime-completions sublime-keymap',
  'sublime-macro sublime-menu sublime-mousemap sublime-project sublime-settings sublime-theme',
  'sublime-workspace sublime_metrics sublime_session xsjs xsjslib jl ipynb krl kicad_pcb kit kt ktm kts lfe',
  'll lol lsl lslp lvproj lasso las lasso8 lasso9 ldml latte lean hlean less lex ly ily m ld lds liquid',
  'lagda litcoffee lhs ls _ls xm x xi lgt logtalk lookml lua fcgi nse pd_lua rbxs wlua mumps m4 mcfunction',
  'mcr mtml muf mak mk mkfile mako mao markdown mkd mkdn mkdown ron mask mathematica cdf ma map mt nb nbp',
  'wl wlt matlab maxpat maxhelp maxproj mxt pat mediawiki wiki moo metal minid druby duby mir mirah mo mms',
  'mmk monkey moon myt ncl nl nsi nsh axs axi nlogo nginxconf nim nimrod ninja nit nix nu numpy numpyw',
  'numsc ml eliom eliomi ml4 mli mll mly objdump mm sj omgrofl opa opal opencl p scad org ox oxh oxo',
  'oxygene oz pwn aw ctp php3 php4 php5 php6 php7 php8 phps phpt pls pck pkb pks plb plsql sql pov pan psc',
  'parrot pasm pir pas dfm dpr lpr pp pl al cgi perl ph plx pm pod psgi t 6pl 6pm nqp p6 p6l p6m pl6 pm6',
  'pkl pig pike pmod pogo pony ps eps ps1 psd1 psm1 pde prolog yap spin proto pub pd pb pbi purs bzl gyp',
  'lmi pyde pyi pyp pyt pyw rpy tac wsgi xpy pytb qbs pri r rd rsx raml rdoc rbbas rbfrm rbmnu rbres rbtbar',
  'rbuistate rhtml rmd rkt rktd rktl scrbl rl raw reb r2 r3 rebol red reds cw rs rsh robot rg rb builder',
  'gemspec god irbrc jbuilder mspec pluginspec podspec rabl rake rbuild rbw rbx ru ruby thor watchr sas',
  'scss smt2 smt sparql rq sqf hqf cql ddl prc tab udf viw db2 ston sage sagews sls sass scala sbt sc scaml',
  'scm sld sps ss sci sce self sh bash bats command ksh tmux tool zsh sh-session shen sl slim smali tpl sp',
  'sma nut stan ML fun sig sml do ado doh ihlp mata matah sthlp styl scd swift sv svh vh toml txl tcl adp',
  'tm tcsh csh tex aux bbx bib cbx dtx ins lbx ltx mkii mkiv mkvi sty toc tea no textile thrift tu ttl twig',
  'upc anim asset meta prefab unity uno uc ur urs vcl vhdl vhd vhf vhi vho vhs vht vhw vala vapi veo vim vb',
  'bas frm frx vba vbhtml vbs volt vue owl webidl x10 xc xml ant ccxml clixml cproject csl csproj ct dita',
  'ditamap ditaval config dotsettings filters fsproj fxml glade grxml iml ivy jelly jsproj kml launch',
  'mdpolicy mxml nproj nuspec odd osm plist props ps1xml psc1 pt rdf rss scxml srdf storyboard stTheme',
  'sublime-snippet targets tmCommand tml tmLanguage tmPreferences tmSnippet tmTheme ui urdf ux vbproj',
  'vcxproj vssettings vxml wsdl wsf wxi wxl x3d xacro xaml xib xlf xliff xmi dist xproj xsd xul zcml',
  'xsp-config metadata xpl xproc xquery xq xql xqm xqy xs xslt xsl xojo_code xojo_menu xojo_report',
  'xojo_script xojo_toolbar xojo_window xtend reek rviz sublime-syntax syntax yang y yacc yy zep zimpl zmpl',
  'zpl ec eh edn fish mu nc ooc rst rest wisp prg prw gitignore gitkeep gitmodules example avifs blp bufr',
  'bw cur dcx dds emf fit fits flc fli ftc ftu gbr grib h5 hdf hif icb icns iim im j2c j2k jp2 jpc jpe jpf',
  'jpx mpeg mpg msp pbm pcd pcx pfm pgm pnm ppm psd pxr qoi ras rgb rgba sgi tga vda vst wmf xpm epub mobi',
].join(' ').split(' '));
const LAYOUT_TYPES: Set<string> = new Set<string>(['pdf', 'doc', 'docx', 'ppt', 'pptx']);

function extension(name: string): string {
  const dot = name.lastIndexOf('.');
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : '';
}

function directory(context: common.UIAbilityContext): string {
  return context.filesDir + '/' + DIRECTORY;
}

function attachmentPath(context: common.UIAbilityContext, item: NativeAttachment): string {
  if (!/^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/i.test(item.id)) {
    throw new Error('附件标识无效。');
  }
  return directory(context) + '/' + item.id;
}

function beginsWith(data: Uint8Array, prefix: number[]): boolean {
  return prefix.every((byte: number, index: number): boolean => data[index] === byte);
}

function sniffMime(data: Uint8Array): string {
  if (beginsWith(data, [0xff, 0xd8, 0xff])) {
    return 'image/jpeg';
  }
  if (beginsWith(data, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
    return 'image/png';
  }
  const header = String.fromCharCode(...Array.from(data));
  if (header.startsWith('GIF87a') || header.startsWith('GIF89a')) {
    return 'image/gif';
  }
  if (header.startsWith('RIFF') && header.slice(8, 12) === 'WEBP') {
    return 'image/webp';
  }
  if (header.startsWith('BM')) {
    return 'image/bmp';
  }
  if (beginsWith(data, [0x49, 0x49, 0x2a, 0]) || beginsWith(data, [0x4d, 0x4d, 0, 0x2a])) {
    return 'image/tiff';
  }
  if (header.slice(4, 8) === 'ftyp' && ['avif', 'avis'].includes(header.slice(8, 12))) {
    return 'image/avif';
  }
  return '';
}

export function attachmentUploadImageMime(header: Uint8Array): string {
  return sniffMime(header.subarray(0, 16));
}

function safeDimensions(width: number, height: number): boolean {
  return width > 0 && height > 0 && width <= MAX_PREVIEW_SIDE && height <= MAX_PREVIEW_SIDE &&
    width * height <= MAX_PREVIEW_PIXELS;
}

function safeJpeg(data: Uint8Array, view: DataView): boolean {
  let offset = 2;
  while (offset + 3 < data.length && data[offset] === 0xff) {
    while (offset < data.length && data[offset] === 0xff) {
      offset++;
    }
    const marker = data[offset++];
    if (marker === 0xda || marker === 0xd9 || offset + 2 > data.length) {
      return false;
    }
    const length = view.getUint16(offset);
    if (length < 2 || offset + length > data.length) {
      return false;
    }
    if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
      return length >= 8 && safeDimensions(view.getUint16(offset + 5), view.getUint16(offset + 3));
    }
    offset += length;
  }
  return false;
}

function safeWebP(data: Uint8Array, view: DataView): boolean {
  if (data.length < 25) {
    return false;
  }
  const type = String.fromCharCode(...Array.from(data.subarray(12, 16)));
  if (type === 'VP8L' && data[20] === 0x2f) {
    const size = view.getUint32(21, true);
    return safeDimensions((size & 0x3fff) + 1, ((size >>> 14) & 0x3fff) + 1);
  }
  if (data.length < 30) {
    return false;
  }
  if (type === 'VP8X') {
    const width = view.getUint16(24, true) + data[26] * 65_536 + 1;
    const height = view.getUint16(27, true) + data[29] * 65_536 + 1;
    return safeDimensions(width, height);
  }
  return type === 'VP8 ' && data[23] === 0x9d && data[24] === 1 && data[25] === 0x2a &&
    safeDimensions(view.getUint16(26, true) & 0x3fff, view.getUint16(28, true) & 0x3fff);
}

export function attachmentRasterMime(data: Uint8Array): string {
  const mime = sniffMime(data.subarray(0, 16));
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
  switch (mime) {
    case 'image/jpeg':
      return safeJpeg(data, view) ? mime : '';
    case 'image/png':
      return data.length >= 24 && view.getUint32(12) === 0x49484452 &&
        safeDimensions(view.getUint32(16), view.getUint32(20)) ? mime : '';
    case 'image/gif':
      return data.length >= 10 && safeDimensions(view.getUint16(6, true), view.getUint16(8, true)) ? mime : '';
    case 'image/webp':
      return safeWebP(data, view) ? mime : '';
    default:
      return '';
  }
}

export function isArchiveRasterPreviewMime(mime: string): boolean {
  return ARCHIVE_PREVIEW_MIMES.includes(mime);
}

export async function fileAttachmentRasterMime(path: string, header: Uint8Array): Promise<string> {
  const raster = attachmentRasterMime(header);
  if (raster) return raster;

  const mime = attachmentUploadImageMime(header);
  if (!NATIVE_PREVIEW_MIMES.includes(mime)) return '';
  let source: image.ImageSource | undefined;
  try {
    // Ask the device decoder for dimensions before showing less common archive formats.
    source = image.createImageSource(path);
    const size = (await source.getImageInfo()).size;
    if (!safeDimensions(size.width, size.height)) return '';
    if (mime === 'image/avif') {
      // Some devices can read AVIF metadata but lack the decoder needed for pixel output.
      const sample = await source.createPixelMap({ desiredSize: { width: 1, height: 1 } });
      await sample.release().catch(() => {});
    }
    return mime;
  } catch {
    return '';
  } finally {
    await source?.release().catch(() => {});
  }
}

async function avifDecodePath(originalPath: string): Promise<string> {
  const existing = existingNativeAvifPreview(originalPath);
  if (existing) return existing;
  try {
    const header = await withBackupInput<Uint8Array>(originalPath, (file: NativeBackupZipInput): Promise<Uint8Array> =>
      file.read(0, Math.min(16, file.size)));
    if (attachmentUploadImageMime(header) !== 'image/avif') return '';
    if (await fileAttachmentRasterMime(originalPath, header)) return originalPath;
    const preview = originalPath + NATIVE_AVIF_PREVIEW_SUFFIX;
    return await writeNativeAvifPreview(originalPath, preview) ? preview : '';
  } catch {
    return '';
  }
}

function extensionMime(ext: string): string {
  switch (ext) {
    case 'apng':
    case 'png': return 'image/png';
    case 'jpg':
    case 'jpeg':
    case 'jfif':
    case 'pjp':
    case 'pjpeg': return 'image/jpeg';
    case 'gif': return 'image/gif';
    case 'webp': return 'image/webp';
    case 'svg':
    case 'svgz': return 'image/svg+xml';
    case 'bmp':
    case 'dib': return 'image/bmp';
    case 'tif':
    case 'tiff': return 'image/tiff';
    case 'avif': return 'image/avif';
    case 'ico': return 'image/x-icon';
    case 'pdf': return 'application/pdf';
    default:
      try {
        const type = uniformTypeDescriptor.getUniformDataTypeByFilenameExtension('.' + ext);
        return uniformTypeDescriptor.getTypeDescriptor(type).mimeTypes[0] ?? BINARY_MIME;
      } catch {
        return BINARY_MIME;
      }
  }
}

export function attachmentMime(name: string): string {
  return extensionMime(extension(name));
}

export function attachmentPurpose(name: string, isImage: boolean): string | null {
  return isImage ? null : (LAYOUT_TYPES.has(extension(name)) ? 'rich_layout_recognition' : 'user_data');
}

function filesEndpoint(config: NativeChatConfig): string {
  if (config.accountToken?.trim()) {
    return ACCOUNT_ORIGIN + '/anthropic/v1/files';
  }
  let resolved: url.URL;
  try {
    resolved = url.URL.parseURL(config.baseUrl.trim());
  } catch {
    throw new Error('请输入有效的附件服务地址。');
  }
  if (resolved.protocol !== 'https:' || !resolved.hostname || resolved.username || resolved.password ||
    resolved.hash || resolved.search) {
    throw new Error('附件服务地址必须使用 HTTPS 且不包含凭据、查询或片段。');
  }
  const basePath = resolved.pathname.replace(/\/+$/, '').replace(/\/(?:anthropic(?:\/v1(?:\/(?:messages|files))?)?|v1)$/i, '');
  resolved.pathname = basePath + '/anthropic/v1/files';
  return resolved.href;
}

function sameDestination(first: NativeChatConfig, second: NativeChatConfig): boolean {
  const account = first.accountToken?.trim() ?? '';
  if (account || second.accountToken?.trim()) {
    return account === (second.accountToken?.trim() ?? '');
  }
  return first.protocol === second.protocol && first.baseUrl.trim() === second.baseUrl.trim() &&
    first.apiKey.trim() === second.apiKey.trim();
}

async function writeChunk(fd: number, bytes: ArrayBuffer): Promise<void> {
  let remaining = bytes;
  while (remaining.byteLength > 0) {
    const written = await fileIo.write(fd, remaining);
    if (written <= 0) {
      throw new Error('附件写入未完成。');
    }
    remaining = remaining.slice(written);
  }
}

async function copyOriginal(source: fileIo.File, destination: string, size: number, header: ArrayBuffer): Promise<void> {
  const target = await fileIo.open(destination,
    fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
  try {
    await writeChunk(target.fd, header);
    let copied = header.byteLength;
    while (copied < size) {
      const chunk = new ArrayBuffer(Math.min(IO_CHUNK, size - copied));
      const read = await fileIo.read(source.fd, chunk);
      if (read <= 0) {
        throw new Error('附件读取未完成。');
      }
      await writeChunk(target.fd, read === chunk.byteLength ? chunk : chunk.slice(0, read));
      copied += read;
    }
    if (await fileIo.read(source.fd, new ArrayBuffer(1)) !== 0) {
      throw new Error('附件内容在复制期间发生变化，请重新选择。');
    }
    await fileIo.fsync(target.fd);
  } finally {
    await fileIo.close(target);
  }
}

function rejectCanceled(transfer: AttachmentTransfer): void {
  if (transfer.canceled) {
    throw new Error('附件上传已取消。');
  }
}

let imageConversionQueue: Promise<void> = Promise.resolve();

function queueImageConversion(file: UploadFile, transfer: AttachmentTransfer): Promise<UploadFile> {
  const conversion = imageConversionQueue.then(async (): Promise<UploadFile> => {
    rejectCanceled(transfer);
    const cached = file.mimeType === 'image/avif' ? existingNativeAvifPreview(file.localPath) : '';
    const converted = await convertImage(file, cached || file.localPath);
    if (converted.temporary || cached || file.mimeType !== 'image/avif') return converted;
    rejectCanceled(transfer);
    const preview = file.localPath + NATIVE_AVIF_PREVIEW_SUFFIX;
    if (!await writeNativeAvifPreview(file.localPath, preview)) return file;
    rejectCanceled(transfer);
    return convertImage(file, preview);
  });
  imageConversionQueue = conversion.then((): void => {}, (): void => {});
  return conversion;
}

async function uploadOrientation(source: image.ImageSource, mimeType: string): Promise<number> {
  if (mimeType === 'image/tiff') {
    try {
      const metadata = await source.readImageMetadata(['TiffOrientation']);
      const orientation = metadata.tiffMetadata?.orientation ?? 1;
      if (orientation >= 5 && orientation <= 8) {
        // The TIFF codec has already applied the flips, leaving only an axis swap for these tags.
        return orientation % 2 ? 5 : 7;
      }
    } catch {
      // The TIFF metadata reader is available only on newer image runtimes.
    }
    return 1;
  }
  try {
    const tag = await source.getImageProperty(image.PropertyKey.ORIENTATION, { defaultValue: '' });
    const value = tag.trim().toLowerCase();
    const numeric = Number(value);
    if (Number.isInteger(numeric) && numeric >= 1 && numeric <= 8) return numeric;
    const named = EXIF_ORIENTATIONS.indexOf(value) + 1;
    if (named) return named;
  } catch {
    // The older EXIF API has limited codec support.
  }
  return 1;
}

async function orientUploadPixels(pixels: image.PixelMap, original: image.Size, orientation: number): Promise<void> {
  const rotation = EXIF_ROTATIONS[orientation] ?? 0;
  if ((rotation === 90 || rotation === 270) && original.width !== original.height) {
    const decoded = (await pixels.getImageInfo()).size;
    if (decoded.width === original.height && decoded.height === original.width) return;
  }
  const horizontal = orientation === 2 || orientation === 5 || orientation === 7;
  const vertical = orientation === 4;
  if (horizontal || vertical) await pixels.flip(horizontal, vertical);
  if (rotation) await pixels.rotate(rotation);
}

async function convertImage(file: UploadFile, sourcePath: string): Promise<UploadFile> {
  const path = file.localPath + '.' + util.generateRandomUUID(true) + '.upload';
  let source: image.ImageSource | undefined;
  let pixels: image.PixelMap | undefined;
  let packer: image.ImagePacker | undefined;
  try {
    source = image.createImageSource(sourcePath);
    const size = (await source.getImageInfo()).size;
    if (!Number.isSafeInteger(size.width) || !Number.isSafeInteger(size.height) ||
      size.width < 1 || size.height < 1 || Math.max(size.width, size.height) > MAX_UPLOAD_DECODE_SIDE) {
      return file;
    }
    const formatSupported = API_SUPPORTED_UPLOAD_IMAGE_MIMES.includes(file.mimeType);
    const needsResize = size.width > MAX_IMAGE_UPLOAD_DIMENSION || size.height > MAX_IMAGE_UPLOAD_DIMENSION;
    if (formatSupported && !needsResize) {
      return file;
    }
    const scale = needsResize ? MAX_IMAGE_UPLOAD_DIMENSION / Math.max(size.width, size.height) : 1;
    const targetW = Math.max(1, Math.floor(size.width * scale));
    const targetH = Math.max(1, Math.floor(size.height * scale));
    if (targetW * targetH > MAX_UPLOAD_DECODE_PIXELS) {
      return file;
    }
    const orientation = sourcePath === file.localPath ? await uploadOrientation(source, file.mimeType) : 1;
    const decodingOptions: image.DecodingOptions = needsResize
      ? { editable: orientation > 1, desiredSize: { width: targetW, height: targetH } }
      : { editable: orientation > 1 };
    pixels = await source.createPixelMap(decodingOptions);
    if (orientation > 1) await orientUploadPixels(pixels, { width: targetW, height: targetH }, orientation);
    packer = image.createImagePacker();
    const out = await fileIo.open(path, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      await packer.packToFile(pixels, out.fd, { format: 'image/jpeg', quality: 92 });
    } finally {
      await fileIo.close(out);
    }
    const encodedSize = (await fileIo.stat(path)).size;
    if (!encodedSize || encodedSize > MAX_BYTES) {
      throw new Error('图片转换大小无效。');
    }
    const dot = file.name.lastIndexOf('.');
    return {
      localPath: path, mimeType: 'image/jpeg', name: (dot > 0 ? file.name.slice(0, dot) : file.name) + '.jpg',
      temporary: true,
    };
  } catch {
    await fileIo.unlink(path).catch(() => {});
    return file;
  } finally {
    await pixels?.release().catch(() => {});
    await source?.release().catch(() => {});
    await packer?.release().catch(() => {});
  }
}

export class NativeChatAttachments {
  private readonly transfers: Map<string, AttachmentTransfer> = new Map<string, AttachmentTransfer>();
  private readonly jobs: AttachmentJob[] = [];
  private active = 0;

  async pick(context: common.UIAbilityContext, existingCount: number): Promise<NativeAttachment[]> {
    if (existingCount >= NATIVE_ATTACHMENT_MAX_COUNT) {
      throw new NativeAttachmentValidationError('count', NATIVE_ATTACHMENT_MAX_COUNT);
    }
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = NATIVE_ATTACHMENT_MAX_COUNT - existingCount;
    const uris = await new picker.DocumentViewPicker(context).select(options);
    return this.importUris(context, uris, existingCount);
  }

  async importUris(context: common.UIAbilityContext, uris: string[], existingCount: number): Promise<NativeAttachment[]> {
    return this.importAttachments(context, uris, [], existingCount);
  }

  async importClipboard(context: common.UIAbilityContext, clipboard: NativeClipboardAttachments,
    existingCount: number): Promise<NativeAttachment[]> {
    return this.importAttachments(context, clipboard.uris, clipboard.pixelMaps, existingCount);
  }

  private async importAttachments(context: common.UIAbilityContext, uris: string[], pixelMaps: image.PixelMap[],
    existingCount: number): Promise<NativeAttachment[]> {
    const count = uris.length + pixelMaps.length;
    if (count + existingCount > NATIVE_ATTACHMENT_MAX_COUNT) {
      throw new NativeAttachmentValidationError('count', NATIVE_ATTACHMENT_MAX_COUNT);
    }
    if (count === 0) {
      return [];
    }
    await ensureNativeDirectory(directory(context));
    const attachments: NativeAttachment[] = [];
    try {
      for (const uri of uris) {
        attachments.push(await this.saveSelected(context, uri));
      }
      for (const bitmap of pixelMaps) {
        attachments.push(await this.saveClipboardImage(context, bitmap));
      }
      return attachments;
    } catch (error) {
      await Promise.all(attachments.map((item: NativeAttachment): Promise<void> =>
        this.remove(context, item).catch(() => {})));
      throw error as Error;
    }
  }

  private async saveClipboardImage(context: common.UIAbilityContext, bitmap: image.PixelMap): Promise<NativeAttachment> {
    const rawSize = bitmap.getPixelBytesNumber();
    if (!Number.isSafeInteger(rawSize) || rawSize <= 0) {
      throw new Error('无法读取剪贴板图片。');
    }
    const path = context.cacheDir + '/clipboard-' + util.generateRandomUUID(true) + '.png';
    let packer: image.ImagePacker | undefined;
    try {
      packer = image.createImagePacker();
      const staged = await fileIo.open(path, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        await packer.packToFile(bitmap, staged.fd, { format: 'image/png', quality: 100 });
      } finally {
        await fileIo.close(staged);
      }
      const item = await this.saveSelected(context, path);
      item.name = 'clipboard.png';
      return item;
    } finally {
      await fileIo.unlink(path).catch(() => {});
      await packer?.release().catch(() => {});
    }
  }

  private async saveSelected(context: common.UIAbilityContext, uri: string): Promise<NativeAttachment> {
    const source = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const name = source.name;
      const ext = extension(name);
      if (!FILE_TYPES.has(ext)) {
        throw new NativeAttachmentValidationError('format');
      }
      const stat = await fileIo.stat(source.fd);
      if (!stat.isFile() || stat.size < 0) {
        throw new NativeAttachmentValidationError('unreadable');
      }
      const header = new ArrayBuffer(Math.min(16, stat.size));
      let length = 0;
      if (header.byteLength > 0) {
        length = await fileIo.read(source.fd, header);
      }
      const sniffed = sniffMime(new Uint8Array(header, 0, length));
      const mimeType = sniffed || extensionMime(ext);
      const isImage = mimeType.startsWith('image/');
      const purpose = attachmentPurpose(name, isImage);
      const limit = purpose === 'user_data' ? MAX_BYTES / 2 : MAX_BYTES;
      if (stat.size > limit) {
        throw new NativeAttachmentValidationError('size', limit / (1024 * 1024));
      }
      const attachment: NativeAttachment = {
        id: util.generateRandomUUID(true), name: name, size: stat.size, isImage: isImage, mimeType: mimeType,
        purpose: purpose, createdAt: Date.now(), serverId: null, local: true,
      };
      const path = attachmentPath(context, attachment);
      try {
        await copyOriginal(source, path, stat.size, header.slice(0, length));
      } catch (error) {
        await fileIo.unlink(path).catch(() => {});
        throw error as Error;
      }
      if (mimeType === 'image/avif' && await avifDecodePath(path) === path) {
        attachment.nativeAvifPreview = true;
      }
      return attachment;
    } finally {
      await fileIo.close(source);
    }
  }

  originalPath(context: common.UIAbilityContext, item: NativeAttachment): string {
    return item.local ? attachmentPath(context, item) : '';
  }

  originalUri(context: common.UIAbilityContext, item: NativeAttachment): string {
    const path = this.originalPath(context, item);
    return path ? fileUri.getUriFromPath(path) : '';
  }

  previewUri(context: common.UIAbilityContext, item: NativeAttachment): string {
    if (!item.local) return '';
    if (item.mimeType !== 'image/avif' || item.nativeAvifPreview) return this.originalUri(context, item);
    const preview = existingNativeAvifPreview(attachmentPath(context, item));
    return preview ? fileUri.getUriFromPath(preview) : '';
  }

  async resolveAvifPreview(context: common.UIAbilityContext, item: NativeAttachment): Promise<string> {
    const preview = await avifDecodePath(attachmentPath(context, item));
    return preview ? fileUri.getUriFromPath(preview) : '';
  }

  async storeOriginal(context: common.UIAbilityContext, item: NativeAttachment, source: NativeBackupZipInput,
    mimeType: string, expectedChecksum?: number): Promise<NativeAttachment> {
    if (!Number.isSafeInteger(source.size) || source.size <= 0) {
      throw new Error('本地附件大小无效。');
    }
    await ensureBackupSpace(context.filesDir, source.size);
    const stored: NativeAttachment = {
      id: util.generateRandomUUID(true),
      archiveId: item.archiveId ?? item.id,
      name: item.name,
      size: source.size,
      isImage: item.isImage,
      mimeType: mimeType,
      purpose: item.purpose,
      createdAt: item.createdAt,
      serverId: null,
      local: true,
    };
    const crc = expectedChecksum === undefined ? undefined : await zlib.createChecksum();
    await ensureNativeDirectory(directory(context));
    const path = attachmentPath(context, stored);
    const target = await fileIo.open(path, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    try {
      try {
        let checksum = 0;
        for (let offset = 0; offset < source.size; offset += IO_CHUNK) {
          const length = Math.min(IO_CHUNK, source.size - offset);
          const chunk = await source.read(offset, length);
          if (chunk.byteLength !== length) {
            throw new Error('图片原件读取未完成。');
          }
          const bytes = chunk.buffer.slice(chunk.byteOffset, chunk.byteOffset + length) as ArrayBuffer;
          if (crc) checksum = (await crc.crc32(checksum, bytes)) >>> 0;
          await writeChunk(target.fd, bytes);
        }
        if (expectedChecksum !== undefined && checksum !== expectedChecksum) {
          throw new Error('图片原件校验失败。');
        }
        await fileIo.fsync(target.fd);
      } finally {
        await fileIo.close(target);
      }
    } catch (error) {
      await fileIo.unlink(path).catch(() => {});
      throw error as Error;
    }
    return stored;
  }

  async readOriginal(context: common.UIAbilityContext, item: NativeAttachment): Promise<Uint8Array | null> {
    if (!item.local) {
      return null;
    }
    const file = await fileIo.open(attachmentPath(context, item), fileIo.OpenMode.READ_ONLY);
    try {
      if (item.size > MAX_BYTES || (await fileIo.stat(file.fd)).size !== item.size) {
        throw new Error('本地附件大小无效。');
      }
      const result = new Uint8Array(item.size);
      let offset = 0;
      while (offset < result.length) {
        const chunk = new ArrayBuffer(Math.min(IO_CHUNK, result.length - offset));
        const read = await fileIo.read(file.fd, chunk);
        if (read <= 0) {
          throw new Error('本地附件读取未完成。');
        }
        result.set(new Uint8Array(chunk, 0, read), offset);
        offset += read;
      }
      return result;
    } finally {
      await fileIo.close(file);
    }
  }

  async encodeImageDataUrl(context: common.UIAbilityContext, item: NativeAttachment): Promise<string | null> {
    if (!item.local || !item.isImage) {
      return null;
    }
    const maxInlineBytes = 20 * 1024 * 1024;
    const dummyConfig: NativeChatConfig = { baseUrl: '', apiKey: '', model: '' };
    const transfer: AttachmentTransfer = { config: dummyConfig, canceled: false };
    let file: UploadFile = {
      localPath: attachmentPath(context, item),
      mimeType: item.mimeType || 'image/jpeg',
      name: item.name,
      temporary: false,
    };
    try {
      file = await queueImageConversion(file, transfer);
      const handle = await fileIo.open(file.localPath, fileIo.OpenMode.READ_ONLY);
      try {
        const size = (await fileIo.stat(handle.fd)).size;
        if (size <= 0 || size > maxInlineBytes) {
          return null;
        }
        const bytes = new Uint8Array(size);
        let offset = 0;
        while (offset < size) {
          const chunk = new ArrayBuffer(Math.min(IO_CHUNK, size - offset));
          const read = await fileIo.read(handle.fd, chunk);
          if (read <= 0) {
            return null;
          }
          bytes.set(new Uint8Array(chunk, 0, read), offset);
          offset += read;
        }
        const mime = file.mimeType || 'image/jpeg';
        const encoded = new util.Base64Helper().encodeToStringSync(bytes);
        return `data:${mime};base64,${encoded}`;
      } finally {
        await fileIo.close(handle);
      }
    } catch {
      return null;
    } finally {
      if (file.temporary) {
        await fileIo.unlink(file.localPath).catch(() => {});
      }
    }
  }

  async remove(context: common.UIAbilityContext, item: NativeAttachment): Promise<void> {
    this.cancelUpload(item.id);
    if (item.local) {
      const path = attachmentPath(context, item);
      try {
        await fileIo.unlink(path);
      } finally {
        if (item.mimeType === 'image/avif') await fileIo.unlink(path + NATIVE_AVIF_PREVIEW_SUFFIX).catch(() => {});
      }
    }
  }

  upload(context: common.UIAbilityContext, config: NativeChatConfig, item: NativeAttachment): Promise<string> {
    if (!item.local) {
      return Promise.reject(new NativeAttachmentUploadError('找不到附件原件。', false));
    }
    const previous = this.transfers.get(item.id);
    if (previous?.result && !previous.canceled && sameDestination(previous.config, config)) {
      return previous.result;
    }
    this.cancelUpload(item.id);
    const transfer: AttachmentTransfer = { config: config, canceled: false };
    this.transfers.set(item.id, transfer);
    const result = new Promise<string>((resolve, reject) => {
      this.jobs.push({
        run: async (): Promise<string> => {
          try {
            return await this.uploadSelected(context, config, item, transfer);
          } finally {
            if (this.transfers.get(item.id) === transfer) {
              this.transfers.delete(item.id);
            }
          }
        },
        resolve: resolve,
        reject: reject,
      });
      this.runUploads();
    });
    transfer.result = result;
    return result;
  }

  cancelUpload(id: string): void {
    const transfer = this.transfers.get(id);
    if (transfer) {
      transfer.canceled = true;
      transfer.request?.destroy();
      transfer.request = undefined;
    }
  }

  private runUploads(): void {
    while (this.active < MAX_ACTIVE_UPLOADS && this.jobs.length > 0) {
      const job = this.jobs.shift();
      if (!job) {
        return;
      }
      this.active++;
      void job.run().then(job.resolve, job.reject).finally(() => {
        this.active--;
        this.runUploads();
      });
    }
  }

  private async uploadSelected(context: common.UIAbilityContext, config: NativeChatConfig, item: NativeAttachment,
    transfer: AttachmentTransfer): Promise<string> {
    rejectCanceled(transfer);
    const account = config.accountToken?.trim() ?? '';
    const apiKey = config.apiKey.trim();
    if (!account && (!apiKey || config.protocol !== 'anthropic')) {
      throw new NativeAttachmentUploadError('请登录 DeepSeek 账号或配置支持 Anthropic 文件接口的服务。', false);
    }
    if (/[\r\n]/.test(account || apiKey)) {
      throw new NativeAttachmentUploadError('凭据不能包含换行。', false);
    }
    const endpoint = filesEndpoint(config);
    let file: UploadFile = {
      localPath: attachmentPath(context, item),
      mimeType: item.mimeType || BINARY_MIME,
      name: item.name.replace(/[\u0000-\u001f\u007f\\/"]/g, '_'),
      temporary: false,
    };
    if (item.isImage) {
      file = await queueImageConversion(file, transfer);
    }
    try {
      rejectCanceled(transfer);
      const fields: http.MultiFormData[] = [];
      if (item.purpose) {
        fields.push({ name: 'purpose', contentType: 'text/plain', data: item.purpose });
      }
      fields.push({ name: 'file', contentType: file.mimeType, remoteFileName: file.name, filePath: file.localPath });
      const header: Record<string, string> = {
        'content-type': 'multipart/form-data', 'anthropic-beta': 'files-api-2025-04-14', 'accept': 'application/json',
      };
      if (account) {
        header['x-dsh-auth-token'] = account;
      } else {
        header['x-api-key'] = apiKey;
      }
      const request = http.createHttp();
      transfer.request = request;
      const response = await request.request(endpoint, {
        method: http.RequestMethod.POST, header: header, multiFormDataList: fields,
        expectDataType: http.HttpDataType.STRING, usingCache: false, maxRedirects: 0,
        connectTimeout: 15000, readTimeout: 300000,
      });
      rejectCanceled(transfer);
      const status = response.responseCode;
      if (status < 200 || status >= 300) {
        const rawBody = typeof response.result === 'string' ? response.result : '';
        const serverMessage = extractUploadErrorMessage(rawBody);
        const contentRejected = status === 400 && !!rawBody && rejectedAttachmentContents(rawBody);
        const quota = status === 400 && rawBody ? attachmentQuota(rawBody) : undefined;
        const detail = formatUploadHttpError(status, serverMessage, contentRejected, quota);
        void recordNativeFeedbackLog(context, 'error', 'api.upload',
          'POST /files -> HTTP ' + status.toString(), serverMessage || rawBody.slice(0, 400));
        throw new NativeAttachmentUploadError(detail,
          status === 429 || status >= 500, status >= 100 && status <= 599 ? status : undefined, contentRejected,
          quota);
      }
      let payload: UploadData;
      try {
        payload = JSON.parse(typeof response.result === 'string' ? response.result : '') as UploadData;
      } catch {
        throw new NativeAttachmentUploadError('附件服务返回的响应格式无效。', true);
      }
      if (typeof payload?.id !== 'string' || !payload.id) {
        throw new NativeAttachmentUploadError('附件服务未返回文件 ID。', true);
      }
      return payload.id;
    } catch (error) {
      rejectCanceled(transfer);
      if (!(error instanceof NativeAttachmentUploadError)) {
        const errMsg = error instanceof Error ? error.message : String(error);
        void recordNativeFeedbackLog(context, 'error', 'api.upload',
          'POST /files failed (' + file.name + ')', errMsg);
      }
      throw error as Error;
    } finally {
      transfer.request?.destroy();
      transfer.request = undefined;
      if (file.temporary) {
        await fileIo.unlink(file.localPath).catch(() => {});
      }
    }
  }
}
