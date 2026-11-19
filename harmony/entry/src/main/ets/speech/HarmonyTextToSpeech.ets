import { util } from '@kit.ArkTS';
import { textToSpeech } from '@kit.CoreSpeechKit';
import { HarmonyCloudSpeech, describeHarmonySpeechError } from './HarmonyCloudSpeech';
import { HarmonySpeechPcm } from './HarmonySpeechPcm';
import {
  HarmonySpeechError, HarmonySpeechOptions, HarmonySpeechRoute, HarmonySpeechVoice,
  resolveHarmonySpeechRoute, stripHarmonySpeechMarkdown,
} from './HarmonySpeechOptions';

const MAX_TEXT_LENGTH = 10000;
const PLAYBACK_COMPLETE = 1;

interface Playback {
  id: string;
  text: string;
  locale: string;
  voice: HarmonySpeechVoice;
  chunks: string[];
  nextChunk: number;
  requestId: string;
  started: boolean;
  cloudRoute?: HarmonySpeechRoute;
  cloud?: HarmonyCloudSpeech;
  pcm?: HarmonySpeechPcm;
}

function splitText(text: string): string[] {
  const chunks: string[] = [];
  let offset = 0;
  while (offset < text.length) {
    let end = Math.min(offset + MAX_TEXT_LENGTH, text.length);
    const lastUnit = text.charCodeAt(end - 1);
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
  private readonly emit: (id: string, state: string, code?: HarmonySpeechError) => void;
  private readonly requestPrefix: string = util.generateRandomUUID(true).replace(/-/g, '');
  private engine?: textToSpeech.TextToSpeechEngine;
  private engineLocale: string = '';
  private engineVoice: HarmonySpeechVoice = 'stella';
  private initializing: boolean = false;
  private requestSequence: number = 0;
  private active?: Playback;

  constructor(emit: (id: string, state: string, code?: HarmonySpeechError) => void) {
    this.emit = emit;
  }

  speak(id: string, text: string, locale: string, options?: HarmonySpeechOptions): void {
    this.stop();
    const chunks = splitText(stripHarmonySpeechMarkdown(text));
    if (!chunks.length) {
      this.emit(id, 'error', 'failed');
      return;
    }
    const mode = options?.engine ?? 'native';
    const cloudRoute = mode === 'native' ? undefined : resolveHarmonySpeechRoute(options, true);
    if (mode === 'cloud' && !cloudRoute) {
      this.emit(id, 'error', 'key-required');
      return;
    }
    const playback: Playback = {
      id: id, text: text, locale: locale.toLowerCase().startsWith('en') ? 'en-US' : 'zh-CN',
      voice: options?.voice ?? 'stella', chunks: chunks, nextChunk: 0, requestId: '',
      started: false, cloudRoute: cloudRoute,
    };
    this.active = playback;
    if (mode === 'cloud') {
      void this.startCloud(playback);
    } else {
      this.playNext();
    }
  }

  stop(id?: string): void {
    const playback = this.active;
    if (!playback || (id !== undefined && playback.id !== id)) {
      return;
    }
    this.active = undefined;
    playback.cloud?.cancel();
    playback.pcm?.stop();
    if (!playback.cloud) {
      try {
        this.engine?.stop();
      } catch {
        this.disposeEngine();
      }
    }
  }

  destroy(): void {
    this.stop();
    this.disposeEngine();
  }

  private async initialize(playback: Playback): Promise<void> {
    this.initializing = true;
    let engine: textToSpeech.TextToSpeechEngine | undefined;
    try {
      if (!canIUse('SystemCapability.AI.TextToSpeech')) {
        throw new Error('System TTS unavailable');
      }
      const person = playback.locale === 'en-US' ? 8 : playback.voice === 'tide' ? 21 : 0;
      try {
        engine = await textToSpeech.createEngine({ language: playback.locale, person: person, online: 1 });
      } catch {
        if (this.active !== playback || person === 0 || playback.cloudRoute) {
          throw new Error('Voice unavailable');
        }
        // HarmonyOS 5.0 offers the offline Mandarin voice with English text support.
        engine = await textToSpeech.createEngine({ language: 'zh-CN', person: 0, online: 1 });
      }
      if (this.active !== playback) {
        this.shutdown(engine);
        return;
      }
      const listener: textToSpeech.SpeakListener = {
        onStart: (requestId: string, _response: textToSpeech.StartResponse): void => {
          const current = this.active;
          if (current?.requestId === requestId) {
            this.markPlaying(current);
          }
        },
        onComplete: (requestId: string, response: textToSpeech.CompleteResponse): void => {
          if (this.active?.requestId === requestId && response.type === PLAYBACK_COMPLETE) {
            this.playNext();
          }
        },
        onStop: (requestId: string, _response: textToSpeech.StopResponse): void => {
          const current = this.active;
          if (current?.requestId === requestId) {
            this.finish(current, 'done');
          }
        },
        onData: (_requestId: string, _audio: ArrayBuffer, _response: textToSpeech.SynthesisResponse): void => {},
        onError: (requestId: string, _code: number, _message: string): void => {
          const current = this.active;
          if (current?.requestId === requestId) {
            this.fallbackOrFail(current, 'failed');
          }
        },
      };
      engine.setListener(listener);
      this.engine = engine;
      this.engineLocale = playback.locale;
      this.engineVoice = playback.voice;
    } catch {
      this.shutdown(engine);
      this.fallbackOrFail(playback, 'unavailable');
    } finally {
      this.initializing = false;
      this.playNext();
    }
  }

  private playNext(): void {
    const playback = this.active;
    if (!playback || playback.cloud || this.initializing) {
      return;
    }
    if (this.engine && (this.engineLocale !== playback.locale || this.engineVoice !== playback.voice)) {
      this.disposeEngine();
    }
    if (!this.engine) {
      void this.initialize(playback);
      return;
    }
    if (playback.nextChunk === playback.chunks.length) {
      this.finish(playback, 'done');
      return;
    }
    playback.requestId = this.requestPrefix + String(++this.requestSequence);
    const chunk = playback.chunks[playback.nextChunk++];
    try {
      const extraParams: Record<string, Object> = { 'playType': 1 };
      const params: textToSpeech.SpeakParams = { requestId: playback.requestId, extraParams: extraParams };
      this.engine.speak(chunk, params);
    } catch {
      this.fallbackOrFail(playback, 'failed');
    }
  }

  private markPlaying(playback: Playback): void {
    if (this.active === playback && !playback.started) {
      playback.started = true;
      this.emit(playback.id, 'playing');
    }
  }

  private fallbackOrFail(playback: Playback, code: HarmonySpeechError): void {
    if (this.active !== playback) {
      return;
    }
    this.disposeEngine();
    if (!playback.started && playback.cloudRoute && !playback.cloud) {
      void this.startCloud(playback);
    } else {
      this.finish(playback, 'error', code);
    }
  }

  private async startCloud(playback: Playback): Promise<void> {
    const route = playback.cloudRoute;
    if (!route || !canIUse('SystemCapability.Multimedia.Audio.Renderer')) {
      this.finish(playback, 'error', route ? 'unavailable' : 'key-required');
      return;
    }
    const cloud = new HarmonyCloudSpeech();
    const pcm = new HarmonySpeechPcm(
      (): void => { this.markPlaying(playback); },
      (): void => { this.finish(playback, 'done'); }
    );
    playback.cloud = cloud;
    playback.pcm = pcm;
    try {
      await cloud.synthesize(route, playback.text, playback.voice, (data: ArrayBuffer): Promise<void> => pcm.write(data));
      if (this.active === playback) {
        await pcm.drain();
        this.finish(playback, 'done');
      }
    } catch (error) {
      this.finish(playback, 'error', describeHarmonySpeechError(error as Object));
    }
  }

  private finish(playback: Playback, state: string, code?: HarmonySpeechError): void {
    if (this.active !== playback) {
      return;
    }
    this.stop(playback.id);
    this.emit(playback.id, state, code);
  }

  private disposeEngine(): void {
    const engine = this.engine;
    this.engine = undefined;
    this.shutdown(engine);
  }

  private shutdown(engine: textToSpeech.TextToSpeechEngine | undefined): void {
    try {
      engine?.shutdown();
    } catch {
      // The system may have already released a disconnected engine.
    }
  }
}
