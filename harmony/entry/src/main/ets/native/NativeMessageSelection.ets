import { deviceInfo } from '@kit.BasicServicesKit';
import lazy { SelectionContainer, SelectionContainerTextJoinStyle } from '@kit.ArkUI';
import type { SelectionContainerAttribute } from '@kit.ArkUI';

@Component
export struct NativeMessageSelection {
  @BuilderParam content: () => void;

  build() {
    Column() {
      if (deviceInfo.apiAvailable('26.0.0')) {
        SelectionContainer() {
          this.content()
        }
        .width('100%')
        .align(Alignment.TopStart)
        .copyOption(CopyOptions.LocalDevice)
        .textJoinStyle(SelectionContainerTextJoinStyle.NEWLINE)
      } else {
        this.content()
      }
    }
    .width('100%')
  }
}
