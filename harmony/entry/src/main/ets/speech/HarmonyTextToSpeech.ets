import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { textToSpeech } from '@kit.CoreSpeechKit';
import { HarmonyCloudSpeech, describeHarmonySpeechError } from './HarmonyCloudSpeech';
import { HarmonySpeechLineTimeline, splitHarmonySpeechLines } from './HarmonySpeechLines';
import { HarmonySpeechPcm } from './HarmonySpeechPcm';
import { HarmonySpeechSession } from './HarmonySpeechSession';
import {
  HarmonySpeechError, HarmonySpeechOptions, HarmonySpeechRoute, HarmonySpeechVoice,
  resolveHarmonySpeechRoute, stripHarmonySpeechMarkdown,
} from './HarmonySpeechOptions';

const MAX_TEXT_LENGTH = 10000;
const PLAYBACK_COMPLETE = 1;
const CAPTION_INTERVAL_MS = 450;

interface Playback {
  id: string;
  text: string;
  locale: string;
  voice: HarmonySpeechVoice;
  chunks: string[];
  nextChunk: number;
  requestId: string;
  started: boolean;
  context?: common.UIAbilityContext;
  cloudRoute?: HarmonySpeechRoute;
  cloud?: HarmonyCloudSpeech;
  pcm?: HarmonySpeechPcm;
  captionTimer?: number;
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
  private engineBackground: boolean = false;
  private initializing: boolean = false;
  private requestSequence: number = 0;
  private active?: Playback;
  private readonly media = new HarmonySpeechSession();

  constructor(emit: (id: string, state: string, code?: HarmonySpeechError) => void) {
    this.emit = emit;
  }

  speak(id: string, text: string, locale: string, options?: HarmonySpeechOptions, context?: common.UIAbilityContext): void {
    this.stop();
    const cleaned = stripHarmonySpeechMarkdown(text);
    const chunks = context ? splitHarmonySpeechLines(cleaned) : splitText(cleaned);
    if (!chunks.length) {
      this.emit(id, 'error', 'failed');
      return;
    }
    const mode = options?.engine ?? 'native';
    const cloudRoute = mode === 'native' ? undefined : resolveHarmonySpeechRoute(options, true);
    const playback: Playback = {
      id: id, text: text, locale: locale.toLowerCase().startsWith('en') ? 'en-US' : 'zh-CN',
      voice: options?.voice ?? 'stella', chunks: chunks, nextChunk: 0, requestId: '',
      started: false, context, cloudRoute: cloudRoute,
    };
    this.active = playback;
    if (mode === 'cloud' && cloudRoute) {
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
    if (playback.captionTimer !== undefined) clearInterval(playback.captionTimer);
    if (playback.context) this.media.stop();
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

  private async createEngine(language: string, person: number, background: boolean): Promise<textToSpeech.TextToSpeechEngine> {
    if (background) {
      try {
        return await textToSpeech.createEngine({ language, person, online: 1, extraParams: { 'isBackStage': true } });
      } catch {
        // Retry with the system's foreground engine when background playback is unavailable.
      }
    }
    return textToSpeech.createEngine({ language, person, online: 1 });
  }

  private async initialize(playback: Playback): Promise<void> {
    this.initializing = true;
    let engine: textToSpeech.TextToSpeechEngine | undefined;
    try {
      if (!canIUse('SystemCapability.AI.TextToSpeech')) {
        throw new Error('System TTS unavailable');
      }
      const person = playback.locale === 'en-US' ? 8 : playback.voice === 'tide' ? 21 : 0;
      const background = playback.context !== undefined;
      try {
        engine = await this.createEngine(playback.locale, person, background);
      } catch {
        if (this.active !== playback || person === 0 || playback.cloudRoute) {
          throw new Error('Voice unavailable');
        }
        // HarmonyOS 5.0 offers the offline Mandarin voice with English text support.
        engine = await this.createEngine('zh-CN', 0, background);
      }
      if (this.active !== playback) {
        this.shutdown(engine);
        return;
      }
      const listener: textToSpeech.SpeakListener = {
        onStart: (requestId: string, _response: textToSpeech.StartResponse): void => {
          const current = this.active;
          if (current?.requestId === requestId) {
            this.markPlaying(current, current.chunks[current.nextChunk - 1]);
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
      this.engineBackground = background;
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
    if (this.engine && (this.engineLocale !== playback.locale || this.engineVoice !== playback.voice ||
      this.engineBackground !== (playback.context !== undefined))) {
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

  private markPlaying(playback: Playback, line: string = playback.chunks[0]): void {
    if (this.active !== playback) return;
    const artist = playback.locale === 'zh-CN' ? 'Nuwa AI 朗读' : 'Nuwa AI Read Aloud';
    if (!playback.started) {
      playback.started = true;
      if (playback.context) {
        this.media.start(playback.context, playback.id, line, artist, (): void => { this.finish(playback, 'done'); });
      }
      this.emit(playback.id, 'playing');
    } else if (playback.context) {
      this.media.updateTitle(playback.id, line, artist);
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
    const captions = playback.context && playback.chunks.length > 1 ? new HarmonySpeechLineTimeline(playback.chunks) : undefined;
    let streamEnded = false;
    const pcm: HarmonySpeechPcm = new HarmonySpeechPcm(
      (): void => {
        this.markPlaying(playback);
        if (captions && this.active === playback) {
          playback.captionTimer = setInterval(() => {
            if (this.active !== playback) return;
            const progress = pcm.progress();
            const line = captions.advance(progress.playedSeconds, progress.bufferedSeconds, streamEnded);
            if (line) this.markPlaying(playback, line);
          }, CAPTION_INTERVAL_MS);
        }
      },
      (): void => { this.finish(playback, 'done'); }
    );
    playback.cloud = cloud;
    playback.pcm = pcm;
    try {
      await cloud.synthesize(route, playback.text, playback.voice, (data: ArrayBuffer): Promise<void> => pcm.write(data));
      if (this.active === playback) {
        streamEnded = true;
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
