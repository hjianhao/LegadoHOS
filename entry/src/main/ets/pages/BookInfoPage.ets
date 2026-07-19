import { AppTheme } from '../theme/AppTheme';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookTable } from '../data/database/BookTable';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { ChapterTable } from '../data/database/ChapterTable';
import { WebViewFetcher } from '../engine/web/WebViewFetcher';
import { CloudflareDialog } from '../components/reader/CloudflareDialog';
import { LoginDialog } from '../components/reader/LoginDialog';
import { Book, BookType, BookGroup } from '../model/Book';
import { BookSource } from '../model/BookSource';
import { BookSourceChapter } from '../model/BookSource';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { ChapterCache } from '../util/ChapterCache';
import { NetUtil } from '../util/NetUtil';
import { BookCover } from '../components/BookCover';
import { SearchResult } from '../model/SearchResult';
import { BookChapter, createDefaultChapter } from '../model/BookChapter';
import {
  ChangeCoverSheet,
  ChangeSourceSheet,
  GroupSelectSheet,
  BookReadRecordSheet,
  RemarkEditDialog,
  EditBookInfoDialog
} from '../components/BookInfoSheets';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';
import { ExportBookDialog } from '../components/ExportBookDialog';
import * as ChapterMatcher from '../util/ChapterMatcher';
import { BookSourceResolver } from '../service/BookSourceResolver';
import { AiBookProfileTable } from '../data/database/AiBookProfileTable';
import { normalizeAiChapters } from '../engine/ai/AiBookImporter';

@Entry
@Component
struct BookInfoPage {
  @State bookName: string = '';
  @State bookAuthor: string = '';
  @State coverUrl: string = '';
  @State customCoverPath: string = '';
  @State noteUrl: string = '';
  @State origin: string = '';
  @State originUrl: string = '';
  @State introduce: string = '';
  @State kind: string = '';
  @State wordCount: string = '';
  @State lastUpdateTime: string = '';
  @State remark: string = '';
  @StorageLink('isDark') isDark: boolean = false;
  @State isLoading: boolean = true;
  @State isRefreshing: boolean = false;
  @State isBusy: boolean = false;
  @State isInShelf: boolean = false;
  @State sourceHeader: string = '';
  @State sourceTocUrl: string = '';
  @State coverDecodeJs: string = '';
  @State sourceCount: number = 1;
  @State chapterCount: number = 0;
  @State tocLoadProgress: number = 0;  // 目录加载进度：已加载的章节数
  @State latestChapter: string = '';
  @State chapters: BookSourceChapter[] = [];
  @State recentChapters: BookSourceChapter[] = [];
  @State introExpanded: boolean = false;
  @State titleExpanded: boolean = false;
  @State showMoreMenu: boolean = false;
  @State deleteAlertEnabled: boolean = true;
  @State durChapterTitle: string = '';
  @State durChapterIndex: number = 0;
  @State lastReadTime: string = '';
  @State bookId: number = 0;
  @State groupId: number = BookGroup.ALL;
  @State showExportDialog: boolean = false;

  private cachedSearchResults: SearchResult[] = [];
  private sourceTocOriginUrl: string = '';
  private currentSource_: BookSource | null = null;  // 缓存当前匹配到的书源对象
  private coverDlg?: CustomDialogController;
  private sourceDlg?: CustomDialogController;
  private groupDlg?: CustomDialogController;
  private readRecordDlg?: CustomDialogController;
  private remarkDlg?: CustomDialogController
  private editInfoDlg?: CustomDialogController
  private loginDlg?: CustomDialogController

  aboutToAppear(): void {
    const params = UiUtil.getParams(this.getUIContext()) as Record<string, string>;
    if (params) {
      this.bookName = params['name'] || '';
      this.bookAuthor = params['author'] || '';
      this.coverUrl = params['coverUrl'] || '';
      this.noteUrl = params['noteUrl'] || '';
      this.origin = params['origin'] || '';
      this.originUrl = params['originUrl'] || '';
      this.introduce = params['introduce'] || '';
      this.kind = params['kind'] || '';
      this.wordCount = params['wordCount'] || '';
      this.lastUpdateTime = params['lastUpdateTime'] || '';
      this.latestChapter = params['latestChapterTitle'] || '';
      try {
        const cachedStr = String(params['cachedSources'] || '');
        if (cachedStr) {
          this.cachedSearchResults = JSON.parse(cachedStr) as SearchResult[];
        }
      } catch (_e) { this.cachedSearchResults = []; }
    }
    this.loadSourceHeader();
    this.checkShelfStatus();
    // 注册 Cloudflare 交互验证：当请求被拦截时弹出 WebView 让用户手动验证
    WebViewFetcher.interactiveFetcher = (url: string): Promise<string> => {
      return new Promise((resolve) => {
        WebViewFetcher.interactiveResolve = resolve;
        let dlg: CustomDialogController | null = null;
        dlg = new CustomDialogController({
          builder: CloudflareDialog({ controller: dlg!, url: url }),
          autoCancel: false,
          customStyle: true,
          alignment: DialogAlignment.Center,
        });
        dlg.open();
      });
    };
    // 登录弹窗
    this.loginDlg = new CustomDialogController({
      builder: LoginDialog({ controller: this.loginDlg! }),
      autoCancel: true,
      customStyle: true,
      alignment: DialogAlignment.Center,
    });
    this.tryFetchBookInfo();
    this.tryFetchCover();
    this.isLoading = false;
  }

  /** 从源获取书籍详情和目录 */
  async tryFetchBookInfo(): Promise<void> {
    if (!this.noteUrl || !this.originUrl) return;
    this.isRefreshing = true;
    this.tocLoadProgress = 0;
    try {
      await AppDatabase.getInstance().waitForInit();
      const matched = await BookSourceResolver.resolveByIdentity(
        this.bookId, this.noteUrl, this.originUrl, this.origin);
      if (!matched) {
        console.warn('[BookInfo] No matching source/profile found for originUrl=' + this.originUrl);
        return;
      }
      this.currentSource_ = matched;  // 缓存书源对象，供路由分流判断
      this.coverDecodeJs = matched?.coverDecodeJs || '';
      // 获取书籍详情（始终请求，确保简介等字段为最新）
      const info = await globalSourceExecutor.getBookInfo(matched, this.noteUrl);
      if (info.name && !this.bookName) this.bookName = info.name;
      if (info.author && !this.bookAuthor) this.bookAuthor = info.author;
      if (info.coverUrl && !this.coverUrl) this.coverUrl = info.coverUrl;
      if (info.introduce) this.introduce = info.introduce;
      if (info.kind && !this.kind) this.kind = info.kind;
      if (info.wordCount && !this.wordCount) this.wordCount = info.wordCount;
      if (info.tocUrl) {
        this.sourceTocUrl = info.tocUrl;
        this.sourceTocOriginUrl = matched.sourceUrl || this.originUrl;
      }
      // 获取目录统计（带进度回调）
      const rawChapters = await globalSourceExecutor.getToc(matched, this.getCurrentTocUrl() || this.noteUrl,
        (loaded: number) => { this.tocLoadProgress = loaded; });
      const aiProfileDao = new AiBookProfileTable(AppDatabase.getInstance().rdbStore);
      const aiProfile = this.bookId > 0
        ? await aiProfileDao.getByBookId(this.bookId) : await aiProfileDao.getByBookUrl(this.noteUrl);
      const chapters = aiProfile ? normalizeAiChapters(rawChapters) : rawChapters;
      if (chapters.length > 0) {
        this.chapterCount = chapters.length;
        const last = chapters[chapters.length - 1];
        this.latestChapter = last.title || '';
        this.recentChapters = chapters.slice(0, 5);
        // 缓存目录以便 ReadPage 复用（避免二次拉取）
        ChapterCache.bookUrl = this.noteUrl;
        ChapterCache.chapters = chapters;
        if (this.bookId > 0) {
          await new ChapterTable(AppDatabase.getInstance().rdbStore)
            .replaceTocPreserveContent(this.bookId, chapters);
        }
      }
    } catch (_e) { /* ignore */ }
    this.isRefreshing = false;
  }

