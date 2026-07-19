/**
 * 搜索页面 — 对标 Android Legado
 * 功能：搜索建议、历史、书架提示、范围筛选、精确搜索、多源并发、按源分组、分页搜索
 */
import { AppDatabase } from '../data/database/AppDatabase';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { BookTable } from '../data/database/BookTable';
import { SearchKeywordTable } from '../data/database/SearchKeywordTable';
import { Book, BookGroup, BookType } from '../model/Book';
import { BookSource } from '../model/BookSource';
import { SearchResult, mergeSearchResults } from '../model/SearchResult';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { BookCover } from '../components/BookCover';
import { WebViewEngine } from '../components/WebViewEngine';
import { WebViewFetcher } from '../engine/web/WebViewFetcher';
import { SettingsStore } from '../data/preferences/SettingsStore';
import { NetUtil } from '../util/NetUtil';
import { UiUtil } from '../util/UiUtil';
import { ArrayDataSource } from '../util/ArrayDataSource';
import { ThemeColors } from '../theme/ThemeColors';
import { AiImportPreviewDialog, AiImportPreviewResult } from '../components/AiImportPreviewDialog';
import { AiBookImporter, ImportProgress, isSafeAiImportUrl } from '../engine/ai/AiBookImporter';
import { ChapterTable } from '../data/database/ChapterTable';
import { BookSourceResolver } from '../service/BookSourceResolver';
import { BookCacheService, CacheChapterItem } from '../service/BookCacheService';
import { BookChapter } from '../model/BookChapter';

interface OnlineSearchEngine {
  id: string;
  name: string;
}

const ONLINE_SEARCH_ENGINES: OnlineSearchEngine[] = [
  { id: 'bing', name: '必应' },
  { id: 'baidu', name: '百度' },
  { id: 'sogou', name: '搜狗' },
  { id: 'shenma', name: '神马' },
  { id: 'google', name: 'Google' },
];

const ONLINE_SEARCH_OPTIONS: SelectOption[] = ONLINE_SEARCH_ENGINES.map((item: OnlineSearchEngine): SelectOption => ({
  value: item.name,
}));

interface SearchSourceGroup {
  sourceName: string;
  sourceUrl: string;
  items: SearchResult[];
}

interface SourceTypeOption {
  value: number;
  label: string;
  count: number;
}

interface ParsedSearchScope {
  isSource: boolean;
  groups: string[];
  sourceUrls: string[];
}

@Entry
@Component
struct SearchPage {
  @State searchMode: number = 0; // 0=书源，1=在线
  @State keyword: string = '';
  @State committedKeyword: string = '';
  @StorageLink('isDark') isDark: boolean = false;
  @State allResults: SearchResult[] = [];
  @State @Watch('onResultsChanged_') results: SearchResult[] = [];
  @State isSearching: boolean = false;
  @State isLoadingMore: boolean = false;
  @State hasSearched: boolean = false;
  @State manualStop: boolean = false;
  @State hasMore: boolean = false;
  @State currentPage: number = 1;
  @State sources: BookSource[] = [];
  @State processedSources: number = 0;
  @State totalSources: number = 0;
  @State history: string[] = [];
  @State bookshelfHints: Book[] = [];
  @State showSuggestions: boolean = false;
  @State suppressSearchSuggestions: boolean = false;
  @State showScopeSheet: boolean = false;
  @State showSettingsSheet: boolean = false;
  @State showClearHistoryDialog: boolean = false;
  @State showRelaxFilterDialog: boolean = false;
  @State matchModeExact: boolean = false;
  @State layoutMode: number = 0; // 0=列表，1=按源分组
  @State selectedSourceTypes: number[] = [];
  @State selectedGroups: string[] = [];
  @State selectedSourceUrls: string[] = [];
  @State scopeBySource: boolean = false;
  @State sourceFilterText: string = '';
  @State expandedSourceUrl: string = '';
  @State shelfBookUrls: string[] = [];
  @State shelfNameAuthorKeys: string[] = [];
  @State showPreviewSheet: boolean = false;
  @State showExpandedSourceSheet: boolean = false;
  @State expandedSourceName: string = '';
  @State expandedSourceSheetUrl: string = '';
  @State expandedSourceBooks: SearchResult[] = [];
  @State expandedSourcePage: number = 1;
  @State expandedSourceLoading: boolean = false;
  @State expandedSourceHasMore: boolean = true;
  @State expandedSourceError: string = '';
  @State onlineEngine: string = 'bing';
  @State showOnlineBrowser: boolean = false;
  @State onlineBrowserUrl: string = '';
  @State onlineBrowserTitle: string = '';
  @State onlineDirectUrl: string = '';
  @State onlineBrowserFromDirect: boolean = false;
  @State onlineImporting: boolean = false;
  @State onlinePhase: string = '';
  @State onlineProgressText: string = '';
  @State onlineProgressCurrent: number = 0;
  @State onlineProgressTotal: number = 0;
  @State onlineErrorText: string = '';
  @State onlineResultText: string = '';

  private searchRunId: number = 0;
  private hintRunId: number = 0;
  private expandedSourceRunId: number = 0;
  private queryHintTimer: number = -1;
  private initialized: boolean = false;
  private previewItem: SearchResult | null = null;
  private resultDataSource_: ArrayDataSource<SearchResult> = new ArrayDataSource<SearchResult>();
  private onlineImporter_: AiBookImporter | null = null;
  private pageActive_: boolean = false;

  private onResultsChanged_(): void {
    this.resultDataSource_.reset(this.results);
  }

  aboutToAppear(): void {
    this.pageActive_ = true;
    this.onlineImporter_ = new AiBookImporter((progress: ImportProgress): void => {
      if (!this.pageActive_) return;
      this.onlinePhase = progress.phase;
      this.onlineProgressText = progress.message;
      this.onlineProgressCurrent = progress.current;
      this.onlineProgressTotal = progress.total;
      if (progress.phase === 'error') {
        this.onlineErrorText = progress.message;
        this.onlineImporting = false;
      } else if (progress.phase === 'done') {
        this.onlineResultText = progress.message;
        this.onlineImporting = false;
      }
    });
    this.initPage();
  }

  aboutToDisappear(): void {
   this.pageActive_ = false;
   this.onlineImporter_?.cancel();
   WebViewFetcher.cancelPending();
   if (this.queryHintTimer >= 0) {
      clearTimeout(this.queryHintTimer);
      this.queryHintTimer = -1;
    }
  }

  async initPage(): Promise<void> {
    if (this.initialized) {
      this.refreshShelfStates();
      return;
    }
    this.initialized = true;
    await AppDatabase.getInstance().waitForInit();
    await this.loadSearchPrefs();
    await this.loadSources();
    await this.loadHistory();
    await this.refreshShelfStates();
    await this.applyRouteParams();
  }

  async loadSearchPrefs(): Promise<void> {
    try {
      const s = SettingsStore.getInstance();
      await s.init(UiUtil.getHostContext(this.getUIContext()));
      this.layoutMode = await s.get<number>('search_layout_mode', 0);
      this.matchModeExact = (await s.get<number>('search_match_mode', 0)) === 1;
      this.selectedSourceTypes = await s.get<number[]>('search_source_types', []);
      this.applySearchScope(await s.get<string>('search_scope', ''), false);
      this.onlineEngine = this.normalizeOnlineEngine_(await s.get<string>('online_search_engine', 'bing'));
      console.info('[SearchPage] prefs loaded layout=' + this.layoutMode.toString()
        + ' exact=' + (this.matchModeExact ? 'true' : 'false')
        + ' typeFilter=' + JSON.stringify(this.selectedSourceTypes)
        + ' scope=' + this.getScopeLabel());
    } catch (_e) { /* ignore */ }
  }

  async saveSearchPrefs(): Promise<void> {
    try {
      const s = SettingsStore.getInstance();
      await s.put('search_layout_mode', this.layoutMode);
      await s.put('search_match_mode', this.matchModeExact ? 1 : 0);
      await s.put('search_source_types', this.selectedSourceTypes);
      await s.put('search_scope', this.encodeSearchScope());
    } catch (_e) { /* ignore */ }
  }

  private normalizeOnlineEngine_(value: string): string {
    return ONLINE_SEARCH_ENGINES.some((item: OnlineSearchEngine): boolean => item.id === value) ? value : 'bing';
  }

  private onlineEngineIndex_(): number {
    const index = ONLINE_SEARCH_ENGINES.findIndex((item: OnlineSearchEngine): boolean => item.id === this.onlineEngine);
    return index >= 0 ? index : 0;
  }

  private onlineEngineName_(): string {
    const index = this.onlineEngineIndex_();
    return ONLINE_SEARCH_ENGINES[index].name;
  }

  private async selectOnlineEngine_(index: number): Promise<void> {
    if (index < 0 || index >= ONLINE_SEARCH_ENGINES.length) return;
    this.onlineEngine = ONLINE_SEARCH_ENGINES[index].id;
    try {
      const settings = SettingsStore.getInstance();
      await settings.init(UiUtil.getHostContext(this.getUIContext()));
      await settings.put('online_search_engine', this.onlineEngine);
    } catch (_e) { /* ignore */ }
  }

  private switchSearchMode_(mode: number): void {
    if (this.searchMode === mode) return;
    if (this.isSearching || this.isLoadingMore) this.stopSearch();
    this.searchMode = mode;
    this.suppressSearchSuggestions = false;
    this.showSuggestions = this.keyword.trim().length === 0 ? this.history.length > 0 : true;
    if (mode === 1) {
      this.bookshelfHints = [];
      this.showSettingsSheet = false;
      this.showScopeSheet = false;
    }
  }

  private submitCurrentSearch_(keyword?: string): void {
    const query = (keyword || this.keyword).trim();
    if (!query) return;
    if (this.searchMode === 1) {
      void this.openOnlineSearch_(query);
    } else {
      void this.doSearch(query);
    }
  }

  private onlineSearchUrl_(keyword: string): string {
    const query = `"${keyword}" 小说 在线阅读 目录 -电视剧 -动漫 -漫画`;
    const encoded = encodeURIComponent(query);
    switch (this.onlineEngine) {
      case 'baidu': return 'https://www.baidu.com/s?wd=' + encoded;
      case 'sogou': return 'https://www.sogou.com/web?query=' + encoded;
      case 'shenma': return 'https://m.sm.cn/s?q=' + encoded;
      case 'google': return 'https://www.google.com/search?q=' + encoded;
      case 'bing':
      default: return 'https://cn.bing.com/search?q=' + encoded;
    }
  }

  private async openOnlineSearch_(rawKeyword?: string): Promise<void> {
    const query = (rawKeyword || this.keyword).trim();
    if (!query) {
      UiUtil.showToast(this.getUIContext(), { message: '请输入书名', duration: 1500 });
      return;
    }
    this.keyword = query;
    this.dismissSearchInput_();
    await this.addToHistory(query);
    this.onlineBrowserUrl = this.onlineSearchUrl_(query);
    this.onlineBrowserTitle = this.onlineEngineName_() + ' · ' + query;
    this.onlineBrowserFromDirect = false;
    this.showOnlineBrowser = true;
  }

  private openDirectOnlineUrl_(): void {
    const url = this.onlineDirectUrl.trim();
    if (!url) {
      UiUtil.showToast(this.getUIContext(), { message: '请输入小说详情页或目录页网址', duration: 1500 });
      return;
    }
    if (!isSafeAiImportUrl(url)) {
      UiUtil.showToast(this.getUIContext(), { message: '请输入有效的公网 HTTP(S) 网址', duration: 2000 });
      return;
    }
    this.dismissSearchInput_();
    this.onlineDirectUrl = url;
    this.onlineBrowserUrl = url;
    this.onlineBrowserTitle = '确认导入网页';
    this.onlineBrowserFromDirect = true;
    this.showOnlineBrowser = true;
  }

