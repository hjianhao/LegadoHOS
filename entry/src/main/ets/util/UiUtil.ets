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

  static pushUrl(uiContext: UIContext, options: router.RouterOptions, mode?: router.RouterMode): void {
    // 优先走页签内 NavPathStack，支持平板 Navigation Split 分栏
    const url = options.url ?? '';
    if (typeof url === 'string' && url.length > 0) {
      const pageName = (url.startsWith('pages/') ? url.substring('pages/'.length) : url) as NavPageName;
      if (NavRouter.push(pageName, options.params as object | undefined)) {
        return;
      }
    }
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
    // 优先弹出 Navigation 栈（平板分栏右侧详情）
    if (NavRouter.depth() > 0 && NavRouter.back()) {
      return;
    }
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
