/**
 * 阅读顶部菜单：返回、书籍/章节信息、章节地址、书源及低频快捷操作。
 */
import { ThemeColors } from '../../theme/ThemeColors';

@Component
export struct ReadTopMenu {
  @StorageLink('isDark') isDark: boolean = false;
  @Prop bookName: string = '';
  @Prop chapterTitle: string = '';
  @Prop chapterUrl: string = '';
  @Prop sourceName: string = '';
  onBack?: () => void;
  onSearch?: () => void;
  onBookmark?: () => void;
  onMore?: () => void;
  onLandscape?: () => void;

  build() {
    Column() {
      Row() {
        Button() {
          Text($r('app.string.ui_9fb248dfd4'))
            .fontSize(24)
            .fontColor(ThemeColors.onSurface(this.isDark))
        }
        .width(48).height(48)
        .backgroundColor(ThemeColors.transparent())
        .accessibilityText($r('app.string.common_back'))
        .onClick(() => { this.onBack?.(); })

        Column() {
          Text(this.bookName)
            .fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.onSurface(this.isDark))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.chapterTitle)
            .fontSize(11)
            .fontColor(ThemeColors.secondaryText(this.isDark))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 4, right: 4 })

        if (this.onSearch) {
          Button() {
            Text($r('app.string.ui_35d70d63b7'))
              .fontSize(20).fontColor(ThemeColors.onSurface(this.isDark))
          }
          .width(44).height(44)
          .backgroundColor(ThemeColors.transparent())
          .accessibilityText($r('app.string.common_search'))
          .onClick(() => { this.onSearch?.(); })
        }
        if (this.onBookmark) {
          Button() {
            Text($r('app.string.ui_ccb920edc1'))
              .fontSize(20).fontColor(ThemeColors.onSurface(this.isDark))
          }
          .width(44).height(44)
          .backgroundColor(ThemeColors.transparent())
          .accessibilityText($r('app.string.ui_820f5b6440'))
          .onClick(() => { this.onBookmark?.(); })
        }
        if (this.onLandscape) {
          Button() {
            Text('双页')
              .fontSize(13).fontColor(ThemeColors.onSurface(this.isDark))
          }
          .height(44)
          .backgroundColor(ThemeColors.transparent())
          .accessibilityText('横屏排版')
          .onClick(() => { this.onLandscape?.(); })
        }
        if (this.onMore) {
          Button() {
            Text('•••')
              .fontSize(18).fontColor(ThemeColors.onSurface(this.isDark))
          }
          .width(44).height(44)
          .backgroundColor(ThemeColors.transparent())
          .accessibilityText('更多阅读工具')
          .onClick(() => { this.onMore?.(); })
        }
      }
      .width('100%').height(52)

      Row() {
        Scroll() {
          Text(this.chapterUrl || '本地章节')
            .fontSize(10)
            .fontColor(ThemeColors.secondaryText(this.isDark))
            .maxLines(1)
            .copyOption(CopyOptions.LocalDevice)
        }
        .height(36)
        .layoutWeight(1)
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Auto)
        Text(this.sourceName || '本地书籍')
          .fontSize(11)
          .fontColor(ThemeColors.secondaryText(this.isDark))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .textAlign(TextAlign.End)
          .width(116)
          .margin({ left: 12 })
      }
      .width('100%')
      .constraintSize({ minHeight: 48 })
      .alignItems(VerticalAlign.Top)
      .padding({ left: 16, right: 16, top: 4, bottom: 10 })
    }
    .width('100%')
    .backgroundColor(ThemeColors.surface(this.isDark))
    .border({ width: { bottom: 0.5 }, color: ThemeColors.outlineVariant(this.isDark) })
  }
}
