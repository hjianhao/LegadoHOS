/**
 * EPUB 阅读页（暂未启用 WebView 方案）
 * TODO: 未来集成 WebView + EPUB.js
 */
import { ThemeColors } from '../theme/ThemeColors';

@Component
export struct EpubReadPage {
  @StorageLink('isDark') isDark: boolean = false;
  build() {
    Text($r('app.string.ui_ebb607fc23')).fontColor(ThemeColors.onBackground(this.isDark))
  }
}
