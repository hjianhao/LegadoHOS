/** 龙空“推书试读”发现：选帖、AI 书目整理与最近分析历史。 */
import { ThemeColors } from '../theme/ThemeColors';
import { UiUtil } from '../util/UiUtil';
import { CookieStore } from '../util/CookieStore';
import { SettingsStore } from '../data/preferences/SettingsStore';
import { LkongLoginDialog } from '../components/LkongLoginDialog';
import {
  LKONG_API_URL,
  LkongForumFilter,
  LkongService,
  LkongTagItem,
  LkongThreadContent,
  LkongThreadItem,
  LkongThreadPage,
} from '../service/LkongService';
import {
  LkongAnalysisRecord,
  LkongBookAgent,
  LkongBookRecommendation,
} from '../engine/ai/LkongBookAgent';
import { ArrayDataSource } from '../util/ArrayDataSource';

interface LkongFilterOption {
  value: LkongBrowseMode;
  label: string;
}

type LkongBrowseMode = 'all' | 'digest' | 'new' | 'hot' | 'tag';

const LKONG_FILTERS: LkongFilterOption[] = [
  { value: 'all', label: '全部' },
  { value: 'digest', label: '精华' },
  { value: 'new', label: '最新' },
  { value: 'hot', label: '今日热门' },
  { value: 'tag', label: '标签' },
];

const RECENT_DAY_OPTIONS: SelectOption[] = [
  { value: '最近 1 天' },
  { value: '最近 2 天' },
  { value: '最近 3 天' },
  { value: '最近 4 天' },
  { value: '最近 5 天' },
  { value: '最近 6 天' },
  { value: '最近 7 天' },
];

@Component
export struct LkongExplorePage {
  @StorageLink('isDark') isDark: boolean = false;
  @State private section: number = 0;
  @State private browseMode: LkongBrowseMode = 'all';
  @State private filter: LkongForumFilter = 'all';
  @State private tags: LkongTagItem[] = [];
  @State private selectedTag: LkongTagItem | null = null;
  @State @Watch('onThreadsChanged_') private threads: LkongThreadItem[] = [];
  @State private selectedIds: number[] = [];
  @State private page: number = 1;
  @State private hasMore: boolean = false;
  @State private isLoading: boolean = true;
  @State private isLoadingMore: boolean = false;
  @State private isSelectingRecent: boolean = false;
  @State private recentDays: number = 1;
  @State private isAnalyzing: boolean = false;
  @State private errorMessage: string = '';
  @State private loginRequired: boolean = false;
  @State private history: LkongAnalysisRecord[] = [];
  @State private currentRecord: LkongAnalysisRecord | null = null;
  @State private analysisStatus: string = '';

  private requestId: number = 0;
  private recentRequestId: number = 0;
  private analysisRequestId: number = 0;
  private selectedSet: Set<number> = new Set();
  private isActive: boolean = false;
  private loginDialog?: CustomDialogController;
  private threadDataSource_: ArrayDataSource<LkongThreadItem> = new ArrayDataSource<LkongThreadItem>();

  private onThreadsChanged_(): void {
    this.threadDataSource_.reset(this.threads);
  }

  aboutToAppear(): void {
    this.isActive = true;
    if (this.history.length === 0) void this.loadHistory();
    if (this.threads.length === 0) void this.loadThreads(false);
  }

  aboutToDisappear(): void {
    this.isActive = false;
    this.requestId++;
    this.recentRequestId++;
    this.analysisRequestId++;
    this.isSelectingRecent = false;
    this.isAnalyzing = false;
    this.analysisStatus = '';
  }

  private async loadHistory(): Promise<void> {
    try {
      const store = SettingsStore.getInstance();
      await store.init(UiUtil.getHostContext(this.getUIContext()));
      const parsed = JSON.parse(await store.getLkongAnalysisHistory()) as LkongAnalysisRecord[];
      if (!this.isActive) return;
      this.history = Array.isArray(parsed) ? parsed.slice(0, 10) : [];
      if (!this.currentRecord && this.history.length > 0) this.currentRecord = this.history[0];
    } catch (_e) {
      if (this.isActive) this.history = [];
    }
  }

