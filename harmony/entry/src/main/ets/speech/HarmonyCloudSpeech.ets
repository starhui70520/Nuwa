import { util } from '@kit.ArkTS';
import { deviceInfo } from '@kit.BasicServicesKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import { HarmonySpeechError, HarmonySpeechRoute, HarmonySpeechVoice } from './HarmonySpeechOptions';

const MAX_TRANSCRIPT_BYTES = 512 * 1024;
const MAX_PCM_BYTES = 48 * 1024 * 1024;

interface SpeechTranscript {
  text?: string;
}

interface SynthesisPayload {
  text: string;
  voice_id: HarmonySpeechVoice;
  format: string;
  filter_markdown: boolean;
}

class CloudSpeechFailure extends Error {
  readonly code: HarmonySpeechError;

  constructor(code: HarmonySpeechError) {
    super(code);
    this.code = code;
  }
}

export function describeHarmonySpeechError(error: Object): HarmonySpeechError {
  return error instanceof CloudSpeechFailure ? error.code : 'failed';
}

function requireSuccess(status: number): void {
  if (status >= 200 && status < 300) {
    return;
  }
  if (status === 401 || status === 403) {
    throw new CloudSpeechFailure('unauthorized');
  }
  if (status === 402) {
    throw new CloudSpeechFailure('quota');
  }
  if (status === 429) {
    throw new CloudSpeechFailure('rate-limited');
  }
  throw new CloudSpeechFailure(status === 404 || status === 405 ? 'unavailable' : 'failed');
}

function pcmContentType(headers: rcp.ResponseHeaders): boolean {
  const field = Object.keys(headers).find((name: string): boolean => name.toLowerCase() === 'content-type');
  const value = field ? headers[field] : undefined;
  const type = (Array.isArray(value) ? value[0] : value)?.toLowerCase() ?? '';
  return !type || type.startsWith('application/octet-stream') || type.startsWith('audio/');
}

export class HarmonyCloudSpeech {
  private active?: rcp.Session;
  private cancelled: boolean = false;

  cancel(): void {
    this.cancelled = true;
    const session = this.active;
    this.active = undefined;
    this.close(session);
  }

  async transcribe(route: HarmonySpeechRoute, wav: ArrayBuffer): Promise<string> {
    let response = await this.upload(route, wav, false);
    if (route.allowWhisperFallback && (response.statusCode === 404 || response.statusCode === 405)) {
      response = await this.upload(route, wav, true);
    }
    requireSuccess(response.statusCode);
    if (!response.body || response.body.byteLength > MAX_TRANSCRIPT_BYTES) {
      throw new CloudSpeechFailure('failed');
    }
    try {
      const decoder = util.TextDecoder.create('utf-8');
      const body = JSON.parse(decoder.decodeToString(new Uint8Array(response.body))) as SpeechTranscript;
      if (typeof body?.text === 'string') {
        return body.text.trim();
      }
    } catch {
      // Keep provider response bodies out of UI errors.
    }
    throw new CloudSpeechFailure('failed');
  }

  private upload(route: HarmonySpeechRoute, wav: ArrayBuffer, whisper: boolean): Promise<rcp.Response> {
    const fileContent: rcp.FileContent = { content: wav };
    const file: rcp.FormFieldFileValue = {
      contentType: 'audio/wav',
      remoteFileName: 'recording.wav',
      contentOrPath: fileContent,
    };
    const formFields: rcp.MultipartFormFields = { 'file': file };
    if (whisper) {
      formFields['model'] = 'whisper-1';
    }
    const path = whisper ? '/v1/audio/transcriptions' : '/v1/tools/asr';
    const request = new rcp.Request(route.baseUrl + path, 'POST',
      { 'authorization': 'Bearer ' + route.key }, new rcp.MultipartForm(formFields));
    return this.fetch(request, 120000);
  }

