/**
 * AI 书源生成页面
 */
import { AiSourceAgent, AiStep, AiStepResult } from '../engine/ai/AiSourceAgent';
import { WebViewFetcher } from '../engine/web/WebViewFetcher';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';

@Entry
@Component
struct AiSourceGeneratePage {
  @StorageLink('isDark') isDark: boolean = false;
  @State homepageUrl: string = '';
  @State searchKeyword: string = '斗罗大陆';
  @State isAnalyzing: boolean = false;
  @State currentStep: number = -1;
  @State steps: AiStepResult[] = [];
  @State expandedStep: number = -1;
  @State showWebViewPrompt: boolean = false;
  @State webViewUrl_: string = '';
  @State logMessages: string[] = [];

  private agent_: AiSourceAgent | null = null;

  aboutToAppear(): void {
    this.agent_ = new AiSourceAgent({
      onStepUpdate: (r: AiStepResult) => {
        this.steps = [...this.steps.map(s => s.step === r.step ? r : s)];
        if (r.status === 'done' || r.status === 'error') {
          this.currentStep = r.step + 1;
        }
      },
      onLog: (msg: string) => {
        this.logMessages = [...this.logMessages, msg];
      },
      onRequestWebView: async (url: string): Promise<string> => {
        return new Promise<string>((resolve: (val: string) => void) => {
          this.webViewUrl_ = url;
          this.showWebViewPrompt = true;
          // 用户点击确认后，通过 WebViewFetcher 加载
          // 这里简化处理：直接通知用户手动使用 WebView
          setTimeout(() => {
            if (WebViewFetcher.isReady()) {
              WebViewFetcher.fetch(url, 30000).then((r) => {
                resolve(r.html || '');
              }).catch(() => resolve(''));
            } else {
              resolve('');
            }
          }, 500);
        });
      },
      onRequestLogin: async (): Promise<Record<string, string>> => {
        return {};
      },
    });
  }

  async startAnalyze(): Promise<void> {
    if (!this.homepageUrl.startsWith('http')) {
      UiUtil.showToast(this.getUIContext(), { message: '请输入有效的网址', duration: 1500 });
      return;
    }

    await this.agent_!.init(UiUtil.getHostContext(this.getUIContext()));
    if (!this.agent_!.isConfigured()) {
      UiUtil.showToast(this.getUIContext(), { message: '请先配置 AI API', duration: 1500 });
      return;
    }

    this.isAnalyzing = true;
    this.currentStep = 0;
    this.logMessages = [];
    // 预填充 6 个步骤，显示分析过程
    this.steps = [
      { step: AiStep.HOMEPAGE, label: '首页分析', status: 'pending', summary: '', data: {} },
      { step: AiStep.SEARCH, label: '搜索分析', status: 'pending', summary: '', data: {} },
      { step: AiStep.BOOK_INFO, label: '详情分析', status: 'pending', summary: '', data: {} },
      { step: AiStep.TOC, label: '目录分析', status: 'pending', summary: '', data: {} },
      { step: AiStep.CONTENT, label: '正文分析', status: 'pending', summary: '', data: {} },
      { step: AiStep.COMPILE, label: '汇总生成', status: 'pending', summary: '', data: {} },
    ];

    const results = await this.agent_!.analyze(this.homepageUrl, this.searchKeyword);
    this.steps = results;
    this.isAnalyzing = false;

    if (results[results.length - 1].status === 'done') {
      UiUtil.showToast(this.getUIContext(), { message: '分析完成', duration: 1500 });
    }
  }

  /** 跳转编辑页，预填数据 */
  navigateToEdit(): void {
    if (!this.agent_) return;
    const data = this.agent_.getCompiledSource();
    const params: Record<string, string> = {};
    params['aiGenerated'] = '1';
    for (const k of Object.keys(data)) {
      params[k] = data[k];
    }
    UiUtil.pushUrl(this.getUIContext(), { url: 'pages/BookSourceEditPage', params: params });
  }

  stepLabel(step: AiStep): string {
    const labels = ['首页分析', '搜索分析', '详情分析', '目录分析', '正文分析', '汇总'];
    return labels[step] || '';
  }

  statusIcon(status: string): string {
    switch (status) {
      case 'running': return '进行中';
      case 'done': return '完成';
      case 'error': return '失败';
      default: return '⬜';
    }
  }

