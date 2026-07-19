import web_webview from '@ohos.web.webview';
import { ThemeColors } from '../theme/ThemeColors';

const AI_WEB_DESKTOP_MODE_KEY = 'ai_import_web_desktop_mode';
const DESKTOP_USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) ' +
  'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

// 在线导入默认请求桌面网页，并跨应用重启记住用户最后一次选择。
PersistentStorage.persistProp(AI_WEB_DESKTOP_MODE_KEY, true);

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
  @StorageLink(AI_WEB_DESKTOP_MODE_KEY) isDesktopMode_: boolean = true;
  @State private currentUrl: string = '';
  @State private isLoading: boolean = true;
  @State private errorText: string = '';
  @State private noticeText: string = '';
  @State private isExtracting: boolean = false;
  @State private canGoBack_: boolean = false;
  @State private canGoForward_: boolean = false;
  private webController_: web_webview.WebviewController = new web_webview.WebviewController();
  @State private controllerAttached_: boolean = false;
  private initialScriptExecuted_: boolean = false;
  private fallbackUsed_: boolean = false;
  private mobileUserAgent_: string = '';

  aboutToAppear(): void {
    this.currentUrl = this.initialUrl;
    this.initialScriptExecuted_ = false;
    this.fallbackUsed_ = false;
    this.noticeText = '';
    this.canGoBack_ = false;
    this.canGoForward_ = false;
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

  private handleNavigation_(action: number): void {
    switch (action) {
      case 0:
        this.goBack_();
        break;
      case 1:
        this.goForward_();
        break;
      case 2:
        this.refresh_();
        break;
      case 3:
        this.togglePageMode_();
        break;
      default:
        break;
    }
  }

  private refresh_(): void {
    if (!this.controllerAttached_) return;
    try {
      this.webController_.refresh();
    } catch (_e) {}
  }

  private applyPageMode_(reload: boolean): void {
    if (!this.controllerAttached_) return;
    try {
      if (!this.mobileUserAgent_) {
        this.mobileUserAgent_ = this.webController_.getCustomUserAgent();
      }
      const userAgent = this.isDesktopMode_ ? DESKTOP_USER_AGENT : this.mobileUserAgent_;
      this.webController_.setCustomUserAgent(userAgent);
      if (reload) this.webController_.refresh();
    } catch (e) {
      this.errorText = '切换网页模式失败：' + (e as Error).message;
    }
  }

  private togglePageMode_(): void {
    if (!this.controllerAttached_) return;
    this.isDesktopMode_ = !this.isDesktopMode_;
    this.noticeText = this.isDesktopMode_ ? '已切换为桌面网页' : '已切换为移动网页';
    this.applyPageMode_(true);
  }

  private updateNavigationState_(): void {
    if (!this.controllerAttached_) {
      this.canGoBack_ = false;
      this.canGoForward_ = false;
      return;
    }
    try {
      this.canGoBack_ = this.webController_.accessBackward();
      this.canGoForward_ = this.webController_.accessForward();
    } catch (_e) {
      this.canGoBack_ = false;
      this.canGoForward_ = false;
    }
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

  @Builder
  private NavigationButton_(icon: string, label: string, enabled: boolean, action: number) {
    Button() {
      Column({ space: 1 }) {
        Text(icon)
          .height(25)
          .fontSize(21)
          .lineHeight(25)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.onSurface(this.isDark))
        Text(label)
          .height(15)
          .fontSize(10)
          .lineHeight(15)
          .fontColor(ThemeColors.onSurface(this.isDark))
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width(56)
    .height(52)
    .padding(0)
    .stateEffect(enabled)
    .opacity(enabled ? 1 : 0.42)
    .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
    .borderRadius(14)
    .accessibilityText(label)
    // 不使用动态 .enabled()：CustomDialog 中 Builder 参数初始化为 false 后，
    // 部分系统版本不会恢复点击命中。事件内再查询 Controller 的实时状态。
    .onClick((): void => { this.handleNavigation_(action); })
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
          this.NavigationButton_('←', '后退', this.canGoBack_, 0)
          this.NavigationButton_('→', '前进', this.canGoForward_, 1)
          this.NavigationButton_('↻', '刷新', this.controllerAttached_, 2)
          this.NavigationButton_(this.isDesktopMode_ ? '▣' : '▯',
            this.isDesktopMode_ ? '桌面' : '移动', this.controllerAttached_, 3)

          Row() {
            Text(this.currentUrl)
              .layoutWeight(1)
              .fontSize(11)
              .maxLines(2)
              .lineHeight(15)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor(ThemeColors.secondaryText(this.isDark))
          }
          .layoutWeight(1)
          .height(44)
          .padding({ left: 10, right: 10 })
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
          .borderRadius(14)
        }
        .width('100%')
        .height(60)
      }
      .width('100%').height(116).padding({ left: 10, right: 10 })
      .backgroundColor(ThemeColors.surface(this.isDark))

      Stack() {
        Web({ src: this.initialUrl, controller: this.webController_ })
          .width('100%').height('100%')
          .javaScriptAccess(true).domStorageAccess(true).zoomAccess(true)
          .mixedMode(MixedMode.All)
          .onControllerAttached((): void => {
            this.controllerAttached_ = true;
            this.applyPageMode_(false);
            this.updateNavigationState_();
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
            this.updateNavigationState_();
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
    .width('96%').height('92%').constraintSize({ maxWidth: 1200, maxHeight: 900 })
    .backgroundColor(ThemeColors.background(this.isDark))
    .borderRadius(18).clip(true)
  }
}
