import web_webview from '@ohos.web.webview';
import { ThemeColors } from '../theme/ThemeColors';

export interface AiImportPreviewResult {
  url: string;
  html: string;
}

@Component
export struct AiImportPreviewDialog {
  initialUrl: string = '';
  titleText: string = '确认导入网页';
  confirmText: string = '确认导入';
  helperText: string = '';
  /** 搜索浏览器需要先由上层校验当前页，通过后再关闭。 */
  dismissBeforeConfirm: boolean = true;
  /** 页面首次加载完成后执行一次，用于给搜索导航页自动填入关键词。 */
  initialScript: string = '';
  /** 搜索站主页无法访问时使用的透明降级地址。 */
  fallbackUrl: string = '';
  fallbackMessage: string = '';
  onConfirm?: (result: AiImportPreviewResult) => void;
  onCancel?: () => void;

  @StorageLink('isDark') isDark: boolean = false;
  @State private currentUrl: string = '';
  @State private isLoading: boolean = true;
  @State private errorText: string = '';
  @State private noticeText: string = '';
  @State private isExtracting: boolean = false;
  private webController_: web_webview.WebviewController = new web_webview.WebviewController();
  @State private controllerAttached_: boolean = false;
  private initialScriptExecuted_: boolean = false;
  private fallbackUsed_: boolean = false;

  aboutToAppear(): void {
    this.currentUrl = this.initialUrl;
    this.initialScriptExecuted_ = false;
    this.fallbackUsed_ = false;
    this.noticeText = '';
  }

  aboutToDisappear(): void {
    this.controllerAttached_ = false;
  }

  private decodeJsString_(value: string): string {
    if (!value) return '';
    try {
      const decoded = JSON.parse(value) as string;
      return decoded || value;
    } catch (_e) {
      return value;
    }
  }

  private async confirm_(): Promise<void> {
    if (!this.controllerAttached_ || this.isExtracting) return;
    this.isExtracting = true;
    try {
      const raw = await this.webController_.runJavaScript('document.documentElement.outerHTML');
      const html = this.decodeJsString_(raw);
      if (!html || html.length < 100) {
        this.errorText = '未能读取页面内容，请等待加载完成';
        return;
      }
      const result: AiImportPreviewResult = { url: this.currentUrl || this.initialUrl, html: html };
      if (this.dismissBeforeConfirm) this.onCancel?.();
      this.onConfirm?.(result);
    } catch (e) {
      this.errorText = '读取页面失败：' + (e as Error).message;
    } finally {
      this.isExtracting = false;
    }
  }

  private goBack_(): void {
    if (!this.controllerAttached_) return;
    try {
      if (this.webController_.accessBackward()) this.webController_.backward();
    } catch (_e) {}
  }

  private goForward_(): void {
    if (!this.controllerAttached_) return;
    try {
      if (this.webController_.accessForward()) this.webController_.forward();
    } catch (_e) {}
  }

  private refresh_(): void {
    if (!this.controllerAttached_) return;
    try {
      this.webController_.refresh();
    } catch (_e) {}
  }

  private runInitialScript_(): void {
    if (!this.controllerAttached_ || this.initialScriptExecuted_ || !this.initialScript) return;
    this.initialScriptExecuted_ = true;
    try {
      this.webController_.runJavaScript(this.initialScript).catch((): void => {});
    } catch (_e) {}
  }

  private scheduleInitialScript_(): void {
    if (!this.initialScript || this.initialScriptExecuted_) return;
    setTimeout((): void => { this.runInitialScript_(); }, 1000);
  }

