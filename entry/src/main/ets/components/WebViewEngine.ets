/**
 * 隐藏的 WebView 渲染引擎
 * 嵌入到搜索页面底部，为需要 JS 渲染的搜索源提供网页加载能力
 *
 * 支持：
 * - DNS-over-HTTPS（DoH）配置（通过 WebViewFetcher.configureDns）
 * - HTTP 代理配置（通过 WebViewFetcher.configureProxy）
 * - 重定向次数限制（通过 onLoadIntercept）
 *
 * 用法：
 * ```ets
 * build() {
 *   Stack() {
 *     // 页面主要内容
 *     Scroll() { ... }
 *     // 隐藏 WebView
 *     WebViewEngine()
 *   }
 * }
 * ```
 */
import web_webview from '@ohos.web.webview';
import { WebViewFetcher } from '../engine/web/WebViewFetcher';

@Component
export struct WebViewEngine {
  private controller: web_webview.WebviewController = new web_webview.WebviewController();

  aboutToAppear(): void {
    WebViewFetcher.register(this.controller);
  }

  aboutToDisappear(): void {
    // 页面销毁时结算仍挂在本控制器上的 fetch 并释放全局引用；否则遗留的
    // pending 请求会一直占用 WebView 队列，后续页面（如书源校验）的请求
    // 只能排队等待，甚至 loadUrl 到已销毁的控制器上没有任何页面事件。
    WebViewFetcher.release(this.controller);
  }

  build() {
    Column() {
      Web({ src: '', controller: this.controller })
        .width('100%').height('100%')
        .onPageEnd((event) => {
          WebViewFetcher.onPageEnd(event);
        })
        .onErrorReceive(() => {
          WebViewFetcher.onPageEnd({ url: '' });
        })
        .onLoadIntercept((event) => {
          // 拦截 URL 加载，用于限制重定向次数（event.data 为 WebResourceRequest）
          return WebViewFetcher.onLoadIntercept(event.data.getRequestUrl());
        })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .mixedMode(MixedMode.All)
    }
    .width(1).height(1)
    // 防止父组件强设 0x0 导致 WebView 不渲染
    .constraintSize({ minWidth: 1, minHeight: 1 })
    .visibility(Visibility.None)
  }
}
