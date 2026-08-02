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
import { BookSource } from '../model/BookSource';
import { changedSourceFields, SourceRevisionService } from '../service/SourceRevisionService';
import { BookSourceChangeNotifier } from '../service/BookSourceChangeNotifier';
import pasteboard from '@ohos.pasteboard';

@CustomDialog
struct AiSourceSaveDialog {
  controller: CustomDialogController;
  @StorageLink('isDark') isDark: boolean = false;
  initialName: string = '';
  @State sourceName: string = '';
  onConfirm?: (sourceName: string) => void;

  aboutToAppear(): void {
    this.sourceName = this.initialName;
  }

  private confirm_(): void {
    const name = this.sourceName.trim();
    if (!name) {
      UiUtil.showToast(this.getUIContext(), {
        message: '书源名称不能为空', duration: 1500
      });
      return;
    }
    this.controller.close();
    this.onConfirm?.(name);
  }

  build() {
    Column() {
      Text('保存书源').fontSize(20).fontWeight(FontWeight.Bold)
        .fontColor(ThemeColors.onSurface(this.isDark)).width('100%')
      Text('Agent 已自动生成名称，你可以修改后再保存。').fontSize(13).lineHeight(19)
        .fontColor(ThemeColors.secondaryText(this.isDark)).width('100%')
        .margin({ top: 8, bottom: 16 })
      TextInput({ text: this.sourceName, placeholder: '请输入书源名称' })
        .width('100%').height(48).borderRadius(12).maxLength(100)
        .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
        .fontColor(ThemeColors.onSurface(this.isDark))
        .placeholderColor(ThemeColors.secondaryText(this.isDark))
        .onChange((value: string): void => { this.sourceName = value; })
        .onSubmit((): void => { this.confirm_(); })
      Row({ space: 12 }) {
        Button('取消').height(44).layoutWeight(1).borderRadius(22)
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
          .fontColor(ThemeColors.onSurface(this.isDark))
          .onClick((): void => { this.controller.close(); })
        Button('保存').height(44).layoutWeight(1).borderRadius(22)
          .backgroundColor(ThemeColors.primary(this.isDark))
          .fontColor(ThemeColors.onPrimary(this.isDark))
          .onClick((): void => { this.confirm_(); })
      }.width('100%').margin({ top: 20 })
    }.width('88%').constraintSize({ maxWidth: 520 })
      .padding(20).borderRadius(20)
      .backgroundColor(ThemeColors.surface(this.isDark))
  }
}

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
  @State repairLoadError: string = '';
  @State isSaving: boolean = false;

  private agent_: AiSourceAgent | null = null;
  private repairSource_: BookSource | null = null;
  private repairSourceUrl_: string = '';
  private challengeDlg?: CustomDialogController;
  private saveNameDlg?: CustomDialogController;
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
        // 保留完整过程供复制排障；界面 List 仍只渲染可见区域，不需要截断数据。
        this.logMessages = [...this.logMessages, message];
      },
      onRequestWebView: (url: string, reason: string): Promise<string> => {
        return this.openInteractiveWebView_(url, reason);
      },
    });

    const params = UiUtil.getParams(this.getUIContext()) as Record<string, string>;
    const repairUrl = params ? String(params['repairSourceUrl'] || '') : '';
    if (repairUrl) {
      this.repairMode = true;
      this.repairSourceUrl_ = repairUrl;
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
    this.repairLoadError = '';
    try {
      await AppDatabase.getInstance().waitForInit();
      this.repairSource_ = await new BookSourceTable(AppDatabase.getInstance().rdbStore)
        .getSourceByUrl(sourceUrl);
      if (!this.repairSource_) throw new Error('未找到需要修复的书源');
      this.homepageUrl = this.repairSource_.sourceUrl;
      this.repairSourceName = this.repairSource_.sourceName;
      console.info('[AiSourceGeneratePage] repair source loaded: ' + this.repairSourceName);
    } catch (e) {
      const message = (e as Error).message || String(e);
      this.repairSource_ = null;
      this.repairLoadError = message;
      console.error('[AiSourceGeneratePage] load repair source failed: ' + message);
      UiUtil.showToast(this.getUIContext(), {
        message: '加载待修复书源失败：' + message, duration: 2500
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
    // 修复模式：进入页面后书源可能尚未加载完成或加载失败，点击时自动重新加载。
    if (this.repairMode && !this.repairSource_ && this.repairSourceUrl_) {
      await this.loadRepairSource_(this.repairSourceUrl_);
    }
    if (this.repairMode && !this.repairSource_) {
      UiUtil.showToast(this.getUIContext(), {
        message: '待修复书源加载失败，请点击“重新加载书源”后重试', duration: 2200
      });
      return;
    }
    if (!this.homepageUrl.startsWith('http')) {
      UiUtil.showToast(this.getUIContext(), { message: '请输入有效的网址', duration: 1500 });
      return;
    }
    if (!this.agent_) return;
    this.isAnalyzing = true;
    this.logMessages = [];
    this.initializeSteps_();
    try {
      await this.agent_.init(UiUtil.getHostContext(this.getUIContext()));
      if (!this.agent_.isConfigured()) {
        UiUtil.showToast(this.getUIContext(), { message: '请先配置 AI API 和模型', duration: 1800 });
        return;
      }
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

  private promptSaveGeneratedSource_(): void {
    if (this.isSaving) return;
    const candidate = this.agent_?.getCompiledBookSource();
    if (!candidate) return;
    this.saveNameDlg = new CustomDialogController({
      builder: AiSourceSaveDialog({
        controller: this.saveNameDlg!,
        initialName: candidate.sourceName || '',
        onConfirm: (sourceName: string): void => {
          this.saveNameDlg = undefined;
          void this.saveGeneratedSource_(sourceName);
        }
      }),
      autoCancel: false,
      customStyle: true,
      alignment: DialogAlignment.Center,
    });
    this.saveNameDlg.open();
  }

  private async saveGeneratedSource_(sourceName: string): Promise<void> {
    if (this.isSaving) return;
    const candidate = this.agent_?.getCompiledBookSource();
    if (!candidate) return;
    const normalizedName = sourceName.trim();
    if (!normalizedName) {
      UiUtil.showToast(this.getUIContext(), {
        message: '书源名称不能为空', duration: 1500
      });
      return;
    }
    candidate.sourceName = normalizedName;

    this.isSaving = true;
    try {
      await AppDatabase.getInstance().waitForInit();
      const dao = new BookSourceTable(AppDatabase.getInstance().rdbStore);
      const existing = await dao.getSourceByUrl(candidate.sourceUrl);
      if (!existing) {
        const now = Date.now();
        candidate.id = 0;
        candidate.enabled = true;
        candidate.createTime = candidate.createTime || now;
        candidate.updateTime = now;
        candidate.id = await dao.insertSource(candidate);
        BookSourceChangeNotifier.notify();
        UiUtil.showToast(this.getUIContext(), {
          message: '书源已新增并启用', duration: 1800
        });
        UiUtil.back(this.getUIContext());
        return;
      }

      const changed = changedSourceFields(existing, candidate);
      const nameChanged = existing.sourceName !== candidate.sourceName;
      if (changed.length === 0 && !nameChanged) {
        UiUtil.showToast(this.getUIContext(), {
          message: '已有书源与生成结果一致，无需重复保存', duration: 2000
        });
        UiUtil.back(this.getUIContext());
        return;
      }

      const result = await UiUtil.showDialog(this.getUIContext(), {
        title: '更新已有书源？',
        message: '网址对应的书源“' + existing.sourceName + '”已经存在。\n\n' +
          '更新后名称为“' + candidate.sourceName + '”，同时替换 AI 识别出的规则；' +
          '原分组、启用状态和排序会保留，旧配置会保存为可回滚版本。',
        buttons: [
          { text: '取消', color: ThemeColors.secondaryText(this.isDark) },
          { text: '更新', color: ThemeColors.primary(this.isDark) },
        ]
      });
      if (result.index !== 1) return;

      const applied = await SourceRevisionService.applyRepair(
        existing, candidate, 'AI 生成书源：更新已有同网址书源', false);
      UiUtil.showToast(this.getUIContext(), {
        message: '书源已更新，修改 ' + applied.length + ' 个字段', duration: 2000
      });
      UiUtil.back(this.getUIContext());
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), {
        message: '保存失败：' + (e as Error).message, duration: 2400
      });
    } finally {
      this.isSaving = false;
    }
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
        if (changed.length === 0) {
          UiUtil.showToast(this.getUIContext(), {
            message: '当前书源配置已通过校验，无需更新', duration: 2000
          });
          UiUtil.back(this.getUIContext());
          return;
        }
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

  private compactDiagnosticValue_(value: string, limit: number = 600): string {
    if (!value || value.length <= limit) return value || '';
    return value.substring(0, limit) + '…（已省略 ' + (value.length - limit) + ' 字符）';
  }

  private buildProcessLog_(): string {
    const lines: string[] = [
      'AI 书源 Agent 过程日志',
      '模式：' + (this.repairMode ? '诊断修复' : '生成书源'),
      '网站：' + this.homepageUrl,
      '测试关键词：' + this.searchKeyword,
      '',
      '执行日志：',
    ];
    for (const message of this.logMessages) lines.push(message);

    lines.push('', '阶段结果：');
    for (const step of this.steps) {
      let stage = '[' + step.label + '] ' + step.status;
      if (step.summary) stage += ' - ' + step.summary;
      lines.push(stage);
      if (Object.keys(step.data).length > 0) {
        const compactData: Record<string, string> = {};
        Object.keys(step.data).forEach((key: string): void => {
          compactData[key] = this.compactDiagnosticValue_(step.data[key]);
        });
        lines.push(JSON.stringify(compactData, null, 2));
      }
    }

    const rules = this.agent_?.getCompiledSource() || {};
    const ruleKeys: string[] = [
      'ruleSearchUrl', 'ruleSearchList', 'ruleSearchName', 'ruleSearchAuthor',
      'ruleSearchNoteUrl', 'ruleExploreList', 'ruleExploreName', 'ruleExploreNoteUrl',
      'ruleBookInfoName', 'ruleBookInfoAuthor', 'ruleBookInfoCover',
      'ruleBookInfoIntroduce', 'ruleBookInfoTocUrl', 'ruleToc', 'ruleTocTitle',
      'ruleTocUrlItem', 'ruleTocNextTocUrl', 'ruleBookContent', 'ruleBookContentNext',
    ];
    lines.push('', '当前规则快照：');
    for (const key of ruleKeys) {
      if (rules[key]) lines.push(key + '=' + this.compactDiagnosticValue_(rules[key], 1000));
    }
    return lines.join('\n');
  }

  private async copyProcessLog_(): Promise<void> {
    if (this.logMessages.length === 0 && this.steps.length === 0) {
      UiUtil.showToast(this.getUIContext(), { message: '暂无可复制的过程日志', duration: 1500 });
      return;
    }
    try {
      const data = pasteboard.createData(
        pasteboard.MIMETYPE_TEXT_PLAIN, this.buildProcessLog_());
      await pasteboard.getSystemPasteboard().setData(data);
      UiUtil.showToast(this.getUIContext(), {
        message: '完整过程已复制到剪贴板', duration: 1500
      });
    } catch (e) {
      console.error('[AiSourceGeneratePage] copy process log failed: ' + String(e));
      UiUtil.showToast(this.getUIContext(), { message: '复制过程日志失败', duration: 1800 });
    }
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
            Text(this.invalidGroups.length > 0
              ? '待修复阶段：' + this.invalidGroups.join('、')
              : '待修复阶段：先校验现有规则，失败阶段自动修复').fontSize(12)
              .fontColor(ThemeColors.error(this.isDark)).width('100%').margin({ bottom: 16 })
          }
          if (this.repairMode && this.repairLoadError.length > 0) {
            Row() {
              Text('书源加载失败：' + this.repairLoadError).fontSize(12).lineHeight(18)
                .fontColor(ThemeColors.error(this.isDark)).layoutWeight(1)
              Button('重新加载书源').fontSize(12).height(32).borderRadius(16)
                .backgroundColor(ThemeColors.transparent())
                .fontColor(ThemeColors.primary(this.isDark))
                .onClick(() => {
                  if (this.repairSourceUrl_) void this.loadRepairSource_(this.repairSourceUrl_);
                })
            }.width('100%').margin({ bottom: 12 })
          } else if (this.repairMode && !this.repairSource_) {
            Text('正在加载待修复书源…').fontSize(12)
              .fontColor(ThemeColors.secondaryText(this.isDark)).width('100%').margin({ bottom: 12 })
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
            Column() {
              Row() {
                Text('整个过程').fontSize(12).fontWeight(FontWeight.Medium)
                  .fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1)
                Button('复制').fontSize(12).height(32).borderRadius(16)
                  .backgroundColor(ThemeColors.transparent())
                  .fontColor(ThemeColors.primary(this.isDark))
                  .accessibilityText('复制完整过程日志')
                  .onClick(() => { void this.copyProcessLog_(); })
              }.width('100%').height(34)
              List() {
                ForEach(this.logMessages, (message: string, index: number) => {
                  ListItem() {
                    Text(message).fontSize(10).lineHeight(15).fontFamily('monospace')
                      .fontColor(ThemeColors.secondaryText(this.isDark)).width('100%')
                  }
                }, (_message: string, index: number): string => index.toString())
              }.layoutWeight(1).width('100%')
            }.height(146).padding({ left: 8, right: 8, bottom: 8 })
              .margin({ left: 12, right: 12, top: 6 })
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
                  Button(this.isSaving ? '保存中…' : '保存书源').height(44).layoutWeight(1).borderRadius(22)
                    .backgroundColor(ThemeColors.primary(this.isDark))
                    .fontColor(ThemeColors.onPrimary(this.isDark))
                    .enabled(!this.isSaving)
                    .onClick(() => { this.promptSaveGeneratedSource_(); })
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
