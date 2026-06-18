import { AppTheme } from '../theme/AppTheme';

@Entry
@Component
export struct AboutPage {
  @State isDark: boolean = false;
  aboutToAppear(): void { this.isDark = AppTheme.getInstance().isDark; }

  build() {
    Column() {
      Text('AboutPage').fontSize(20).fontWeight(FontWeight.Bold)
        .alignSelf(ItemAlign.Start).padding(16)
      Text('功能开发中').fontSize(14).fontColor('#888').margin({ top: 40 })
    }
    .width('100%').height('100%').backgroundColor(this.isDark ? '#121212' : '#F5F5F5')
  }
}
