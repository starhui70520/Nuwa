import { util } from '@kit.ArkTS';
import { textToSpeech } from '@kit.CoreSpeechKit';

const MAX_TEXT_LENGTH = 10000;
const PLAYBACK_COMPLETE = 1;

interface Playback {
  id: string;
  chunks: string[];
  nextChunk: number;
  requestId: string;
  started: boolean;
}

function splitText(text: string): string[] {
  const chunks: string[] = [];
  let offset = 0;
  while (offset < text.length) {
    let end = Math.min(offset + MAX_TEXT_LENGTH, text.length);
    const lastUnit = text.charCodeAt(end - 1);
    // Keep surrogate pairs together when a chunk ends in the middle of one.
    if (end < text.length && lastUnit >= 0xd800 && lastUnit <= 0xdbff) {
      end--;
    }
    const chunk = text.slice(offset, end);
    if (chunk.trim().length > 0) {
      chunks.push(chunk);
    }
    offset = end;
  }
  return chunks;
}

export class HarmonyTextToSpeech {
  private readonly emit: (id: string, state: string) => void;
  private readonly requestPrefix: string = util.generateRandomUUID(true).replace(/-/g, '');
  private engine?: textToSpeech.TextToSpeechEngine;
  private initializing: boolean = false;
  private engineGeneration: number = 0;
  private requestSequence: number = 0;
  private active?: Playback;

  constructor(emit: (id: string, state: string) => void) {
    this.emit = emit;
  }

  speak(id: string, text: string, _locale: string): void {
    this.stop();
    const chunks = splitText(text);
    if (chunks.length === 0) {
      this.emit(id, 'error');
      return;
    }
    this.active = { id, chunks, nextChunk: 0, requestId: '', started: false };
    this.playNext();
  }

  stop(id?: string): void {
    if (this.active === undefined || (id !== undefined && this.active.id !== id)) {
      return;
    }
    this.active = undefined;
    try {
      this.engine?.stop();
    } catch {
      this.destroy();
    }
  }

  destroy(): void {
    this.active = undefined;
    this.engineGeneration++;
    const engine = this.engine;
    this.engine = undefined;
    this.shutdown(engine);
  }

  private async initialize(): Promise<void> {
    this.initializing = true;
    const generation = this.engineGeneration;
    let engine: textToSpeech.TextToSpeechEngine | undefined;
    try {
      // HarmonyOS 5.0 includes the offline Mandarin voice.
      const params: textToSpeech.CreateEngineParams = { language: 'zh-CN', person: 0, online: 1 };
      engine = await textToSpeech.createEngine(params);
      if (generation !== this.engineGeneration) {
        this.shutdown(engine);
        return;
      }
      const listener: textToSpeech.SpeakListener = {
        onStart: (requestId: string, _response: textToSpeech.StartResponse): void => {
          const playback = this.active;
          if (playback?.requestId === requestId && !playback.started) {
            playback.started = true;
            this.emit(playback.id, 'playing');
          }
        },
        onComplete: (requestId: string, response: textToSpeech.CompleteResponse): void => {
          if (this.active?.requestId === requestId && response.type === PLAYBACK_COMPLETE) {
            this.playNext();
          }
        },
        onStop: (requestId: string, _response: textToSpeech.StopResponse): void => {
          if (this.active?.requestId === requestId) {
            this.finish('done');
          }
        },
        onData: (_requestId: string, _audio: ArrayBuffer, _response: textToSpeech.SynthesisResponse): void => {},
        onError: (requestId: string, _code: number, _message: string): void => {
          if (this.active?.requestId === requestId) {
            this.finish('error');
          }
        }
      };
      engine.setListener(listener);
      this.engine = engine;
    } catch {
      this.shutdown(engine);
      if (generation === this.engineGeneration) {
        this.finish('error');
      }
    } finally {
      this.initializing = false;
      this.playNext();
    }
  }

  private playNext(): void {
    const playback = this.active;
    if (playback === undefined) {
      return;
    }
    if (this.engine === undefined) {
      if (!this.initializing) {
        void this.initialize();
      }
      return;
    }
    if (playback.nextChunk === playback.chunks.length) {
      this.finish('done');
      return;
    }
    playback.requestId = `${this.requestPrefix}${++this.requestSequence}`;
    const chunk = playback.chunks[playback.nextChunk++];
    try {
      const extraParams: Record<string, Object> = { playType: 1 };
      const params: textToSpeech.SpeakParams = { requestId: playback.requestId, extraParams };
      this.engine.speak(chunk, params);
    } catch {
      this.finish('error');
    }
  }

  private finish(state: string): void {
    const playback = this.active;
    if (playback !== undefined) {
      this.active = undefined;
      if (state === 'error') {
        this.destroy();
      }
      this.emit(playback.id, state);
    }
  }

  private shutdown(engine: textToSpeech.TextToSpeechEngine | undefined): void {
    try {
      engine?.shutdown();
    } catch {
      // The system may have already released a disconnected engine.
    }
  }
}
