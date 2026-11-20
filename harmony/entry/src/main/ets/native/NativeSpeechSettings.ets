import { HarmonySpeechEngine, HarmonySpeechVoice } from '../speech/HarmonySpeechOptions';
import { NativeLocale } from './NativeLocation';

@Component
export struct NativeSpeechSettings {
  @Prop locale: NativeLocale = 'zh-CN';
  @Prop engine: HarmonySpeechEngine = 'auto';
  @Prop voice: HarmonySpeechVoice = 'stella';
  @Prop cloudRecognition: boolean = false;
  @Prop cloudSynthesis: boolean = false;
  onEngine: (engine: HarmonySpeechEngine) => void = (_engine: HarmonySpeechEngine) => {};
  onVoice: (voice: HarmonySpeechVoice) => void = (_voice: HarmonySpeechVoice) => {};

  private label(chinese: string, english: string): string {
    return this.locale === 'en-US' ? english : chinese;
  }

  private canSelectEngine(): boolean {
    return this.cloudRecognition || this.cloudSynthesis;
  }

  private hint(): string {
    if (this.engine === 'native' || !this.canSelectEngine()) {
      return this.label('在设备上进行语音输入和朗读，支持离线英文听写。',
        'Uses on-device speech and supports offline English dictation.');
    }
    if (!this.cloudSynthesis) {
      return this.label('语音识别可能将录音发送给配置的服务，朗读在设备上完成。',
        'Dictation may send recordings to the configured service. Read-aloud runs on the device.');
    }
    if (this.engine === 'cloud') {
      return this.label('云端语音会将录音或朗读文本发送给配置的语音服务。',
        'Cloud speech sends recordings or read-aloud text to the configured speech service.');
    }
    return this.label('自动选择设备或云端语音，使用云端时会发送录音或朗读文本。',
      'Uses on-device or cloud speech automatically. The cloud service receives recordings or read-aloud text when used.');
  }

  build() {
    Column({ space: 10 }) {
      Column() {
        Row() {
          Text(this.label('语音引擎', 'Speech engine')).layoutWeight(1).fontSize(15)
            .fontColor($r('app.color.native_chat_primary'))
          if (this.canSelectEngine()) {
            Select([{ value: this.label('自动', 'Auto') }, { value: this.label('设备原生', 'On-device') },
              { value: this.label('云端', 'Cloud') }])
              .selected(this.engine === 'native' ? 1 : this.engine === 'cloud' ? 2 : 0)
              .value(this.engine === 'native' ? this.label('设备原生', 'On-device') :
                this.engine === 'cloud' ? this.label('云端', 'Cloud') : this.label('自动', 'Auto'))
              .accessibilityText(this.label('语音引擎', 'Speech engine'))
              .onSelect((index: number) => { this.onEngine(index === 1 ? 'native' : index === 2 ? 'cloud' : 'auto'); })
          } else {
            Text(this.label('设备原生', 'On-device')).fontSize(13).fontColor($r('app.color.native_chat_secondary'))
          }
        }
        .width('100%').height(48).padding({ left: 15, right: 12 })
        if (this.engine !== 'native') {
          Divider().color($r('app.color.native_chat_stroke')).margin({ left: 14 })
          Row() {
            Text(this.label('朗读音色', 'Read-aloud voice')).layoutWeight(1).fontSize(15)
              .fontColor($r('app.color.native_chat_primary'))
            Select([{ value: this.label('海星（女声）', 'Stella (female)') },
              { value: this.label('暗潮（男声）', 'Tide (male)') }])
              .selected(this.voice === 'tide' ? 1 : 0)
              .value(this.voice === 'tide' ? this.label('暗潮（男声）', 'Tide (male)') :
                this.label('海星（女声）', 'Stella (female)'))
              .accessibilityText(this.label('朗读音色', 'Read-aloud voice'))
              .onSelect((index: number) => { this.onVoice(index === 1 ? 'tide' : 'stella'); })
          }
          .width('100%').height(48).padding({ left: 15, right: 12 })
        }
      }
      .width('100%').borderRadius(16).clip(true).backgroundColor($r('app.color.native_chat_surface'))
      Text(this.hint()).width('100%').fontSize(12).fontColor($r('app.color.native_chat_secondary')).padding({ left: 9 })
    }
    .width('100%')
  }
}
