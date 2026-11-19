import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { audio } from '@kit.AudioKit';
import { speechRecognizer } from '@kit.CoreSpeechKit';
import { HarmonyCloudSpeech, describeHarmonySpeechError } from './HarmonyCloudSpeech';
import { HarmonySpeechError, HarmonySpeechOptions, HarmonySpeechRoute, resolveHarmonySpeechRoute } from './HarmonySpeechOptions';
import { encodeHarmonySpeechWav, HARMONY_ASR_MAX_BYTES, HARMONY_ASR_MAX_SECONDS, HARMONY_ASR_SAMPLE_RATE } from './HarmonySpeechWav';

const MIC_PERMISSION: Permissions = 'ohos.permission.MICROPHONE';
const MIC_PERMISSION_DENIED = 1002200012;
const DEVICE_START_GRACE_MS = 7000;
const DEVICE_LIMIT_MS = 60000;
const DEVICE_FINISH_GRACE_MS = 5000;

class RecognitionSession {
  readonly id: string;
  engine?: speechRecognizer.SpeechRecognitionEngine;
  capturer?: audio.AudioCapturer;
  cloud?: HarmonyCloudSpeech;
  route?: HarmonySpeechRoute;
  pcm?: Uint8Array;
  byteCount: number = 0;
  text: string = '';
  finishing: boolean = false;
  deviceStarted: boolean = false;
  captureStarting: boolean = false;
  timer: number = -1;

  constructor(id: string) {
    this.id = id;
  }
}

export class HarmonySpeechRecognition {
  private active?: RecognitionSession;
  private opening: Promise<void> = Promise.resolve();
  private releasing: Promise<void> = Promise.resolve();
  private readonly emit: (id: string, state: string, text?: string, code?: HarmonySpeechError) => void;

  constructor(emit: (id: string, state: string, text?: string, code?: HarmonySpeechError) => void) {
    this.emit = emit;
  }

  start(id: string, context: common.UIAbilityContext, options?: HarmonySpeechOptions): void {
    this.cancel();
    const session = new RecognitionSession(id);
    this.active = session;
    // Wait for cancelled initialization and device shutdown before reacquiring the microphone.
    this.opening = this.opening.then(async (): Promise<void> => {
      try {
        await this.releasing;
        await this.open(session, context, options);
      } catch {
        this.fail(session, 'unavailable');
      }
    });
  }

  finish(id: string): void {
    const session = this.active;
    if (!session || session.id !== id) {
      return;
    }
    if (session.finishing || !(session.deviceStarted || (session.capturer && !session.captureStarting))) {
      this.cancel(id);
      this.emit(id, 'cancelled');
      return;
    }
    session.finishing = true;
    this.clearTimer(session);
    if (session.capturer) {
      void this.transcribe(session);
      return;
    }
    try {
      session.timer = setTimeout((): void => { this.complete(session); }, DEVICE_FINISH_GRACE_MS);
      session.engine?.finish(id);
    } catch {
      this.fail(session, 'failed');
    }
  }

  cancel(id?: string): void {
    const session = this.active;
    if (!session || (id !== undefined && session.id !== id)) {
      return;
    }
    this.active = undefined;
    this.clearTimer(session);
    session.cloud?.cancel();
    session.pcm = undefined;
    const engine = session.engine;
    session.engine = undefined;
    if (engine) {
      try {
        engine.cancel(session.id);
      } catch {
        // The device may have ended the session already.
      }
      this.shutdown(engine);
    }
    void this.releaseCapturer(session);
  }

  private async open(session: RecognitionSession, context: common.UIAbilityContext,
    options: HarmonySpeechOptions | undefined): Promise<void> {
    if (this.active !== session) {
      return;
    }
    const engine = options?.engine ?? 'native';
    session.route = engine === 'native' ? undefined : resolveHarmonySpeechRoute(options, false);
    if (engine === 'cloud' && !session.route) {
      this.fail(session, 'key-required');
      return;
    }
    const nativeAvailable = canIUse('SystemCapability.AI.SpeechRecognizer');
    if (!nativeAvailable && !session.route) {
      this.fail(session, 'unavailable');
      return;
    }
    try {
      const permission = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, [MIC_PERMISSION]);
      if (this.active !== session) {
        return;
      }
      if (permission.authResults[0] !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        this.fail(session, 'permission-denied');
        return;
      }
    } catch {
      this.fail(session, 'permission-denied');
      return;
    }

