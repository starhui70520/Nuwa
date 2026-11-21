import { curves, uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { vibrator } from '@kit.SensorServiceKit';

let cachedImmersiveSupport: boolean | undefined = undefined;

/** Runtime detection for HarmonyOS 26.0.0+ native Immersive Light (沉浸光感) material support. */
export function isImmersiveMaterialAvailable(): boolean {
  if (cachedImmersiveSupport !== undefined) {
    return cachedImmersiveSupport;
  }
  try {
    if (deviceInfo.sdkApiVersion >= 26) {
      cachedImmersiveSupport = uiMaterial.isImmersiveMaterialSupported();
      return cachedImmersiveSupport;
    }
  } catch {
    // Fall back cleanly on older HarmonyOS versions or unsupported targets.
  }
  cachedImmersiveSupport = false;
  return false;
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
 * Floating translucent capsule material for header chrome & floating action pills.
 * Activates native Immersive Light refraction + press deformation + touch glow on HarmonyOS 26+,
 * falling back to frosted glass blur on HarmonyOS 5.0-6.x.
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
      .border({ width: 0.75, color: $r('app.color.native_chat_stroke') })
      .shadow({ radius: 14, color: '#14000000', offsetY: 3 });
    if (isImmersiveMaterialAvailable()) {
      try {
        instance.systemMaterial(new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.THIN,
          materialColor: $r('app.color.native_immersive_tint'),
          applyShadow: false,
          interactive: this.interactive,
          lightEffect: {},
        }));
      } catch {
        // Frosted glass styling above remains active.
      }
    }
  }
}

/**
 * Floating luminous glass dock for the chat composer.
 * Preserves high contrast text legibility while letting scrolled messages glow beneath.
 */
export class ImmersiveComposerModifier implements AttributeModifier<CommonAttribute> {
  private readonly elevated: boolean;

  constructor(elevated: boolean = true) {
    this.elevated = elevated;
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    instance
      .backgroundColor($r('app.color.native_immersive_tint'))
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .border({ width: 1, color: $r('app.color.native_chat_stroke') })
      .shadow({ radius: 18, offsetY: 5, color: '#16000000' });
    if (isImmersiveMaterialAvailable()) {
      try {
        instance.systemMaterial(new uiMaterial.ImmersiveMaterial({
          style: this.elevated ? uiMaterial.ImmersiveStyle.REGULAR : uiMaterial.ImmersiveStyle.THIN,
          materialColor: $r('app.color.native_immersive_tint'),
          applyShadow: false,
          interactive: false,
          lightEffect: {},
        }));
      } catch {
        // Frosted glass styling above remains active.
      }
    }
  }
}

/**
 * Thick immersive glass surface for floating modal dialogs & action sheets.
 */
export class ImmersiveSurfaceModifier implements AttributeModifier<CommonAttribute> {
  applyNormalAttribute(instance: CommonAttribute): void {
    instance
      .backgroundColor($r('app.color.native_chat_surface'))
      .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .border({ width: 1, color: $r('app.color.native_chat_stroke') })
      .shadow({ radius: 22, offsetY: 8, color: '#1E000000' });
    if (isImmersiveMaterialAvailable()) {
      try {
        instance.systemMaterial(new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.THICK,
          materialColor: $r('app.color.native_immersive_tint'),
          applyShadow: false,
          interactive: false,
        }));
      } catch {
        // Frosted glass styling above remains active.
      }
    }
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
