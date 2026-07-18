import { AppTheme } from '../theme/AppTheme';
import { ThemeColors } from '../theme/ThemeColors';

@Entry
@Component
struct AboutPage {
  @StorageLink('isDark') isDark: boolean = false;
  aboutToAppear(): void { this.isDark = AppTheme.getInstance().isDark; }

  build() {
    Column() {
      Text($r('app.string.ui_5a35cf6119')).fontSize(20).fontWeight(FontWeight.Bold)
        .fontColor(ThemeColors.onBackground(this.isDark))
        .alignSelf(ItemAlign.Start).padding(16)
      Text($r('app.string.ui_b48ed8db6e')).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 40 })
    }
    .width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
  }
}