  /** 检查书籍是否已在书架 */
  async checkShelfStatus(): Promise<void> {
    if (!this.bookName && !this.noteUrl) return;
    try {
      await AppDatabase.getInstance().waitForInit();
      const bookTable = new BookTable(AppDatabase.getInstance().rdbStore);
      if (this.noteUrl) {
        let matched = await bookTable.getBookByUrl(this.noteUrl);
        if (!matched && this.bookName) {
          const existing = await bookTable.searchBooks(this.bookName);
          matched = existing.find(b => b.isShelf && (b.name === this.bookName || (this.bookAuthor && b.author === this.bookAuthor))) || null;
        }
        if (matched && matched.isShelf) {
          // 保存 router param 传入的 coverUrl（避免被 DB 中的错误值覆盖）
          const paramCoverUrl = this.coverUrl;
          const paramCustomCover = this.customCoverPath;
          this.isInShelf = true;
          this.bookId = matched.id;
          if (matched.name) this.bookName = matched.name;
          if (matched.author) this.bookAuthor = matched.author;
          // DB 读取时，优先用 router 传进来的封面 URL（最新搜索结果的），DB 中的仅做兜底
          if (!this.coverUrl) this.coverUrl = matched.coverUrl;
          if (!this.customCoverPath) this.customCoverPath = matched.customCoverPath;
          if (matched.origin) this.origin = matched.origin;
          if (matched.originUrl) this.originUrl = matched.originUrl;
          if (matched.bookUrl) this.noteUrl = matched.bookUrl;
          if (matched.tocUrl) {
            this.sourceTocUrl = matched.tocUrl;
            this.sourceTocOriginUrl = matched.originUrl || this.originUrl;
          }
          if (matched.kind) this.kind = matched.kind;
          if (matched.wordCount) this.wordCount = matched.wordCount;
          if (matched.introduce) this.introduce = matched.introduce;
          if (matched.remark) this.remark = matched.remark;
          if (matched.lastUpdateTime) this.lastUpdateTime = matched.lastUpdateTime;
          if (matched.latestChapterTitle) this.latestChapter = matched.latestChapterTitle;
          if (matched.totalChapterNum > 0) this.chapterCount = matched.totalChapterNum;
          this.durChapterTitle = matched.durChapterTitle || '';
          this.durChapterIndex = matched.durChapterIndex || 0;
          if (matched.lastOpenTime > 0) {
            const d = new Date(matched.lastOpenTime);
            this.lastReadTime = d.getMonth()+1 + '-' + d.getDate() + ' ' +
              String(d.getHours()).padStart(2,'0') + ':' + String(d.getMinutes()).padStart(2,'0');
          }
          console.info('[BookInfo] found in shelf, id=', matched.id, 'progress=', matched.durChapterTitle);
        } else {
          this.isInShelf = false;
          this.bookId = 0;
        }
      }
    } catch (_e) { /* ignore */ }
  }

  /** 从书架删除 */
  async removeFromShelf(): Promise<void> {
    if (!this.bookId) {
      UiUtil.showToast(this.getUIContext(), { message: '未在书架中', duration: 1500 });
      return;
    }
    UiUtil.showDialog(this.getUIContext(), {
      title: '确认删除',
      message: '从书架中移除 "' + this.bookName + '"？',
      buttons: [
        { text: '取消', color: ThemeColors.secondaryText(this.isDark) },
        { text: '删除', color: ThemeColors.error(this.isDark) }
      ]
    }).then((res: Object) => {
      if ((res as Record<string, Object>)['index'] === 1) this.doDelete();
    });
  }

  private async doDelete(): Promise<void> {
    try {
      const bookTable = new BookTable(AppDatabase.getInstance().rdbStore);
      await bookTable.updateBook({
        id: this.bookId, name: this.bookName, author: this.bookAuthor,
        coverUrl: this.coverUrl, customCoverPath: '', bookUrl: this.noteUrl,
        origin: this.origin, originUrl: this.originUrl, type: 0, groupId: 0,
        tocUrl: '', chapterCount: 0, totalChapterNum: 0, latestChapterTitle: '',
        durChapterTitle: '', durChapterIndex: 0, durChapterPos: 0, durChapterProgress: 0,
        isRead: false, isAudio: false, isManga: false, isShelf: false, order: 0,
        canUpdate: true,
        kind: '', wordCount: '', introduce: '', remark: '', lastUpdateTime: '', lastOpenTime: 0,
        createTime: 0, updateTime: Date.now(), syncTime: 0
      });
      this.isInShelf = false;
      this.bookId = 0;
      AppStorage.set<number>('shelfRefreshCounter', (AppStorage.get<number>('shelfRefreshCounter') || 0) + 1);
      UiUtil.showToast(this.getUIContext(), { message: '已从书架移除', duration: 1500 });
    } catch (_e) {
      UiUtil.showToast(this.getUIContext(), { message: '删除失败', duration: 2000 });
    }
  }

  private clearCache(): void {
    if (!this.bookId) {
      UiUtil.showToast(this.getUIContext(), { message: '未在书架中', duration: 1500 });
      return;
    }
    UiUtil.showDialog(this.getUIContext(), {
      title: '清除缓存',
      message: '清除《' + this.bookName + '》已缓存的章节内容？目录和阅读进度会保留。',
      buttons: [
        { text: '取消', color: ThemeColors.secondaryText(this.isDark) },
        { text: '清除', color: ThemeColors.warning(this.isDark) }
      ]
    }).then((res: Object) => {
      if ((res as Record<string, Object>)['index'] === 1) this.doClearCache();
    });
  }

  private async doClearCache(): Promise<void> {
    try {
      const chapterTable = new ChapterTable(AppDatabase.getInstance().rdbStore);
      await chapterTable.clearContentByBookId(this.bookId);
      UiUtil.showToast(this.getUIContext(), { message: '成功清理缓存', duration: 1500 });
    } catch (_e) {
      UiUtil.showToast(this.getUIContext(), { message: '清理缓存失败', duration: 1500 });
    }
  }

  /** 从书籍详情页提取封面图 */
  async tryFetchCover(): Promise<void> {
    if (this.coverUrl || !this.noteUrl) return;
    try {
      const html = await NetUtil.httpGet(this.noteUrl, {
        'Accept': 'text/html,*/*',
        'Referer': this.originUrl || this.noteUrl,
      });
      if (!html) return;
      // 尝试常见封面位置：<img> 标签（优先大图）
      const imgRegex = /<img[^>]*src=["']([^"']+(?:jpe?g|png|webp|gif|bmp)[^"']*)["'][^>]*>/i;
      const m = html.match(imgRegex);
      if (m) {
        let url = m[1];
        if (url && !url.startsWith('http')) {
          const baseUrl = this.noteUrl.replace(/\/[^/]*$/, '');
          url = (baseUrl || '') + (url.startsWith('/') ? url : '/' + url);
        }
        this.coverUrl = url;
        console.info('[BookInfo] Cover extracted from detail page:', url.substring(0, 60));
      }
    } catch (e) {
      console.warn('[BookInfo] Cover fetch failed:', (e as Error).message);
    }
  }