  private async loadThreads(append: boolean): Promise<void> {
    if (this.browseMode === 'tag' && !this.selectedTag) {
      this.isLoading = false;
      this.isLoadingMore = false;
      return;
    }
    if (append) {
      if (this.isLoadingMore || !this.hasMore) return;
      this.isLoadingMore = true;
    } else {
      this.isLoading = true;
      this.errorMessage = '';
      this.loginRequired = false;
    }
    const runId = ++this.requestId;
    const targetPage = append ? this.page + 1 : 1;
    try {
      const result = await this.fetchThreadPage(targetPage);
      if (!this.isActive || runId !== this.requestId) return;
      this.threads = append ? [...this.threads, ...result.threads] : result.threads;
      this.page = targetPage;
      this.hasMore = result.hasMore;
      this.loginRequired = false;
    } catch (e) {
      if (!this.isActive || runId !== this.requestId) return;
      const message = (e as Error).message || '加载失败';
      this.loginRequired = message.startsWith('LOGIN_REQUIRED:');
      this.errorMessage = this.loginRequired ? '龙空要求登录后浏览该板块' : message;
    } finally {
      if (this.isActive && runId === this.requestId) {
        this.isLoading = false;
        this.isLoadingMore = false;
      }
    }
  }

  private async fetchThreadPage(targetPage: number): Promise<LkongThreadPage> {
    if (this.browseMode === 'hot') return LkongService.loadHotThreads();
    if (this.browseMode === 'tag' && this.selectedTag) {
      return LkongService.loadTagThreads(this.selectedTag, targetPage);
    }
    return LkongService.loadThreads(this.filter, targetPage);
  }

  private async loadTags(): Promise<void> {
    if (this.tags.length > 0) return;
    this.isLoading = true;
    this.errorMessage = '';
    const runId = ++this.requestId;
    try {
      const result = await LkongService.loadTags();
      if (!this.isActive || runId !== this.requestId || this.browseMode !== 'tag') return;
      this.tags = result;
      if (result.length === 0) this.errorMessage = '该板块暂时没有可浏览标签';
    } catch (e) {
      if (!this.isActive || runId !== this.requestId) return;
      const message = (e as Error).message || '标签加载失败';
      this.loginRequired = message.startsWith('LOGIN_REQUIRED:');
      this.errorMessage = this.loginRequired ? '龙空要求登录后浏览该板块' : message;
    } finally {
      if (this.isActive && runId === this.requestId) this.isLoading = false;
    }
  }

  private selectFilter(option: LkongFilterOption): void {
    if (option.value === this.browseMode || this.isLoading || this.isAnalyzing) return;
    this.requestId++;
    this.browseMode = option.value;
    if (option.value === 'all' || option.value === 'digest' || option.value === 'new') {
      this.filter = option.value;
    }
    this.threads = [];
    this.setSelectedIds([]);
    this.page = 1;
    this.hasMore = false;
    this.errorMessage = '';
    this.loginRequired = false;
    if (option.value === 'tag') {
      this.selectedTag = null;
      void this.loadTags();
    } else {
      void this.loadThreads(false);
    }
  }

  private selectTag(tag: LkongTagItem): void {
    if (this.selectedTag?.id === tag.id || this.isLoading || this.isAnalyzing) return;
    this.selectedTag = tag;
    this.threads = [];
    this.setSelectedIds([]);
    this.page = 1;
    this.hasMore = false;
    void this.loadThreads(false);
  }

  private isSelected(tid: number): boolean {
    return this.selectedSet.has(tid);
  }

  private setSelectedIds(ids: number[]): void {
    this.selectedSet = new Set(ids);
    this.selectedIds = ids;
  }

  private toggleSelected(tid: number, selected?: boolean): void {
    const shouldSelect = selected === undefined ? !this.isSelected(tid) : selected;
    if (shouldSelect && !this.isSelected(tid)) {
      this.setSelectedIds([...this.selectedIds, tid]);
    } else if (!shouldSelect) {
      this.setSelectedIds(this.selectedIds.filter((id: number): boolean => id !== tid));
    }
  }

  private toggleAllLoaded(): void {
    const allSelected = this.threads.length > 0 && this.threads.every((item: LkongThreadItem): boolean => this.isSelected(item.tid));
    this.setSelectedIds(allSelected ? [] : this.threads.map((item: LkongThreadItem): number => item.tid));
  }

