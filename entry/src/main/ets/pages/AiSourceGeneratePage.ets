/** AI 全站书源生成与现有书源修复页面。 */
import { AiRepairScope, AiSourceAgent, AiStep, AiStepResult } from '../engine/ai/AiSourceAgent';
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
import { SettingsStore } from '../data/preferences/SettingsStore';
import { AiImportPreviewDialog, AiImportPreviewResult } from '../components/AiImportPreviewDialog';
import {
  ONLINE_SEARCH_ENGINES, OnlineSearchEngine, buildOnlineSearchUrl, getOnlineSearchEngineName,
  isOnlineSearchResultPage, normalizeOnlineSearchEngine
} from '../service/OnlineSearchEngineService';
import { AiSourceDiscoveryService } from '../service/AiSourceDiscoveryService';
import { AiSourceBatchGenerateService } from '../service/AiSourceBatchGenerateService';
import { AiGeneratedSourceSaveService } from '../service/AiGeneratedSourceSaveService';
import {
  AiSourceBatchSummary, AiSourceCandidate, createAiSourceBatchSummary
} from '../model/AiSourceDiscovery';

const AI_DISCOVERY_SEARCH_OPTIONS: SelectOption[] = ONLINE_SEARCH_ENGINES.map(
  (item: OnlineSearchEngine): SelectOption => ({ value: item.name }));

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
  /** 修复链路范围：全部=搜索+发现；search=仅搜索链路；discovery=仅发现链路。 */
  @State repairScope: AiRepairScope = 'all';
  @State repairLoadError: string = '';
  @State isSaving: boolean = false;
  @State createTab_: number = 0;
  @State discoveryKeyword_: string = '';
  @State discoveryEngine_: string = 'bing';
  @State showDiscoveryBrowser_: boolean = false;
  @State discoveryBrowserUrl_: string = '';
  @State discoveryCandidates_: AiSourceCandidate[] = [];
  @State discoveryPhase_: string = 'idle';
  @State discoveryError_: string = '';
  @State allowUpdateExisting_: boolean = false;
  @State batchRunning_: boolean = false;
  @State batchStopRequested_: boolean = false;
  @State batchSummary_: AiSourceBatchSummary = createAiSourceBatchSummary();

  private agent_: AiSourceAgent | null = null;
  private batchService_: AiSourceBatchGenerateService | null = null;
  private pageActive_: boolean = false;
  private repairSource_: BookSource | null = null;
  private repairSourceUrl_: string = '';
  private challengeDlg?: CustomDialogController;
  private saveNameDlg?: CustomDialogController;
  private captchaHandler_: ((url: string, captchaImage?: image.PixelMap | null) => Promise<string>) | null = null;
  private interactiveFetcher_: ((url: string) => Promise<string>) | null = null;

  aboutToAppear(): void {
    this.pageActive_ = true;
    void this.loadDiscoveryPrefs_();
    this.registerCaptchaHandler_();
    if (!this.interactiveFetcher_) {
      this.interactiveFetcher_ = (url: string): Promise<string> =>
        this.openInteractiveWebView_(url,
          WebViewFetcher.interactiveReason || '页面需要登录或人工验证');
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
    this.pageActive_ = false;
    if (this.batchRunning_) this.batchService_?.requestStop();
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

  private async loadDiscoveryPrefs_(): Promise<void> {
    try {
      const settings = SettingsStore.getInstance();
      await settings.init(UiUtil.getHostContext(this.getUIContext()));
      this.discoveryEngine_ = normalizeOnlineSearchEngine(
        await settings.get<string>('online_search_engine', 'bing'));
      this.createTab_ = await settings.get<number>('ai_source_create_tab', 0) === 1 ? 1 : 0;
    } catch (_e) {
      this.discoveryEngine_ = 'bing';
      this.createTab_ = 0;
    }
    if (this.repairMode) this.createTab_ = 0;
  }

  private async persistDiscoveryPrefs_(): Promise<void> {
    try {
      const settings = SettingsStore.getInstance();
      await settings.init(UiUtil.getHostContext(this.getUIContext()));
      await settings.put('online_search_engine', this.discoveryEngine_);
      await settings.put('ai_source_create_tab', this.createTab_);
    } catch (_e) { /* 偏好写入失败不影响本次任务 */ }
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
        builder: CloudflareDialog({ controller: this.challengeDlg!, url: url, reason: reason }),
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
        ? await this.agent_.repair(this.repairSource_, this.searchKeyword, this.invalidGroups,
          this.repairScope)
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

  private isAnyTaskRunning_(): boolean {
    return this.isAnalyzing || this.batchRunning_ || this.discoveryPhase_ === 'extracting';
  }

  private switchCreateTab_(tab: number): void {
    if (this.repairMode || this.isAnyTaskRunning_() || tab === this.createTab_) return;
    this.createTab_ = tab;
    this.discoveryError_ = '';
    void this.persistDiscoveryPrefs_();
  }

  private normalizedDiscoveryKeyword_(): string {
    return this.discoveryKeyword_.replace(/[\s\u3000,:：;；。！？!?]+$/g, '').trim();
  }

  private async openDiscoveryBrowser_(): Promise<void> {
    const keyword = this.normalizedDiscoveryKeyword_().trim();
    if (!keyword) {
      UiUtil.showToast(this.getUIContext(), { message: '请输入书名', duration: 1500 });
      return;
    }
    if (this.isAnyTaskRunning_()) return;
    this.discoveryKeyword_ = keyword;
    this.discoveryBrowserUrl_ = buildOnlineSearchUrl(this.discoveryEngine_, keyword);
    this.discoveryPhase_ = 'browser';
    this.discoveryError_ = '';
    this.showDiscoveryBrowser_ = true;
    await this.persistDiscoveryPrefs_();
  }

  private closeDiscoveryBrowser_(): void {
    this.showDiscoveryBrowser_ = false;
    this.discoveryPhase_ = this.discoveryCandidates_.length > 0 ? 'candidates' : 'idle';
  }

  private async handleDiscoveryPreview_(result: AiImportPreviewResult): Promise<void> {
    if (!isOnlineSearchResultPage(result.url)) {
      this.discoveryError_ = '请返回搜索结果页后再提取网站';
      return;
    }
    if (!result.links || result.links.length === 0) {
      this.discoveryError_ = '当前搜索结果页没有可用链接，请刷新后重试';
      return;
    }
    this.discoveryPhase_ = 'extracting';
    this.discoveryError_ = '';
    try {
      await AppDatabase.getInstance().waitForInit();
      const sources = await new BookSourceTable(AppDatabase.getInstance().rdbStore).getAllSources();
      const candidates = AiSourceDiscoveryService.buildCandidates(
        this.discoveryEngine_, this.normalizedDiscoveryKeyword_(), result.url, result.links, sources);
      if (candidates.length === 0) {
        this.discoveryError_ = '未发现可用公网网站，请换一个搜索引擎或搜索词';
        this.discoveryPhase_ = 'error';
        return;
      }
      this.discoveryCandidates_ = candidates;
      this.discoveryPhase_ = 'candidates';
      this.showDiscoveryBrowser_ = false;
    } catch (e) {
      this.discoveryError_ = '提取网站失败：' + ((e as Error).message || String(e));
      this.discoveryPhase_ = 'error';
    }
  }

  private selectionCount_(): number {
    return this.discoveryCandidates_.filter((item: AiSourceCandidate): boolean => item.selected).length;
  }

  private cloneCandidate_(item: AiSourceCandidate, selected?: boolean,
    homepageUrl?: string, safe?: boolean, duplicate?: 'none' | 'exact' | 'same_host'): AiSourceCandidate {
    return {
      id: item.id,
      engineId: item.engineId,
      keyword: item.keyword,
      resultPageUrl: item.resultPageUrl,
      displayName: item.displayName,
      landingUrl: item.landingUrl,
      homepageUrl: homepageUrl === undefined ? item.homepageUrl : homepageUrl,
      normalizedSiteKey: item.normalizedSiteKey,
      host: item.host,
      hitCount: item.hitCount,
      samples: item.samples.slice(),
      confidence: item.confidence,
      selected: selected === undefined ? item.selected : selected,
      safe: safe === undefined ? item.safe : safe,
      duplicate: duplicate === undefined ? item.duplicate : duplicate,
      existingSourceId: item.existingSourceId,
      existingSourceName: item.existingSourceName,
      status: item.status,
      currentStep: item.currentStep,
      stepSummary: item.stepSummary,
      logs: item.logs.slice(),
      savedSourceId: item.savedSourceId,
      error: item.error,
    };
  }

  private toggleCandidate_(id: string, selected: boolean): void {
    if (selected && this.selectionCount_() >= 10) {
      UiUtil.showToast(this.getUIContext(), { message: '一次最多选择 10 个网站', duration: 1800 });
      return;
    }
    this.discoveryCandidates_ = this.discoveryCandidates_.map((item: AiSourceCandidate): AiSourceCandidate =>
      item.id === id ? this.cloneCandidate_(item, selected) : item);
  }

  private updateCandidateHomepage_(id: string, value: string): void {
    const homepage = value.trim();
    const normalized = AiSourceDiscoveryService.normalizeHomepageUrl(homepage);
    const safe = !!normalized && AiSourceDiscoveryService.isCandidateUrl(homepage);
    this.discoveryCandidates_ = this.discoveryCandidates_.map((item: AiSourceCandidate): AiSourceCandidate => {
      if (item.id !== id) return item;
      const next = this.cloneCandidate_(item, safe ? item.selected : false, homepage, safe,
        safe ? item.duplicate : 'none');
      next.normalizedSiteKey = AiSourceDiscoveryService.normalizedSiteKey(homepage);
      return next;
    });
  }

  private selectAllNewCandidates_(): void {
    let count = 0;
    this.discoveryCandidates_ = this.discoveryCandidates_.map((item: AiSourceCandidate): AiSourceCandidate => {
      if (!item.safe || item.duplicate !== 'none') return this.cloneCandidate_(item, false);
      if (count >= 10) return this.cloneCandidate_(item, false);
      count++;
      return this.cloneCandidate_(item, true);
    });
    if (this.discoveryCandidates_.filter((item: AiSourceCandidate): boolean =>
      item.safe && item.duplicate === 'none').length > 10) {
      UiUtil.showToast(this.getUIContext(), { message: '已选择前 10 个新网站', duration: 1600 });
    }
  }

  private clearCandidateSelection_(): void {
    this.discoveryCandidates_ = this.discoveryCandidates_.map((item: AiSourceCandidate): AiSourceCandidate =>
      this.cloneCandidate_(item, false));
  }

  private async startBatchGenerate_(): Promise<void> {
    if (this.batchRunning_) return;
    const selected = this.selectionCount_();
    if (selected <= 0) {
      UiUtil.showToast(this.getUIContext(), { message: '请先选择至少一个网站', duration: 1600 });
      return;
    }
    if (selected > 10) {
      UiUtil.showToast(this.getUIContext(), { message: '一次最多选择 10 个网站', duration: 1800 });
      return;
    }
    const result = await UiUtil.showDialog(this.getUIContext(), {
      title: '开始批量生成？',
      message: '即将依次分析 ' + selected.toString() + ' 个网站。每个网站都会真实执行搜索、详情、目录和正文验证，可能耗时较长并消耗多次 AI 请求。\n\n生成成功的书源会立即保存为“未启用”。',
      buttons: [
        { text: '取消', color: ThemeColors.secondaryText(this.isDark) },
        { text: '开始生成', color: ThemeColors.primary(this.isDark) },
      ],
    });
    if (result.index !== 1) return;
    this.batchRunning_ = true;
    this.batchStopRequested_ = false;
    this.discoveryPhase_ = 'running';
    this.batchSummary_ = createAiSourceBatchSummary();
    this.batchService_ = new AiSourceBatchGenerateService();
    try {
      const summary = await this.batchService_.run(
        UiUtil.getHostContext(this.getUIContext()), this.normalizedDiscoveryKeyword_(),
        this.discoveryCandidates_, this.allowUpdateExisting_, {
          onCandidateChanged: (candidate: AiSourceCandidate): void => {
            if (!this.pageActive_) return;
            this.discoveryCandidates_ = this.discoveryCandidates_.map((item: AiSourceCandidate): AiSourceCandidate =>
              item.id === candidate.id ? candidate : item);
          },
          onSummaryChanged: (next: AiSourceBatchSummary): void => {
            if (this.pageActive_) this.batchSummary_ = next;
          },
          onRequestWebView: (url: string, reason: string): Promise<string> =>
            this.pageActive_ ? this.openInteractiveWebView_(url, reason) : Promise.resolve(''),
          onBatchError: (message: string): void => {
            if (this.pageActive_) UiUtil.showToast(this.getUIContext(), { message: message, duration: 2200 });
          },
        });
      if (this.pageActive_) this.batchSummary_ = summary;
      this.discoveryPhase_ = 'completed';
    } catch (e) {
      this.discoveryError_ = '批量任务失败：' + ((e as Error).message || String(e));
      this.discoveryPhase_ = 'error';
    } finally {
      this.batchRunning_ = false;
      this.batchService_ = null;
    }
  }

  private requestBatchStop_(): void {
    if (!this.batchRunning_) return;
    this.batchStopRequested_ = true;
    this.batchService_?.requestStop();
  }

  private async enableBatchCreated_(): Promise<void> {
    if (this.batchSummary_.createdSourceIds.length === 0) return;
    try {
      await AppDatabase.getInstance().waitForInit();
      const dao = new BookSourceTable(AppDatabase.getInstance().rdbStore);
      for (const id of this.batchSummary_.createdSourceIds) await dao.toggleEnabled(id, true);
      BookSourceChangeNotifier.notify();
      UiUtil.showToast(this.getUIContext(), { message: '已启用本次新增书源', duration: 1800 });
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: '启用失败：' + ((e as Error).message || String(e)), duration: 2200 });
    }
  }

  private candidateDuplicateText_(candidate: AiSourceCandidate): string {
    if (!candidate.safe) return '地址待确认';
    if (candidate.duplicate === 'exact') return '已有书源';
    if (candidate.duplicate === 'same_host') return '疑似重复';
    return '新网站';
  }

  private candidateStatusText_(candidate: AiSourceCandidate): string {
    if (candidate.status === 'created') return '已新增（未启用）';
    if (candidate.status === 'updated') return '已更新';
    if (candidate.status === 'unchanged') return '配置无变化';
    if (candidate.status === 'skipped') return '已跳过';
    if (candidate.status === 'failed') return '生成失败';
    if (candidate.status === 'cancelled') return '未执行';
    if (candidate.status === 'waiting_user') return '等待人工验证';
    if (candidate.status === 'running') return '生成中';
    return '等待中';
  }

  private batchProgressText_(): string {
    const selected = this.discoveryCandidates_.filter((item: AiSourceCandidate): boolean => item.selected);
    const finished = selected.filter((item: AiSourceCandidate): boolean =>
      item.status === 'created' || item.status === 'updated' || item.status === 'unchanged' ||
      item.status === 'failed' || item.status === 'skipped' || item.status === 'cancelled').length;
    const current = selected.find((item: AiSourceCandidate): boolean =>
      item.status === 'running' || item.status === 'waiting_user');
    if (!current) return finished.toString() + ' / ' + selected.length.toString();
    return finished.toString() + ' / ' + selected.length.toString() + ' · 当前：' + (current.host || current.displayName) +
      (current.stepSummary ? ' · ' + current.stepSummary : '');
  }

  private async copyBatchSummary_(): Promise<void> {
    const lines: string[] = ['AI 搜书发现批量结果', '书名：' + this.discoveryKeyword_, ''];
    for (const candidate of this.discoveryCandidates_) {
      lines.push((candidate.host || candidate.displayName) + '：' + this.candidateStatusText_(candidate) +
        (candidate.error || candidate.stepSummary ? '，' + (candidate.error || candidate.stepSummary) : ''));
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, lines.join('\n'));
      await pasteboard.getSystemPasteboard().setData(data);
      UiUtil.showToast(this.getUIContext(), { message: '结果摘要已复制', duration: 1500 });
    } catch (_e) {
      UiUtil.showToast(this.getUIContext(), { message: '复制结果摘要失败', duration: 1800 });
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
      const existing = await AiGeneratedSourceSaveService.findExistingByNormalizedUrl(candidate.sourceUrl);
      if (!existing) {
        const result = await AiGeneratedSourceSaveService.createGeneratedSource(candidate, true);
        UiUtil.showToast(this.getUIContext(), {
          message: result.message, duration: 1800
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

      const applied = await AiGeneratedSourceSaveService.updateGeneratedSource(
        existing, candidate, 'AI 生成书源：更新已有同网址书源', false);
      UiUtil.showToast(this.getUIContext(), {
        message: applied.message, duration: 2000
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
    if (status === 'skipped') return '○';
    return '−';
  }

  private repairScopeDesc_(): string {
    if (this.repairScope === 'search') {
      return '仅诊断修复搜索链路：搜索结果 → 详情 → 目录 → 正文；发现规则保持原样';
    }
    if (this.repairScope === 'discovery') {
      return '仅诊断修复发现链路：发现分类 → 分类列表 → 详情 → 目录 → 正文；书源无发现规则时自动新增，搜索规则保持原样';
    }
    return '诊断修复完整链路：搜索与发现的列表、详情、目录、正文';
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

  @Builder
  private buildDiscoveryPanel_() {
    Column({ space: 10 }) {
      if (this.discoveryCandidates_.length === 0) {
        Text('书名').fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).width('100%')
        TextInput({ text: this.discoveryKeyword_, placeholder: '输入要发现网站的书名' })
          .width('100%').height(46).fontSize(15)
          .fontColor(ThemeColors.onSurface(this.isDark))
          .placeholderColor(ThemeColors.secondaryText(this.isDark))
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).borderRadius(12)
          .onChange((value: string): void => { this.discoveryKeyword_ = value; })
        Row() {
          Text('搜索引擎').fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).layoutWeight(1)
          Select(AI_DISCOVERY_SEARCH_OPTIONS)
            .selected(ONLINE_SEARCH_ENGINES.findIndex((item): boolean => item.id === this.discoveryEngine_))
            .value(getOnlineSearchEngineName(this.discoveryEngine_))
            .height(40).fontColor(ThemeColors.primary(this.isDark))
            .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
            .onSelect((index: number): void => {
              if (index < 0 || index >= ONLINE_SEARCH_ENGINES.length) return;
              this.discoveryEngine_ = ONLINE_SEARCH_ENGINES[index].id;
              void this.persistDiscoveryPrefs_();
            })
        }.width('100%')
        Button('打开搜索结果并发现网站').width('100%').height(48).borderRadius(24)
          .fontSize(15).fontColor(ThemeColors.onPrimary(this.isDark))
          .backgroundColor(ThemeColors.primary(this.isDark))
          .enabled(!this.isAnyTaskRunning_())
          .onClick((): void => { void this.openDiscoveryBrowser_(); })
        Text('这里只发现并生成书源，不会把搜索到的书加入书架。')
          .fontSize(12).lineHeight(18).fontColor(ThemeColors.secondaryText(this.isDark)).width('100%')
        if (this.discoveryError_) {
          Text(this.discoveryError_).fontSize(12).lineHeight(18)
            .fontColor(ThemeColors.error(this.isDark)).width('100%')
        }
      } else {
        this.buildDiscoveryCandidates_()
      }
    }.width('100%').layoutWeight(1).padding({ left: 16, right: 16, top: 10, bottom: 10 })
  }

  @Builder
  private buildDiscoveryCandidates_() {
    Column({ space: 8 }) {
      if (this.discoveryError_) {
        Text(this.discoveryError_).fontSize(12).lineHeight(18)
          .fontColor(ThemeColors.error(this.isDark)).width('100%')
      }
      if (this.batchRunning_ || this.discoveryPhase_ === 'completed') {
        Column({ space: 4 }) {
          Text(this.batchRunning_ ? '批量生成进行中' : '批量生成完成')
            .fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.onSurface(this.isDark)).width('100%')
          Text('新增 ' + this.batchSummary_.created.toString() + ' · 更新 ' +
            this.batchSummary_.updated.toString() + ' · 无变化 ' + this.batchSummary_.unchanged.toString() +
            ' · 失败 ' + this.batchSummary_.failed.toString() + ' · 跳过 ' +
            this.batchSummary_.skipped.toString() + ' · 未执行 ' + this.batchSummary_.cancelled.toString())
            .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).width('100%')
          if (this.batchRunning_) {
            Text(this.batchProgressText_()).fontSize(12)
              .fontColor(ThemeColors.primary(this.isDark)).width('100%').maxLines(2)
          }
          if (this.batchRunning_) {
            Text(this.batchStopRequested_ ? '当前网站结束后将停止后续任务' : '网站按顺序执行，当前项完成后才会开始下一项')
              .fontSize(12).fontColor(ThemeColors.primary(this.isDark)).width('100%')
            Button('完成当前网站后停止').height(36).borderRadius(18)
              .fontSize(12).fontColor(ThemeColors.onPrimary(this.isDark))
              .backgroundColor(ThemeColors.primary(this.isDark))
              .enabled(!this.batchStopRequested_)
              .onClick((): void => { this.requestBatchStop_(); })
          }
        }.width('100%').padding(12).backgroundColor(ThemeColors.surfaceVariant(this.isDark)).borderRadius(12)
      }

      Row() {
        Text('发现 ' + this.discoveryCandidates_.length.toString() + ' 个候选网站 · 已选择 ' +
          this.selectionCount_().toString()).fontSize(13)
          .fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1)
        Button('选择新网站').height(32).fontSize(11).borderRadius(16)
          .backgroundColor(ThemeColors.transparent()).fontColor(ThemeColors.primary(this.isDark))
          .enabled(!this.isAnyTaskRunning_()).onClick((): void => { this.selectAllNewCandidates_(); })
        Button('清空').height(32).fontSize(11).borderRadius(16)
          .backgroundColor(ThemeColors.transparent()).fontColor(ThemeColors.secondaryText(this.isDark))
          .enabled(!this.isAnyTaskRunning_()).onClick((): void => { this.clearCandidateSelection_(); })
      }.width('100%')

      List({ space: 8 }) {
        ForEach(this.discoveryCandidates_, (candidate: AiSourceCandidate) => {
          ListItem() {
            Column({ space: 6 }) {
              Row({ space: 8 }) {
                Toggle({ type: ToggleType.Checkbox, isOn: candidate.selected })
                  .width(26).height(26)
                  .enabled(candidate.safe && !this.isAnyTaskRunning_())
                  .accessibilityText('选择 ' + candidate.displayName)
                  .onChange((value: boolean): void => { this.toggleCandidate_(candidate.id, value); })
                Column({ space: 2 }) {
                  Text(candidate.displayName).fontSize(14).fontWeight(FontWeight.Medium)
                    .fontColor(ThemeColors.onSurface(this.isDark)).maxLines(1)
                  Text(candidate.host || '地址待确认').fontSize(11)
                    .fontColor(ThemeColors.secondaryText(this.isDark)).maxLines(1)
                }.layoutWeight(1)
                Text(this.candidateDuplicateText_(candidate)).fontSize(11)
                  .fontColor(candidate.duplicate === 'exact' ? ThemeColors.warning(this.isDark) :
                    candidate.safe ? ThemeColors.primary(this.isDark) : ThemeColors.error(this.isDark))
              }.width('100%')
              TextInput({ text: candidate.homepageUrl, placeholder: '编辑首页地址（例如 https://example.com）' })
                .width('100%').height(38).fontSize(12)
                .fontColor(ThemeColors.onSurface(this.isDark))
                .placeholderColor(ThemeColors.secondaryText(this.isDark))
                .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).borderRadius(9)
                .enabled(!this.isAnyTaskRunning_())
                .onChange((value: string): void => { this.updateCandidateHomepage_(candidate.id, value); })
              Text('搜索结果中命中 ' + candidate.hitCount.toString() + ' 个页面 · 置信度 ' +
                candidate.confidence.toString())
                .fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).width('100%')
              if (candidate.samples.length > 0) {
                Text(candidate.samples.map((sample): string => sample.title || sample.url).join(' · '))
                  .fontSize(11).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .fontColor(ThemeColors.secondaryText(this.isDark)).width('100%')
              }
              if (candidate.status !== 'candidate') {
                Text(this.candidateStatusText_(candidate) + (candidate.stepSummary ? '：' + candidate.stepSummary : ''))
                  .fontSize(11).lineHeight(16)
                  .fontColor(candidate.status === 'failed' ? ThemeColors.error(this.isDark) :
                    candidate.status === 'created' ? ThemeColors.success(this.isDark) : ThemeColors.secondaryText(this.isDark))
                  .width('100%').maxLines(3)
              }
              if (candidate.logs.length > 0 && (candidate.status === 'running' || candidate.status === 'waiting_user')) {
                Text(candidate.logs[candidate.logs.length - 1]).fontSize(10).lineHeight(15)
                  .fontColor(ThemeColors.secondaryText(this.isDark)).width('100%').maxLines(2)
              }
            }.padding(10).backgroundColor(ThemeColors.surface(this.isDark)).borderRadius(12)
          }
        }, (candidate: AiSourceCandidate): string => candidate.id)
      }.layoutWeight(1).width('100%')

      if (!this.batchRunning_ && this.discoveryPhase_ !== 'completed') {
        Row() {
          Toggle({ type: ToggleType.Switch, isOn: this.allowUpdateExisting_ })
            .onChange((value: boolean): void => { this.allowUpdateExisting_ = value; })
          Text('允许重新生成并更新已有书源').fontSize(12)
            .fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1).margin({ left: 8 })
        }.width('100%')
        Button('批量生成选中的 ' + this.selectionCount_().toString() + ' 个书源')
          .width('100%').height(48).borderRadius(24).fontSize(15)
          .fontColor(ThemeColors.onPrimary(this.isDark)).backgroundColor(ThemeColors.primary(this.isDark))
          .enabled(this.selectionCount_() > 0 && !this.isAnyTaskRunning_())
          .onClick((): void => { void this.startBatchGenerate_(); })
      } else if (!this.batchRunning_ && this.discoveryPhase_ === 'completed') {
        Row({ space: 8 }) {
          Button('重新搜索').layoutWeight(1).height(42).borderRadius(21)
            .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).fontColor(ThemeColors.onSurface(this.isDark))
            .onClick((): void => {
              this.discoveryCandidates_ = [];
              this.discoveryPhase_ = 'idle';
              this.discoveryError_ = '';
            })
          Button('启用本次新增').layoutWeight(1).height(42).borderRadius(21)
            .backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark))
            .enabled(this.batchSummary_.createdSourceIds.length > 0)
            .onClick((): void => { void this.enableBatchCreated_(); })
          Button('复制摘要').layoutWeight(1).height(42).borderRadius(21)
            .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).fontColor(ThemeColors.onSurface(this.isDark))
            .onClick((): void => { void this.copyBatchSummary_(); })
        }.width('100%')
      }
    }.width('100%').layoutWeight(1)
  }

  build() {
    Column() {
      Row() {
        Button($r('app.string.ui_8179643cdc')).fontSize(18)
          .fontColor(ThemeColors.secondaryText(this.isDark)).width(40).height(40)
          .backgroundColor(ThemeColors.transparent())
          .accessibilityText($r('app.string.common_back'))
          .onClick(() => { UiUtil.back(this.getUIContext()); })
        Text(this.repairMode ? 'AI 修复书源' : 'AI 书源')
          .fontColor(ThemeColors.onSurface(this.isDark)).fontSize(18)
          .fontWeight(FontWeight.Bold).layoutWeight(1)
        Button('AI 设置').fontSize(13).height(40).backgroundColor(ThemeColors.transparent())
          .fontColor(ThemeColors.primary(this.isDark))
          .onClick(() => { UiUtil.pushUrl(this.getUIContext(), { url: 'pages/AiConfigPage' }); })
      }.padding({ left: 12, right: 12 }).width('100%')
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])

      if (!this.repairMode) {
        Row({ space: 0 }) {
          Button('网址建源').layoutWeight(1).height(42).fontSize(14)
            .fontColor(this.createTab_ === 0 ? ThemeColors.primary(this.isDark) : ThemeColors.secondaryText(this.isDark))
            .backgroundColor(this.createTab_ === 0 ? ThemeColors.primaryContainer(this.isDark) : ThemeColors.surface(this.isDark))
            .enabled(!this.isAnyTaskRunning_())
            .accessibilityText('网址建源')
            .onClick((): void => { this.switchCreateTab_(0); })
          Button('搜书发现').layoutWeight(1).height(42).fontSize(14)
            .fontColor(this.createTab_ === 1 ? ThemeColors.primary(this.isDark) : ThemeColors.secondaryText(this.isDark))
            .backgroundColor(this.createTab_ === 1 ? ThemeColors.primaryContainer(this.isDark) : ThemeColors.surface(this.isDark))
            .enabled(!this.isAnyTaskRunning_())
            .accessibilityText('搜书发现')
            .onClick((): void => { this.switchCreateTab_(1); })
        }.width('100%').padding({ left: 12, right: 12, top: 4, bottom: 4 })
      }

      if (!this.repairMode && this.createTab_ === 1) {
        this.buildDiscoveryPanel_()
      } else if (!this.isAnalyzing && this.steps.length === 0) {
        Column() {
          if (this.repairMode) {
            Text('待修复：' + (this.repairSourceName || '加载中…')).fontSize(15)
              .fontWeight(FontWeight.Medium).fontColor(ThemeColors.onSurface(this.isDark))
              .width('100%').margin({ bottom: 6 })
            Text(this.invalidGroups.length > 0
              ? '待修复阶段：' + this.invalidGroups.join('、')
              : '待修复阶段：先校验现有规则，失败阶段自动修复').fontSize(12)
              .fontColor(ThemeColors.error(this.isDark)).width('100%').margin({ bottom: 12 })
            Text('修复范围').fontSize(14)
              .fontColor(ThemeColors.secondaryText(this.isDark)).width('100%').margin({ bottom: 6 })
            Row({ space: 0 }) {
              Button('全部').layoutWeight(1).height(42).fontSize(14)
                .fontColor(this.repairScope === 'all' ? ThemeColors.primary(this.isDark) :
                  ThemeColors.secondaryText(this.isDark))
                .backgroundColor(this.repairScope === 'all' ? ThemeColors.primaryContainer(this.isDark) :
                  ThemeColors.surface(this.isDark))
                .accessibilityText('修复范围：全部')
                .onClick((): void => { this.repairScope = 'all'; })
              Button('搜索').layoutWeight(1).height(42).fontSize(14)
                .fontColor(this.repairScope === 'search' ? ThemeColors.primary(this.isDark) :
                  ThemeColors.secondaryText(this.isDark))
                .backgroundColor(this.repairScope === 'search' ? ThemeColors.primaryContainer(this.isDark) :
                  ThemeColors.surface(this.isDark))
                .accessibilityText('修复范围：仅搜索链路')
                .onClick((): void => { this.repairScope = 'search'; })
              Button('发现').layoutWeight(1).height(42).fontSize(14)
                .fontColor(this.repairScope === 'discovery' ? ThemeColors.primary(this.isDark) :
                  ThemeColors.secondaryText(this.isDark))
                .backgroundColor(this.repairScope === 'discovery' ?
                  ThemeColors.primaryContainer(this.isDark) : ThemeColors.surface(this.isDark))
                .accessibilityText('修复范围：仅发现链路')
                .onClick((): void => { this.repairScope = 'discovery'; })
            }.width('100%')
            Text(this.repairScopeDesc_()).fontSize(11).lineHeight(16)
              .fontColor(ThemeColors.secondaryText(this.isDark)).width('100%')
              .margin({ top: 6, bottom: 16 })
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
      if (this.showDiscoveryBrowser_) {
        Stack({ alignContent: Alignment.Center }) {
          Column().width('100%').height('100%').backgroundColor(ThemeColors.scrim(this.isDark))
          AiImportPreviewDialog({
            initialUrl: this.discoveryBrowserUrl_,
            titleText: getOnlineSearchEngineName(this.discoveryEngine_) + ' · ' + this.discoveryKeyword_,
            confirmText: '提取当前页网站',
            helperText: '停留在搜索结果页，无需进入具体小说。加载完成后提取当前页中的网站。',
            dismissBeforeConfirm: false,
            collectLinks: true,
            onCancel: (): void => { this.closeDiscoveryBrowser_(); },
            onConfirm: (result: AiImportPreviewResult): void => { void this.handleDiscoveryPreview_(result); },
          })
        }.width('100%').height('100%')
      }
      WebViewEngine().width(1).height(1).visibility(Visibility.Hidden)
    }.width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
  }
}