  private isOnlineSearchPage_(url: string): boolean {
    const lower = url.toLowerCase();
    return (lower.includes('bing.com/search'))
      || (lower.includes('baidu.com/s'))
      || (lower.includes('sogou.com/web') || lower.includes('m.sogou.com/web'))
      || (lower.includes('sm.cn/s'))
      || (lower.includes('google.') && lower.includes('/search'));
  }

  private confirmOnlinePage_(result: AiImportPreviewResult): void {
    if (this.isOnlineSearchPage_(result.url)) {
      UiUtil.showToast(this.getUIContext(), { message: '请先打开具体小说的详情页或目录页', duration: 2200 });
      return;
    }
    if (!isSafeAiImportUrl(result.url)) {
      UiUtil.showToast(this.getUIContext(), { message: '当前网页不可导入', duration: 1800 });
      return;
    }
    this.dismissSearchInput_();
    this.showOnlineBrowser = false;
    void this.startOnlineImport_(result.url, result.html);
  }

  /** 防止 WebView 浮层关闭或系统对话框弹出时，焦点自动回到搜索框并展开历史。 */
  private dismissSearchInput_(): void {
    this.suppressSearchSuggestions = true;
    this.showSuggestions = false;
    this.bookshelfHints = [];
    try {
      this.getUIContext().getFocusController().clearFocus();
    } catch (_e) { /* 当前窗口尚未建立焦点链时无需处理 */ }
  }

  private async startOnlineImport_(url: string, html: string): Promise<void> {
    this.onlineImporting = true;
    this.onlineErrorText = '';
    this.onlineResultText = '';
    try {
      if (!this.onlineImporter_) throw new Error('导入器未初始化');
      const ready = await this.onlineImporter_.init(UiUtil.getHostContext(this.getUIContext()));
      if (!ready) throw new Error('请先在 AI 配置中设置 LLM API');
      const result = await this.onlineImporter_.import(url, html);
      this.onlineResultText = `导入成功！已生成 ${result.chapterCount} 章目录`;
      this.onlineImporting = false;
      this.askOnlineBackgroundCache_(result.bookId, result.chapterCount);
    } catch (e) {
      this.onlineErrorText = '导入失败：' + ((e as Error).message || '');
      this.onlineImporting = false;
    }
  }

  private askOnlineBackgroundCache_(bookId: number, chapterCount: number): void {
    UiUtil.showDialog(this.getUIContext(), {
      title: '目录导入完成',
      message: `已生成 ${chapterCount} 章目录。可以在阅读时按需加载，或现在开始后台缓存全书。`,
      buttons: [
        { text: '稍后缓存', color: ThemeColors.secondaryText(this.isDark) },
        { text: '立即后台缓存', color: ThemeColors.primary(this.isDark) }
      ]
    }).then((result): void => {
      if (result.index === 1) void this.startOnlineBackgroundCache_(bookId);
    });
  }

