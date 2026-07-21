/**
 * 阅读页底部半模态 / 菜单的边距约定。
 *
 * 阅读时会隐藏系统导航栏与 navigationIndicator，但手势导航仍占用底部触控带；
 * 半模态若不预留底边，Slider 等拖动手势会与系统返回/主页手势冲突。
 */
import { WindowLayout } from './WindowLayout';

/** 底部半模态相对屏幕底边的最小预留（vp） */
export const READER_SHEET_BOTTOM_MIN = 36;

/** 内容区额外呼吸间距（vp） */
export const READER_SHEET_CONTENT_GAP = 12;

export class ReaderInsets {
  /**
   * 底部半模态 paddingBottom（vp）。
   * 横屏略减，竖屏用更大预留。
   */
  static sheetBottomPad(): number {
    const base = WindowLayout.isLandscape ? 28 : READER_SHEET_BOTTOM_MIN;
    return base + READER_SHEET_CONTENT_GAP;
  }

  /**
   * 风格/设置面板内容区最大高度（vp），超出后内部滚动，
   * 避免整块面板贴底并盖住过多正文。
   */
  static sheetContentMaxHeight(): number {
    const h = WindowLayout.heightVp > 100 ? WindowLayout.heightVp : 640;
    // 约 40% 屏高，夹在 200–380 之间
    return Math.max(200, Math.min(380, Math.floor(h * 0.40)));
  }
}