  build() {
    Column() {
      Column() {
        Row({ space: 8 }) {
          Button('取消')
            .height(44)
            .fontSize(14)
            .fontColor(ThemeColors.onSurface(this.isDark))
            .backgroundColor(Color.Transparent)
            .onClick((): void => { this.onCancel?.(); })

          Text(this.titleText)
            .layoutWeight(1).fontSize(16).fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor(ThemeColors.onSurface(this.isDark))

          Button(this.isExtracting ? '读取中' : this.confirmText)
            .height(40)
            .padding({ left: 14, right: 14 })
            .fontSize(14)
            // 页面可能因广告、统计脚本等子资源长时间加载或失败，
            // 只要 WebView 已关联就允许用户读取当前可见页面。
            .enabled(this.controllerAttached_ && !this.isExtracting)
            .fontColor(ThemeColors.onPrimary(this.isDark))
            .backgroundColor(ThemeColors.primary(this.isDark))
            .borderRadius(20)
            .onClick((): void => { void this.confirm_(); })
        }
        .width('100%')
        .height(56)

        Row({ space: 8 }) {
          Button('‹')
            .width(36).height(32).fontSize(22)
            .fontColor(ThemeColors.onSurface(this.isDark))
            .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
            .borderRadius(16)
            .onClick((): void => { this.goBack_(); })

          Button('›')
            .width(36).height(32).fontSize(22)
            .fontColor(ThemeColors.onSurface(this.isDark))
            .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
            .borderRadius(16)
            .onClick((): void => { this.goForward_(); })

          Button('↻')
            .width(36).height(32).fontSize(17)
            .fontColor(ThemeColors.onSurface(this.isDark))
            .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
            .borderRadius(16)
            .onClick((): void => { this.refresh_(); })

          Text(this.currentUrl)
            .layoutWeight(1).fontSize(11).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontColor(ThemeColors.secondaryText(this.isDark))
        }
        .width('100%')
        .height(40)
      }
      .width('100%').height(96).padding({ left: 6, right: 10 })
      .backgroundColor(ThemeColors.surface(this.isDark))

      Stack() {
        Web({ src: this.initialUrl, controller: this.webController_ })
          .width('100%').height('100%')
          .javaScriptAccess(true).domStorageAccess(true).zoomAccess(true)
          .mixedMode(MixedMode.All)
          .onControllerAttached((): void => {
            this.controllerAttached_ = true;
            this.scheduleInitialScript_();
          })
          .onPageBegin((): void => {
            this.isLoading = true;
            this.errorText = '';
            this.scheduleInitialScript_();
          })
          .onPageEnd((event): void => {
            this.currentUrl = event.url || this.currentUrl;
            this.isLoading = false;
            this.runInitialScript_();
          })
          .onErrorReceive((event): void => {
            if (event?.request?.isMainFrame() && this.fallbackUrl && !this.fallbackUsed_) {
              this.fallbackUsed_ = true;
              this.noticeText = this.fallbackMessage || '原搜索站无法访问，已切换备用搜索。';
              this.errorText = '';
              try {
                this.webController_.loadUrl(this.fallbackUrl);
              } catch (e) {
                this.errorText = '打开备用搜索失败：' + (e as Error).message;
              }
              return;
            }
            this.isLoading = false;
            this.errorText = '页面加载失败，请检查网址或网络';
          })
        if (this.isLoading) {
          Column({ space: 10 }) {
            LoadingProgress().width(32).height(32).color(ThemeColors.primary(this.isDark))
            Text('正在加载网页…').fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
          }
          .padding(18).backgroundColor(ThemeColors.surface(this.isDark)).borderRadius(14)
        }
      }
      .width('100%').layoutWeight(1)

      if (this.helperText) {
        Text(this.helperText)
          .width('100%')
          .fontSize(12)
          .lineHeight(18)
          .fontColor(ThemeColors.secondaryText(this.isDark))
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor(ThemeColors.surface(this.isDark))
      }

      if (this.noticeText) {
        Text(this.noticeText)
          .width('100%')
          .fontSize(12)
          .lineHeight(18)
          .fontColor(ThemeColors.primary(this.isDark))
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
      }

      if (this.errorText) {
        Text(this.errorText).width('100%').fontSize(12)
          .fontColor(ThemeColors.error(this.isDark)).padding(10)
          .backgroundColor(ThemeColors.surface(this.isDark))
      }
    }
    .width('96%').height('92%')
    .backgroundColor(ThemeColors.background(this.isDark))
    .borderRadius(18).clip(true)
  }
}
