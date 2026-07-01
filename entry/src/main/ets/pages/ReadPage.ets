/**
 * 阅读页
 */
import router from '@ohos.router';
import { BookSource, BookSourceChapter } from '../model/BookSource';
import { MeasureUtils } from '@kit.ArkUI';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { SettingsStore } from '../data/preferences/SettingsStore';
import { ChapterCache } from '../util/ChapterCache';
import { TextLayout, LayoutConfig, LayoutPage, DEFAULT_LAYOUT_CONFIG } from '../engine/book/TextLayout';
import { convertChinese } from '../util/ChineseConverter';
import { PageView, PageViewConfig, PageTurnAnim, PageTurnEvent } from '../components/reader/PageView';
import { ClickAction, DEFAULT_ZONE_ACTIONS } from '../components/reader/ClickAction';
import { StylePanel } from '../components/reader/StylePanel';
import { ReadBottomMenu } from '../components/reader/ReadBottomMenu';
import { ClickActionConfig } from '../components/reader/ClickActionConfig';
import { NetUtil } from '../util/NetUtil';
import { HtmlUtil } from '../util/HtmlUtil';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookTable } from '../data/database/BookTable';
import { ChapterTable } from '../data/database/ChapterTable';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { BookChapter } from '../model/BookChapter';
import { SearchResult } from '../model/SearchResult';
import { CacheDialog } from '../components/reader/CacheDialog';
import { ChangeSourceSheet } from '../components/BookInfoSheets';
import { ReadAloudPanel } from '../components/reader/ReadAloudPanel';
import { ReadAloudEngine, AloudState } from '../service/ReadAloudEngine';
import promptAction from '@ohos.promptAction';

