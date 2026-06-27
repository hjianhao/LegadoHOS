/**
 * 9 分区触摸处理器 — ArkTS 兼容版
 */
export enum TouchZone { TL = 0, TC = 1, TR = 2, ML = 3, MC = 4, MR = 5, BL = 6, BC = 7, BR = 8 }

// 注意：值与 ClickAction.ts 保持一致（存储和配置使用 ClickAction 的值）
export enum TouchZoneAction {
  NONE = -1, MENU = 0, NEXT_PAGE = 1, PREV_PAGE = 2,
  NEXT_CHAPTER = 3, PREV_CHAPTER = 4,
  PREV_PARAGRAPH = 5, NEXT_PARAGRAPH = 6, ADD_BOOKMARK = 7,
  TOC = 10, READ_ALOUD = 13,
}

export interface TouchActionItem {
  value: TouchZoneAction;
  label: string;
}

// 默认值需与 ClickAction.DEFAULT_ZONE_ACTIONS 一致（当前仅用作 fallback）
const DEFAULT_ZONES: TouchZoneAction[] = [
  TouchZoneAction.PREV_CHAPTER, TouchZoneAction.PREV_PAGE, TouchZoneAction.NEXT_CHAPTER,
  TouchZoneAction.PREV_PAGE,    TouchZoneAction.MENU,       TouchZoneAction.NEXT_PAGE,
  TouchZoneAction.PREV_PAGE,    TouchZoneAction.NEXT_PAGE,  TouchZoneAction.NEXT_PAGE,
];

export class PageTouchHandler {
  private zoneActions: TouchZoneAction[] = DEFAULT_ZONES.slice();

  setAction(zone: TouchZone, action: TouchZoneAction): void {
    this.zoneActions[zone] = action;
  }

  setAllActions(actions: TouchZoneAction[]): void {
    for (let i = 0; i < 9 && i < actions.length; i++) {
      this.zoneActions[i] = actions[i];
    }
  }

  getZoneAction(zone: TouchZone): TouchZoneAction {
    return this.zoneActions[zone];
  }

  getTouchZone(x: number, y: number, pw: number, ph: number): TouchZone {
    const col: number = x < pw / 3 ? 0 : x < pw * 2 / 3 ? 1 : 2;
    const row: number = y < ph / 3 ? 0 : y < ph * 2 / 3 ? 1 : 2;
    return (row * 3 + col) as TouchZone;
  }

  getAction(x: number, y: number, pw: number, ph: number): TouchZoneAction {
    const zone: TouchZone = this.getTouchZone(x, y, pw, ph);
    return this.zoneActions[zone];
  }

  getAllActions(): TouchZoneAction[] {
    return this.zoneActions.slice();
  }

  static getAvailableActions(): TouchActionItem[] {
    const list: TouchActionItem[] = [];
    list.push({ value: TouchZoneAction.NONE, label: '无操作' } as TouchActionItem);
    list.push({ value: TouchZoneAction.PREV_PAGE, label: '上一页' } as TouchActionItem);
    list.push({ value: TouchZoneAction.NEXT_PAGE, label: '下一页' } as TouchActionItem);
    list.push({ value: TouchZoneAction.PREV_CHAPTER, label: '上一章' } as TouchActionItem);
    list.push({ value: TouchZoneAction.NEXT_CHAPTER, label: '下一章' } as TouchActionItem);
    list.push({ value: TouchZoneAction.MENU, label: '菜单' } as TouchActionItem);
    list.push({ value: TouchZoneAction.TOC, label: '目录' } as TouchActionItem);
    list.push({ value: TouchZoneAction.READ_ALOUD, label: '朗读' } as TouchActionItem);
    list.push({ value: TouchZoneAction.BRIGHTNESS, label: '亮度' } as TouchActionItem);
    list.push({ value: TouchZoneAction.SCROLL_UP, label: '向上滚动' } as TouchActionItem);
    list.push({ value: TouchZoneAction.SCROLL_DOWN, label: '向下滚动' } as TouchActionItem);
    return list;
  }

  static getActionLabel(action: TouchZoneAction): string {
    const items: TouchActionItem[] = PageTouchHandler.getAvailableActions();
    for (const item of items) {
      if (item.value === action) return item.label;
    }
    return '未知';
  }
}
