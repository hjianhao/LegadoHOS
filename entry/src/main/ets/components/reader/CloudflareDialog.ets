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
import { WebUserAgent } from '../../util/WebUserAgent';
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
  /** 当前使用的视图模式；验证码/登录页多为移动版站点，默认移动 UA。 */
  @State isDesktopMode: boolean = false;
  private loginPanelOpened_: boolean = false;
  private prefillTimer_: number = -1;
  private prefillApplied_: boolean = false;
  private prefillSubmitted_: boolean = false;

  aboutToAppear(): void {
    // 不再强制桌面模式：部分站点的验证码只有移动版页面能加载，桌面版
    // 直接加载不出来。默认移动 UA（可被全局设置 webview_ua_mode 覆盖），
    // 顶部可一键切换到桌面版（部分站点对 HarmonyOS 默认 UA 返回错误页，
    // 这里用的是明确的 Android Chrome UA）。
    // setCustomUserAgent 必须在 Web 组件 attach 后调用，aboutToAppear 阶段
    // controller 尚未与组件关联，调用只会被静默忽略并抛异常。
    this.isDesktopMode = WebUserAgent.isDesktopMode(false);
  }

  /** controller 关联后按当前视图模式设置 UA。 */
  private applyUserAgent_(): void {
    try {
      this.webController.setCustomUserAgent(
        this.isDesktopMode ? WebUserAgent.DESKTOP : WebUserAgent.MOBILE);
    } catch (e) {
      console.warn('[CloudflareDialog] 设置 WebView UA 失败');
    }
  }

  /** 切换移动版/桌面版并重新加载当前页。 */
  private toggleViewMode_(): void {
    this.isDesktopMode = !this.isDesktopMode;
    this.applyUserAgent_();
    try {
      this.webController.refresh();
    } catch (e) {
      console.warn('[CloudflareDialog] 切换视图模式重载失败');
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
          Button(this.isDesktopMode ? '移动版' : '桌面版')
            .fontSize(12).fontColor(ThemeColors.onSurface(this.isDark))
            .height(40).padding({ left: 10, right: 10 })
            .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).borderRadius(16)
            .onClick(() => { this.toggleViewMode_(); })
        }
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
            .onControllerAttached(() => {
              this.applyUserAgent_();
            })
            .onPageBegin(() => {
              this.isLoading = true;
              this.clearPrefillTimer_();
            })
            .onPageEnd(() => {
              this.isLoading = false;
              // 只在首次搜索页同步输入框。提交后结果页也可能保留搜索
              // 表单，不能再次派发 keyup 导致站点重复提交/重新限频。
              if (!this.prefillApplied_) {
                void this.prefillRequest_();
                this.schedulePrefill_();
              }
              if (WebViewFetcher.interactivePurpose === 'login') {
                this.pageTitle = '登录页面（登录后点击"验证完成"）';
                void this.openLoginPanel_();
              } else if (WebViewFetcher.interactivePurpose === 'imageCaptcha') {
                this.pageTitle = '请完成图片验证码后点击"验证完成"';
              } else if (WebViewFetcher.interactivePurpose === 'searchSubmit') {
                this.pageTitle = '搜索提交页面（提交后点击"验证完成"）';
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
   * 返回空搜索页。搜索表单回填后自动提交，等价于用户重新输入并点击搜索；
   * WAF 页面没有匹配的搜索字段时不会提交，仍由用户手动完成验证。
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
          var dispatched = 0;
          var submitField = null;
          var explicitSearchField = false;
          var decode = function(value) {
            try { return decodeURIComponent(String(value || '').split('+').join(' ')); }
            catch (e) { return String(value || ''); }
          };
          // 不能只给 element.value 赋值：Vue/React 及不少老站点的搜索脚本
          // 会维护自己的状态，必须通过原生 setter + 输入/键盘事件同步状态，
          // 才等价于用户重新输入同一个关键词。
          var setNativeValue = function(element, value) {
            try {
              var proto = element instanceof HTMLTextAreaElement
                ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
              var descriptor = Object.getOwnPropertyDescriptor(proto, 'value');
              if (descriptor && descriptor.set) descriptor.set.call(element, value);
              else element.value = value;
            } catch (e) { element.value = value; }
            try { element.setAttribute('value', value); } catch (e) {}
            try { element.defaultValue = value; } catch (e) {}
          };
          var notifyInput = function(element) {
            var eventNames = ['input', 'change', 'keydown', 'keyup'];
            for (var eIndex = 0; eIndex < eventNames.length; eIndex++) {
              var eventName = eventNames[eIndex];
              try {
                var event;
                if (eventName === 'keydown' || eventName === 'keyup') {
                  event = new KeyboardEvent(eventName, {
                    bubbles: true, cancelable: true, key: 'Unidentified', code: '', keyCode: 0, which: 0
                  });
                } else {
                  event = new Event(eventName, { bubbles: true, cancelable: true });
                }
                element.dispatchEvent(event);
                dispatched++;
              } catch (e) {}
            }
          };
          for (var p = 0; p < pairs.length; p++) {
            var pair = pairs[p];
            var index = pair.indexOf('=');
            var key = decode(index >= 0 ? pair.substring(0, index) : pair);
            var value = decode(index >= 0 ? pair.substring(index + 1) : '');
            if (!key) continue;
            values.push({ key: key, value: value });
            for (var i = 0; i < fields.length; i++) {
              if (String(fields[i].name || '').toLowerCase() !== key.toLowerCase()) continue;
              // 页面加载后可能由异步脚本才绑定搜索监听器。延迟重放时只
              // 更新空值或仍是本次预填值的控件，不覆盖用户已经改写的关键词。
              var currentValue = String(fields[i].value || '');
              if (currentValue && currentValue !== value) continue;
              setNativeValue(fields[i], value);
              notifyInput(fields[i]);
              if (p === 0) {
                submitField = fields[i];
                explicitSearchField = true;
              }
              filled++;
              break;
            }
          }
          // 某些站点的搜索输入框没有 name，body 中的字段名只能作为语义线索；
          // 找不到同名控件时回填第一个可见文本搜索框，至少保证用户可直接点击搜索。
          if (filled === 0 && values.length > 0) {
            for (var j = 0; j < fields.length; j++) {
              var type = String(fields[j].type || 'text').toLowerCase();
              var currentFallbackValue = String(fields[j].value || '');
              var fallbackDescriptor = [fields[j].id, fields[j].className, fields[j].placeholder,
                fields[j].getAttribute('aria-label')].join(' ');
              if ((type === 'text' || type === 'search') && !fields[j].disabled &&
                (!currentFallbackValue || currentFallbackValue === values[0].value)) {
                setNativeValue(fields[j], values[0].value);
                notifyInput(fields[j]);
                submitField = fields[j];
                explicitSearchField = /search|query|keyword|搜索|关键字/i.test(fallbackDescriptor);
                filled++;
                break;
              }
            }
          }
          var submitted = 0;
          if (filled > 0 && values.length > 0 && explicitSearchField) {
            try {
              // 只有明确找到请求体中的搜索字段，或控件本身明确标注为搜索框，
              // 才自动提交；挑战页通常没有这些特征，因此不会误提交验证码表单。
              if (submitField && submitField.form) {
                var submitForm = submitField.form;
                if (typeof submitForm.requestSubmit === 'function') {
                  submitForm.requestSubmit();
                  submitted = 1;
                } else {
                  var submitButton = submitForm.querySelector('button[type="submit"],input[type="submit"]');
                  if (submitButton && typeof submitButton.click === 'function') {
                    submitButton.click();
                    submitted = 1;
                  }
                }
              }
            } catch (e) {}
          }
          return String(filled) + ':' + String(dispatched) + ':' + String(submitted);
        } catch (e) { return '0'; }
      })(${bodyLiteral})`);
      const resultText = String(result || '0');
      const filledText = resultText.split(':')[0];
      const submittedText = resultText.split(':')[2] || '0';
      if (Number(filledText) > 0) this.prefillApplied_ = true;
      if (Number(submittedText) > 0) {
        this.prefillSubmitted_ = true;
        this.clearPrefillTimer_();
      }
      console.info('[CloudflareDialog] POST 搜索关键词预填结果=' + resultText);
    } catch (e) {
      console.warn('[CloudflareDialog] 预填 POST 搜索关键词失败：', (e as Error).message);
    }
  }

  /** 页面脚本可能在 onPageEnd 之后才绑定搜索监听器，延迟再同步一次。 */
  private schedulePrefill_(): void {
    this.clearPrefillTimer_();
    if (!(this.requestBody || '').trim() || this.prefillSubmitted_) return;
    this.prefillTimer_ = setTimeout((): void => {
      this.prefillTimer_ = -1;
      void this.prefillRequest_();
    }, 800);
  }

  private clearPrefillTimer_(): void {
    if (this.prefillTimer_ >= 0) {
      clearTimeout(this.prefillTimer_);
      this.prefillTimer_ = -1;
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
    this.clearPrefillTimer_();
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
    this.clearPrefillTimer_();
    if (WebViewFetcher.interactiveResolve) {
      WebViewFetcher.interactiveResolve('');
      WebViewFetcher.interactiveResolve = null;
    }
    this.controller.close();
  }
}
