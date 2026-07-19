/**
 * 漫画阅读页
 *
 * 支持图片型书源（bookSourceType=2）的漫画阅读。
 * 功能：
 * - 条漫滚动 / 左右翻页 / 右左翻页三种阅读方向
 * - 双指缩放手势（0.5x ~ 3x）+ 双击缩放
 * - 章节边界提示页（下一章/已读完）
 * - 图片预加载（带书源 Referer/Cookie 头下载）
 * - 上下章切换、进度保存、目录跳转
 */
import { BookSource, BookSourceChapter } from '../model/BookSource';
import { ThemeColors } from '../theme/ThemeColors';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { ChapterCache } from '../util/ChapterCache';
import { NetUtil } from '../util/NetUtil';
import { ContentCleaner } from '../util/ContentCleaner';
import { MangaImageLoader } from '../util/MangaImageLoader';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookTable } from '../data/database/BookTable';
import { ChapterTable } from '../data/database/ChapterTable';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { BookChapter } from '../model/BookChapter';
import { UiUtil } from '../util/UiUtil';
import { SettingsStore } from '../data/preferences/SettingsStore';
import { ClickAction } from '../components/reader/ClickAction';
import { ChangeSourceSheet } from '../components/BookInfoSheets';
import { SearchResult } from '../model/SearchResult';
import window from '@ohos.window';
import photoAccessHelper from '@ohos.file.photoAccessHelper';
import fileFs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';

/** 阅读方向模式 */
const READ_MODE_WEBTOON: number = 0;  // 条漫（从上到下连续滚动）
const READ_MODE_LEFT_TO_RIGHT: number = 1;  // 左->右翻页
const READ_MODE_RIGHT_TO_LEFT: number = 2;  // 旧版右->左模式，仅用于设置迁移
const READ_MODE_SINGLE_PAGE: number = 3;  // 单页全屏（每屏一张图，Contain缩放）

/** 缩放范围 */
const MIN_SCALE: number = 0.5;
const MAX_SCALE: number = 3.0;
const DOUBLE_TAP_SCALE: number = 2.0;