    // The on-device recognizer is Mandarin-only. In Auto, English can use the configured cloud route.
    if (engine === 'cloud' || !nativeAvailable || (session.route && options?.locale.toLowerCase().startsWith('en'))) {
      await this.openCloudRecorder(session);
    } else {
      await this.openDevice(session);
    }
  }

  private async openDevice(session: RecognitionSession): Promise<void> {
    let engine: speechRecognizer.SpeechRecognitionEngine;
    try {
      const params: speechRecognizer.CreateEngineParams = { language: 'zh-CN', online: 1 };
      engine = await speechRecognizer.createEngine(params);
    } catch {
      await this.fallbackOrFail(session, 'unavailable');
      return;
    }
    if (this.active !== session) {
      this.shutdown(engine);
      return;
    }
    session.engine = engine;
    const listener: speechRecognizer.RecognitionListener = {
      onStart: (id: string, _message: string): void => {
        if (this.active === session && session.engine === engine && id === session.id && !session.deviceStarted) {
          session.deviceStarted = true;
          this.clearTimer(session);
          session.timer = setTimeout((): void => { this.complete(session); },
            DEVICE_LIMIT_MS + DEVICE_FINISH_GRACE_MS);
          this.emit(id, 'started');
        }
      },
      onEvent: (_id: string, _event: number, _message: string): void => {},
      onResult: (id: string, result: speechRecognizer.SpeechRecognitionResult): void => {
        if (this.active === session && session.engine === engine && id === session.id && result.isFinal) {
          session.text += result.result;
        }
      },
      onComplete: (id: string, _message: string): void => {
        if (session.engine === engine && id === session.id) {
          this.complete(session);
        }
      },
      onError: (id: string, errorCode: number, _message: string): void => {
        if (session.engine === engine && id === session.id) {
          this.queueDeviceFallback(session, engine, errorCode === MIC_PERMISSION_DENIED ? 'permission-denied' : 'failed');
        }
      }
    };
    const extraParams: Record<string, Object> = {
      'recognitionMode': 0, 'vadEnd': 2000, 'maxAudioDuration': DEVICE_LIMIT_MS,
    };
    const params: speechRecognizer.StartParams = {
      sessionId: session.id,
      audioInfo: { audioType: 'pcm', sampleRate: HARMONY_ASR_SAMPLE_RATE, soundChannel: 1, sampleBit: 16 },
      extraParams: extraParams,
    };
    try {
      engine.setListener(listener);
      session.timer = setTimeout((): void => {
        this.queueDeviceFallback(session, engine, 'unavailable');
      }, DEVICE_START_GRACE_MS);
      engine.startListening(params);
    } catch {
      await this.fallbackOrFail(session, 'failed');
    }
  }

  private queueDeviceFallback(session: RecognitionSession, engine: speechRecognizer.SpeechRecognitionEngine,
    code: HarmonySpeechError): void {
    this.opening = this.opening.then(async (): Promise<void> => {
      if (session.engine === engine) {
        try {
          await this.fallbackOrFail(session, code);
        } catch {
          this.fail(session, code);
        }
      }
    });
  }

  private async fallbackOrFail(session: RecognitionSession, code: HarmonySpeechError): Promise<void> {
    if (this.active !== session) {
      return;
    }
    this.clearTimer(session);
    if (code !== 'permission-denied' && session.route && !session.deviceStarted && !session.finishing) {
      const engine = session.engine;
      session.engine = undefined;
      this.shutdown(engine);
      await this.openCloudRecorder(session);
    } else {
      this.fail(session, code);
    }
  }

  private async openCloudRecorder(session: RecognitionSession): Promise<void> {
    if (this.active !== session || session.captureStarting || session.capturer) {
      return;
    }
    if (!canIUse('SystemCapability.Multimedia.Audio.Capturer') ||
      !canIUse('SystemCapability.Collaboration.RemoteCommunication')) {
      this.fail(session, 'unavailable');
      return;
    }
    session.captureStarting = true;
    try {
      const options: audio.AudioCapturerOptions = {
        streamInfo: {
          samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
          channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
        },
        capturerInfo: { source: audio.SourceType.SOURCE_TYPE_MIC, capturerFlags: 0 },
      };
      const capturer = await audio.createAudioCapturer(options);
      session.capturer = capturer;
      if (this.active !== session) {
        return;
      }
      session.pcm = new Uint8Array(HARMONY_ASR_MAX_BYTES);
      capturer.on('readData', (data: ArrayBuffer): void => { this.appendRecording(session, data); });
      await capturer.start();
      if (this.active === session) {
        session.timer = setTimeout((): void => { this.finish(session.id); }, HARMONY_ASR_MAX_SECONDS * 1000);
        this.emit(session.id, 'started');
      }
    } catch {
      this.fail(session, 'unavailable');
    } finally {
      session.captureStarting = false;
      if (this.active !== session) {
        await this.releaseCapturer(session);
      }
    }
  }

  private appendRecording(session: RecognitionSession, data: ArrayBuffer): void {
    const pcm = session.pcm;
    if (this.active !== session || session.finishing || !pcm) {
      return;
    }
    const length = Math.min(data.byteLength, pcm.length - session.byteCount);
    pcm.set(new Uint8Array(data, 0, length), session.byteCount);
    session.byteCount += length;
    if (session.byteCount === pcm.length) {
      this.finish(session.id);
    }
  }

  private async transcribe(session: RecognitionSession): Promise<void> {
    const pcm = session.pcm;
    const route = session.route;
    session.pcm = undefined;
    this.emit(session.id, 'transcribing');
    await this.releaseCapturer(session);
    if (this.active !== session) {
      return;
    }
    if (!pcm || !route || session.byteCount < 2) {
      this.complete(session);
      return;
    }
    try {
      const cloud = new HarmonyCloudSpeech();
      session.cloud = cloud;
      session.text = await cloud.transcribe(route, encodeHarmonySpeechWav(pcm.subarray(0, session.byteCount)));
      this.complete(session);
    } catch (error) {
      this.fail(session, describeHarmonySpeechError(error as Object));
    }
  }

  private releaseCapturer(session: RecognitionSession): Promise<void> {
    const capturer = session.capturer;
    if (!capturer || session.captureStarting) {
      return this.releasing;
    }
    session.capturer = undefined;
    this.releasing = this.releasing.then(async (): Promise<void> => {
      try {
        capturer.off('readData');
        if (capturer.state === audio.AudioState.STATE_RUNNING) {
          await capturer.stop();
        }
      } catch {
        // System interruptions can stop capture first.
      }
      try {
        await capturer.release();
      } catch {
        // Release can race with an audio service reset.
      }
    });
    return this.releasing;
  }

  private clearTimer(session: RecognitionSession): void {
    if (session.timer >= 0) {
      clearTimeout(session.timer);
      session.timer = -1;
    }
  }

  private complete(session: RecognitionSession): void {
    if (this.active !== session) {
      return;
    }
    const engine = session.engine;
    session.engine = undefined;
    this.shutdown(engine);
    this.cancel(session.id);
    this.emit(session.id, 'done', session.text.trim());
  }

  private fail(session: RecognitionSession, code: HarmonySpeechError): void {
    if (this.active !== session) {
      return;
    }
    this.cancel(session.id);
    this.emit(session.id, 'error', undefined, code);
  }

  private shutdown(engine?: speechRecognizer.SpeechRecognitionEngine): void {
    try {
      engine?.shutdown();
    } catch {
      // The device may have released the engine after a service error.
    }
  }
}
