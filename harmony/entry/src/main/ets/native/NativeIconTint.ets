import { ColorMetrics } from '@kit.ArkUI';

export function nativeIconTint(color: ResourceColor): number[] {
  const tint = ColorMetrics.resourceColor(color);
  return [
    0, 0, 0, 0, tint.red / 255,
    0, 0, 0, 0, tint.green / 255,
    0, 0, 0, 0, tint.blue / 255,
    0, 0, 0, tint.alpha / 255, 0,
  ];
}