  build() {
    Column() {
      // 顶栏
      Row() {
        Button($r('app.string.ui_8179643cdc')).fontSize(18).fontColor(ThemeColors.secondaryText(this.isDark)).width(40).height(40)
          .backgroundColor(ThemeColors.transparent()).accessibilityText($r('app.string.common_back')).onClick(() => { UiUtil.back(this.getUIContext()); })
        Text($r('app.string.ui_1ef00e7d2f')).fontColor(ThemeColors.onSurface(this.isDark)).fontSize(18).fontWeight(FontWeight.Bold).layoutWeight(1)
        Button($r('app.string.ui_d7d7ce790b')).fontSize(13)
          .backgroundColor(ThemeColors.transparent()).width(40).height(40)
          .onClick(() => { UiUtil.pushUrl(this.getUIContext(), { url: 'pages/AiConfigPage' }); })
      }.padding({ left: 12, right: 12, top: 44 }).width('100%')

      if (!this.isAnalyzing && this.steps.length === 0) {
        // 输入区
        Column() {
          Text($r('app.string.ui_735c63bd30'))
            .fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).alignSelf(ItemAlign.Start).margin({ bottom: 6 })
          TextInput({ text: this.homepageUrl, placeholder: $r('app.string.ui_740e739790') })
            .fontSize(14).width('100%').type(InputType.URL)
            .onChange((v: string) => { this.homepageUrl = v; })

          Text($r('app.string.ui_0f19d1f0d6'))
            .fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).alignSelf(ItemAlign.Start).margin({ top: 16, bottom: 6 })
          TextInput({ text: this.searchKeyword, placeholder: $r('app.string.ui_1ffe87e82f') })
            .fontSize(14).width('100%')
            .onChange((v: string) => { this.searchKeyword = v; })

          Button($r('app.string.ui_4769da8dd6')).fontSize(16).fontColor(ThemeColors.onPrimary(this.isDark)).backgroundColor(ThemeColors.primary(this.isDark))
            .width('100%').height(48).borderRadius(24).margin({ top: 28 })
            .onClick(() => { this.startAnalyze(); })

          Text($r('app.string.ui_c46ddaba9a'))
            .fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 12 })
        }
        .padding({ left: 16, right: 16 }).width('100%').layoutWeight(1)
      } else {
        // 进度区
        Column() {
          List() {
            ForEach(this.steps, (r: AiStepResult) => {
              ListItem() {
                Column() {
                  Row() {
                    Text(this.statusIcon(r.status)).fontColor(ThemeColors.onSurface(this.isDark)).fontSize(14)
                    Text(this.stepLabel(r.step)).fontSize(14)
                      .fontWeight(r.status === 'running' ? FontWeight.Bold : FontWeight.Normal)
                      .fontColor(ThemeColors.onBackground(this.isDark)).margin({ left: 8 })
                    Text(r.summary).fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1).margin({ left: 8 })
                    Button(this.expandedStep === r.step ? '▲' : '▼').fontSize(12)
                      .backgroundColor(ThemeColors.transparent()).width(40).height(40)
                      .onClick(() => { this.expandedStep = this.expandedStep === r.step ? -1 : r.step; })
                  }.width('100%')

                  if (this.expandedStep === r.step && (r.status === 'done' || r.status === 'error')) {
                    Text(r.status === 'error' ? '错误: ' + r.summary : JSON.stringify(r.data, null, 2))
                      .fontSize(10).fontColor(r.status === 'error' ? ThemeColors.error(this.isDark) : ThemeColors.secondaryText(this.isDark)).fontFamily('monospace')
                      .width('100%').padding(8).backgroundColor(ThemeColors.surface(this.isDark))
                      .borderRadius(6).margin({ top: 6 }).maxLines(20)
                  }
                }
                .padding({ top: 10, bottom: 10, left: 12, right: 12 })
              }
              .border({ width: { bottom: 1 }, color: ThemeColors.outlineVariant(this.isDark) })
            })
          }.layoutWeight(1)

          // 交互日志区
          if (this.logMessages.length > 0) {
            Column() {
              Text($r('app.string.ui_480e589572')).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
                .padding({ top: 6, bottom: 4, left: 4 }).alignSelf(ItemAlign.Start)
              List() {
                ForEach(this.logMessages, (msg: string) => {
                  ListItem() {
                    Text(msg).fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark))
                      .fontFamily('monospace').width('100%')
                      .padding({ top: 2, bottom: 2, left: 4, right: 4 })
                  }
                })
              }
              .height(80).width('100%')
              .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).borderRadius(6)
            }.padding({ left: 16, right: 16 }).width('100%')
          }

          if (!this.isAnalyzing && this.steps.length > 0) {
            if (this.steps.some(s => s.status === 'error')) {
              Button($r('app.string.ui_6e1dce9241')).fontSize(15).fontColor(ThemeColors.onPrimary(this.isDark)).backgroundColor(ThemeColors.warning(this.isDark))
                .width('100%').height(44).borderRadius(22)
                .margin({ top: 12, left: 16, right: 16 })
                .onClick(() => { this.startAnalyze(); })
            }
            Button($r('app.string.ui_fcf0c4061c')).fontSize(15).fontColor(ThemeColors.onPrimary(this.isDark)).backgroundColor(ThemeColors.success(this.isDark))
              .width('100%').height(44).borderRadius(22).margin({ top: 8, bottom: 12, left: 16, right: 16 })
              .onClick(() => { this.navigateToEdit(); })
          }
        }.width('100%').layoutWeight(1)
      }
    }
    .width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
  }
}
