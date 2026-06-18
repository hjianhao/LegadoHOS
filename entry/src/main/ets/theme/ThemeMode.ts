/**
 * 主题模式定义
 * 遵循 HarmonyOS Design 设计规范
 */
export enum ThemeMode {
  LIGHT = 'light',
  DARK = 'dark',
  SYSTEM = 'system',
}

export enum ColorMode {
  DYNAMIC = 'dynamic',     // 从壁纸取色
  PRESET = 'preset',       // 预设色板
  CUSTOM = 'custom',       // 自定义颜色
}

export enum PresetPalette {
  DEFAULT = 'default',     // 默认蓝
  FOREST = 'forest',       // 墨绿
  AMBER = 'amber',         // 琥珀
  SAKURA = 'sakura',       // 樱花
  STAR = 'star',           // 星空
  PURE = 'pure',           // 素白
  EYE_CARE = 'eye_care',   // 护眼
  PAPER = 'paper',         // 纸质
  GEEK = 'geek',           // 极客
}

/**
 * 主题配置
 */
export interface ThemeConfig {
  mode: ThemeMode;
  colorMode: ColorMode;
  presetPalette: PresetPalette;
  seedColor: string;            // 取色种子（hex）
  customPrimary: string;
  customSecondary: string;
  customBackground: string;
  customText: string;

  // 阅读专用
  readBgColor: string;
  readTextColor: string;
  readFontFamily: string;

  // Amoled 纯黑
  amoledBlack: boolean;
}

export function createDefaultTheme(): ThemeConfig {
  return {
    mode: ThemeMode.SYSTEM,
    colorMode: ColorMode.PRESET,
    presetPalette: PresetPalette.DEFAULT,
    seedColor: '#0078D7',
    customPrimary: '#0078D7',
    customSecondary: '#5CACF2',
    customBackground: '#F5F5F5',
    customText: '#1A1A2E',
    readBgColor: '#F5F0E8',
    readTextColor: '#333333',
    readFontFamily: '默认',
    amoledBlack: false,
  };
}
