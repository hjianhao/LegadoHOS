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
import { CookieStore } from '../../util/CookieStore';

@CustomDialog
export struct CloudflareDialog {
  controller: CustomDialogController;
  url: string = '';
  /** 当前页面需要用户完成的具体操作，例如登录或输入图片验证码。 */
  reason: string = '页面需要人工验证';
  /** POST 搜索验证时用于预填搜索框的原始表单体。 */
  requestBody: string = '';
  @StorageLink('isDark') isDark: boolean = false;
  private webController: web_webview.WebviewController = new web_webview.WebviewController();
  @State pageTitle: string = '页面加载中...';
  @State isLoading: boolean = true;
  @State hasError: boolean = false;
  private loginPanelOpened_: boolean = false;

  aboutToAppear(): void {
    // 与隐藏 WebViewFetcher 使用同一桌面 UA。部分站点对 HarmonyOS 默认 UA
    // 返回错误页，用户看到“验证 WebView 加载失败”并不是验证码本身失败。
    try {
      this.webController.setCustomUserAgent(
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36');
    } catch (_e) {
      console.warn('[CloudflareDialog] 设置 WebView UA 失败');
    }
  }

  build() {
    Column() {
      // 顶部栏
      Row() {
        Column({ space: 1 }) {
          Text(this.pageTitle).fontSize(15).fontWeight(FontWeight.Bold)
            .fontColor(ThemeColors.onBackground(this.isDark)).maxLines(1)
          Text(this.reason || '请完成页面要求的操作').fontSize(11)
            .fontColor(ThemeColors.secondaryText(this.isDark)).maxLines(1)
        }.layoutWeight(1)
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
            Text($r('app.string.ui_bf341e957f')).fontColor(ThemeColors.onSurface(this.isDark)).fontSize(48).margin({ top: 60 })
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
              void this.prefillRequest_();
              if (WebViewFetcher.interactivePurpose === 'login') {
                this.pageTitle = '登录页面（登录后点击"验证完成"）';
                void this.openLoginPanel_();
              } else if (this.reason && this.reason.includes('图片验证码')) {
                this.pageTitle = '请完成图片验证码后点击"验证完成"';
              } else {
                this.pageTitle = '验证页面（验证后点击"验证完成"）';
              }
            })
            .onErrorReceive((event) => {
              if (event?.error?.getErrorCode() === -1) return;
              const errInfo = event?.error?.getErrorInfo() || '';
              console.warn('[CloudflareDialog] WebView error:', errInfo);
              this.hasError = true;
              this.isLoading = false;
              this.pageTitle = '页面加载出错，请关闭后重试';
            })
            .onHttpErrorReceive((event) => {
              const code = event?.response?.getResponseCode();
              // 403 可能来自 Cloudflare 验证页（Turnstile），让用户看到页面而非报错
              if ((code && code >= 500) || code === 404 || code === 410) {
                console.warn('[CloudflareDialog] HTTP error:', code);
                this.hasError = true;
                this.pageTitle = '页面错误 ' + (code || '');
                this.isLoading = false;
              }
            })
            .mixedMode(MixedMode.All)
            .width('100%').layoutWeight(1)

          if (this.isLoading) {
            LoadingProgress().color(ThemeColors.primary(this.isDark))
          }
        }
      }
    }
    .width('96%').height('92%').constraintSize({ maxWidth: 1200, maxHeight: 900 })
    .backgroundColor(ThemeColors.background(this.isDark))
    .borderRadius(16)
  }

  /**
   * 交互验证打开的是 GET 页面，而触发验证的请求可能是 POST；如果不把
   * 原始表单体回填，用户看到的搜索框就是空的，点击“验证完成”也只会
   * 返回空搜索页。回填只更新字段并触发 input/change，不自动提交，避免
   * 在 WAF 脚本尚未完成时打断页面验证。
   */
  private async prefillRequest_(): Promise<void> {
    const body = (this.requestBody || '').trim();
    if (!body) return;
    const bodyLiteral = JSON.stringify(body) || '""';
    try {
      const result = await this.webController.runJavaScript(`(function(raw) {
        try {
          var fields = document.querySelectorAll('input,textarea,select');
          var pairs = String(raw || '').split('&');
          var values = [];
          var filled = 0;
          var decode = function(value) {
            try { return decodeURIComponent(String(value || '').split('+').join(' ')); }
            catch (e) { return String(value || ''); }
          };
          for (var p = 0; p < pairs.length; p++) {
            var pair = pairs[p];
            var index = pair.indexOf('=');
            var key = decode(index >= 0 ? pair.substring(0, index) : pair);
            var value = decode(index >= 0 ? pair.substring(index + 1) : '');
            if (!key) continue;
            values.push({ key: key, value: value });
            for (var i = 0; i < fields.length; i++) {
              if (String(fields[i].name || '') !== key) continue;
              fields[i].value = value;
              try { fields[i].dispatchEvent(new Event('input', { bubbles: true })); } catch (e) {}
              try { fields[i].dispatchEvent(new Event('change', { bubbles: true })); } catch (e) {}
              filled++;
              break;
            }
          }
          // 某些站点的搜索输入框没有 name，body 中的字段名只能作为语义线索；
          // 找不到同名控件时回填第一个可见文本搜索框，至少保证用户可直接点击搜索。
          if (filled === 0 && values.length > 0) {
            for (var j = 0; j < fields.length; j++) {
              var type = String(fields[j].type || 'text').toLowerCase();
              if ((type === 'text' || type === 'search') && !fields[j].disabled) {
                fields[j].value = values[0].value;
                try { fields[j].dispatchEvent(new Event('input', { bubbles: true })); } catch (e) {}
                try { fields[j].dispatchEvent(new Event('change', { bubbles: true })); } catch (e) {}
                filled++;
                break;
              }
            }
          }
          return String(filled);
        } catch (e) { return '0'; }
      })(${bodyLiteral})`);
      console.info('[CloudflareDialog] POST 搜索关键词预填字段数=' + String(result || '0'));
    } catch (e) {
      console.warn('[CloudflareDialog] 预填 POST 搜索关键词失败：', (e as Error).message);
    }
  }

  /** 登录模式下自动展开站点常见的登录弹层，避免用户先找登录入口。 */
  private async openLoginPanel_(): Promise<void> {
    if (this.loginPanelOpened_) return;
    this.loginPanelOpened_ = true;
    try {
      const result = await this.webController.runJavaScript(`(function() {
        try {
          if (typeof toggleLogin === 'function') { toggleLogin(); return 'toggleLogin'; }
          var trigger = document.querySelector('[onclick*="toggleLogin"]');
          if (trigger) { trigger.click(); return 'click'; }
        } catch (e) { return ''; }
        return '';
      })()`);
      console.info('[CloudflareDialog] Login panel auto-open result:', String(result || 'none'));
    } catch (e) {
      console.warn('[CloudflareDialog] Auto-open login panel failed:', (e as Error).message);
    }
  }

  private async extractAndClose(): Promise<void> {
    try {
      const html = await this.webController.runJavaScript(
        'document.documentElement.outerHTML'
      );
      if (html && typeof html === 'string' && html.length > 200) {
        const clean = WebViewFetcher.decodeJavaScriptString(html);
        if (WebViewFetcher.isInteractiveChallengeHtml(clean)) {
          this.pageTitle = '验证尚未完成，请输入验证码并等待结果出现';
          return;
        }
        try {
          const webCookie = web_webview.WebCookieManager.fetchCookieSync(this.url);
          if (webCookie && webCookie.trim()) {
            await CookieStore.getInstance().setCookie(this.url, webCookie);
            console.info('[CloudflareDialog] WebView Cookie 已同步，长度=' + webCookie.length);
          }
        } catch (cookieError) {
          console.warn('[CloudflareDialog] 同步 WebView Cookie 失败：',
            (cookieError as Error).message);
        }
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
