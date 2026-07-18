import { AppTheme } from '../theme/AppTheme';
import { ThemeColors } from '../theme/ThemeColors';

@Entry
@Component
struct BookmarkPage {
  @StorageLink('isDark') isDark: boolean = false;
  aboutToAppear(): void { this.isDark = AppTheme.getInstance().isDark; }

  build() {
    Column() {
      Text($r('app.string.ui_7b1b3f86fe')).fontSize(20).fontWeight(FontWeight.Bold)
        .fontColor(ThemeColors.onBackground(this.isDark))
        .alignSelf(ItemAlign.Start).padding(16)
      Text($r('app.string.ui_b48ed8db6e')).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 40 })
    }
    .width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
  }
}
