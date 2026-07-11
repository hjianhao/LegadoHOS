/**
 * 漫画阅读页
 *
 * 支持图片型书源（bookSourceType=2）的漫画阅读。
 * 功能：条漫滚动模式 / 翻页模式、上下章切换、进度保存、目录跳转。
 */
import { BookSource, BookSourceChapter } from '../model/BookSource';
import { ThemeColors } from '../theme/ThemeColors';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { ChapterCache } from '../util/ChapterCache';
import { NetUtil } from '../util/NetUtil';
import { ContentCleaner } from '../util/ContentCleaner';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookTable } from '../data/database/BookTable';
import { ChapterTable } from '../data/database/ChapterTable';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { BookChapter } from '../model/BookChapter';
import { UiUtil } from '../util/UiUtil';

@Entry
@Component
struct ComicReadPage {
  @StorageLink('isDark') isDark: boolean = false;

  // 书籍信息
  @State bookName: string = '';
  @State bookUrl: string = '';
  @State originUrl: string = '';
  @State origin: string = '';
  @State tocUrl: string = '';

  // 章节状态
  @State chapters: BookSourceChapter[] = [];
  @State currentIndex: number = 0;
  @State chapterTitle: string = '';
  @State totalChapters: number = 0;

  // 图片状态
  @State imageUrls: string[] = [];
  @State isLoading: boolean = true;
  @State loadError: string = '';

  // UI 状态
  @State showMenu: boolean = false;
  @State pageMode: boolean = false;  // false=滚动(条漫), true=翻页
  @State currentPageIndex: number = 0;

  // 内部状态
  private source_: BookSource | null = null;
  private bookId_: number = -1;
  private targetIdx_: number = -1;
  private allChapters_: BookSourceChapter[] = [];
  private listScroller_: ListScroller = new ListScroller();
  private swiperController_: SwiperController = new SwiperController();
  private justLoadedChapter_: boolean = false;
  private nextChapterContent_: string = '';
  private nextChapterIdx_: number = -1;
  private preloadingChapterPromises_: Map<number, Promise<string>> = new Map<number, Promise<string>>();
  // 图片加载失败标记（key = url）
  @State failedImages: Set<string> = new Set<string>();

  aboutToAppear(): void {
    const p = UiUtil.getParams(this.getUIContext()) as Record<string, Object>;
    this.bookName = String(p['bookName'] || p['name'] || '');
    this.bookUrl = String(p['bookUrl'] || '');
    this.originUrl = String(p['originUrl'] || '');
    this.origin = String(p['origin'] || '');
    this.tocUrl = String(p['tocUrl'] || '');
    if (p['durChapterIndex'] !== undefined) this.targetIdx_ = Number(p['durChapterIndex']);
  }

  onPageShow(): void {
    if (!this.isLoading) {
      // 从目录页返回时，通过 ChapterCache 获取目标章节索引
      if (ChapterCache.targetIndex >= 0) {
        const idx = ChapterCache.targetIndex;
        ChapterCache.targetIndex = -1;
        if (ChapterCache.chapters.length > 0 && ChapterCache.bookUrl === this.bookUrl) {
          this.allChapters_ = ChapterCache.chapters;
          this.totalChapters = ChapterCache.chapters.length;
          this.chapters = ChapterCache.chapters;
        }
        if (idx < this.allChapters_.length && idx !== this.currentIndex) {
          this.loadChapterImages(idx);
        }
      }
      return;
    }
    this.loadContent();
  }

