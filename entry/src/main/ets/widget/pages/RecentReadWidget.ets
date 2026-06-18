/**
 * 最近阅读桌面小组件
 *
 * FormExtensionAbility 的实现需要注册到 module.json5
 * 此处为 ArkUI 小组件页面。
 *
 * HarmonyOS Widget 组件使用 @ohos.form.formExtension 生命周期。
 */
@Component
export struct RecentReadWidget {
  @State bookName: string = '';
  @State chapterTitle: string = '';
  @State progress: number = 0;
  @State bookCover: string = '';

  build() {
    Column() {
      Row() {
        if (this.bookCover) {
          Image(this.bookCover)
            .width(48).height(64)
            .borderRadius(4)
            .margin({ right: 8 })
        } else {
          Column() {
            Text((this.bookName || '📚').charAt(0))
              .fontSize(24).fontColor('#FFF')
          }
          .width(48).height(64)
          .backgroundColor('#455A64')
          .borderRadius(4)
          .margin({ right: 8 })
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        }

        Column() {
          Text(this.bookName || '点击开始阅读')
            .fontSize(14).fontWeight(FontWeight.Bold)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .alignSelf(ItemAlign.Start)

          if (this.chapterTitle) {
            Text(this.chapterTitle)
              .fontSize(11).fontColor('#888')
              .maxLines(1)
              .alignSelf(ItemAlign.Start)
              .margin({ top: 2 })
          }

          Row() {
            // 进度条
            Column()
              .width(`${Math.min(100, this.progress * 100)}%`)
              .height(3)
              .backgroundColor('#0078D7')
              .borderRadius(2)
          }
          .width('100%').height(3)
          .backgroundColor('#333')
          .borderRadius(2)
          .margin({ top: 4 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .padding(12)
    }
    .width('100%').height('100%')
    .backgroundColor('#FFFFFF')
    .borderRadius(8)
    .onClick(() => {
      // 打开书籍
      console.info('[Widget] Open book');
    })
  }
}