  // 加载书源的请求头
  async loadSourceHeader(): Promise<void> {
    if (!this.originUrl) return;
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const matched = await BookSourceResolver.resolveByIdentity(
        this.bookId, this.noteUrl, this.originUrl, this.origin);
      if (matched && matched.header) {
        this.sourceHeader = matched.header;
        console.info('[BookInfo] Header found for', this.originUrl, ':', matched.header.substring(0, 50));
      } else {
        console.info('[BookInfo] No header for', this.originUrl, 'matched:', matched !== undefined);
      }
    } catch (_e) { /* ignore */ }
  }

  async addToShelf(): Promise<void> {
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const bookTable = new BookTable(db);

      // 去重检查：严格按 bookUrl 匹配，不同源的书允许同名
      const nowTs = Date.now();
      if (this.noteUrl) {
        const existing = await bookTable.getBookByUrl(this.noteUrl);
        if (existing) {
          if (!existing.isShelf) {
            existing.isShelf = true;
            existing.updateTime = nowTs;
          }
          // 始终用详情页最新数据更新关键字段（coverUrl 用有效值）
          const shelfCover = this.getEffectiveCoverUrl();
          if (shelfCover) existing.coverUrl = shelfCover;
          if (this.customCoverPath && !existing.customCoverPath) existing.customCoverPath = this.customCoverPath;
          if (this.kind && !existing.kind) existing.kind = this.kind;
          if (this.wordCount && !existing.wordCount) existing.wordCount = this.wordCount;
          if (this.introduce && !existing.introduce) existing.introduce = this.introduce;
          if (this.origin && !existing.origin) existing.origin = this.origin;
          if (this.originUrl && !existing.originUrl) existing.originUrl = this.originUrl;
          if (this.getCurrentTocUrl()) existing.tocUrl = this.getCurrentTocUrl();
          existing.updateTime = nowTs;
          await bookTable.updateBook(existing);
          this.isInShelf = true;
          this.bookId = existing.id;
          this.groupId = existing.groupId;
          this.durChapterTitle = existing.durChapterTitle || '';
          this.durChapterIndex = existing.durChapterIndex || 0;
          // 确保目录已保存到数据库（修复重启后目录丢失的问题）
          await this.ensureChaptersInDb(existing.id);
          AppStorage.set<number>('shelfRefreshCounter', (AppStorage.get<number>('shelfRefreshCounter') || 0) + 1);
          UiUtil.showToast(this.getUIContext(), { message: '已加入书架', duration: 1500 });
          return;
        }
      }

      const effectiveCover = this.getEffectiveCoverUrl();
      const insertTime = Date.now();
      const isMangaSource: boolean = this.currentSource_ ? (this.currentSource_.sourceType === 2) : false;
      const book: Book = {
        id: 0,
        name: this.bookName,
        author: this.bookAuthor,
        coverUrl: effectiveCover,
        customCoverPath: this.customCoverPath,
        bookUrl: this.noteUrl,
        tocUrl: this.getCurrentTocUrl(),
        origin: this.origin,
        originUrl: this.originUrl,
        type: isMangaSource ? BookType.MANGA : BookType.TEXT,
        groupId: BookGroup.ALL,
        chapterCount: this.chapterCount,
        totalChapterNum: this.chapterCount,
        latestChapterTitle: '',
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
        kind: this.kind,
        wordCount: this.wordCount,
        introduce: this.introduce,
        remark: '',
        lastUpdateTime: '',
        lastOpenTime: 0,
        createTime: insertTime,
        updateTime: insertTime,
        syncTime: 0,
      };

      const id = await bookTable.insertBook(book);
      if (id > 0) {
        this.bookId = id;
        this.isInShelf = true;
        this.groupId = book.groupId;
        // 保存目录到数据库（修复重启后目录丢失的问题）
        await this.saveChaptersToDb(id);
        AppStorage.set<number>('shelfRefreshCounter', (AppStorage.get<number>('shelfRefreshCounter') || 0) + 1);
        UiUtil.showToast(this.getUIContext(), { message: '已加入书架', duration: 1500 });
      }
    } catch (err) {
      UiUtil.showToast(this.getUIContext(), { message: '加入书架失败', duration: 2000 });
    }
  }

  /**
   * 保存目录到数据库（新增书籍时调用）
   * 优先使用 ChapterCache 中已缓存的目录，避免重复网络请求
   */
  private async saveChaptersToDb(bookId: number): Promise<void> {
    try {
      let chapters: BookSourceChapter[] = [];
      if (ChapterCache.chapters.length > 0 && ChapterCache.bookUrl === this.noteUrl) {
        chapters = ChapterCache.chapters;
      } else if (this.chapters.length > 0) {
        chapters = this.chapters;
      }
      if (chapters.length === 0) return;

      const ct = new ChapterTable(AppDatabase.getInstance().rdbStore);
      await ct.replaceTocPreserveContent(bookId, chapters);

      // 更新书籍的章数和最新章节标题
      const lastCh = chapters[chapters.length - 1];
      const bookTable = new BookTable(AppDatabase.getInstance().rdbStore);
      await bookTable.updateTocInfo(bookId, chapters.length, lastCh.title || '');
      console.info('[BookInfo] Saved', chapters.length, 'chapters to DB for bookId=', bookId);
    } catch (e) {
      console.warn('[BookInfo] Failed to save chapters to DB:', (e as Error).message);
    }
  }

  /**
   * 确保目录已存入数据库（已有书籍重新加入书架时调用）
   * 仅在 DB 中无目录时才写入，避免覆盖已有内容缓存
   */
  private async ensureChaptersInDb(bookId: number): Promise<void> {
    try {
      const ct = new ChapterTable(AppDatabase.getInstance().rdbStore);
      const existingCount = await ct.getChapterCount(bookId);
      if (existingCount > 0) return; // 目录已存在，跳过

      await this.saveChaptersToDb(bookId);
    } catch (e) {
      console.warn('[BookInfo] Failed to ensure chapters in DB:', (e as Error).message);
    }
  }

  /**
   * 开始阅读（对齐 Android readBook + openReader）：
   * 1. 不在书架 → 隐式保存（标记 notShelf），加入数据库后再打开阅读器
   * 2. 已在书架 → 更新 lastOpenTime 后打开
   */
  /**
   * 确保已加载书源对象（用于 startRead/startReadAt 时 currentSource_ 可能为 null 的情况）
   * 返回是否为漫画源
   */
  private async ensureMangaFlag_(): Promise<boolean> {
    if (this.currentSource_) {
      return this.currentSource_.sourceType === 2;
    }
    // currentSource_ 为 null，从 DB 查询
    try {
      await AppDatabase.getInstance().waitForInit();
      const matched = await BookSourceResolver.resolveByIdentity(
        this.bookId, this.noteUrl, this.originUrl, this.origin);
      if (matched) {
        this.currentSource_ = matched;
        return matched.sourceType === 2;
      }
    } catch (_) { /* ignore */ }
    return false;
  }

  async startRead(): Promise<void> {
    if (this.isRefreshing) {
      UiUtil.showToast(this.getUIContext(), { message: '目录加载中，请稍候', duration: 1500 });
      return;
    }
    if (!this.isInShelf) {
      const saved = await this.saveBookImplicitly();
      if (!saved) {
        UiUtil.showToast(this.getUIContext(), { message: '保存失败，请重试', duration: 1500 });
        return;
      }
    } else if (this.bookId > 0) {
      await this.updateLastOpenTime();
    }
    const isManga: boolean = await this.ensureMangaFlag_();
    const targetPage = isManga ? 'pages/ComicReadPage' : 'pages/ReadPage';
    UiUtil.pushUrl(this.getUIContext(), {
      url: targetPage,
      params: {
        name: this.bookName,
        author: this.bookAuthor,
        bookUrl: this.noteUrl,
        tocUrl: this.getCurrentTocUrl(),
        origin: this.origin,
        originUrl: this.originUrl,
        header: this.sourceHeader,
        bookId: this.bookId,
        inBookshelf: this.isInShelf,
        cachedSources: JSON.stringify(this.cachedSearchResults),
      }
    });
  }

  async startReadAt(index: number): Promise<void> {
    if (this.isRefreshing) {
      UiUtil.showToast(this.getUIContext(), { message: '目录加载中，请稍候', duration: 1500 });
      return;
    }
    const isManga: boolean = await this.ensureMangaFlag_();
    const targetPage = isManga ? 'pages/ComicReadPage' : 'pages/ReadPage';
    UiUtil.pushUrl(this.getUIContext(), {
      url: targetPage,
      params: {
        name: this.bookName,
        author: this.bookAuthor,
        bookUrl: this.noteUrl,
        tocUrl: this.getCurrentTocUrl(),
        origin: this.origin,
        originUrl: this.originUrl,
        header: this.sourceHeader,
        durChapterIndex: index,
        bookId: this.bookId,
        inBookshelf: this.isInShelf,
        cachedSources: JSON.stringify(this.cachedSearchResults),
      }
    });
  }

  /**
   * 不在书架时隐式保存书籍（对齐 Android readBook() 中 BookType.notShelf 逻辑）
   * 保存后 isShelf = false，后续进入书架页不会展示
   */
  private async saveBookImplicitly(): Promise<boolean> {
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const bookTable = new BookTable(db);

      // 检查是否已存在（通过 bookUrl）
      if (this.noteUrl) {
        const existing = await bookTable.getBookByUrl(this.noteUrl);
        if (existing) {
          this.bookId = existing.id;
          await this.updateLastOpenTime();
          AppStorage.set<number>('shelfRefreshCounter', (AppStorage.get<number>('shelfRefreshCounter') || 0) + 1);
          return true;
        }
      }

      const effectiveCover = this.getEffectiveCoverUrl();
      const insertTime = Date.now();
      const isMangaSource = this.currentSource_ ? (this.currentSource_.sourceType === 2) : false;
      const book: Book = {
        id: 0,
        name: this.bookName,
        author: this.bookAuthor,
        coverUrl: effectiveCover,
        customCoverPath: this.customCoverPath,
        bookUrl: this.noteUrl,
        origin: this.origin,
        originUrl: this.originUrl,
        type: isMangaSource ? BookType.MANGA : BookType.TEXT,
        groupId: BookGroup.ALL,
        tocUrl: this.getCurrentTocUrl(),
        chapterCount: this.chapterCount,
        totalChapterNum: this.chapterCount,
        latestChapterTitle: this.latestChapter,
        durChapterTitle: this.durChapterTitle,
        durChapterIndex: this.durChapterIndex,
        durChapterPos: 0,
        durChapterProgress: 0,
        isRead: false,
        isAudio: false,
        isManga: isMangaSource,
        isShelf: false,  // 关键：不在书架（对齐 Android BookType.notShelf）
        order: 0,
        canUpdate: true,
        kind: this.kind,
        wordCount: this.wordCount,
        introduce: this.introduce,
        remark: this.remark,
        lastUpdateTime: this.lastUpdateTime,
        lastOpenTime: insertTime,
        createTime: insertTime,
        updateTime: insertTime,
        syncTime: 0,
      };

      const id = await bookTable.insertBook(book);
      if (id > 0) {
        this.bookId = id;
        AppStorage.set<number>('shelfRefreshCounter', (AppStorage.get<number>('shelfRefreshCounter') || 0) + 1);
        return true;
      }
      return false;
    } catch (err) {
      console.error('[BookInfo] saveBookImplicitly failed:', (err as Error).message);
      return false;
    }
  }

  /** 更新最后打开时间 */
  private async updateLastOpenTime(): Promise<void> {
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const bookTable = new BookTable(db);
      const book = await bookTable.getBookById(this.bookId);
      if (book) {
        book.lastOpenTime = Date.now();
        book.updateTime = Date.now();
        await bookTable.updateBook(book);
      }
    } catch (_e) {
      /* non-critical */
    }
  }

  changeSource(): void {
    const cached = this.cachedSearchResults;
    this.sourceDlg = new CustomDialogController({
      builder: ChangeSourceSheet({
        controller: this.sourceDlg!,
        bookName: this.bookName,
        bookAuthor: this.bookAuthor,
        currentOriginUrl: this.originUrl,
        cachedSources: cached,
        currentSourceType: this.currentSource_ ? this.currentSource_.sourceType : -1,
        onReplace: (result: SearchResult) => { this.replaceWithSource(result); },
        onAddAsNew: (result: SearchResult) => { this.addSourceAsNewBook(result); }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      customStyle: true
    });
    this.sourceDlg.open();
  }

  private replaceWithSource(result: SearchResult): void {
    const newOriginUrl = result.originUrl || this.originUrl;
    const newNoteUrl = result.noteUrl || this.noteUrl;
    const sourceChanged = newOriginUrl !== this.originUrl || newNoteUrl !== this.noteUrl;
    if (!sourceChanged) {
      this.recentChapters = [];
      return;
    }
    // 书架书籍：先加载新源目录校验，成功后再迁移数据库记录（对齐 Legado ChangeBookSourceUseCase）
    if (this.isInShelf && this.bookId > 0) {
      this.migrateShelfBookToSource_(result, newOriginUrl, newNoteUrl);
      return;
    }
    // 未入架书籍：只切换当前页面的书源指向，重新加载详情
    this.switchUnshelvedSource_(result, newOriginUrl, newNoteUrl);
  }

  /** 未入架书籍的换源：只更新页面状态并重新拉取详情 */
  private switchUnshelvedSource_(result: SearchResult, newOriginUrl: string, newNoteUrl: string): void {
    const oldNoteUrl = this.noteUrl;
    this.origin = result.origin || this.origin;
    this.originUrl = newOriginUrl;
    this.noteUrl = newNoteUrl;
    if (result.coverUrl) this.coverUrl = result.coverUrl;
    if (result.kind) this.kind = result.kind;
    if (result.wordCount) this.wordCount = result.wordCount;
    if (result.introduce) this.introduce = result.introduce;
    this.sourceHeader = '';
    this.sourceTocUrl = '';
    this.sourceTocOriginUrl = '';
    this.chapterCount = 0;
    this.latestChapter = result.latestChapterTitle || '';
    this.recentChapters = [];
    this.chapters = [];
    this.isInShelf = false;
    this.bookId = 0;
    this.durChapterTitle = '';
    this.durChapterIndex = 0;
    this.lastReadTime = '';
    if (ChapterCache.bookUrl === oldNoteUrl || ChapterCache.bookUrl === newNoteUrl) {
      ChapterCache.bookUrl = '';
      ChapterCache.chapters = [];
      ChapterCache.targetIndex = -1;
    }
    console.info('[BookInfo] Source switched (unshelved):',
      'originUrl=' + this.originUrl.substring(0, 80),
      'noteUrl=' + this.noteUrl.substring(0, 80));
    this.loadSourceHeader();
    this.tryFetchBookInfo();
    this.tryFetchCover();
    UiUtil.showToast(this.getUIContext(), { message: '已更换书源', duration: 1500 });
  }

  /**
   * 书架书籍换源（对齐 Legado ChangeBookSourceUseCase）：
   * 1. 先加载新源详情 + 目录并校验（目录为空则失败回退，不动数据库）
   * 2. 按章节标题/章节号匹配当前阅读进度（BookHelp.getDurChapter）
   * 3. 校验通过后更新书架记录、替换目录（保留分组/排序/自定义封面/备注）
   */
  private async migrateShelfBookToSource_(result: SearchResult, newOriginUrl: string, newNoteUrl: string): Promise<void> {
    UiUtil.showToast(this.getUIContext(), { message: '正在校验新书源...', duration: 1500 });
    // 回滚快照
    let bookBackup: Book | null = null;
    let chaptersBackup: BookChapter[] = [];
    let migrated = false;
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const srcDao = new BookSourceTable(db);
      const sources = await srcDao.getAllSources();
      const norm = newOriginUrl.replace(/\/+$/, '');
      const newSource = sources.find(s => s.sourceUrl === newOriginUrl) ||
        sources.find(s => s.sourceUrl.replace(/\/+$/, '') === norm) ||
        sources.find(s => s.sourceName === result.origin) || null;
      if (!newSource) throw new Error('未找到对应书源');

      // 先验证：加载新源详情 + 目录，目录为空则视为失败
      let newTocUrl = '';
      try {
        const info = await globalSourceExecutor.getBookInfo(newSource, newNoteUrl);
        newTocUrl = info.tocUrl || '';
      } catch (_e) { /* 详情失败时用 bookUrl 兜底拉目录 */ }
      const primaryTocUrl = newTocUrl || newNoteUrl;
      let newToc = await globalSourceExecutor.getToc(newSource, primaryTocUrl);
      if (newToc.length === 0 && primaryTocUrl !== newNoteUrl) {
        newToc = await globalSourceExecutor.getToc(newSource, newNoteUrl);
      }
      if (newToc.length === 0) throw new Error('新源目录为空');

      // 在新目录中匹配当前阅读进度
      const matchedIdx = ChapterMatcher.getDurChapterIndex(
        this.durChapterIndex, this.durChapterTitle, newToc, this.chapterCount);

      // 目标 URL 查重：已是另一书架记录则拒绝，避免产生重复 bookUrl
      const bookTable = new BookTable(db);
      const book = await bookTable.getBookById(this.bookId);
      if (!book) throw new Error('书籍记录不存在');
      const dupBook = await bookTable.getBookByUrl(newNoteUrl);
      if (dupBook && dupBook.id !== book.id) {
        if (dupBook.isShelf) throw new Error('目标源的书籍已在书架中');
        await bookTable.deleteBook(dupBook.id);
      }

      // 快照旧记录，供提交后异常时明确恢复（ArkTS 禁止对象展开，用 JSON 深拷贝）
      bookBackup = JSON.parse(JSON.stringify(book)) as Book;
      const ct = new ChapterTable(db);
      chaptersBackup = await ct.getChaptersByBookId(book.id);

      book.bookUrl = newNoteUrl;
      book.origin = result.origin || newSource.sourceName || this.origin;
      book.originUrl = newOriginUrl;
      book.tocUrl = primaryTocUrl;
      if (result.coverUrl && !book.customCoverPath) book.coverUrl = result.coverUrl;
      if (result.kind) book.kind = result.kind;
      if (result.wordCount) book.wordCount = result.wordCount;
      if (result.introduce) book.introduce = result.introduce;
      book.latestChapterTitle = newToc[newToc.length - 1]?.title || '';
      book.chapterCount = newToc.length;
      book.totalChapterNum = newToc.length;
      book.durChapterIndex = matchedIdx;
      book.durChapterTitle = newToc[matchedIdx]?.title || '';
      book.updateTime = Date.now();

      // 事务迁移：更新书架记录 + 替换目录（旧章节内容缓存一并清除）
      const now = Date.now();
      const rows: BookChapter[] = newToc.map((ch: BookSourceChapter, idx: number): BookChapter => {
        const item = createDefaultChapter();
        item.bookId = book.id;
        item.index = ch.index >= 0 ? ch.index : idx;
        item.title = ch.title || '';
        item.url = ch.url || '';
        item.createTime = now;
        item.updateTime = now;
        return item;
      });
      db.beginTransaction();
      try {
        await bookTable.updateBook(book);
        await ct.deleteChaptersByBookId(book.id);
        await ct.insertChapters(rows);
        db.commit();
        migrated = true;
      } catch (txErr) {
        db.rollBack();
        throw new Error('数据库迁移失败: ' + (txErr as Error).message);
      }

      // 更新页面状态
      this.origin = book.origin;
      this.originUrl = newOriginUrl;
      this.noteUrl = newNoteUrl;
      this.sourceTocUrl = primaryTocUrl;
      this.sourceTocOriginUrl = newOriginUrl;
      this.currentSource_ = newSource;
      this.coverDecodeJs = newSource.coverDecodeJs || '';
      if (result.coverUrl && !this.customCoverPath) this.coverUrl = result.coverUrl;
      if (result.kind) this.kind = result.kind;
      if (result.wordCount) this.wordCount = result.wordCount;
      if (result.introduce) this.introduce = result.introduce;
      this.chapterCount = newToc.length;
      this.latestChapter = book.latestChapterTitle;
      this.recentChapters = newToc.slice(0, 5);
      this.chapters = newToc;
      this.durChapterIndex = matchedIdx;
      this.durChapterTitle = newToc[matchedIdx]?.title || '';
      this.sourceHeader = '';
      this.loadSourceHeader();
      ChapterCache.bookUrl = newNoteUrl;
      ChapterCache.chapters = newToc;
      ChapterCache.targetIndex = matchedIdx;
      AppStorage.set<number>('shelfRefreshCounter', (AppStorage.get<number>('shelfRefreshCounter') || 0) + 1);
      UiUtil.showToast(this.getUIContext(), {
        message: '已更换书源：' + (this.durChapterTitle || '第 ' + (matchedIdx + 1) + ' 章'),
        duration: 2000
      });
    } catch (e) {
      console.error('[BookInfo] migrateShelfBookToSource failed:', (e as Error).message);
      // 已提交事务后出现意外：用快照明确恢复旧书籍记录和旧目录
      if (migrated && bookBackup) {
        try {
          const db = AppDatabase.getInstance().rdbStore;
          const bookTable = new BookTable(db);
          const ct = new ChapterTable(db);
          await bookTable.updateBook(bookBackup);
          await ct.deleteChaptersByBookId(bookBackup.id);
          if (chaptersBackup.length > 0) await ct.insertChapters(chaptersBackup);
        } catch (rbErr) {
          console.error('[BookInfo] rollback failed:', (rbErr as Error).message);
        }
      }
      UiUtil.showToast(this.getUIContext(), { message: '换源失败：' + (e as Error).message, duration: 2000 });
    }
  }

  /**
   * 作为新书加入书架（对齐 Legado：先加载详情+目录，成功后才写入）
   * 目录加载失败则不加，避免书架上留下没有目录的书
   */
  private async addSourceAsNewBook(result: SearchResult): Promise<void> {
    if (!result.noteUrl || !result.originUrl) {
      UiUtil.showToast(this.getUIContext(), { message: '书源信息不完整', duration: 1500 });
      return;
    }
    UiUtil.showToast(this.getUIContext(), { message: '正在加载书籍信息...', duration: 1500 });
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const bookTable = new BookTable(db);
      const existing = await bookTable.getBookByUrl(result.noteUrl);
      if (existing && existing.isShelf) {
        UiUtil.showToast(this.getUIContext(), { message: '该书已在书架中', duration: 1500 });
        return;
      }
      const srcDao = new BookSourceTable(db);
      const sources = await srcDao.getAllSources();
      const norm = result.originUrl.replace(/\/+$/, '');
      const src = sources.find(s => s.sourceUrl === result.originUrl) ||
        sources.find(s => s.sourceUrl.replace(/\/+$/, '') === norm) ||
        sources.find(s => s.sourceName === result.origin) || null;
      if (!src) throw new Error('未找到对应书源');

      // 先验证：加载详情 + 目录，目录为空则视为不可用
      let tocUrl = '';
      let infoCover = '';
      let infoIntroduce = '';
      let infoKind = '';
      let infoWordCount = '';
      try {
        const info = await globalSourceExecutor.getBookInfo(src, result.noteUrl);
        tocUrl = info.tocUrl || '';
        infoCover = info.coverUrl || '';
        infoIntroduce = info.introduce || '';
        infoKind = info.kind || '';
        infoWordCount = info.wordCount || '';
      } catch (_e) { /* 详情失败时用搜索结果自带字段 */ }
      const toc = await globalSourceExecutor.getToc(src, tocUrl || result.noteUrl);
      if (toc.length === 0) throw new Error('目录加载失败');

      const isManga = src.sourceType === 2;
      const now = Date.now();
      const ct = new ChapterTable(db);
      const chapterRows: BookChapter[] = toc.map((ch: BookSourceChapter, idx: number): BookChapter => {
        const item = createDefaultChapter();
        item.index = ch.index >= 0 ? ch.index : idx;
        item.title = ch.title || '';
        item.url = ch.url || '';
        item.createTime = now;
        item.updateTime = now;
        return item;
      });
      let newId = 0;
      db.beginTransaction();
      try {
        if (existing) {
          // 已有记录但未入架：标记入架并补全字段
          existing.isShelf = true;
          existing.origin = result.origin || existing.origin;
          existing.originUrl = result.originUrl || existing.originUrl;
          existing.tocUrl = tocUrl || result.noteUrl;
          if (infoCover && !existing.coverUrl) existing.coverUrl = infoCover;
          if (result.coverUrl && !existing.coverUrl) existing.coverUrl = result.coverUrl;
          if (infoKind && !existing.kind) existing.kind = infoKind;
          if (result.kind && !existing.kind) existing.kind = result.kind;
          if (infoWordCount && !existing.wordCount) existing.wordCount = infoWordCount;
          if (result.wordCount && !existing.wordCount) existing.wordCount = result.wordCount;
          if (infoIntroduce && !existing.introduce) existing.introduce = infoIntroduce;
          if (result.introduce && !existing.introduce) existing.introduce = result.introduce;
          existing.chapterCount = toc.length;
          existing.totalChapterNum = toc.length;
          existing.latestChapterTitle = toc[toc.length - 1]?.title || '';
          existing.updateTime = now;
          await bookTable.updateBook(existing);
          newId = existing.id;
          await ct.deleteChaptersByBookId(newId);
        } else {
          const book: Book = {
            id: 0,
            name: result.name || this.bookName,
            author: result.author || this.bookAuthor,
            coverUrl: infoCover || result.coverUrl || '',
            customCoverPath: '',
            bookUrl: result.noteUrl,
            tocUrl: tocUrl || result.noteUrl,
            origin: result.origin || '',
            originUrl: result.originUrl,
            type: isManga ? BookType.MANGA : BookType.TEXT,
            groupId: BookGroup.ALL,
            chapterCount: toc.length,
            totalChapterNum: toc.length,
            latestChapterTitle: toc[toc.length - 1]?.title || '',
            durChapterTitle: '',
            durChapterIndex: 0,
            durChapterPos: 0,
            durChapterProgress: 0,
            isRead: false,
            isAudio: false,
            isManga: isManga,
            isShelf: true,
            order: 0,
            canUpdate: true,
            kind: infoKind || result.kind || '',
            wordCount: infoWordCount || result.wordCount || '',
            introduce: infoIntroduce || result.introduce || '',
            remark: '',
            lastUpdateTime: result.lastUpdateTime || '',
            lastOpenTime: 0,
            createTime: now,
            updateTime: now,
            syncTime: 0,
          };
          newId = await bookTable.insertBook(book);
        }
        if (newId <= 0) throw new Error('写入书架失败');
        for (const row of chapterRows) row.bookId = newId;
        await ct.insertChapters(chapterRows);
        db.commit();
      } catch (txErr) {
        db.rollBack();
        throw new Error('写入书架事务失败: ' + (txErr as Error).message);
      }
      AppStorage.set<number>('shelfRefreshCounter', (AppStorage.get<number>('shelfRefreshCounter') || 0) + 1);
      UiUtil.showToast(this.getUIContext(), { message: '已作为新书加入书架', duration: 1500 });
    } catch (e) {
      console.error('[BookInfo] addSourceAsNewBook failed:', (e as Error).message);
      UiUtil.showToast(this.getUIContext(), { message: '加入书架失败：' + (e as Error).message, duration: 2000 });
    }
  }

  showCoverSheet(): void {
    this.coverDlg = new CustomDialogController({
      builder: ChangeCoverSheet({
        controller: this.coverDlg!,
        bookName: this.bookName,
        bookAuthor: this.bookAuthor,
        onSelect: (cover: string) => { this.updateCover(cover); }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      customStyle: true
    });
    this.coverDlg.open();
  }

  private async updateCover(cover: string): Promise<void> {
    this.customCoverPath = cover;
    if (!this.coverUrl) this.coverUrl = cover;
    UiUtil.showToast(this.getUIContext(), { message: '封面已更新', duration: 1200 });
  }

  showGroupSheet(): void {
    this.groupDlg = new CustomDialogController({
      builder: GroupSelectSheet({
        controller: this.groupDlg!,
        selectedGroupId: this.groupId,
        onConfirm: (gid: number) => {
          this.groupId = gid;
          UiUtil.showToast(this.getUIContext(), { message: '分组已更新', duration: 1500 });
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      customStyle: true
    });
    this.groupDlg.open();
  }

  showReadRecord(): void {
    this.readRecordDlg = new CustomDialogController({
      builder: BookReadRecordSheet({
        controller: this.readRecordDlg!,
        bookName: this.bookName,
      }),
      autoCancel: true,
      alignment: DialogAlignment.Bottom,
      customStyle: true
    });
    this.readRecordDlg.open();
  }

  showRemarkDialog(): void {
    this.remarkDlg = new CustomDialogController({
      builder: RemarkEditDialog({
        controller: this.remarkDlg!,
        remarkText: this.remark,
        onConfirm: (text: string) => {
          this.remark = text;
          UiUtil.showToast(this.getUIContext(), { message: '备注已保存', duration: 1500 });
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      customStyle: true
    });
    this.remarkDlg.open();
  }

  showEditInfoDialog(): void {
    this.editInfoDlg = new CustomDialogController({
      builder: EditBookInfoDialog({
        controller: this.editInfoDlg!,
        editName: this.bookName,
        editAuthor: this.bookAuthor,
        onConfirm: (name: string, author: string) => {
          this.saveBookInfo(name, author);
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      customStyle: true
    });
    this.editInfoDlg.open();
  }

  private async saveBookInfo(name: string, author: string): Promise<void> {
    if (!name.trim()) {
      UiUtil.showToast(this.getUIContext(), { message: '书名不能为空', duration: 1500 });
      return;
    }
    this.bookName = name.trim();
    this.bookAuthor = author.trim();
    // 书架中的书，同步更新数据库
    if (this.isInShelf && this.bookId > 0) {
      try {
        await AppDatabase.getInstance().waitForInit();
        const bookTable = new BookTable(AppDatabase.getInstance().rdbStore);
        const book = await bookTable.getBookById(this.bookId);
        if (book) {
          book.name = this.bookName;
          book.author = this.bookAuthor;
          book.updateTime = Date.now();
          await bookTable.updateBook(book);
          AppStorage.set<number>('shelfRefreshCounter', (AppStorage.get<number>('shelfRefreshCounter') || 0) + 1);
        }
      } catch (e) {
        console.warn('[BookInfo] Failed to save book info:', (e as Error).message);
        UiUtil.showToast(this.getUIContext(), { message: '保存失败', duration: 1500 });
        return;
      }
    }
    UiUtil.showToast(this.getUIContext(), { message: '已保存', duration: 1500 });
  }

  openToc(): void {
    const isManga = this.currentSource_ ? (this.currentSource_.sourceType === 2) : false;
    UiUtil.pushUrl(this.getUIContext(), { url: 'pages/ChapterListPage', params: {
      from: 'BookInfoPage', bookName: this.bookName, bookAuthor: this.bookAuthor,
      bookUrl: this.noteUrl, originUrl: this.originUrl, origin: this.origin,
      tocUrl: this.getCurrentTocUrl(),
      header: this.sourceHeader,
      isManga: isManga ? '1' : '0',
    }});
  }

  /**
   * 确保封面 URL 有效 ——
   * 详情页封面图片: Image(this.getDisplayCover()) 使用的是 customCoverPath || coverUrl
   * 保存到 DB 时也需用相同的优先级
   */
  private getEffectiveCoverUrl(): string {
    return this.customCoverPath || this.coverUrl || '';
  }

  private getCurrentTocUrl(): string {
    if (!this.sourceTocUrl) return '';
    if (this.sourceTocOriginUrl && this.sourceTocOriginUrl !== this.originUrl) {
      console.warn('[BookInfo] Ignore stale tocUrl:',
        'tocOrigin=' + this.sourceTocOriginUrl.substring(0, 80),
        'currentOrigin=' + this.originUrl.substring(0, 80),
        'tocUrl=' + this.sourceTocUrl.substring(0, 80));
      return '';
    }
    return this.sourceTocUrl;
  }

  build() {
    Stack() {
      // 背景层：对齐 Android BookInfoBackdrop，使用封面大图 + 遮罩
      Column() {
        if (this.getEffectiveCoverUrl()) {
          Image(this.getEffectiveCoverUrl())
            .width('100%')
            .height(500)
            .objectFit(ImageFit.Cover)
            .blur(24)
            .opacity(0.72)
        } else {
          Column()
            .width('100%')
            .height(500)
            .backgroundColor(this.getCoverColor())
        }
        Blank()
      }
      .width('100%')
      .height('100%')

      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          direction: GradientDirection.Bottom,
          colors: [
            [ThemeColors.heroGradientStart(this.isDark), 0.0],
            [ThemeColors.heroGradientEnd(this.isDark), 0.56],
            [this.surfaceColor(), 0.74],
            [this.surfaceColor(), 1.0],
          ]
        })

      Column() {
        // 透明顶栏：返回 + 分享 + 更多，滚动顶部保持轻量
        Row() {
          Button() { Text($r('app.string.ui_0dccf90917')).fontSize(30).fontColor(this.primaryTextColor()) }
            .width(44).height(44).backgroundColor(Color.Transparent)
            .accessibilityText($r('app.string.common_back'))
            .onClick((): void => { UiUtil.back(this.getUIContext()); })
          Blank()
          Button() { Text($r('app.string.ui_6564582d82')).fontSize(20).fontColor(this.primaryTextColor()) }
            .width(44).height(44).backgroundColor(Color.Transparent)
            .accessibilityText('分享')
            .onClick(() => {
              UiUtil.showToast(this.getUIContext(), { message: '分享功能待完善', duration: 1200 });
            })
          Button() { Text($r('app.string.ui_b7ed67990b')).fontSize(24).fontColor(this.primaryTextColor()) }
            .width(44).height(44).backgroundColor(Color.Transparent)
            .accessibilityText($r('app.string.ui_77836d3a99')).onClick(() => { this.showMoreMenu = !this.showMoreMenu; })
        }
        .width('100%')
        .height(88)
        .padding({ left: 4, right: 8, top: 36 })
        .zIndex(10)
        .position({ x: 0, y: 0 })

        Scroll() {
          Column() {
            // Header：封面 112x157 + 右侧书名/作者/来源，贴近 Compose 版 BookInfoHeader
            Column() {
              Row() {
                BookCover({
                  name: this.bookName,
                  coverUrl: this.getDisplayCover(),
                  coverWidth: 112,
                  coverHeight: 157,
                  coverDecodeJs: this.coverDecodeJs
                })
                  .borderRadius(8)
                  .shadow({ radius: 16, color: ThemeColors.shadow(this.isDark), offsetX: 0, offsetY: 8 })
                  .onClick(() => { this.showCoverSheet(); })
                  .margin({ right: 16 })

                Column() {
                  Text(this.bookName || '未知书名')
                    .fontSize(23)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(this.primaryTextColor())
                    .maxLines(this.titleExpanded ? 6 : 2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .alignSelf(ItemAlign.Start)
                    .onClick(() => { this.titleExpanded = !this.titleExpanded; })

                  Row() {
                    Text($r('app.string.ui_e8555020c4')).fontSize(11).fontColor(this.secondaryTextColor())
                      .width(18).height(18).textAlign(TextAlign.Center)
                    Text(this.bookAuthor || '未知作者')
                      .fontSize(16)
                      .fontColor(this.secondaryTextColor())
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                      .margin({ left: 4 })
                  }
                  .width('100%')
                  .margin({ top: 8 })

                  Row() {
                    Text($r('app.string.ui_4ad9435ac1')).fontSize(11).fontColor(this.primaryColor())
                      .width(18).height(18).textAlign(TextAlign.Center)
                    Text(this.origin || '未知书源')
                      .fontSize(13)
                      .fontColor(this.primaryColor())
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                      .margin({ left: 4 })
                  }
                  .width('100%')
                  .margin({ top: 6 })
                  .onClick(() => {
                    UiUtil.showToast(this.getUIContext(), { message: this.originUrl || this.origin || '暂无书源信息', duration: 1500 });
                  })
                }
                .layoutWeight(1)
                .height(157)
                .justifyContent(FlexAlign.Center)
              }
              .width('100%')
              .padding({ left: 16, right: 16 })

              if (this.getInfoLabels().length > 0) {
                Scroll() {
                  Row() {
                    ForEach(this.getInfoLabels(), (label: string) => {
                      this.buildLabelChip(label)
                    }, (label: string) => label)
                  }
                  .padding({ left: 16, right: 16 })
                }
                .width('100%')
                .scrollable(ScrollDirection.Horizontal)
              }
            }
            .width('100%')
            .padding({ top: 104, bottom: 12 })
            .linearGradient({
              direction: GradientDirection.Bottom,
              colors: [
                [ThemeColors.transparent(), 0.0],
                [this.surfaceTranslucentColor(), 0.74],
                [this.surfaceColor(), 1.0],
              ]
            })

            Column() {
              this.buildActionRow()
              this.buildSummary()
            }
            .width('100%')
            .backgroundColor(this.surfaceColor())
            .padding({ bottom: 128 })
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
      }
      .width('100%')
      .height('100%')

      // 阅读 FAB：对齐 Android ExtendedFloatingActionButton，固定右下角
      Stack({ alignContent: Alignment.BottomEnd }) {
        Button() {
          Row() {
            Text($r('app.string.ui_fe04274cef')).fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.fabTextColor())
            Text($r('app.string.ui_aac0ef6c1c')).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.fabTextColor())
              .margin({ left: 8 })
          }
        }
        .height(54)
        .padding({ left: 18, right: 22 })
        .borderRadius(27)
        .backgroundColor(this.fabColor())
        .shadow({ radius: 18, color: ThemeColors.shadow(this.isDark), offsetX: 0, offsetY: 8 })
        .margin({ right: 16, bottom: 16 })
        .onClick((): void => { this.startRead(); })
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)

      if (this.showMoreMenu) {
        this.buildOverflowMenu()
      }

      if (this.showExportDialog) {
        Column() {
          Column().width('100%').layoutWeight(1).onClick(() => { this.showExportDialog = false; })
          ExportBookDialog({
            bookId: this.bookId,
            bookName: this.bookName,
            bookAuthor: this.bookAuthor,
            introduce: this.introduce,
            bookCover: this.coverUrl,
            bookUrl: this.noteUrl,
            origin: this.origin,
            originUrl: this.originUrl,
            onDismiss: () => { this.showExportDialog = false; },
          })
        }.width('100%').height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.surfaceColor())
  }

  @Builder buildActionRow() {
    Row() {
      this.buildShelfActionCard()
      this.buildActionCard('☰', '查看目录', () => { this.openToc(); })
      this.buildActionCard('源', '书源', () => { this.changeSource(); })
      this.buildActionCard('时', '阅读记录', () => { this.showReadRecord(); })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .justifyContent(FlexAlign.SpaceBetween)
  }

  @Builder buildShelfActionCard() {
    Column() {
      Text(this.isInShelf ? '书' : '+')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.primaryTextColor())
        .height(24)
        .textAlign(TextAlign.Center)
      Text(this.isInShelf ? '已在书架' : '加入书架')
        .fontSize(12)
        .fontColor(this.primaryTextColor())
        .maxLines(2)
        .textAlign(TextAlign.Center)
        .margin({ top: 5 })
    }
    .height(74)
    .layoutWeight(1)
    .margin({ left: 4, right: 4 })
    .padding({ left: 6, right: 6, top: 12, bottom: 10 })
    .borderRadius(16)
    .backgroundColor(this.containerLowColor())
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      if (this.isInShelf) {
        this.removeFromShelf();
      } else {
        this.addToShelf();
      }
    })
  }

  @Builder buildActionCard(icon: string, label: string, action: () => void) {
    Column() {
      Text(icon)
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.primaryTextColor())
        .height(24)
        .textAlign(TextAlign.Center)
      Text(label)
        .fontSize(12)
        .fontColor(this.primaryTextColor())
        .maxLines(2)
        .textAlign(TextAlign.Center)
        .margin({ top: 5 })
    }
    .height(74)
    .layoutWeight(1)
    .margin({ left: 4, right: 4 })
    .padding({ left: 6, right: 6, top: 12, bottom: 10 })
    .borderRadius(16)
    .backgroundColor(this.containerLowColor())
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(action)
  }

  @Builder buildSummary() {
    Column() {
      Text('目录：' + (this.durChapterTitle ||
        (this.isRefreshing ? (this.tocLoadProgress > 0 ? `加载中(${this.tocLoadProgress}章)` : '加载中') : '未开始阅读'))).fontColor(ThemeColors.onSurface(this.isDark))
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.primaryTextColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .onClick(() => { this.openToc(); })

      Text('最新：' + (this.latestChapter || '无最新章节信息'))
        .fontSize(14)
        .fontColor(this.secondaryTextColor())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 4 })
        .onClick(() => { this.openToc(); })

      Row() {
        Text('共' + this.chapterCount + '章')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.primaryColor())
        Text($r('app.string.ui_3eb416223e'))
          .fontSize(13)
          .fontColor(this.tertiaryTextColor())
          .margin({ left: 8, right: 8 })
        Text(this.getReadIndexText())
          .fontSize(13)
          .fontColor(this.tertiaryTextColor())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.lastReadTime) {
          Text(this.lastReadTime).fontSize(12).fontColor(this.tertiaryTextColor())
        }
      }
      .width('100%')
      .margin({ top: 8 })

      if (this.chapterCount === 0 && !this.isRefreshing) {
        Text($r('app.string.ui_31bfcf117e'))
          .fontSize(12)
          .fontColor(ThemeColors.error(this.isDark))
          .width('100%')
          .margin({ top: 8 })
      }

      if (this.remark) {
        Column() {
          Text(this.remark)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.primaryTextColor())
            .lineHeight(20)
            .width('100%')
        }
        .width('100%')
        .padding(14)
        .borderRadius(14)
        .backgroundColor(this.containerLowColor())
        .margin({ top: 14, bottom: 8 })
        .onClick(() => { this.showRemarkDialog(); })
      }

      Text(this.getIntroText())
        .fontSize(14)
        .fontColor(this.primaryTextColor())
        .lineHeight(22)
        .maxLines(this.introExpanded ? 100 : 8)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 12 })
        .onClick(() => { this.introExpanded = !this.introExpanded; })

      if (this.getIntroText().length > 180) {
        Text(this.introExpanded ? '收起' : '展开')
          .fontSize(13)
          .fontColor(this.primaryColor())
          .margin({ top: 8 })
          .onClick(() => { this.introExpanded = !this.introExpanded; })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder buildLabelChip(label: string) {
    Text(label)
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.primaryTextColor())
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .borderRadius(14)
      .backgroundColor(this.containerColor())
      .margin({ right: 8, top: 10 })
  }

  @Builder buildOverflowMenu() {
    Column() {
      this.buildMenuItem('登录', () => { this.showMoreMenu = false; this.loginDlg?.open(); })
      this.buildMenuItem('刷新', () => { this.showMoreMenu = false; this.tryFetchBookInfo(); })
      this.buildMenuItem('换封面', () => { this.showMoreMenu = false; this.showCoverSheet(); })
      this.buildMenuItem('书籍分组', () => { this.showMoreMenu = false; this.showGroupSheet(); })
      this.buildMenuItem('备注', () => { this.showMoreMenu = false; this.showRemarkDialog(); })
      this.buildMenuItem('编辑', () => { this.showMoreMenu = false; this.showEditInfoDialog(); })
      if (this.isInShelf) {
        this.buildMenuItem('导出', () => { this.showMoreMenu = false; this.showExportDialog = true; })
        this.buildMenuItem('清缓存', () => { this.showMoreMenu = false; this.clearCache(); })
        this.buildMenuItem('移出书架', () => { this.showMoreMenu = false; this.removeFromShelf(); }, true)
      }
    }
    .width(150)
    .padding({ top: 8, bottom: 8 })
    .borderRadius(16)
    .backgroundColor(ThemeColors.surface(this.isDark))
    .shadow({ radius: 20, color: ThemeColors.shadow(this.isDark), offsetX: 0, offsetY: 8 })
    .position({ right: 12, top: 82 })
    .zIndex(30)
  }

  @Builder buildMenuItem(label: string, action: () => void, danger: boolean = false) {
    Text(label)
      .fontSize(14)
      .fontColor(danger ? ThemeColors.error(this.isDark) : this.primaryTextColor())
      .width('100%')
      .padding({ left: 16, right: 16, top: 11, bottom: 11 })
      .onClick(action)
  }

  private getDisplayCover(): string {
    return this.customCoverPath || this.coverUrl || '';
  }

  private getInfoLabels(): string[] {
    const labels: string[] = [];
    if (this.groupId > BookGroup.ALL) {
      labels.push('分组 ' + this.groupId);
    }
    if (this.wordCount) {
      labels.push(this.wordCount);
    }
    if (this.chapterCount > 0) {
      labels.push(this.chapterCount + '章');
    }
    if (this.lastUpdateTime) {
      labels.push(this.lastUpdateTime);
    }
    if (this.kind) {
      const parts = this.kind.split(/[,，\\s]+/).filter((p: string) => p.length > 0);
      for (let i = 0; i < parts.length && i < 8; i++) {
        labels.push(parts[i]);
      }
    }
    return labels;
  }

  private getReadIndexText(): string {
    if (this.chapterCount > 0 && this.durChapterIndex + 1 >= this.chapterCount) {
      return '已读完';
    }
    return '读至第' + (this.durChapterIndex + 1) + '章';
  }

  private getIntroText(): string {
    return this.introduce || '暂无简介';
  }

  private getCoverColor(): string {
    const cs = ThemeColors.coverPlaceholderPalette();
    return this.bookName ? cs[this.bookName.charCodeAt(0) % cs.length] : cs[0];
  }

  private surfaceColor(): string {
    return ThemeColors.surface(this.isDark);
  }

  private surfaceTranslucentColor(): string {
    return ThemeColors.surfaceTranslucent(this.isDark);
  }

  private containerColor(): string {
    return ThemeColors.surface(this.isDark);
  }

  private containerLowColor(): string {
    return ThemeColors.surfaceVariant(this.isDark);
  }

  private primaryTextColor(): string {
    return ThemeColors.onBackground(this.isDark);
  }

  private secondaryTextColor(): string {
    return ThemeColors.secondaryText(this.isDark);
  }

  private tertiaryTextColor(): string {
    return ThemeColors.secondaryText(this.isDark);
  }

  private primaryColor(): string {
    return ThemeColors.primary(this.isDark);
  }

  private fabColor(): string {
    return ThemeColors.primary(this.isDark);
  }

  private fabTextColor(): string {
    return ThemeColors.onSurface(this.isDark);
  }
}
