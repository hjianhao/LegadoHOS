/**
 * Cloudflare 验证弹窗
 *
 * 当请求被反爬保护拦截时，弹出此窗口让用户手动验证或查看错误。
 * - Cloudflare/JS 挑战：用户手动点击验证，通过后提取页面 HTML
 * - 403/404 等硬错误：显示错误信息，自动关闭
 */
import web_webview from '@ohos.web.webview';
import { ThemeColors } from '../../theme/ThemeColors';
import { WebViewFetcher } from '../../engine/web/WebViewFetcher';

@CustomDialog
export struct CloudflareDialog {
  controller: CustomDialogController;
  url: string = '';
  @StorageLink('isDark') isDark: boolean = false;
  private webController: web_webview.WebviewController = new web_webview.WebviewController();
  @State pageTitle: string = '页面加载中...';
  @State isLoading: boolean = true;
  @State hasError: boolean = false;

  build() {
    Column() {
      // 顶部栏
      Row() {
        Text(this.pageTitle).fontSize(15).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark)).layoutWeight(1)
        if (!this.hasError) {
          Button($r('app.string.ui_94eb3aea29')).fontSize(13).fontColor(ThemeColors.onPrimary(this.isDark))
            .height(40).padding({ left: 12, right: 12 })
            .backgroundColor(ThemeColors.primary(this.isDark)).borderRadius(16)
            .onClick(() => { this.extractAndClose(); })
        }
        Button($r('app.string.common_close')).fontSize(13).fontColor(ThemeColors.onBackground(this.isDark))
          .height(40).padding({ left: 8, right: 8 })
          .backgroundColor(Color.Transparent)
          .onClick(() => { this.doClose(); })
      }
      .width('100%').height(44).padding({ left: 12, right: 8 })
      .backgroundColor(ThemeColors.surface(this.isDark))

      // WebView
      Stack() {
        if (this.hasError) {
          Column() {
            Text($r('app.string.ui_bf341e957f')).fontSize(48).margin({ top: 60 })
            Text($r('app.string.ui_e1a2e746b7')).fontSize(16).fontWeight(FontWeight.Medium)
              .fontColor(ThemeColors.onBackground(this.isDark)).margin({ top: 12 })
            Text($r('app.string.ui_82153b1e69')).fontSize(13)
              .fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 8 })
            Text(this.url).fontSize(11)
              .fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 16 })
              .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding({ left: 20, right: 20 })
          }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Center)
        } else {
          Web({ src: this.url, controller: this.webController })
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .zoomAccess(false)
            .overviewModeAccess(true)
            .onPageBegin(() => { this.isLoading = true; })
            .onPageEnd(() => {
              this.isLoading = false;
              this.pageTitle = '验证页面（验证后点击"验证完成"）';
            })
            .onErrorReceive((event) => {
              if (event?.error?.getErrorCode() === -1) return;
              const errInfo = event?.error?.getErrorInfo() || '';
              console.warn('[CloudflareDialog] WebView error:', errInfo);
            })
            .onHttpErrorReceive((event) => {
              const code = event?.response?.getResponseCode();
              if (code === 403 || code === 404 || (code && code >= 500)) {
                console.warn('[CloudflareDialog] HTTP error:', code);
                this.hasError = true;
                this.pageTitle = '页面错误 ' + (code || '');
                this.isLoading = false;
              }
            })
            .width('100%').layoutWeight(1)

          if (this.isLoading) {
            LoadingProgress().color(ThemeColors.primary(this.isDark))
          }
        }
      }
    }
    .width('96%').height('92%')
    .backgroundColor(ThemeColors.background(this.isDark))
    .borderRadius(16)
  }

  private async extractAndClose(): Promise<void> {
    try {
      const html = await this.webController.runJavaScript(
        'document.documentElement.outerHTML'
      );
      if (html && typeof html === 'string' && html.length > 200) {
        const clean = html.replace(/^"|"$/g, '');
        console.info('[CloudflareDialog] Extracted HTML:', clean.length, 'bytes');
        if (WebViewFetcher.interactiveResolve) {
          WebViewFetcher.interactiveResolve(clean);
          WebViewFetcher.interactiveResolve = null;
        }
        this.controller.close();
        return;
      }
    } catch (e) {
      console.warn('[CloudflareDialog] Extract error:', (e as Error).message);
    }
    this.doClose();
  }

  private doClose(): void {
    if (WebViewFetcher.interactiveResolve) {
      WebViewFetcher.interactiveResolve('');
      WebViewFetcher.interactiveResolve = null;
    }
    this.controller.close();
  }
}
