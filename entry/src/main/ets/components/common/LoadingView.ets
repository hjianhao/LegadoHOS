/**
 * 通用加载视图
 */
@Component
export struct LoadingView {
  @Prop message: string;

  build() {
    Column() {
      LoadingProgress()
        .color('#0078D7')
        .width(48)
        .height(48)
      Text(this.message)
        .fontSize(14)
        .fontColor('#888')
        .margin({ top: 16 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}

@Component
export struct EmptyView {
  @Prop message: string;
  @Prop icon: ResourceStr;

  build() {
    Column() {
      Text(this.icon)
        .fontSize(48)
        .margin({ bottom: 16 })
      Text(this.message)
        .fontSize(15)
        .fontColor('#888')
        .textAlign(TextAlign.Center)
        .lineHeight(22)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
