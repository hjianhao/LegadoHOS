import type promptAction from '@ohos.promptAction';
import type router from '@ohos.router';

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
}
