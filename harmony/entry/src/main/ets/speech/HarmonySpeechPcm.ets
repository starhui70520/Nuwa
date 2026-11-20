import { audio } from '@kit.AudioKit';
import { deviceInfo } from '@kit.BasicServicesKit';

const PCM_SAMPLE_RATE = 24000;

export interface HarmonySpeechPlaybackProgress {
  playedSeconds: number;
  bufferedSeconds: number;
}

export class HarmonySpeechPcm {
  private renderer?: audio.AudioRenderer;
  private stopped: boolean = false;
  private trailing: number = -1;
  private started: boolean = false;
  private writtenFrames: number = 0;
  private estimatedFrames: number = 0;
  private estimateAt: number = -1;
  private lastDevicePosition: number = 0;
  private devicePositionOffset: number = 0;
  private readonly onPlaying: () => void;
  private readonly onInterrupted: () => void;

  constructor(onPlaying: () => void, onInterrupted: () => void) {
    this.onPlaying = onPlaying;
    this.onInterrupted = onInterrupted;
  }

  async write(data: ArrayBuffer): Promise<void> {
    if (this.stopped || data.byteLength === 0) {
      return;
    }

    let bytes = new Uint8Array(data);
    if (this.trailing >= 0) {
      const aligned = new Uint8Array(bytes.length + 1);
      aligned[0] = this.trailing;
      aligned.set(bytes, 1);
      bytes = aligned;
      this.trailing = -1;
    }
    let length = bytes.length;
    if (length % 2 === 1) {
      length--;
      this.trailing = bytes[length];
    }
    if (!length) {
      return;
    }

    const renderer = this.renderer ?? await this.open();
    if (!renderer) {
      return;
    }
    let offset = 0;
    while (offset < length && !this.stopped) {
      // The push API gives backpressure and reports partial writes.
      const buffer = offset === 0 && length === bytes.buffer.byteLength ? bytes.buffer as ArrayBuffer :
        bytes.buffer.slice(bytes.byteOffset + offset, bytes.byteOffset + length) as ArrayBuffer;
      const written = await renderer.write(buffer);
      if (written <= 0 || written > length - offset || written % 2 !== 0) {
        throw new Error('PCM write failed');
      }
      offset += written;
      this.advanceEstimate();
      this.writtenFrames += written / 2;
      if (!this.started && !this.stopped) {
        this.started = true;
        this.onPlaying();
      }
    }
  }

  progress(): HarmonySpeechPlaybackProgress {
    this.advanceEstimate();
    const renderer = this.renderer;
    if (renderer && deviceInfo.sdkApiVersion >= 19) {
      try {
        const position = renderer.getAudioTimestampInfoSync().framePos;
        if (Number.isFinite(position) && position >= 0) {
          if (position < this.lastDevicePosition) this.devicePositionOffset += this.lastDevicePosition;
          this.lastDevicePosition = position;
          this.estimatedFrames = Math.min(this.writtenFrames, this.devicePositionOffset + position);
        }
      } catch {
        // The device position is unavailable before playback starts or while the route is changing.
      }
    }
    return {
      playedSeconds: this.estimatedFrames / PCM_SAMPLE_RATE,
      bufferedSeconds: this.writtenFrames / PCM_SAMPLE_RATE,
    };
  }

  private advanceEstimate(): void {
    const now = Date.now();
    if (this.estimateAt >= 0) {
      this.estimatedFrames = Math.min(this.writtenFrames,
        this.estimatedFrames + Math.max(0, now - this.estimateAt) * PCM_SAMPLE_RATE / 1000);
    }
    this.estimateAt = now;
  }

  async drain(): Promise<void> {
    if (!this.started || this.trailing >= 0) {
      throw new Error('Incomplete PCM audio');
    }
    if (!this.stopped && this.renderer) {
      await this.renderer.drain();
    }
  }

  stop(): void {
    this.stopped = true;
    const renderer = this.renderer;
    this.renderer = undefined;
    if (renderer) {
      void this.close(renderer);
    }
  }

  private async open(): Promise<audio.AudioRenderer | undefined> {
    const options: audio.AudioRendererOptions = {
      streamInfo: {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_24000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW,
      },
      rendererInfo: { usage: audio.StreamUsage.STREAM_USAGE_VOICE_ASSISTANT, rendererFlags: 0 },
    };
    const renderer = await audio.createAudioRenderer(options);
    try {
      if (!this.stopped) {
        if (canIUse('SystemCapability.Multimedia.Audio.Interrupt')) {
          renderer.on('audioInterrupt', (event: audio.InterruptEvent): void => {
            if (!this.stopped && event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) {
              this.stop();
              this.onInterrupted();
            }
          });
        }
        await renderer.start();
        if (!this.stopped) {
          this.renderer = renderer;
          return renderer;
        }
      }
    } catch {
      await this.close(renderer);
      throw new Error('PCM renderer unavailable');
    }
    await this.close(renderer);
    return undefined;
  }

  private async close(renderer: audio.AudioRenderer): Promise<void> {
    try {
      if (renderer.state === audio.AudioState.STATE_RUNNING) {
        await renderer.stop();
      }
    } catch {
      // The system can revoke audio focus during playback.
    }
    try {
      await renderer.release();
    } catch {
      // Release can race with a device audio reset.
    }
  }
}
