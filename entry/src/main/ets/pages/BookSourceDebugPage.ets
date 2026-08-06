import { AppDatabase } from '../data/database/AppDatabase';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { BookSource } from '../model/BookSource';
import { CheckDetail, CheckResult, SourceChecker } from '../service/SourceChecker';
import { applyCheckResultToSource } from '../service/SourceCheckPersistence';
import { ThemeColors } from '../theme/ThemeColors';
import { UiUtil } from '../util/UiUtil';
import { SourceRevisionService } from '../service/SourceRevisionService';
import { WebViewEngine } from '../components/WebViewEngine';
import { JsExpressionEvaluator } from '../engine/source/JsExpressionEvaluator';
import { CaptchaDialog } from '../components/reader/CaptchaDialog';
import { CloudflareDialog } from '../components/reader/CloudflareDialog';
import { WebViewFetcher, WebViewInteractiveRequest } from '../engine/web/WebViewFetcher';
import { image } from '@kit.ImageKit';

@Entry
@Component
export struct BookSourceDebugPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State source: BookSource | null = null;
  @State keyword: string = '';
  @State details: CheckDetail[] = [];
  @State statusText: string = '输入关键词后运行，可依次检查搜索、详情、目录和正文。';
  @State isRunning: boolean = false;
  @State invalidGroups: string[] = [];
  private checker: SourceChecker | null = null;
  private captchaHandler_: ((url: string, captchaImage?: image.PixelMap | null) => Promise<string>) | null = null;
  private interactiveFetcher_: ((url: string, request?: WebViewInteractiveRequest) => Promise<string>) | null = null;
  private challengeDlg?: CustomDialogController;

  aboutToAppear(): void {
    this.registerCaptchaHandler_();
    if (!this.interactiveFetcher_) {
      this.interactiveFetcher_ = (url: string, request?: WebViewInteractiveRequest): Promise<string> =>
        this.openInteractiveWebView_(url, request?.body || '');
    }
    WebViewFetcher.interactiveFetcher = this.interactiveFetcher_;
    const params = UiUtil.getParams(this.getUIContext()) as Record<string, string>;
    this.loadSource(params ? String(params['sourceUrl'] || params['url'] || '') : '');
  }

  aboutToDisappear(): void {
    if (JsExpressionEvaluator.captchaHandler === this.captchaHandler_) {
      JsExpressionEvaluator.captchaHandler = null;
    }
    if (WebViewFetcher.interactiveFetcher === this.interactiveFetcher_) {
      WebViewFetcher.interactiveFetcher = null;
    }
    if (WebViewFetcher.interactiveResolve) {
      WebViewFetcher.interactiveResolve('');
      WebViewFetcher.interactiveResolve = null;
    }
  }

  private openInteractiveWebView_(url: string, requestBody: string = ''): Promise<string> {
    return new Promise<string>((resolve: (html: string) => void) => {
      this.statusText = '请在网页中完成登录或验证，然后点击“验证完成”。';
      WebViewFetcher.interactiveResolve = resolve;
      this.challengeDlg = new CustomDialogController({
        builder: CloudflareDialog({ controller: this.challengeDlg!, url: url,
          reason: WebViewFetcher.interactiveReason || '页面需要登录或人工验证', requestBody: requestBody }),
        autoCancel: false,
        customStyle: true,
        alignment: DialogAlignment.Center,
      });
      this.challengeDlg.open();
    });
  }

  private registerCaptchaHandler_(): void {
    if (!this.captchaHandler_) {
      this.captchaHandler_ = (captchaUrl: string,
        captchaImage?: image.PixelMap | null): Promise<string> => {
        return new Promise<string>((resolve: (code: string) => void) => {
          let dialog: CustomDialogController | null = null;
          dialog = new CustomDialogController({
            builder: CaptchaDialog({
              controller: dialog!, captchaUrl: captchaUrl,
              captchaImage: captchaImage ?? null, captchaResolve: resolve
            }),
            autoCancel: false,
            customStyle: true,
            alignment: DialogAlignment.Center,
          });
          dialog.open();
        });
      };
    }
    JsExpressionEvaluator.captchaHandler = this.captchaHandler_;
  }

  private async loadSource(sourceUrl: string): Promise<void> {
    try {
      await AppDatabase.getInstance().waitForInit();
      const dao = new BookSourceTable(AppDatabase.getInstance().rdbStore);
      this.source = await dao.getSourceByUrl(sourceUrl);
      if (this.source) {
        this.keyword = this.source.ruleSearchCheckKeyWord || '我';
      } else {
        this.statusText = '没有找到对应书源，请返回管理页重试。';
      }
    } catch (e) {
      this.statusText = '加载书源失败：' + String(e);
    }
  }

  private async runDebug(): Promise<void> {
    if (!this.source || this.isRunning) return;
    if (!this.keyword.trim()) {
      UiUtil.showToast(this.getUIContext(), { message: '请输入测试关键词', duration: 1500 });
      return;
    }
    this.isRunning = true;
    this.details = [];
    this.statusText = '正在运行规则链路…';
    this.checker = new SourceChecker({
      keyword: this.keyword.trim(), timeout: 30000,
      checkSearch: true, checkDiscovery: false, checkInfo: true,
      checkCategory: true, checkContent: true, concurrency: 1
    });
    try {
      const result: CheckResult = await this.checker.checkSource(this.source);
      this.details = result.details.slice();
      this.invalidGroups = result.invalidGroups.slice();
      this.statusText = result.status === 'success' ? '全部规则检查通过' : '规则检查失败';
      const dao = new BookSourceTable(AppDatabase.getInstance().rdbStore);
      applyCheckResultToSource(this.source, result, 30000);
      await dao.updateSource(this.source);
    } catch (e) {
      this.statusText = '调试失败：' + String(e);
    } finally {
      this.isRunning = false;
      this.checker = null;
    }
  }

  private cancelDebug(): void {
    this.checker?.cancel();
    this.statusText = '正在停止并取消当前网络请求。';
  }

  private openAiRepair(): void {
    if (!this.source || this.invalidGroups.length === 0) return;
    UiUtil.pushUrl(this.getUIContext(), {
      url: 'pages/AiSourceGeneratePage',
      params: {
        repairSourceUrl: this.source.sourceUrl,
        repairKeyword: this.keyword.trim() || '我',
        invalidGroups: JSON.stringify(this.invalidGroups),
      }
    });
  }

  private rollbackLatestRepair(): void {
    if (!this.source) return;
    UiUtil.showDialog(this.getUIContext(), {
      title: '回滚 AI 修复',
      message: '恢复到最近一次 AI 修复前的书源规则？',
      buttons: [
        { text: '取消', color: ThemeColors.secondaryText(this.isDark) },
        { text: '回滚', color: ThemeColors.error(this.isDark) },
      ]
    }).then(async (result): Promise<void> => {
      if (result.index !== 1 || !this.source) return;
      try {
        const restored = await SourceRevisionService.rollbackLatest(this.source.sourceUrl);
        UiUtil.showToast(this.getUIContext(), {
          message: restored ? '已回滚最近一次 AI 修复' : '没有可回滚的 AI 修复版本',
          duration: 1800
        });
        if (restored) await this.loadSource(this.source.sourceUrl);
      } catch (e) {
        UiUtil.showToast(this.getUIContext(), {
          message: '回滚失败：' + (e as Error).message, duration: 2000
        });
      }
    });
  }

  build() {
    Column() {
      Row() {
        Button($r('app.string.ui_0dccf90917')).fontSize(26).width(40).height(40).backgroundColor(ThemeColors.transparent())
          .fontColor(ThemeColors.onBackground(this.isDark))
          .onClick(() => { UiUtil.back(this.getUIContext()); })
        Column() {
          Text($r('app.string.ui_51f7688b7a')).fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor(ThemeColors.onBackground(this.isDark)).width('100%')
          Text(this.source ? this.source.sourceName : '加载中…').fontSize(12)
            .fontColor(ThemeColors.secondaryText(this.isDark)).width('100%').maxLines(1)
        }.layoutWeight(1)
      }.height(64).padding({ left: 8, right: 16 }).width('100%')

      Column() {
        Text($r('app.string.ui_284abffdc3')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).width('100%')
        Row() {
          TextInput({ text: this.keyword, placeholder: $r('app.string.ui_57292d42ea') })
            .height(48).layoutWeight(1).borderRadius(12)
            .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
            .fontColor(ThemeColors.onSurface(this.isDark))
            .placeholderColor(ThemeColors.secondaryText(this.isDark))
            .onChange((value: string) => { this.keyword = value; })
          Button(this.isRunning ? '停止' : '运行').height(48).margin({ left: 8 })
            .borderRadius(24).padding({ left: 20, right: 20 })
            .backgroundColor(this.isRunning ? ThemeColors.error(this.isDark) : ThemeColors.primary(this.isDark))
            .fontColor(ThemeColors.onPrimary(this.isDark))
            .onClick(() => { if (this.isRunning) this.cancelDebug(); else this.runDebug(); })
        }.width('100%').margin({ top: 6 })
        Text(this.statusText).fontSize(13).lineHeight(20)
          .fontColor(ThemeColors.secondaryText(this.isDark)).width('100%').margin({ top: 12 })
        if (!this.isRunning && this.source) {
          Row({ space: 8 }) {
            if (this.invalidGroups.length > 0) {
              Button('AI 诊断修复').height(42).layoutWeight(1).borderRadius(21)
                .backgroundColor(ThemeColors.primary(this.isDark))
                .fontColor(ThemeColors.onPrimary(this.isDark))
                .onClick(() => { this.openAiRepair(); })
            }
            Button('回滚最近修复').height(42).layoutWeight(1).borderRadius(21)
              .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
              .fontColor(ThemeColors.onSurface(this.isDark))
              .onClick(() => { this.rollbackLatestRepair(); })
          }.width('100%').margin({ top: 10 })
        }
      }.margin({ left: 16, right: 16, top: 4, bottom: 12 }).padding(16).borderRadius(16)
        .backgroundColor(ThemeColors.surface(this.isDark))

      if (this.isRunning) {
        Progress({ value: 20, total: 100, type: ProgressType.Linear }).width('100%')
          .color(ThemeColors.primary(this.isDark)).style({ strokeWidth: 3 })
      }

      if (!this.isRunning && this.details.length === 0) {
        Column() {
          Text($r('app.string.ui_45b3b04258')).fontSize(18).fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.onBackground(this.isDark))
          Text($r('app.string.ui_7d46687776')).fontSize(14).margin({ top: 10 })
            .fontColor(ThemeColors.secondaryText(this.isDark))
        }.layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.details, (detail: CheckDetail) => {
            ListItem() {
              Row() {
                Text(detail.passed ? '✓' : '!').fontSize(18).fontWeight(FontWeight.Bold)
                  .fontColor(detail.passed ? ThemeColors.primary(this.isDark) : ThemeColors.error(this.isDark))
                  .width(32).height(32).textAlign(TextAlign.Center)
                Column() {
                  Row() {
                    Text(detail.name).fontSize(16).fontWeight(FontWeight.Medium)
                      .fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1)
                    if (detail.duration > 0) {
                      Text(detail.duration + ' ms').fontSize(12)
                        .fontColor(ThemeColors.secondaryText(this.isDark))
                    }
                  }.width('100%')
                  Text(detail.message).fontSize(13).lineHeight(19).margin({ top: 4 })
                    .fontColor(detail.passed ? ThemeColors.secondaryText(this.isDark) : ThemeColors.error(this.isDark))
                    .width('100%')
                }.layoutWeight(1).margin({ left: 8 })
              }.padding(16).width('100%').borderRadius(16)
                .backgroundColor(ThemeColors.surface(this.isDark))
            }
          }, (detail: CheckDetail): string => detail.name)
        }.layoutWeight(1).padding({ left: 16, right: 16, bottom: 16 })
      }
      WebViewEngine().width(1).height(1).visibility(Visibility.Hidden)
    }.width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
  }
}
