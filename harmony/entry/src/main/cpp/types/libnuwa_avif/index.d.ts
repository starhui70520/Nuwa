export interface AvifFrame {
  width: number;
  height: number;
  /** Tightly packed 8-bit RGBA with straight alpha. */
  rgba: ArrayBuffer;
}

export interface AvifAnimation {
  readonly frameCount: number;
  /** Number of complete plays. Zero means loop indefinitely. */
  readonly playCount: number;
}

export interface AvifAnimationFrame extends AvifFrame {
  /** Frame duration in milliseconds from the AVIF track. */
  durationMs: number;
}

interface NuwaAvif {
  /** Decodes the first frame and applies its AVIF display transforms. */
  decodeAvif(path: string): Promise<AvifFrame | null>;
  /** Opens a multi-frame AVIF sequence for on-demand decoding. */
  openAvifAnimation(path: string): Promise<AvifAnimation | null>;
  /** Decodes a zero-based frame index. Only one read per animation can be pending. */
  readAvifAnimationFrame(animation: AvifAnimation, index: number): Promise<AvifAnimationFrame | null>;
  /** Closes the animation and discards any pending frame. */
  closeAvifAnimation(animation: AvifAnimation): void;
}

declare const nuwaAvif: NuwaAvif;
export default nuwaAvif;