  /** 自动翻页，直到帖子时间越过所选天数边界或没有下一页。 */
  private async selectRecentDays(): Promise<void> {
    if (this.isSelectingRecent || this.isLoading) return;
    this.isSelectingRecent = true;
    const runId = ++this.recentRequestId;
    this.errorMessage = '';
    const days = Math.min(7, Math.max(1, this.recentDays));
    const since = Date.now() - days * 24 * 60 * 60 * 1000;
    let collected: LkongThreadItem[] = [];
    let nextPage = 1;
    let continueLoading = true;
    try {
      while (continueLoading && nextPage <= 20) {
        this.analysisStatus = '正在读取最近 ' + days.toString() + ' 天帖子 · 第 ' + nextPage.toString() + ' 页';
        const result = await this.fetchThreadPage(nextPage);
        if (!this.isActive || runId !== this.recentRequestId) return;
        collected = [...collected, ...result.threads];
        const timestamps = result.threads.map((item: LkongThreadItem): number => item.timestamp)
          .filter((value: number): boolean => value > 0);
        const oldest = timestamps.length > 0 ? Math.min(...timestamps) : 0;
        continueLoading = result.hasMore && (oldest === 0 || oldest >= since);
        nextPage++;
      }
      this.threads = collected;
      this.page = Math.max(1, nextPage - 1);
      this.hasMore = continueLoading;
      this.setSelectedIds(LkongService.filterSince(collected, since)
        .map((item: LkongThreadItem): number => item.tid));
      this.loginRequired = false;
      UiUtil.showToast(this.getUIContext(), {
        message: '已选择最近 ' + days.toString() + ' 天 ' + this.selectedIds.length.toString() + ' 个帖子', duration: 1800
      });
    } catch (e) {
      if (!this.isActive || runId !== this.recentRequestId) return;
      const message = (e as Error).message || '读取最近帖子失败';
      this.loginRequired = message.startsWith('LOGIN_REQUIRED:');
      this.errorMessage = this.loginRequired ? '龙空要求登录后浏览该板块' : message;
    } finally {
      if (this.isActive && runId === this.recentRequestId) {
        this.analysisStatus = '';
        this.isSelectingRecent = false;
      }
    }
  }

  private async analyzeSelected(): Promise<void> {
    if (this.isAnalyzing || this.selectedIds.length === 0) {
      if (this.selectedIds.length === 0) {
        UiUtil.showToast(this.getUIContext(), { message: '请先选择帖子', duration: 1500 });
      }
      return;
    }
    this.isAnalyzing = true;
    const runId = ++this.analysisRequestId;
    this.errorMessage = '';
    try {
      const agent = new LkongBookAgent();
      await agent.init(UiUtil.getHostContext(this.getUIContext()));
      if (!this.isActive || runId !== this.analysisRequestId) return;
      if (!agent.isConfigured()) throw new Error('请先在设置中配置大模型 API');
      const selected = this.threads.filter((item: LkongThreadItem): boolean => this.isSelected(item.tid));
      const contents: LkongThreadContent[] = [];
      for (let i = 0; i < selected.length; i++) {
        this.analysisStatus = '读取帖子正文 ' + (i + 1).toString() + '/' + selected.length.toString();
        contents.push(await LkongService.loadThreadContent(selected[i]));
        if (!this.isActive || runId !== this.analysisRequestId) return;
      }
      this.analysisStatus = '大模型正在整理书名、作者和推荐理由…';
      const books = await agent.analyze(contents);
      if (!this.isActive || runId !== this.analysisRequestId) return;
      const now = Date.now();
      const record: LkongAnalysisRecord = {
        id: now.toString(),
        title: this.formatTime(now) + ' · ' + this.filterLabel(),
        createdAt: now,
        filterLabel: this.filterLabel(),
        threadCount: selected.length,
        books: books,
      };
      this.history = [record, ...this.history].slice(0, 10);
      this.currentRecord = record;
      const store = SettingsStore.getInstance();
      await store.setLkongAnalysisHistory(JSON.stringify(this.history));
      if (!this.isActive || runId !== this.analysisRequestId) return;
      this.section = 1;
      UiUtil.showToast(this.getUIContext(), {
        message: '已整理 ' + books.length.toString() + ' 本书', duration: 1800
      });
    } catch (e) {
      if (!this.isActive || runId !== this.analysisRequestId) return;
      this.errorMessage = (e as Error).message || '分析失败';
      UiUtil.showToast(this.getUIContext(), { message: this.errorMessage, duration: 2200 });
    } finally {
      if (this.isActive && runId === this.analysisRequestId) {
        this.analysisStatus = '';
        this.isAnalyzing = false;
      }
    }
  }