@Entry
@Component
struct ReadPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State bookName: string = '';
  @State bookAuthor: string = '';
  @State bookUrl: string = '';
  @State originUrl: string = '';
  @State origin: string = '';
  @State tocUrl: string = '';
  @State pageMode: boolean = true;
  @State chapters: BookSourceChapter[] = [];
  @State currentIndex: number = 0;
  @State pageIndex: number = 0;
  @State text: string = '';
  @State isLoading: boolean = true;
  @State pages: LayoutPage[] = [];
  @State scrollText: string = '';
  // 预加载下一章，实现无缝翻页
  private nextChapterContent_: string = '';
  private nextChapterIdx_: number = -1;
  private isPreloading_: boolean = false;
  private preloadingChapterPromises_: Map<number, Promise<string>> = new Map<number, Promise<string>>();
  private bookId_: number = -1;
  private cacheSize_: number = 10;
  private isCaching_: boolean = false;
  private scroller_: Scroller = new Scroller();
  private scrollAtTop_: boolean = true;
  private justLoadedChapter_: boolean = false;
  private measureCharW_: number = 0;
  private measureLineH_: number = 0;
  private measureUtil_: MeasureUtils | null = null;
  @State showMenu: boolean = false;
  @State showStyle: boolean = false;
  @State showCacheDialog: boolean = false;
  @State showZoneConfig: boolean = false;
  @State showAloud: boolean = false;
  @State readBgColor: string = '#F5F0E8';
  @State readTextColor: string = '#333333';
  @State zoneActions: number[] = DEFAULT_ZONE_ACTIONS;
  @State cfg: PageViewConfig = {
    animType: PageTurnAnim.SLIDE, bgColor: '#F5F0E8', textColor: '#333333', titleColor: '#999',
    fontSize: 18, fontWeight: 1, fontFamily: 'HarmonyOS Sans', lineHeight: 1.6,
    letterSpacing: 0.5, paragraphSpacing: 10, textAlign: 'justify', indentSize: 2,
    paddingTop: 24, paddingBottom: 24, paddingLeft: 20, paddingRight: 20,
    showHeader: false, showFooter: true, headerContent: '', footerContent: '',
    brightness: 80, zhFormat: true, chineseMode: 'original', pageMode: true,
  };
  @State pageW: number = 360;
  @State pageH: number = 640;
  private source_: BookSource | null = null;
  private targetIdx_: number = -1;
  private allChapters_: BookSourceChapter[] = [];
  private totalChapters_: number = 0;
  private aloudEngine_: ReadAloudEngine | null = null;
  private sourceDlg?: CustomDialogController;

  aboutToAppear(): void {
    const p = router.getParams() as Record<string, Object>;
    this.bookName = String(p['bookName'] || p['name'] || '');
    this.bookAuthor = String(p['bookAuthor'] || p['author'] || '');
    this.bookUrl = String(p['bookUrl'] || '');
    this.originUrl = String(p['originUrl'] || '');
    this.origin = String(p['origin'] || '');
    this.tocUrl = String(p['tocUrl'] || '');
    if (p['durChapterIndex'] !== undefined) this.targetIdx_ = Number(p['durChapterIndex']);
    if (p['durPageIndex'] !== undefined) this.pageIndex = Number(p['durPageIndex']);
    this.loadSettings();
    // 初始化测量工具
    try { this.measureUtil_ = this.getUIContext().getMeasureUtils(); } catch (_) { /* ignore */ }
  }

  onPageShow(): void {
    if (!this.isLoading) {
      // 从目录页返回时，通过 ChapterCache 获取目标章节索引
      if (ChapterCache.targetIndex >= 0) {
        const idx = ChapterCache.targetIndex;
        ChapterCache.targetIndex = -1;
        // 同步章节列表（目录页可能已重新排序）
        if (ChapterCache.chapters.length > 0 && ChapterCache.bookUrl === this.bookUrl) {
          this.allChapters_ = ChapterCache.chapters;
          this.totalChapters_ = ChapterCache.chapters.length;
          this.chapters = ChapterCache.chapters;
        }
        if (idx < this.allChapters_.length && idx !== this.currentIndex) {
          console.info('[ReadPage] Jump to chapter from toc:', idx);
          this.loadChapter(idx);
        }
      }
      return;
    }
    this.loadContent();
  }

  private async loadSettings(): Promise<void> {
    try {
      const s = SettingsStore.getInstance();
      await s.init(getContext());
      this.pageMode = (await s.getPageMode()) !== 0;
      this.cfg.fontSize = await s.getFontSize();
      this.cfg.fontFamily = await s.getFontFamily();
      this.cfg.lineHeight = await s.getLineHeight();
      this.cfg.indentSize = await s.getIndentSize();
      this.cfg.letterSpacing = await s.getLetterSpacing();
      this.cfg.paragraphSpacing = await s.getParagraphSpacing();
      this.cfg.fontWeight = await s.getFontWeight();
      this.cfg.paddingTop = await s.getPaddingTop();
      this.cfg.paddingBottom = await s.getPaddingBottom();
      this.cfg.paddingLeft = await s.getPaddingLeft();
      this.cfg.paddingRight = await s.getPaddingRight();
      this.cfg.chineseMode = await s.getChineseMode();
    this.cfg.zhFormat = await s.getZhFormat();
    this.readBgColor = await s.getReadBgColor();
    this.readTextColor = await s.getReadTextColor();
      this.pageMode = (await s.getPageMode()) !== 0;
      this.cfg.pageMode = this.pageMode;
      this.cacheSize_ = await s.getAutoCacheSize();
      // 加载自定义触控区域配置
      const za: number[] = [];
      for (let z = 0; z < 9; z++) za.push(await s.getClickAction(z));
      this.zoneActions = za;
      this.cfg.bgColor = this.readBgColor;
      this.cfg.textColor = this.readTextColor;
    } catch (_e) { /* ignore */ }
  }

  private async loadContent(): Promise<void> {
    this.isLoading = true;
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const srcDao = new BookSourceTable(db);
      const sources = await srcDao.getAllSources();
      const norm = this.originUrl.replace(/\/+$/, '');
      this.source_ = sources.find(s => s.sourceUrl === this.originUrl) ||
        sources.find(s => s.sourceUrl.replace(/\/+$/, '') === norm) ||
        sources.find(s => s.sourceName === this.origin) || null;

      let chapters: BookSourceChapter[] = [];
      if (ChapterCache.chapters.length > 0 && ChapterCache.bookUrl === this.bookUrl) {
        chapters = ChapterCache.chapters;
        console.info('[ReadPage] Loaded chapters from cache:', chapters.length, this.bookUrl.substring(0, 80));
      } else {
        if (ChapterCache.chapters.length > 0) {
          console.info('[ReadPage] Ignore stale chapter cache. cacheBookUrl=',
            ChapterCache.bookUrl.substring(0, 80), 'current=', this.bookUrl.substring(0, 80));
        }
        if (this.source_) {
          chapters = await globalSourceExecutor.getToc(this.source_, this.bookUrl);
          if (chapters.length === 0 && this.tocUrl && this.tocUrl !== this.bookUrl) {
            chapters = await globalSourceExecutor.getToc(this.source_, this.tocUrl);
          }
        }
      }
      if (chapters.length === 0) { this.text = '无目录'; this.isLoading = false; console.info('[ReadPage] no chapters'); return; }
      this.allChapters_ = chapters;
      this.totalChapters_ = chapters.length;
      this.currentIndex = this.targetIdx_ >= 0 && this.targetIdx_ < chapters.length ? this.targetIdx_ : 0;
      this.chapters = chapters;
      if (ChapterCache.bookUrl !== this.bookUrl || ChapterCache.chapters.length === 0) {
        ChapterCache.chapters = chapters;
        ChapterCache.bookUrl = this.bookUrl;
      }
      // 获取 bookId 用于缓存
      try {
        const bookTable = new BookTable(db);
        const book = await bookTable.getBookByUrl(this.bookUrl);
        if (book) { this.bookId_ = book.id; }
      } catch (_) { /* ignore */ }
      await this.loadChapter(this.currentIndex);
    } catch (e) {
      this.text = '加载失败';
      this.isLoading = false;
    }
  }

  private async loadChapter(idx: number, forceFetch: boolean = false): Promise<void> {
    if (idx < 0 || idx >= this.allChapters_.length) return;
    this.isLoading = true;
    this.currentIndex = idx;
    this.pageIndex = 0;
    const ch = this.allChapters_[idx];

    // 非强制刷新的情况下，尝试从数据库缓存加载
    if (!forceFetch) {
      const cachedContent = await this.readChapterCache_(idx);
      if (cachedContent && cachedContent.length > 50) {
        console.info('[ReadPage] Loaded from cache:', ch.title?.substring(0, 20));
        this.applyChapterContent_(idx, cachedContent);
        this.isLoading = false;
        this.saveProgress();
        this.preloadNextChapter_(idx);
        this.cacheSurrounding_(idx);
        return;
      }
    }

    try {
      const content = await this.fetchChapterContent_(idx);
      if (content && content.length > 50) {
        this.applyChapterContent_(idx, content);
      } else {
        this.text = content || '加载失败';
        this.layoutText(this.text);
      }
    } catch (e) {
      this.text = '加载失败';
    }
    this.isLoading = false;
    // 持久化缓存到数据库
    this.saveToDbCache_(idx, this.text);
    // 保存阅读进度
    this.saveProgress();
    // 无缝翻页：预加载下一章
    this.preloadNextChapter_(idx);
    // 自动缓存前后 ±n 章
    this.cacheSurrounding_(idx);
  }

  private async readChapterCache_(idx: number): Promise<string> {
    if (this.bookId_ <= 0) return '';
    try {
      const ct = new ChapterTable(AppDatabase.getInstance().rdbStore);
      const cached = await ct.getChapterByIndex(this.bookId_, idx);
      return cached?.content || '';
    } catch (_e) {
      return '';
    }
  }

  private async fetchChapterContent_(idx: number): Promise<string> {
    const ch = this.allChapters_[idx];
    if (!ch) return '';
    const url = ch.url || this.bookUrl;
    let content = '';
    if (this.source_) {
      content = await globalSourceExecutor.getContent(this.source_, url, this.bookUrl);
    }
    if (!content && url && url.startsWith('http')) {
      const r = await NetUtil.httpGet(url);
      if (r) content = HtmlUtil.stripHtml(r);
    }
    if (content && content.length > 50 && this.cfg.chineseMode !== 'original') {
      content = convertChinese(content, this.cfg.chineseMode);
    }
    return content;
  }

  private applyChapterContent_(idx: number, content: string): void {
    this.currentIndex = idx;
    this.pageIndex = 0;
    this.text = content;
    this.layoutText(content);
    this.initAloudEngine_();
  }

  /** 预加载下一章文本，用于无缝翻页 */
  private preloadNextChapter_(currentIdx: number): void {
    const nextIdx = currentIdx + 1;
    if (nextIdx >= this.allChapters_.length || this.preloadingChapterPromises_.has(nextIdx)) return;
    this.isPreloading_ = true;

    const ch = this.allChapters_[nextIdx];
    const preloadBookUrl = this.bookUrl;
    const promise = this.readChapterCache_(nextIdx)
      .then((cached: string): Promise<string> | string => {
        if (cached && cached.length > 50) return cached;
        return this.fetchChapterContent_(nextIdx);
      });
    this.preloadingChapterPromises_.set(nextIdx, promise);
    promise
      .then(async (content: string): Promise<void> => {
        if (preloadBookUrl !== this.bookUrl) return;
        if (content && content.length > 50) {
          this.nextChapterContent_ = content;
          this.nextChapterIdx_ = nextIdx;
          await this.saveToDbCache_(nextIdx, content);
          console.info('[ReadPage] Preloaded next chapter:', nextIdx, ch.title?.substring(0, 20));
        }
      })
      .catch((_e: Error) => { /* ignore preload failure */ })
      .then(() => {
        if (this.preloadingChapterPromises_.get(nextIdx) === promise) {
          this.preloadingChapterPromises_.delete(nextIdx);
        }
        this.isPreloading_ = this.preloadingChapterPromises_.size > 0;
      });
  }

  private async tryUsePreloadedChapter_(idx: number): Promise<boolean> {
    let content = '';
    if (this.nextChapterIdx_ === idx && this.nextChapterContent_ && this.nextChapterContent_.length > 50) {
      content = this.nextChapterContent_;
    } else {
      const pending = this.preloadingChapterPromises_.get(idx);
      if (pending) {
        try {
          content = await pending;
        } catch (_e) {
          content = '';
        }
      }
      if (!content) {
        content = await this.readChapterCache_(idx);
      }
    }
    if (!content || content.length <= 50) return false;
    console.info('[ReadPage] Seamless switch to chapter:', idx);
    this.applyChapterContent_(idx, content);
    if (this.nextChapterIdx_ === idx) {
      this.nextChapterContent_ = '';
      this.nextChapterIdx_ = -1;
    }
    this.isLoading = false;
    this.saveProgress();
    this.saveToDbCache_(idx, content);
    this.preloadNextChapter_(idx);
    this.cacheSurrounding_(idx);
    return true;
  }

  /** 将章节内容存入数据库缓存 */
  private async saveToDbCache_(idx: number, content: string): Promise<void> {
    if (this.bookId_ <= 0 || !content || content.length <= 50) return;
    try {
      const ct = new ChapterTable(AppDatabase.getInstance().rdbStore);
      const existing = await ct.getChapterByIndex(this.bookId_, idx);
      const ch = this.allChapters_[idx];
      const now = Date.now();
      if (existing) {
        existing.content = content;
        existing.contentLength = content.length;
        existing.isCached = true;
        existing.updateTime = now;
        await ct.updateChapter(existing);
      } else {
        await ct.insertChapters([{
          id: 0, bookId: this.bookId_, index: idx, volumeIndex: 0,
          title: ch?.title || '', url: ch?.url || '',
          content: content, contentLength: content.length,
          isRead: false, isDownloaded: false, isCached: true,
          duration: 0, audioUrl: '', createTime: now, updateTime: now,
        }]);
      }
    } catch (_e) { /* ignore */ }
  }

  /** 自动缓存当前章节前后 ±cacheSize_ 章 */
  private async cacheSurrounding_(currentIdx: number): Promise<void> {
    if (this.bookId_ <= 0 || this.isCaching_ || !this.source_) return;
    this.isCaching_ = true;
    const total = this.allChapters_.length;
    const start = Math.max(0, currentIdx - this.cacheSize_);
    const end = Math.min(total - 1, currentIdx + this.cacheSize_);
    try {
      let count = 0;
      for (let i = start; i <= end; i++) {
        if (i === currentIdx) continue; // 当前章节已缓存
        const ch = this.allChapters_[i];
        if (!ch) continue;
        try {
          let content = await this.readChapterCache_(i);
          if (content && content.length > 50) continue;

          const pending = this.preloadingChapterPromises_.get(i);
          if (pending) {
            content = await pending;
          } else {
            content = await this.fetchChapterContent_(i);
          }
          if (content && content.length > 50) {
            await this.saveToDbCache_(i, content);
            count++;
          }
        } catch (_e) { /* skip individual chapter errors */ }
      }
      if (count > 0) console.info('[ReadPage] Auto-cached', count, 'chapters around', currentIdx);
    } catch (_e) { /* ignore */ }
    this.isCaching_ = false;
  }

  private saveProgress(): void {
    const ch = this.allChapters_[this.currentIndex];
    if (!ch || !this.bookUrl) return;
    const bookTable = new BookTable(AppDatabase.getInstance().rdbStore);
    bookTable.updateReadingProgress(this.bookUrl, this.currentIndex, ch.title || '', this.totalChapters_)
      .catch(() => { /* ignore */ });
  }

  private getProgressPercent(): number {
    if (this.totalChapters_ <= 0) return 0;
    return Math.min(100, Math.round((this.currentIndex / this.totalChapters_) * 100));
  }

  private normalizeReaderText_(text: string): string {
    if (!text) return '';
    return text
      .replace(/\r\n/g, '\n')
      .replace(/\r/g, '\n')
      .split('\n')
      .map((line: string): string => line.trim())
      .join('\n')
      .replace(/[ \t\u00a0]+/g, ' ')
      .replace(/\n[ \t]*\n+/g, '\n')
      .trim();
  }

  private layoutText(text: string): void {
    text = this.normalizeReaderText_(text);
    // 构建带缩进的滚动文本
    let scrollText = text;
    const indentSize = this.cfg.indentSize;
    if (indentSize > 0) {
      let prefix = '';
      for (let i = 0; i < indentSize; i++) prefix += '  ';
      scrollText = text.split('\n').map((para: string, i: number) => {
        return i > 0 ? prefix + para : para;
      }).join('\n');
    }

    const lc: LayoutConfig = {
      fontFamily: this.cfg.fontFamily,
      fontSize: this.cfg.fontSize,
      fontBold: this.cfg.fontWeight >= 2,
      fontWeight: this.cfg.fontWeight,
      lineHeightMultiplier: this.cfg.lineHeight,
      paragraphSpacing: this.cfg.paragraphSpacing,
      letterSpacing: this.cfg.letterSpacing,
      textAlign: this.cfg.textAlign as 'left' | 'justify',
      firstLineIndent: this.cfg.indentSize > 0,
      indentSize: this.cfg.indentSize,
      pagePadding: 20,
      pagePaddingTop: this.cfg.paddingTop,
      pagePaddingBottom: this.cfg.paddingBottom,
      pagePaddingLeft: this.cfg.paddingLeft,
      pagePaddingRight: this.cfg.paddingRight,
      zhFormat: this.cfg.zhFormat,
      chineseMode: this.cfg.chineseMode,
      measuredCharWidth: this.measureCharW_,
      measuredLineHeight: this.measureLineH_,
    };
    const footerH = this.cfg.showFooter ? this.footerH_() : 0;
    // 精确定位模式：pageHeight 已包含 paddingBottom（页脚在其上方叠加），
    // TextLayout 内部会减去 paddingTop/paddingBottom，无需再额外减 footerH
    this.pages = TextLayout.splitIntoPages(text, lc, this.pageW, this.pageH, this.measureUtil_ || undefined);
    if (this.pages.length === 0) this.pages = [{ lines: [], startOffset: 0, endOffset: 0 }];
    if (this.pageIndex >= this.pages.length) this.pageIndex = 0;
    this.scrollText = scrollText;
  }

  private onStyleChange(c: PageViewConfig): void {
    this.cfg = c;
    this.readBgColor = c.bgColor;
    this.readTextColor = c.textColor;
    this.pageMode = c.pageMode;
    // 即时应用简繁转换
    let text = this.text;
    if (c.chineseMode !== 'original' && text) {
      text = convertChinese(text, c.chineseMode);
    }
    this.layoutText(text);
    // 持久化设置
    (async () => {
      try {
        const s = SettingsStore.getInstance();
        await s.init(getContext());
        s.setFontSize(c.fontSize).catch(() => {});
        s.setFontFamily(c.fontFamily).catch(() => {});
        s.setLineHeight(c.lineHeight).catch(() => {});
        s.setIndentSize(c.indentSize).catch(() => {});
        s.setLetterSpacing(c.letterSpacing).catch(() => {});
        s.setParagraphSpacing(c.paragraphSpacing).catch(() => {});
        s.setFontWeight(c.fontWeight).catch(() => {});
        s.setPaddingTop(c.paddingTop).catch(() => {});
        s.setPaddingBottom(c.paddingBottom).catch(() => {});
        s.setPaddingLeft(c.paddingLeft).catch(() => {});
        s.setPaddingRight(c.paddingRight).catch(() => {});
        s.setReadBgColor(c.bgColor).catch(() => {});
        s.setReadTextColor(c.textColor).catch(() => {});
        s.setChineseMode(c.chineseMode).catch(() => {});
        s.setZhFormat(c.zhFormat).catch(() => {});
        s.setPageMode(c.pageMode ? 1 : 0).catch(() => {});
      } catch (_e) { /* ignore */ }
    })();
  }

  private onPageTurn(ev: PageTurnEvent): void { this.pageIndex = ev.currentPage; }
  private onPrevChapter(): void {
    if (this.currentIndex > 0) {
      this.justLoadedChapter_ = true;
      this.loadChapter(this.currentIndex - 1).then(() => {
        this.pageIndex = Math.max(0, this.pages.length - 1);
        this.scroller_.scrollEdge(Edge.Bottom);
      });
    }
  }
  private async onNextChapter(): Promise<void> {
    const n = this.currentIndex + 1;
    if (n >= this.totalChapters_) return;
    // 无缝翻页：尝试使用预加载内容
    if (await this.tryUsePreloadedChapter_(n)) {
      this.scroller_.scrollTo({ xOffset: 0, yOffset: 0 });
      this.justLoadedChapter_ = true;
      return;
    }
    console.info('[ReadPage] Fallback loadChapter for:', n);
    this.loadChapter(n).then(() => {
      this.scroller_.scrollTo({ xOffset: 0, yOffset: 0 });
      this.justLoadedChapter_ = true;
    });
  }
  private onPrevPage(): void { if (this.pageIndex > 0) this.pageIndex--; else this.onPrevChapter(); }
  private onNextPage(): void { if (this.pageIndex < this.pages.length - 1) this.pageIndex++; else this.onNextChapter(); }

  private onOpenToc(): void {
    ChapterCache.chapters = this.allChapters_;
    ChapterCache.bookUrl = this.bookUrl;
    router.pushUrl({ url: 'pages/ChapterListPage', params: { from: 'ReadPage', bookName: this.bookName, bookAuthor: this.bookAuthor, bookUrl: this.bookUrl, originUrl: this.originUrl, durChapterIndex: this.currentIndex } });
  }

  private onOpenSearchContent(): void {
    if (this.allChapters_.length === 0) {
      promptAction.showToast({ message: '章节列表未加载', duration: 1500 });
      return;
    }
    ChapterCache.chapters = this.allChapters_;
    ChapterCache.bookUrl = this.bookUrl;
    router.pushUrl({
      url: 'pages/SearchContentPage',
      params: {
        bookId: this.bookId_,
        bookName: this.bookName,
        bookAuthor: this.bookAuthor,
        bookUrl: this.bookUrl,
        originUrl: this.originUrl,
        currentIndex: this.currentIndex,
      }
    });
  }

  private resetReadStateForSourceChange_(): void {
    this.source_ = null;
    this.bookId_ = -1;
    this.targetIdx_ = 0;
    this.currentIndex = 0;
    this.pageIndex = 0;
    this.text = '';
    this.scrollText = '';
    this.pages = [];
    this.chapters = [];
    this.allChapters_ = [];
    this.totalChapters_ = 0;
    this.nextChapterContent_ = '';
    this.nextChapterIdx_ = -1;
    this.isPreloading_ = false;
    this.preloadingChapterPromises_.clear();
    this.scrollAtTop_ = true;
    this.justLoadedChapter_ = false;
    ChapterCache.bookUrl = '';
    ChapterCache.chapters = [];
    ChapterCache.targetIndex = -1;
  }

  private async applySourceChange(result: SearchResult): Promise<void> {
    const newBookUrl = result.noteUrl || '';
    const newOriginUrl = result.originUrl || '';
    if (!newBookUrl || !newOriginUrl) {
      promptAction.showToast({ message: '书源信息不完整', duration: 1500 });
      return;
    }
    if (newBookUrl === this.bookUrl && newOriginUrl === this.originUrl) {
      promptAction.showToast({ message: '已经是当前书源', duration: 1200 });
      return;
    }

    this.showMenu = false;
    const oldBookUrl = this.bookUrl;
    try {
      this.saveProgress();
    } catch (_e) {
      /* ignore */
    }

    promptAction.showToast({ message: '正在更换书源...', duration: 1000 });
    try {
      await AppDatabase.getInstance().waitForInit();
      const bookTable = new BookTable(AppDatabase.getInstance().rdbStore);
      const shelfBook = oldBookUrl ? await bookTable.getBookByUrl(oldBookUrl) : null;

      this.origin = result.origin || this.origin;
      this.originUrl = newOriginUrl;
      this.bookUrl = newBookUrl;
      this.tocUrl = '';
      this.resetReadStateForSourceChange_();
      this.isLoading = true;

      if (shelfBook) {
        shelfBook.bookUrl = this.bookUrl;
        shelfBook.origin = this.origin;
        shelfBook.originUrl = this.originUrl;
        shelfBook.tocUrl = '';
        if (result.coverUrl) shelfBook.coverUrl = result.coverUrl;
        if (result.kind) shelfBook.kind = result.kind;
        if (result.wordCount) shelfBook.wordCount = result.wordCount;
        if (result.introduce) shelfBook.introduce = result.introduce;
        shelfBook.latestChapterTitle = result.latestChapterTitle || '';
        shelfBook.chapterCount = 0;
        shelfBook.totalChapterNum = 0;
        shelfBook.durChapterTitle = '';
        shelfBook.durChapterIndex = 0;
        shelfBook.durChapterPos = 0;
        shelfBook.durChapterProgress = 0;
        shelfBook.lastUpdateTime = result.lastUpdateTime || shelfBook.lastUpdateTime;
        shelfBook.lastOpenTime = Date.now();
        shelfBook.updateTime = Date.now();
        await bookTable.updateBook(shelfBook);
        this.bookId_ = shelfBook.id;
        const chapterTable = new ChapterTable(AppDatabase.getInstance().rdbStore);
        await chapterTable.deleteChaptersByBookId(shelfBook.id);
        AppStorage.set<number>('shelfRefreshCounter', (AppStorage.get<number>('shelfRefreshCounter') || 0) + 1);
      }

      await this.loadContent();
      promptAction.showToast({ message: '已更换书源', duration: 1500 });
    } catch (e) {
      console.error('[ReadPage] applySourceChange failed:', (e as Error).message);
      this.isLoading = false;
      promptAction.showToast({ message: '换源失败', duration: 1500 });
    }
  }

  private openSourceSheet(): void {
    // 读取保存的搜索结果缓存（从 BookInfoPage 进入时写入了 router params）
    let cachedForSheet: SearchResult[] = [];
    try {
      const p = router.getParams() as Record<string, Object>;
      if (p['cachedSources']) {
        cachedForSheet = JSON.parse(String(p['cachedSources'])) as SearchResult[];
      }
    } catch (_e) { /* ignore */ }

    this.sourceDlg = new CustomDialogController({
      builder: ChangeSourceSheet({
        controller: this.sourceDlg!,
        bookName: this.bookName,
        bookAuthor: this.bookAuthor,
        currentOriginUrl: this.originUrl,
        cachedSources: cachedForSheet,
        onReplace: (result: SearchResult) => { this.applySourceChange(result); },
        onAddAsNew: (_result: SearchResult) => {
          promptAction.showToast({ message: '阅读页暂不支持作为新书加入', duration: 1500 });
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      customStyle: true
    });
    this.sourceDlg.open();
  }

  private formatCurTime(): string {
    const d = new Date();
    const hh = String(d.getHours()).padStart(2, '0');
    const mm = String(d.getMinutes()).padStart(2, '0');
    return `${hh}:${mm}`;
  }

  private footerH_(): number { return 20; }

  private initAloudEngine_(): void {
    if (this.aloudEngine_) {
      try { this.aloudEngine_.release(); } catch (_) {}
      this.aloudEngine_ = null;
    }
    this.aloudEngine_ = new ReadAloudEngine({
      onStateChange: (s: AloudState) => {
        console.info('[ReadPage] Aloud state: ' + s);
      },
      onProgress: (_charIdx: number, _total: number) => { },
      onChapterEnd: () => {
        this.onNextChapter();
      },
      onError: (msg: string) => {
        console.error('[ReadPage] Aloud error: ' + msg);
        promptAction.showToast({ message: msg, duration: 2000 });
      },
    });
  }

  build() {
    Stack() {
      if (this.isLoading) {
        Column() { LoadingProgress().width(40).height(40).color('#0078D7') }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
      } else if (!this.pageMode && this.scrollText) {
        Scroll(this.scroller_) {
          Text(this.scrollText)
            .fontSize(this.cfg.fontSize).fontColor(this.readTextColor)
            .fontWeight(this.cfg.fontWeight === 0 ? FontWeight.Lighter : this.cfg.fontWeight === 2 ? FontWeight.Bold : FontWeight.Normal)
            .fontFamily(this.cfg.fontFamily)
            .lineHeight(this.cfg.fontSize * this.cfg.lineHeight)
            .letterSpacing(this.cfg.letterSpacing)
            .width('100%')
            .padding({ left: this.cfg.paddingLeft, right: this.cfg.paddingRight, top: this.cfg.paddingTop, bottom: this.cfg.paddingBottom })
        }
        .width('100%').height('100%').backgroundColor(this.readBgColor)
        .onClick(() => { this.showMenu = true; })
        .onScrollEdge((side: Edge) => {
          if (!this.justLoadedChapter_ && side === Edge.Bottom) { this.onNextChapter(); }
        })
        .onScroll((_x: number, y: number) => {
          if (this.justLoadedChapter_) return;
          if (y <= 0 && !this.scrollAtTop_) {
            this.scrollAtTop_ = true;
          }
        })
        .onScrollStop(() => {
          if (this.justLoadedChapter_) { this.justLoadedChapter_ = false; return; }
          if (this.scrollAtTop_ && this.currentIndex > 0 &&
              this.scroller_.currentOffset().yOffset <= 0) {
            this.scrollAtTop_ = false;
            this.onPrevChapter();
          }
        })
      } else if (this.pages.length > 0) {
        PageView({
          pages: this.pages, chapterTitle: this.allChapters_[this.currentIndex]?.title || '',
          chapterIndex: this.currentIndex, pageIndex: this.pageIndex, totalChapters: this.totalChapters_,
          zoneActions: this.zoneActions,
          config: {
            animType: this.cfg.animType, bgColor: this.cfg.bgColor, textColor: this.cfg.textColor,
            titleColor: this.cfg.titleColor, fontSize: this.cfg.fontSize, fontWeight: this.cfg.fontWeight,
            fontFamily: this.cfg.fontFamily, lineHeight: this.cfg.lineHeight, letterSpacing: this.cfg.letterSpacing,
            paragraphSpacing: this.cfg.paragraphSpacing, textAlign: this.cfg.textAlign, indentSize: this.cfg.indentSize,
            paddingTop: this.cfg.paddingTop, paddingBottom: this.cfg.paddingBottom,
            paddingLeft: this.cfg.paddingLeft, paddingRight: this.cfg.paddingRight,
            showHeader: false, showFooter: false, headerContent: '', footerContent: '',
            brightness: this.cfg.brightness, zhFormat: this.cfg.zhFormat, chineseMode: this.cfg.chineseMode,
            pageMode: this.cfg.pageMode,
          },
          onPageTurn: (ev: PageTurnEvent) => { this.onPageTurn(ev); },
          onPrevChapter: () => { this.onPrevChapter(); },
          onNextChapter: () => { this.onNextChapter(); },
          onShowMenu: () => { this.showMenu = true; },
          onShowToc: () => { this.onOpenToc(); },
          onMeasured: (cw: number, lh: number) => {
            if (cw > 0 && this.measureCharW_ !== cw) { this.measureCharW_ = cw; }
            if (lh > 0 && this.measureLineH_ !== lh) { this.measureLineH_ = lh; }
          },
        }).width('100%').height('100%')
      }
      // 页脚：直接渲染在 ReadPage Stack 中，PageView 上方
      if (!this.isLoading && this.pages.length > 0 && this.cfg.showFooter) {
        Stack({ alignContent: Alignment.Bottom }) {
          Column() {
            Row().width('100%').height(1).backgroundColor(this.isDark ? '#555' : '#CCC')
              .margin({ top: 4, bottom: 4 })
            Row() {
              Text(this.allChapters_[this.currentIndex]?.title || '')
                .fontSize(11).fontColor(this.isDark ? '#AAA' : '#999')
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
              Text(this.formatCurTime())
                .fontSize(11).fontColor(this.isDark ? '#AAA' : '#999').margin({ right: 10 })
              Text(`${this.pageIndex + 1}/${this.pages.length}` +
                (this.totalChapters_ > 0 ? ` (${this.getProgressPercent()}%)` : ''))
                .fontSize(11).fontColor(this.isDark ? '#AAA' : '#999')
            }.width('100%')
              .padding({ left: this.cfg.paddingLeft, right: this.cfg.paddingRight })
          }
          .width('100%')
          .backgroundColor(this.readBgColor)
        }
        .width('100%').height('100%')
        .hitTestBehavior(HitTestMode.None)
      }
      if (this.showMenu) {
        Column() {
          Column().width('100%').layoutWeight(1).onClick(() => { this.showMenu = false; })
          ReadBottomMenu({
            onToc: () => { this.showMenu = false; this.onOpenToc(); },
            onReadAloud: () => { this.showMenu = false; if (!this.aloudEngine_) { promptAction.showToast({message:'请先加载章节内容',duration:1500}); return; } this.showAloud = true; },
            onBookmark: () => { this.showMenu = false; promptAction.showToast({message:'书签功能开发中',duration:1500}); },
            onStyle: () => { this.showMenu = false; this.showStyle = true; },
            onSettings: () => { this.showMenu = false; this.showZoneConfig = true; },
            onSearch: () => { this.showMenu = false; this.onOpenSearchContent(); },
            onSource: () => { this.showMenu = false; this.openSourceSheet(); },
            onCache: () => { this.showMenu = false; this.showCacheDialog = true; },
            onRefresh: () => { this.showMenu = false; this.loadChapter(this.currentIndex); promptAction.showToast({message:'已刷新',duration:1500}); },
          })
        }.width('100%').height('100%')
      }
      if (this.showStyle) {
        Column() {
          Column().width('100%').layoutWeight(1).onClick(() => { this.showStyle = false; })
          StylePanel({
            cfg: this.cfg, onChange: (c: PageViewConfig) => { this.onStyleChange(c); },
            onDismiss: () => { this.showStyle = false; },
          })
        }.width('100%').height('100%')
      }
      if (this.showCacheDialog) {
        Column() {
          Column().width('100%').layoutWeight(1).onClick(() => { this.showCacheDialog = false; })
          CacheDialog({
            bookName: this.bookName,
            bookOriginUrl: this.bookUrl,
            bookId: this.bookId_,
            source: this.source_,
            chapters: this.allChapters_,
            totalChapters: this.totalChapters_,
            currentIndex: this.currentIndex,
            onDismiss: () => { this.showCacheDialog = false; },
            onCacheComplete: () => { promptAction.showToast({ message: '缓存完成', duration: 1500 }); },
            onCacheStart: () => {},
          })
        }.width('100%').height('100%')
      }

      if (this.showAloud) {
        Column() {
          Column().width('100%').layoutWeight(1).onClick(() => { this.showAloud = false; })
          ReadAloudPanel({
            text: this.text,
            chapterTitle: this.chapters[this.currentIndex]?.title || '',
            externalEngine: this.aloudEngine_!,
            onDismiss: () => { this.showAloud = false; },
            onNextChapter: () => { this.showAloud = false; this.onNextChapter(); },
            onPrevChapter: () => { this.showAloud = false; this.onPrevChapter(); },
          })
        }.width('100%').height('100%')
      }
      if (this.showZoneConfig) {
        Column() {
          Column().width('100%').layoutWeight(1).onClick(() => { this.showZoneConfig = false; })
          ClickActionConfig({
            onDismiss: () => { this.showZoneConfig = false; },
            onChanged: (actions: number[]) => { this.zoneActions = [...actions]; },
          })
        }.width('100%').height('100%')
      }
    }
    .width('100%').height('100%').backgroundColor(this.readBgColor)
    .onAreaChange((_old: Area, n: Area) => {
      const w = typeof n.width === 'number' ? n.width : Number(n.width) || 360;
      const h = typeof n.height === 'number' ? n.height : Number(n.height) || 640;
      if (w > 0 && h > 0) { this.pageW = w; this.pageH = h; if (this.text) this.layoutText(this.text); }
    })
  }
}
