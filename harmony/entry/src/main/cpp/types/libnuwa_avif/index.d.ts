export interface AvifFrame {
  width: number;
  height: number;
  /** Tightly packed 8-bit RGBA with straight alpha. */
  rgba: ArrayBuffer;
}

interface NuwaAvif {
  /** Decodes the first frame and applies its AVIF display transforms. */
  decodeAvif(path: string): Promise<AvifFrame | null>;
}

declare const nuwaAvif: NuwaAvif;
export default nuwaAvif;
