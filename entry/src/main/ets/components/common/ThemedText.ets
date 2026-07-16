/**
 * 主题感知的 Text 组件
 *
 * 自动绑定 @StorageLink('isDark')，无需父组件传递 isDark。
 * 通过 colorRole 参数选择颜色类型：
 *   - body      → ThemeColors.onBackground (默认，正文)
 *   - secondary → ThemeColors.secondaryText (次要/说明文字)
 *   - primary   → ThemeColors.primary (主色调/链接)
 *   - onPrimary → ThemeColors.onPrimary (主色调上文字)
 *   - surface   → ThemeColors.onSurface (浮层上文字)
 *   - error     → ThemeColors.error (错误/警告)
 *
 * 用法：
 *   ThemedText({ content: '书名', colorRole: 'body', fontSize: 18, fontWeight: FontWeight.Bold })
 *   ThemedText({ content: '作者', colorRole: 'secondary', fontSize: 12 })
 *   ThemedText({ content: '重试', colorRole: 'primary', fontSize: 14 })
 */
import { ThemeColors } from '../../theme/ThemeColors';

@Component
export struct ThemedText {
  @StorageLink('isDark') isDark: boolean = false;
  private content: ResourceStr = '';
  @Prop colorRole: string = 'body';
  @Prop fontSize: number = 16;
  @Prop fontWeight: number | string = FontWeight.Normal;

  build() {
    Text(this.content)
      .fontColor(this.getColor())
      .fontSize(this.fontSize)
      .fontWeight(this.fontWeight)
  }

  private getColor(): string {
    switch (this.colorRole) {
      case 'secondary':
        return ThemeColors.secondaryText(this.isDark);
      case 'primary':
        return ThemeColors.primary(this.isDark);
      case 'error':
        return ThemeColors.error(this.isDark);
      case 'onPrimary':
        return ThemeColors.onPrimary(this.isDark);
      case 'surface':
        return ThemeColors.onSurface(this.isDark);
      default:
        return ThemeColors.onBackground(this.isDark);
    }
  }
}
