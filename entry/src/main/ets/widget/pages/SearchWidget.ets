/**
 * 快速搜索小组件
 * 一键打开搜索页面
 */
@Component
export struct SearchWidget {
  build() {
    Column() {
      Text('🔍').fontSize(28)
      Text('搜索').fontSize(12).fontColor('#888').margin({ top: 4 })
    }
    .width('100%').height('100%')
    .backgroundColor('#FFFFFF')
    .borderRadius(8)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      // 打开搜索页面
      console.info('[Widget] Open search');
    })
  }
}
