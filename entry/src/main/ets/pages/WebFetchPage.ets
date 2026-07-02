/**
 * WebView 获取页面 — 用于加载 Cloudflare 保护的站点
 *
 * 通过路由参数接收 URL，使用系统 Web 组件加载，
 * 待页面加载完成后注入 JS 提取正文，再通过路由返回。
 */
import webview from '@ohos.web.webview';
import router from '@ohos.router';
import { UiUtil } from '../util/UiUtil';

@Entry
@Component
export struct WebFetchPage {
  private controller: webview.WebviewController = new webview.WebviewController();
  @State fetchUrl: string = '';
  @State statusText: string = '正在加载...';
  @State isLoaded: boolean = false;

  aboutToAppear(): void {
    const params = UiUtil.getParams(this.getUIContext()) as Record<string, string>;
    if (params) {
      this.fetchUrl = params['url'] || '';
    }
    if (!this.fetchUrl) {
      this.statusText = '无效的 URL';
    }
  }

  onPageEnd(): void {
    if (this.isLoaded) return;
    this.isLoaded = true;
    this.statusText = '页面已加载，提取内容...';
    console.info('[WebFetch] Page loaded:', this.fetchUrl);

    // 等待 Cloudflare 挑战完成（通常需要几秒）
    setTimeout((): void => {
      this.extractContent();
    }, 3000);
  }

  private extractContent(): void {
    // 提取页面正文
    this.controller.runJavaScript(
      'document.body ? document.body.innerText.substring(0, 50000) : ""'
    ).then((result: string): void => {
      console.info('[WebFetch] Content extracted, length:', result.length);
      // 返回结果
      UiUtil.back(this.getUIContext(), {
        url: 'pages/MainPage',
        params: {
          'webFetchResult': result,
          'webFetchUrl': this.fetchUrl
        }
      });
    }).catch((err: Error): void => {
      console.error('[WebFetch] JS execution failed:', err.message);
      UiUtil.back(this.getUIContext(), {
        url: 'pages/MainPage',
        params: {
          'webFetchResult': '',
          'webFetchUrl': this.fetchUrl,
          'webFetchError': err.message
        }
      });
    });
  }

  build() {
    Column() {
      // 加载状态
      Row() {
        Text(this.statusText).fontSize(14).fontColor('#888')
        if (!this.isLoaded) {
          LoadingProgress().width(20).height(20).margin({ left: 8 })
        }
      }.padding(16).width('100%')

      Text('URL: ' + this.fetchUrl).fontSize(11).fontColor('#AAA')
        .padding({ left: 16, right: 16 }).width('100%').maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      // 隐藏的 Web 组件（缩小到几乎不可见，但保持可渲染）
      Web({ src: this.fetchUrl, controller: this.controller })
        .width(1).height(1).position({ x: 0, y: 0 })
        .onPageEnd((): void => { this.onPageEnd(); })
        .onErrorReceive((_event) => {
          console.error('[WebFetch] Load error');
          this.statusText = '加载失败';
        })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .geolocationAccess(false)
        .mixedMode(MixedMode.All)

      // 显示实际内容的预览（可选）
      if (this.isLoaded) {
        Button('返回').margin(16).fontSize(14)
          .onClick((): void => {
            UiUtil.back(this.getUIContext(), { url: 'pages/MainPage' });
          })
      }
    }
    .width('100%').height('100%')
    .backgroundColor('#F5F5F5')
  }
}
