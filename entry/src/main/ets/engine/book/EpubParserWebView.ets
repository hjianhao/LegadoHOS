/**
 * EPUB 解析用隐藏 WebView 组件
 */
import web_webview from '@ohos.web.webview';
import { setParserController } from './EpubJsParser';

@Component
export struct EpubParserWebView {
  private controller: web_webview.WebviewController = new web_webview.WebviewController();

  aboutToAppear(): void {
    setParserController(this.controller);
  }

  build() {
    Column() {
      Web({ src: $rawfile('epub/epub-parser.html'), controller: this.controller })
        .width('100%').height('100%')
        .javaScriptAccess(true)
        .domStorageAccess(true)
    }
    .width(1).height(1)
    .constraintSize({ minWidth: 1, minHeight: 1 })
    .visibility(Visibility.None)
  }
}
