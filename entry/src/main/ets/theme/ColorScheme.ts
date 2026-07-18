/**
 * 配色方案引擎
 * 基于 HarmonyOS Design 色板规范 + 动态取色
 */
import { ThemeConfig, PresetPalette, ThemeMode } from './ThemeMode';

/**
 * 完整的应用配色
 */
export interface AppColorScheme {
  // 主色
  primary: string;
  primaryContainer: string;
  onPrimary: string;

  // 次要色
  secondary: string;
  secondaryContainer: string;
  onSecondary: string;

  // 背景
  background: string;
  onBackground: string;
  surface: string;
  onSurface: string;
  surfaceVariant: string;

  // 强调色
  accent: string;
  error: string;
  onError: string;

  // 轮廓
  outline: string;
  outlineVariant: string;

  // 阅读专用
  readBg: string;
  readText: string;
}

// 预设色板（HarmonyOS Design 风格）
const PALETTES: Record<PresetPalette, { light: AppColorScheme; dark: AppColorScheme }> = {
  [PresetPalette.DEFAULT]: {
    light: {
      primary: '#0078D7', primaryContainer: '#D4E8FA', onPrimary: '#FFFFFF',
      secondary: '#5CACF2', secondaryContainer: '#D4E8FA', onSecondary: '#FFFFFF',
      background: '#F5F5F5', onBackground: '#1A1A2E',
      surface: '#FFFFFF', onSurface: '#1A1A2E', surfaceVariant: '#F0F0F0',
      accent: '#FF8C00', error: '#D32F2F', onError: '#FFFFFF',
      outline: '#C0C0C0', outlineVariant: '#E0E0E0',
      readBg: '#F5F0E8', readText: '#333333',
    },
    dark: {
      primary: '#5CACF2', primaryContainer: '#003258', onPrimary: '#003258',
      secondary: '#90CAF9', secondaryContainer: '#003258', onSecondary: '#003258',
      background: '#121212', onBackground: '#E0E0E0',
      surface: '#1E1E1E', onSurface: '#E0E0E0', surfaceVariant: '#2C2C2C',
      accent: '#FFB74D', error: '#EF5350', onError: '#FFFFFF',
      outline: '#444444', outlineVariant: '#333333',
      readBg: '#1E1E1E', readText: '#C0C0C0',
    },
  },
  [PresetPalette.FOREST]: {
    light: {
      primary: '#2E7D32', primaryContainer: '#C8E6C9', onPrimary: '#FFFFFF',
      secondary: '#66BB6A', secondaryContainer: '#C8E6C9', onSecondary: '#FFFFFF',
      background: '#F5F5F5', onBackground: '#1A1A2E',
      surface: '#FFFFFF', onSurface: '#1A1A2E', surfaceVariant: '#F0F0F0',
      accent: '#FF8C00', error: '#D32F2F', onError: '#FFFFFF',
      outline: '#C0C0C0', outlineVariant: '#E0E0E0',
      readBg: '#E8F0E8', readText: '#333333',
    },
    dark: {
      primary: '#66BB6A', primaryContainer: '#1B5E20', onPrimary: '#FFFFFF',
      secondary: '#A5D6A7', secondaryContainer: '#1B5E20', onSecondary: '#FFFFFF',
      background: '#121212', onBackground: '#E0E0E0',
      surface: '#1E1E1E', onSurface: '#E0E0E0', surfaceVariant: '#2C2C2C',
      accent: '#FFB74D', error: '#EF5350', onError: '#FFFFFF',
      outline: '#444444', outlineVariant: '#333333',
      readBg: '#1E2E1E', readText: '#C0C0C0',
    },
  },
  [PresetPalette.AMBER]: {
    light: {
      primary: '#FF8F00', primaryContainer: '#FFF8E1', onPrimary: '#FFFFFF',
      secondary: '#FFB300', secondaryContainer: '#FFF8E1', onSecondary: '#FFFFFF',
      background: '#F5F5F5', onBackground: '#1A1A2E',
      surface: '#FFFFFF', onSurface: '#1A1A2E', surfaceVariant: '#F0F0F0',
      accent: '#E65100', error: '#D32F2F', onError: '#FFFFFF',
      outline: '#C0C0C0', outlineVariant: '#E0E0E0',
      readBg: '#FFF8E1', readText: '#333333',
    },
    dark: {
      primary: '#FFB300', primaryContainer: '#FF6F00', onPrimary: '#FFFFFF',
      secondary: '#FFD54F', secondaryContainer: '#FF6F00', onSecondary: '#FFFFFF',
      background: '#121212', onBackground: '#E0E0E0',
      surface: '#1E1E1E', onSurface: '#E0E0E0', surfaceVariant: '#2C2C2C',
      accent: '#FF8A65', error: '#EF5350', onError: '#FFFFFF',
      outline: '#444444', outlineVariant: '#333333',
      readBg: '#2E2400', readText: '#C0C0C0',
    },
  },
  [PresetPalette.SAKURA]: {
    light: {
      primary: '#D81B60', primaryContainer: '#FCE4EC', onPrimary: '#FFFFFF',
      secondary: '#F06292', secondaryContainer: '#FCE4EC', onSecondary: '#FFFFFF',
      background: '#FEF5F7', onBackground: '#2E1A1A',
      surface: '#FFFFFF', onSurface: '#2E1A1A', surfaceVariant: '#FAF0F2',
      accent: '#7B1FA2', error: '#C62828', onError: '#FFFFFF',
      outline: '#D0B0B8', outlineVariant: '#E8D0D8',
      readBg: '#FEF5F7', readText: '#333333',
    },
    dark: {
      primary: '#F06292', primaryContainer: '#880E4F', onPrimary: '#FFFFFF',
      secondary: '#F48FB1', secondaryContainer: '#880E4F', onSecondary: '#FFFFFF',
      background: '#1A1214', onBackground: '#E0D0D4',
      surface: '#2A1A1E', onSurface: '#E0D0D4', surfaceVariant: '#3A2A2E',
      accent: '#CE93D8', error: '#EF5350', onError: '#FFFFFF',
      outline: '#4A3A3E', outlineVariant: '#3A2A2E',
      readBg: '#2A1A1E', readText: '#C0B0B4',
    },
  },
  [PresetPalette.STAR]: {
    light: {
      primary: '#1565C0', primaryContainer: '#E3F2FD', onPrimary: '#FFFFFF',
      secondary: '#42A5F5', secondaryContainer: '#E3F2FD', onSecondary: '#FFFFFF',
      background: '#F5F8FC', onBackground: '#0D1B2A',
      surface: '#FFFFFF', onSurface: '#0D1B2A', surfaceVariant: '#EEF2F8',
      accent: '#FF6F00', error: '#D32F2F', onError: '#FFFFFF',
      outline: '#B0C0D0', outlineVariant: '#D0DCE8',
      readBg: '#E8F0F8', readText: '#1A2A3A',
    },
    dark: {
      primary: '#42A5F5', primaryContainer: '#0D47A1', onPrimary: '#FFFFFF',
      secondary: '#90CAF9', secondaryContainer: '#0D47A1', onSecondary: '#FFFFFF',
      background: '#0D1B2A', onBackground: '#D0DCE8',
      surface: '#1B2838', onSurface: '#D0DCE8', surfaceVariant: '#2A3850',
      accent: '#FFB74D', error: '#EF5350', onError: '#FFFFFF',
      outline: '#3A4860', outlineVariant: '#2A3850',
      readBg: '#1B2838', readText: '#C0D0E0',
    },
  },
  [PresetPalette.PURE]: {
    light: {
      primary: '#455A64', primaryContainer: '#ECEFF1', onPrimary: '#FFFFFF',
      secondary: '#78909C', secondaryContainer: '#ECEFF1', onSecondary: '#FFFFFF',
      background: '#FEFEFE', onBackground: '#212121',
      surface: '#FFFFFF', onSurface: '#212121', surfaceVariant: '#F5F5F5',
      accent: '#FF5722', error: '#D32F2F', onError: '#FFFFFF',
      outline: '#BDBDBD', outlineVariant: '#E0E0E0',
      readBg: '#FFFFFF', readText: '#333333',
    },
    dark: {
      primary: '#78909C', primaryContainer: '#37474F', onPrimary: '#FFFFFF',
      secondary: '#B0BEC5', secondaryContainer: '#37474F', onSecondary: '#FFFFFF',
      background: '#1A1A1A', onBackground: '#E0E0E0',
      surface: '#2A2A2A', onSurface: '#E0E0E0', surfaceVariant: '#333333',
      accent: '#FF8A65', error: '#EF5350', onError: '#FFFFFF',
      outline: '#555555', outlineVariant: '#444444',
      readBg: '#2A2A2A', readText: '#C0C0C0',
    },
  },
  [PresetPalette.EYE_CARE]: {
    light: {
      primary: '#5B8C5A', primaryContainer: '#E8F0E8', onPrimary: '#FFFFFF',
      secondary: '#8CB08B', secondaryContainer: '#E8F0E8', onSecondary: '#FFFFFF',
      background: '#F0F5ED', onBackground: '#2A3A2A',
      surface: '#F5FAF3', onSurface: '#2A3A2A', surfaceVariant: '#EEF5EC',
      accent: '#B8860B', error: '#A0522D', onError: '#FFFFFF',
      outline: '#B8C8B8', outlineVariant: '#D8E0D8',
      readBg: '#C4E0C0', readText: '#3A4A3A',
    },
    dark: {
      primary: '#8CB08B', primaryContainer: '#3A5A3A', onPrimary: '#FFFFFF',
      secondary: '#A8C8A8', secondaryContainer: '#3A5A3A', onSecondary: '#FFFFFF',
      background: '#1A2A1A', onBackground: '#D0E0D0',
      surface: '#2A3A2A', onSurface: '#D0E0D0', surfaceVariant: '#3A4A3A',
      accent: '#D4A843', error: '#D4846A', onError: '#FFFFFF',
      outline: '#4A5A4A', outlineVariant: '#3A4A3A',
      readBg: '#2A3A2A', readText: '#B0C8B0',
    },
  },
  [PresetPalette.PAPER]: {
    light: {
      primary: '#8D6E63', primaryContainer: '#EFEBE9', onPrimary: '#FFFFFF',
      secondary: '#A1887F', secondaryContainer: '#EFEBE9', onSecondary: '#FFFFFF',
      background: '#F5F0E8', onBackground: '#3E2723',
      surface: '#FAF5EE', onSurface: '#3E2723', surfaceVariant: '#F0EBE3',
      accent: '#FF6F00', error: '#BF360C', onError: '#FFFFFF',
      outline: '#C8B8A8', outlineVariant: '#E0D8C8',
      readBg: '#F5F0E8', readText: '#3E2723',
    },
    dark: {
      primary: '#A1887F', primaryContainer: '#4E342E', onPrimary: '#FFFFFF',
      secondary: '#BCAAA4', secondaryContainer: '#4E342E', onSecondary: '#FFFFFF',
      background: '#1E1410', onBackground: '#D0C0B8',
      surface: '#2E221E', onSurface: '#D0C0B8', surfaceVariant: '#3E322E',
      accent: '#FFB74D', error: '#D47454', onError: '#FFFFFF',
      outline: '#5A4A44', outlineVariant: '#4A3A34',
      readBg: '#2E221E', readText: '#C0B0A8',
    },
  },
  [PresetPalette.GEEK]: {
    light: {
      primary: '#00BCD4', primaryContainer: '#E0F7FA', onPrimary: '#FFFFFF',
      secondary: '#26A69A', secondaryContainer: '#E0F7FA', onSecondary: '#FFFFFF',
      background: '#F0F5F8', onBackground: '#0D1B2A',
      surface: '#F8FAFB', onSurface: '#0D1B2A', surfaceVariant: '#EEF2F5',
      accent: '#00E676', error: '#FF1744', onError: '#FFFFFF',
      outline: '#A0B8C8', outlineVariant: '#C0D8E8',
      readBg: '#E8F0F5', readText: '#1A2A3A',
    },
    dark: {
      primary: '#00BCD4', primaryContainer: '#006064', onPrimary: '#FFFFFF',
      secondary: '#26A69A', secondaryContainer: '#006064', onSecondary: '#FFFFFF',
      background: '#0D1B2A', onBackground: '#C0D8E8',
      surface: '#1B2838', onSurface: '#C0D8E8', surfaceVariant: '#2A3850',
      accent: '#00E676', error: '#FF1744', onError: '#FFFFFF',
      outline: '#3A5068', outlineVariant: '#2A3850',
      readBg: '#1B2838', readText: '#B0C8D8',
    },
  },
};

