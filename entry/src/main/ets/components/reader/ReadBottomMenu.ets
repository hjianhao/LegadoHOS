/**
 * 阅读底部菜单 — 按钮栏（含回调）
 */
import { ThemeColors } from '../../theme/ThemeColors';

@Component
export struct ReadBottomMenu {
  @StorageLink('isDark') isDark: boolean = false;
  @Prop isLocalBook: boolean = false;
  onToc?: () => void;
  onReadAloud?: () => void;
  onBookmark?: () => void;
  onStyle?: () => void;
  onFont?: () => void;
  onSettings?: () => void;
  onSearch?: () => void;
  onSource?: () => void;
  /** 长按换源：选择整本换源/单章换源（对齐 Legado ReadBookMenuBar） */
  onSourceLongPress?: () => void;
  onCache?: () => void;
  onRefresh?: () => void;

  build() {
    Row() {
      Column() {
        Text($r('app.string.ui_3a0ea34a22')).fontSize(20).fontColor(ThemeColors.onBackground(this.isDark))
        Text($r('app.string.ui_41e5243e2d')).fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark)).margin({top: 2})
      }.height(48).accessibilityText($r('app.string.ui_41e5243e2d')).hitTestBehavior(HitTestMode.Block).onClick(() => { console.info('[Menu] 目录 click'); this.onToc?.(); })
      Column() {
        Text($r('app.string.ui_1e358ba2b7')).fontSize(20).fontColor(ThemeColors.onBackground(this.isDark))
        Text($r('app.string.ui_8f84b8a07c')).fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark)).margin({top: 2})
      }.height(48).accessibilityText($r('app.string.ui_8f84b8a07c')).hitTestBehavior(HitTestMode.Block).onClick(() => { console.info('[Menu] 朗读 click'); this.onReadAloud?.(); })
      Column() {
        Text($r('app.string.ui_ccb920edc1')).fontSize(20).fontColor(ThemeColors.onBackground(this.isDark))
        Text($r('app.string.ui_820f5b6440')).fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark)).margin({top: 2})
      }.height(48).accessibilityText($r('app.string.ui_820f5b6440')).onClick(() => { this.onBookmark?.() })
      Column() {
        Text($r('app.string.ui_e7a0cc5d37')).fontSize(20).fontColor(ThemeColors.onBackground(this.isDark))
        Text($r('app.string.ui_a4ce420c69')).fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark)).margin({top: 2})
      }.height(48).accessibilityText($r('app.string.ui_280750b313')).onClick(() => { this.onStyle?.() })
      Column() {
        Text($r('app.string.ui_ebbdf13fa6')).fontSize(20).fontColor(ThemeColors.onBackground(this.isDark))
        Text($r('app.string.common_settings')).fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark)).margin({top: 2})
      }.height(48).accessibilityText($r('app.string.ui_bc0832465e')).onClick(() => { this.onSettings?.() })
      Column() {
        Text($r('app.string.ui_35d70d63b7')).fontSize(20).fontColor(ThemeColors.onBackground(this.isDark))
        Text($r('app.string.common_search')).fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark)).margin({top: 2})
      }.height(48).accessibilityText($r('app.string.common_search')).onClick(() => { this.onSearch?.() })
      if (!this.isLocalBook) {
        Column() {
          Text($r('app.string.ui_9394cdbfe1')).fontSize(20).fontColor(ThemeColors.onBackground(this.isDark))
          Text($r('app.string.ui_f28106c1d8')).fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark)).margin({top: 2})
        }
        .height(48).accessibilityText($r('app.string.ui_209ae0beeb')).onClick(() => { this.onSource?.() })
        .gesture(
          LongPressGesture({ repeat: false })
            .onAction(() => { this.onSourceLongPress?.(); })
        )
        Column() {
          Text($r('app.string.ui_11f1ad2c76')).fontSize(20).fontColor(ThemeColors.onBackground(this.isDark))
          Text($r('app.string.ui_6cdba4aad0')).fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark)).margin({top: 2})
        }.height(48).accessibilityText($r('app.string.ui_6cdba4aad0')).onClick(() => { this.onCache?.() })
        Column() {
          Text($r('app.string.ui_7b8a6bebd3')).fontSize(20).fontColor(ThemeColors.onBackground(this.isDark))
          Text($r('app.string.common_refresh')).fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark)).margin({top: 2})
        }.height(48).accessibilityText($r('app.string.common_refresh')).onClick(() => { this.onRefresh?.() })
      }
    }.width('100%').justifyContent(FlexAlign.SpaceEvenly)
    .padding({top: 12, bottom: 16, left: 8, right: 8})
    .backgroundColor(ThemeColors.surface(this.isDark))
  }
}
