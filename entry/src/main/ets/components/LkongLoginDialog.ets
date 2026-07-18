/** 龙空网页登录弹窗：登录完成后同步会话给 GraphQL API。 */
import web_webview from '@ohos.web.webview';
import { ThemeColors } from '../theme/ThemeColors';
import { CookieStore, parseCookieHeader } from '../util/CookieStore';
import { LKONG_API_URL, LKONG_BASE_URL, LKONG_LOGIN_URL, LkongService } from '../service/LkongService';
import { UiUtil } from '../util/UiUtil';

@CustomDialog
export struct LkongLoginDialog {
  controller: CustomDialogController;
  onLoginSuccess: () => void = (): void => {};

  @StorageLink('isDark') isDark: boolean = false;
  @State private pageLoading: boolean = true;
  private webController: web_webview.WebviewController = new web_webview.WebviewController();
  private isActive: boolean = false;
  private finishRequestId: number = 0;

  aboutToAppear(): void {
    this.isActive = true;
    try {
      web_webview.WebCookieManager.putAcceptCookieEnabled(true);
      const stored = CookieStore.getInstance().getCookie(LKONG_BASE_URL);
      if (stored) {
        parseCookieHeader(stored).forEach((value: string, key: string): void => {
          web_webview.WebCookieManager.configCookie(LKONG_BASE_URL, key + '=' + value).catch((): void => {});
          web_webview.WebCookieManager.configCookie(LKONG_API_URL, key + '=' + value).catch((): void => {});
        });
      }
    } catch (e) {
      console.warn('[LkongLogin] push cookies failed:', (e as Error).message);
    }
  }

  aboutToDisappear(): void {
    this.isActive = false;
    this.finishRequestId++;
  }

  build() {
    Column() {
      Row() {
        Text('登录龙的天空').fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark)).layoutWeight(1)
        Button('完成').fontSize(13).fontColor(ThemeColors.onPrimary(this.isDark))
          .height(44).padding({ left: 12, right: 12 }).borderRadius(22)
          .backgroundColor(ThemeColors.primary(this.isDark))
          .onClick((): void => { void this.finishLogin(); })
        Button('关闭').fontSize(13).fontColor(ThemeColors.onBackground(this.isDark))
          .height(44).padding({ left: 10, right: 10 }).backgroundColor(Color.Transparent)
          .onClick((): void => { this.controller.close(); })
      }.width('100%').height(52).padding({ left: 12, right: 8 })

      Stack() {
        Web({ src: LKONG_LOGIN_URL, controller: this.webController })
          .javaScriptAccess(true).domStorageAccess(true).zoomAccess(true)
          .onPageBegin((): void => { if (this.isActive) this.pageLoading = true; })
          .onPageEnd((): void => { if (this.isActive) this.pageLoading = false; })
          .width('100%').layoutWeight(1)
        if (this.pageLoading) LoadingProgress().color(ThemeColors.primary(this.isDark))
      }.width('100%').layoutWeight(1)
      Text('在页面中完成登录（含验证码/二次验证）后点击“完成”')
        .fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark))
        .width('100%').padding({ left: 12, right: 12, top: 6, bottom: 8 })
    }
    .width('96%').height('92%').borderRadius(16)
    .backgroundColor(ThemeColors.background(this.isDark))
  }

  private async finishLogin(): Promise<void> {
    const runId = ++this.finishRequestId;
    try {
      const webCookie = web_webview.WebCookieManager.fetchCookieSync(LKONG_BASE_URL);
      const apiCookie = web_webview.WebCookieManager.fetchCookieSync(LKONG_API_URL);
      const cookie = [webCookie, apiCookie].filter((value: string): boolean => !!value && !!value.trim()).join('; ');
      if (!cookie || !cookie.trim()) {
        UiUtil.showToast(this.getUIContext(), { message: '未获取到登录 Cookie，请确认已登录' });
        return;
      }
      const store = CookieStore.getInstance();
      await store.setCookie(LKONG_BASE_URL, cookie);
      // 龙空 GraphQL 位于独立子域；显式复制域 Cookie，供 NetUtil 注入。
      await store.setCookie(LKONG_API_URL, cookie);
      if (!this.isActive || runId !== this.finishRequestId) return;
      // Cookie 存在不等于已登录，通过受保护板块请求验证会话。
      await LkongService.loadThreads('all', 1);
      if (!this.isActive || runId !== this.finishRequestId) return;
      UiUtil.showToast(this.getUIContext(), { message: '龙空登录状态已保存' });
      this.onLoginSuccess();
      this.controller.close();
    } catch (e) {
      if (!this.isActive || runId !== this.finishRequestId) return;
      UiUtil.showToast(this.getUIContext(), { message: '登录验证失败：' + (e as Error).message });
    }
  }
}
