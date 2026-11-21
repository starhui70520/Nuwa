import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { prepareNativeContinuation, restoreNativeContinuationFromWant } from '../native/NativeContinuity';
import { parseIncomingShareWant, publishIncomingSharePayload } from '../native/NativeHarmonyShare';

export const NUWA_MAIN_WINDOW_ID_KEY: string = 'nuwa_main_window_id';

export default class EntryAbility extends UIAbility {
  private handleWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    if (launchParam.launchReason === AbilityConstant.LaunchReason.CONTINUATION) {
      void restoreNativeContinuationFromWant(this.context, want);
      return;
    }
    void parseIncomingShareWant(want).then((payload) => {
      if (payload) publishIncomingSharePayload(payload);
    }).catch(() => {});
  }

  private loadMainStage(windowStage: window.WindowStage): void {
    windowStage.getMainWindow().then((mainWindow: window.Window): void => {
      try {
        const props = mainWindow.getWindowProperties();
        if (props?.id > 0) {
          AppStorage.setOrCreate<number>(NUWA_MAIN_WINDOW_ID_KEY, props.id);
        }
      } catch {
        // Ignore window property errors on restricted hosts.
      }
    }).catch(() => {});

    windowStage.loadContent('pages/NativeChat', (err) => {
      if (err.code) {
        return;
      }
    });
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.handleWant(want, launchParam);
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.handleWant(want, launchParam);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.loadMainStage(windowStage);
  }

  onWindowStageRestore(windowStage: window.WindowStage): void {
    this.loadMainStage(windowStage);
  }

  async onContinue(wantParam: Record<string, Object>): Promise<AbilityConstant.OnContinueResult> {
    return prepareNativeContinuation(this.context, wantParam);
  }
}
