/**
 * EPUB 图文混排阅读页 — WebView + EPUB.js 引擎
 *
 * 使用流程：
 *   1. 解压 EPUB 到沙箱（Worker 线程）
 *   2. 启动 EpubServer（本地 HTTP 服务）
 *   3. WebView 加载 reader.html
 *   4. EPUB.js 通过 HTTP 加载 OPF，分页渲染
 *
 * TODO: 当前为框架占位，待 WebView 引擎开发时实现完整逻辑
 */
import router from '@ohos.router';
import web_webview from '@ohos.web.webview';
import fileFs from '@ohos.file.fs';

@Entry
@Component
struct ReaderPage {
  @State bookName: string = '';
  @State epubPath: string = '';
  @State isLoading: boolean = true;
  @State progressText: string = '加载中...';

  private controller: web_webview.WebviewController = new web_webview.WebviewController();

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, string>;
    this.bookName = params['bookName'] || '';
    this.epubPath = params['epubPath'] || '';
    this.startLoad_();
  }

  private async startLoad_(): Promise<void> {
    // TODO: 解压 EPUB → 启动 EpubServer → WebView 加载
    this.progressText = '图文混排引擎开发中...';
  }

  build() {
    Stack() {
      Web({ src: '', controller: this.controller })
        .width('100%').height('100%')
        .javaScriptAccess(true)
        .domStorageAccess(true)

      if (this.isLoading) {
        Column() {
          LoadingProgress().width(40).height(40).color('#FF6600')
          Text(this.progressText).fontSize(14).margin({ top: 12 })
        }
        .width('100%').height('100%').backgroundColor('#FFF')
      }
    }
    .width('100%').height('100%')
  }
}
