/** 阅读菜单中的章节进度与前后章导航。 */
import { ThemeColors } from '../../theme/ThemeColors';

@Component
export struct ReadProgressBar {
  @StorageLink('isDark') isDark: boolean = false;
  @Prop currentIndex: number = 0;
  @Prop total: number = 0;
  onPrevious?: () => void;
  onNext?: () => void;
  onSeek?: (index: number) => void;

  private percent_(): number {
    if (this.total <= 1) return this.total === 1 ? 100 : 0;
    return Math.round(this.currentIndex * 100 / (this.total - 1));
  }

  build() {
    Row() {
      Button('上一章')
        .width(68).height(48)
        .fontSize(12)
        .fontColor(this.currentIndex > 0 ? ThemeColors.onSurface(this.isDark) : ThemeColors.secondaryText(this.isDark))
        .backgroundColor(ThemeColors.transparent())
        .enabled(this.currentIndex > 0)
        .onClick(() => { this.onPrevious?.(); })

      Column() {
        Text(this.total > 0
          ? `${this.currentIndex + 1}/${this.total} 章 · ${this.percent_()}%`
          : '暂无章节进度')
          .fontSize(11)
          .fontColor(ThemeColors.secondaryText(this.isDark))
          .maxLines(1)
        Slider({
          value: Math.min(Math.max(1, this.currentIndex + 1), Math.max(1, this.total)),
          min: 1,
          max: Math.max(1, this.total),
          step: 1,
          style: SliderStyle.OutSet,
        })
          .height(30)
          .selectedColor(ThemeColors.primary(this.isDark))
          .blockColor(ThemeColors.primary(this.isDark))
          .trackColor(ThemeColors.outlineVariant(this.isDark))
          .enabled(this.total > 1)
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              const target = Math.round(value) - 1;
              if (target !== this.currentIndex) this.onSeek?.(target);
            }
          })
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)

      Button('下一章')
        .width(68).height(48)
        .fontSize(12)
        .fontColor(this.currentIndex < this.total - 1
          ? ThemeColors.onSurface(this.isDark) : ThemeColors.secondaryText(this.isDark))
        .backgroundColor(ThemeColors.transparent())
        .enabled(this.currentIndex < this.total - 1)
        .onClick(() => { this.onNext?.(); })
    }
    .width('100%')
    .height(64)
    .padding({ left: 4, right: 4 })
    .backgroundColor(ThemeColors.surface(this.isDark))
    .border({ width: { bottom: 0.5 }, color: ThemeColors.outlineVariant(this.isDark) })
  }
}