  async synthesize(
    route: HarmonySpeechRoute, text: string, voice: HarmonySpeechVoice,
    play: (data: ArrayBuffer) => Promise<void>
  ): Promise<void> {
    const payload: SynthesisPayload = {
      text: text, voice_id: voice, format: 'pcm', filter_markdown: true,
    };
    const request = new rcp.Request(route.baseUrl + '/v1/tools/tts', 'POST', {
      'authorization': 'Bearer ' + route.key,
      'content-type': 'application/json',
    }, JSON.stringify(payload));

    // Newer SDKs expose the status before audio arrives. Older SDKs verify the
    // HTTP response before playing their bounded buffer.
    const live = deviceInfo.sdkApiVersion >= 20;
    let status = 0;
    let audio = false;
    let received = 0;
    const pending: ArrayBuffer[] = [];
    let playbackFailed = false;
    let scheduled: Promise<void> = Promise.resolve();
    request.destination = (data: ArrayBuffer): Promise<void> => {
      if (this.cancelled || (status !== 0 && (status < 200 || status >= 300))) {
        return scheduled;
      }
      received += data.byteLength;
      if (received > MAX_PCM_BYTES || playbackFailed) {
        this.cancel();
        return scheduled;
      }
      const copied = data.slice(0);
      scheduled = scheduled.then(async (): Promise<void> => {
        if (this.cancelled) {
          return;
        }
        if (live && audio && status >= 200 && status < 300) {
          try {
            for (const buffered of pending) {
              await play(buffered);
            }
            pending.length = 0;
            await play(copied);
          } catch {
            playbackFailed = true;
            this.cancel();
          }
        } else {
          pending.push(copied);
        }
      });
      return scheduled;
    };
    const transfer: rcp.TransferConfiguration = {
      autoRedirect: false,
      timeout: { connectMs: 15000, inactivityMs: 45000, transferMs: 600000 },
    };
    const tracing: rcp.TracingConfiguration = {
      httpEventsHandler: {
        onStatusCodeReceive: (value: number): void => { status = value; },
        onHeaderReceive: (headers: rcp.ResponseHeaders): void => { audio = pcmContentType(headers); },
      },
    };
    request.configuration = { transfer: transfer, tracing: live ? tracing : undefined };
    let response: rcp.Response;
    try {
      response = await this.fetch(request, 600000);
      await scheduled;
    } catch (error) {
      if (received > MAX_PCM_BYTES || playbackFailed) {
        throw new CloudSpeechFailure('failed');
      }
      throw new CloudSpeechFailure(describeHarmonySpeechError(error as Object));
    }
    if (received > MAX_PCM_BYTES || playbackFailed) {
      throw new CloudSpeechFailure('failed');
    }
    requireSuccess(response.statusCode);
    if (!pcmContentType(response.headers) || received === 0) {
      throw new CloudSpeechFailure('failed');
    }
    for (const buffered of pending) {
      if (this.cancelled) {
        return;
      }
      await play(buffered);
    }
  }

  private async fetch(request: rcp.Request, transferMs: number): Promise<rcp.Response> {
    if (this.cancelled || !canIUse('SystemCapability.Collaboration.RemoteCommunication')) {
      throw new CloudSpeechFailure('unavailable');
    }
    const configuration: rcp.Configuration = {
      transfer: {
        autoRedirect: false,
        timeout: { connectMs: 15000, inactivityMs: 45000, transferMs: transferMs },
      },
    };
    let session: rcp.Session | undefined;
    try {
      session = rcp.createSession({ requestConfiguration: configuration });
      this.active = session;
      return await session.fetch(request);
    } catch {
      throw new CloudSpeechFailure('network');
    } finally {
      if (this.active === session) {
        this.active = undefined;
        this.close(session);
      }
    }
  }

  private close(session: rcp.Session | undefined): void {
    try {
      session?.close();
    } catch {
      // Cancellation and connection completion can race.
    }
  }
}
