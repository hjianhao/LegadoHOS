import { ThemeColors } from '../theme/ThemeColors';

@Component
struct ErrorPage {
  @StorageLink('isDark') isDark: boolean = false;
  build() {
    Column() {
      Text($r('app.string.ui_76e163cfa2')).fontSize(64).margin({ bottom: 16 })
      Text($r('app.string.ui_965c956cb1')).fontSize(20).fontWeight(FontWeight.Bold)
      Text($r('app.string.ui_232ec8d773')).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 8 })
    }
    .width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
  }
}
