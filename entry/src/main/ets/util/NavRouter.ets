/**
 * Navigation 导航路由器
 *
 * 为 MainPage 的四个页签分别维护独立的 NavPathStack，支持：
 * - 每个页签独立的导航栈（切换页签时保留各页签的子页面状态）
 * - 平板宽屏下列表/详情分栏（详情通过 NavPathStack push 到右侧面板）
 * - 与现有 router 导航共存（阅读器等全屏页面仍走 router）
 *
 * 使用方式：
 *   NavRouter.setActiveStack(stack)  // 在 MainPage onChange 中调用
 *   NavRouter.push('pages/BookSourcePage', { url: ... })
 *   NavRouter.back()
 *
 * NavDestination 注册在 MainPage 的 @NavDestination builder 中。
 */

/** 支持通过 NavRouter 导航的页面名（不含 'pages/' 前缀） */
export type NavPageName =
  | 'BookSourcePage'
  | 'BookSourceEditPage'
  | 'BookSourceDebugPage'
  | 'ReplaceRulePage'
  | 'ReplaceRuleEditPage'
  | 'SettingsPage'
  | 'SearchPage'
  | 'BookInfoPage'
  | 'ChapterListPage'
  | 'ChangeSourcePage'
  | 'BookshelfManagePage'
  | 'BookmarkPage'
  | 'FontManagerPage'
  | 'BackupSettingsPage'
  | 'AiConfigPage'
  | 'AiImportBookPage'
  | 'AiSourceGeneratePage'
  | 'CacheManagePage'
  | 'ReadRecordPage'
  | 'RssSourceManagePage'
  | 'RssSortPage'
  | 'RssArticlesPage'
  | 'WebServicePage'
  | 'AboutPage'
  | 'GroupManagePage';

/**
 * NavRouter 单例 - 管理当前活跃的 NavPathStack。
 * NavPathStack 是 ArkUI 全局类型，不需要 import。
 */
export class NavRouter {
  /** 当前活跃页签的 NavPathStack */
  private static activeStack: NavPathStack | null = null;

  /** 各页签的 NavPathStack 引用，由 MainPage 注入 */
  private static stacks: Map<number, NavPathStack> = new Map();

  /**
   * 注册页签对应的 NavPathStack。
   * 在 MainPage aboutToAppear 中为每个页签调用。
   */
  static registerStack(tabIndex: number, stack: NavPathStack): void {
    NavRouter.stacks.set(tabIndex, stack);
  }

  /**
   * 设置当前活跃的页签索引。
   * 在 MainPage Tabs.onChange 中调用。
   */
  static setActiveTab(tabIndex: number): void {
    const stack = NavRouter.stacks.get(tabIndex);
    if (stack) {
      NavRouter.activeStack = stack;
    }
  }

  /**
   * 获取当前活跃的 NavPathStack。
   * 如果未设置（如冷启动前），返回 null。
   */
  static getActiveStack(): NavPathStack | null {
    return NavRouter.activeStack;
  }

  /**
   * 获取指定页签的 NavPathStack。
   */
  static getStack(tabIndex: number): NavPathStack | null {
    return NavRouter.stacks.get(tabIndex) ?? null;
  }

  /** 规范化页面名为 `pages/Xxx` 形式 */
  private static normalizeName(pageName: string): string {
    return pageName.startsWith('pages/') ? pageName : 'pages/' + pageName;
  }

  /**
   * Push 一个页面到当前活跃页签的导航栈。
   *
   * @param pageName 页面名（不含 'pages/' 前缀，如 'BookSourcePage'）
   * @param param 传递给目标页面的参数
   * @returns true 如果成功 push，false 如果没有活跃的 stack（调用方应回退到 router）
   */
  static push(pageName: NavPageName, param?: object): boolean {
    const stack = NavRouter.activeStack;
    if (!stack) {
      console.warn('[NavRouter] No active stack, falling back to router for ' + pageName);
      return false;
    }
    try {
      stack.pushPath({ name: NavRouter.normalizeName(pageName), param: param });
      return true;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error('[NavRouter] push failed: ' + msg);
      return false;
    }
  }

  /**
   * 替换当前栈顶页面（无栈顶时 push）。
   * 用于平板分栏：左侧菜单切换右侧详情时避免无限堆栈。
   */
  static replace(pageName: NavPageName, param?: object): boolean {
    const stack = NavRouter.activeStack;
    if (!stack) {
      console.warn('[NavRouter] No active stack, falling back to router for replace ' + pageName);
      return false;
    }
    try {
      const nameWithPath = NavRouter.normalizeName(pageName);
      if (stack.size() > 0) {
        stack.replacePath({ name: nameWithPath, param: param });
      } else {
        stack.pushPath({ name: nameWithPath, param: param });
      }
      return true;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error('[NavRouter] replace failed: ' + msg);
      return false;
    }
  }

  /**
   * 返回上一页。如果当前栈为空或只有根页面，不操作。
   */
  static back(): boolean {
    const stack = NavRouter.activeStack;
    if (!stack || stack.size() === 0) return false;
    try {
      stack.pop();
      return true;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error('[NavRouter] back failed: ' + msg);
      return false;
    }
  }

  /**
   * 返回到指定页面（清除中间页面）。
   * @param pageName 要返回到的页面名
   */
  static backTo(pageName: NavPageName): boolean {
    const stack = NavRouter.activeStack;
    if (!stack) return false;
    try {
      const nameWithPath = pageName.startsWith('pages/') ? pageName : 'pages/' + pageName;
      stack.popToName(nameWithPath);
      return true;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error('[NavRouter] backTo failed: ' + msg);
      return false;
    }
  }

  /**
   * 清空当前页签的导航栈（回到首页）。
   */
  static clear(): void {
    const stack = NavRouter.activeStack;
    if (!stack) return;
    try {
      stack.clear();
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error('[NavRouter] clear failed: ' + msg);
    }
  }

  /**
   * 当前活跃栈的深度（0 = 在首页，1+ = 有子页面）。
   */
  static depth(): number {
    const stack = NavRouter.activeStack;
    return stack ? stack.size() : 0;
  }
}
