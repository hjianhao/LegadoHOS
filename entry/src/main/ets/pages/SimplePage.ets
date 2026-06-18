@Entry
@Component
struct SimplePage {
  build() {
    Column() {
      Text("Test")
        .fontSize(30)
        .fontColor('#FF0000')
        .margin({ top: 200 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#1A1A2E')
  }
}
