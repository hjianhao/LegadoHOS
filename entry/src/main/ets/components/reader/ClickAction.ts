/**
 * 触控区域动作定义
 *
 * 映射 Android Legado 的 14 种动作：
 * https://github.com/gedoor/legado
 */

/** 9 个触控区域 */
export enum ClickZone {
  TL = 0, TC = 1, TR = 2,
  ML = 3, MC = 4, MR = 5,
  BL = 6, BC = 7, BR = 8,
}

/** 区域对应的偏好设置 key */
export const ZONE_KEYS: string[] = [
  'click_tl', 'click_tc', 'click_tr',
  'click_ml', 'click_mc', 'click_mr',
  'click_bl', 'click_bc', 'click_br',
];

/** 动作代码 */
export enum ClickAction {
  NONE = -1,         // 无动作
  MENU = 0,          // 显示菜单
  NEXT_PAGE = 1,     // 下一页
  PREV_PAGE = 2,     // 上一页
  NEXT_CHAPTER = 3,  // 下一章
  PREV_CHAPTER = 4,  // 上一章
  PREV_PARAGRAPH = 5, // 朗读上一段
  NEXT_PARAGRAPH = 6, // 朗读下一段
  ADD_BOOKMARK = 7,  // 添加书签
  CHAPTER_LIST = 10, // 目录
  READ_ALOUD = 13,   // 朗读暂停/继续
}

export const ACTION_LABELS: Record<number, string> = {
  [ClickAction.NONE]: '无动作',
  [ClickAction.MENU]: '显示菜单',
  [ClickAction.NEXT_PAGE]: '下一页',
  [ClickAction.PREV_PAGE]: '上一页',
  [ClickAction.NEXT_CHAPTER]: '下一章',
  [ClickAction.PREV_CHAPTER]: '上一章',
  [ClickAction.PREV_PARAGRAPH]: '朗读上一段',
  [ClickAction.NEXT_PARAGRAPH]: '朗读下一段',
  [ClickAction.ADD_BOOKMARK]: '添加书签',
  [ClickAction.CHAPTER_LIST]: '目录',
  [ClickAction.READ_ALOUD]: '朗读',
};

/** 9 个区域的默认动作（匹配 Android Legado） */
export const DEFAULT_ZONE_ACTIONS: number[] = [
  ClickAction.PREV_CHAPTER,  // TL - 上一章
  ClickAction.PREV_PAGE,     // TC - 上一页
  ClickAction.NEXT_CHAPTER,  // TR - 下一章
  ClickAction.PREV_PAGE,     // ML - 上一页
  ClickAction.MENU,          // MC - 菜单
  ClickAction.NEXT_PAGE,     // MR - 下一页
  ClickAction.PREV_PAGE,     // BL - 上一页
  ClickAction.NEXT_PAGE,     // BC - 下一页
  ClickAction.NEXT_PAGE,     // BR - 下一页
];
