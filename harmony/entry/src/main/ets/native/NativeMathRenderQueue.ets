export interface NativeMathPictureRequest {
  source: string;
  display: boolean;
  fontSize: number;
  color: string;
  density: number;
  bold: boolean;
}

export interface NativeMathPicture {
  png: string;
  width: number;
  height: number;
  depth: number;
}

export interface NativeMathPictureJob {
  key: string;
  request: NativeMathPictureRequest;
  complete: (picture: NativeMathPicture | null) => void;
  promise: Promise<NativeMathPicture | null>;
}

interface CachedMathPicture {
  picture: NativeMathPicture | null;
  cost: number;
}

// Two million UTF-16 code units is a conservative four MiB payload budget.
const MAX_CACHE_COST = 2_000_000;
const MAX_QUEUED = 128;
const cache = new Map<string, CachedMathPicture>();
const pending = new Map<string, NativeMathPictureJob>();
let waiting: NativeMathPictureJob[] = [];
let cacheCost = 0;
let notifyHost: (() => void) | undefined;

export function nativeMathPictureKey(request: NativeMathPictureRequest): string {
  return JSON.stringify([request.source, request.display, request.fontSize, request.color, request.density, request.bold]);
}

function cacheResult(key: string, picture: NativeMathPicture | null): void {
  const old = cache.get(key);
  if (old) cacheCost -= old.cost;
  cache.delete(key);
  const cost = (picture?.png.length ?? 0) + key.length + 128;
  cache.set(key, { picture, cost });
  cacheCost += cost;
  while (cacheCost > MAX_CACHE_COST) {
    const oldest = cache.keys().next();
    if (oldest.done) break;
    cacheCost -= cache.get(oldest.value)?.cost ?? 0;
    cache.delete(oldest.value);
  }
}

export function subscribeNativeMathHost(notify: () => void): () => void {
  notifyHost = notify;
  if (waiting.length) notify();
  return (): void => {
    if (notifyHost !== notify) return;
    notifyHost = undefined;
    closeNativeMathJobs();
  };
}

export function closeNativeMathJobs(): void {
  for (const job of pending.values()) job.complete(null);
  pending.clear();
  waiting = [];
}

export function nextNativeMathJob(): NativeMathPictureJob | undefined {
  return waiting.shift();
}

export function completeNativeMathJob(job: NativeMathPictureJob, picture: NativeMathPicture | null, cacheable: boolean): void {
  if (pending.get(job.key) !== job) return;
  pending.delete(job.key);
  if (cacheable) cacheResult(job.key, picture);
  job.complete(picture);
}

export function requestNativeMathPicture(request: NativeMathPictureRequest): Promise<NativeMathPicture | null> {
  const key = nativeMathPictureKey(request);
  const cached = cache.get(key);
  if (cached) {
    cache.delete(key);
    cache.set(key, cached);
    return Promise.resolve(cached.picture);
  }
  const inflight = pending.get(key);
  if (inflight) return inflight.promise;
  if (!notifyHost || pending.size >= MAX_QUEUED || request.source.length > 2048) return Promise.resolve(null);
  let complete = (_picture: NativeMathPicture | null): void => {};
  const promise = new Promise<NativeMathPicture | null>((resolve): void => {
    complete = (picture: NativeMathPicture | null): void => { resolve(picture); };
  });
  const job: NativeMathPictureJob = { key, request, complete, promise };
  pending.set(key, job);
  waiting.push(job);
  notifyHost();
  return promise;
}
