/**
 * WebView 获取对话框 — 用于加载 Cloudflare 保护的站点
 *
 * 使用 CustomDialog + Web 组件，具备完整浏览器能力。
 * Cloudflare 挑战在此自动完成。
 */
import webview from '@ohos.web.webview';
import { ThemeColors } from '../theme/ThemeColors';

@CustomDialog
export struct WebViewFetchDialog {
  controller: CustomDialogController;
  @StorageLink('isDark') isDark: boolean = false;
  private webController: webview.WebviewController = new webview.WebviewController();

  @State fetchUrl: string = '';
  @State statusText: string = '正在加载页面...';
  @State pageLoadedCount: number = 0;
  @State extractedContent: string = '';

  onFetched?: (content: string, url: string) => void;

  onPageEnd(): void {
    this.pageLoadedCount++;
    this.statusText = '页面已加载 (' + this.pageLoadedCount + ' 次重定向)';

    // Cloudflare 通常需要 2-5 秒完成挑战
    // 等待 5 秒后尝试提取正文
    if (this.pageLoadedCount >= 2) {
      setTimeout((): void => {
        this.extractContent();
      }, 5000);
    }
  }

  private extractContent(): void {
    this.statusText = '正在提取内容...';
    this.webController.runJavaScript(
      'document.body ? document.body.innerText.substring(0, 100000) : ""'
    ).then((result: string): void => {
      console.info('[WebViewFetch] Extracted', result.length, 'chars');
      this.extractedContent = result;
      // 获取完整 HTML（不返回 Promise 链）
      this.webController.runJavaScript(
        'document.documentElement ? document.documentElement.outerHTML.substring(0, 200000) : ""'
      ).then((html: string): void => {
        console.info('[WebViewFetch] HTML length:', html.length);
        const content = html || this.extractedContent;
        this.controller.close();
        if (this.onFetched) {
          this.onFetched(content, this.fetchUrl);
        }
      }).catch((_err: Error): void => {
        // HTML 获取失败，用之前提取的文本
        this.controller.close();
        if (this.onFetched) {
          this.onFetched(this.extractedContent, this.fetchUrl);
        }
      });
    }).catch((_err: Error): void => {
      console.error('[WebViewFetch] Extraction error');
      // 尝试直接获取 HTML
      this.webController.runJavaScript(
        'document.documentElement ? document.documentElement.outerHTML.substring(0, 200000) : ""'
      ).then((html: string): void => {
        this.controller.close();
        if (this.onFetched) {
          this.onFetched(html, this.fetchUrl);
        }
      }).catch((): void => {
        this.controller.close();
        if (this.onFetched) {
          this.onFetched('', this.fetchUrl);
        }
      });
    });
  }

  build() {
    Column() {
      // 状态提示
      Text(this.statusText).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 20 })
      Text(this.fetchUrl).fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 4 })
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .padding({ left: 20, right: 20 })

      // Web 组件（缩小但保持可渲染）
      Web({ src: this.fetchUrl, controller: this.webController })
        .width('100%').height(1)
        .onPageEnd((): void => { this.onPageEnd(); })
        .onErrorReceive((_event) => {
          console.error('[WebViewFetch] Load error');
          this.statusText = '页面加载出错';
        })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .mixedMode(MixedMode.All)

      // 取消按钮
      Button($r('app.string.common_cancel')).margin({ top: 12, bottom: 20 }).fontSize(14)
        .onClick((): void => {
          this.controller.close();
          if (this.onFetched) {
            this.onFetched('', this.fetchUrl);
          }
        })
    }.width('100%').padding(16)
  }
}
