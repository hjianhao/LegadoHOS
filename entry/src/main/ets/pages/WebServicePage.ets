import { AppTheme } from '../theme/AppTheme';
import { ThemeColors } from '../theme/ThemeColors';

@Entry
@Component
struct WebServicePage {
  @StorageLink('isDark') isDark: boolean = false;
  aboutToAppear(): void { this.isDark = AppTheme.getInstance().isDark; }

  build() {
    Column() {
      Text('WebServicePage').fontSize(20).fontWeight(FontWeight.Bold)
        .fontColor(ThemeColors.onBackground(this.isDark))
        .alignSelf(ItemAlign.Start).padding(16)
      Text('功能开发中').fontSize(14).fontColor('#888').margin({ top: 40 })
    }
    .width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
  }
}
