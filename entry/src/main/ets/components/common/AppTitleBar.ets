import { ThemeColors } from '../../theme/ThemeColors';
import { WindowSizeClass } from '../../util/WindowLayout';

/** 全局统一的页面返回按钮：48vp 点击区域、系统 Symbol 和无障碍语义。 */
@Component
export struct AppBackButton {
  @StorageLink('isDark') isDark: boolean = false;
  onBack: () => void = () => {};

  build() {
    Button() {
      SymbolGlyph($r('sys.symbol.chevron_backward'))
        .fontSize(24)
        .fontColor([ThemeColors.onSurface(this.isDark)])
    }
    .width(48)
    .height(48)
    .padding(0)
    .borderRadius(24)
    .backgroundColor(ThemeColors.transparent())
    .accessibilityText($r('app.string.common_back'))
    .onClick(() => { this.onBack(); })
  }
}

/**
 * 无右侧操作的标准二级页面标题栏。
 *
 * 平板适配：
 * - 宽屏时 expandSafeArea 让标题栏延伸到状态栏下方
 * - 内容最大宽度限制，避免横屏拉伸过宽
 * - 低高度模式（横屏）压缩高度到 48vp
 */
@Component
export struct AppTitleBar {
  @StorageLink('isDark') isDark: boolean = false;
  @StorageProp('windowSizeClass') sizeClass: WindowSizeClass = WindowSizeClass.COMPACT;
  @StorageProp('windowIsLowHeight') isLowHeight: boolean = false;
  title: ResourceStr = '';
  onBack: () => void = () => {};

  private get barHeight(): number {
    return this.isLowHeight ? 48 : 56;
  }

  build() {
    Row() {
      // 用 Row + Blank 居中限宽，避免宽屏标题栏横跨整屏
      Blank().layoutWeight(this.sizeClass >= WindowSizeClass.MEDIUM ? 1 : 0)
      Row() {
        AppBackButton({ onBack: this.onBack })
        Text(this.title)
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onSurface(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .constraintSize({ maxWidth: this.sizeClass >= WindowSizeClass.MEDIUM ? 1200 : Number.MAX_SAFE_INTEGER })
      .height(this.barHeight)
      .padding({ left: 4, right: 12 })
      Blank().layoutWeight(this.sizeClass >= WindowSizeClass.MEDIUM ? 1 : 0)
    }
    .width('100%')
    .height(this.barHeight)
    .backgroundColor(ThemeColors.surface(this.isDark))
    .border({ width: { bottom: 0.5 }, color: ThemeColors.outlineVariant(this.isDark) })
    // 宽屏时延伸到状态栏区域，避免硬编码 top padding
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
  }
}
