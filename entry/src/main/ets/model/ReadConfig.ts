/**
 * 阅读配置模型
 * 控制字体、排版、翻页、主题等阅读相关设置
 */
export enum PageMode {
  COVER = 0,         // 覆盖翻页
  SIMULATION = 1,    // 仿真翻页
  SCROLL = 2,        // 滚动
  SLIDE = 3,         // 滑动
  NONE = 4           // 无动画
}

export enum TextSizeUnit {
  SP = 0,
  DP = 1
}

export interface ReadConfig {
  // 字体
  fontFamily: string;          // 字体名称
  fontSize: number;            // 字号 (sp)
  fontBold: boolean;           // 粗体
  lineHeightMultiplier: number; // 行高倍数 (1.0 ~ 2.0)
  paragraphSpacing: number;    // 段间距 (sp)
  letterSpacing: number;       // 字间距 (sp)

  // 翻页
  pageMode: PageMode;
  pageAnimDuration: number;    // 翻页动画时长 (ms)
  horizontalPage: boolean;     // 横向翻页
  volumeKeyPage: boolean;      // 音量键翻页

  // 背景
  bgColor: string;             // 背景色 (HEX)
  textColor: string;           // 文字色 (HEX)
  bgImagePath: string;         // 背景图片路径
  bgBrightness: number;        // 背景亮度 0.0 ~ 1.0

  // 状态栏
  showStatusBar: boolean;
  showProgressBar: boolean;

  // 点击区域
  tapZoneTop: number;         // 上翻页区域百分比
  tapZoneBottom: number;      // 下翻页区域百分比
  tapZoneCenter: number;      // 中间区域（菜单）百分比

  // 简繁转换
  convertSimplified: boolean; // 简转繁
  convertTraditional: boolean;// 繁转简

  // 过滤
  replaceRules: number[];     // 启用的替换规则 ID 列表
}

export function createDefaultReadConfig(): ReadConfig {
  return {
    fontFamily: '默认',
    fontSize: 18,
    fontBold: false,
    lineHeightMultiplier: 1.5,
    paragraphSpacing: 8,
    letterSpacing: 0.5,
    pageMode: PageMode.COVER,
    pageAnimDuration: 300,
    horizontalPage: true,
    volumeKeyPage: true,
    bgColor: '#F5F0E8',
    textColor: '#333333',
    bgImagePath: '',
    bgBrightness: 1.0,
    showStatusBar: true,
    showProgressBar: true,
    tapZoneTop: 35,
    tapZoneBottom: 35,
    tapZoneCenter: 30,
    convertSimplified: false,
    convertTraditional: false,
    replaceRules: [],
  };
}
