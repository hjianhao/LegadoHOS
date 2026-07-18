/**
 * TTS 朗读控制面板
 */
import { ThemeColors } from '../../theme/ThemeColors';

@Component
export struct TtsControlPanel {
  @StorageLink('isDark') isDark: boolean = false;
  @Prop playLabel: string = '播放';
  @Prop speed: number = 50;
  @State showVoiceSelect: boolean = false;
  /** 可用音色列表 */
  @Prop voices: string = '';
  /** 当前音色索引 */
  @Prop currentVoice: number = 0;
  @Prop voiceStatuses: string = '';
  onPlayPause?: () => void;
  onStop?: () => void;
  onPrevChapter?: () => void;
  onNextChapter?: () => void;
  onSpeedChange?: (speed: number) => void;
  onDismiss?: () => void;
  onVoiceChange?: (person: number) => void;

  build() {
    Column() {
      Column().layoutWeight(1).width('100%')
        .onClick(() => { this.onDismiss?.(); })
      Column() {
        // 语速控制
        Row() {
          Text($r('app.string.ui_747374775d')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark))
          Slider({ value: this.speed, min: 0, max: 100, step: 5 })
            .layoutWeight(1).margin({ left: 8, right: 8 })
            .onChange((v: number) => { this.onSpeedChange?.(v); })
          Text(String(Math.round(this.speed))).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).width(30)
        }.width('100%').padding({ left: 16, right: 16, top: 12 })

        // 音色选择
        Row() {
          Text($r('app.string.ui_c4301894a2')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark))
          if (this.voices) {
            Text(this.voices.split(',')[this.currentVoice] || '未知')
              .fontSize(13).fontColor(ThemeColors.primary(this.isDark)).margin({ left: 8 })
          } else {
            Text($r('app.string.common_loading')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ left: 8 })
          }
          Blank()
          Button($r('app.string.ui_2f116b7d1c')).fontSize(12).height(40).padding({ left: 12, right: 12 })
            .backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark)).borderRadius(15)
            .onClick(() => { this.showVoiceSelect = !this.showVoiceSelect; })
        }.width('100%').padding({ left: 16, right: 16, top: 8 })

        // 音色列表
        if (this.showVoiceSelect && this.voices) {
          this.voiceListContent()
        }

        Row() {
          Button($r('app.string.ui_1393bb2a70')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark))
            .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).borderRadius(18).height(40)
            .padding({ left: 12, right: 12 })
            .onClick(() => { this.onPrevChapter?.(); })
          Button(this.playLabel).fontSize(14).fontColor(ThemeColors.onPrimary(this.isDark))
            .backgroundColor(ThemeColors.primary(this.isDark)).borderRadius(20).height(40)
            .padding({ left: 20, right: 20 })
            .onClick(() => { this.onPlayPause?.(); })
          Button($r('app.string.ui_1b061d776b')).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark))
            .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).borderRadius(18).height(40)
            .padding({ left: 12, right: 12 })
            .onClick(() => { this.onNextChapter?.(); })
          Button($r('app.string.common_stop')).fontSize(14).fontColor(ThemeColors.onPrimary(this.isDark))
            .backgroundColor(ThemeColors.error(this.isDark)).borderRadius(18).height(40)
            .padding({ left: 16, right: 16 })
            .onClick(() => { this.onStop?.(); })
        }.width('100%').justifyContent(FlexAlign.Center).margin({ top: 10, bottom: 16 })
      }.width('100%').backgroundColor(ThemeColors.surface(this.isDark)).borderRadius(12)
    }.width('100%').height('100%').backgroundColor('rgba(0,0,0,0.3)')
  }

  @Builder
  voiceListContent() {
    Scroll() {
      Column() {
        ForEach(this.voices.split(','), (name: string, idx: number) => {
          Row() {
            Text(name + (this.voiceStatuses.split(',')[idx] === 'GA' ? '（需下载）' : '（可用）')).fontSize(13)
              .fontColor(idx === this.currentVoice ? ThemeColors.primary(this.isDark) : ThemeColors.onSurface(this.isDark))
            if (idx === this.currentVoice) {
              Text($r('app.string.ui_be5522d56c')).fontSize(13).fontColor(ThemeColors.primary(this.isDark))
            }
          }
          .width('100%').padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .backgroundColor(idx === this.currentVoice ? ThemeColors.primaryContainer(this.isDark) : ThemeColors.transparent())
          .borderRadius(6)
          .onClick(() => {
            this.onVoiceChange?.(idx);
            this.showVoiceSelect = false;
          })
        })
      }.width('100%')
    }.width('100%').height(140)
  }
}
