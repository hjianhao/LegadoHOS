/**
 * 统一的主题颜色 Token 辅助类
 * 所有页面/组件通过 ThemeColors.xxx(this.isDark) 引用颜色。
 * 优先从 AppTheme.colorScheme 取色（支持色板切换），
 * 若 colorScheme 返回的状态与 isDark 矛盾，则使用硬编码兜底。
 *
 * 用法：
 *   @StorageLink('isDark') isDark: boolean = false;
 *   .backgroundColor(ThemeColors.background(this.isDark))
 *   .fontColor(ThemeColors.onBackground(this.isDark))
 */
import { AppTheme } from './AppTheme';
import { AppColorScheme } from './ColorScheme';

/** isDark=true 时期望的暗色页面背景，用于校验 colorScheme 是否处于正确的模式 */
const DARK_BG_HEX = '#121212';
const LIGHT_BG_HEX = '#F5F5F5';

function getScheme(): AppColorScheme | null {
  try {
    return AppTheme.getInstance().colorScheme;
  } catch (_e) {
    return null;
  }
}

/** 校验 scheme 与 isDark 是否一致 */
function schemeMatches(s: AppColorScheme, isDark: boolean): boolean {
  if (!s || s.background === undefined) return false;
  // 若 isDark=true 但 background 是浅色，说明 scheme 还在 light 模式
  if (isDark && s.background === LIGHT_BG_HEX) return false;
  // 若 isDark=false 但 background 是深色，说明 scheme 还在 dark 模式
  if (!isDark && s.background === DARK_BG_HEX) return false;
  return true;
}

export class ThemeColors {
  /** 页面背景色 */
  static background(isDark: boolean): string {
    const s = getScheme();
    if (s && schemeMatches(s, isDark)) return s.background;
    if (isDark) return DARK_BG_HEX;
    return LIGHT_BG_HEX;
  }

  /** 背景上的正文文字色 */
  static onBackground(isDark: boolean): string {
    const s = getScheme();
    if (s && schemeMatches(s, isDark)) return s.onBackground;
    return isDark ? '#E0E0E0' : '#1A1A2E';
  }

  /** 卡片/列表项等浮层背景色 */
  static surface(isDark: boolean): string {
    const s = getScheme();
    if (s && schemeMatches(s, isDark)) return s.surface;
    return isDark ? '#1E1E1E' : '#FFFFFF';
  }

  /** 卡片/浮层上的文字色 */
  static onSurface(isDark: boolean): string {
    const s = getScheme();
    if (s && schemeMatches(s, isDark)) return s.onSurface;
    return isDark ? '#E0E0E0' : '#1A1A2E';
  }

  /** 较浅的浮层背景（区分于 surface） */
  static surfaceVariant(isDark: boolean): string {
    const s = getScheme();
    if (s && schemeMatches(s, isDark)) return s.surfaceVariant;
    return isDark ? '#2C2C2C' : '#F0F0F0';
  }

  /** 分割线 / 边框色 */
  static outlineVariant(isDark: boolean): string {
    const s = getScheme();
    if (s && schemeMatches(s, isDark)) return s.outlineVariant;
    return isDark ? '#333333' : '#E0E0E0';
  }

  /** 次要文字（说明、简介、时间戳等 — 比正文暗但保证可读性） */
  static secondaryText(isDark: boolean): string {
    // 统一用以下值，不依赖 colorScheme.outline（outline 是为边框设计的，偏暗）
    // 调整这里即可全局改变所有说明文字的颜色
    return isDark ? '#AAAAAA' : '#888888';
  }

  /** 主色调（按钮、链接等） */
  static primary(isDark: boolean): string {
    const s = getScheme();
    if (s && schemeMatches(s, isDark)) return s.primary;
    return isDark ? '#5CACF2' : '#0078D7';
  }

  /** 主色调上的文字/图标色 */
  static onPrimary(isDark: boolean): string {
    const s = getScheme();
    if (s && schemeMatches(s, isDark)) return s.onPrimary;
    return '#FFFFFF';
  }

  /** 弹层遮罩色 */
  static scrim(_isDark: boolean): string {
    return 'rgba(0,0,0,0.18)';
  }

