import { audio } from '@kit.AudioKit';

export class HarmonySpeechPcm {
  private renderer?: audio.AudioRenderer;
  private stopped: boolean = false;
  private trailing: number = -1;
  private started: boolean = false;
  private readonly onPlaying: () => void;

  constructor(onPlaying: () => void) {
    this.onPlaying = onPlaying;
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
      if (!this.started && !this.stopped) {
        this.started = true;
        this.onPlaying();
      }
    }
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