  private async loadContent(): Promise<void> {
    this.isLoading = true;
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;

      // 书架只传 bookUrl，从 DB 补全
      try {
        const bookTable = new BookTable(db);
        const book = await bookTable.getBookByUrl(this.bookUrl);
        if (book) {
          this.bookId_ = book.id;
          if (!this.tocUrl) this.tocUrl = book.tocUrl || '';
          if (!this.originUrl) this.originUrl = book.originUrl || '';
          if (!this.origin) this.origin = book.origin || '';
          if (!this.bookName) this.bookName = book.name || '';
          if (this.targetIdx_ < 0) this.targetIdx_ = book.durChapterIndex || 0;
        }
      } catch (_) { /* ignore */ }

      // 匹配书源
      const srcDao = new BookSourceTable(db);
      const sources = await srcDao.getAllSources();
      const norm = this.originUrl.replace(/\/+$/, '');
      this.source_ = sources.find(s => s.sourceUrl === this.originUrl) ||
        sources.find(s => s.sourceUrl.replace(/\/+$/, '') === norm) ||
        sources.find(s => s.sourceName === this.origin) || null;
      console.info('[ComicRead] loadContent: source_=', this.source_ ? this.source_.sourceName : 'NULL',
        'bookUrl=', this.bookUrl.substring(0, 80));

      // 加载章节列表
      let chapters: BookSourceChapter[] = [];
      if (ChapterCache.chapters.length > 0 && ChapterCache.bookUrl === this.bookUrl) {
        chapters = ChapterCache.chapters;
      } else {
        // 从数据库加载缓存的目录
        if (this.bookId_ > 0) {
          try {
            const ct = new ChapterTable(db);
            const dbChapters = await ct.getChaptersByBookId(this.bookId_);
            if (dbChapters.length > 0) {
              chapters = dbChapters.map((ch: BookChapter): BookSourceChapter => ({
                index: ch.index, title: ch.title, url: ch.url,
              }));
            }
          } catch (_e) { /* fall through to network */ }
        }
        // 从网络刷新目录
        if (chapters.length === 0 && this.source_) {
          const primaryTocUrl = this.tocUrl || this.bookUrl;
          chapters = await globalSourceExecutor.getToc(this.source_, primaryTocUrl);
          if (chapters.length === 0 && primaryTocUrl !== this.bookUrl) {
            const fallback = await globalSourceExecutor.getToc(this.source_, this.bookUrl);
            if (fallback.length > 0) chapters = fallback;
          }
          // 保存到 DB
          if (chapters.length > 0 && this.bookId_ > 0) {
            await this.saveFullTocToDb_(this.bookId_, chapters);
          }
        }
      }

      if (chapters.length === 0) {
        this.loadError = '无目录';
        this.isLoading = false;
        return;
      }
      this.allChapters_ = chapters;
      this.totalChapters = chapters.length;
      this.chapters = chapters;
      if (ChapterCache.bookUrl !== this.bookUrl || ChapterCache.chapters.length === 0) {
        ChapterCache.chapters = chapters;
        ChapterCache.bookUrl = this.bookUrl;
      }

      // 恢复阅读位置
      if (this.targetIdx_ >= 0 && this.targetIdx_ < this.allChapters_.length) {
        this.currentIndex = this.targetIdx_;
      } else {
        this.currentIndex = 0;
      }

      await this.loadChapterImages(this.currentIndex);
    } catch (e) {
      this.loadError = '加载失败: ' + (e as Error).message;
      this.isLoading = false;
    }
  }

  private async loadChapterImages(idx: number): Promise<void> {
    if (idx < 0 || idx >= this.allChapters_.length) return;
    this.isLoading = true;
    this.currentIndex = idx;
    this.currentPageIndex = 0;
    this.failedImages = new Set<string>();
    const ch = this.allChapters_[idx];
    this.chapterTitle = ch?.title || '';
    console.info('[ComicRead] loadChapterImages: idx=', idx, 'title=', ch?.title);

    // 尝试从数据库缓存加载
    let content: string = await this.readChapterCache_(idx);
    if (!content || content.length < 10) {
      content = await this.fetchChapterContent_(idx);
    }

    if (content) {
      const baseUrl: string = ch?.url || this.bookUrl || this.source_?.sourceUrl || '';
      const urls: string[] = globalSourceExecutor.extractImageUrls(content, baseUrl);
      console.info('[ComicRead] extractImageUrls: found', urls.length, 'images');
      if (urls.length > 0) {
        this.imageUrls = urls;
      } else {
        this.imageUrls = [];
        this.loadError = '本章没有图片';
      }
    } else {
      this.imageUrls = [];
      this.loadError = '加载失败';
    }

    this.isLoading = false;
    this.saveProgress();
    this.preloadNextChapter_(idx);
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
      // preserveImages=true：保留 <img> 标签
      content = await globalSourceExecutor.getContent(this.source_, url, this.bookUrl, true);
      console.info('[ComicRead] getContent(preserveImages) returned:', content.length, 'chars');
    }
    if (!content && url && url.startsWith('http')) {
      const r = await NetUtil.httpGet(url);
      if (r) content = ContentCleaner.formatKeepImg(r, url);
    }
    // 保存到 DB 缓存
    if (content && content.length > 10) {
      await this.saveToDbCache_(idx, content);
    }
    return content;
  }

  /** 预加载下一章 */
  private preloadNextChapter_(currentIdx: number): void {
    const nextIdx = currentIdx + 1;
    if (nextIdx >= this.allChapters_.length || this.preloadingChapterPromises_.has(nextIdx)) return;
    const promise = this.readChapterCache_(nextIdx)
      .then((cached: string): Promise<string> | string => {
        if (cached && cached.length > 10) return cached;
        return this.fetchChapterContent_(nextIdx);
      });
    this.preloadingChapterPromises_.set(nextIdx, promise);
    promise
      .then((content: string): void => {
        if (content && content.length > 10) {
          this.nextChapterContent_ = content;
          this.nextChapterIdx_ = nextIdx;
        }
      })
      .catch((_e: Error) => { /* ignore */ })
      .then(() => {
        this.preloadingChapterPromises_.delete(nextIdx);
      });
  }

  private async tryUsePreloadedChapter_(idx: number): Promise<boolean> {
    let content: string = '';
    if (this.nextChapterIdx_ === idx && this.nextChapterContent_ && this.nextChapterContent_.length > 10) {
      content = this.nextChapterContent_;
    } else {
      const pending = this.preloadingChapterPromises_.get(idx);
      if (pending) {
        try { content = await pending; } catch (_) { content = ''; }
      }
      if (!content) content = await this.readChapterCache_(idx);
    }
    if (!content || content.length <= 10) return false;

    const ch = this.allChapters_[idx];
    const baseUrl: string = ch?.url || this.bookUrl || this.source_?.sourceUrl || '';
    const urls: string[] = globalSourceExecutor.extractImageUrls(content, baseUrl);
    if (urls.length === 0) return false;

    this.currentIndex = idx;
    this.chapterTitle = ch?.title || '';
    this.imageUrls = urls;
    this.currentPageIndex = 0;
    this.failedImages = new Set<string>();
    this.isLoading = false;
    if (this.nextChapterIdx_ === idx) {
      this.nextChapterContent_ = '';
      this.nextChapterIdx_ = -1;
    }
    this.saveProgress();
    this.preloadNextChapter_(idx);
    return true;
  }

  private async saveToDbCache_(idx: number, content: string): Promise<void> {
    if (this.bookId_ <= 0 || !content || content.length <= 10) return;
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

  private async saveFullTocToDb_(bookId: number, chapters: BookSourceChapter[]): Promise<void> {
    try {
      const ct = new ChapterTable(AppDatabase.getInstance().rdbStore);
      await ct.deleteChaptersByBookId(bookId);
      const now = Date.now();
      const newChapters: BookChapter[] = chapters.map((ch: BookSourceChapter, idx: number): BookChapter => ({
        id: 0, bookId: bookId, index: ch.index >= 0 ? ch.index : idx, volumeIndex: 0,
        title: ch.title || '', url: ch.url || '',
        content: '', contentLength: 0,
        isRead: false, isDownloaded: false, isCached: false,
        duration: 0, audioUrl: '', createTime: now, updateTime: now,
      }));
      await ct.insertChapters(newChapters);
    } catch (e) {
      console.warn('[ComicRead] Failed to save TOC to DB:', (e as Error).message);
    }
  }

  private saveProgress(): void {
    const ch = this.allChapters_[this.currentIndex];
    if (!ch || !this.bookUrl) return;
    const bookTable = new BookTable(AppDatabase.getInstance().rdbStore);
    bookTable.updateReadingProgress(this.bookUrl, this.currentIndex, ch.title || '', this.totalChapters, 0).catch(() => {});
  }

  async aboutToDisappear(): Promise<void> {
    const ch = this.allChapters_[this.currentIndex];
    if (ch && this.bookUrl) {
      const bookTable = new BookTable(AppDatabase.getInstance().rdbStore);
      try { await bookTable.updateReadingProgress(this.bookUrl, this.currentIndex, ch.title || '', this.totalChapters, 0); } catch (_) { /* ignore */ }
    }
  }

  // ============ 章节导航 ============

  private onPrevChapter(): void {
    if (this.currentIndex > 0) {
      this.justLoadedChapter_ = true;
      this.loadChapterImages(this.currentIndex - 1).then(() => {
        // 滚动到底部
        setTimeout(() => {
          this.listScroller_.scrollToIndex(this.imageUrls.length - 1);
        }, 100);
      });
    }
  }

  private async onNextChapter(): Promise<void> {
    const n = this.currentIndex + 1;
    if (n >= this.totalChapters) return;
    // 尝试使用预加载内容
    if (await this.tryUsePreloadedChapter_(n)) {
      this.justLoadedChapter_ = true;
      return;
    }
    this.loadChapterImages(n).then(() => {
      this.listScroller_.scrollTo({ xOffset: 0, yOffset: 0 });
      this.justLoadedChapter_ = true;
    });
  }

  private onOpenToc(): void {
    ChapterCache.chapters = this.allChapters_;
    ChapterCache.bookUrl = this.bookUrl;
    UiUtil.pushUrl(this.getUIContext(), {
      url: 'pages/ChapterListPage',
      params: {
        from: 'ComicReadPage', bookName: this.bookName, bookAuthor: '',
        bookUrl: this.bookUrl, tocUrl: this.tocUrl, originUrl: this.originUrl,
        durChapterIndex: this.currentIndex,
      }
    });
  }

  private getProgressPercent(): number {
    if (this.totalChapters <= 0) return 0;
    return Math.min(100, Math.round((this.currentIndex / this.totalChapters) * 100));
  }

  private formatCurTime(): string {
    const d = new Date();
    return `${d.getHours().toString().padStart(2, '0')}:${d.getMinutes().toString().padStart(2, '0')}`;
  }

  /** 图片加载失败处理 */
  private onImageError(url: string): void {
    this.failedImages.add(url);
    // 触发 UI 更新
    this.failedImages = new Set<string>(this.failedImages);
  }

  build() {
    Stack() {
      if (this.isLoading) {
        // 加载中
        Column() {
          LoadingProgress().width(40).height(40).color(ThemeColors.primary(this.isDark))
          if (this.loadError) {
            Text(this.loadError).fontSize(14).fontColor(ThemeColors.error(this.isDark)).margin({ top: 16 })
          } else {
            Text('加载中…').fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 16 })
          }
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
      } else if (this.imageUrls.length === 0) {
        // 无图片
        Column() {
          Text(this.loadError || '本章没有图片').fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark))
          Button('重试').margin({ top: 20 }).onClick(() => {
            this.loadChapterImages(this.currentIndex);
          })
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center)
      } else if (this.pageMode) {
        // 翻页模式
        Swiper(this.swiperController_) {
          ForEach(this.imageUrls, (url: string, index: number) => {
            Stack() {
              Image(url)
                .width('100%').height('100%')
                .objectFit(ImageFit.Contain)
                .backgroundColor(this.isDark ? '#000000' : '#FFFFFF')
                .onError(() => { this.onImageError(url); })
              if (this.failedImages.has(url)) {
                Column() {
                  Text('图片加载失败').fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark))
                  Text(url.substring(0, 60) + '...').fontSize(10).fontColor(ThemeColors.outlineVariant(this.isDark))
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 8 })
                }
                .justifyContent(FlexAlign.Center)
              }
            }
            .width('100%').height('100%')
            .backgroundColor(this.isDark ? '#000000' : '#FFFFFF')
          })
        }
        .indicator(false)
        .loop(false)
        .duration(300)
        .width('100%').height('100%')
        .backgroundColor(this.isDark ? '#000000' : '#FFFFFF')
        .onChange((index: number) => {
          this.currentPageIndex = index;
          if (index === this.imageUrls.length - 1) {
            // 到最后一张，自动下一章
          }
        })
      } else {
        // 滚动模式（条漫，默认）
        List({ scroller: this.listScroller_ }) {
          ForEach(this.imageUrls, (url: string, index: number) => {
            ListItem() {
              Column() {
                if (!this.failedImages.has(url)) {
                  Image(url)
                    .width('100%')
                    .objectFit(ImageFit.Auto)
                    .onError(() => { this.onImageError(url); })
                } else {
                  // 加载失败占位
                  Column() {
                    Text('图片加载失败').fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark))
                    Text(url.substring(0, 80)).fontSize(10).fontColor(ThemeColors.outlineVariant(this.isDark))
                      .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 4 })
                  }
                  .width('100%').height(200)
                  .justifyContent(FlexAlign.Center)
                  .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
                }
                // 图片序号
                Text(`${index + 1}/${this.imageUrls.length}`)
                  .fontSize(11)
                  .fontColor(ThemeColors.secondaryText(this.isDark))
                  .margin({ top: 4, bottom: 8 })
              }
              .width('100%')
            }
          })
        }
        .width('100%').height('100%')
        .backgroundColor(this.isDark ? '#000000' : '#FFFFFF')
        .divider({ strokeWidth: 0, color: Color.Transparent, startMargin: 0, endMargin: 0 })
        .onReachStart(() => {
          if (!this.justLoadedChapter_ && this.currentIndex > 0) {
            this.onPrevChapter();
          }
          this.justLoadedChapter_ = false;
        })
        .onReachEnd(() => {
          if (!this.justLoadedChapter_ && this.currentIndex < this.totalChapters - 1) {
            this.onNextChapter();
          }
          this.justLoadedChapter_ = false;
        })
        .onClick(() => {
          this.showMenu = !this.showMenu;
        })
      }

      // 页脚信息条（非加载状态）
      if (!this.isLoading && this.imageUrls.length > 0) {
        Stack({ alignContent: Alignment.Bottom }) {
          Column() {
            Row().width('100%').height(1).backgroundColor(ThemeColors.outlineVariant(this.isDark))
              .margin({ top: 4, bottom: 4 })
            Row() {
              Text(this.chapterTitle || '')
                .fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
              Text(this.formatCurTime())
                .fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ right: 10 })
              Text(`${this.currentIndex + 1}/${this.totalChapters}` +
                (this.totalChapters > 0 ? ` (${this.getProgressPercent()}%)` : ''))
                .fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark))
            }
            .width('100%')
            .padding({ left: 20, right: 20 })
          }
          .width('100%')
          .backgroundColor(this.isDark ? '#000000' : '#FFFFFF')
        }
        .width('100%').height('100%')
        .hitTestBehavior(HitTestMode.None)
      }

      // 顶部菜单栏
      if (this.showMenu) {
        Column() {
          // 顶部栏
          Row() {
            Text('〈').fontSize(24).fontColor(ThemeColors.onSurface(this.isDark))
              .onClick(() => { UiUtil.back(this.getUIContext()); })
              .padding({ left: 12, right: 12 })
            Text(this.bookName || '漫画阅读').fontSize(16).fontColor(ThemeColors.onSurface(this.isDark))
              .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            // 模式切换
            Text(this.pageMode ? '翻页' : '滚动').fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .borderRadius(4)
              .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
              .onClick(() => { this.pageMode = !this.pageMode; this.showMenu = false; })
          }
          .width('100%').height(48)
          .backgroundColor(ThemeColors.surface(this.isDark))
          .padding({ left: 8, right: 12 })
          .justifyContent(FlexAlign.SpaceBetween)

          Column().width('100%').layoutWeight(1).onClick(() => { this.showMenu = false; })

          // 底部栏
          Row() {
            Text('上一章').fontSize(13).fontColor(ThemeColors.onSurface(this.isDark))
              .layoutWeight(1).textAlign(TextAlign.Center)
              .onClick(() => { this.showMenu = false; this.onPrevChapter(); })
            Text('目录').fontSize(13).fontColor(ThemeColors.onSurface(this.isDark))
              .layoutWeight(1).textAlign(TextAlign.Center)
              .onClick(() => { this.showMenu = false; this.onOpenToc(); })
            Text('下一章').fontSize(13).fontColor(ThemeColors.onSurface(this.isDark))
              .layoutWeight(1).textAlign(TextAlign.Center)
              .onClick(() => { this.showMenu = false; this.onNextChapter(); })
          }
          .width('100%').height(56)
          .backgroundColor(ThemeColors.surface(this.isDark))
          .justifyContent(FlexAlign.SpaceEvenly)
        }
        .width('100%').height('100%')
      }
    }
    .width('100%').height('100%')
    .backgroundColor(this.isDark ? '#000000' : '#FFFFFF')
  }
}
