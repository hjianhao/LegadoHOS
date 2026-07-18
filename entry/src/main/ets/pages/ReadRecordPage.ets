import { AppTheme } from '../theme/AppTheme';
import { ThemeColors } from '../theme/ThemeColors';

@Entry
@Component
struct ReadRecordPage {
  @StorageLink('isDark') isDark: boolean = false;
  aboutToAppear(): void { this.isDark = AppTheme.getInstance().isDark; }

  build() {
    Column() {
      Text($r('app.string.ui_c3733c356a')).fontSize(20).fontWeight(FontWeight.Bold)
        .fontColor(ThemeColors.onBackground(this.isDark))
        .alignSelf(ItemAlign.Start).padding(16)
      Row() {
        Column() {
          Text($r('app.string.ui_b6589fc6ab')).fontSize(32).fontColor(ThemeColors.primary(this.isDark)).fontWeight(FontWeight.Bold)
          Text($r('app.string.ui_957cc945c1')).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 4 })
        }.layoutWeight(1).alignItems(HorizontalAlign.Center)
        Column() {
          Text($r('app.string.ui_b6589fc6ab')).fontSize(32).fontColor(ThemeColors.success(this.isDark)).fontWeight(FontWeight.Bold)
          Text($r('app.string.ui_962b3a5d34')).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 4 })
        }.layoutWeight(1).alignItems(HorizontalAlign.Center)
        Column() {
          Text($r('app.string.ui_b6589fc6ab')).fontSize(32).fontColor(ThemeColors.warning(this.isDark)).fontWeight(FontWeight.Bold)
          Text($r('app.string.ui_11731fd41d')).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 4 })
        }.layoutWeight(1).alignItems(HorizontalAlign.Center)
      }.padding(24).width('100%')
      Column() {
        Text($r('app.string.ui_367b6ee56c')).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 40 })
      }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Center)
    }
    .width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
  }
}