  private async startOnlineBackgroundCache_(bookId: number): Promise<void> {
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const book = await new BookTable(db).getBookById(bookId);
      if (!book) throw new Error('书籍不存在');
      const source = await BookSourceResolver.resolve(book);
      if (!source) throw new Error('AI 解析档案不可用');
      const chapters = await new ChapterTable(db).getChaptersByBookId(bookId);
      const items: CacheChapterItem[] = chapters.map((chapter: BookChapter): CacheChapterItem => ({
        index: chapter.index, title: chapter.title, url: chapter.url,
      }));
      this.onlineResultText = `已在后台缓存《${book.name}》，可在离线缓存页查看进度`;
      BookCacheService.getInstance().cacheBook({
        bookId: book.id,
        bookName: book.name,
        bookUrl: book.bookUrl,
        source: source,
        chapters: items,
        startIndex: 0,
        endIndex: Math.max(0, items.length - 1),
        context: UiUtil.getHostContext(this.getUIContext()),
      }).catch((e: Error): void => { console.warn('[OnlineImport] background cache failed:', e.message); });
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: '启动后台缓存失败：' + (e as Error).message, duration: 2000 });
    }
  }

  private onlinePhaseLabel_(): string {
    switch (this.onlinePhase) {
      case 'fetch': return '抓取页面';
      case 'analyze_toc': return '分析目录';
      case 'analyze_content': return '分析正文';
      case 'download': return '下载章节';
      case 'done': return '完成';
      case 'error': return '出错';
      default: return '';
    }
  }

  async loadHistory(): Promise<void> {
    try {
      const table = new SearchKeywordTable(AppDatabase.getInstance().rdbStore);
      let items = await table.getRecent(30);
      if (items.length === 0) {
        const s = SettingsStore.getInstance();
        await s.init(UiUtil.getHostContext(this.getUIContext()));
        const legacy = await s.getSearchHistory();
        for (const word of legacy) {
          await table.save(word);
        }
        items = await table.getRecent(30);
      }
      this.history = items.map(item => item.word);
      // 最近输入只在用户主动点击搜索框时展开，避免页面或浮层重建时遮挡对话框。
      this.showSuggestions = false;
    } catch (_e) { this.history = []; }
  }

  async saveHistory(): Promise<void> {
    // 主搜索历史已迁移到 SearchKeywordTable；保留空实现避免旧调用产生双写。
  }

  async addToHistory(kw: string): Promise<void> {
    const q = kw.trim();
    if (!q) return;
    try {
      const table = new SearchKeywordTable(AppDatabase.getInstance().rdbStore);
      await table.save(q);
      await table.trimHistory(100);
      this.history = (await table.getRecent(30)).map(item => item.word);
    } catch (_e) {
      this.history = [q, ...this.history.filter((h: string) => h !== q)].slice(0, 30);
    }
  }

  async removeHistory(idx: number): Promise<void> {
    // STATE-002: use filter instead of splice to trigger re-render
    const word = this.history[idx] || '';
    const next: string[] = [];
    for (let i = 0; i < this.history.length; i++) {
      if (i !== idx) next.push(this.history[i]);
    }
    this.history = next;
    try {
      if (word) {
        const table = new SearchKeywordTable(AppDatabase.getInstance().rdbStore);
        await table.delete(word);
      }
    } catch (_e) { /* ignore */ }
    this.showSuggestions = this.keyword.trim().length > 0 || this.history.length > 0 || this.bookshelfHints.length > 0;
  }

  async clearHistory(): Promise<void> {
    this.history = [];
    try {
      const table = new SearchKeywordTable(AppDatabase.getInstance().rdbStore);
      await table.deleteAll();
      const s = SettingsStore.getInstance();
      await s.init(UiUtil.getHostContext(this.getUIContext()));
      await s.setSearchHistory([]);
    } catch (_e) { /* ignore */ }
    this.showClearHistoryDialog = false;
    this.showSuggestions = this.keyword.trim().length > 0 && this.bookshelfHints.length > 0;
  }

  async loadSources(): Promise<void> {
    try {
      await AppDatabase.getInstance().waitForInit();
      const dao = new BookSourceTable(AppDatabase.getInstance().rdbStore);
      this.sources = await dao.getEnabledSources();
    } catch (_e) { this.sources = []; }
  }

  async refreshShelfStates(): Promise<void> {
    try {
      await AppDatabase.getInstance().waitForInit();
      const table = new BookTable(AppDatabase.getInstance().rdbStore);
      const books = await table.getAllShelfBooks();
      this.shelfBookUrls = books.map((b: Book): string => b.bookUrl).filter((url: string): boolean => url.length > 0);
      this.shelfNameAuthorKeys = books.map((b: Book): string => this.nameAuthorKey(b.name, b.author));
    } catch (_e) {
      this.shelfBookUrls = [];
      this.shelfNameAuthorKeys = [];
    }
  }

  async loadBookshelfHints(raw: string): Promise<void> {
    const q = raw.trim();
    const runId = ++this.hintRunId;
    if (!q) {
      this.bookshelfHints = [];
      return;
    }
    try {
      await AppDatabase.getInstance().waitForInit();
      const table = new BookTable(AppDatabase.getInstance().rdbStore);
      const books = await table.searchBooks(q);
      if (runId !== this.hintRunId) return;
      this.bookshelfHints = books.filter((b: Book): boolean => b.isShelf).slice(0, 8);
    } catch (_e) {
      if (runId === this.hintRunId) this.bookshelfHints = [];
    }
  }

  async applyRouteParams(): Promise<void> {
    try {
      const params = UiUtil.getParams(this.getUIContext()) as Record<string, Object>;
      if (!params) return;
      const modeRaw = String(params['searchMode'] || params['mode'] || '').toLowerCase();
      this.searchMode = modeRaw === 'online' || modeRaw === '1' ? 1 : 0;
      const scopeRaw = String(params['searchScope'] || params['scope'] || '');
      if (scopeRaw) {
        this.applySearchScope(scopeRaw, false);
      }
      const key = String(params['key'] || params['keyword'] || '');
      if (key.trim()) {
        this.keyword = key.trim();
        this.showSuggestions = false;
        if (this.searchMode === 1) await this.openOnlineSearch_(key);
        else await this.doSearch(key);
      }
    } catch (_e) { /* ignore */ }
  }

  hasRelaxableFilters(): boolean {
    return this.selectedGroups.length > 0
      || this.selectedSourceUrls.length > 0
      || this.selectedSourceTypes.length > 0
      || this.matchModeExact;
  }

  async relaxFiltersAndSearch(mode: number): Promise<void> {
    if (mode === 0 || mode === 2) {
      this.matchModeExact = false;
    }
    if (mode === 1 || mode === 2) {
      this.selectedSourceTypes = [];
      this.selectAllScope();
    }
    this.showRelaxFilterDialog = false;
    await this.saveSearchPrefs();
    this.doSearch(this.committedKeyword || this.keyword);
  }

  onQueryChanged(v: string): void {
    this.keyword = v;
    this.suppressSearchSuggestions = false;
    const q = v.trim();
    this.showSuggestions = !this.hasSearched || q !== this.committedKeyword;
    if (this.queryHintTimer >= 0) clearTimeout(this.queryHintTimer);
    if (this.searchMode === 1) {
      this.bookshelfHints = [];
      return;
    }
    this.queryHintTimer = setTimeout(() => {
      this.queryHintTimer = -1;
      this.loadBookshelfHints(this.keyword.trim());
    }, 200);
  }

  shouldShowSuggestions(): boolean {
    if (this.suppressSearchSuggestions) return false;
    if (this.searchMode === 1) return this.showSuggestions && !this.onlineImporting;
    return this.showSuggestions
      && !this.isSearching
      && !this.isLoadingMore
      && (!this.hasSearched || this.keyword.trim() !== this.committedKeyword);
  }

  normalize(value: string): string {
    return (value || '')
      .toLowerCase()
      .replace(/[《》「」『』【】[\]（）()]/g, '')
      .replace(/[\s·・•:：,，。！？、…—\-_~～|｜]+/g, '');
  }

  nameAuthorKey(name: string, author: string): string {
    return this.normalize(name) + '|' + this.normalize(author);
  }

  isExactMatched(item: SearchResult, keyword: string): boolean {
    return this.getSearchPriority(item, keyword) <= 2;
  }

  filterResultsByMode(items: SearchResult[], keyword: string): SearchResult[] {
    const source = this.matchModeExact
      ? items.filter((item: SearchResult): boolean => this.isExactMatched(item, keyword))
      : items;
    const sorted = source.slice().sort((a: SearchResult, b: SearchResult): number => {
      const pa = this.getSearchPriority(a, keyword);
      const pb = this.getSearchPriority(b, keyword);
      if (pa !== pb) return pa - pb;
      if (a.sourceCount !== b.sourceCount) return b.sourceCount - a.sourceCount;
      return (a.name || '').localeCompare(b.name || '');
    });
    if (this.matchModeExact) {
      console.info('[SearchPage] exact filter keyword=' + keyword + ' raw=' + items.length.toString() + ' shown=' + sorted.length.toString());
    }
    return sorted;
  }

  getSearchPriority(item: SearchResult, keyword: string): number {
    const q = this.normalize(keyword);
    if (!q) return 3;
    const name = this.normalize(item.name);
    const author = this.normalize(item.author);
    const kind = this.normalize(item.kind);
    if (name === q || author === q) return 0;
    if (kind.includes(q)) return 1;
    if (name.includes(q) || author.includes(q)) return 2;
    return 3;
  }

  sourceGroupsOf(source: BookSource): string[] {
    const raw = source.group || '';
    return raw.split(/[,，;；|｜\n\r\t]+/).map((g: string): string => g.trim()).filter((g: string): boolean => g.length > 0);
  }

  getSourceGroupNames(): string[] {
    const names: string[] = [];
    this.sources.forEach((source: BookSource) => {
      this.sourceGroupsOf(source).forEach((group: string) => {
        if (!names.includes(group)) names.push(group);
      });
    });
    return names.sort();
  }

  getSourceTypeOptions(): SourceTypeOption[] {
    const options: SourceTypeOption[] = [];
    this.sources.forEach((source: BookSource) => {
      const existing = options.find((item: SourceTypeOption): boolean => item.value === source.sourceType);
      if (existing) {
        existing.count++;
      } else {
        options.push({
          value: source.sourceType,
          label: this.sourceTypeLabel(source.sourceType),
          count: 1
        });
      }
    });
    return options.sort((a: SourceTypeOption, b: SourceTypeOption): number => a.value - b.value);
  }

  sourceTypeLabel(type: number): string {
    if (type === 0) return '小说';
    if (type === 1) return '音频';
    if (type === 2) return '漫画';
    return '类型' + type.toString();
  }

  sourceInSelectedGroups(source: BookSource): boolean {
    if (this.selectedGroups.length === 0) return true;
    const groups = this.sourceGroupsOf(source);
    return this.selectedGroups.some((group: string): boolean => groups.includes(group));
  }

  getActiveSources(): BookSource[] {
    return this.sources.filter((source: BookSource): boolean => {
      if (!source.ruleSearchUrl) return false;
      if (this.selectedSourceTypes.length > 0 && !this.selectedSourceTypes.includes(source.sourceType)) return false;
      if (this.scopeBySource && this.selectedSourceUrls.length > 0) {
        return this.selectedSourceUrls.includes(source.sourceUrl);
      }
      if (!this.scopeBySource && this.selectedGroups.length > 0) {
        return this.sourceInSelectedGroups(source);
      }
      return true;
    });
  }

  getScopeLabel(): string {
    if (this.scopeBySource && this.selectedSourceUrls.length > 0) {
      const names = this.sources
        .filter((s: BookSource): boolean => this.selectedSourceUrls.includes(s.sourceUrl))
        .map((s: BookSource): string => s.sourceName);
      if (names.length === 1) return names[0];
      return names.length + '个书源';
    }
    if (!this.scopeBySource && this.selectedGroups.length > 0) {
      if (this.selectedGroups.length === 1) return this.selectedGroups[0];
      return this.selectedGroups.length + '个分组';
    }
    return '全部书源';
  }

  getFilteredSourcesForSheet(): BookSource[] {
    const q = this.sourceFilterText.trim().toLowerCase();
    if (!q) return this.sources;
    return this.sources.filter((source: BookSource): boolean => {
      return source.sourceName.toLowerCase().includes(q)
        || source.sourceUrl.toLowerCase().includes(q)
        || (source.group || '').toLowerCase().includes(q);
    });
  }

  toggleSourceType(value: number): void {
    if (this.selectedSourceTypes.includes(value)) {
      this.selectedSourceTypes = this.selectedSourceTypes.filter((item: number): boolean => item !== value);
    } else {
      this.selectedSourceTypes = [...this.selectedSourceTypes, value];
    }
    this.saveSearchPrefs();
    this.restartCommittedSearchIfNeeded();
  }

  setMatchModeExact(exact: boolean): void {
    if (this.matchModeExact === exact) return;
    this.matchModeExact = exact;
    this.saveSearchPrefs();
    this.restartCommittedSearchIfNeeded();
    if (this.hasSearched && this.committedKeyword && this.manualStop) {
      this.results = this.filterResultsByMode(this.allResults.length > 0 ? this.allResults : this.results, this.committedKeyword);
    }
  }

  setLayoutMode(mode: number): void {
    if (this.layoutMode === mode) return;
    this.layoutMode = mode;
    if (mode === 0) this.expandedSourceUrl = '';
    this.saveSearchPrefs();
  }

  finishScopeSheet(): void {
    this.showScopeSheet = false;
    this.saveSearchPrefs();
    this.restartCommittedSearchIfNeeded();
  }

  toggleGroup(group: string): void {
    this.scopeBySource = false;
    this.selectedSourceUrls = [];
    if (this.selectedGroups.includes(group)) {
      this.selectedGroups = this.selectedGroups.filter((item: string): boolean => item !== group);
    } else {
      this.selectedGroups = [...this.selectedGroups, group];
    }
    this.saveSearchPrefs();
  }

  toggleSource(source: BookSource): void {
    this.scopeBySource = true;
    this.selectedGroups = [];
    if (this.selectedSourceUrls.includes(source.sourceUrl)) {
      this.selectedSourceUrls = this.selectedSourceUrls.filter((item: string): boolean => item !== source.sourceUrl);
    } else {
      this.selectedSourceUrls = [...this.selectedSourceUrls, source.sourceUrl];
    }
    this.saveSearchPrefs();
  }

  selectAllScope(): void {
    this.scopeBySource = false;
    this.selectedGroups = [];
    this.selectedSourceUrls = [];
    this.saveSearchPrefs();
  }

  encodeSearchScope(): string {
    if (this.scopeBySource && this.selectedSourceUrls.length > 0) {
      const parts = this.sources
        .filter((source: BookSource): boolean => this.selectedSourceUrls.includes(source.sourceUrl))
        .map((source: BookSource): string => '{"name":' + JSON.stringify(source.sourceName.replace(/[:,]/g, '')) + ',"url":' + JSON.stringify(source.sourceUrl) + '}');
      return '{"type":"source","sources":[' + parts.join(',') + ']}';
    }
    if (!this.scopeBySource && this.selectedGroups.length > 0) {
      return '{"type":"group","groups":' + JSON.stringify(this.selectedGroups) + '}';
    }
    return '';
  }

  parseSearchScope(raw: string): ParsedSearchScope {
    const trimmed = (raw || '').trim();
    if (!trimmed) return { isSource: false, groups: [], sourceUrls: [] };
    try {
      const obj = JSON.parse(trimmed) as Record<string, Object>;
      const type = String(obj['type'] || '');
      if (type === 'source') {
        const sources = (obj['sources'] || []) as Array<Record<string, Object>>;
        return {
          isSource: true,
          groups: [],
          sourceUrls: sources.map((source: Record<string, Object>): string => String(source['url'] || '')).filter((url: string): boolean => url.length > 0)
        };
      }
      if (type === 'group') {
        const groups = (obj['groups'] || []) as string[];
        return {
          isSource: false,
          groups: groups.map((group: string): string => String(group || '').trim()).filter((group: string): boolean => group.length > 0),
          sourceUrls: []
        };
      }
    } catch (_e) { /* fallback to legacy format */ }

    const rawItems = trimmed.split(',').map((item: string): string => item.trim()).filter((item: string): boolean => item.length > 0);
    const legacySources = rawItems
      .filter((item: string): boolean => item.includes('::'))
      .map((item: string): string => item.substring(item.indexOf('::') + 2))
      .filter((url: string): boolean => url.length > 0);
    if (legacySources.length > 0 && legacySources.length === rawItems.length) {
      return { isSource: true, groups: [], sourceUrls: legacySources };
    }
    return { isSource: false, groups: rawItems, sourceUrls: [] };
  }

  applySearchScope(raw: string, persist: boolean = true): void {
    const parsed = this.parseSearchScope(raw);
    this.scopeBySource = parsed.isSource;
    this.selectedGroups = parsed.isSource ? [] : parsed.groups;
    this.selectedSourceUrls = parsed.isSource ? parsed.sourceUrls : [];
    if (persist) this.saveSearchPrefs();
  }

  restartCommittedSearchIfNeeded(): void {
    if (this.committedKeyword && this.hasSearched && !this.showSuggestions && !this.manualStop) {
      this.doSearch(this.committedKeyword);
    }
  }

  stopSearch(): void {
    if (!this.isSearching && !this.isLoadingMore) return;
    this.searchRunId++;
    this.manualStop = true;
    this.isSearching = false;
    this.isLoadingMore = false;
    this.hasMore = this.results.length > 0;
    UiUtil.showToast(this.getUIContext(), { message: '已停止搜索', duration: 1200 });
  }

  async doSearch(kw?: string): Promise<void> {
    const q = (kw || this.keyword).trim();
    if (!q) return;
    const searchable = this.getActiveSources();
    if (searchable.length === 0) {
      UiUtil.showToast(this.getUIContext(), { message: '当前范围没有可搜索书源', duration: 1500 });
      return;
    }
    const runId = ++this.searchRunId;
    this.keyword = q;
    this.committedKeyword = q;
    this.currentPage = 1;
    this.manualStop = false;
    this.hasMore = false;
    this.isSearching = true;
    this.isLoadingMore = false;
    this.hasSearched = true;
    this.showSuggestions = false;
    this.showScopeSheet = false;
    this.showSettingsSheet = false;
    this.showExpandedSourceSheet = false;
    this.expandedSourceUrl = '';
    this.allResults = [];
    this.results = [];
    this.processedSources = 0;
    this.totalSources = searchable.length;
    await this.addToHistory(q);
    console.info('[SearchPage] start q=' + q
      + ' exact=' + (this.matchModeExact ? 'true' : 'false')
      + ' activeSources=' + searchable.length.toString()
      + ' totalSources=' + this.sources.length.toString()
      + ' typeFilter=' + JSON.stringify(this.selectedSourceTypes)
      + ' scope=' + this.getScopeLabel());
    try {
      const merged = await globalSourceExecutor.search(q, searchable,
        (partial: SearchResult[], done: number, total: number) => {
          if (runId !== this.searchRunId || this.manualStop) return;
          this.processedSources = done;
          this.totalSources = total;
          this.allResults = partial;
          this.results = this.filterResultsByMode(this.allResults, q);
          console.info('[SearchPage] progress q=' + q
            + ' done=' + done.toString() + '/' + total.toString()
            + ' raw=' + this.allResults.length.toString()
            + ' shown=' + this.results.length.toString()
            + ' exact=' + (this.matchModeExact ? 'true' : 'false'));
        }, 1);
      if (runId !== this.searchRunId || this.manualStop) return;
      this.allResults = merged;
      this.results = this.filterResultsByMode(this.allResults, q);
      console.info('[SearchPage] finish q=' + q
        + ' raw=' + this.allResults.length.toString()
        + ' shown=' + this.results.length.toString()
        + ' exact=' + (this.matchModeExact ? 'true' : 'false')
        + ' first=' + this.results.slice(0, 5).map((r: SearchResult): string => r.name + '/' + r.sourceCount.toString()).join(','));
      const exactShouldStop = this.matchModeExact && this.currentPage === 1 && this.results.length <= 3;
      this.hasMore = merged.length > 0 && !exactShouldStop;
    } catch (_e) {
      if (runId === this.searchRunId) {
        UiUtil.showToast(this.getUIContext(), { message: '搜索失败', duration: 1500 });
      }
    }
    if (runId === this.searchRunId) {
      this.isSearching = false;
      this.processedSources = this.totalSources;
      if (this.results.length === 0 && this.hasRelaxableFilters()) {
        this.showRelaxFilterDialog = true;
      }
      this.refreshShelfStates();
      this.fetchMissingCovers();
    }
  }

  async loadMore(): Promise<void> {
    if (this.isSearching || this.isLoadingMore || !this.hasMore || !this.committedKeyword) return;
    const searchable = this.getActiveSources();
    if (searchable.length === 0) return;
    const nextPage = this.currentPage + 1;
    const runId = ++this.searchRunId;
    const baseResults = this.allResults.length > 0 ? this.allResults : this.results;
    const beforeCount = baseResults.length;
    this.isLoadingMore = true;
    this.manualStop = false;
    this.processedSources = 0;
    this.totalSources = searchable.length;
    try {
      const pageResults = await globalSourceExecutor.search(this.committedKeyword, searchable,
        (partial: SearchResult[], done: number, total: number) => {
          if (runId !== this.searchRunId || this.manualStop) return;
          this.processedSources = done;
          this.totalSources = total;
          this.allResults = mergeSearchResults([...baseResults, ...partial]);
          this.results = this.filterResultsByMode(this.allResults, this.committedKeyword);
        }, nextPage);
      if (runId !== this.searchRunId || this.manualStop) return;
      const mergedCount = this.allResults.length;
      if (pageResults.length === 0 || mergedCount <= beforeCount) {
        this.hasMore = false;
        UiUtil.showToast(this.getUIContext(), { message: '没有更多结果', duration: 1200 });
      } else {
        this.currentPage = nextPage;
        this.allResults = mergeSearchResults([...baseResults, ...pageResults]);
        this.results = this.filterResultsByMode(this.allResults, this.committedKeyword);
        this.hasMore = this.allResults.length > beforeCount;
        this.fetchMissingCovers();
      }
    } catch (_e) {
      if (runId === this.searchRunId) UiUtil.showToast(this.getUIContext(), { message: '加载更多失败', duration: 1500 });
    }
    if (runId === this.searchRunId) {
      this.isLoadingMore = false;
      this.processedSources = this.totalSources;
    }
  }

  openExpandedSourceSheet(group: SearchSourceGroup): void {
    this.expandedSourceRunId++;
    this.expandedSourceName = group.sourceName;
    this.expandedSourceSheetUrl = group.sourceUrl;
    this.expandedSourceBooks = group.items;
    this.expandedSourcePage = Math.max(1, this.currentPage);
    this.expandedSourceLoading = false;
    this.expandedSourceHasMore = !!this.committedKeyword;
    this.expandedSourceError = '';
    this.showExpandedSourceSheet = true;
  }

  mergeExpandedSourceItems(base: SearchResult[], incoming: SearchResult[]): SearchResult[] {
    const map = new Map<string, SearchResult>();
    for (const item of base) {
      map.set((item.noteUrl || item.key || item.name + item.author), item);
    }
    for (const item of incoming) {
      const key = item.noteUrl || item.key || item.name + item.author;
      if (!map.has(key)) map.set(key, item);
    }
    return Array.from(map.values());
  }

  async loadMoreExpandedSource(): Promise<void> {
    if (this.expandedSourceLoading || !this.expandedSourceHasMore || !this.committedKeyword) return;
    const source = this.sources.find((item: BookSource): boolean => item.sourceUrl === this.expandedSourceSheetUrl);
    if (!source) {
      this.expandedSourceError = '未找到该书源';
      this.expandedSourceHasMore = false;
      return;
    }
    const nextPage = this.expandedSourcePage + 1;
    const runId = ++this.expandedSourceRunId;
    const base = this.expandedSourceBooks;
    this.expandedSourceLoading = true;
    this.expandedSourceError = '';
    try {
      const pageResults = await globalSourceExecutor.search(this.committedKeyword, [source], undefined, nextPage);
      if (runId !== this.expandedSourceRunId) return;
      const merged = this.mergeExpandedSourceItems(base, pageResults);
      this.expandedSourceBooks = merged;
      this.expandedSourcePage = nextPage;
      if (pageResults.length === 0 || merged.length <= base.length) {
        this.expandedSourceHasMore = false;
        this.expandedSourceError = '没有更多结果';
      }
    } catch (_e) {
      if (runId === this.expandedSourceRunId) {
        this.expandedSourceError = '加载更多失败';
      }
    }
    if (runId === this.expandedSourceRunId) {
      this.expandedSourceLoading = false;
    }
  }

  /** 后台为没有封面的结果抓取详情页封面（并发 3） */
  async fetchMissingCovers(): Promise<void> {
    const noCover = this.results.filter((r: SearchResult) => !r.coverUrl && r.noteUrl);
    if (noCover.length === 0) return;
    let cursor = 0;
    const worker = async (): Promise<void> => {
      while (cursor < noCover.length) {
        const idx = cursor++;
        const r = noCover[idx];
        try {
          const html = await NetUtil.httpGet(r.noteUrl, {
            'Accept': 'text/html,*/*',
            'Referer': r.originUrl || r.noteUrl,
          }, 8000);
          if (!html) continue;
          let m = html.match(/<img[^>]*src=["']([^"']+\.(?:jpe?g|png|webp|gif|bmp))["']/i);
          if (!m) m = html.match(/<img[^>]*(?:src|data-src|data-original|data-lazy-src)=["']([^"']+)["']/i);
          if (!m) m = html.match(/background(?:-image)?\s*:\s*url\(['"]?([^'")\s]+)['"]?\)/i);
          if (m) {
            let url = m[1];
            if (url.startsWith('//')) url = 'https:' + url;
            if (!url.startsWith('http')) {
              const base = r.noteUrl.replace(/\/[^/]*$/, '');
              url = (base || '') + (url.startsWith('/') ? url : '/' + url);
            }
            if (url) {
              r.coverUrl = url;
              this.results = [...this.results];
            }
          }
        } catch (_e) { /* ignore */ }
      }
    };
    const workers: Promise<void>[] = [];
    for (let w = 0; w < Math.min(3, noCover.length); w++) workers.push(worker());
    await Promise.all(workers);
  }

  getShelfState(item: SearchResult): number {
    const urls = [item.noteUrl, ...(item.sourceNoteUrls || [])].filter((url: string): boolean => url.length > 0);
    if (urls.some((url: string): boolean => this.shelfBookUrls.includes(url))) return 1;
    if (this.shelfNameAuthorKeys.includes(this.nameAuthorKey(item.name, item.author))) return 2;
    return 0;
  }

  expandResultSources(item: SearchResult): SearchResult[] {
    const origins = item.sourceOrigins && item.sourceOrigins.length > 0 ? item.sourceOrigins : [item.origin];
    const originUrls = item.sourceOriginUrls || [];
    const noteUrls = item.sourceNoteUrls || [];
    return origins.map((origin: string, idx: number): SearchResult => {
      const originUrl = originUrls[idx] || item.originUrl;
      const noteUrl = noteUrls[idx] || item.noteUrl;
      return {
        key: (originUrl || item.originUrl || '') + '|' + (noteUrl || item.noteUrl || '') + '|' + idx.toString(),
        name: item.name,
        author: item.author,
        coverUrl: item.coverUrl,
        kind: item.kind,
        wordCount: item.wordCount,
        lastUpdateTime: item.lastUpdateTime,
        latestChapterTitle: item.latestChapterTitle,
        introduce: item.introduce,
        helperMsg: item.helperMsg,
        duration: item.duration,
        searchTime: item.searchTime,
        origin: origin || item.origin,
        originUrl: originUrl,
        noteUrl: noteUrl,
        sourceCount: 1,
        sourceOrigins: [origin || item.origin],
        sourceOriginUrls: [originUrl],
        sourceNoteUrls: [noteUrl],
      };
    });
  }

  getSourceGroups(): SearchSourceGroup[] {
    const map = new Map<string, SearchSourceGroup>();
    this.results.forEach((item: SearchResult) => {
      this.expandResultSources(item).forEach((sourceItem: SearchResult) => {
        const key = sourceItem.originUrl || sourceItem.origin || 'unknown';
        let group = map.get(key);
        if (!group) {
          group = { sourceName: sourceItem.origin || '未知书源', sourceUrl: key, items: [] };
          map.set(key, group);
        }
        group.items.push(sourceItem);
      });
    });
    return Array.from(map.values());
  }

  getPreviewItems(items: SearchResult[], expanded: boolean): SearchResult[] {
    if (expanded || items.length <= 6) return items;
    return items.slice(0, 6);
  }

 splitKind(kind: string): string[] {
   return (kind || '').split(/[,，;；|｜\s]+/).map((item: string): string => item.trim()).filter((item: string): boolean => item.length > 0).slice(0, 4);
 }
 
   formatWordCount(wordCount: string): string {
     if (!wordCount) return '';
     // 已经带文字（如 "12万字"）直接返回
     if (/[^\d]/.test(wordCount)) return wordCount;
     const num = parseInt(wordCount, 10);
     if (isNaN(num)) return '';
     if (num >= 10000) return Math.floor(num / 10000) + '万字';
     if (num >= 1000) return Math.floor(num / 1000) + '千字';
     return num + '字';
   }

 goToBookInfo(item: SearchResult): void {
    UiUtil.pushUrl(this.getUIContext(), { url: 'pages/BookInfoPage', params: {
      name: item.name, author: item.author, coverUrl: item.coverUrl,
      noteUrl: item.noteUrl, origin: item.origin, originUrl: item.originUrl,
      introduce: item.introduce || '', kind: item.kind || '',
      sourceCount: item.sourceCount, sourceOrigins: JSON.stringify(item.sourceOrigins || []),
      sourceOriginUrls: JSON.stringify(item.sourceOriginUrls || []),
      sourceNoteUrls: JSON.stringify(item.sourceNoteUrls || []),
      cachedSources: JSON.stringify(this.results),
    }});
  }

  goToShelfBook(book: Book): void {
    UiUtil.pushUrl(this.getUIContext(), { url: 'pages/BookInfoPage', params: {
      id: book.id,
      name: book.name,
      author: book.author,
      coverUrl: book.coverUrl || book.customCoverPath,
      customCoverPath: book.customCoverPath,
      noteUrl: book.bookUrl,
      bookUrl: book.bookUrl,
      origin: book.origin,
      originUrl: book.originUrl,
      introduce: book.introduce || '',
      kind: book.kind || '',
      lastUpdateTime: book.lastUpdateTime || '',
      latestChapterTitle: book.latestChapterTitle || '',
    }});
  }

  showPreview(item: SearchResult): void {
    this.previewItem = item;
    this.showPreviewSheet = true;
  }

  async addPreviewToShelf(): Promise<void> {
    const item = this.previewItem;
    if (!item) return;
    try {
      await AppDatabase.getInstance().waitForInit();
      const bookTable = new BookTable(AppDatabase.getInstance().rdbStore);
      const now = Date.now();
      const existing = item.noteUrl ? await bookTable.getBookByUrl(item.noteUrl) : null;
      if (existing) {
        existing.isShelf = true;
        existing.coverUrl = existing.coverUrl || item.coverUrl;
        existing.kind = existing.kind || item.kind;
        existing.wordCount = existing.wordCount || item.wordCount;
        existing.introduce = existing.introduce || item.introduce;
        existing.origin = existing.origin || item.origin;
        existing.originUrl = existing.originUrl || item.originUrl;
        existing.latestChapterTitle = existing.latestChapterTitle || item.latestChapterTitle;
        existing.updateTime = now;
        await bookTable.updateBook(existing);
      } else {
        // 查询书源类型，判断是否为漫画源
        let isMangaSource = false;
        try {
          const srcDao = new BookSourceTable(AppDatabase.getInstance().rdbStore);
          const sources = await srcDao.getAllSources();
          const matchedSource = sources.find(s => s.sourceUrl === item.originUrl || s.sourceName === item.origin);
          if (matchedSource && matchedSource.sourceType === 2) isMangaSource = true;
        } catch (_) { /* ignore */ }

        const book: Book = {
          id: 0,
          name: item.name,
          author: item.author,
          coverUrl: item.coverUrl,
          customCoverPath: '',
          bookUrl: item.noteUrl,
          origin: item.origin,
          originUrl: item.originUrl,
          type: isMangaSource ? BookType.MANGA : BookType.TEXT,
          groupId: BookGroup.ALL,
          tocUrl: '',
          chapterCount: 0,
          totalChapterNum: 0,
          latestChapterTitle: item.latestChapterTitle || '',
          durChapterTitle: '',
          durChapterIndex: 0,
          durChapterPos: 0,
          durChapterProgress: 0,
          isRead: false,
          isAudio: false,
          isManga: isMangaSource,
          isShelf: true,
          order: 0,
          canUpdate: true,
          kind: item.kind,
          wordCount: item.wordCount,
          introduce: item.introduce,
          remark: '',
          lastUpdateTime: item.lastUpdateTime,
          lastOpenTime: 0,
          createTime: now,
          updateTime: now,
          syncTime: 0,
        };
        await bookTable.insertBook(book);
      }
      this.showPreviewSheet = false;
      this.refreshShelfStates();
      AppStorage.set<number>('shelfRefreshCounter', (AppStorage.get<number>('shelfRefreshCounter') || 0) + 1);
      UiUtil.showToast(this.getUIContext(), { message: '已加入书架', duration: 1500 });
    } catch (_e) {
      UiUtil.showToast(this.getUIContext(), { message: '加入书架失败', duration: 1500 });
    }
  }

  primaryColor(): string { return ThemeColors.primary(this.isDark); }
  bgColor(): string { return ThemeColors.background(this.isDark); }
  surfaceColor(): string { return ThemeColors.surface(this.isDark); }
  surfaceAltColor(): string { return ThemeColors.surfaceVariant(this.isDark); }
  textColor(): string { return ThemeColors.onBackground(this.isDark); }
  subTextColor(): string { return ThemeColors.secondaryText(this.isDark); }
  lineColor(): string { return ThemeColors.outlineVariant(this.isDark); }

  build() {
    Stack() {
      Column() {
        this.buildTopArea()
        if (this.searchMode === 0) this.buildScopeStrip()
        Stack({ alignContent: Alignment.TopStart }) {
          this.buildBody()
        }
        .layoutWeight(1)
        .width('100%')
        WebViewEngine().width(1).height(1).visibility(Visibility.Hidden)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.bgColor())

      if (this.searchMode === 0 && (this.isSearching || this.isLoadingMore)) {
        Button(this.isSearching ? '■' : '+')
          .fontSize(20)
          .fontColor(ThemeColors.onPrimary(this.isDark))
          .width(56)
          .height(56)
          .borderRadius(28)
          .backgroundColor(this.isSearching ? ThemeColors.error(this.isDark) : this.primaryColor())
          .position({ right: 16, bottom: 24 })
          .onClick(() => {
            if (this.isSearching || this.isLoadingMore) {
              this.stopSearch();
            }
          })
      } else if (this.searchMode === 0 && this.hasSearched && this.hasMore && this.results.length > 0) {
        Button($r('app.string.ui_a979ef10cc'))
          .fontSize(24)
          .fontColor(ThemeColors.onPrimary(this.isDark))
          .width(56)
          .height(56)
          .borderRadius(28)
          .backgroundColor(this.primaryColor())
          .position({ right: 16, bottom: 24 })
          .onClick(() => { this.loadMore(); })
      }

      if (this.showSettingsSheet) {
        this.buildDimLayer(() => { this.showSettingsSheet = false; })
        this.buildSettingsSheet()
      }

      if (this.showScopeSheet) {
        this.buildDimLayer(() => { this.showScopeSheet = false; })
        this.buildScopeSheet()
      }

      if (this.showClearHistoryDialog) {
        this.buildDimLayer(() => { this.showClearHistoryDialog = false; })
        Stack({ alignContent: Alignment.Center }) {
          this.buildClearHistoryDialog()
        }.width('100%').height('100%')
      }

      if (this.showRelaxFilterDialog) {
        this.buildDimLayer(() => { this.showRelaxFilterDialog = false; })
        Stack({ alignContent: Alignment.Center }) {
          this.buildRelaxFilterDialog()
        }.width('100%').height('100%')
      }

      if (this.showPreviewSheet) {
        this.buildDimLayer(() => { this.showPreviewSheet = false; })
        this.buildPreviewSheet()
      }

      if (this.showExpandedSourceSheet) {
        this.buildDimLayer(() => {
          this.expandedSourceRunId++;
          this.showExpandedSourceSheet = false;
        })
        this.buildExpandedSourceSheet()
      }

      if (this.showOnlineBrowser) {
        Stack({ alignContent: Alignment.Center }) {
          Column().width('100%').height('100%').backgroundColor(ThemeColors.scrim(this.isDark))
          AiImportPreviewDialog({
            initialUrl: this.onlineBrowserUrl,
            titleText: this.onlineBrowserTitle,
            confirmText: '导入当前页',
            helperText: this.onlineBrowserFromDirect ?
              '请确认当前网页是小说详情页或目录页，再导入当前网页。' :
              '先在搜索结果中进入小说详情页或目录页，再导入当前网页。',
            dismissBeforeConfirm: false,
            onCancel: (): void => {
              this.showOnlineBrowser = false;
              this.onlineBrowserFromDirect = false;
            },
            onConfirm: (result: AiImportPreviewResult): void => { this.confirmOnlinePage_(result); }
          })
        }
        .width('100%').height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.bgColor())
  }

  @Builder buildTopArea() {
    Column() {
      Row() {
        Button($r('app.string.ui_c4dd3c8cdd'))
          .fontSize(20)
          .fontColor(this.textColor())
          .width(40)
          .height(40)
          .backgroundColor(ThemeColors.transparent())
          .onClick(() => { UiUtil.back(this.getUIContext()); })
        Text($r('app.string.common_search'))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.textColor())
          .layoutWeight(1)
        if (this.searchMode === 0) {
          this.buildIconAction('筛选', this.layoutMode === 1 || this.selectedSourceTypes.length > 0, () => {
            this.showSettingsSheet = true;
            this.showScopeSheet = false;
          })
          this.buildIconAction('=', this.matchModeExact, () => {
            this.setMatchModeExact(!this.matchModeExact);
          })
          this.buildIconAction('☰', this.selectedGroups.length > 0 || this.selectedSourceUrls.length > 0, () => {
            this.showScopeSheet = true;
            this.showSettingsSheet = false;
          })
        }
      }
      .width('100%')
      .height(48)
      .padding({ left: 8, right: 10 })
      .alignItems(VerticalAlign.Center)

      Row() {
        Button('书源')
          .layoutWeight(1).height(38).fontSize(14)
          .fontColor(this.searchMode === 0 ? ThemeColors.onPrimary(this.isDark) : this.textColor())
          .backgroundColor(this.searchMode === 0 ? this.primaryColor() : ThemeColors.transparent())
          .borderRadius(19)
          .onClick((): void => { this.switchSearchMode_(0); })
        Button('在线')
          .layoutWeight(1).height(38).fontSize(14)
          .fontColor(this.searchMode === 1 ? ThemeColors.onPrimary(this.isDark) : this.textColor())
          .backgroundColor(this.searchMode === 1 ? this.primaryColor() : ThemeColors.transparent())
          .borderRadius(19)
          .onClick((): void => { this.switchSearchMode_(1); })
      }
      .width('100%')
      .padding(3)
      .margin({ left: 16, right: 16, bottom: 10 })
      .backgroundColor(this.surfaceAltColor())
      .borderRadius(22)

      if (this.searchMode === 1) {
        Row() {
          Text('搜索引擎').fontSize(13).fontColor(this.subTextColor()).layoutWeight(1)
          Select(ONLINE_SEARCH_OPTIONS)
            .selected(this.onlineEngineIndex_())
            .value(this.onlineEngineName_())
            .height(40)
            .fontColor(this.primaryColor())
            .backgroundColor(this.surfaceAltColor())
            .onSelect((index: number): void => { void this.selectOnlineEngine_(index); })
        }
        .width('100%')
        .padding({ left: 18, right: 16, bottom: 8 })
      }

      Row() {
        Row() {
          Text($r('app.string.ui_1b0a1f59a5'))
            .fontSize(18)
            .fontColor(this.subTextColor())
            .width(34)
            .height(42)
            .textAlign(TextAlign.Center)
          TextInput({ placeholder: $r('app.string.ui_f9faaeaa8e'), text: this.keyword })
            .height(42)
            .layoutWeight(1)
            .backgroundColor(Color.Transparent)
            .fontSize(15)
            .fontColor(this.textColor())
            .placeholderColor(this.subTextColor())
            .padding({ left: 0 })
            .onChange((v: string) => { this.onQueryChanged(v); })
            .onSubmit(() => { this.submitCurrentSearch_(); })
            .onFocus(() => {
              if (!this.suppressSearchSuggestions &&
                (this.searchMode === 1 || !this.hasSearched || this.keyword.trim() !== this.committedKeyword)) {
                this.showSuggestions = this.keyword.trim().length > 0 || this.history.length > 0 || this.bookshelfHints.length > 0;
              }
            })
            .onClick(() => {
              // 点击代表用户主动编辑；此时才解除导入流程设置的历史面板抑制状态。
              this.suppressSearchSuggestions = false;
              if (!this.onlineImporting) {
                this.showSuggestions = this.keyword.trim().length > 0 || this.history.length > 0 || this.bookshelfHints.length > 0;
              }
            })
          if (this.keyword) {
            Text($r('app.string.ui_67fba2f357'))
              .fontSize(16)
              .fontColor(this.subTextColor())
              .width(34)
              .height(34)
              .textAlign(TextAlign.Center)
              .onClick(() => {
                this.keyword = '';
                this.bookshelfHints = [];
                this.showSuggestions = this.history.length > 0;
                if (!this.isSearching) {
                  this.allResults = [];
                  this.results = [];
                  this.hasSearched = false;
                  this.committedKeyword = '';
                }
              })
          }
        }
        .height(42)
        .layoutWeight(1)
        .backgroundColor(this.surfaceAltColor())
        .borderRadius(21)

        Button(this.searchMode === 0 && this.isSearching ? '停止' : '搜索')
          .fontSize(14)
          .fontColor(ThemeColors.onPrimary(this.isDark))
          .height(40)
          .padding({ left: 16, right: 16 })
          .backgroundColor(this.searchMode === 0 && this.isSearching ? ThemeColors.error(this.isDark) : this.primaryColor())
          .borderRadius(20)
          .margin({ left: 8 })
          .onClick(() => {
            if (this.searchMode === 0 && this.isSearching) this.stopSearch();
            else this.submitCurrentSearch_();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 10 })
    }
    .width('100%')
    .padding({ top: 42 })
    .backgroundColor(this.surfaceColor())
  }

  @Builder buildIconAction(label: string, selected: boolean, action: () => void) {
    Button(label)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor(selected ? ThemeColors.onPrimary(this.isDark) : this.textColor())
      .width(40)
      .height(40)
      .padding(0)
      .backgroundColor(selected ? this.primaryColor() : ThemeColors.transparent())
      .borderRadius(18)
      .margin({ left: 2 })
      .onClick(action)
  }

  @Builder buildScopeStrip() {
    Row() {
      this.buildTinyChip(this.getScopeLabel(), this.selectedGroups.length > 0 || this.selectedSourceUrls.length > 0, () => {
        this.showScopeSheet = true;
      })
      this.buildTinyChip(this.matchModeExact ? '精确匹配' : '普通匹配', this.matchModeExact, () => {
        this.setMatchModeExact(!this.matchModeExact);
      })
      if (this.selectedSourceTypes.length > 0) {
        this.buildTinyChip('已筛类型', true, () => { this.showSettingsSheet = true; })
      }
      Blank()
      Text(this.sources.length + '源')
        .fontSize(12)
        .fontColor(this.subTextColor())
    }
    .width('100%')
    .height(42)
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.surfaceColor())
    .border({ width: { top: 1 }, color: this.lineColor() })
  }

  @Builder buildTinyChip(label: string, selected: boolean, action: () => void) {
    Text(label)
      .fontSize(12)
      .fontColor(selected ? ThemeColors.onPrimary(this.isDark) : this.subTextColor())
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .backgroundColor(selected ? this.primaryColor() : this.surfaceAltColor())
      .borderRadius(14)
      .margin({ right: 8 })
      .onClick(action)
  }

  @Builder buildBody() {
    if (this.shouldShowSuggestions()) {
      this.buildSuggestionPanel()
    } else if (this.searchMode === 1) {
      this.buildOnlineBody_()
    } else if (this.hasSearched || this.isSearching || this.isLoadingMore) {
      Column() {
        this.buildFloatingSummary()
        if (this.results.length === 0 && !this.isSearching && !this.isLoadingMore) {
          this.buildEmptyResult()
        } else if (this.layoutMode === 1) {
          this.buildGroupedResults()
        } else {
          this.buildListResults()
        }
      }
      .height('100%')
      .width('100%')
      .justifyContent(FlexAlign.Start)
    } else {
      this.buildIdle()
    }
  }

  @Builder buildSuggestionPanel() {
    if (this.bookshelfHints.length === 0 && this.history.length === 0) {
      Column() {
        Text($r('app.string.ui_72077749f7'))
          .fontSize(42)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.subTextColor())
          .margin({ top: 24 })
        Text($r('app.string.ui_6685a5ea64'))
          .fontSize(15)
          .fontColor(this.subTextColor())
          .margin({ top: 8 })
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Center)
      .justifyContent(FlexAlign.Start)
      .backgroundColor(this.bgColor())
    } else {
      List({ space: 0 }) {
        if (this.searchMode === 0 && this.bookshelfHints.length > 0) {
          ListItem() {
            Row() {
              Text($r('app.string.ui_8986a5a260'))
                .fontSize(13)
                .fontColor(this.subTextColor())
                .layoutWeight(1)
              Text(this.bookshelfHints.length + '本')
                .fontSize(12)
                .fontColor(this.subTextColor())
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 14, bottom: 6 })
          }

          ForEach(this.bookshelfHints, (book: Book) => {
            ListItem() {
              Row() {
                BookCover({ name: book.name, coverUrl: book.coverUrl || book.customCoverPath, coverWidth: 42, coverHeight: 58, coverDecodeJs: book.coverDecodeJs || '' })
                  .margin({ right: 12 })
                Column() {
                  Text(book.name)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.textColor())
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text((book.author || '未知作者') + (book.latestChapterTitle ? ' · ' + book.latestChapterTitle : ''))
                    .fontSize(12)
                    .fontColor(this.subTextColor())
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 4 })
                }
                .layoutWeight(1)
                Text($r('app.string.ui_a6f11567e2'))
                  .fontSize(11)
                  .fontColor(this.primaryColor())
                  .padding({ left: 7, right: 7, top: 3, bottom: 3 })
                  .backgroundColor(ThemeColors.primaryContainer(this.isDark))
                  .borderRadius(4)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 8, bottom: 8 })
              .backgroundColor(this.surfaceColor())
              .onClick(() => { this.goToShelfBook(book); })
            }
          }, (book: Book): string => 'shelf_' + book.id.toString())
        }

        if (this.history.length > 0) {
          ListItem() {
            Row() {
              Text($r('app.string.ui_adf6d73a69'))
                .fontSize(13)
                .fontColor(this.subTextColor())
                .layoutWeight(1)
              Text('收起')
                .fontSize(12)
                .fontColor(this.primaryColor())
                .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                .onClick(() => {
                  this.suppressSearchSuggestions = true;
                  this.showSuggestions = false;
                  try {
                    this.getUIContext().getFocusController().clearFocus();
                  } catch (_e) { /* ignore */ }
                })
              Text($r('app.string.ui_2e9ab4934c'))
                .fontSize(12)
                .fontColor(ThemeColors.error(this.isDark))
                .onClick(() => { this.showClearHistoryDialog = true; })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 14, bottom: 4 })
          }

          ForEach(this.history, (h: string, idx: number) => {
            ListItem() {
              Row() {
                Text($r('app.string.ui_a34801ad9c'))
                  .fontSize(12)
                  .fontColor(this.subTextColor())
                  .width(24)
                Text(h)
                  .fontSize(15)
                  .fontColor(this.textColor())
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text($r('app.string.ui_11f6ad8ec5'))
                  .fontSize(14)
                  .fontColor(this.subTextColor())
                  .width(44)
                  .height(44)
                  .textAlign(TextAlign.Center)
                  .accessibilityText($r('app.string.common_delete'))
                  .onClick(() => { this.removeHistory(idx); })
              }
              .width('100%')
              .height(48)
              .padding({ left: 16, right: 10 })
              .backgroundColor(this.surfaceColor())
              .onClick(() => {
                this.keyword = h;
                this.showSuggestions = false;
                this.submitCurrentSearch_(h);
              })
            }
          }, (h: string, idx: number): string => h + idx.toString())
        }
      }
      .height('100%')
      .width('100%')
      .alignListItem(ListItemAlign.Start)
      .backgroundColor(this.bgColor())
    }
  }

  @Builder buildOnlineBody_() {
    Scroll() {
      Column({ space: 14 }) {
        Column({ space: 8 }) {
          Text('在线搜索导入')
            .width('100%')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.textColor())
          Text('输入书名后会在内置浏览器中搜索。请打开具体小说详情页或目录页，再点击“导入当前页”。')
            .width('100%')
            .fontSize(14)
            .lineHeight(21)
            .fontColor(this.subTextColor())
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(16)
        .backgroundColor(this.surfaceColor())
        .borderRadius(16)

        Row({ space: 10 }) {
          Text('当前引擎').fontSize(13).fontColor(this.subTextColor())
          Text(this.onlineEngineName_())
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryColor())
          Blank()
          Text('会记住上次选择').fontSize(12).fontColor(this.subTextColor())
        }
        .width('100%')
        .padding(14)
        .backgroundColor(this.surfaceAltColor())
        .borderRadius(14)

        Column({ space: 10 }) {
          Row() {
            Text('直接网址导入')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.textColor())
            Blank()
            Text('小说详情页 / 目录页')
              .fontSize(12)
              .fontColor(this.subTextColor())
          }
          .width('100%')

          TextArea({
            text: this.onlineDirectUrl,
            placeholder: 'https://example.com/book/123/'
          })
            .width('100%')
            .height(96)
            .fontSize(14)
            .fontColor(this.textColor())
            .placeholderColor(this.subTextColor())
            .caretColor(this.primaryColor())
            .padding(12)
            .backgroundColor(this.surfaceAltColor())
            .borderRadius(12)
            .border({ width: 1, color: ThemeColors.outlineVariant(this.isDark) })
            .onChange((value: string): void => { this.onlineDirectUrl = value; })

          Button('打开网址并确认导入')
            .width('100%')
            .height(48)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.onPrimary(this.isDark))
            .backgroundColor(this.primaryColor())
            .borderRadius(24)
            .enabled(!this.onlineImporting && this.onlineDirectUrl.trim().length > 0)
            .onClick((): void => { this.openDirectOnlineUrl_(); })
        }
        .width('100%')
        .padding(16)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor(this.surfaceColor())
        .borderRadius(16)
        .border({ width: 1, color: ThemeColors.outlineVariant(this.isDark) })

        if (this.onlineImporting || this.onlineResultText || this.onlineErrorText) {
          Column({ space: 10 }) {
            if (this.onlineImporting) {
              Row({ space: 10 }) {
                LoadingProgress().width(24).height(24).color(this.primaryColor())
                Column({ space: 3 }) {
                  Text(this.onlinePhaseLabel_())
                    .width('100%').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.textColor())
                  Text(this.onlineProgressText)
                    .width('100%').fontSize(12).fontColor(this.subTextColor())
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              }.width('100%')
              if (this.onlineProgressTotal > 0) {
                Progress({
                  value: this.onlineProgressCurrent,
                  total: this.onlineProgressTotal,
                  type: ProgressType.Linear,
                }).width('100%').color(this.primaryColor())
              }
            }
            if (this.onlineResultText) {
              Text(this.onlineResultText).width('100%').fontSize(14).fontColor(this.primaryColor())
            }
            if (this.onlineErrorText) {
              Text(this.onlineErrorText).width('100%').fontSize(14).fontColor(ThemeColors.error(this.isDark))
            }
          }
          .width('100%')
          .padding(16)
          .alignItems(HorizontalAlign.Start)
          .backgroundColor(this.surfaceColor())
          .borderRadius(16)
        }

        Text('最近输入会在搜索框获得焦点时显示，可直接点击再次搜索。')
          .width('100%')
          .fontSize(12)
          .lineHeight(18)
          .fontColor(this.subTextColor())
          .padding({ left: 4, right: 4 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 18, bottom: 30 })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
  }

  @Builder buildFloatingSummary() {
    if (this.hasSearched || this.isSearching || this.isLoadingMore) {
      Row() {
        if (this.isSearching || this.isLoadingMore) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color(this.primaryColor())
            .margin({ right: 6 })
        }
        Text(this.results.length + '个结果')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.textColor())
        if (this.totalSources > 0) {
          Text(' · ' + this.processedSources + '/' + this.totalSources + '源')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.textColor())
        }
        if (this.currentPage > 1) {
          Text(' · 第' + this.currentPage + '页')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.textColor())
        }
      }
      .alignSelf(ItemAlign.Center)
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .margin({ top: 8, bottom: 2 })
      .borderRadius(18)
      .backgroundColor(this.surfaceColor())
      .shadow({ radius: 8, color: this.isDark ? ThemeColors.strongScrim(this.isDark) : ThemeColors.shadow(this.isDark), offsetY: 2 })
    }
  }

  @Builder buildListResults() {
    List({ space: 8 }) {
      LazyForEach(this.resultDataSource_, (item: SearchResult) => {
        ListItem() {
          this.buildBookListItem(item)
        }
      }, (item: SearchResult): string => {
        return item.key + '|' + item.sourceCount.toString() + '|' + (item.noteUrl || '')
      })
      ListItem() {
        this.buildFooter()
      }
    }
    .height('100%')
    .width('100%')
    .padding({ top: 6, bottom: 16 })
    .onReachEnd(() => {
      if (!this.isSearching && !this.isLoadingMore && this.hasMore && this.results.length > 0) {
        this.loadMore();
      }
    })
  }

  @Builder buildGroupedResults() {
    List({ space: 12 }) {
      ForEach(this.getSourceGroups(), (group: SearchSourceGroup) => {
        ListItem() {
          Column() {
            Row() {
              Text(group.sourceName)
                .fontSize(15)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.textColor())
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(group.items.length.toString())
                .fontSize(11)
                .fontColor(this.subTextColor())
                .padding({ left: 7, right: 7, top: 3, bottom: 3 })
                .backgroundColor(this.surfaceAltColor())
                .borderRadius(10)
                .margin({ right: 8 })
              Text($r('app.string.ui_778fc8f994'))
                .fontSize(12)
                .fontColor(this.primaryColor())
                .onClick(() => { this.openExpandedSourceSheet(group); })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 10, bottom: 8 })

            if (this.expandedSourceUrl === group.sourceUrl) {
              ForEach(this.getPreviewItems(group.items, true), (item: SearchResult) => {
                this.buildBookListItem(item)
              }, (item: SearchResult): string => item.key)
            } else {
              Scroll() {
                Row() {
                  ForEach(this.getPreviewItems(group.items, false), (item: SearchResult) => {
                    this.buildGridItem(item)
                  }, (item: SearchResult): string => item.key)
                }
                .padding({ left: 16, right: 16, bottom: 8 })
              }
              .scrollable(ScrollDirection.Horizontal)
              .scrollBar(BarState.Off)
              .width('100%')
            }
          }
          .width('100%')
          .backgroundColor(this.surfaceColor())
        }
      }, (group: SearchSourceGroup): string => group.sourceUrl)
      ListItem() {
        this.buildFooter()
      }
    }
    .height('100%')
    .width('100%')
    .padding({ top: 6, bottom: 16 })
    .onReachEnd(() => {
      if (!this.isSearching && !this.isLoadingMore && this.hasMore && this.results.length > 0) {
        this.loadMore();
      }
    })
  }

  @Builder buildBookListItem(item: SearchResult) {
    Row() {
      Stack() {
        BookCover({ name: item.name, coverUrl: item.coverUrl, coverWidth: 72, coverHeight: 101, coverDecodeJs: item.coverDecodeJs || '' })
        if (this.getShelfState(item) > 0) {
          Text(this.getShelfState(item) === 1 ? '✓' : '↔')
            .fontSize(11)
            .fontColor(ThemeColors.onPrimary(this.isDark))
            .fontWeight(FontWeight.Bold)
            .width(22)
            .height(22)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.primaryColor())
            .borderRadius(4)
            .position({ x: 48, y: 2 })
        }
      }
      .width(72)
      .height(101)
      .margin({ right: 10 })

      Column() {
        Row() {
         Text(item.name)
           .fontSize(14)
           .fontWeight(FontWeight.Bold)
            .fontColor(this.textColor())
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (item.sourceCount > 1) {
            Text(item.sourceCount + '源')
              .fontSize(10)
              .fontColor(this.primaryColor())
              .padding({ left: 5, right: 5, top: 2, bottom: 2 })
              .backgroundColor(ThemeColors.primaryContainer(this.isDark))
              .borderRadius(4)
              .margin({ left: 8 })
          }
        }
        .width('100%')

        Row() {
          Text(item.author || '未知作者')
            .fontSize(12)
            .fontColor(this.subTextColor())
            .maxLines(1)
          if (item.latestChapterTitle) {
            Text(' · 最新: ' + item.latestChapterTitle)
              .fontSize(12)
              .fontColor(this.subTextColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
        }
        .width('100%')
        .margin({ top: 3 })

        if (item.introduce) {
          Text(item.introduce.replace(/\s+/g, ''))
            .fontSize(12)
            .fontColor(this.subTextColor())
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 6 })
        }

       Row() {
         if (item.wordCount) {
           Text(this.formatWordCount(item.wordCount))
             .fontSize(10)
             .fontColor(this.subTextColor())
             .padding({ left: 5, right: 5, top: 2, bottom: 2 })
             .backgroundColor(this.surfaceAltColor())
             .borderRadius(4)
             .margin({ right: 5 })
         }
         ForEach(this.splitKind(item.kind), (kind: string) => {
           Text(kind)
             .fontSize(10)
              .fontColor(this.subTextColor())
              .padding({ left: 5, right: 5, top: 2, bottom: 2 })
              .backgroundColor(this.surfaceAltColor())
              .borderRadius(4)
              .margin({ right: 5 })
          }, (kind: string): string => kind)
          Text(item.origin || '未知书源')
            .fontSize(10)
            .fontColor(this.subTextColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .margin({ top: 6 })
      }
      .layoutWeight(1)
      .height(101)
      .justifyContent(FlexAlign.Center)

      Text($r('app.string.ui_091385be99'))
        .fontSize(18)
        .fontColor(this.subTextColor())
        .margin({ left: 8 })
    }
    .width('100%')
    .padding({ left: 16, right: 14, top: 10, bottom: 10 })
    .backgroundColor(this.surfaceColor())
    .onClick(() => { this.goToBookInfo(item); })
    .gesture(LongPressGesture().onAction(() => { this.showPreview(item); }))
  }

  @Builder buildGridItem(item: SearchResult) {
    Column() {
      Stack() {
        BookCover({ name: item.name, coverUrl: item.coverUrl, coverWidth: 96, coverHeight: 134, coverDecodeJs: item.coverDecodeJs || '' })
        if (this.getShelfState(item) > 0) {
          Text(this.getShelfState(item) === 1 ? '✓' : '↔')
            .fontSize(10)
            .fontColor(ThemeColors.onPrimary(this.isDark))
            .fontWeight(FontWeight.Bold)
            .width(20)
            .height(20)
            .textAlign(TextAlign.Center)
            .backgroundColor(this.primaryColor())
            .borderRadius(4)
            .position({ x: 72, y: 3 })
        }
      }
      .width(96)
      .height(134)
      Text(item.name)
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.textColor())
        .maxLines(2)
        .minLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(96)
        .margin({ top: 6 })
      Text(item.author || item.origin)
        .fontSize(10)
        .fontColor(this.subTextColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(96)
        .margin({ top: 2 })
    }
    .width(108)
    .margin({ right: 8 })
    .onClick(() => { this.goToBookInfo(item); })
    .gesture(LongPressGesture().onAction(() => { this.showPreview(item); }))
  }

  @Builder buildFooter() {
    Column() {
      if (this.isSearching || this.isLoadingMore) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color(this.primaryColor())
          .margin({ bottom: 8 })
        Text(this.isLoadingMore ? '正在加载下一页' : '正在搜索')
          .fontSize(12)
          .fontColor(this.subTextColor())
      } else if (this.hasMore && this.results.length > 0) {
        Button($r('app.string.ui_8e1ac919ae'))
          .fontSize(14)
          .fontColor(this.primaryColor())
          .height(40)
          .padding({ left: 18, right: 18 })
          .backgroundColor(this.surfaceAltColor())
          .borderRadius(19)
          .onClick(() => { this.loadMore(); })
      } else if (this.hasSearched) {
        Text($r('app.string.ui_3471e133fa'))
          .fontSize(12)
          .fontColor(this.subTextColor())
      }
    }
    .width('100%')
    .padding({ top: 18, bottom: 28 })
    .alignItems(HorizontalAlign.Center)
  }

  @Builder buildEmptyResult() {
    Column() {
      Text($r('app.string.ui_72077749f7'))
        .fontSize(42)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.subTextColor())
        .margin({ top: 80 })
      Text(this.matchModeExact ? '没有精确匹配结果' : '没有找到结果')
        .fontSize(16)
        .fontColor(this.subTextColor())
        .margin({ top: 10 })
      Text('已搜索 ' + this.totalSources + ' 个源')
        .fontSize(12)
        .fontColor(this.subTextColor())
        .margin({ top: 4 })
      if (this.hasRelaxableFilters()) {
        Button($r('app.string.ui_423b4efd16'))
          .fontSize(14)
          .fontColor(ThemeColors.onPrimary(this.isDark))
          .height(40)
          .padding({ left: 18, right: 18 })
          .backgroundColor(this.primaryColor())
          .borderRadius(19)
          .margin({ top: 18 })
          .onClick(() => { this.showRelaxFilterDialog = true; })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder buildIdle() {
    Column() {
      Text($r('app.string.ui_35d70d63b7'))
        .fontSize(46)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.subTextColor())
        .margin({ top: 96 })
      Text($r('app.string.ui_70ed469dce'))
        .fontSize(16)
        .fontColor(this.subTextColor())
        .margin({ top: 8 })
      Text('已加载 ' + this.sources.length + ' 个启用书源')
        .fontSize(12)
        .fontColor(this.subTextColor())
        .margin({ top: 4 })
    }
    .width('100%')
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder buildDimLayer(action: () => void) {
    Column() {}
      .width('100%')
      .height('100%')
      .backgroundColor(ThemeColors.strongScrim(this.isDark))
      .onClick(action)
  }

  @Builder buildSettingsSheet() {
    Column() {
      Row() {
        Text($r('app.string.ui_07f40562ca'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.textColor())
          .layoutWeight(1)
        Text($r('app.string.common_done'))
          .fontSize(14)
          .fontColor(this.primaryColor())
          .onClick(() => { this.showSettingsSheet = false; })
      }
      .width('100%')
      .height(52)
      .padding({ left: 18, right: 18 })

      Text($r('app.string.ui_b0961e172b'))
        .fontSize(13)
        .fontColor(this.subTextColor())
        .alignSelf(ItemAlign.Start)
        .margin({ left: 18, top: 8, bottom: 8 })
      Row() {
        this.buildSegment('列表', this.layoutMode === 0, () => {
          this.setLayoutMode(0);
        })
        this.buildSegment('按源分组', this.layoutMode === 1, () => {
          this.setLayoutMode(1);
        })
      }
      .width('100%')
      .padding({ left: 18, right: 18 })

      Text($r('app.string.ui_b3eb306129'))
        .fontSize(13)
        .fontColor(this.subTextColor())
        .alignSelf(ItemAlign.Start)
        .margin({ left: 18, top: 18, bottom: 8 })
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.getSourceTypeOptions(), (option: SourceTypeOption) => {
          this.buildSelectionChip(option.label + ' ' + option.count, this.selectedSourceTypes.includes(option.value), () => {
            this.toggleSourceType(option.value);
          })
        }, (option: SourceTypeOption): string => option.value.toString())
      }
      .width('100%')
      .padding({ left: 18, right: 18 })

      Text($r('app.string.ui_c7127bb6ee'))
        .fontSize(13)
        .fontColor(this.subTextColor())
        .alignSelf(ItemAlign.Start)
        .margin({ left: 18, top: 18, bottom: 8 })
      Row() {
        this.buildSelectionChip('精确搜索', this.matchModeExact, () => {
          this.setMatchModeExact(true);
        })
        this.buildSelectionChip('普通搜索', !this.matchModeExact, () => {
          this.setMatchModeExact(false);
        })
      }
      .width('100%')
      .padding({ left: 18, right: 18 })

      Blank()
    }
    .width('100%')
    .height('46%')
    .padding({ bottom: 18 })
    .backgroundColor(this.surfaceColor())
    .borderRadius({ topLeft: 20, topRight: 20 })
    .position({ left: 0, bottom: 0 })
  }

  @Builder buildSegment(label: string, selected: boolean, action: () => void) {
    Text(label)
      .fontSize(14)
      .fontColor(selected ? ThemeColors.onPrimary(this.isDark) : this.textColor())
      .textAlign(TextAlign.Center)
      .height(38)
      .layoutWeight(1)
      .padding({ top: 9 })
      .backgroundColor(selected ? this.primaryColor() : this.surfaceAltColor())
      .borderRadius(8)
      .margin({ right: 8 })
      .onClick(action)
  }

  @Builder buildSelectionChip(label: string, selected: boolean, action: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor(selected ? ThemeColors.onPrimary(this.isDark) : this.textColor())
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .backgroundColor(selected ? this.primaryColor() : this.surfaceAltColor())
      .borderRadius(16)
      .margin({ right: 8, bottom: 8 })
      .onClick(action)
  }

  @Builder buildScopeSheet() {
    Column() {
      Row() {
        Text($r('app.string.ui_2cacc1b742'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.textColor())
          .layoutWeight(1)
        Text($r('app.string.ui_778fc8f994'))
          .fontSize(14)
          .fontColor(this.primaryColor())
          .margin({ right: 18 })
          .onClick(() => { this.selectAllScope(); })
        Text($r('app.string.common_done'))
          .fontSize(14)
          .fontColor(this.primaryColor())
          .onClick(() => { this.finishScopeSheet(); })
      }
      .width('100%')
      .height(52)
      .padding({ left: 18, right: 18 })

      Row() {
        Row() {
          TextInput({ placeholder: $r('app.string.ui_440a4757f9'), text: this.sourceFilterText })
            .height(40)
            .layoutWeight(1)
            .backgroundColor(Color.Transparent)
            .fontSize(14)
            .fontColor(this.textColor())
            .placeholderColor(this.subTextColor())
            .padding({ left: 12 })
            .onChange((v: string) => { this.sourceFilterText = v; })
          if (this.sourceFilterText) {
            Text($r('app.string.ui_11f6ad8ec5'))
              .fontSize(14)
              .fontColor(this.subTextColor())
              .width(44)
              .height(44)
              .textAlign(TextAlign.Center)
              .accessibilityText($r('app.string.common_clear'))
              .onClick(() => { this.sourceFilterText = ''; })
          }
        }
        .height(40)
        .layoutWeight(1)
        .backgroundColor(this.surfaceAltColor())
        .borderRadius(20)
      }
      .width('100%')
      .padding({ left: 18, right: 18, bottom: 8 })

      Row() {
        this.buildSegment('分组', !this.scopeBySource, () => { this.scopeBySource = false; })
        this.buildSegment('书源', this.scopeBySource, () => { this.scopeBySource = true; })
      }
      .width('100%')
      .padding({ left: 18, right: 18, bottom: 8 })

      if (!this.scopeBySource) {
        Scroll() {
          Flex({ wrap: FlexWrap.Wrap }) {
            this.buildSelectionChip('全部书源', this.selectedGroups.length === 0 && this.selectedSourceUrls.length === 0, () => {
              this.selectAllScope();
            })
            ForEach(this.getSourceGroupNames().filter((group: string): boolean => {
              const q = this.sourceFilterText.trim().toLowerCase();
              return !q || group.toLowerCase().includes(q);
            }), (group: string) => {
              this.buildSelectionChip(group, this.selectedGroups.includes(group), () => { this.toggleGroup(group); })
            }, (group: string): string => group)
          }
          .width('100%')
          .padding({ left: 18, right: 18, bottom: 24 })
        }
        .layoutWeight(1)
        .width('100%')
      } else {
        List({ space: 1 }) {
          ForEach(this.getFilteredSourcesForSheet(), (source: BookSource) => {
            ListItem() {
              Row() {
                Text(this.selectedSourceUrls.includes(source.sourceUrl) ? '✓' : '')
                  .fontSize(14)
                  .fontColor(ThemeColors.onPrimary(this.isDark))
                  .fontWeight(FontWeight.Bold)
                  .width(24)
                  .height(24)
                  .textAlign(TextAlign.Center)
                  .backgroundColor(this.selectedSourceUrls.includes(source.sourceUrl) ? this.primaryColor() : this.surfaceAltColor())
                  .borderRadius(12)
                  .margin({ right: 12 })
                Column() {
                  Text(source.sourceName)
                    .fontSize(15)
                    .fontColor(this.textColor())
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text((source.group || '未分组') + ' · ' + (source.sourceType === 0 ? '出版' : '网络'))
                    .fontSize(12)
                    .fontColor(this.subTextColor())
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 3 })
                }
                .layoutWeight(1)
              }
              .width('100%')
              .padding({ left: 18, right: 18, top: 10, bottom: 10 })
              .backgroundColor(this.surfaceColor())
              .onClick(() => { this.toggleSource(source); })
            }
          }, (source: BookSource): string => source.sourceUrl)
        }
        .layoutWeight(1)
        .width('100%')
      }
    }
    .width('100%')
    .height('70%')
    .padding({ bottom: 18 })
    .backgroundColor(this.surfaceColor())
    .borderRadius({ topLeft: 20, topRight: 20 })
    .position({ left: 0, bottom: 0 })
  }

  @Builder buildClearHistoryDialog() {
    Column() {
      Text($r('app.string.ui_63c63d5fff'))
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.textColor())
        .margin({ top: 20 })
      Text($r('app.string.ui_258e710c18'))
        .fontSize(14)
        .fontColor(this.subTextColor())
        .margin({ top: 12, bottom: 18 })
      Row() {
        Button($r('app.string.common_cancel'))
          .fontSize(14)
          .fontColor(this.textColor())
          .layoutWeight(1)
          .height(40)
          .backgroundColor(this.surfaceAltColor())
          .borderRadius(20)
          .onClick(() => { this.showClearHistoryDialog = false; })
        Button($r('app.string.ui_7b15e5e8e7'))
          .fontSize(14)
          .fontColor(ThemeColors.onPrimary(this.isDark))
          .layoutWeight(1)
          .height(40)
          .backgroundColor(ThemeColors.error(this.isDark))
          .borderRadius(20)
          .margin({ left: 10 })
          .onClick(() => { this.clearHistory(); })
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 18 })
    }
    .width('82%')
    .backgroundColor(this.surfaceColor())
    .borderRadius(18)
  }

  @Builder buildRelaxFilterDialog() {
    Column() {
      Text($r('app.string.ui_7b518aad5a'))
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.textColor())
        .margin({ top: 20 })
      Text($r('app.string.ui_84128a8270'))
        .fontSize(14)
        .fontColor(this.subTextColor())
        .lineHeight(20)
        .textAlign(TextAlign.Center)
        .padding({ left: 20, right: 20 })
        .margin({ top: 10, bottom: 16 })
      if (this.matchModeExact) {
        Button($r('app.string.ui_61041cbe12'))
          .fontSize(14)
          .fontColor(ThemeColors.onPrimary(this.isDark))
          .width('100%')
          .height(40)
          .backgroundColor(this.primaryColor())
          .borderRadius(20)
          .margin({ bottom: 8 })
          .onClick(() => { this.relaxFiltersAndSearch(0); })
      }
      if (this.selectedGroups.length > 0 || this.selectedSourceUrls.length > 0 || this.selectedSourceTypes.length > 0) {
        Button($r('app.string.ui_510d465771'))
          .fontSize(14)
          .fontColor(this.primaryColor())
          .width('100%')
          .height(40)
          .backgroundColor(this.surfaceAltColor())
          .borderRadius(20)
          .margin({ bottom: 8 })
          .onClick(() => { this.relaxFiltersAndSearch(1); })
      }
      Button($r('app.string.ui_3597d00e59'))
        .fontSize(14)
        .fontColor(this.textColor())
        .width('100%')
        .height(40)
        .backgroundColor(this.surfaceAltColor())
        .borderRadius(20)
        .onClick(() => { this.relaxFiltersAndSearch(2); })
      Text($r('app.string.common_cancel'))
        .fontSize(14)
        .fontColor(this.subTextColor())
        .height(40)
        .textAlign(TextAlign.Center)
        .margin({ top: 8, bottom: 12 })
        .onClick(() => { this.showRelaxFilterDialog = false; })
    }
    .width('82%')
    .padding({ left: 20, right: 20 })
    .backgroundColor(this.surfaceColor())
    .borderRadius(18)
  }

  @Builder buildExpandedSourceSheet() {
    Column() {
      Row() {
        Column() {
          Text(this.expandedSourceName || '书源结果')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.textColor())
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.expandedSourceBooks.length + ' 本 · 第 ' + this.expandedSourcePage + ' 页')
            .fontSize(12)
            .fontColor(this.subTextColor())
            .margin({ top: 3 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        Text($r('app.string.common_close'))
          .fontSize(14)
          .fontColor(this.primaryColor())
          .onClick(() => {
            this.expandedSourceRunId++;
            this.showExpandedSourceSheet = false;
          })
      }
      .width('100%')
      .height(58)
      .padding({ left: 18, right: 18 })

      List({ space: 1 }) {
        ForEach(this.expandedSourceBooks, (item: SearchResult) => {
          ListItem() {
            this.buildBookListItem(item)
          }
        }, (item: SearchResult): string => item.key + item.noteUrl)

        ListItem() {
          Column() {
            if (this.expandedSourceLoading) {
              LoadingProgress()
                .width(22)
                .height(22)
                .color(this.primaryColor())
              Text($r('app.string.ui_109062ac89'))
                .fontSize(12)
                .fontColor(this.subTextColor())
                .margin({ top: 8 })
            } else if (this.expandedSourceHasMore) {
              Button($r('app.string.ui_3a0fab4978'))
                .fontSize(14)
                .fontColor(this.primaryColor())
                .height(40)
                .padding({ left: 18, right: 18 })
                .backgroundColor(this.surfaceAltColor())
                .borderRadius(19)
                .onClick(() => { this.loadMoreExpandedSource(); })
            } else if (this.expandedSourceError) {
              Text(this.expandedSourceError)
                .fontSize(12)
                .fontColor(this.subTextColor())
            }
          }
          .width('100%')
          .height(72)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        }
      }
      .layoutWeight(1)
      .width('100%')
      .divider({ strokeWidth: 0.5, color: ThemeColors.outlineVariant(this.isDark) })
      .onReachEnd(() => {
        if (this.expandedSourceHasMore && !this.expandedSourceLoading) {
          this.loadMoreExpandedSource();
        }
      })
    }
    .width('100%')
    .height('82%')
    .padding({ bottom: 18 })
    .backgroundColor(this.surfaceColor())
    .borderRadius({ topLeft: 20, topRight: 20 })
    .position({ left: 0, bottom: 0 })
  }

  @Builder buildPreviewSheet() {
    if (this.previewItem) {
      Column() {
        Row() {
          Text($r('app.string.ui_0cb95c69f1'))
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.textColor())
            .layoutWeight(1)
          Text($r('app.string.common_close'))
            .fontSize(14)
            .fontColor(this.primaryColor())
            .onClick(() => { this.showPreviewSheet = false; })
        }
        .width('100%')
        .height(52)
        .padding({ left: 18, right: 18 })

        Row() {
          BookCover({
            name: this.previewItem.name,
            coverUrl: this.previewItem.coverUrl,
            coverWidth: 96,
            coverHeight: 134,
            coverDecodeJs: this.previewItem.coverDecodeJs || ''
          })
            .margin({ right: 14 })
          Column() {
            Text(this.previewItem.name)
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.textColor())
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.previewItem.author || '未知作者')
              .fontSize(13)
              .fontColor(this.subTextColor())
              .margin({ top: 6 })
            Text((this.previewItem.origin || '未知书源') + (this.previewItem.sourceCount > 1 ? ' · ' + this.previewItem.sourceCount + '源' : ''))
              .fontSize(12)
              .fontColor(this.primaryColor())
              .margin({ top: 8 })
            if (this.previewItem.latestChapterTitle) {
              Text('最新: ' + this.previewItem.latestChapterTitle)
                .fontSize(12)
                .fontColor(this.subTextColor())
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: 6 })
            }
          }
          .layoutWeight(1)
          .height(134)
          .justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 4 })

        if (this.previewItem.introduce) {
          Text(this.previewItem.introduce.replace(/\s+/g, ''))
            .fontSize(13)
            .fontColor(this.textColor())
            .lineHeight(20)
            .maxLines(5)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .padding({ left: 18, right: 18, top: 16 })
        }

        Row() {
          Button($r('app.string.ui_c0ea2c7481'))
            .fontSize(14)
            .fontColor(this.primaryColor())
            .layoutWeight(1)
            .height(42)
            .backgroundColor(this.surfaceAltColor())
            .borderRadius(21)
            .onClick(() => { this.addPreviewToShelf(); })
          Button($r('app.string.ui_faea8c1db9'))
            .fontSize(14)
            .fontColor(ThemeColors.onPrimary(this.isDark))
            .layoutWeight(1)
            .height(42)
            .backgroundColor(this.primaryColor())
            .borderRadius(21)
            .margin({ left: 10 })
            .onClick(() => {
              if (this.previewItem) {
                const item = this.previewItem;
                this.showPreviewSheet = false;
                this.goToBookInfo(item);
              }
            })
        }
        .width('100%')
        .padding({ left: 18, right: 18, top: 20, bottom: 18 })
      }
      .width('100%')
      .backgroundColor(this.surfaceColor())
      .borderRadius({ topLeft: 20, topRight: 20 })
      .position({ left: 0, bottom: 0 })
    }
  }
}