export class ColorScheme {
  /**
   * 根据主题配置获取完整配色
   */
  static resolve(config: ThemeConfig, isDark: boolean): AppColorScheme {
    if (config.colorMode === 'preset') {
      const palette = PALETTES[config.presetPalette] || PALETTES[PresetPalette.DEFAULT];
      // 预设 palette 是全局共享常量。先复制再应用 AMOLED/阅读配色覆盖，
      // 避免一次 AMOLED 解析永久污染后续主题解析结果。
      const scheme: AppColorScheme = { ...(isDark ? palette.dark : palette.light) };

      // 应用自定义覆盖
      if (config.amoledBlack && isDark) {
        scheme.background = '#000000';
        scheme.surface = '#000000';
        scheme.surfaceVariant = '#111111';
      }

      return {
        ...scheme,
        readBg: config.readBgColor || scheme.readBg,
        readText: config.readTextColor || scheme.readText,
      };
    }

    // 动态取色（从壁纸提取主色后生成）
    if (config.colorMode === 'dynamic') {
      return this.generateFromSeed(config.seedColor, isDark);
    }

    // 自定义
    return this.generateFromSeed(config.customPrimary, isDark, {
      background: config.customBackground,
      text: config.customText,
    });
  }

  /**
   * 从种子颜色生成完整色板
   * 简化版 HSL 算法
   */
  private static generateFromSeed(
    seed: string,
    isDark: boolean,
    overrides?: { background?: string; text?: string }
  ): AppColorScheme {
    const hsl = this.hexToHsl(seed);
    const l = isDark ? 0.6 : 0.45;

    const primary = this.hslToHex(hsl[0], hsl[1], l);
    const primaryContainer = this.hslToHex(hsl[0], hsl[1] * 0.5, isDark ? 0.15 : 0.9);
    const secondary = this.hslToHex(hsl[0] + 30, hsl[1] * 0.7, l);
    const bg = overrides?.background || (isDark ? '#121212' : '#F5F5F5');
    const text = overrides?.text || (isDark ? '#E0E0E0' : '#1A1A2E');

    return {
      primary, primaryContainer, onPrimary: '#FFFFFF',
      secondary, secondaryContainer: primaryContainer, onSecondary: '#FFFFFF',
      background: bg, onBackground: text,
      surface: isDark ? '#1E1E1E' : '#FFFFFF',
      onSurface: text, surfaceVariant: isDark ? '#2C2C2C' : '#F0F0F0',
      accent: this.hslToHex((hsl[0] + 180) % 360, hsl[1], l + 0.2),
      error: '#D32F2F', onError: '#FFFFFF',
      outline: isDark ? '#444444' : '#C0C0C0',
      outlineVariant: isDark ? '#333333' : '#E0E0E0',
      readBg: overrides?.background || (isDark ? '#1E1E1E' : '#F5F0E8'),
      readText: overrides?.text || (isDark ? '#C0C0C0' : '#333333'),
    };
  }

