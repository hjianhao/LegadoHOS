/**
 * 横屏排版设置面板（单页/双页切换）
 * 从阅读菜单打开，独立于风格设置面板。
 */
import { ThemeColors } from '../../theme/ThemeColors';

@Component
export struct LandscapeLayoutPanel {
  @StorageLink('isDark') isDark: boolean = false;
  /** 当前排版模式：'single' | 'dual' */
  mode: string = 'single';
  onDismiss?: () => void;
  onChange?: (mode: string) => void;

  build() {
    Column() {
      // 标题栏
      Row() {
        Text('横屏排版').fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark)).layoutWeight(1)
        Button($r('app.string.ui_0951b9a022')).fontSize(16)
          .fontColor(ThemeColors.secondaryText(this.isDark))
          .backgroundColor(ThemeColors.transparent())
          .accessibilityText($r('app.string.common_close'))
          .onClick(() => { this.onDismiss?.(); })
      }.width('100%').padding({ left: 16, right: 12, top: 12, bottom: 8 })

      // 选项
      Row() {
        this.modeChip('单页', 'single')
        this.modeChip('双页', 'dual')
      }.width('100%').padding({ left: 16, right: 16, bottom: 16 })

      Text('单页模式内容铺满屏幕；双页模式左右并排连续两页。')
        .fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark))
        .width('100%').padding({ left: 16, right: 16, bottom: 16 })
    }
    .width('100%')
    .backgroundColor(ThemeColors.surface(this.isDark))
    .borderRadius({ topLeft: 16, topRight: 16 })
  }

  @Builder
  modeChip(label: string, value: string) {
    Column() {
      Text(label).fontSize(14)
        .fontColor(this.mode === value ? ThemeColors.onPrimary(this.isDark) : ThemeColors.onSurface(this.isDark))
        .padding({ top: 10, bottom: 10, left: 32, right: 32 })
    }
    .backgroundColor(this.mode === value ? ThemeColors.primary(this.isDark) : ThemeColors.surfaceVariant(this.isDark))
    .borderRadius(20).margin({ right: 12 })
    .onClick(() => {
      this.onChange?.(value);
    })
  }
}