  /** 错误/警告色 */
  static error(isDark: boolean): string {
    const s = getScheme();
    if (s && schemeMatches(s, isDark) && s.error) return s.error;
    return '#EF5350';
  }

  /** 错误色容器上的前景色。 */
  static onError(_isDark: boolean): string {
    return '#FFFFFF';
  }

  /** 成功状态色。保持足够饱和度，避免与正文颜色混淆。 */
  static success(isDark: boolean): string {
    return isDark ? '#66BB6A' : '#2E7D32';
  }

  /** 警告状态色。 */
  static warning(isDark: boolean): string {
    return isDark ? '#FFB74D' : '#E65100';
  }

  /** 主色弱化容器，用于选中项而不是主按钮。 */
  static primaryContainer(isDark: boolean): string {
    const s = getScheme();
    if (s && schemeMatches(s, isDark)) return s.primaryContainer;
    return isDark ? '#1A3A5A' : '#E8F0FE';
  }

  static successContainer(isDark: boolean): string {
    return isDark ? '#1A3A2A' : '#E8F5E9';
  }

  static warningContainer(isDark: boolean): string {
    return isDark ? '#4A3218' : '#FFF3E0';
  }

  static shadow(isDark: boolean): string {
    return isDark ? 'rgba(0,0,0,0.40)' : 'rgba(0,0,0,0.14)';
  }

  static surfaceTranslucent(isDark: boolean): string {
    return isDark ? 'rgba(18,18,18,0.80)' : 'rgba(255,255,255,0.85)';
  }

  static transparent(): string { return 'rgba(0,0,0,0)'; }

  static heroGradientStart(isDark: boolean): string {
    return isDark ? 'rgba(38,50,56,0.67)' : 'rgba(221,230,232,0.67)';
  }

  static heroGradientEnd(isDark: boolean): string {
    return isDark ? 'rgba(18,18,18,0.90)' : 'rgba(255,255,255,0.85)';
  }

  static strongScrim(_isDark: boolean): string {
    return 'rgba(0,0,0,0.40)';
  }

  /** 漫画内容画布需要纯黑/纯白，不随 surface 色板偏移。 */
  static comicCanvas(isDark: boolean): string {
    return isDark ? '#000000' : '#FFFFFF';
  }

  static readingBackgroundDefault(): string { return '#F5F0E8'; }
  static readingTextDefault(): string { return '#333333'; }
  static readingTitleDefault(): string { return '#999999'; }
  static readingNightBackground(): string { return '#1A1A1A'; }
  static readingNightText(): string { return '#C0C0C0'; }

  static readingBackgroundPresets(): string[] {
    return ['#F5F0E8', '#FFFFFF', '#C6E2E8', '#D4E8D0', '#F0D0C0', '#E8E0D0', '#D0D0D0', '#000000'];
  }

  static readingTextPresets(): string[] {
    return ['#333333', '#000000', '#2C3E50', '#5D4037', '#666666', '#FFFFFF', '#1A237E', '#880E4F'];
  }

  /** 根据背景色决定系统栏是否使用浅色图标。支持 #RGB、#RRGGBB 和 #AARRGGBB。 */
  static useLightSystemBarIcons(backgroundColor: string): boolean {
    let hex = (backgroundColor || '').trim().replace('#', '');
    if (hex.length === 3) {
      hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2];
    } else if (hex.length === 8) {
      hex = hex.substring(2);
    }
    if (hex.length !== 6) return false;
    const value = parseInt(hex, 16);
    if (Number.isNaN(value)) return false;
    const red = (value >> 16) & 0xFF;
    const green = (value >> 8) & 0xFF;
    const blue = value & 0xFF;
    return (red * 299 + green * 587 + blue * 114) / 1000 < 150;
  }

  static coverPlaceholderPalette(): string[] {
    return ['#455A64', '#5C6BC0', '#26A69A', '#EC407A', '#AB47BC', '#42A5F5',
      '#66BB6A', '#FF7043', '#8D6E63', '#78909C', '#7E57C2', '#29B6F6'];
  }

  static coverPlaceholder(index: number): string {
    const colors = ThemeColors.coverPlaceholderPalette();
    return colors[Math.abs(index) % colors.length];
  }
}