/** 阅读模式选项 */
interface ReadModeOption {
  mode: number;
  label: string;
}

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
  @State @Watch('onShowMenuChange_') showMenu: boolean = false;
  @State readMode: number = READ_MODE_WEBTOON;
  @State singlePageMode: boolean = false;  // 单页全屏开关（独立于阅读方向）
  @State currentPageIndex: number = 0;
  @State swiperIndex: number = 0;  // Swiper 声明式 index，用于数据变化时直接定位到正确页

  // 缩放状态
  @State imageScale: number = 1.0;
  private pinchStartScale_: number = 1.0;  // 手势开始时的缩放基准
  // 缩放后拖动平移
  @State panOffsetX: number = 0;
  @State panOffsetY: number = 0;
  private panStartX_: number = 0;
  private panStartY_: number = 0;
  // 交叉淡入动画
  @State imageOpacity: number = 0;

  // 触控区域动作配置（9宫格）
  @State comicZoneActions: number[] = [4, 2, 3, 2, 0, 1, 2, 1, 1];
  // 菜单子面板
  @State showModeSelect: boolean = false;
  @State showZoneConfig: boolean = false;
  // 屏幕宽高（用于触控区域计算）
  @State screenWidth: number = 0;
  @State screenHeight: number = 0;
  // 预加载数量
  private preloadNum_: number = 3;
  // 换源对话框
  private sourceDlg?: CustomDialogController;

  // 内部状态
  private source_: BookSource | null = null;
  private bookId_: number = -1;
  private targetIdx_: number = -1;
  private allChapters_: BookSourceChapter[] = [];
  private listScroller_: ListScroller = new ListScroller();
  private swiperController_: SwiperController = new SwiperController();
  private justLoadedChapter_: boolean = false;
  private chapterSwitching_: boolean = false;  // 章节切换中标记，防止 onReachEnd/onReachStart 重复触发
  private nextChapterContent_: string = '';
  private nextChapterIdx_: number = -1;
  private prevChapterContent_: string = '';
  private prevChapterIdx_: number = -1;
  private preloadingChapterPromises_: Map<number, Promise<string>> = new Map<number, Promise<string>>();
  /** 章节切换代次，用于丢弃已经过期的图片异步结果。 */
  private imageLoadGeneration_: number = 0;
  // 图片本地路径缓存：url -> localPath
  @State imagePaths: Map<string, string> = new Map<string, string>();
  // 图片加载失败标记
  @State failedImages: Set<string> = new Set<string>();
  // 图片下载进度：url -> percent(0-100)
  @State imageProgress: Map<string, number> = new Map<string, number>();
  // 自动阅读
  @State autoRead: boolean = false;
  private autoReadTimer_: number = -1;
  private autoReadSpeed_: number = 3;  // 秒
  // 色彩滤镜亮度（0-100, 50=默认不变）
  @State comicBrightness: number = 50;
  // 条漫侧边留白百分比（0-20）
  @State comicSidePadding: number = 0;

  aboutToAppear(): void {
    const p = UiUtil.getParams(this.getUIContext()) as Record<string, Object>;
    this.bookName = String(p['bookName'] || p['name'] || '');
    this.bookUrl = String(p['bookUrl'] || '');
    this.originUrl = String(p['originUrl'] || '');
    this.origin = String(p['origin'] || '');
    this.tocUrl = String(p['tocUrl'] || '');
    if (p['durChapterIndex'] !== undefined) this.targetIdx_ = Number(p['durChapterIndex']);
    // 加载阅读模式和触控配置
    this.loadSettings();
    // 进入沉浸式模式（隐藏状态栏和导航栏）
    this.setSystemBarVisible_(false);
  }

  private async loadSettings(): Promise<void> {
    try {
      const s = SettingsStore.getInstance();
      await s.init(UiUtil.getHostContext(this.getUIContext()));
      const storedReadMode: number = await s.getComicReadMode();
      // 旧版“右->左”模式会反转物理滑动方向，迁移为统一的横向翻页模式。
      this.readMode = storedReadMode === READ_MODE_RIGHT_TO_LEFT
        ? READ_MODE_LEFT_TO_RIGHT : storedReadMode;
      if (storedReadMode === READ_MODE_RIGHT_TO_LEFT) {
        await s.setComicReadMode(READ_MODE_LEFT_TO_RIGHT);
      }
      this.singlePageMode = await s.getComicSinglePageMode();
      this.preloadNum_ = await s.getComicPreloadNum();
      this.autoReadSpeed_ = await s.getComicAutoReadSpeed();
      this.comicBrightness = await s.getComicBrightness();
      this.comicSidePadding = await s.getComicSidePadding();
      const actions: number[] = [];
      for (let i = 0; i < 9; i++) {
        actions.push(await s.getComicClickAction(i));
      }
      this.comicZoneActions = actions;
    } catch (_) { /* ignore */ }
  }

  private async saveReadMode(): Promise<void> {
    try {
      const s = SettingsStore.getInstance();
      await s.setComicReadMode(this.readMode);
    } catch (_) { /* ignore */ }
  }

  onPageShow(): void {
    if (!this.isLoading) {
      if (ChapterCache.targetIndex >= 0) {
        const idx = ChapterCache.targetIndex;
        ChapterCache.targetIndex = -1;
        if (ChapterCache.chapters.length > 0 && ChapterCache.bookUrl === this.bookUrl) {
          this.allChapters_ = ChapterCache.chapters;
          this.totalChapters = ChapterCache.chapters.length;
          this.chapters = ChapterCache.chapters;
        }
        if (idx < this.allChapters_.length && idx !== this.currentIndex) {
          console.info('[ComicRead] Jump to chapter from toc:', idx);
          this.justLoadedChapter_ = true;
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
          // 恢复页内进度
          if (book.durChapterPos && book.durChapterPos > 0) {
            this.currentPageIndex = book.durChapterPos;
          }
        }
      } catch (_) { /* ignore */ }

      // 匹配书源
      const srcDao = new BookSourceTable(db);
      const sources = await srcDao.getAllSources();
      const norm = this.originUrl.replace(/\/+$/, '');
      this.source_ = sources.find(s => s.sourceUrl === this.originUrl) ||
        sources.find(s => s.sourceUrl.replace(/\/+$/, '') === norm) ||
        sources.find(s => s.sourceName === this.origin) || null;
      console.info('[ComicRead] loadContent: source_=', this.source_ ? this.source_.sourceName : 'NULL');

      // 加载章节列表
      let chapters: BookSourceChapter[] = [];
      if (ChapterCache.chapters.length > 0 && ChapterCache.bookUrl === this.bookUrl) {
        chapters = ChapterCache.chapters;
      } else {
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
        if (chapters.length === 0 && this.source_) {
          const primaryTocUrl = this.tocUrl || this.bookUrl;
          chapters = await globalSourceExecutor.getToc(this.source_, primaryTocUrl);
          if (chapters.length === 0 && primaryTocUrl !== this.bookUrl) {
            const fallback = await globalSourceExecutor.getToc(this.source_, this.bookUrl);
            if (fallback.length > 0) chapters = fallback;
          }
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

      if (this.targetIdx_ >= 0 && this.targetIdx_ < this.allChapters_.length) {
        this.currentIndex = this.targetIdx_;
      } else {
        this.currentIndex = 0;
      }

      // 恢复页内进度：从 DB 读取的 durChapterPos 传递给 loadChapterImages
      const savedPageIdx: number = this.currentPageIndex;
      await this.loadChapterImages(this.currentIndex, false, false, savedPageIdx);
    } catch (e) {
      this.loadError = '加载失败: ' + (e as Error).message;
      this.isLoading = false;
    }
  }

  private async loadChapterImages(idx: number, boundarySwitch: boolean = false, gotoLastPage: boolean = false, restorePageIdx: number = -1, forceRefresh: boolean = false): Promise<void> {
    if (idx < 0 || idx >= this.allChapters_.length) {
      this.chapterSwitching_ = false;
      return;
    }
    // 设置标记，防止 onReachEnd/onReachStart 在章节切换时连锁触发
    this.justLoadedChapter_ = true;
    this.imageLoadGeneration_++;
    if (!boundarySwitch) {
      this.isLoading = true;
    }
    this.currentIndex = idx;
    this.failedImages = new Set<string>();
    this.imagePaths = new Map<string, string>();
    if (!boundarySwitch) {
      // 先清空 imageUrls，避免旧列表残留导致 onReachEnd 触发
      this.imageUrls = [];
      // 不强制清零 currentPageIndex，保留外部恢复的进度（restorePageIdx 或已有值）
      if (restorePageIdx >= 0) {
        this.currentPageIndex = restorePageIdx;
      } else if (!gotoLastPage) {
        this.currentPageIndex = 0;
      }
    }
	    const ch = this.allChapters_[idx];
	    this.chapterTitle = ch?.title || '';

	    let content: string = '';
	    if (forceRefresh) {
	      // 强制刷新：清除缓存并重新拉取
	      await this.clearChapterCache_(idx);
	      content = await this.fetchChapterContent_(idx);
	    } else {
	      content = await this.readChapterCache_(idx);
	      if (!content || content.length < 10) {
	        content = await this.fetchChapterContent_(idx);
	      }
	    }

    if (content) {
      const baseUrl: string = ch?.url || this.bookUrl || this.source_?.sourceUrl || '';
      const urls: string[] = globalSourceExecutor.extractImageUrls(content, baseUrl);
      console.info('[ComicRead] extractImageUrls: found', urls.length, 'images for chapter', idx);
      if (urls.length > 0) {
        // 在设置 imageUrls 之前确定目标页码和 Swiper index，使 Swiper 数据变化时直接从正确页渲染
        let targetPage: number;
        if (gotoLastPage) {
          targetPage = urls.length - 1;
        } else if (restorePageIdx >= 0 && restorePageIdx < urls.length) {
          targetPage = restorePageIdx;
        } else {
          targetPage = 0;
        }
        this.currentPageIndex = targetPage;
        this.swiperIndex = targetPage;
        this.imageUrls = urls;
        this.isLoading = false;
        // 以目标页为中心向两侧扩散预加载，确保目标页优先下载
        this.preloadImages_(urls, Math.min(this.preloadNum_, 6), targetPage);
        // 下一帧滚动到目标位置（等待 List 渲染新数据后再滚动）
        setTimeout(() => {
          if (this.readMode === READ_MODE_WEBTOON) {
            if (gotoLastPage) {
              this.listScroller_.scrollToIndex(targetPage);
            } else {
              this.listScroller_.scrollTo({ xOffset: 0, yOffset: 0 });
            }
          }
        }, 0);
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
    this.preloadPrevChapter_(idx);
    // 相邻章节只预取首图，避免整章图片在后台堆积。
    this.preloadSurroundingChapters_(idx, 1);
    // 延迟清除标记，确保 List 渲染完成后再允许 onReachEnd/onReachStart
    setTimeout(() => {
      this.justLoadedChapter_ = false;
      this.chapterSwitching_ = false;
    }, 500);
  }

  /** 以目标页为中心向两侧扩散预加载图片，确保目标页优先下载 */
  private preloadImages_(urls: string[], count: number, targetPage: number): void {
    const n: number = Math.min(count, urls.length);
    // 先加载目标页本身
    if (targetPage >= 0 && targetPage < urls.length) {
      this.loadImage_(urls[targetPage]);
    }
    // 然后以目标页为中心，向两侧交替扩散
    let loaded = 1;
    let offset = 1;
    while (loaded < n) {
      const before: number = targetPage - offset;
      const after: number = targetPage + offset;
      if (after >= 0 && after < urls.length) {
        this.loadImage_(urls[after]);
        loaded++;
      }
      if (loaded >= n) break;
      if (before >= 0 && before < urls.length) {
        this.loadImage_(urls[before]);
        loaded++;
      }
      offset++;
    }
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

  /** 清除指定章节的本地缓存（用于强制刷新时重新拉取） */
  private async clearChapterCache_(idx: number): Promise<void> {
    if (this.bookId_ <= 0) return;
    try {
      const ct = new ChapterTable(AppDatabase.getInstance().rdbStore);
      const cached = await ct.getChapterByIndex(this.bookId_, idx);
      if (cached) {
        cached.content = '';
        cached.contentLength = 0;
        cached.isCached = false;
        cached.updateTime = Date.now();
        await ct.updateChapter(cached);
      }
    } catch (_e) { /* ignore */ }
  }

  private async fetchChapterContent_(idx: number): Promise<string> {
    const ch = this.allChapters_[idx];
    if (!ch) return '';
    const url = ch.url || this.bookUrl;
    let content: string = '';
    if (this.source_) {
      content = await globalSourceExecutor.getContent(this.source_, url, this.bookUrl, true);
    }
    if (!content && url && url.startsWith('http')) {
      const r = await NetUtil.httpGet(url);
      if (r) content = ContentCleaner.formatKeepImg(r, url);
    }
    if (content && content.length > 10) {
      await this.saveToDbCache_(idx, content);
    }
    return content;
  }

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
          // 预下载下一章图片到本地缓存，切章时秒加载
          this.preloadChapterImages_(nextIdx, content);
        }
      })
      .catch((_e: Error) => { /* ignore */ })
      .then(() => {
        this.preloadingChapterPromises_.delete(nextIdx);
      });
  }

  /** 预加载上一章文本，用于向前无缝翻页 */
  private preloadPrevChapter_(currentIdx: number): void {
    const prevIdx = currentIdx - 1;
    if (prevIdx < 0 || this.preloadingChapterPromises_.has(prevIdx)) return;
    const promise = this.readChapterCache_(prevIdx)
      .then((cached: string): Promise<string> | string => {
        if (cached && cached.length > 10) return cached;
        return this.fetchChapterContent_(prevIdx);
      });
    this.preloadingChapterPromises_.set(prevIdx, promise);
    promise
      .then((content: string): void => {
        if (content && content.length > 10) {
          this.prevChapterContent_ = content;
          this.prevChapterIdx_ = prevIdx;
          // 预下载上一章图片到本地缓存
          this.preloadChapterImages_(prevIdx, content);
        }
      })
      .catch((_e: Error) => { /* ignore */ })
      .then(() => {
        this.preloadingChapterPromises_.delete(prevIdx);
      });
  }

  /** 预下载指定章节的所有图片到本地缓存（不阻塞 UI） */
  private preloadChapterImages_(idx: number, content: string): void {
    try {
      const ch = this.allChapters_[idx];
      const baseUrl: string = ch?.url || this.bookUrl || this.source_?.sourceUrl || '';
      const urls: string[] = globalSourceExecutor.extractImageUrls(content, baseUrl);
      if (urls.length === 0) return;
      // 相邻章节只预取封面页；进入章节后再以当前页为中心按需加载。
      console.info('[ComicRead] Preloading first image for chapter', idx);
      MangaImageLoader.preload(urls[0], this.source_);
    } catch (_) { /* ignore */ }
  }

  /** 预下载前后各 N 章的图片到本地缓存（不阻塞 UI，异步静默执行） */
  private preloadSurroundingChapters_(currentIdx: number, range: number): void {
    for (let offset = 1; offset <= range; offset++) {
      // 后 N 章
      const nextIdx: number = currentIdx + offset;
      if (nextIdx < this.allChapters_.length && !this.preloadingChapterPromises_.has(nextIdx)) {
        const idx: number = nextIdx;
        this.readChapterCache_(idx)
          .then((cached: string): Promise<string> | string => {
            if (cached && cached.length > 10) return cached;
            return this.fetchChapterContent_(idx);
          })
          .then((content: string): void => {
            if (content && content.length > 10) {
              this.preloadChapterImages_(idx, content);
            }
          })
          .catch((_e: Error) => { /* ignore */ });
      }
      // 前 N 章
      const prevIdx: number = currentIdx - offset;
      if (prevIdx >= 0 && !this.preloadingChapterPromises_.has(prevIdx)) {
        const idx: number = prevIdx;
        this.readChapterCache_(idx)
          .then((cached: string): Promise<string> | string => {
            if (cached && cached.length > 10) return cached;
            return this.fetchChapterContent_(idx);
          })
          .then((content: string): void => {
            if (content && content.length > 10) {
              this.preloadChapterImages_(idx, content);
            }
          })
          .catch((_e: Error) => { /* ignore */ });
      }
    }
  }

  private async tryUsePreloadedChapter_(idx: number, gotoLastPage: boolean = false): Promise<boolean> {
    let content: string = '';
    let fromNextCache = false;
    let fromPrevCache = false;
    if (this.nextChapterIdx_ === idx && this.nextChapterContent_ && this.nextChapterContent_.length > 10) {
      content = this.nextChapterContent_;
      fromNextCache = true;
    } else if (this.prevChapterIdx_ === idx && this.prevChapterContent_ && this.prevChapterContent_.length > 10) {
      content = this.prevChapterContent_;
      fromPrevCache = true;
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

    // 设置标记，防止 onReachEnd 连锁触发
    this.justLoadedChapter_ = true;
    this.imageLoadGeneration_++;
    this.currentIndex = idx;
    this.chapterTitle = ch?.title || '';
    this.failedImages = new Set<string>();
    this.imagePaths = new Map<string, string>();
    // 在设置 imageUrls 之前确定目标页码和 Swiper index，使 Swiper 数据变化时直接从正确页渲染
    const targetPage: number = gotoLastPage ? urls.length - 1 : 0;
    this.currentPageIndex = targetPage;
    this.swiperIndex = targetPage;
    this.imageUrls = urls;
    this.isLoading = false;
    if (fromNextCache) {
      this.nextChapterContent_ = '';
      this.nextChapterIdx_ = -1;
    }
    if (fromPrevCache) {
      this.prevChapterContent_ = '';
      this.prevChapterIdx_ = -1;
    }
    this.saveProgress();
    this.preloadNextChapter_(idx);
    this.preloadPrevChapter_(idx);
    this.preloadImages_(urls, Math.min(this.preloadNum_, 6), targetPage);
    // 条漫模式需要手动滚动到正确位置；翻页模式由 .index(swiperIndex) 声明式绑定处理
    setTimeout(() => {
      if (this.readMode === READ_MODE_WEBTOON) {
        if (gotoLastPage) {
          this.listScroller_.scrollToIndex(targetPage);
        } else {
          this.listScroller_.scrollTo({ xOffset: 0, yOffset: 0 });
        }
      }
    }, 0);
    // 延迟清除标记，防止 onReachEnd/onReachStart 连锁触发
    setTimeout(() => {
      this.justLoadedChapter_ = false;
      this.chapterSwitching_ = false;
    }, 300);
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
      console.warn('[ComicRead] Failed to save TOC:', (e as Error).message);
    }
  }

  private saveProgress(): void {
    const ch = this.allChapters_[this.currentIndex];
    if (!ch || !this.bookUrl) return;
    const bookTable = new BookTable(AppDatabase.getInstance().rdbStore);
    bookTable.updateReadingProgress(this.bookUrl, this.currentIndex, ch.title || '', this.totalChapters, this.currentPageIndex).catch(() => {});
  }

  async aboutToDisappear(): Promise<void> {
    this.imageLoadGeneration_++;
    // 停止自动阅读
    this.stopAutoRead();
    const ch = this.allChapters_[this.currentIndex];
    if (ch && this.bookUrl) {
      const bookTable = new BookTable(AppDatabase.getInstance().rdbStore);
      try { await bookTable.updateReadingProgress(this.bookUrl, this.currentIndex, ch.title || '', this.totalChapters, this.currentPageIndex); } catch (_) { /* ignore */ }
    }
    // 退出时恢复系统栏
    this.setSystemBarVisible_(true);
  }

  /** showMenu 变化时自动同步系统栏：菜单显示→恢复状态栏，菜单隐藏→进入沉浸式 */
  private onShowMenuChange_(): void {
    this.setSystemBarVisible_(this.showMenu);
  }

  /** 控制系统栏显示/隐藏 */
  private async setSystemBarVisible_(visible: boolean): Promise<void> {
    try {
      const ctx = UiUtil.getHostContext(this.getUIContext());
      if (!ctx) return;
      const win: window.Window = await window.getLastWindow(ctx);
      if (visible) {
        await win.setWindowSystemBarEnable(['status', 'navigation']);
      } else {
        await win.setWindowSystemBarEnable([]);
      }
    } catch (err) {
      // 部分设备可能不支持，忽略
      console.warn('[ComicRead] setSystemBar failed:', (err as Error).message);
    }
  }

  // ============ 章节导航 ============

  private onPrevChapter(): void {
    if (this.currentIndex <= 0) {
      this.chapterSwitching_ = false;
      return;
    }
    this.justLoadedChapter_ = true;
    const prevIdx = this.currentIndex - 1;
    // 无缝翻页：先尝试预加载内容，保持旧页面不闪烁
    this.tryUsePreloadedChapter_(prevIdx, true).then((ok: boolean) => {
      if (ok) return;
      // 预加载未命中，回退到普通加载（保持旧页面直到新内容就绪）
      this.loadChapterImages(prevIdx, true, true);
    });
  }

  private async onNextChapter(): Promise<void> {
    const n = this.currentIndex + 1;
    if (n >= this.totalChapters) {
      this.chapterSwitching_ = false;
      return;
    }
    // 设置标记，防止 onReachEnd 连锁触发
    this.justLoadedChapter_ = true;
    if (await this.tryUsePreloadedChapter_(n, false)) {
      // tryUsePreloadedChapter_ 内部已处理 justLoadedChapter_ 的清除
      return;
    }
    // 预加载未命中，回退到普通加载（保持旧页面直到新内容就绪）
    this.loadChapterImages(n, true, false);
  }

  private onOpenToc(): void {
    ChapterCache.chapters = this.allChapters_;
    ChapterCache.bookUrl = this.bookUrl;
    UiUtil.pushUrl(this.getUIContext(), {
      url: 'pages/ChapterListPage',
	      params: {
	        from: 'ComicReadPage', bookName: this.bookName, bookAuthor: '',
	        bookUrl: this.bookUrl, tocUrl: this.tocUrl, originUrl: this.originUrl,
	        origin: this.origin,
	        durChapterIndex: this.currentIndex,
	        isManga: '1',
	      }
    });
  }

  private getProgressPercent(): number {
    if (this.totalChapters <= 0) return 0;
    // 加权进度：章节进度 + 页内进度
    const chapterProgress: number = this.currentIndex / this.totalChapters;
    let pageProgress: number = 0;
    if (this.imageUrls.length > 0) {
      pageProgress = (1 / this.totalChapters) * ((this.currentPageIndex + 1) / this.imageUrls.length);
    }
    let percent: number = Math.round((chapterProgress + pageProgress) * 100);
    // 未读完时不超过 99%
    if (percent >= 100 && this.currentIndex < this.totalChapters - 1) percent = 99;
    return Math.min(100, Math.max(0, percent));
  }

  private formatCurTime(): string {
    const d = new Date();
    return `${d.getHours().toString().padStart(2, '0')}:${d.getMinutes().toString().padStart(2, '0')}`;
  }

  /** 异步加载图片：先下载到本地，再更新 state 触发渲染 */
  private async loadImage_(url: string, generation: number = this.imageLoadGeneration_): Promise<void> {
    if (this.imagePaths.has(url) || this.failedImages.has(url)) return;
    // 检查 url 是否属于当前章节（章节切换后旧 promise 的结果应丢弃）
    if (this.imageUrls.indexOf(url) < 0) return;
    try {
      const localPath: string = await MangaImageLoader.load(url, this.source_, (percent: number) => {
        // 更新进度
        if (generation === this.imageLoadGeneration_ && this.imageUrls.indexOf(url) >= 0 &&
          !this.imagePaths.has(url)) {
          const newProg = new Map<string, number>(this.imageProgress);
          newProg.set(url, percent);
          this.imageProgress = newProg;
        }
      });
      // 异步返回后再次检查：章节可能已切换
      if (generation !== this.imageLoadGeneration_ || this.imageUrls.indexOf(url) < 0) return;
      // 清除进度
      const newProg = new Map<string, number>(this.imageProgress);
      newProg.delete(url);
      this.imageProgress = newProg;

      if (localPath && localPath.startsWith('/')) {
        const newMap = new Map<string, string>(this.imagePaths);
        newMap.set(url, 'file://' + localPath);
        this.imagePaths = newMap;
      } else {
        const newMap = new Map<string, string>(this.imagePaths);
        newMap.set(url, url);
        this.imagePaths = newMap;
      }
    } catch (err) {
      if (generation !== this.imageLoadGeneration_ || this.imageUrls.indexOf(url) < 0) return;
      const newSet = new Set<string>(this.failedImages);
      newSet.add(url);
      this.failedImages = newSet;
    }
  }

  /** 双击图片缩放，定位到点击点 */
  private onDoubleTap(tapX: number = 0, tapY: number = 0): void {
    if (this.imageScale > 1.0) {
      // 已放大，还原
      this.imageScale = 1.0;
      this.panOffsetX = 0;
      this.panOffsetY = 0;
    } else {
      // 放大到 2x，以点击点为中心
      this.imageScale = DOUBLE_TAP_SCALE;
      const w: number = this.screenWidth > 0 ? this.screenWidth : 360;
      const h: number = this.screenHeight > 0 ? this.screenHeight : 640;
      // 偏移量 = (屏幕中心 - 点击点) * (scale - 1)
      const targetX: number = (w / 2 - tapX) * (DOUBLE_TAP_SCALE - 1.0);
      const targetY: number = (h / 2 - tapY) * (DOUBLE_TAP_SCALE - 1.0);
      this.clampPanOffset_(targetX, targetY);
    }
  }

  /** 缩放时归零偏移（缩放变化后原有偏移不再适用） */
  private onScaleChange_(): void {
    if (this.imageScale <= 1.0) {
      this.panOffsetX = 0;
      this.panOffsetY = 0;
    }
  }

  /** clamp 平移偏移量，防止拖出边界 */
  private clampPanOffset_(x: number, y: number): void {
    const w: number = this.screenWidth > 0 ? this.screenWidth : 360;
    const h: number = this.screenHeight > 0 ? this.screenHeight : 640;
    const maxX: number = (this.imageScale - 1.0) * w / 2;
    const maxY: number = (this.imageScale - 1.0) * h / 2;
    this.panOffsetX = Math.max(-maxX, Math.min(maxX, x));
    this.panOffsetY = Math.max(-maxY, Math.min(maxY, y));
  }

  // ============ 9 宫格触控分发 ============

  /** 处理点击事件，按 3x3 区域分发动作 */
  private handleComicClick_(x: number, y: number): void {
    const w: number = this.screenWidth > 0 ? this.screenWidth : 360;
    const h: number = this.screenHeight > 0 ? this.screenHeight : 640;
    const x3: number = w / 3;
    const y3: number = h / 3;
    let zone: number = 4;  // 默认中间
    if (y < y3) {
      zone = x < x3 ? 0 : (x > w - x3 ? 2 : 1);         // TL/TC/TR
    } else if (y < y3 * 2) {
      zone = x < x3 ? 3 : (x > w - x3 ? 5 : 4);         // ML/MC/MR
    } else {
      zone = x < x3 ? 6 : (x > w - x3 ? 8 : 7);         // BL/BC/BR
    }
    this.dispatchZoneAction_(zone);
  }

  /** 根据区域动作配置执行对应操作 */
  private dispatchZoneAction_(zone: number): void {
    const actions: number[] = this.comicZoneActions.length === 9 ? this.comicZoneActions : [4,2,3,2,0,1,2,1,1];
    const action: number = actions[zone] ?? -1;
    switch (action) {
      case ClickAction.NONE:
        break;
      case ClickAction.MENU:
        this.showMenu = !this.showMenu;
        // 菜单显示时暂停自动阅读（状态栏由 @Watch onShowMenuChange_ 自动同步）
        if (this.showMenu) {
          this.stopAutoRead();
        }
        break;
      case ClickAction.NEXT_PAGE:
        this.nextPage();
        break;
      case ClickAction.PREV_PAGE:
        this.prevPage();
        break;
      case ClickAction.NEXT_CHAPTER:
        this.onNextChapter();
        break;
      case ClickAction.PREV_CHAPTER:
        this.onPrevChapter();
        break;
      default:
        this.showMenu = !this.showMenu;
        break;
    }
  }

  /** 下一页（条漫模式滚动一屏，翻页/单页模式 Swiper 下一项） */
  private nextPage(): void {
    if (this.readMode === READ_MODE_WEBTOON && !this.singlePageMode) {
      if (this.currentPageIndex < this.imageUrls.length - 1) {
        this.currentPageIndex++;
        this.saveProgress();
      }
      this.listScroller_.scrollBy(0, this.screenHeight > 0 ? this.screenHeight * 0.8 : 500);
    } else {
      if (this.currentPageIndex < this.imageUrls.length - 1) {
        this.currentPageIndex++;
        this.swiperIndex = this.currentPageIndex;
      } else {
        this.onNextChapter();
      }
    }
  }

  /** 上一页 */
  private prevPage(): void {
    if (this.readMode === READ_MODE_WEBTOON && !this.singlePageMode) {
      if (this.currentPageIndex > 0) {
        this.currentPageIndex--;
        this.saveProgress();
      }
      this.listScroller_.scrollBy(0, this.screenHeight > 0 ? -(this.screenHeight * 0.8) : -500);
    } else {
      if (this.currentPageIndex > 0) {
        this.currentPageIndex--;
        this.swiperIndex = this.currentPageIndex;
      } else {
        this.onPrevChapter();
      }
    }
  }

  /** 获取翻页模式图片；页序始终保持语义顺序，物理手势方向不随排版设置反转。 */
  private getDisplayImageUrls(): string[] {
    return this.imageUrls;
  }

  build() {
    Stack() {
	      if (this.isLoading) {
	        // 加载中 — 可点击调出菜单（方便取消/返回）
	        Column() {
	          LoadingProgress().width(40).height(40).color(ThemeColors.primary(this.isDark))
	          if (this.loadError) {
	            Text(this.loadError).fontSize(14).fontColor(ThemeColors.error(this.isDark)).margin({ top: 16 })
	          } else {
	            Text($r('app.string.ui_300ee3dee4')).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 16 })
	          }
	        }
	        .width('100%').height('100%').justifyContent(FlexAlign.Center)
		        .onClick(() => {
		          this.showMenu = !this.showMenu;
		        })
	      } else if (this.imageUrls.length === 0) {
	        // 无图片 — 同样支持点击调出菜单和刷新
	        Column() {
	          Text(this.loadError || '本章没有图片').fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark))
	          Row() {
	          Button($r('app.string.common_retry')).margin({ top: 20 }).onClick(() => {
	              this.loadChapterImages(this.currentIndex, false, false, -1, true);
	            })
		            Button($r('app.string.ui_7082456207')).margin({ top: 20 }).margin({ left: 16 }).onClick(() => {
		              this.showMenu = !this.showMenu;
		            })
	          }
	          .justifyContent(FlexAlign.Center)
	        }
	        .width('100%').height('100%').justifyContent(FlexAlign.Center)
	        .onClick(() => {
	          // 点击页面空白处调出菜单（与正常阅读模式一致的触控行为）
	          this.handleComicClick_(this.screenWidth / 2, this.screenHeight / 2);
	        })
      } else if (this.singlePageMode) {
        // 单页全屏模式（独立开关，覆盖阅读方向）
        this.buildSinglePageMode()
      } else if (this.readMode === READ_MODE_WEBTOON) {
        // 条漫滚动模式
        this.buildWebtoonMode()
      } else {
        // 翻页模式（左右/右左）
        this.buildPagedMode()
      }

      // 页脚信息条
      if (!this.isLoading && this.imageUrls.length > 0) {
        this.buildFooter()
      }

      // 菜单层
      if (this.showMenu) {
        this.buildMenu()
      }
      // 模式选择面板
      if (this.showModeSelect) {
        this.buildModeSelectPanel()
      }
      // 触控设置面板
      if (this.showZoneConfig) {
        this.buildZoneConfigPanel()
      }
    }
    .width('100%').height('100%')
    .backgroundColor(ThemeColors.comicCanvas(this.isDark))
    .onAreaChange((_old: Area, n: Area) => {
      const w: number = typeof n.width === 'number' ? n.width : Number(n.width) || 360;
      const h: number = typeof n.height === 'number' ? n.height : Number(n.height) || 640;
      if (w > 0) this.screenWidth = w;
      if (h > 0) this.screenHeight = h;
    })
  }

  @Builder
  buildWebtoonMode() {
    List({ scroller: this.listScroller_ }) {
      // 章首提示
      ListItem() {
        this.buildChapterEdge(false)
      }

      // 图片列表
      ForEach(this.imageUrls, (url: string, index: number) => {
        ListItem() {
          this.buildImageItem(url, index)
        }
      }, (url: string) => url)

      // 章尾提示
      ListItem() {
        this.buildChapterEdge(true)
      }
    }
    .width('100%').height('100%')
    .backgroundColor(ThemeColors.comicCanvas(this.isDark))
    .onReachStart(() => {
      if (this.chapterSwitching_) return;
      if (!this.justLoadedChapter_ && this.currentIndex > 0) {
        this.chapterSwitching_ = true;
        this.onPrevChapter();
      }
      this.justLoadedChapter_ = false;
    })
    .onReachEnd(() => {
      if (this.chapterSwitching_) return;
      if (!this.justLoadedChapter_ && this.currentIndex < this.totalChapters - 1) {
        this.chapterSwitching_ = true;
        this.onNextChapter();
      }
      this.justLoadedChapter_ = false;
    })
    .onClick((event: ClickEvent) => {
      this.handleComicClick_(event.x, event.y);
    })
    .padding({
      left: this.comicSidePadding > 0 ? `${this.comicSidePadding}%` : 0,
      right: this.comicSidePadding > 0 ? `${this.comicSidePadding}%` : 0,
    })
  }

  @Builder
  buildPagedMode() {
    Swiper(this.swiperController_) {
      ForEach(this.getDisplayImageUrls(), (url: string, index: number) => {
        Stack() {
          this.buildImageItem(url, index)
        }
        .width('100%').height('100%')
        .backgroundColor(ThemeColors.comicCanvas(this.isDark))
      }, (url: string) => url)
    }
    .indicator(false)
    .loop(false)
    .duration(300)
    .disableSwipe(this.imageScale > 1.0)
    .index(this.swiperIndex)
    .width('100%').height('100%')
    .backgroundColor(ThemeColors.comicCanvas(this.isDark))
    .onChange((index: number) => {
      this.currentPageIndex = index;
      this.swiperIndex = index;
      this.saveProgress();
      // 翻到边界时不自动切章，由触控区域 nextPage()/prevPage() 处理，
      // 避免自动切章定时器与用户点击冲突导致跳到下一章第二页
    })
    .onClick((event: ClickEvent) => {
      this.handleComicClick_(event.x, event.y);
    })
    .padding({
      left: this.comicSidePadding > 0 ? `${this.comicSidePadding}%` : 0,
      right: this.comicSidePadding > 0 ? `${this.comicSidePadding}%` : 0,
    })
  }

  @Builder
  buildSinglePageMode() {
    Swiper(this.swiperController_) {
      ForEach(this.imageUrls, (url: string, index: number) => {
        Stack() {
          if (this.failedImages.has(url)) {
            Column() {
              Text($r('app.string.ui_486ca2d3e4')).fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark))
              Text(url.substring(0, 80)).fontSize(10).fontColor(ThemeColors.outlineVariant(this.isDark))
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 4 })
              Button($r('app.string.common_retry')).margin({ top: 12 }).fontSize(12).height(40)
                .onClick(() => {
                  const newSet = new Set<string>(this.failedImages);
                  newSet.delete(url);
                  this.failedImages = newSet;
                  const newMap = new Map<string, string>(this.imagePaths);
                  newMap.delete(url);
                  this.imagePaths = newMap;
                  this.loadImage_(url);
                })
            }
            .justifyContent(FlexAlign.Center)
          } else if (this.imagePaths.has(url)) {
            Image(this.imagePaths.get(url) as string)
            .width('100%').height('100%')
              .objectFit(ImageFit.Contain)
              .scale({ x: this.imageScale, y: this.imageScale })
              .translate({ x: this.panOffsetX, y: this.panOffsetY })
              .opacity(1)
              .animation({ duration: 300, curve: Curve.EaseInOut })
              .onError(() => {
                const newSet = new Set<string>(this.failedImages);
                newSet.add(url);
                this.failedImages = newSet;
              })
              .gesture(
                PinchGesture({ fingers: 2 })
                  .onActionStart((_event: GestureEvent) => {
                    this.pinchStartScale_ = this.imageScale;
                  })
                  .onActionUpdate((event: GestureEvent) => {
                    const newScale: number = this.pinchStartScale_ * event.scale;
                    this.imageScale = Math.max(MIN_SCALE, Math.min(MAX_SCALE, newScale));
                    this.onScaleChange_();
                  })
              )
              .gesture(
                PanGesture()
                  .onActionStart((_event: GestureEvent) => {
                    this.panStartX_ = this.panOffsetX;
                    this.panStartY_ = this.panOffsetY;
                  })
                  .onActionUpdate((event: GestureEvent) => {
                    if (this.imageScale > 1.0) {
                      this.clampPanOffset_(this.panStartX_ + event.offsetX, this.panStartY_ + event.offsetY);
                    }
                  })
              )
              .gesture(
                TapGesture({ count: 2 })
                  .onAction((event: GestureEvent) => {
                    if (event && event.fingerList && event.fingerList.length > 0) {
                      this.onDoubleTap(event.fingerList[0].localX, event.fingerList[0].localY);
                    } else {
                      this.onDoubleTap();
                    }
                  })
              )
          } else {
            Column() {
              LoadingProgress().width(30).height(30).color(ThemeColors.secondaryText(this.isDark))
              Text(this.imageProgress.has(url) ? `${this.imageProgress.get(url)}%` : `${index + 1}/${this.imageUrls.length}`)
                .fontSize(11)
                .fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 8 })
            }
            .justifyContent(FlexAlign.Center)
            .onAppear(() => { this.loadImage_(url); })
          }
        }
        .width('100%').height('100%')
        .backgroundColor(ThemeColors.comicCanvas(this.isDark))
      }, (url: string) => url)
    }
    .indicator(false)
    .loop(false)
    .duration(300)
    .disableSwipe(this.imageScale > 1.0)
    .index(this.swiperIndex)
    .width('100%').height('100%')
    .backgroundColor(ThemeColors.comicCanvas(this.isDark))
    .onChange((index: number) => {
      this.currentPageIndex = index;
      this.swiperIndex = index;
      this.saveProgress();
      // 翻到边界时不自动切章，由触控区域 nextPage()/prevPage() 处理
    })
    .onClick((event: ClickEvent) => {
      this.handleComicClick_(event.x, event.y);
    })
  }

  @Builder
  buildImageItem(url: string, index: number) {
    Column() {
      if (this.failedImages.has(url)) {
        // 加载失败占位
        Column() {
          Text($r('app.string.ui_486ca2d3e4')).fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark))
          Text(url.substring(0, 80)).fontSize(10).fontColor(ThemeColors.outlineVariant(this.isDark))
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 4 })
          Button($r('app.string.common_retry')).margin({ top: 12 }).fontSize(12).height(40)
            .onClick(() => {
              const newSet = new Set<string>(this.failedImages);
              newSet.delete(url);
              this.failedImages = newSet;
              const newMap = new Map<string, string>(this.imagePaths);
              newMap.delete(url);
              this.imagePaths = newMap;
              this.loadImage_(url);
            })
        }
        .width('100%').height(300)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
      } else {
        // 图片显示
        if (this.imagePaths.has(url)) {
          Image(this.imagePaths.get(url) as string)
            .width('100%')
            .objectFit(ImageFit.Auto)
            .scale({ x: this.imageScale, y: this.imageScale })
            .translate({ x: this.panOffsetX, y: this.panOffsetY })
            .opacity(1)
            .animation({ duration: 300, curve: Curve.EaseInOut })
            .onError(() => {
              const newSet = new Set<string>(this.failedImages);
              newSet.add(url);
              this.failedImages = newSet;
            })
            .gesture(
              PinchGesture({ fingers: 2 })
                .onActionStart((_event: GestureEvent) => {
                  this.pinchStartScale_ = this.imageScale;
                })
                .onActionUpdate((event: GestureEvent) => {
                  const newScale: number = this.pinchStartScale_ * event.scale;
                  this.imageScale = Math.max(MIN_SCALE, Math.min(MAX_SCALE, newScale));
                  this.onScaleChange_();
                })
            )
            .gesture(
              PanGesture()
                .onActionStart((_event: GestureEvent) => {
                  this.panStartX_ = this.panOffsetX;
                  this.panStartY_ = this.panOffsetY;
                })
                .onActionUpdate((event: GestureEvent) => {
                  if (this.imageScale > 1.0) {
                    this.clampPanOffset_(this.panStartX_ + event.offsetX, this.panStartY_ + event.offsetY);
                  }
                })
            )
            .gesture(
              TapGesture({ count: 2 })
                .onAction(() => { this.onDoubleTap(); })
            )
            .gesture(
              LongPressGesture()
                .onAction(() => { this.saveImageToGallery_(url); })
            )
        } else {
          // 加载中占位，异步触发下载
          Column() {
            LoadingProgress().width(30).height(30).color(ThemeColors.secondaryText(this.isDark))
            Text(this.imageProgress.has(url) ? `${this.imageProgress.get(url)}%` : `${index + 1}/${this.imageUrls.length}`)
              .fontSize(11)
              .fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 8 })
          }
          .width('100%').height(200)
          .justifyContent(FlexAlign.Center)
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
          .onAppear(() => { this.loadImage_(url); })
        }
        // 图片序号
        Text(`${index + 1}/${this.imageUrls.length}`)
          .fontSize(11)
          .fontColor(ThemeColors.secondaryText(this.isDark))
          .margin({ top: 4, bottom: 8 })
      }
    }
    .width('100%')
  }

  @Builder
  buildChapterEdge(isEnd: boolean) {
    Column() {
      Text(isEnd ? '已读完' : '下一章')
        .fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark))
      Text(this.chapterTitle || '')
        .fontSize(12).fontColor(ThemeColors.outlineVariant(this.isDark))
        .margin({ top: 4 })
      if (isEnd && this.currentIndex >= this.totalChapters - 1) {
        Text($r('app.string.ui_e647cd13d7')).fontSize(12).fontColor(ThemeColors.outlineVariant(this.isDark))
          .margin({ top: 8 })
      } else if (isEnd) {
        Text($r('app.string.ui_f61763b8b7')).fontSize(12).fontColor(ThemeColors.primary(this.isDark))
          .margin({ top: 8 })
          .onClick(() => { this.onNextChapter(); })
      } else if (!isEnd && this.currentIndex > 0) {
        Text($r('app.string.ui_2c96dbe4ab')).fontSize(12).fontColor(ThemeColors.primary(this.isDark))
          .margin({ top: 8 })
          .onClick(() => { this.onPrevChapter(); })
      }
    }
    .width('100%').height(120)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  buildFooter() {
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
          if (this.imageUrls.length > 0) {
            Text(`${this.currentPageIndex + 1}/${this.imageUrls.length}`)
              .fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ right: 10 })
          }
          Text(`${this.currentIndex + 1}/${this.totalChapters}` +
            (this.totalChapters > 0 ? ` (${this.getProgressPercent()}%)` : '')).fontColor(ThemeColors.onSurface(this.isDark))
            .fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark))
        }
        .width('100%')
        .padding({ left: 20, right: 20 })
      }
      .width('100%')
      .backgroundColor(ThemeColors.comicCanvas(this.isDark))
    }
    .width('100%').height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  buildMenu() {
    Column() {
      // 顶部栏
      Row() {
        Text($r('app.string.ui_9fb248dfd4')).fontSize(24).fontColor(ThemeColors.onSurface(this.isDark))
          .onClick(() => { UiUtil.back(this.getUIContext()); })
          .padding({ left: 12, right: 12 })
        Column() {
          Text(this.bookName || '漫画阅读').fontSize(14).fontColor(ThemeColors.onSurface(this.isDark))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.chapterTitle || '').fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1).alignItems(HorizontalAlign.Start).margin({ left: 4 })
        .onClick(() => { this.openChapterUrl_(); })
        // 模式选择
        Text(this.readModeLabel()).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(4)
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
          .onClick(() => { this.showModeSelect = true; })
      }
      .width('100%').height(52)
      .backgroundColor(ThemeColors.surface(this.isDark))
      .padding({ left: 8, right: 12 })
      .justifyContent(FlexAlign.SpaceBetween)

      Column().width('100%').layoutWeight(1).onClick(() => { this.showMenu = false; })

      // 章节进度条
      if (this.totalChapters > 1) {
        Row() {
          Text($r('app.string.ui_e54d3bce2a')).fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).width(30)
          Slider({ value: this.currentIndex + 1, min: 1, max: this.totalChapters, step: 1 })
            .layoutWeight(1).margin({ left: 8, right: 8 })
            .onChange((val: number) => {
              const idx: number = Math.round(val) - 1;
              if (idx >= 0 && idx < this.allChapters_.length && idx !== this.currentIndex) {
                this.showMenu = false;
                this.loadChapterImages(idx);
              }
            })
          Text(`${this.currentIndex + 1}/${this.totalChapters}`).fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark))
            .width(50).textAlign(TextAlign.End)
        }
        .width('100%').height(40)
        .backgroundColor(ThemeColors.surface(this.isDark))
        .padding({ left: 16, right: 16 })
      }

      // 亮度调节
      Row() {
        Text($r('app.string.ui_5d419889c4')).fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).width(30)
        Slider({ value: this.comicBrightness, min: 0, max: 100, step: 5 })
          .layoutWeight(1).margin({ left: 8, right: 8 })
          .onChange((val: number) => {
            this.comicBrightness = Math.round(val);
            this.saveBrightness_();
          })
        Text(`${this.comicBrightness}`).fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).width(30)
      }
      .width('100%').height(36)
      .backgroundColor(ThemeColors.surface(this.isDark))
      .padding({ left: 16, right: 16 })

      // 页内进度条（图片跳转）
      if (this.imageUrls.length > 1) {
        Row() {
          Text($r('app.string.ui_7b0930e205')).fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).width(30)
          Slider({ value: this.currentPageIndex + 1, min: 1, max: this.imageUrls.length, step: 1 })
            .layoutWeight(1).margin({ left: 8, right: 8 })
            .onChange((val: number) => {
              const idx: number = Math.round(val) - 1;
              if (idx >= 0 && idx < this.imageUrls.length && idx !== this.currentPageIndex) {
                this.currentPageIndex = idx;
                if (this.readMode === READ_MODE_WEBTOON && !this.singlePageMode) {
                  this.listScroller_.scrollToIndex(idx);
                } else {
                  this.swiperIndex = idx;
                }
              }
            })
          Text(`${this.currentPageIndex + 1}/${this.imageUrls.length}`).fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark))
            .width(50).textAlign(TextAlign.End)
        }
        .width('100%').height(40)
        .backgroundColor(ThemeColors.surface(this.isDark))
        .padding({ left: 16, right: 16 })
      }

      // 底部按钮栏
      Row() {
        Column() {
          Text($r('app.string.ui_1393bb2a70')).fontSize(12).fontColor(ThemeColors.onSurface(this.isDark))
        }.layoutWeight(1).justifyContent(FlexAlign.Center)
        .onClick(() => { this.showMenu = false; this.onPrevChapter(); })

        Column() {
          Text($r('app.string.ui_41e5243e2d')).fontSize(12).fontColor(ThemeColors.onSurface(this.isDark))
        }.layoutWeight(1).justifyContent(FlexAlign.Center)
        .onClick(() => { this.showMenu = false; this.onOpenToc(); })

        Column() {
          Text($r('app.string.ui_1b061d776b')).fontSize(12).fontColor(ThemeColors.onSurface(this.isDark))
        }.layoutWeight(1).justifyContent(FlexAlign.Center)
        .onClick(() => { this.showMenu = false; this.onNextChapter(); })

        Column() {
          Text(this.autoRead ? '自动✓' : '自动').fontSize(12)
            .fontColor(this.autoRead ? ThemeColors.primary(this.isDark) : ThemeColors.onSurface(this.isDark))
        }.layoutWeight(1).justifyContent(FlexAlign.Center)
        .onClick(() => { this.toggleAutoRead(); })
      }
      .width('100%').height(48)
      .backgroundColor(ThemeColors.surface(this.isDark))
      .justifyContent(FlexAlign.SpaceEvenly)

      Row() {
        Column() {
          Text($r('app.string.common_refresh')).fontSize(12).fontColor(ThemeColors.onSurface(this.isDark))
        }.layoutWeight(1).justifyContent(FlexAlign.Center)
        .onClick(() => { this.showMenu = false; this.onRefresh(); })

        Column() {
          Text($r('app.string.ui_f28106c1d8')).fontSize(12).fontColor(ThemeColors.onSurface(this.isDark))
        }.layoutWeight(1).justifyContent(FlexAlign.Center)
        .onClick(() => { this.showMenu = false; this.openChangeSourceDialog(); })

        Column() {
          Text(this.singlePageMode ? '单页✓' : '单页').fontSize(12)
            .fontColor(this.singlePageMode ? ThemeColors.primary(this.isDark) : ThemeColors.onSurface(this.isDark))
        }.layoutWeight(1).justifyContent(FlexAlign.Center)
        .onClick(() => { this.toggleSinglePageMode(); })

        Column() {
          Text($r('app.string.ui_580c1ae19a')).fontSize(12).fontColor(ThemeColors.onSurface(this.isDark))
        }.layoutWeight(1).justifyContent(FlexAlign.Center)
        .onClick(() => { this.showMenu = false; this.showZoneConfig = true; })
      }
      .width('100%').height(48)
      .backgroundColor(ThemeColors.surface(this.isDark))
      .justifyContent(FlexAlign.SpaceEvenly)
    }
    .width('100%').height('100%')
  }

  @Builder
  buildModeSelectPanel() {
    Column() {
      Column().width('100%').layoutWeight(1).onClick(() => { this.showModeSelect = false; })
      Column() {
        Text($r('app.string.ui_3eac2277d9')).fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onSurface(this.isDark)).margin({ bottom: 16, top: 16 })
        ForEach([
          { mode: READ_MODE_WEBTOON, label: '条漫（从上到下滚动）' } as ReadModeOption,
          { mode: READ_MODE_LEFT_TO_RIGHT, label: '横向翻页' } as ReadModeOption,
        ], (item: ReadModeOption) => {
          Row() {
            Text(item.label).fontSize(15).fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1)
            if (this.readMode === item.mode) {
              Text($r('app.string.ui_698a879938')).fontSize(18).fontColor(ThemeColors.primary(this.isDark))
            }
          }
          .width('100%').height(48).padding({ left: 24, right: 24 })
          .onClick(() => {
            this.readMode = item.mode;
            this.swiperIndex = this.currentPageIndex;
            this.saveReadMode();
            this.showModeSelect = false;
            this.showMenu = false;
          })
        }, (item: ReadModeOption) => item.mode.toString())
      }
      .width('100%')
      .backgroundColor(ThemeColors.surface(this.isDark))
      .borderRadius({ topLeft: 16, topRight: 16 })
    }
    .width('100%').height('100%')
  }

  @Builder
  buildZoneConfigPanel() {
    Column() {
      Column().width('100%').layoutWeight(1).onClick(() => { this.showZoneConfig = false; })
      Column() {
        Text($r('app.string.ui_ee2972614e')).fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onSurface(this.isDark)).margin({ bottom: 8, top: 16 })
        Text($r('app.string.ui_30abb7cbaa')).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
          .margin({ bottom: 16 })
        // 3x3 网格
        ForEach([0, 1, 2], (rowIdx: number) => {
          Row() {
            ForEach([0, 1, 2], (colIdx: number) => {
              this.buildZoneCell_(rowIdx * 3 + colIdx)
            }, (colIdx: number) => colIdx.toString())
          }
          .width('100%').height(80)
          .justifyContent(FlexAlign.SpaceEvenly)
        }, (rowIdx: number) => rowIdx.toString())
        // 保存按钮
        Button($r('app.string.common_save')).margin({ top: 16, bottom: 16 }).onClick(async () => {
          try {
            const s = SettingsStore.getInstance();
            await s.init(UiUtil.getHostContext(this.getUIContext()));
            for (let i = 0; i < 9; i++) {
              await s.setComicClickAction(i, this.comicZoneActions[i]);
            }
          } catch (_) { /* ignore */ }
          this.showZoneConfig = false;
          UiUtil.showToast(this.getUIContext(), { message: '已保存', duration: 1500 });
        })
      }
      .width('100%')
      .backgroundColor(ThemeColors.surface(this.isDark))
      .borderRadius({ topLeft: 16, topRight: 16 })
      .padding({ left: 16, right: 16, bottom: 16 })
    }
    .width('100%').height('100%')
  }

  @Builder
  buildZoneCell_(zone: number) {
    Column() {
      Text(this.zoneLabel_(zone)).fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark))
      Text(this.actionLabel_(this.comicZoneActions[zone])).fontSize(12)
        .fontColor(ThemeColors.onSurface(this.isDark))
    }
    .width('30%').height(70)
    .borderRadius(8)
    .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
    .justifyContent(FlexAlign.Center)
    .onClick(() => { this.cycleZoneAction_(zone); })
  }

  private zoneLabel_(zone: number): string {
    const labels: string[] = ['左上', '上中', '右上', '左中', '中央', '右中', '左下', '下中', '右下'];
    return labels[zone] || '';
  }

  private actionLabel_(action: number): string {
    switch (action) {
      case -1: return '无';
      case 0: return '菜单';
      case 1: return '下页';
      case 2: return '上页';
      case 3: return '下章';
      case 4: return '上章';
      default: return '无';
    }
  }

  private cycleZoneAction_(zone: number): void {
    const actions: number[] = [-1, 0, 1, 2, 3, 4];  // 无/菜单/下页/上页/下章/上章
    const current: number = this.comicZoneActions[zone];
    const idx: number = actions.indexOf(current);
    const next: number = actions[(idx + 1) % actions.length];
    const newActions: number[] = [...this.comicZoneActions];
    newActions[zone] = next;
    this.comicZoneActions = newActions;
  }

  /** 打开换源面板 */
  private openChangeSourceDialog(): void {
    this.sourceDlg = new CustomDialogController({
      builder: ChangeSourceSheet({
        controller: this.sourceDlg!,
        bookName: this.bookName,
        bookAuthor: '',
        currentOriginUrl: this.originUrl,
        cachedSources: [],
        onReplace: (result: SearchResult) => { this.replaceSource_(result); },
      }),
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      customStyle: true,
    });
    this.sourceDlg.open();
  }

  /** 换源回调：更新书源信息，重新加载 */
  private async replaceSource_(result: SearchResult): Promise<void> {
    const newOriginUrl: string = result.originUrl || this.originUrl;
    const newNoteUrl: string = result.noteUrl || this.bookUrl;
    const sourceChanged: boolean = newOriginUrl !== this.originUrl || newNoteUrl !== this.bookUrl;

    this.origin = result.origin || this.origin;
    this.originUrl = newOriginUrl;
    this.bookUrl = newNoteUrl;
    this.chapterTitle = '';

    if (sourceChanged) {
      // 清空缓存
      this.imageLoadGeneration_++;
      this.allChapters_ = [];
      this.chapters = [];
      this.imageUrls = [];
      this.imagePaths = new Map<string, string>();
      this.nextChapterContent_ = '';
      this.nextChapterIdx_ = -1;
      this.prevChapterContent_ = '';
      this.prevChapterIdx_ = -1;
      this.preloadingChapterPromises_.clear();
      ChapterCache.chapters = [];
      ChapterCache.bookUrl = '';
      this.currentIndex = 0;
      this.currentPageIndex = 0;
      this.targetIdx_ = 0;

      // 更新数据库中的书籍信息
      try {
        const bookTable = new BookTable(AppDatabase.getInstance().rdbStore);
        const book = await bookTable.getBookByUrl(newNoteUrl);
        if (book) {
          book.origin = this.origin;
          book.originUrl = newOriginUrl;
          book.bookUrl = newNoteUrl;
          await bookTable.updateBook(book);
          this.bookId_ = book.id;
        }
      } catch (_) { /* ignore */ }

      // 重新匹配书源并加载
      this.source_ = null;
      this.isLoading = true;
      this.loadContent();
      UiUtil.showToast(this.getUIContext(), { message: '已更换书源', duration: 1500 });
    }
  }

  private onRefresh(): void {
    this.loadChapterImages(this.currentIndex, false, false, -1, true).then(() => {
      UiUtil.showToast(this.getUIContext(), { message: '已刷新', duration: 1500 });
    });
  }

  /** 切换单页全屏模式开关 */
  private async toggleSinglePageMode(): Promise<void> {
    this.singlePageMode = !this.singlePageMode;
    this.showMenu = false;
    // 重置缩放
    this.imageScale = 1.0;
    // 持久化
    try {
      const s = SettingsStore.getInstance();
      await s.setComicSinglePageMode(this.singlePageMode);
    } catch (_) { /* ignore */ }
    UiUtil.showToast(this.getUIContext(), {
      message: this.singlePageMode ? '单页全屏模式' : '已关闭单页全屏',
      duration: 1500,
    });
  }

  /** 长按保存图片到相册 */
  private async saveImageToGallery_(url: string): Promise<void> {
    try {
      // 获取本地缓存路径
      const localPath: string = MangaImageLoader.getLocalPath(url);
      if (!localPath || !await fileFs.access(localPath)) {
        UiUtil.showToast(this.getUIContext(), { message: '图片未缓存，无法保存', duration: 1500 });
        return;
      }

      const ctx = UiUtil.getHostContext(this.getUIContext());
      if (!ctx) {
        UiUtil.showToast(this.getUIContext(), { message: '无法获取上下文', duration: 1500 });
        return;
      }

      const rawExt = (localPath.split('.').pop() || 'jpg').toLowerCase();
      const ext = ['jpg', 'jpeg', 'png', 'gif', 'webp'].includes(rawExt) ? rawExt : 'jpg';
      const title = ('legado_comic_' + Date.now()).replace(/[.\\/:\*\?"'`<>\|\{\}\[\]]/g, '_');
      const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(ctx);
      await helper.showAssetsCreationDialog(
        ['file://' + localPath],
        [{
          title,
          fileNameExtension: ext,
          photoType: photoAccessHelper.PhotoType.IMAGE,
        } as photoAccessHelper.PhotoCreationConfig]
      );

      UiUtil.showToast(this.getUIContext(), { message: '已保存到相册', duration: 1500 });
    } catch (err) {
      console.warn('[ComicRead] Save image failed:', (err as Error).message);
      UiUtil.showToast(this.getUIContext(), { message: '保存失败: ' + (err as Error).message, duration: 2000 });
    }
  }

  /** 启动自动阅读 */
  private startAutoRead(): void {
    if (this.autoRead) return;
    this.autoRead = true;
    const interval: number = this.autoReadSpeed_ * 1000;
    this.autoReadTimer_ = setInterval(() => {
      this.nextPage();
    }, interval);
    this.showMenu = false;
    UiUtil.showToast(this.getUIContext(), { message: `自动阅读 ${this.autoReadSpeed_}s/页`, duration: 1500 });
  }

  /** 停止自动阅读 */
  private stopAutoRead(): void {
    if (!this.autoRead) return;
    this.autoRead = false;
    if (this.autoReadTimer_ >= 0) {
      clearInterval(this.autoReadTimer_);
      this.autoReadTimer_ = -1;
    }
  }

  /** 切换自动阅读 */
  private toggleAutoRead(): void {
    if (this.autoRead) {
      this.stopAutoRead();
      UiUtil.showToast(this.getUIContext(), { message: '已停止自动阅读', duration: 1500 });
    } else {
      this.startAutoRead();
    }
  }

  /** 计算色彩滤镜矩阵（亮度调节） */
  private getColorModify_(): [number, number, number, number, number, number, number, number, number, number, number, number, number, number, number, number, number, number, number, number] {
    if (this.comicBrightness === 50) {
      // 默认矩阵（无变化）
      return [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0];
    }
    // 亮度：50=1.0, 0=0.5(暗), 100=1.5(亮)
    const factor: number = 0.5 + this.comicBrightness / 100;
    // 偏移量：亮度高时加正值，低时减
    const offset: number = (factor - 1.0) * 0.5 * 255;
    return [factor, 0, 0, 0, offset, 0, factor, 0, 0, offset, 0, 0, factor, 0, offset, 0, 0, 0, 1, 0];
  }

  /** 保存亮度设置 */
  private async saveBrightness_(): Promise<void> {
    try {
      const s = SettingsStore.getInstance();
      await s.setComicBrightness(this.comicBrightness);
    } catch (_) { /* ignore */ }
  }

  /** 用系统浏览器打开当前章节 URL */
  private openChapterUrl_(): void {
    const ch = this.allChapters_[this.currentIndex];
    if (!ch || !ch.url) {
      UiUtil.showToast(this.getUIContext(), { message: '无章节URL', duration: 1500 });
      return;
    }
    try {
      const ctx = UiUtil.getHostContext(this.getUIContext()) as common.UIAbilityContext;
      ctx.startAbility({
        action: 'ohos.want.action.viewData',
        uri: ch.url,
      }).catch(() => {
        UiUtil.showToast(this.getUIContext(), { message: '打开失败', duration: 1500 });
      });
    } catch (_) {
      UiUtil.showToast(this.getUIContext(), { message: '启动失败', duration: 1500 });
    }
  }

  private readModeLabel(): string {
    if (this.singlePageMode) return '单页';
    switch (this.readMode) {
      case READ_MODE_LEFT_TO_RIGHT:
      case READ_MODE_RIGHT_TO_LEFT:
        return '横向';
      default: return '条漫';
    }
  }
}
