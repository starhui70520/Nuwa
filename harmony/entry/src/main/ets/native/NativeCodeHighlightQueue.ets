import { MessageEvents, worker } from '@kit.ArkTS';
import { isHarmonyLowPerfDevice } from './NativeDevicePerf';

export interface NativeCodeHighlightRequest {
  id: number;
  language: string;
  source: string;
}

export interface NativeCodeHighlightReply {
  id: number;
  payload: string;
}

export interface NativeCodeHighlightRun {
  end: number;
  lightColor: string;
  darkColor: string;
  lightFlags: number;
  darkFlags: number;
}

interface HighlightJob {
  key: string;
  request: NativeCodeHighlightRequest;
  promise: Promise<NativeCodeHighlightRun[] | null>;
  resolve: (runs: NativeCodeHighlightRun[] | null) => void;
}

interface CachedHighlight {
  runs: NativeCodeHighlightRun[] | null;
  cost: number;
}

const WORKER = 'entry/ets/workers/NativeCodeHighlightWorker.ets';
const MAX_SOURCE = 32_768;
const MAX_RUNS = 8192;
const MAX_QUEUE = 24;
const MAX_CACHE = 640_000;
const LOW_PERF_MAX_CACHE = 240_000;
const JOB_TIMEOUT = 2500;
const IDLE_TIMEOUT = 45_000;
const LOW_PERF_IDLE_TIMEOUT = 20_000;
const cache = new Map<string, CachedHighlight>();
const pending = new Map<string, HighlightJob>();
const waiting: HighlightJob[] = [];
let current: HighlightJob | undefined;
let thread: worker.ThreadWorker | undefined;
let sequence = 0;
let cost = 0;
let jobTimer = -1;
let idleTimer = -1;

export function nativeCodeHighlightKey(language: string, source: string): string {
  return language.length.toString() + ':' + language + source;
}

/** 释放代码高亮缓存并回收空闲 Worker（低内存告警时调用）。 */
export function clearNativeCodeHighlightCache(): void {
  cache.clear();
  cost = 0;
  if (!current && waiting.length === 0) {
    stopWorker();
  }
}

function remember(job: HighlightJob, runs: NativeCodeHighlightRun[] | null): void {
  const entry: CachedHighlight = { runs: runs, cost: job.key.length + (runs?.length ?? 0) * 40 };
  cache.set(job.key, entry);
  cost += entry.cost;
  const maxCache = isHarmonyLowPerfDevice() ? LOW_PERF_MAX_CACHE : MAX_CACHE;
  while (cost > maxCache) {
    const first = cache.keys().next();
    if (first.done) break;
    const oldest = cache.get(first.value);
    cache.delete(first.value);
    cost -= oldest?.cost ?? 0;
  }
}

function settle(job: HighlightJob, runs: NativeCodeHighlightRun[] | null, cacheable: boolean): void {
  pending.delete(job.key);
  if (cacheable) remember(job, runs);
  job.resolve(runs);
}

function stopWorker(): void {
  const old = thread;
  thread = undefined;
  clearTimeout(idleTimer);
  clearTimeout(jobTimer);
  try {
    old?.terminate();
  } catch {
    // Exiting workers may already have closed the underlying port.
  }
}

function failWorker(): void {
  stopWorker();
  const active = current;
  current = undefined;
  if (active) settle(active, null, true);
  for (const job of waiting.splice(0)) settle(job, null, false);
}

function validColor(value: string): boolean {
  return typeof value === 'string' && (value === '' || /^#(?:[\da-f]{6}|[\da-f]{8})$/i.test(value));
}

function parseRuns(payload: string, length: number): NativeCodeHighlightRun[] | null {
  if (typeof payload !== 'string' || !payload || payload.length > MAX_RUNS * 120) return null;
  try {
    const runs = JSON.parse(payload) as NativeCodeHighlightRun[];
    if (!Array.isArray(runs) || runs.length > MAX_RUNS) return null;
    let end = 0;
    for (const run of runs) {
      if (!run || !Number.isInteger(run.end) || run.end <= end || run.end > length ||
        !validColor(run.lightColor) || !validColor(run.darkColor) ||
        !Number.isInteger(run.lightFlags) || run.lightFlags < 0 || run.lightFlags > 3 ||
        !Number.isInteger(run.darkFlags) || run.darkFlags < 0 || run.darkFlags > 3) {
        return null;
      }
      end = run.end;
    }
    return end === length ? runs : null;
  } catch {
    return null;
  }
}

function startWorker(): worker.ThreadWorker {
  const instance = new worker.ThreadWorker(WORKER, { name: 'NuwaCodeHighlight' });
  thread = instance;
  instance.onmessage = (event: MessageEvents): void => {
    const reply = event.data as NativeCodeHighlightReply;
    const active = current;
    if (thread !== instance || !active || reply?.id !== active.request.id) return;
    clearTimeout(jobTimer);
    current = undefined;
    settle(active, parseRuns(reply.payload, active.request.source.length), true);
    drain();
  };
  instance.onerror = (): void => { if (thread === instance) failWorker(); };
  instance.onmessageerror = (): void => { if (thread === instance) failWorker(); };
  instance.onexit = (): void => { if (thread === instance) failWorker(); };
  return instance;
}

function drain(): void {
  if (current) return;
  clearTimeout(idleTimer);
  const next = waiting.shift();
  if (!next) {
    if (thread) {
      idleTimer = setTimeout((): void => { stopWorker(); },
        isHarmonyLowPerfDevice() ? LOW_PERF_IDLE_TIMEOUT : IDLE_TIMEOUT);
    }
    return;
  }
  current = next;
  try {
    const port = thread ?? startWorker();
    jobTimer = setTimeout((): void => { failWorker(); }, JOB_TIMEOUT);
    port.postMessage(next.request);
  } catch {
    failWorker();
  }
}

export function requestNativeCodeHighlight(language: string, source: string): Promise<NativeCodeHighlightRun[] | null> {
  if (!source || source.length > MAX_SOURCE || language.length > 48 || language === 'text' || language === 'plaintext') {
    return Promise.resolve(null);
  }
  const key = nativeCodeHighlightKey(language, source);
  const cached = cache.get(key);
  if (cached) {
    cache.delete(key);
    cache.set(key, cached);
    return Promise.resolve(cached.runs);
  }
  const existing = pending.get(key);
  if (existing) return existing.promise;
  if (pending.size >= MAX_QUEUE) return Promise.resolve(null);

  let resolve = (_runs: NativeCodeHighlightRun[] | null): void => {};
  const promise = new Promise<NativeCodeHighlightRun[] | null>((settleResult): void => {
    resolve = settleResult;
  });
  const job: HighlightJob = {
    key: key, request: { id: ++sequence, language: language, source: source },
    promise: promise, resolve: resolve,
  };
  pending.set(key, job);
  waiting.push(job);
  drain();
  return promise;
}
