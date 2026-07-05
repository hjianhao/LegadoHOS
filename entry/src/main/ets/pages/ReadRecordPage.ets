import { AppTheme } from '../theme/AppTheme';

@Entry
@Component
export struct ReadRecordPage {
  @StorageLink('isDark') isDark: boolean = false;
  aboutToAppear(): void { this.isDark = AppTheme.getInstance().isDark; }

  build() {
    Column() {
      Text('\uD83D\uDCCA 阅读记录').fontSize(20).fontWeight(FontWeight.Bold)
        .alignSelf(ItemAlign.Start).padding(16)
      Row() {
        Column() {
          Text('0').fontSize(32).fontColor('#0078D7').fontWeight(FontWeight.Bold)
          Text('总阅读时长').fontSize(12).fontColor('#888').margin({ top: 4 })
        }.layoutWeight(1).alignItems(HorizontalAlign.Center)
        Column() {
          Text('0').fontSize(32).fontColor('#4CAF50').fontWeight(FontWeight.Bold)
          Text('阅读天数').fontSize(12).fontColor('#888').margin({ top: 4 })
        }.layoutWeight(1).alignItems(HorizontalAlign.Center)
        Column() {
          Text('0').fontSize(32).fontColor('#FF9800').fontWeight(FontWeight.Bold)
          Text('已读书籍').fontSize(12).fontColor('#888').margin({ top: 4 })
        }.layoutWeight(1).alignItems(HorizontalAlign.Center)
      }.padding(24).width('100%')
      Column() {
        Text('暂无阅读记录').fontSize(14).fontColor('#888').margin({ top: 40 })
      }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Center)
    }
    .width('100%').height('100%').backgroundColor(this.isDark ? '#121212' : '#F5F5F5')
  }
}
