/** AI 全站书源生成与现有书源修复页面。 */
import { AiSourceAgent, AiStep, AiStepResult } from '../engine/ai/AiSourceAgent';
import { WebViewFetcher } from '../engine/web/WebViewFetcher';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';
import { WebViewEngine } from '../components/WebViewEngine';
import { CloudflareDialog } from '../components/reader/CloudflareDialog';
import { CaptchaDialog } from '../components/reader/CaptchaDialog';
import { JsExpressionEvaluator } from '../engine/source/JsExpressionEvaluator';
import { image } from '@kit.ImageKit';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { BookSource, serializeBookSource } from '../model/BookSource';
import { SourceRevisionService } from '../service/SourceRevisionService';

@Entry
@Component
struct AiSourceGeneratePage {
  @StorageLink('isDark') isDark: boolean = false;
  @State homepageUrl: string = '';
  @State searchKeyword: string = '斗罗大陆';
  @State isAnalyzing: boolean = false;
  @State steps: AiStepResult[] = [];
  @State expandedStep: number = -1;
  @State logMessages: string[] = [];
  @State repairMode: boolean = false;
  @State repairSourceName: string = '';
  @State invalidGroups: string[] = [];

  private agent_: AiSourceAgent | null = null;
  private repairSource_: BookSource | null = null;
  private challengeDlg?: CustomDialogController;
  private captchaHandler_: ((url: string, captchaImage?: image.PixelMap | null) => Promise<string>) | null = null;
  private interactiveFetcher_: ((url: string) => Promise<string>) | null = null;