  private filterLabel(): string {
    if (this.browseMode === 'tag') return '标签 · ' + (this.selectedTag?.name || '未选择');
    return LKONG_FILTERS.find((item: LkongFilterOption): boolean => item.value === this.browseMode)?.label || '全部';
  }

  private formatTime(timestamp: number): string {
    const date = new Date(timestamp);
    const pad = (value: number): string => value < 10 ? '0' + value.toString() : value.toString();
    return (date.getMonth() + 1).toString() + '-' + pad(date.getDate()) + ' ' +
      pad(date.getHours()) + ':' + pad(date.getMinutes());
  }

  private formatThreadMeta(item: LkongThreadItem): string {
    const parts: string[] = [];
    if (item.author) parts.push(item.author);
    if (this.browseMode === 'hot') parts.push('今日热门');
    else if (item.timestamp > 0) parts.push(this.formatTime(item.timestamp));
    if (item.replies > 0) parts.push(item.replies.toString() + ' 回复');
    if (item.views > 0) parts.push(item.views.toString() + ' 浏览');
    return parts.join(' · ');
  }

  private openLogin(): void {
    this.loginDialog = new CustomDialogController({
      builder: LkongLoginDialog({
        controller: this.loginDialog!,
        onLoginSuccess: (): void => { if (this.isActive) this.retryCurrentLoad(); }
      }),
      autoCancel: true,
      customStyle: true,
      alignment: DialogAlignment.Center,
    });
    this.loginDialog.open();
  }

  private retryCurrentLoad(): void {
    this.errorMessage = '';
    this.loginRequired = false;
    if (this.browseMode === 'tag' && !this.selectedTag) {
      this.tags = [];
      void this.loadTags();
    } else {
      void this.loadThreads(false);
    }
  }

  private async logout(): Promise<void> {
    await CookieStore.getInstance().removeCookie(LKONG_API_URL);
    await CookieStore.getInstance().removeCookie('https://www.lkong.com');
    this.loginRequired = true;
    this.threads = [];
    this.tags = [];
    this.selectedTag = null;
    this.setSelectedIds([]);
    this.errorMessage = '已退出龙空登录';
  }

  private openSearch(book: LkongBookRecommendation): void {
    const keyword = book.author ? book.name + ' ' + book.author : book.name;
    UiUtil.showDialog(this.getUIContext(), {
      title: '搜索《' + book.name + '》',
      message: '请选择搜索方式',
      buttons: [
        { text: '书源搜索', color: ThemeColors.primary(this.isDark) },
        { text: '在线搜索', color: ThemeColors.primary(this.isDark) }
      ]
    }).then((result): void => {
      if (result.index < 0 || result.index > 1) return;
      UiUtil.pushUrl(this.getUIContext(), {
        url: 'pages/SearchPage', params: { key: keyword, bookName: book.name, author: book.author,
          searchMode: result.index === 1 ? 'online' : 'source' }
      });
    });
  }

  private deleteAnalysisRecord(record: LkongAnalysisRecord): void {
    UiUtil.showAlertDialog(this.getUIContext(), {
      title: '删除分析结果',
      message: '确定删除“' + record.title + '”吗？',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: {
        value: '删除',
        fontColor: ThemeColors.error(this.isDark),
        action: (): void => { void this.confirmDeleteAnalysisRecord(record.id); }
      }
    });
  }

  private async confirmDeleteAnalysisRecord(id: string): Promise<void> {
    this.history = this.history.filter((record: LkongAnalysisRecord): boolean => record.id !== id);
    if (this.currentRecord?.id === id) {
      this.currentRecord = this.history.length > 0 ? this.history[0] : null;
    }
    const store = SettingsStore.getInstance();
    await store.init(UiUtil.getHostContext(this.getUIContext()));
    await store.setLkongAnalysisHistory(JSON.stringify(this.history));
    UiUtil.showToast(this.getUIContext(), { message: '已删除分析结果', duration: 1200 });
  }

  build() {
    Column() {
      Row() {
        this.buildSection('选帖子', 0)
        this.buildSection('分析结果', 1)
      }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 4 })

