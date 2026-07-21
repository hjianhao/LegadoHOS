/** 阅读底部高频菜单。搜索、书签及网络工具由顶部菜单承载。 */
import { ThemeColors } from '../../theme/ThemeColors';
import { ReaderInsets } from '../../util/ReaderInsets';

@Component
export struct ReadBottomMenu {
  @StorageLink('isDark') isDark: boolean = false;
  onToc?: () => void;
  onReadAloud?: () => void;
  onStyle?: () => void;
  onSettings?: () => void;

  build() {
    Row() {
      Column() {
        Text($r('app.string.ui_3a0ea34a22')).fontSize(20).fontColor(ThemeColors.onBackground(this.isDark))
        Text($r('app.string.ui_41e5243e2d')).fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark)).margin({top: 2})
      }.height(48).layoutWeight(1).justifyContent(FlexAlign.Center)
      .accessibilityText($r('app.string.ui_41e5243e2d')).hitTestBehavior(HitTestMode.Block)
      .onClick(() => { console.info('[Menu] 目录 click'); this.onToc?.(); })
      Column() {
        Text($r('app.string.ui_1e358ba2b7')).fontSize(20).fontColor(ThemeColors.onBackground(this.isDark))
        Text($r('app.string.ui_8f84b8a07c')).fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark)).margin({top: 2})
      }.height(48).layoutWeight(1).justifyContent(FlexAlign.Center)
      .accessibilityText($r('app.string.ui_8f84b8a07c')).hitTestBehavior(HitTestMode.Block)
      .onClick(() => { console.info('[Menu] 朗读 click'); this.onReadAloud?.(); })
      Column() {
        Text($r('app.string.ui_e7a0cc5d37')).fontSize(20).fontColor(ThemeColors.onBackground(this.isDark))
        Text($r('app.string.ui_a4ce420c69')).fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark)).margin({top: 2})
      }.height(48).layoutWeight(1).justifyContent(FlexAlign.Center)
      .accessibilityText($r('app.string.ui_280750b313')).onClick(() => { this.onStyle?.() })
      Column() {
        Text($r('app.string.ui_ebbdf13fa6')).fontSize(20).fontColor(ThemeColors.onBackground(this.isDark))
        Text($r('app.string.common_settings')).fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark)).margin({top: 2})
      }.height(48).layoutWeight(1).justifyContent(FlexAlign.Center)
      .accessibilityText($r('app.string.ui_bc0832465e')).onClick(() => { this.onSettings?.() })
    }.width('100%').justifyContent(FlexAlign.SpaceAround)
    .padding({ top: 12, bottom: ReaderInsets.sheetBottomPad(), left: 8, right: 8 })
    .backgroundColor(ThemeColors.surface(this.isDark))
  }
}
