import { nativeIconTint } from './NativeIconTint';
import { common } from '@kit.AbilityKit';
import { NativeChatSource, safeNativeSourceUrl } from './NativeChatSources';
import { NativeLocale } from './NativeLocation';

function sourceDate(value: string | null): string {
  if (!value) {
    return '';
  }
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) {
    return value;
  }
  return date.getFullYear().toString() + '/' + (date.getMonth() + 1).toString().padStart(2, '0') + '/' +
    date.getDate().toString().padStart(2, '0');
}

@Component
export struct NativeSourcesPanel {
  @Prop locale: NativeLocale = 'zh-CN';
  @Prop sources: NativeChatSource[] = [];
  @Prop title: string = '参考资料';
  onClose: () => void = () => {};

  private text(chinese: string, english: string): string {
    return this.locale === 'zh-CN' ? chinese : english;
  }

  private async openSource(source: NativeChatSource): Promise<void> {
    const href = safeNativeSourceUrl(source.url);
    if (!href) {
      return;
    }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await context.openLink(href, { appLinkingOnly: false });
    } catch {
      this.getUIContext().getPromptAction().showToast({ message: this.text('无法打开链接', 'Unable to open link') });
    }
  }

  @Builder
  private card(source: NativeChatSource) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        Text(source.index.toString()).fontSize(11).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.native_chat_blue_text')).textAlign(TextAlign.Center)
          .width(24).height(24).backgroundColor($r('app.color.native_chat_field')).borderRadius(8)
          .alignSelf(ItemAlign.Start)
        Column({ space: 5 }) {
          Row({ space: 7 }) {
            Text(source.siteName).fontSize(12).fontColor($r('app.color.native_chat_secondary'))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '65%' })
            if (source.publishedAt) {
              Text(sourceDate(source.publishedAt)).fontSize(12).fontColor($r('app.color.native_chat_caption'))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          Text(source.title).fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.native_chat_primary')).maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (source.snippet) {
            Text(source.snippet).fontSize(13).fontColor($r('app.color.native_chat_secondary')).maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .layoutWeight(1).alignItems(HorizontalAlign.Start)
        Image($r('app.media.native_chevron_right')).width(14).height(14)
          .colorFilter(nativeIconTint($r('app.color.native_chat_caption')))
      }
      .width('100%').alignItems(VerticalAlign.Center)
    }
    .width('100%').padding(12).borderRadius(14)
    .backgroundColor($r('app.color.native_chat_surface'))
    .onClick(() => { void this.openSource(source); })
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Text(this.title === '参考资料' ? this.text('参考资料', 'Sources') : this.title)
          .layoutWeight(1).fontSize(18).fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.native_chat_primary'))
        Button('×', { type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }).width(38).height(36)
          .fontSize(24).fontColor($r('app.color.native_chat_secondary')).padding(0)
          .accessibilityText(this.text('关闭', 'Close')).onClick(() => { this.onClose(); })
      }
      .width('100%').padding({ left: 2 })
      List({ space: 8 }) {
        ForEach(this.sources, (source: NativeChatSource) => {
          ListItem() { this.card(source) }
        }, (source: NativeChatSource): string =>
          source.url + source.index.toString() + source.title + source.siteName +
          (source.snippet ?? '') + (source.publishedAt ?? ''))
      }
      .width('100%').layoutWeight(1).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: false })
      .scrollBar(BarState.Auto)
    }
    .width('100%').height('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 16 })
  }
}