      if (this.section === 0) {
        this.buildThreadSection()
      } else {
        this.buildResultSection()
      }
    }.width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
  }

  @Builder
  private buildSection(label: string, index: number) {
    Button(label).fontSize(13).fontWeight(this.section === index ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.section === index ? ThemeColors.primary(this.isDark) : ThemeColors.secondaryText(this.isDark))
      .height(44).layoutWeight(1).backgroundColor(Color.Transparent)
      .border({ width: this.section === index ? 1 : 0, color: ThemeColors.primary(this.isDark) }).borderRadius(22)
      .accessibilityText(label).accessibilityDescription('双击切换到' + label)
      .onClick((): void => { this.section = index; })
  }

  @Builder
  private buildThreadSection() {
    Column() {
      Row() {
        Column() {
          Text($r('app.string.ui_669a0d78a8')).fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor(ThemeColors.onBackground(this.isDark))
          Text($r('app.string.ui_ed3fa2f3e8')).fontSize(12)
            .fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 2 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button(this.loginRequired ? '登录' : '账号').fontSize(12).height(44).borderRadius(22)
          .fontColor(this.loginRequired ? ThemeColors.onPrimary(this.isDark) : ThemeColors.primary(this.isDark))
          .backgroundColor(this.loginRequired ? ThemeColors.primary(this.isDark) : ThemeColors.surfaceVariant(this.isDark))
          .onClick((): void => {
            if (this.loginRequired) this.openLogin();
            else UiUtil.showAlertDialog(this.getUIContext(), {
              title: '龙空账号', message: '需要重新登录或退出当前登录状态吗？',
              primaryButton: { value: '重新登录', action: (): void => { this.openLogin(); } },
              secondaryButton: { value: '退出', fontColor: ThemeColors.error(this.isDark),
                action: (): void => { void this.logout(); } }
            });
          })
      }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })

      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(LKONG_FILTERS, (option: LkongFilterOption) => {
          Button(option.label).fontSize(12).height(44)
            .fontColor(this.browseMode === option.value ? ThemeColors.onPrimary(this.isDark) : ThemeColors.onSurface(this.isDark))
            .backgroundColor(this.browseMode === option.value ? ThemeColors.primary(this.isDark) : ThemeColors.surfaceVariant(this.isDark))
            .borderRadius(22).padding({ left: 14, right: 14 }).margin({ right: 7, bottom: 4 })
            .accessibilityText('帖子筛选：' + option.label)
            .onClick((): void => { this.selectFilter(option); })
        }, (option: LkongFilterOption): string => option.value)
      }.width('100%').padding({ left: 16, right: 16, bottom: 8 })

      if (this.browseMode === 'tag' && this.tags.length > 0) {
        Column() {
          Row() {
            Text($r('app.string.ui_608b8e137e')).fontSize(13).fontWeight(FontWeight.Medium)
              .fontColor(ThemeColors.onBackground(this.isDark)).layoutWeight(1)
            if (this.selectedTag) {
              Text('正在浏览：' + this.selectedTag.name).fontSize(11)
                .fontColor(ThemeColors.secondaryText(this.isDark))
            }
          }.width('100%').margin({ bottom: 4 })
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.tags, (tag: LkongTagItem) => {
              Button(tag.name).fontSize(12).height(44).borderRadius(22)
                .fontColor(this.selectedTag?.id === tag.id ?
                  ThemeColors.onPrimary(this.isDark) : ThemeColors.onSurface(this.isDark))
                .backgroundColor(this.selectedTag?.id === tag.id ?
                  ThemeColors.primary(this.isDark) : ThemeColors.surfaceVariant(this.isDark))
                .padding({ left: 14, right: 14 }).margin({ right: 7, bottom: 4 })
                .accessibilityText('浏览标签：' + tag.name)
                .accessibilityDescription('来自龙空标签链接 ' + tag.url)
                .onClick((): void => { this.selectTag(tag); })
            }, (tag: LkongTagItem): string => tag.id.toString())
          }.width('100%')
        }.width('100%').padding({ left: 16, right: 16, bottom: 8 })
      }

      Row() {
        Text(this.selectedIds.length.toString() + ' / ' + this.threads.length.toString() + ' 已选择')
          .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).layoutWeight(1)
        Button($r('app.string.common_select_all')).fontSize(12).height(44).backgroundColor(ThemeColors.surfaceVariant(this.isDark))
          .fontColor(ThemeColors.onSurface(this.isDark)).margin({ right: 6 })
          .onClick((): void => { this.toggleAllLoaded(); })
        Select(RECENT_DAY_OPTIONS)
          .selected(this.recentDays - 1).value(this.isSelectingRecent ? '读取中…' : '最近 ' + this.recentDays.toString() + ' 天')
          .height(44).fontColor(ThemeColors.primary(this.isDark))
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
          .enabled(!this.isSelectingRecent && !this.isLoading &&
            (this.browseMode !== 'tag' || this.selectedTag !== null))
          .onSelect((index: number): void => {
            this.recentDays = index + 1;
            void this.selectRecentDays();
          })
      }.width('100%').padding({ left: 16, right: 16, bottom: 8 })

      if (this.isLoading && this.threads.length === 0) {
        Column() {
          LoadingProgress().width(32).height(32).color(ThemeColors.primary(this.isDark))
          Text(this.browseMode === 'tag' && !this.selectedTag ? '正在加载标签…' : '正在加载龙空帖子…')
            .fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 10 })
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else if (this.errorMessage && this.threads.length === 0) {
        Column() {
          Text(this.loginRequired ? '登录后才能浏览' :
            (this.browseMode === 'tag' && !this.selectedTag ? '标签加载失败' : '帖子加载失败'))
            .fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.onBackground(this.isDark))
          Text(this.errorMessage).fontSize(12).fontColor(ThemeColors.error(this.isDark))
            .textAlign(TextAlign.Center).padding({ left: 24, right: 24 }).margin({ top: 8 })
          Button(this.loginRequired ? '登录龙空' : '重试').margin({ top: 16 })
            .onClick((): void => { if (this.loginRequired) this.openLogin(); else this.retryCurrentLoad(); })
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else if (this.browseMode === 'tag' && !this.selectedTag) {
        Column() {
          Text($r('app.string.ui_4994e3d43b')).fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.onBackground(this.isDark))
          Text($r('app.string.ui_24041f7a07'))
            .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 8 })
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else if (this.threads.length === 0) {
        Column() {
          Text(this.browseMode === 'hot' ? '今日暂无热门帖子' : '暂无帖子')
            .fontSize(16).fontWeight(FontWeight.Medium).fontColor(ThemeColors.onBackground(this.isDark))
          Button($r('app.string.common_refresh')).height(44).margin({ top: 12 }).onClick((): void => { void this.loadThreads(false); })
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else {
        List({ space: 7 }) {
          LazyForEach(this.threadDataSource_, (item: LkongThreadItem) => {
            ListItem() { this.buildThreadRow(item) }
          }, (item: LkongThreadItem): string => item.tid.toString())
          if (this.isLoadingMore) {
            ListItem() {
              Row() {
                LoadingProgress().width(20).height(20).color(ThemeColors.primary(this.isDark))
                Text($r('app.string.ui_d5d58840ea')).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ left: 8 })
              }.width('100%').justifyContent(FlexAlign.Center).padding(14)
            }
          }
        }.layoutWeight(1).width('100%').onReachEnd((): void => { void this.loadThreads(true); })
      }

      if (this.analysisStatus) {
        Row() {
          LoadingProgress().width(18).height(18).color(ThemeColors.primary(this.isDark))
          Text(this.analysisStatus).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ left: 8 })
        }.width('100%').justifyContent(FlexAlign.Center).padding({ top: 5, bottom: 5 })
      }
      Button(this.isAnalyzing ? '分析中…' : '分析选中的帖子（' + this.selectedIds.length.toString() + '）')
        .fontSize(14).fontColor(ThemeColors.onPrimary(this.isDark)).height(44).width('92%').borderRadius(22)
        .backgroundColor(ThemeColors.primary(this.isDark)).margin({ top: 7, bottom: 10 })
        .enabled(!this.isAnalyzing && this.selectedIds.length > 0)
        .onClick((): void => { void this.analyzeSelected(); })
    }.width('100%').layoutWeight(1)
  }

  @Builder
  private buildThreadRow(item: LkongThreadItem) {
    Row() {
      Checkbox({ name: 'lkong_' + item.tid.toString(), group: 'lkong_threads' })
        .select(this.isSelected(item.tid)).selectedColor(ThemeColors.primary(this.isDark)).margin({ right: 10 })
        .accessibilityText('选择帖子：' + item.title)
        .onChange((selected: boolean): void => { this.toggleSelected(item.tid, selected); })
      Column() {
        Row() {
          Text(item.title).fontSize(14).fontWeight(FontWeight.Medium).fontColor(ThemeColors.onSurface(this.isDark))
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          if (item.digest) Text($r('app.string.ui_fcb83b62bc')).fontSize(10).fontColor(ThemeColors.primary(this.isDark)).margin({ left: 6 })
        }.width('100%')
        Text(this.formatThreadMeta(item))
          .fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 5 }).maxLines(1)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    }.width('100%').padding(12).margin({ left: 12, right: 12 })
      .backgroundColor(ThemeColors.surface(this.isDark)).borderRadius(10)
      .border({ width: 1, color: this.isSelected(item.tid) ? ThemeColors.primary(this.isDark) : ThemeColors.outlineVariant(this.isDark) })
      .onClick((): void => { this.toggleSelected(item.tid); })
  }

  @Builder
  private buildResultSection() {
    Column() {
      if (this.history.length > 0) {
        Scroll() {
          Row() {
            ForEach(this.history, (record: LkongAnalysisRecord) => {
              Row() {
                Button(record.title).fontSize(11).height(44)
                  .fontColor(this.currentRecord?.id === record.id ? ThemeColors.onPrimary(this.isDark) : ThemeColors.onSurface(this.isDark))
                  .padding({ left: 10, right: 6 }).backgroundColor(Color.Transparent)
                  .accessibilityText('查看分析结果：' + record.title)
                  .onClick((): void => { this.currentRecord = record; })
                Button($r('app.string.ui_67fba2f357')).fontSize(14).width(44).height(44)
                  .fontColor(this.currentRecord?.id === record.id ? ThemeColors.onPrimary(this.isDark) : ThemeColors.error(this.isDark))
                  .padding(0).backgroundColor(Color.Transparent)
                  .accessibilityText('删除分析结果：' + record.title)
                  .onClick((): void => { this.deleteAnalysisRecord(record); })
              }
              .backgroundColor(this.currentRecord?.id === record.id ? ThemeColors.primary(this.isDark) : ThemeColors.surfaceVariant(this.isDark))
              .borderRadius(13).margin({ right: 6 })
            }, (record: LkongAnalysisRecord): string => record.id)
          }.padding({ left: 12, right: 12, top: 10, bottom: 8 })
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
      }

      if (!this.currentRecord) {
        Column() {
          Text($r('app.string.ui_fa49c1b160')).fontSize(17).fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.onBackground(this.isDark))
          Text($r('app.string.ui_0cb9ce6e01'))
            .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 8 })
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else {
        Row() {
          Column() {
            Text(this.currentRecord.title).fontSize(16).fontWeight(FontWeight.Bold)
              .fontColor(ThemeColors.onBackground(this.isDark))
            Text(this.currentRecord.threadCount.toString() + ' 个帖子 · ' +
              this.currentRecord.books.length.toString() + ' 本书')
              .fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 3 })
          }.alignItems(HorizontalAlign.Start)
        }.width('100%').padding({ left: 16, right: 16, top: 5, bottom: 8 })

        List({ space: 8 }) {
          ForEach(this.currentRecord.books, (book: LkongBookRecommendation, index: number) => {
            ListItem() { this.buildBookRow(book, index) }
          }, (book: LkongBookRecommendation, index: number): string => index.toString() + book.name)
        }.layoutWeight(1).width('100%')
      }
    }.width('100%').layoutWeight(1)
  }

  @Builder
  private buildBookRow(book: LkongBookRecommendation, index: number) {
    Column() {
      Row() {
        Text((index + 1).toString()).fontSize(11).fontColor(ThemeColors.onPrimary(this.isDark))
          .width(22).height(22).textAlign(TextAlign.Center).borderRadius(11)
          .backgroundColor(ThemeColors.primary(this.isDark)).margin({ right: 9 })
        Text(book.name).fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1)
        if (book.author) {
          Text(book.author).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ left: 8 })
        }
        Text($r('app.string.ui_ea0cb6560f')).fontSize(11).fontColor(ThemeColors.primary(this.isDark)).margin({ left: 8 })
      }.width('100%')
      Text(book.reason).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
        .lineHeight(19).margin({ top: 8 }).width('100%')
    }.width('100%').padding(13).margin({ left: 12, right: 12 })
      .backgroundColor(ThemeColors.surface(this.isDark)).borderRadius(11)
      .border({ width: 1, color: ThemeColors.outlineVariant(this.isDark) })
      .onClick((): void => { this.openSearch(book); })
  }
}