  private static hexToHsl(hex: string): [number, number, number] {
    let r = 0, g = 0, b = 0;
    if (hex.length === 7) {
      r = parseInt(hex.slice(1, 3), 16) / 255;
      g = parseInt(hex.slice(3, 5), 16) / 255;
      b = parseInt(hex.slice(5, 7), 16) / 255;
    }
    const max = Math.max(r, g, b), min = Math.min(r, g, b);
    let h = 0, s = 0, l = (max + min) / 2;
    if (max !== min) {
      const d = max - min;
      s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
      switch (max) {
        case r: h = ((g - b) / d + (g < b ? 6 : 0)) * 60; break;
        case g: h = ((b - r) / d + 2) * 60; break;
        case b: h = ((r - g) / d + 4) * 60; break;
      }
    }
    return [h, s, l];
  }

  private static hslToHex(h: number, s: number, l: number): string {
    h = ((h % 360) + 360) % 360;
    const c = (1 - Math.abs(2 * l - 1)) * s;
    const x = c * (1 - Math.abs((h / 60) % 2 - 1));
    const m = l - c / 2;
    let r = 0, g = 0, b = 0;
    if (h < 60) { r = c; g = x; }
    else if (h < 120) { r = x; g = c; }
    else if (h < 180) { g = c; b = x; }
    else if (h < 240) { g = x; b = c; }
    else if (h < 300) { r = x; b = c; }
    else { r = c; b = x; }
    const toHex = (v: number) =>
      Math.round((v + m) * 255).toString(16).padStart(2, '0');
    return `#${toHex(r)}${toHex(g)}${toHex(b)}`;
  }
}
