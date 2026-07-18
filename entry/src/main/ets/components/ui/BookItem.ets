import { Book } from '../../model/Book';
import { ThemeColors } from '../../theme/ThemeColors';
/**
 * 书籍封面组件（网格模式）
 */
@Component
export struct BookItem {
  @Prop book: Book;
  @Prop isDark: boolean;

  build() {
    Column() {
      // 封面
      Stack() {
        Column() {
          Text(this.book.name?.charAt(0) || '?')
            .fontSize(32)
            .fontColor(ThemeColors.onPrimary(this.isDark))
        }
        .width('100%')
        .aspectRatio(0.72)  // 宽高比例约 5:7
        .backgroundColor(ThemeColors.coverPlaceholder(this.book.name?.charCodeAt(0) || 0))
        .borderRadius(8)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')

      // 书名
      Text(this.book.name)
        .fontSize(13)
        .fontColor(ThemeColors.onBackground(this.isDark))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 4 })
        .width('100%')

      // 作者
      Text(this.book.author)
        .fontSize(11)
        .fontColor(ThemeColors.secondaryText(this.isDark))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width('100%')
    .onClick(() => {
      console.info('[BookItem] Click: ' + this.book.name);
    })
  }
}

/**
 * 书籍列表项（列表模式）
 */
@Component
export struct BookListItem {
  @Prop book: Book;
  @Prop isDark: boolean;

  build() {
    Row() {
      // 封面
      Column() {
        Text(this.book.name?.charAt(0) || '?')
          .fontSize(22)
          .fontColor(ThemeColors.onPrimary(this.isDark))
      }
      .width(50)
      .height(70)
      .backgroundColor(ThemeColors.coverPlaceholder(this.book.name?.charCodeAt(0) || 0))
      .borderRadius(6)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .margin({ right: 12 })

      // 信息
      Column() {
        Text(this.book.name)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .alignSelf(ItemAlign.Start)

        Text(this.book.author)
          .fontSize(13)
          .fontColor(ThemeColors.secondaryText(this.isDark))
          .alignSelf(ItemAlign.Start)
          .margin({ top: 2 })

        Text(`已读 ${(this.book.durChapterProgress * 100).toFixed(1)}%`)
          .fontSize(12)
          .fontColor(ThemeColors.secondaryText(this.isDark))
          .alignSelf(ItemAlign.Start)
          .margin({ top: 4 })

        if (this.book.durChapterTitle) {
          Text(this.book.durChapterTitle)
            .fontSize(11)
            .fontColor(ThemeColors.secondaryText(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .alignSelf(ItemAlign.Start)
            .margin({ top: 2 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .height(70)
      .justifyContent(FlexAlign.Center)

      Text($r('app.string.ui_091385be99'))
        .fontSize(18)
        .fontColor(ThemeColors.secondaryText(this.isDark))
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .onClick(() => {
      console.info('[BookListItem] Click: ' + this.book.name);
    })
  }
}
