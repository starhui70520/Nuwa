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
      hilog.info(IMMERSIVE_LOG_DOMAIN, IMMERSIVE_LOG_TAG,
        'sdkApi=%{public}d immersiveSupported=%{public}s level=%{public}d',
        deviceInfo.sdkApiVersion, String(cachedImmersiveSupport), level);
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
 * Floating luminous glass capsule for header chrome & floating action pills.
 * Note: HarmonyOS 26+ restricts systemMaterial(ImmersiveMaterial) on ordinary page containers
 * outside Navigation titleBar / bottom TabBar (logging "Material inactive: out of scope"),
 * whereas system Menu/Dialog/Sheet/Toggle/Toast get ImmersiveMaterial globally via module.json5.
 * For floating custom chrome, combining GPU BlurStyle + pure translucent crystal fill + specular rim +
 * soft elevation shadow + HarmonyOS 6.0+ HDS pointLight/pressShadow delivers crisp, reliable glass
 * on both pure-white backgrounds and scrolling content across API 12–26+.
 */
export class ImmersiveGlassCapsuleModifier implements AttributeModifier<CommonAttribute> {
  private readonly interactive: boolean;

  constructor(interactive: boolean = true) {
    this.interactive = interactive;
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    instance
      .backgroundColor($r('app.color.native_immersive_tint'))
      .backgroundBlurStyle(BlurStyle.COMPONENT_THIN)
      .border({ width: 0.75, color: $r('app.color.native_glass_rim') })
      .shadow({ radius: 12, color: $r('app.color.native_glass_shadow'), offsetY: 3 });
    applyHdsGlassLight(instance, this.interactive);
  }
}

/**
 * Floating luminous glass dock for the chat composer.
 * Crisp translucent crystal surface with backdrop blur, delicate rim, airy elevation shadow,
 * and HDS border point-light illumination so scrolled messages softly glow beneath.
 */
export class ImmersiveComposerModifier implements AttributeModifier<CommonAttribute> {
  private readonly elevated: boolean;

  constructor(elevated: boolean = true) {
    this.elevated = elevated;
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    instance
      .backgroundColor($r('app.color.native_immersive_composer_tint'))
      .backgroundBlurStyle(this.elevated ? BlurStyle.COMPONENT_THICK : BlurStyle.COMPONENT_THIN)
      .border({ width: 0.75, color: $r('app.color.native_glass_rim') })
      .shadow({ radius: 18, offsetY: 4, color: $r('app.color.native_glass_composer_shadow') });
    applyHdsGlassLight(instance, false);
  }
}

/**
 * Thick frosted glass surface for floating modal dialogs & action sheets.
 */
export class ImmersiveSurfaceModifier implements AttributeModifier<CommonAttribute> {
  applyNormalAttribute(instance: CommonAttribute): void {
    instance
      .backgroundColor($r('app.color.native_chat_surface'))
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .border({ width: 0.75, color: $r('app.color.native_glass_rim') })
      .shadow({ radius: 22, offsetY: 8, color: '#24000000' });
    applyHdsGlassLight(instance, false);
  }
}

export type NativeHapticStyle = 'light' | 'medium' | 'selection';

/** Subtle system haptic feedback matching HarmonyOS native touch feel. */
export function triggerNativeHaptic(style: NativeHapticStyle = 'light'): void {
  try {
    const effectId = style === 'medium'
      ? 'haptic.effect.hard'
      : style === 'selection'
        ? 'haptic.clock.timer'
        : 'haptic.effect.soft';
    if (vibrator.isSupportEffectSync(effectId)) {
      void vibrator.startVibration(
        { type: 'preset', effectId: effectId, count: 1 },
        { id: 0, usage: 'touch' }
      ).catch(() => {});
      return;
    }
    void vibrator.startVibration(
      { type: 'time', duration: style === 'medium' ? 16 : 8 },
      { id: 0, usage: 'touch' }
    ).catch(() => {});
  } catch {
    // Ignore on simulators or devices without vibrator hardware.
  }
}
