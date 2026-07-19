/**
 * 通用加载视图
 */
import { ThemeColors } from '../../theme/ThemeColors';

@Component
export struct LoadingView {
  @Prop message: string;
  @StorageLink('isDark') isDark: boolean = false;

  build() {
    Column() {
      LoadingProgress()
        .color(ThemeColors.primary(this.isDark))
        .width(48)
        .height(48)
      Text(this.message)
        .fontSize(14)
        .fontColor(ThemeColors.secondaryText(this.isDark))
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
      Text(this.icon).fontColor(ThemeColors.onSurface(this.isDark))
        .fontSize(48)
        .margin({ bottom: 16 })
      Text(this.message)
        .fontSize(15)
        .fontColor(ThemeColors.secondaryText(this.isDark))
        .textAlign(TextAlign.Center)
        .lineHeight(22)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
