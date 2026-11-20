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
  @Prop fontScale: number = 1;
  @Prop sources: NativeChatSource[] = [];
  @Prop title: string = '参考资料';
  @State private failedSiteIcons: string[] = [];
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
  private siteIcon(source: NativeChatSource) {
    Row() {
      if (source.siteIcon && !this.failedSiteIcons.includes(source.siteIcon)) {
        Image(source.siteIcon).width(18).height(18).objectFit(ImageFit.Cover).autoResize(true)
          .borderRadius(9)
          .onError((): void => {
            if (!this.failedSiteIcons.includes(source.siteIcon ?? '')) {
              this.failedSiteIcons = this.failedSiteIcons.concat([source.siteIcon ?? '']);
            }
          })
      } else {
        Image($r('app.media.native_web_search')).width(12).height(12)
          .colorFilter(nativeIconTint($r('app.color.native_chat_caption')))
      }
    }
    .width(18).height(18).borderRadius(9).backgroundColor($r('app.color.native_chat_citation_bg'))
    .clip(true)
  }

  @Builder
  private card(source: NativeChatSource) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 6 }) {
        Row({ space: 6 }) {
          this.siteIcon(source)
          if (source.siteName) {
            Text(source.siteName).fontSize(13 * this.fontScale).lineHeight(17 * this.fontScale)
              .fontWeight(FontWeight.Medium).fontColor($r('app.color.native_chat_caption'))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).constraintSize({ maxWidth: '65%' })
          }
          if (source.siteName && source.publishedAt) {
            Divider().vertical(true).strokeWidth(1).color($r('app.color.native_chat_stroke'))
              .width(1).height(12).margin({ left: 3, right: 3 })
          }
          if (source.publishedAt) {
            Text(sourceDate(source.publishedAt)).fontSize(13 * this.fontScale).lineHeight(17 * this.fontScale)
              .fontWeight(FontWeight.Regular).fontColor($r('app.color.native_chat_caption'))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%').alignItems(VerticalAlign.Center)
        Column({ space: 6 }) {
          Text(source.title).fontSize(14 * this.fontScale).lineHeight(22 * this.fontScale)
            .fontWeight(FontWeight.Medium).fontColor($r('app.color.native_chat_primary')).maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (source.snippet) {
            Text(source.snippet).fontSize(13 * this.fontScale).lineHeight(20 * this.fontScale)
              .fontColor($r('app.color.native_chat_caption')).maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%').alignItems(HorizontalAlign.Start)
      }
      .width('100%').alignItems(HorizontalAlign.Start)
    }
    .width('100%').padding(12).borderRadius(12)
    .backgroundColor($r('app.color.native_chat_surface'))
    .onClick(() => { void this.openSource(source); })
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Text(this.title === '参考资料' ? this.text('参考资料', 'Sources') : this.title)
          .layoutWeight(1).fontSize(14 * this.fontScale).lineHeight(22).fontWeight(FontWeight.Medium)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor($r('app.color.native_chat_primary'))
        Button('×', { type: ButtonType.Normal, buttonStyle: ButtonStyleMode.TEXTUAL }).width(38).height(36)
          .fontSize(24).fontColor($r('app.color.native_chat_secondary')).padding(0)
          .accessibilityText(this.text('关闭', 'Close')).onClick(() => { this.onClose(); })
      }
      .width('100%').padding({ left: 2 })
      List({ space: 6 }) {
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
    .padding({ left: 8, right: 8, top: 12, bottom: 16 })
  }
}
