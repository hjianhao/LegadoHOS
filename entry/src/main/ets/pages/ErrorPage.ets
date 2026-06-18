@Component
struct ErrorPage {
  build() {
    Column() {
      Text('\u26A0\uFE0F').fontSize(64).margin({ bottom: 16 })
      Text('页面加载失败').fontSize(20).fontWeight(FontWeight.Bold)
      Text('请重启应用或检查日志').fontSize(14).fontColor('#888').margin({ top: 8 })
    }
    .width('100%').height('100%').backgroundColor('#1A1A2E')
    .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
  }
}
