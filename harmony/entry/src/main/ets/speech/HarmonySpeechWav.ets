export const HARMONY_ASR_SAMPLE_RATE = 16000;
export const HARMONY_ASR_MAX_SECONDS = 120;
export const HARMONY_ASR_MAX_BYTES = HARMONY_ASR_SAMPLE_RATE * 2 * HARMONY_ASR_MAX_SECONDS;

export function encodeHarmonySpeechWav(samples: Uint8Array): ArrayBuffer {
  // Every sample is signed 16-bit little-endian PCM on one channel.
  const sampleBytes = samples.length - samples.length % 2;
  const wav = new ArrayBuffer(44 + sampleBytes);
  const header = new DataView(wav);
  header.setUint32(0, 0x52494646);
  header.setUint32(4, wav.byteLength - 8, true);
  header.setUint32(8, 0x57415645);
  header.setUint32(12, 0x666d7420);
  header.setUint32(16, 16, true);
  header.setUint16(20, 1, true);
  header.setUint16(22, 1, true);
  header.setUint32(24, HARMONY_ASR_SAMPLE_RATE, true);
  header.setUint32(28, HARMONY_ASR_SAMPLE_RATE * 2, true);
  header.setUint16(32, 2, true);
  header.setUint16(34, 16, true);
  header.setUint32(36, 0x64617461);
  header.setUint32(40, sampleBytes, true);
  new Uint8Array(wav, 44).set(samples.subarray(0, sampleBytes));
  return wav;
}
