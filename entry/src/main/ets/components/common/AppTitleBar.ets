import { ThemeColors } from '../../theme/ThemeColors';

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

/** 无右侧操作的标准二级页面标题栏。 */
@Component
export struct AppTitleBar {
  @StorageLink('isDark') isDark: boolean = false;
  title: ResourceStr = '';
  onBack: () => void = () => {};

  build() {
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
    .height(56)
    .padding({ left: 4, right: 12 })
    .backgroundColor(ThemeColors.surface(this.isDark))
    .border({ width: { bottom: 0.5 }, color: ThemeColors.outlineVariant(this.isDark) })
  }
}
