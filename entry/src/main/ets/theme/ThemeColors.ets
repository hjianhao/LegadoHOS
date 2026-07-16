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
  static onPrimary(_isDark: boolean): string {
    return '#FFFFFF';
  }

  /** 弹层遮罩色 */
  static scrim(_isDark: boolean): string {
    return 'rgba(0,0,0,0.18)';
  }

  /** 错误/警告色 */
  static error(_isDark: boolean): string {
    const s = getScheme();
    if (s && s.error) return s.error;
    return '#EF5350';
  }
}
