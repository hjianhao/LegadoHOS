import type promptAction from '@ohos.promptAction';
import type router from '@ohos.router';
import { NavRouter, NavPageName } from './NavRouter';

export class UiUtil {
  static getHostContext(uiContext: UIContext): Context {
    const context = uiContext.getHostContext();
    if (!context) {
      throw new Error('Host context is unavailable');
    }
    return context;
  }

  static showToast(uiContext: UIContext, options: promptAction.ShowToastOptions): void {
    try {
      uiContext.getPromptAction().showToast(options);
    } catch (err) {
      console.warn('[UiUtil] showToast failed:', err);
    }
  }

  static async showDialog(
    uiContext: UIContext,
    options: promptAction.ShowDialogOptions
  ): Promise<promptAction.ShowDialogSuccessResponse> {
    try {
      return await uiContext.getPromptAction().showDialog(options);
    } catch (err) {
      console.warn('[UiUtil] showDialog failed:', err);
      const fallback: promptAction.ShowDialogSuccessResponse = { index: -1 };
      return fallback;
    }
  }

  static showAlertDialog(
    uiContext: UIContext,
    options: AlertDialogParamWithConfirm | AlertDialogParamWithButtons | AlertDialogParamWithOptions
  ): void {
    try {
      uiContext.showAlertDialog(options);
    } catch (err) {
      console.warn('[UiUtil] showAlertDialog failed:', err);
    }
  }

  /**
   * 在「我的」等页签 Navigation 内 push（支持平板 Split）。
   * 失败时回退 classic router。阅读器等全屏页请直接用本方法的 classic 路径，
   * 或继续调用本 pushUrl（不强制进 Nav 栈，避免盖在阅读器下看不见）。
   */
  static pushInNav(uiContext: UIContext, url: string, params?: object): void {
    if (url.length > 0) {
      const pageName = (url.startsWith('pages/') ? url.substring('pages/'.length) : url) as NavPageName;
      if (NavRouter.isNavPage(pageName) && NavRouter.push(pageName, params)) {
        return;
      }
    }
    UiUtil.pushUrl(uiContext, { url: url, params: params });
  }

  static pushUrl(uiContext: UIContext, options: router.RouterOptions, mode?: router.RouterMode): void {
    try {
      if (mode !== undefined) {
        uiContext.getRouter().pushUrl(options, mode).catch((err: Error) => {
          console.warn('[UiUtil] pushUrl failed:', err);
        });
        return;
      }
      uiContext.getRouter().pushUrl(options).catch((err: Error) => {
        console.warn('[UiUtil] pushUrl failed:', err);
      });
    } catch (err) {
      console.warn('[UiUtil] pushUrl failed:', err);
    }
  }

  static back(uiContext: UIContext, options?: router.RouterOptions): void {
    // 1) classic router 有上层页（如内嵌设置里再打开 AI/备份）时先 pop
    // 注意：getLength() 返回 string
    try {
      const len = Number(uiContext.getRouter().getLength());
      if (Number.isFinite(len) && len > 1) {
        uiContext.getRouter().back(options);
        return;
      }
    } catch (_e) {
      // ignore，继续后续策略
    }
    // 2) 「我的」宽屏内嵌详情：通知清空右侧（MyPage 监听 AppStorage）
    try {
      const embedded = AppStorage.get<string>('myEmbeddedDetail') ?? '';
      if (embedded.length > 0) {
        AppStorage.setOrCreate('myEmbeddedDetail', '');
        // 发事件标记，MyPage onPageShow / 轮询 Storage 时会同步 @State
        AppStorage.setOrCreate('myEmbeddedDetailCleared', Date.now());
        return;
      }
    } catch (_e) {
      // ignore
    }
    // 3) Navigation 栈
    if (NavRouter.depth() > 0 && NavRouter.back()) {
      return;
    }
    // 4) classic router 兜底
    try {
      uiContext.getRouter().back(options);
    } catch (err) {
      console.warn('[UiUtil] back failed:', err);
    }
  }

  static getParams(uiContext: UIContext): Object {
    try {
      return uiContext.getRouter().getParams();
    } catch (err) {
      console.warn('[UiUtil] getParams failed:', err);
      return new Object();
    }
  }

  /**
   * 自适应弹窗对齐方式：Compact 底部，Medium+ 居中。
   * 用于 CustomDialogController 的 alignment 参数。
   */
  static adaptiveDialogAlignment(): DialogAlignment {
    const isWide = AppStorage.get<boolean>('windowIsWide') ?? false;
    return isWide ? DialogAlignment.Center : DialogAlignment.Bottom;
  }
}
