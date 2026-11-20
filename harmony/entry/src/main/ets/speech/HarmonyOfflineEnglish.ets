import { common, sendableContextManager } from '@kit.AbilityKit';
import { MessageEvents, worker } from '@kit.ArkTS';
import { HarmonyOfflineEnglishCommand, HarmonyOfflineEnglishReply } from './HarmonyOfflineEnglishMessages';
import { HARMONY_ASR_MAX_BYTES, HARMONY_ASR_SAMPLE_RATE } from './HarmonySpeechWav';

const WORKER_PATH = 'entry/ets/workers/HarmonyOfflineEnglishWorker.ets';
const FRAME_BYTES = HARMONY_ASR_SAMPLE_RATE; // Half a second of signed 16-bit audio.
const MODEL_START_TIMEOUT_MS = 20_000;
const RESULT_TIMEOUT_MS = 30_000;

class EnglishSession {
  readonly thread: worker.ThreadWorker;
  state: 'opening' | 'ready' | 'finishing' = 'opening';
  frame: ArrayBuffer = new ArrayBuffer(FRAME_BYTES);
  frameLength: number = 0;
  bytesAccepted: number = 0;
  timeout: number = -1;
  resolveOpen?: () => void;
  rejectOpen?: (error: Error) => void;
  finishPromise?: Promise<string>;
  resolveFinish?: (text: string) => void;
  rejectFinish?: (error: Error) => void;

  constructor(thread: worker.ThreadWorker) {
    this.thread = thread;
  }
}

/** Streaming on-device dictation. The caller owns microphone permission and capture. */
export class HarmonyOfflineEnglish {
  private session?: EnglishSession;
  private failure?: Error;
  private result?: string;

  open(context: common.UIAbilityContext): Promise<void> {
    this.cancel();
    return new Promise<void>((resolve, reject) => {
      let session: EnglishSession;
      try {
        session = new EnglishSession(new worker.ThreadWorker(WORKER_PATH));
      } catch {
        reject(new Error('Unable to start the offline English worker.'));
        return;
      }
      this.session = session;
      session.resolveOpen = resolve;
      session.rejectOpen = reject;
      session.timeout = setTimeout((): void => {
        this.fail(session, 'Offline English model initialization timed out.');
      }, MODEL_START_TIMEOUT_MS);
      session.thread.onmessage = (event: MessageEvents): void => {
        this.receive(session, event.data as HarmonyOfflineEnglishReply);
      };
      session.thread.onerror = (): void => { this.fail(session, 'Offline English worker failed.'); };
      session.thread.onmessageerror = (): void => { this.fail(session, 'Offline English worker message failed.'); };
      session.thread.onexit = (): void => { this.fail(session, 'Offline English worker stopped unexpectedly.'); };

      try {
        const command: HarmonyOfflineEnglishCommand = {
          type: 'open', context: sendableContextManager.convertFromContext(context),
        };
        session.thread.postMessageWithSharedSendable(command);
      } catch {
        this.fail(session, 'Unable to initialize offline English recognition.');
      }
    });
  }

  write(data: ArrayBuffer): void {
    const session = this.session;
    if (!session || session.state !== 'ready') {
      return;
    }
    // Copy only the accepted bytes. The capture callback may reuse its buffer after returning.
    const audio = new Uint8Array(data, 0, Math.min(data.byteLength, HARMONY_ASR_MAX_BYTES - session.bytesAccepted));
    let offset = 0;
    try {
      while (offset < audio.length) {
        const length = Math.min(audio.length - offset, FRAME_BYTES - session.frameLength);
        new Uint8Array(session.frame).set(audio.subarray(offset, offset + length), session.frameLength);
        offset += length;
        session.frameLength += length;
        session.bytesAccepted += length;
        if (session.frameLength === FRAME_BYTES) {
          this.sendFrame(session, FRAME_BYTES);
        }
      }
    } catch {
      this.fail(session, 'Unable to send audio to offline English recognition.');
    }
  }

  finish(): Promise<string> {
    const session = this.session;
    if (!session) {
      return this.result !== undefined ? Promise.resolve(this.result) :
        Promise.reject(this.failure ?? new Error('Offline English recognition is not open.'));
    }
    if (session.finishPromise) {
      return session.finishPromise;
    }
    if (session.state !== 'ready') {
      return Promise.reject(new Error('Offline English recognition is not ready.'));
    }
    session.state = 'finishing';
    const promise = new Promise<string>((resolve, reject) => {
      session.resolveFinish = resolve;
      session.rejectFinish = reject;
    });
    session.finishPromise = promise;
    session.timeout = setTimeout((): void => {
      this.fail(session, 'Offline English transcription timed out.');
    }, RESULT_TIMEOUT_MS);
    try {
      // An incomplete final PCM sample cannot be decoded.
      const length = session.frameLength - session.frameLength % 2;
      if (length > 0) {
        this.sendFrame(session, length);
      }
      const command: HarmonyOfflineEnglishCommand = { type: 'finish' };
      session.thread.postMessage(command);
    } catch {
      this.fail(session, 'Unable to finish offline English recognition.');
    }
    return promise;
  }

  cancel(): void {
    const session = this.session;
    this.failure = undefined;
    this.result = undefined;
    if (session) {
      this.close(session);
      const error = new Error('Offline English recognition was cancelled.');
      session.rejectOpen?.(error);
      session.rejectFinish?.(error);
    }
  }

  private sendFrame(session: EnglishSession, length: number): void {
    const pcm = length === FRAME_BYTES ? session.frame : session.frame.slice(0, length);
    session.frame = new ArrayBuffer(FRAME_BYTES);
    session.frameLength = 0;
    const command: HarmonyOfflineEnglishCommand = { type: 'audio', pcm: pcm };
    session.thread.postMessage(command, [pcm]);
  }

  private receive(session: EnglishSession, reply: HarmonyOfflineEnglishReply): void {
    if (this.session !== session) {
      return;
    }
    if (reply.type === 'opened' && session.state === 'opening') {
      clearTimeout(session.timeout);
      session.state = 'ready';
      session.resolveOpen?.();
      session.resolveOpen = undefined;
      session.rejectOpen = undefined;
    } else if (reply.type === 'result' && session.state === 'finishing' && typeof reply.text === 'string') {
      this.close(session);
      this.result = reply.text;
      session.resolveFinish?.(reply.text);
    } else if (reply.type === 'error') {
      this.fail(session, session.state === 'opening' ? 'Unable to load the offline English model.' :
        'Offline English transcription failed.');
    }
  }

  private fail(session: EnglishSession, message: string): void {
    if (this.session !== session) {
      return;
    }
    const error = new Error(message);
    this.failure = error;
    this.close(session);
    session.rejectOpen?.(error);
    session.rejectFinish?.(error);
  }

  private close(session: EnglishSession): void {
    this.session = undefined;
    clearTimeout(session.timeout);
    try {
      session.thread.terminate();
    } catch {
      // The worker may have already exited.
    }
  }
}
