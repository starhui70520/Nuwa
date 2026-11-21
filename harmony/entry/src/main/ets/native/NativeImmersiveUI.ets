import { curves, uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { vibrator } from '@kit.SensorServiceKit';
import { hdsEffect } from '@kit.UIDesignKit';

let cachedImmersiveSupport: boolean | undefined = undefined;
const IMMERSIVE_LOG_DOMAIN = 0x2090;
const IMMERSIVE_LOG_TAG = 'NuwaImmersiveUI';

/** Runtime detection for HarmonyOS 26.0.0+ native Immersive Light (沉浸光感) material support. */
export function isImmersiveMaterialAvailable(): boolean {
  if (cachedImmersiveSupport !== undefined) {
    return cachedImmersiveSupport;
  }
  try {
    if (deviceInfo.sdkApiVersion >= 26) {
      cachedImmersiveSupport = uiMaterial.isImmersiveMaterialSupported();
      const level = cachedImmersiveSupport ? uiMaterial.getGlobalMaterialLevel() : -1;
      const info = uiMaterial.getMaterialInfo();
      hilog.info(IMMERSIVE_LOG_DOMAIN, IMMERSIVE_LOG_TAG,
        'sdkApi=%{public}d supported=%{public}s level=%{public}d state=%{public}d type=%{public}d',
        deviceInfo.sdkApiVersion, String(cachedImmersiveSupport), level, info.state, info.type);
      return cachedImmersiveSupport;
    }
  } catch {
    // Fall back cleanly on older HarmonyOS versions or unsupported targets.
  }
  cachedImmersiveSupport = false;
  return false;
}

/** Runtime detection for HarmonyOS 6.0+ (API 20+) HDS point-light & press-glow visual effects. */
function isHdsPointLightAvailable(): boolean {
  try {
    return deviceInfo.sdkApiVersion >= 20;
  } catch {
    return false;
  }
}

function applyHdsGlassLight(instance: CommonAttribute, interactive: boolean): void {
  if (!isHdsPointLightAvailable()) {
    return;
  }
  try {
    const builder = new hdsEffect.HdsEffectBuilder().pointLight({
      sourceType: interactive ? hdsEffect.PointLightSourceType.SOFT : hdsEffect.PointLightSourceType.NONE,
      illuminatedType: interactive
        ? hdsEffect.PointLightIlluminatedType.BORDER_CONTENT
        : hdsEffect.PointLightIlluminatedType.BORDER,
    });
    if (interactive) {
      builder.pressShadow(hdsEffect.PressShadowType.BLEND_GRADIENT);
    }
    instance.visualEffect(builder.buildEffect());
  } catch {
    // Gracefully skip on HarmonyOS 5.x or devices without HDS lighting pipeline.
  }
}

/** Responsive physics spring matching HarmonyOS native touch-and-release motion. */
export function nativeSpringCurve(response: number = 0.30, dampingFraction: number = 0.86): ICurve {
  return curves.responsiveSpringMotion(response, dampingFraction);
}

/** Smooth physics spring tuned for sidebar drawer open/close and gesture release. */
export function nativeDrawerSpringCurve(): ICurve {
  return curves.responsiveSpringMotion(0.35, 0.90);
}

/** Smooth physics spring tuned for bottom sheet drag rebound and floating panels. */
export function nativeSheetSpringCurve(): ICurve {
  return curves.responsiveSpringMotion(0.32, 0.88);
}

/** Spring scale + opacity transition for floating dialogs and overlays. */
export function nativeDialogTransition(): TransitionEffect {
  return TransitionEffect.OPACITY
    .combine(TransitionEffect.scale({ x: 0.94, y: 0.94 }))
    .animation({ curve: nativeSpringCurve(0.28, 0.86) });
}

/** Spring fade + bottom slide transition for expandable composer toolbars & floating banners. */
export function nativeFloatingBarTransition(): TransitionEffect {
  return TransitionEffect.OPACITY
    .combine(TransitionEffect.move(TransitionEdge.BOTTOM))
    .animation({ curve: nativeSpringCurve(0.28, 0.88) });
}

/** Spring slide-from-end transition for right-side sheets (e.g. sources panel). */
export function nativeSideSheetTransition(): TransitionEffect {
  return TransitionEffect.OPACITY
    .combine(TransitionEffect.move(TransitionEdge.END))
    .animation({ curve: nativeSpringCurve(0.32, 0.90) });
}

/** Spring pop-in / morph transition for dynamic composer action buttons (Send / Stop / Voice) and chips. */
export function nativeActionButtonTransition(): TransitionEffect {
  return TransitionEffect.OPACITY
    .combine(TransitionEffect.scale({ x: 0.62, y: 0.62 }))
    .animation({ curve: nativeSpringCurve(0.26, 0.78) });
}

/** Native HarmonyOS light-weight tactile click feedback options. */
export const NATIVE_ICON_CLICK_EFFECT: ClickEffect = {
  level: ClickEffectLevel.LIGHT,
  scale: 0.90,
};

export const NATIVE_PILL_CLICK_EFFECT: ClickEffect = {
  level: ClickEffectLevel.LIGHT,
  scale: 0.95,
};

export const NATIVE_CARD_CLICK_EFFECT: ClickEffect = {
  level: ClickEffectLevel.LIGHT,
  scale: 0.97,
};

/**
 * Native HarmonyOS 26+ ImmersiveMaterial modifier for Navigation title bar chrome.
 * Because these capsules live inside Navigation().title(..., { barStyle: BarStyle.STACK }),
 * RenderService activates genuine GPU Immersive Light (optical refraction, specular rim,
 * press deformation, and touch light) with zero out-of-scope rejection.
 * Falls back cleanly to high-luminance frosted backgroundEffect + HDS pointLight on API 12-25.
 */
export class ImmersiveGlassCapsuleModifier implements AttributeModifier<CommonAttribute> {
  private readonly interactive: boolean;

  constructor(interactive: boolean = true) {
    this.interactive = interactive;
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    if (isImmersiveMaterialAvailable()) {
      try {
        instance
          .backgroundColor(Color.Transparent)
          .systemMaterial(new uiMaterial.ImmersiveMaterial({
            style: uiMaterial.ImmersiveStyle.THIN,
            applyShadow: true,
            interactive: this.interactive,
            lightEffect: {},
          }));
        return;
      } catch {
        // Fall through to GPU frosted glass fallback.
      }
    }
    instance
      .backgroundColor(Color.Transparent)
      .backgroundEffect({
        radius: 36,
        saturation: 1.5,
        brightness: 1.08,
        color: $r('app.color.native_immersive_composer_tint'),
      })
      .border({ width: 0.75, color: $r('app.color.native_glass_rim') })
      .shadow({ radius: 14, color: $r('app.color.native_glass_shadow'), offsetY: 3 });
    applyHdsGlassLight(instance, this.interactive);
  }
}

/**
 * Floating luminous crystal glass dock for the chat composer.
 * Uses pure GPU backgroundEffect (44px blur, boosted saturation & brightness, low-alpha smoked/crystal tint)
 * + delicate luminous glass rim + subtle top specular sheen + HDS pointLight so scrolled messages
 * genuinely refract and glow behind the composer across both light and dark modes (API 12-26+).
 */
export class ImmersiveComposerModifier implements AttributeModifier<CommonAttribute> {
  private readonly elevated: boolean;

  constructor(elevated: boolean = true) {
    this.elevated = elevated;
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    instance
      .backgroundColor(Color.Transparent)
      .backgroundEffect({
        radius: this.elevated ? 44 : 32,
        saturation: 1.6,
        brightness: 1.1,
        color: $r('app.color.native_immersive_composer_tint'),
      })
      .linearGradient({
        direction: GradientDirection.Bottom,
        colors: [
          [$r('app.color.native_glass_sheen'), 0.0],
          ['#00FFFFFF', 0.35],
        ],
      });
    applyHdsGlassLight(instance, true);
  }
}

/**
 * Luminous floating glass button modifier for sheet/modal circular controls (e.g. Back / Close)
 * outside Navigation title bar, matching HarmonyOS 7.0 Immersive Light depth & specular rim.
 */
export class ImmersiveGlassControlModifier implements AttributeModifier<CommonAttribute> {
  applyNormalAttribute(instance: CommonAttribute): void {
    instance
      .backgroundColor(Color.Transparent)
      .backgroundEffect({
        radius: 28,
        saturation: 1.5,
        brightness: 1.1,
        color: $r('app.color.native_immersive_composer_tint'),
      })
      .border({ width: 0.75, color: $r('app.color.native_glass_rim') })
      .shadow({ radius: 10, offsetY: 2, color: $r('app.color.native_glass_shadow') });
    applyHdsGlassLight(instance, true);
  }
}

/**
 * Thick frosted glass surface for floating modal dialogs & action sheets.
 */
export class ImmersiveSurfaceModifier implements AttributeModifier<CommonAttribute> {
  applyNormalAttribute(instance: CommonAttribute): void {
    instance
      .backgroundColor(Color.Transparent)
      .backgroundEffect({
        radius: 48,
        saturation: 1.5,
        brightness: 1.08,
        color: $r('app.color.native_immersive_composer_tint'),
      })
      .border({ width: 0.85, color: $r('app.color.native_glass_rim') })
      .shadow({ radius: 24, offsetY: 8, color: '#2E000000' });
    applyHdsGlassLight(instance, false);
  }
}

export type NativeHapticStyle = 'light' | 'medium' | 'selection' | 'success' | 'warning';

let nativeHapticEnabled: boolean = true;

export function setNativeHapticEnabled(enabled: boolean): void {
  nativeHapticEnabled = enabled;
}

export function isNativeHapticEnabled(): boolean {
  return nativeHapticEnabled;
}

function resolveHapticCandidates(style: NativeHapticStyle): string[] {
  switch (style) {
    case 'medium':
      return ['haptic.effect.hard', 'haptic.effect.soft'];
    case 'selection':
      return ['haptic.effect.sharp', 'haptic.clock.timer', 'haptic.effect.soft'];
    case 'success':
      return ['haptic.notice.success', 'haptic.effect.soft'];
    case 'warning':
      return ['haptic.notice.warning', 'haptic.effect.hard', 'haptic.effect.soft'];
    default:
      return ['haptic.effect.soft'];
  }
}

/** Subtle system haptic feedback matching HarmonyOS native touch feel. */
export function triggerNativeHaptic(style: NativeHapticStyle = 'light'): void {
  if (!nativeHapticEnabled) {
    return;
  }
  try {
    const candidates = resolveHapticCandidates(style);
    for (let i = 0; i < candidates.length; i++) {
      const effectId = candidates[i];
      if (vibrator.isSupportEffectSync(effectId)) {
        void vibrator.startVibration(
          { type: 'preset', effectId: effectId, count: 1 },
          { id: 0, usage: 'touch' }
        ).catch(() => {});
        return;
      }
    }
    const duration = style === 'warning' ? 18 : style === 'medium' ? 14 : style === 'success' ? 10 : 7;
    void vibrator.startVibration(
      { type: 'time', duration },
      { id: 0, usage: 'touch' }
    ).catch(() => {});
  } catch {
    // Ignore on simulators or devices without vibrator hardware.
  }
}
