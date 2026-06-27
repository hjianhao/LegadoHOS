/**
 * 阅读页
 */
import router from '@ohos.router';
import { BookSource, BookSourceChapter } from '../model/BookSource';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { SettingsStore } from '../data/preferences/SettingsStore';
import { ChapterCache } from '../util/ChapterCache';
import { TextLayout, LayoutConfig, LayoutPage, DEFAULT_LAYOUT_CONFIG } from '../engine/book/TextLayout';
import { PageView, PageViewConfig, PageTurnAnim, PageTurnEvent } from '../components/reader/PageView';
import { ClickAction, DEFAULT_ZONE_ACTIONS } from '../components/reader/ClickAction';
import { StylePanel } from '../components/reader/StylePanel';
import { ReadBottomMenu } from '../components/reader/ReadBottomMenu';
import { NetUtil } from '../util/NetUtil';
import { HtmlUtil } from '../util/HtmlUtil';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookTable } from '../data/database/BookTable';
import { BookSourceTable } from '../data/database/BookSourceTable';
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
  @State showMenu: boolean = false;
  @State showStyle: boolean = false;
  @State readBgColor: string = '#F5F0E8';
  @State readTextColor: string = '#333333';
  @State zoneActions: number[] = DEFAULT_ZONE_ACTIONS;
  @State cfg: PageViewConfig = {
    animType: PageTurnAnim.SLIDE, bgColor: '#F5F0E8', textColor: '#333333', titleColor: '#999',
    fontSize: 18, fontWeight: 1, fontFamily: 'HarmonyOS Sans', lineHeight: 1.6,
    letterSpacing: 0.5, paragraphSpacing: 10, textAlign: 'justify', indentSize: 2,
    paddingTop: 24, paddingBottom: 24, paddingLeft: 20, paddingRight: 20,
    showHeader: false, showFooter: true, headerContent: '', footerContent: '',
    brightness: 80, zhFormat: true, chineseMode: 'original',
  };
  @State pageW: number = 360;
  @State pageH: number = 640;
  private source_: BookSource | null = null;
  private targetIdx_: number = -1;
  private allChapters_: BookSourceChapter[] = [];
  private totalChapters_: number = 0;

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
  }

  onPageShow(): void {
    if (!this.isLoading) return;
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
      this.readBgColor = await s.getReadBgColor();
      this.readTextColor = await s.getReadTextColor();
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

      let chapters = ChapterCache.chapters;
      if (!chapters || chapters.length === 0) {
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
      await this.loadChapter(this.currentIndex);
    } catch (e) {
      this.text = '加载失败';
      this.isLoading = false;
    }
  }

  private async loadChapter(idx: number): Promise<void> {
    if (idx < 0 || idx >= this.allChapters_.length) return;
    this.isLoading = true;
    this.currentIndex = idx;
    this.pageIndex = 0;
    const ch = this.allChapters_[idx];
    const url = ch.url || this.bookUrl;
    try {
      let content = '';
      if (this.source_) {
        content = await globalSourceExecutor.getContent(this.source_, url, this.bookUrl);
      }
      if (!content && url && url.startsWith('http')) {
        const r = await NetUtil.httpGet(url);
        if (r) content = HtmlUtil.stripHtml(r);
      }
      if (content && content.length > 50) {
        this.text = content;
        this.layoutText(content);
      } else {
        this.text = content || '加载失败';
        this.layoutText(this.text);
      }
    } catch (e) {
      this.text = '加载失败';
    }
    this.isLoading = false;
    // 保存阅读进度
    this.saveProgress();
  }

  private saveProgress(): void {
    const ch = this.allChapters_[this.currentIndex];
    if (!ch || !this.bookUrl) return;
    const bookTable = new BookTable(AppDatabase.getInstance().rdbStore);
    bookTable.updateReadingProgress(this.bookUrl, this.currentIndex, ch.title || '', this.totalChapters_)
      .catch(() => { /* ignore */ });
  }

  private layoutText(text: string): void {
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
      measuredCharWidth: 0,
      measuredLineHeight: 0,
    };
    this.pages = TextLayout.splitIntoPages(text, lc, this.pageW, this.pageH);
    if (this.pages.length === 0) this.pages = [{ lines: [], startOffset: 0, endOffset: 0 }];
    if (this.pageIndex >= this.pages.length) this.pageIndex = 0;
    this.scrollText = text;
  }

  private onStyleChange(c: PageViewConfig): void {
    this.cfg = c;
    this.readBgColor = c.bgColor;
    this.readTextColor = c.textColor;
    this.layoutText(this.text);
  }

  private onPageTurn(ev: PageTurnEvent): void { this.pageIndex = ev.currentPage; }
  private onPrevChapter(): void {
    if (this.currentIndex > 0) { this.loadChapter(this.currentIndex - 1).then(() => { this.pageIndex = Math.max(0, this.pages.length - 1); }); }
  }
  private onNextChapter(): void {
    const n = this.currentIndex + 1;
    if (n < this.totalChapters_) this.loadChapter(n);
  }
  private onPrevPage(): void { if (this.pageIndex > 0) this.pageIndex--; else this.onPrevChapter(); }
  private onNextPage(): void { if (this.pageIndex < this.pages.length - 1) this.pageIndex++; else this.onNextChapter(); }

  private onOpenToc(): void {
    ChapterCache.chapters = this.allChapters_;
    ChapterCache.bookUrl = this.bookUrl;
    router.pushUrl({ url: 'pages/ChapterListPage', params: { from: 'ReadPage', bookName: this.bookName, bookAuthor: this.bookAuthor, bookUrl: this.bookUrl, originUrl: this.originUrl, durChapterIndex: this.currentIndex } });
  }

  build() {
    Stack() {
      if (this.isLoading) {
        Column() { LoadingProgress().width(40).height(40).color('#0078D7') }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
      } else if (!this.pageMode && this.scrollText) {
        Scroll(new Scroller()) {
          Text(this.scrollText).fontSize(this.cfg.fontSize).fontColor(this.readTextColor).width('100%').padding(16)
        }.width('100%').height('100%').backgroundColor(this.readBgColor).onClick(() => { this.showMenu = true; })
      } else if (this.pages.length > 0) {
        PageView({
          pages: this.pages, chapterTitle: this.allChapters_[this.currentIndex]?.title || '',
          chapterIndex: this.currentIndex, pageIndex: this.pageIndex, totalChapters: this.totalChapters_,
          zoneActions: this.zoneActions, config: this.cfg,
          onPageTurn: (ev: PageTurnEvent) => { this.onPageTurn(ev); },
          onPrevChapter: () => { this.onPrevChapter(); },
          onNextChapter: () => { this.onNextChapter(); },
          onShowMenu: () => { this.showMenu = true; },
          onShowToc: () => { this.onOpenToc(); },
        }).width('100%').height('100%')
      }
      if (this.showMenu) {
        Column() {
          Column() {}.layoutWeight(1).onClick(() => { this.showMenu = false; })
          ReadBottomMenu({
            onToc: () => { this.showMenu = false; this.onOpenToc(); },
            onReadAloud: () => { this.showMenu = false; promptAction.showToast({message:'朗读功能开发中',duration:1500}); },
            onBookmark: () => { this.showMenu = false; promptAction.showToast({message:'书签功能开发中',duration:1500}); },
            onStyle: () => { this.showMenu = false; this.showStyle = true; },
            onSettings: () => { this.showMenu = false; this.showStyle = true; },
            onSource: () => { this.showMenu = false; promptAction.showToast({message:'换源功能开发中',duration:1500}); },
            onCache: () => { this.showMenu = false; promptAction.showToast({message:'缓存已触发',duration:1500}); },
            onRefresh: () => { this.showMenu = false; this.loadChapter(this.currentIndex); promptAction.showToast({message:'已刷新',duration:1500}); },
          })
        }.width('100%').height('100%')
      }
      if (this.showStyle) {
        Column() {
          Column() {}.layoutWeight(1).onClick(() => { this.showStyle = false; })
          StylePanel({
            cfg: this.cfg, onChange: (c: PageViewConfig) => { this.onStyleChange(c); },
            onDismiss: () => { this.showStyle = false; },
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
