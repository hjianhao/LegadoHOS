/**
 * Cloudflare 验证弹窗
 *
 * 当请求被反爬保护拦截时，弹出此窗口让用户手动验证或查看错误。
 * - Cloudflare/JS 挑战：用户手动点击验证，通过后提取页面 HTML
 * - 真实硬错误：保留页面并显示状态，用户可重试或关闭
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
  /** ArkUI 重建组件时也要保留预填状态，避免 onPageEnd 重复派发输入事件。 */
  @State private prefillApplied_: boolean = false;
  @State private prefillSubmitted_: boolean = false;
  private prefillInFlight_: boolean = false;
  /** 同一弹窗内跨页面重载去重；新弹窗会生成新的 key。 */
  private prefillSessionKey_: string = '__legado_prefill_' + Date.now().toString();

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
            Button('重试').fontSize(14).height(40).padding({ left: 24, right: 24 })
              .borderRadius(20).margin({ top: 20 })
              .fontColor(ThemeColors.onPrimary(this.isDark))
              .backgroundColor(ThemeColors.primary(this.isDark))
              .onClick(() => { this.retryLoad_(); })
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
              // 表单，不能再次派发输入事件导致站点重复提交/重新限频。
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
              // Cloudflare Turnstile 会在挑战页内加载跨域 iframe；其脚本/媒体
              // 请求失败时 ArkWeb 也会回调 onErrorReceive。此类子框架错误不等于
              // 当前验证页无法使用，不能把整个 WebView 替换成错误页，否则用户
              // 尚未完成验证就失去复选框/跳转页面（山丽文学网即会触发
              // ERR_INTERNET_DISCONNECTED）。只有主框架失败才显示错误状态。
              let isMainFrame = true;
              try {
                isMainFrame = event?.request?.isMainFrame() ?? true;
              } catch (_e) {
                // 旧版本 Web API 可能不支持 isMainFrame，按主框架处理。
              }
              console.warn('[CloudflareDialog] WebView error:', errInfo);
              if (!isMainFrame) {
                console.info('[CloudflareDialog] Ignoring subframe WebView error:', errInfo);
                return;
              }
              // 即使页面稍后因主框架网络错误无法执行 outerHTML，也尽早把挑战
              // 期间写入的 cookie 交给 HTTP 层，供原始搜索请求重放。
              void this.syncCookies_();
              // Turnstile 的跨域资源在 ArkWeb 中偶发上报
              // ERR_INTERNET_DISCONNECTED（部分系统版本会误标为主框架）。
              // 这不是验证失败；保留交互页面，避免刚出现验证控件就切换到
              // 错误页。用户仍可完成验证并点击“验证完成”。
              if (/ERR_INTERNET_DISCONNECTED/i.test(errInfo) &&
                WebViewFetcher.interactivePurpose !== 'login') {
                this.isLoading = false;
                this.pageTitle = '验证页面部分资源加载失败，仍可继续操作';
                return;
              }
              this.hasError = true;
              this.isLoading = false;
              this.pageTitle = '页面加载出错，可重试或关闭';
            })
            .onHttpErrorReceive((event) => {
              const code = event?.response?.getResponseCode();
              // 子资源（图片/字体/统计接口）404/5xx 经常伴随正常页面出现，
              // 不能把整个交互页面切换成错误界面。即使主框架 4xx/5xx，浏览器
              // 仍会渲染站点错误页正文：保留 WebView 让用户看到真实内容并自行
              // 重试或导航，只是把状态码记入标题，避免“页面明明显示了一部分
              // 却突然跳到错误页”的断送式体验。
              let isMainFrame = true;
              try {
                isMainFrame = event?.request?.isMainFrame() ?? true;
              } catch (_e) {
                // 旧版本 Web API 可能不支持 isMainFrame，按主框架处理。
              }
              // 403 是 Cloudflare/WAF 常见状态码，但 Turnstile 挑战页本身也会
              // 返回 403，不能仅凭状态码判定为硬拦截；子资源 403（图片/脚本
              // 防盗链）同样只记录，不影响交互页面继续运行。
              if (code === 403) {
                console.warn('[CloudflareDialog] HTTP 403:', 'mainFrame=', String(isMainFrame), 'url=', this.url);
                if (isMainFrame) {
                  // Cloudflare 的 Turnstile 挑战页本身通常就是 HTTP 403，不能
                  // 仅凭状态码判定为“硬拦截”。保留 WebView 让用户完成挑战；
                  // 真正的 403/Not Found 短壳会在 extractAndClose 中结合页面
                  // 内容再判定，避免山丽文学网验证页被提前关闭。
                  this.pageTitle = '网站返回 HTTP 403 · 请完成验证后点击"验证完成"';
                } else {
                  console.info('[CloudflareDialog] Subresource 403:', this.url);
                }
              } else if (code && (code >= 500 || code === 404 || code === 410)) {
                console.warn('[CloudflareDialog] HTTP error:', code,
                  'mainFrame=', String(isMainFrame), 'url=', this.url);
                if (isMainFrame) {
                  this.pageTitle = '页面错误 ' + code + ' · 可切换视图或重试后继续';
                }
              } else {
                console.info('[CloudflareDialog] Subresource HTTP status:', code);
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
   * 返回空搜索页。只有明确的 searchSubmit 用途才自动提交。Cloudflare
   * challenge 的原始 POST 会在验证完成后由 SourceExecutor 重放；在验证
   * WebView 中提交表单会再次触发 WAF/验证码，山丽文学网尤其会因 keyup
   * 事件形成提交循环。
   */
  private async prefillRequest_(): Promise<void> {
    const body = (this.requestBody || '').trim();
    if (!body || this.prefillInFlight_) return;
    this.prefillInFlight_ = true;
    const bodyLiteral = JSON.stringify(body) || '""';
    const allowSubmitLiteral = WebViewFetcher.interactivePurpose === 'searchSubmit' ? 'true' : 'false';
    const sessionKeyLiteral = JSON.stringify(this.prefillSessionKey_) || '"__legado_prefill"';
    try {
      const result = await this.webController.runJavaScript(`(function(raw, allowSubmit, markerKey) {
        try {
          // 页面提交后会完整重载，普通 JS 变量会丢失；sessionStorage 在同源
          // 重载间保持不变，用它保证同一弹窗不会再次回填/提交同一请求。
          var markerStore = null;
          try {
            markerStore = window.sessionStorage;
            if (markerStore && markerKey && markerStore.getItem(markerKey) === '1') {
              return '0:0:0';
            }
          } catch (e) {}
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
          // 会维护自己的状态，使用原生 setter + input/change 事件同步状态。
          // 不派发 keydown/keyup：老站点常把 keyup 绑定为立即搜索，会造成
          // 验证页重载和验证码弹窗循环。
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
            // challenge 只需要把关键词显示给用户，不能触发站点的搜索监听器；
            // 否则某些老站会在 input/change 事件中再次提交。searchSubmit
            // 才需要同步框架状态并自动提交表单。
            if (!allowSubmit) return;
            var eventNames = ['input', 'change'];
            for (var eIndex = 0; eIndex < eventNames.length; eIndex++) {
              var eventName = eventNames[eIndex];
              try {
                var event = new Event(eventName, { bubbles: true, cancelable: true });
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
          if (filled > 0 && markerStore && markerKey) {
            try { markerStore.setItem(markerKey, '1'); } catch (e) {}
          }
          // challenge 用途只回填，不提交；验证通过后调用方会用原始 POST
          // body 重放。只有 webView=true 的 searchSubmit 流程允许自动提交。
          if (allowSubmit && filled > 0 && values.length > 0 && explicitSearchField) {
            try {
              // 只有明确找到请求体中的搜索字段，或控件本身明确标注为搜索框，
              // 才自动提交，避免误提交验证码表单。
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
      })(${bodyLiteral}, ${allowSubmitLiteral}, ${sessionKeyLiteral})`);
      const resultText = String(result || '0');
      const filledText = resultText.split(':')[0];
      const submittedText = resultText.split(':')[2] || '0';
      if (Number(filledText) > 0) {
        this.prefillApplied_ = true;
        this.clearPrefillTimer_();
      }
      if (Number(submittedText) > 0) {
        this.prefillSubmitted_ = true;
        this.clearPrefillTimer_();
      }
      console.info('[CloudflareDialog] POST 搜索关键词预填结果=' + resultText);
    } catch (e) {
      console.warn('[CloudflareDialog] 预填 POST 搜索关键词失败：', (e as Error).message);
    } finally {
      this.prefillInFlight_ = false;
    }
  }

  /** 页面脚本可能在 onPageEnd 之后才绑定搜索监听器，延迟再同步一次。 */
  private schedulePrefill_(): void {
    this.clearPrefillTimer_();
    if (!(this.requestBody || '').trim() || this.prefillApplied_ || this.prefillSubmitted_) return;
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

  /** 真实加载失败（网络/TLS 等）后重置错误状态，Web 组件重新挂载会自动重新加载 URL。 */
  private retryLoad_(): void {
    this.hasError = false;
    this.isLoading = true;
    this.pageTitle = '页面加载中...';
  }

  private async extractAndClose(): Promise<void> {
    this.clearPrefillTimer_();
    try {
      const html = await this.webController.runJavaScript(
        'document.documentElement.outerHTML'
      );
      if (html && typeof html === 'string' && html.length > 200) {
        const clean = WebViewFetcher.decodeJavaScriptString(html);
        // 无论当前提取到的是挑战页、404 壳还是正常结果，都先同步浏览器
        // 会话。Cloudflare 通行证往往会把 GET 挑战页重载成 404，而搜索随后
        // 还需要用原始 POST 体重放；若在挑战判定前返回，cf_clearance 不会
        // 进入 NetUtil 的 CookieStore，重放仍会再次收到 403。
        await this.syncCookies_();
        if (WebViewFetcher.isInteractiveChallengeHtml(clean)) {
          // 硬拦截兜底判定：提取到带 403/Not Found/CF 挑战脚本特征的短壳，
          // 且没有验证码控件时，说明交互窗口里没有可操作的验证入口。直接
          // 关闭并让调用方拿到空结果，由上层给出“站点无法适配”的明确错误。
          // 有些站点的挑战壳很大（会内嵌整段 Cloudflare 脚本），不能再用
          // 页面长度作为唯一条件。只要页面仍含 Turnstile iframe/验证码控件，
          // 就保留给用户操作；带挑战标记但完全没有入口的页面才判为硬拦截。
          const hasVerificationControl = /(?:cf-turnstile|cf-chl-widget|turnstile|challenge-form|challenges\.cloudflare\.com|captcha|验证码|<(?:input|form)\b[^>]*(?:verification|verify)[^>]*>)/i.test(clean);
          const hasHardBlockMarker = /not found|http error 404|403[^<]{0,20}|__CF\$cv\$params|challenge-platform/i.test(clean);
          const looksHardBlockedShell = hasHardBlockMarker && !hasVerificationControl;
          if (looksHardBlockedShell) {
            this.pageTitle = '站点被 Cloudflare/WAF 硬拦截，无法通过验证';
            this.doClose();
            return;
          }
          this.pageTitle = '验证尚未完成，请输入验证码并等待结果出现';
          return;
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

  /** 将交互 WebView 的会话同步到 HTTP 层，供验证后的请求重放使用。 */
  private async syncCookies_(): Promise<void> {
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
