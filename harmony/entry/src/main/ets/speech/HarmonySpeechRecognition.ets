import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { speechRecognizer } from '@kit.CoreSpeechKit';

const MIC_PERMISSION: Permissions = 'ohos.permission.MICROPHONE';
const MIC_PERMISSION_DENIED = 1002200012;

class RecognitionSession {
  readonly id: string;
  engine?: speechRecognizer.SpeechRecognitionEngine;
  text: string = '';
  finishing: boolean = false;

  constructor(id: string) {
    this.id = id;
  }
}

export class HarmonySpeechRecognition {
  private active?: RecognitionSession;
  private opening: Promise<void> = Promise.resolve();
  private readonly emit: (id: string, state: string, text?: string, code?: string) => void;

  constructor(emit: (id: string, state: string, text?: string, code?: string) => void) {
    this.emit = emit;
  }

  start(id: string, context: common.UIAbilityContext): void {
    this.cancel();
    const session = new RecognitionSession(id);
    this.active = session;
    // The service allows only one engine. Let a cancelled pending initialization release its engine first.
    this.opening = this.opening.then(() => this.open(session, context));
  }

  finish(id: string): void {
    const session = this.active;
    if (!session || session.id !== id || session.finishing) {
      return;
    }
    if (!session.engine) {
      this.complete(session);
      return;
    }
    session.finishing = true;
    try {
      session.engine.finish(id);
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
    const engine = session.engine;
    if (engine) {
      try {
        engine.cancel(session.id);
      } catch {
        // The service may have already ended the session.
      }
      this.shutdown(engine);
    }
  }

  private async open(session: RecognitionSession, context: common.UIAbilityContext): Promise<void> {
    if (this.active !== session) {
      return;
    }
    if (!canIUse('SystemCapability.AI.SpeechRecognizer')) {
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

    let engine: speechRecognizer.SpeechRecognitionEngine;
    try {
      // Core Speech Kit's on-device recognizer supports Mandarin on the compatible SDK.
      const engineParams: speechRecognizer.CreateEngineParams = { language: 'zh-CN', online: 1 };
      engine = await speechRecognizer.createEngine(engineParams);
    } catch {
      this.fail(session, 'unavailable');
      return;
    }
    if (this.active !== session) {
      this.shutdown(engine);
      return;
    }
    session.engine = engine;
    const listener: speechRecognizer.RecognitionListener = {
      onStart: (id: string, _message: string): void => {
        if (this.active === session && id === session.id) {
          this.emit(id, 'started');
        }
      },
      onEvent: (_id: string, _event: number, _message: string): void => {},
      onResult: (id: string, result: speechRecognizer.SpeechRecognitionResult): void => {
        if (this.active === session && id === session.id && result.isFinal) {
          session.text += result.result;
        }
      },
      onComplete: (id: string, _message: string): void => {
        if (id === session.id) {
          this.complete(session);
        }
      },
      onError: (id: string, errorCode: number, _message: string): void => {
        if (id === session.id) {
          this.fail(session, errorCode === MIC_PERMISSION_DENIED ? 'permission-denied' : 'failed');
        }
      }
    };
    // Mode 0 lets the system service record from the mic without passing audio to the WebView.
    const extraParams: Record<string, Object> = { 'recognitionMode': 0, 'vadEnd': 2000, 'maxAudioDuration': 60000 };
    const startParams: speechRecognizer.StartParams = {
      sessionId: session.id,
      audioInfo: { audioType: 'pcm', sampleRate: 16000, soundChannel: 1, sampleBit: 16 },
      extraParams
    };
    try {
      engine.setListener(listener);
      engine.startListening(startParams);
    } catch {
      this.fail(session, 'failed');
    }
  }

  private complete(session: RecognitionSession): void {
    if (this.active !== session) {
      return;
    }
    this.active = undefined;
    this.shutdown(session.engine);
    this.emit(session.id, 'done', session.text.trim());
  }

  private fail(session: RecognitionSession, code: string): void {
    if (this.active !== session) {
      return;
    }
    this.active = undefined;
    this.shutdown(session.engine);
    this.emit(session.id, 'error', undefined, code);
  }

  private shutdown(engine?: speechRecognizer.SpeechRecognitionEngine): void {
    try {
      engine?.shutdown();
    } catch {
      // Closing an engine again after a service error is harmless.
    }
  }
}
