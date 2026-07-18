import { ThemeColors } from '../theme/ThemeColors';

@Entry
@Component
struct SimplePage {
  @StorageLink('isDark') isDark: boolean = false;
  build() {
    Column() {
      Text($r('app.string.ui_640ab2bae0'))
        .fontSize(30)
        .fontColor(ThemeColors.error(this.isDark))
        .margin({ top: 200 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemeColors.background(this.isDark))
  }
}
