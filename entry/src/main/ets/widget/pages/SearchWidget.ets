/**
 * 快速搜索小组件
 * 一键打开搜索页面
 */
import { ThemeColors } from '../../theme/ThemeColors';

@Component
export struct SearchWidget {
  @StorageProp('isDark') isDark: boolean = false;

  build() {
    Column() {
      Image($r('app.media.ic_search'))
        .width(28).height(28)
        .fillColor(ThemeColors.primary(this.isDark))
        .accessibilityText($r('app.string.common_search'))
      Text($r('app.string.common_search')).fontSize(12)
        .fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 4 })
    }
    .width('100%').height('100%')
    .backgroundColor(ThemeColors.surface(this.isDark))
    .borderRadius(8)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      // 打开搜索页面
      console.info('[Widget] Open search');
    })
    .accessibilityText($r('app.string.common_search'))
  }
}
