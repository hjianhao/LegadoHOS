/**
 * 窗口尺寸分级与全局响应式状态
 *
 * 四级窗口规格（参考 doc/ref/pad.md）：
 *   COMPACT  < 600vp     手机单列、底部页签、底部半模态
 *   MEDIUM   600-839vp   紧凑侧边栏、内容限宽、部分双列
 *   EXPANDED 840-1199vp  左侧导航、列表详情分栏、多列内容
 *   LARGE    >= 1200vp   扩展分栏、更多网格列、阅读双页模式
 *
 * 低高度规则：窗口高度 < 480vp 时 isLowHeight = true，压缩标题栏。
 *
 * 使用方式：
 *   1. 根容器（MainPage）onAreaChange 中调用 WindowLayout.update(width, height)
 *   2. 子页面/组件用 @StorageProp('windowSizeClass') 消费，或直接读 WindowLayout 静态字段
 *   3. 需要响应变化时用 @StorageProp('windowWidthVp') / @StorageProp('windowHeightVp')
 */

/** 窗口尺寸分级 */
export enum WindowSizeClass {
  COMPACT = 0,
  MEDIUM = 1,
  EXPANDED = 2,
  LARGE = 3,
}

/** 断点阈值（vp） */
export const BREAKPOINT_COMPACT_MAX = 600;
export const BREAKPOINT_MEDIUM_MAX = 840;
export const BREAKPOINT_EXPANDED_MAX = 1200;

/** 低高度阈值（vp） */
export const LOW_HEIGHT_THRESHOLD = 480;

/** 阅读器横屏限宽默认值（vp），0 表示不限 */
export const DEFAULT_READ_MAX_CONTENT_WIDTH = 800;

/** AppStorage 键名 */
const KEY_SIZE_CLASS = 'windowSizeClass';
const KEY_WIDTH_VP = 'windowWidthVp';
const KEY_HEIGHT_VP = 'windowHeightVp';
const KEY_IS_LANDSCAPE = 'windowIsLandscape';
const KEY_IS_LOW_HEIGHT = 'windowIsLowHeight';
const KEY_IS_WIDE = 'windowIsWide';
const KEY_IS_TABLET = 'windowIsTablet';

/**
 * 窗口布局全局状态。
 *
 * 静态字段与 AppStorage 双向同步：update() 同时更新两者，
 * 组件端可以用 @StorageProp('windowSizeClass') 等观察变化。
 */
export class WindowLayout {
  /** 当前窗口尺寸分级 */
  static current: WindowSizeClass = WindowSizeClass.COMPACT;
  /** 当前窗口宽度（vp） */
  static widthVp: number = 360;
  /** 当前窗口高度（vp） */
  static heightVp: number = 640;
  /** 是否横屏（widthVp > heightVp） */
  static isLandscape: boolean = false;
  /** 是否低高度（heightVp < 480vp） */
  static isLowHeight: boolean = false;
  /** 是否宽屏（>= MEDIUM） */
  static isWide: boolean = false;
  /** 是否平板级宽屏（>= EXPANDED） */
  static isTablet: boolean = false;

  /** 根据宽度计算尺寸分级 */
  static classify(widthVp: number): WindowSizeClass {
    if (widthVp < BREAKPOINT_COMPACT_MAX) return WindowSizeClass.COMPACT;
    if (widthVp < BREAKPOINT_MEDIUM_MAX) return WindowSizeClass.MEDIUM;
    if (widthVp < BREAKPOINT_EXPANDED_MAX) return WindowSizeClass.EXPANDED;
    return WindowSizeClass.LARGE;
  }

  /**
   * 更新窗口尺寸（在根容器 onAreaChange 中调用）。
   * 同时写入静态字段和 AppStorage，让 @StorageProp 能感知变化。
   */
  static update(widthVp: number, heightVp: number): void {
    if (widthVp <= 0 || heightVp <= 0) return;
    const sizeClass = WindowLayout.classify(widthVp);
    const isLandscape = widthVp > heightVp;
    const isLowHeight = heightVp < LOW_HEIGHT_THRESHOLD;
    const isWide = sizeClass >= WindowSizeClass.MEDIUM;
    const isTablet = sizeClass >= WindowSizeClass.EXPANDED;

    // 跳过无变化的情况，减少不必要的重渲染
    if (
      widthVp === WindowLayout.widthVp &&
      heightVp === WindowLayout.heightVp &&
      sizeClass === WindowLayout.current
    ) {
      return;
    }

    WindowLayout.widthVp = widthVp;
    WindowLayout.heightVp = heightVp;
    WindowLayout.current = sizeClass;
    WindowLayout.isLandscape = isLandscape;
    WindowLayout.isLowHeight = isLowHeight;
    WindowLayout.isWide = isWide;
    WindowLayout.isTablet = isTablet;

    // 同步到 AppStorage，让 @StorageProp 消费者能感知
    AppStorage.setOrCreate(KEY_SIZE_CLASS, sizeClass);
    AppStorage.setOrCreate(KEY_WIDTH_VP, widthVp);
    AppStorage.setOrCreate(KEY_HEIGHT_VP, heightVp);
    AppStorage.setOrCreate(KEY_IS_LANDSCAPE, isLandscape);
    AppStorage.setOrCreate(KEY_IS_LOW_HEIGHT, isLowHeight);
    AppStorage.setOrCreate(KEY_IS_WIDE, isWide);
    AppStorage.setOrCreate(KEY_IS_TABLET, isTablet);
  }

  /** 获取适合弹窗的对齐方式：Compact 底部，Medium+ 居中 */
  static adaptiveDialogAlignment(): DialogAlignment {
    return WindowLayout.isWide ? DialogAlignment.Center : DialogAlignment.Bottom;
  }

  /**
   * 根据窗口宽度与最小卡片宽度，计算宫格列数。
   * used by: BookshelfPage, RssMainPage 等网格布局
   */
  static computeGridColumns(minCardWidth: number, padding: number = 32): number {
    const available = WindowLayout.widthVp - padding;
    return Math.max(1, Math.floor(available / minCardWidth));
  }
}