  aboutToAppear(): void {
    this.registerCaptchaHandler_();
    if (!this.interactiveFetcher_) {
      this.interactiveFetcher_ = (url: string): Promise<string> =>
        this.openInteractiveWebView_(url, '页面需要登录或人工验证');
    }
    WebViewFetcher.interactiveFetcher = this.interactiveFetcher_;
    this.agent_ = new AiSourceAgent({
      onStepUpdate: (result: AiStepResult): void => {
        const next = this.steps.slice();
        const index = next.findIndex((item: AiStepResult): boolean => item.step === result.step);
        if (index >= 0) next[index] = result;
        else next.push(result);
        this.steps = next;
      },
      onLog: (message: string): void => {
        this.logMessages = [...this.logMessages.slice(-119), message];
      },
      onRequestWebView: (url: string, reason: string): Promise<string> => {
        return this.openInteractiveWebView_(url, reason);
      },
    });

    const params = UiUtil.getParams(this.getUIContext()) as Record<string, string>;
    const repairUrl = params ? String(params['repairSourceUrl'] || '') : '';
    if (repairUrl) {
      this.repairMode = true;
      this.searchKeyword = String(params['repairKeyword'] || '我');
      try {
        const groups = JSON.parse(String(params['invalidGroups'] || '[]')) as string[];
        this.invalidGroups = Array.isArray(groups) ? groups : [];
      } catch (_e) {
        this.invalidGroups = [];
      }
      void this.loadRepairSource_(repairUrl);
    }
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

  private openInteractiveWebView_(url: string, reason: string): Promise<string> {
    return new Promise<string>((resolve: (html: string) => void) => {
      this.logMessages = [...this.logMessages, '👤 ' + reason + '，请完成后点击“验证完成”'];
      WebViewFetcher.interactiveResolve = resolve;
      this.challengeDlg = new CustomDialogController({
        builder: CloudflareDialog({ controller: this.challengeDlg!, url: url }),
        autoCancel: false,
        customStyle: true,
        alignment: DialogAlignment.Center,
      });
      this.challengeDlg.open();
    });
  }

  private async loadRepairSource_(sourceUrl: string): Promise<void> {
    try {
      await AppDatabase.getInstance().waitForInit();
      this.repairSource_ = await new BookSourceTable(AppDatabase.getInstance().rdbStore)
        .getSourceByUrl(sourceUrl);
      if (!this.repairSource_) throw new Error('未找到需要修复的书源');
      this.homepageUrl = this.repairSource_.sourceUrl;
      this.repairSourceName = this.repairSource_.sourceName;
      if (this.invalidGroups.length === 0) {
        this.invalidGroups = ['搜索', '发现', '详情', '目录', '正文'];
      }
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), {
        message: '加载待修复书源失败：' + (e as Error).message, duration: 2000
      });
    }
  }

  private initializeSteps_(): void {
    this.steps = [
      { step: AiStep.HOMEPAGE, label: '首页与搜索入口', status: 'pending', summary: '', data: {} },
      { step: AiStep.SEARCH, label: '搜索规则', status: 'pending', summary: '', data: {} },
      { step: AiStep.DISCOVERY, label: '发现规则', status: 'pending', summary: '', data: {} },
      { step: AiStep.BOOK_INFO, label: '详情规则', status: 'pending', summary: '', data: {} },
      { step: AiStep.TOC, label: '目录规则', status: 'pending', summary: '', data: {} },
      { step: AiStep.CONTENT, label: '正文规则', status: 'pending', summary: '', data: {} },
      { step: AiStep.VALIDATE, label: '全链路校验', status: 'pending', summary: '', data: {} },
      { step: AiStep.COMPILE, label: '生成书源', status: 'pending', summary: '', data: {} },
    ];
  }

  private async startAnalyze(): Promise<void> {
    if (this.isAnalyzing) return;
    if (!this.homepageUrl.startsWith('http')) {
      UiUtil.showToast(this.getUIContext(), { message: '请输入有效的网址', duration: 1500 });
      return;
    }
    if (!this.agent_) return;
    await this.agent_.init(UiUtil.getHostContext(this.getUIContext()));
    if (!this.agent_.isConfigured()) {
      UiUtil.showToast(this.getUIContext(), { message: '请先配置 AI API 和模型', duration: 1800 });
      return;
    }

    this.isAnalyzing = true;
    this.logMessages = [];
    this.initializeSteps_();
    try {
      const results = this.repairMode && this.repairSource_
        ? await this.agent_.repair(this.repairSource_, this.searchKeyword, this.invalidGroups)
        : await this.agent_.analyze(this.homepageUrl, this.searchKeyword);
      this.steps = results.slice();
      const compiled = results[AiStep.COMPILE];
      UiUtil.showToast(this.getUIContext(), {
        message: compiled?.status === 'done' ? '全链路验证通过' : '生成未通过，请查看失败阶段',
        duration: 2000
      });
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), {
        message: 'Agent 执行失败：' + (e as Error).message, duration: 2200
      });
    } finally {
      this.isAnalyzing = false;
    }
  }

  private canUseResult_(): boolean {
    return !this.isAnalyzing && this.steps.length > AiStep.COMPILE &&
      this.steps[AiStep.COMPILE].status === 'done';
  }

  private navigateToEdit(): void {
    const source = this.agent_?.getCompiledBookSource();
    if (!source) return;
    UiUtil.pushUrl(this.getUIContext(), {
      url: 'pages/BookSourceEditPage',
      params: { sourceJson: serializeBookSource(source), aiGenerated: '1' }
    });
  }

  private applyRepair(): void {
    if (!this.agent_ || !this.repairSource_) return;
    const candidate = this.agent_.getCompiledBookSource();
    if (!candidate) return;
    const reason = 'AI 修复：' + this.invalidGroups.join('、');
    UiUtil.showDialog(this.getUIContext(), {
      title: '应用 AI 修复',
      message: '新规则已经通过完整链路校验。应用后会保留旧版本，可从规则调试页回滚。',
      buttons: [
        { text: '取消', color: ThemeColors.secondaryText(this.isDark) },
        { text: '应用', color: ThemeColors.primary(this.isDark) },
      ]
    }).then(async (result): Promise<void> => {
      if (result.index !== 1 || !this.repairSource_) return;
      try {
        const changed = await SourceRevisionService.applyRepair(this.repairSource_, candidate, reason);
        UiUtil.showToast(this.getUIContext(), {
          message: '修复已应用，修改 ' + changed.length + ' 个字段', duration: 2000
        });
        UiUtil.back(this.getUIContext());
      } catch (e) {
        UiUtil.showToast(this.getUIContext(), {
          message: '应用失败：' + (e as Error).message, duration: 2200
        });
      }
    });
  }

  private statusText_(status: string): string {
    if (status === 'running') return '进行中';
    if (status === 'done') return '✓';
    if (status === 'error') return '!';
    return '−';
  }

  build() {
    Column() {
      Row() {
        Button($r('app.string.ui_8179643cdc')).fontSize(18)
          .fontColor(ThemeColors.secondaryText(this.isDark)).width(40).height(40)
          .backgroundColor(ThemeColors.transparent())
          .accessibilityText($r('app.string.common_back'))
          .onClick(() => { UiUtil.back(this.getUIContext()); })
        Text(this.repairMode ? 'AI 修复书源' : 'AI 生成书源')
          .fontColor(ThemeColors.onSurface(this.isDark)).fontSize(18)
          .fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('AI 设置').fontSize(13).height(40).backgroundColor(ThemeColors.transparent())
          .fontColor(ThemeColors.primary(this.isDark))
          .onClick(() => { UiUtil.pushUrl(this.getUIContext(), { url: 'pages/AiConfigPage' }); })
      }.padding({ left: 12, right: 12 }).width('100%')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])

      if (!this.isAnalyzing && this.steps.length === 0) {
        Column() {
          if (this.repairMode) {
            Text('待修复：' + (this.repairSourceName || '加载中…')).fontSize(15)
              .fontWeight(FontWeight.Medium).fontColor(ThemeColors.onSurface(this.isDark))
              .width('100%').margin({ bottom: 6 })
            Text('失败阶段：' + this.invalidGroups.join('、')).fontSize(12)
              .fontColor(ThemeColors.error(this.isDark)).width('100%').margin({ bottom: 16 })
          }
          Text('网站首页或小说站 URL').fontSize(14)
            .fontColor(ThemeColors.secondaryText(this.isDark)).width('100%').margin({ bottom: 6 })
          TextInput({ text: this.homepageUrl, placeholder: 'https://example.com' })
            .fontSize(14).width('100%').type(InputType.URL)
            .enabled(!this.repairMode)
            .fontColor(ThemeColors.onSurface(this.isDark))
            .onChange((value: string): void => { this.homepageUrl = value; })
          Text('真实测试关键词').fontSize(14)
            .fontColor(ThemeColors.secondaryText(this.isDark)).width('100%')
            .margin({ top: 16, bottom: 6 })
          TextInput({ text: this.searchKeyword, placeholder: '输入站内确实存在的书名' })
            .fontSize(14).width('100%').fontColor(ThemeColors.onSurface(this.isDark))
            .onChange((value: string): void => { this.searchKeyword = value; })
          Button(this.repairMode ? '开始诊断并修复' : '开始生成').fontSize(16)
            .fontColor(ThemeColors.onPrimary(this.isDark))
            .backgroundColor(ThemeColors.primary(this.isDark))
            .width('100%').height(48).borderRadius(24).margin({ top: 28 })
            .enabled(!this.repairMode || this.repairSource_ !== null)
            .onClick(() => { void this.startAnalyze(); })
          Text('Agent 会真实执行搜索、详情、目录和正文规则；遇到登录或验证码会暂停等待操作。')
            .fontSize(11).lineHeight(17).fontColor(ThemeColors.secondaryText(this.isDark))
            .margin({ top: 12 }).width('100%')
        }.padding({ left: 16, right: 16, top: 8 }).width('100%').layoutWeight(1)
      } else {
        Column() {
          List({ space: 4 }) {
            ForEach(this.steps, (result: AiStepResult) => {
              ListItem() {
                Column() {
                  Row() {
                    Text(this.statusText_(result.status)).fontSize(14)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(result.status === 'error' ? ThemeColors.error(this.isDark) :
                        result.status === 'done' ? ThemeColors.primary(this.isDark) :
                          ThemeColors.secondaryText(this.isDark)).width(24)
                    Text(result.label).fontSize(14).fontWeight(FontWeight.Medium)
                      .fontColor(ThemeColors.onSurface(this.isDark)).width(110)
                    Text(result.summary).fontSize(12).maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
                      .fontColor(result.status === 'error' ? ThemeColors.error(this.isDark) :
                        ThemeColors.secondaryText(this.isDark))
                    Button(this.expandedStep === result.step ? '▲' : '▼').fontSize(11)
                      .width(40).height(40).backgroundColor(ThemeColors.transparent())
                      .fontColor(ThemeColors.primary(this.isDark))
                      .onClick(() => {
                        this.expandedStep = this.expandedStep === result.step ? -1 : result.step;
                      })
                  }.width('100%')
                  if (this.expandedStep === result.step && Object.keys(result.data).length > 0) {
                    Text(JSON.stringify(result.data, null, 2)).fontSize(10).fontFamily('monospace')
                      .fontColor(ThemeColors.secondaryText(this.isDark)).width('100%')
                      .padding(8).backgroundColor(ThemeColors.surfaceVariant(this.isDark))
                      .borderRadius(8).maxLines(20)
                  }
                }.padding({ left: 12, right: 8, top: 6, bottom: 6 })
                  .backgroundColor(ThemeColors.surface(this.isDark)).borderRadius(12)
              }
            }, (result: AiStepResult): string => result.step.toString())
          }.layoutWeight(1).padding({ left: 12, right: 12 })

          if (this.logMessages.length > 0) {
            List() {
              ForEach(this.logMessages, (message: string, index: number) => {
                ListItem() {
                  Text(message).fontSize(10).lineHeight(15).fontFamily('monospace')
                    .fontColor(ThemeColors.secondaryText(this.isDark)).width('100%')
                }
              }, (_message: string, index: number): string => index.toString())
            }.height(112).padding(8).margin({ left: 12, right: 12, top: 6 })
              .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).borderRadius(10)
          }

          if (!this.isAnalyzing) {
            Row({ space: 8 }) {
              Button('重新运行').height(44).layoutWeight(1).borderRadius(22)
                .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
                .fontColor(ThemeColors.onSurface(this.isDark))
                .onClick(() => { void this.startAnalyze(); })
              if (this.canUseResult_()) {
                if (this.repairMode) {
                  Button('应用修复').height(44).layoutWeight(1).borderRadius(22)
                    .backgroundColor(ThemeColors.primary(this.isDark))
                    .fontColor(ThemeColors.onPrimary(this.isDark))
                    .onClick(() => { this.applyRepair(); })
                } else {
                  Button('编辑规则').height(44).layoutWeight(1).borderRadius(22)
                    .backgroundColor(ThemeColors.primary(this.isDark))
                    .fontColor(ThemeColors.onPrimary(this.isDark))
                    .onClick(() => { this.navigateToEdit(); })
                }
              }
            }.padding({ left: 12, right: 12, top: 8, bottom: 12 }).width('100%')
          }
        }.width('100%').layoutWeight(1)
      }
      WebViewEngine().width(1).height(1).visibility(Visibility.Hidden)
    }.width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
  }
}
