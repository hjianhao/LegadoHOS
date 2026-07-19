import { AppTheme } from '../theme/AppTheme';
import { ThemeColors } from '../theme/ThemeColors';
import { UiUtil } from '../util/UiUtil';
import { AppTitleBar } from '../components/common/AppTitleBar';

@Entry
@Component
struct WebServicePage {
  @StorageLink('isDark') isDark: boolean = false;
  aboutToAppear(): void { this.isDark = AppTheme.getInstance().isDark; }

  build() {
    Column() {
      AppTitleBar({ title: $r('app.string.ui_6980edd1a3'), onBack: () => { UiUtil.back(this.getUIContext()); } })
      Text($r('app.string.ui_b48ed8db6e')).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 40 })
    }
    .width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
  }
}
