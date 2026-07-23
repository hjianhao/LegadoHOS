/**
 * 书架页面 — 完整功能版（参照 Android Legado）
 *
 * 功能：
 * - 下拉刷新（列表和网格视图均支持）
 * - 分组标签：全部 / 在读 / 已完本
 * - 搜索过滤（书名 + 作者）
 * - 排序切换：最后阅读 / 书名 / 更新时间
 * - 布局切换：列表 / 网格（3列）
 * - 每个条目：封面、书名、作者、当前章节、最新章节、更新数徽章、进度条
 * - 点击阅读 / 长按菜单(详情/清缓存/删除)
 */
import { Book } from '../model/Book';
import { ThemeColors } from '../theme/ThemeColors';
import { WindowLayout } from '../util/WindowLayout';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookTable } from '../data/database/BookTable';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { ChapterTable } from '../data/database/ChapterTable';
import { BookCover } from '../components/BookCover';
import { GlobalConfig } from '../data/preferences/GlobalConfig';
import { WebDavService } from '../service/WebDavService';
import { BookGroupTable } from '../data/database/BookGroupTable';
import { BookGroup, BookGroupItem, bookMatchesSystemGroup } from '../model/BookGroup';
import { BookSourceChapter } from '../model/BookSource';
import { createDefaultChapter, BookChapter } from '../model/BookChapter';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { BookCacheService, CacheChapterItem } from '../service/BookCacheService';
import { BookSourceResolver } from '../service/BookSourceResolver';
import { BookDeleter } from '../service/BookDeleter';
import { MangaImageLoader } from '../util/MangaImageLoader';
import { BookCoverUtil } from '../util/BookCoverUtil';
import { SettingsStore } from '../data/preferences/SettingsStore';
import { localBookEngine, LocalBookEngine, ImportFileItem, LOCAL_BOOK_ORIGIN } from '../engine/book/LocalBookEngine';
import { localBookTitleFromPath } from '../engine/book/LocalBookFileUtil';
import { EpubEngineType, EpubEngineConfig } from '../engine/EpubEngineConfig';
import { extractZipConcurrent } from '../engine/book/ZipExtractTask';
import picker from '@ohos.file.picker';
import { taskpool } from '@kit.ArkTS';
import fileFs from '@ohos.file.fs';

import { BookshelfConfigDialog } from './BookshelfConfigDialog';
import { BookGroupManageDialog } from './BookGroupManageDialog';
import { AddBookUrlDialog } from './AddBookUrlDialog';
import { BookshelfImportDialog } from './BookshelfImportDialog';
import { BookshelfExportDialog } from './BookshelfExportDialog';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { UiUtil } from '../util/UiUtil';
import { ArrayDataSource } from '../util/ArrayDataSource';
import { AiBookProfileTable } from '../data/database/AiBookProfileTable';
import { extractAiBookMetadata, normalizeAiChapters } from '../engine/ai/AiBookImporter';
import { NetUtil } from '../util/NetUtil';
import { ShareImportPayload } from '../service/ShareImportService';

@Component
export struct BookshelfPage {
  @State books: Book[] = [];
  @State filteredBooks: Book[] = [];
  @State isLoading: boolean = false;
  @State isRefreshing: boolean = false;
  @StorageLink('isDark') isDark: boolean = false;
  @State activeTabIndex: number = 0;
  @State activeGroupId: number = BookGroup.ALL;
  @State groups: BookGroupItem[] = [];
  @State searchText: string = '';
  @State isShelfSearchFocused: boolean = false;
  @StorageLink('gc_groupStyle') groupStyle: number = 0;
  @StorageLink('gc_sortMode') sortMode: number = 0;
  @StorageLink('gc_sortOrder') sortOrder: number = 0;
  @StorageLink('gc_layoutMode') layoutMode: number = 0;
  @StorageLink('gc_gridColumns') gridColumns: number = 3;

  /**
   * 根据窗口宽度自适应计算宫格列数。
   * 用户配置的 gridColumns 作为"密度偏好"，在不同窗口规格下按合理范围 clamp：
   * - COMPACT (<600vp)：2-3 列
   * - MEDIUM (600-839vp)：3-5 列
   * - EXPANDED (840-1199vp)：5-7 列
   * - LARGE (>=1200vp)：7-9 列
   */
  @StorageProp('windowWidthVp') windowWidthVp: number = 360;
  private computeGridColumns_(): number {
    const w = this.windowWidthVp > 0 ? this.windowWidthVp : WindowLayout.widthVp;
    const user = this.gridColumns;
    if (w < 600) return Math.max(2, Math.min(3, user));
    if (w < 840) return Math.max(3, Math.min(5, user));
    if (w < 1200) return Math.max(5, Math.min(7, user));
    return Math.max(7, Math.min(9, user));
  }

  @StorageLink('gc_gridStyle') gridStyle: number = 0;
  @StorageLink('gc_showDivider') showDivider: boolean = true;
  @StorageLink('gc_coverWidth') coverWidth: number = 84;
  @StorageLink('gc_isCompact') isCompact: boolean = false;
  @StorageLink('gc_titleLines') titleMaxLines: number = 2;
  @StorageLink('gc_coverShadow') coverShadow: boolean = false;
  @StorageLink('gc_showUnread') showUnread: boolean = true;
  @StorageLink('gc_showTip') showTip: boolean = true;
  @StorageLink('gc_showLastUpd') showLastUpdateTime: boolean = true;
  @StorageLink('gc_showBookIntro') showBookIntro: boolean = true;
  @StorageLink('gc_showLatest') showLatestChapter: boolean = true;
  @StorageLink('gc_showTag') showTag: boolean = true;
  @StorageLink('gc_introLines') introMaxLines: number = 2;
  @StorageLink('shelfRefreshCounter') @Watch('onShelfRefreshCounterChanged') shelfRefreshCounter: number = 0;
  @StorageLink('pendingShareImport') @Watch('onShareImport') pendingShareImport: ShareImportPayload | null = null;
  private lastShareImportId: number = 0;

  @State showMenu: boolean = false;
  @State isSelectMode: boolean = false;
  @State selectedBookIds: number[] = [];
  @State exportBooks: Book[] = [];
  @State isImporting: boolean = false;
  @State importProgress: string = '';
  private cfgDlg?: CustomDialogController;
  private groupDlg?: CustomDialogController;
  private addUrlDlg?: CustomDialogController;
  private importDlg?: CustomDialogController;
  private exportDlg?: CustomDialogController;
  private sortLabels: string[] = ['最后阅读', '书名', '更新时间', '手动排序'];
  private firstLoadRetryCount: number = 0;
  private isLoadingShelf: boolean = false;
  private bookDataSource_: ArrayDataSource<Book> = new ArrayDataSource<Book>();

  aboutToAppear(): void {
    GlobalConfig.getInstance().syncToAppStorage();
    this.cfgDlg = new CustomDialogController({
      builder: BookshelfConfigDialog({
        controller: this.cfgDlg!,
        onConfigChanged: () => {
          this.applyFilters();
        }
      }),
      autoCancel: true,
      alignment: UiUtil.adaptiveDialogAlignment(),
      customStyle: true
    });
    this.groupDlg = new CustomDialogController({
      builder: BookGroupManageDialog({
        controller: this.groupDlg!,
        onGroupChanged: () => {
          this.loadGroups();
          this.loadBooks();
        }
      }),
      autoCancel: true,
      alignment: UiUtil.adaptiveDialogAlignment(),
      customStyle: true
    });
    this.addUrlDlg = new CustomDialogController({
      builder: AddBookUrlDialog({
        controller: this.addUrlDlg!,
        groupId: this.activeGroupId,
        onSuccess: () => { this.loadBooks(); }
      }),
      autoCancel: true,
      alignment: UiUtil.adaptiveDialogAlignment(),
      customStyle: true
    });
    this.importDlg = new CustomDialogController({
      builder: BookshelfImportDialog({
        controller: this.importDlg!,
        groupId: this.activeGroupId,
        onImportSuccess: () => { this.loadBooks(); }
      }),
      autoCancel: true,
      alignment: UiUtil.adaptiveDialogAlignment(),
      customStyle: true
    });
    this.exportDlg = new CustomDialogController({
      builder: BookshelfExportDialog({
        controller: this.exportDlg!,
        books: this.exportBooks
      }),
      autoCancel: true,
      alignment: UiUtil.adaptiveDialogAlignment(),
      customStyle: true
    });
    this.loadShelfData();
    this.syncProgressFromCloud();
    // 「打开方式/分享」冷启动时 payload 可能已就绪
    this.consumeShareImport(this.pendingShareImport);
  }

  onPageShow(): void {
    this.loadShelfData();
    this.syncProgressFromCloud();
  }

  private syncProgressFromCloud(): void {
    // fire-and-forget；更新成功后刷新书架展示
    this.syncProgressFromCloudAsync_().catch((e: Error) => {
      console.warn('[Bookshelf] Cloud progress sync error:', e.message);
    });
  }

  private async syncProgressFromCloudAsync_(): Promise<void> {
    WebDavService.ensurePersistentProps();
    if (!WebDavService.isProgressSyncEnabled()) {
      console.info('[Bookshelf] Cloud progress sync disabled');
      return;
    }
    if (!WebDavService.getInstance().isConfigured()) {
      console.info('[Bookshelf] Cloud progress sync skipped: WebDAV not configured');
      return;
    }
    // 确保启动时的 initFromStorage 已完成（冷启动竞态）
    try {
      const ctx = UiUtil.getHostContext(this.getUIContext());
      if (ctx) {
        await WebDavService.getInstance().initFromStorage(ctx);
      }
    } catch (_e) { /* ignore */ }
    const updated = await WebDavService.getInstance().downloadAllBookProgress();
    console.info('[Bookshelf] Cloud progress sync done, updated=', updated);
    if (updated > 0) {
      await this.loadShelfData();
    }
  }

  onShelfRefreshCounterChanged(): void {
    this.loadShelfData();
  }

  private async ensureDatabaseReady(): Promise<boolean> {
    try {
      await AppDatabase.getInstance().waitForInit();
      return true;
    } catch (_e) {
      try {
        await AppDatabase.getInstance().init(UiUtil.getHostContext(this.getUIContext()));
        return true;
      } catch (err) {
        console.error('[Bookshelf] database not ready:', err);
        return false;
      }
    }
  }

  private async loadShelfData(): Promise<void> {
    if (this.isLoadingShelf) return;
    this.isLoadingShelf = true;
    try {
      const ready = await this.ensureDatabaseReady();
      if (!ready) {
        this.scheduleFirstLoadRetry();
        return;
      }
      await this.loadGroups();
      await this.loadBooks();
      this.firstLoadRetryCount = 0;
    } finally {
      this.isLoadingShelf = false;
    }
  }

  private scheduleFirstLoadRetry(): void {
    if (this.firstLoadRetryCount >= 3) return;
    this.firstLoadRetryCount++;
    setTimeout(() => {
      this.loadShelfData();
    }, 300);
  }

  async loadBooks(): Promise<void> {
    if (!this.isRefreshing) this.isLoading = true;
    try {
      const ready = await this.ensureDatabaseReady();
      if (!ready) {
        this.scheduleFirstLoadRetry();
        return;
      }
      const db = AppDatabase.getInstance().rdbStore;
      const bookDao = new BookTable(db);
      const result = await bookDao.getAllShelfBooks();
      const repairs: Promise<void>[] = [];
      for (const book of result) {
        if (book.origin !== LOCAL_BOOK_ORIGIN || book.kind !== 'PDF') continue;
        const fileTitle = localBookTitleFromPath(book.originUrl);
        if (!fileTitle || fileTitle === book.name) continue;
        // PDF 内嵌 Title 经常是下载站域名或制作工具名称。本地 PDF 始终以
        // 用户导入时的文件名为书名，并顺带修复旧版本已被覆盖的数据库记录。
        book.name = fileTitle;
        repairs.push(bookDao.updateBook(book));
      }
      if (repairs.length > 0) await Promise.all(repairs);
      this.books = result;
      this.applyFilters();
    } catch (e) {
      console.error('[Bookshelf] load error:', e);
    }
    this.isLoading = false;
    this.isRefreshing = false;
  }

  async loadGroups(): Promise<void> {
    try {
      const ready = await this.ensureDatabaseReady();
      if (!ready) {
        this.scheduleFirstLoadRetry();
        return;
      }
      const groupDao = new BookGroupTable(AppDatabase.getInstance().rdbStore);
      const shown = await groupDao.getShownGroups();
      this.groups = shown.length > 0 ? shown : [{
        id: BookGroup.ALL, name: '全部', order: 0, cover: '', isSystem: true,
        enableRefresh: true, show: true, isPrivate: false, bookSort: -1
      }];
      if (!this.groups.some((g: BookGroupItem): boolean => g.id === this.activeGroupId)) {
        this.activeGroupId = this.groups[0].id;
        this.activeTabIndex = 0;
      }
      this.applyFilters();
    } catch (_e) {
      this.groups = [{
        id: BookGroup.ALL, name: '全部', order: 0, cover: '', isSystem: true,
        enableRefresh: true, show: true, isPrivate: false, bookSort: -1
      }];
    }
  }

  /**
   * 下拉刷新对齐安卓：对当前可见网络书重新拉取目录（获取最新章节）。
   * 本地书 / canUpdate=false（如完本关闭更新）会跳过。
   */
  async onRefresh(): Promise<void> {
    if (this.isLoadingShelf || this.isRefreshing) {
      this.isRefreshing = false;
      return;
    }
    // 先刷新本地展示，再联网更新目录
    await this.loadShelfData();
    await this.updateTocForVisible();
  }

  /**
   * 添加本地书籍 - 打开文件选择器
   */
  private async addLocalBooks(): Promise<void> {
    try {
      const docPicker = new picker.DocumentViewPicker();
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 20;
      options.fileSuffixFilters = ['.txt', '.epub', '.mobi', '.azw', '.azw3', '.pdf'];
      const uris = await docPicker.select(options);
      if (!uris || uris.length === 0) return;
      await this.importLocalBookUris(uris);
    } catch (e) {
      this.isImporting = false;
      this.importProgress = '';
      // 用户取消选择会抛异常，不提示
      if (e && (e as Error).message?.includes('cancel')) return;
      console.error('[Bookshelf] addLocalBooks error:', e);
      UiUtil.showToast(this.getUIContext(), { message: '导入失败', duration: 1500 });
    }
  }

  /**
   * 本地书籍导入流程：「文件选择器」与「打开方式/分享」共用
   */
  private async importLocalBookUris(uris: string[]): Promise<void> {
    this.isImporting = true;
    this.importProgress = `正在导入 0/${uris.length}...`;

    // 获取沙箱 context
    const context = this.getUIContext().getHostContext() as Context;

    // 构造导入项列表（uri + fileName），从 URI 提取文件名
    const items: ImportFileItem[] = [];
    for (let i = 0; i < uris.length; i++) {
      const uri = uris[i];
      const name = decodeURIComponent(uri.split('/').pop() || `book_${i + 1}`);
      items.push({ uri, fileName: name });
    }

    // 先复制到沙箱，EPUB 再用 TaskPool 解压（避免 EAWorker + WebView 冲突）
    const sandboxItems: ImportFileItem[] = [];
    for (const item of items) {
      const sandboxPath = await localBookEngine.copyToSandbox(item.uri, item.fileName, context);
      let epubDir = '';
      if (/\.epub$/i.test(item.fileName)) {
        epubDir = LocalBookEngine.getEpubDir(context);
        this.importProgress = `正在解压 ${item.fileName}...`;
        await taskpool.execute(extractZipConcurrent, sandboxPath, epubDir);
      }
      sandboxItems.push({ uri: sandboxPath, fileName: item.fileName, epubDir });
    }

    const result = await localBookEngine.importBooks(sandboxItems, context, (current, total, name) => {
      this.importProgress = `正在导入 ${current}/${total}: ${name}`;
    });

    this.isImporting = false;
    this.importProgress = '';

    if (result.success > 0) {
      UiUtil.showToast(this.getUIContext(), {
        message: `导入完成: 成功 ${result.success} 本${result.failed > 0 ? `，失败 ${result.failed} 本` : ''}`,
        duration: 2000
      });
      await this.loadBooks();
    } else if (result.failed > 0) {
      let firstError = '未知错误';
      for (const detail of result.details) {
        if (!detail.success && detail.error) {
          firstError = detail.error;
          break;
        }
      }
      UiUtil.showToast(this.getUIContext(), {
        message: `导入失败: ${firstError}`,
        duration: 2000
      });
    }
  }

  private onShareImport(): void {
    this.consumeShareImport(this.pendingShareImport);
  }

  /** 「打开方式/分享」收到的电子书文件：执行本地书导入 */
  private consumeShareImport(p: ShareImportPayload | null): void {
    if (!p || p.id === this.lastShareImportId || p.kind !== 'book') return;
    this.lastShareImportId = p.id;
    console.info('[Bookshelf] share import books: ' + p.fileName);
    this.importLocalBookUris(p.uris).catch((e: Error) => {
      this.isImporting = false;
      this.importProgress = '';
      console.error('[Bookshelf] importSharedBooks error:', e);
      UiUtil.showToast(this.getUIContext(), { message: '导入失败', duration: 1500 });
    });
  }

  applyFilters(): void {
    let result = [...this.books];
    if (this.activeGroupId < BookGroup.CUSTOM) {
      result = result.filter((b: Book): boolean => bookMatchesSystemGroup(b, this.activeGroupId));
    } else {
      result = result.filter((b: Book): boolean => b.groupId === this.activeGroupId);
    }
    if (this.searchText.trim()) {
      const q = this.searchText.trim().toLowerCase();
      result = result.filter(b =>
        b.name.toLowerCase().includes(q) ||
        (b.author && b.author.toLowerCase().includes(q))
      );
    }
    result.sort((a, b) => {
      let cmp = 0;
      switch (this.sortMode) { case 0: cmp = (b.lastOpenTime||0)-(a.lastOpenTime||0); break; case 1: cmp = (a.name||'').localeCompare(b.name||''); break; case 2: cmp = (b.lastUpdateTime||'').localeCompare(a.lastUpdateTime||''); break; case 3: cmp = (a.id||0)-(b.id||0); break; }
      return this.sortOrder === 1 ? -cmp : cmp;
    });
    this.filteredBooks = result;
    this.bookDataSource_.reset(result);
  }

  onTabChange(index: number): void {
    this.activeTabIndex = index;
    if (this.groups[index]) this.activeGroupId = this.groups[index].id;
    this.applyFilters();
  }

  private onBookLongPress(book: Book): void {
    if (this.isSelectMode) {
      this.toggleBookSelection(book.id);
    } else {
      this.showContextMenu(book);
    }
  }

  onSearchChange(value: string): void {
    this.searchText = value;
    this.applyFilters();
  }

  onSortToggle(): void {
    this.sortMode = (this.sortMode + 1) % 4;
    this.saveConfig();
    this.applyFilters();
  }

  onLayoutToggle(): void {
    this.layoutMode = this.layoutMode === 0 ? 1 : 0;
    this.saveConfig();
  }

  private currentTargetBooks(): Book[] {
    if (this.selectedBookIds.length > 0) {
      return this.books.filter((book: Book): boolean => this.selectedBookIds.includes(book.id));
    }
    return this.filteredBooks;
  }

  private toggleSelectMode(): void {
    this.isSelectMode = !this.isSelectMode;
    if (!this.isSelectMode) this.selectedBookIds = [];
  }

  private isSelected(id: number): boolean {
    return this.selectedBookIds.includes(id);
  }

  private toggleBookSelection(id: number): void {
    if (this.isSelected(id)) {
      this.selectedBookIds = this.selectedBookIds.filter((item: number): boolean => item !== id);
    } else {
      this.selectedBookIds = [...this.selectedBookIds, id];
    }
  }

  private selectAllVisible(): void {
    if (this.selectedBookIds.length === this.filteredBooks.length) {
      this.selectedBookIds = [];
    } else {
      this.selectedBookIds = this.filteredBooks.map((book: Book): number => book.id);
    }
  }

  private openExportDialog(books: Book[]): void {
    this.exportBooks = books;
    this.exportDlg?.open();
  }

  private async removeSelectedFromShelf(): Promise<void> {
    if (this.selectedBookIds.length === 0) return;
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const bookDao = new BookTable(db);
      const count = this.selectedBookIds.length;
      // 查出完整 Book 对象（BookDeleter 需要 originUrl/tocUrl/customCoverPath 清理文件）
      const books: Book[] = [];
      for (const id of this.selectedBookIds) {
        const book = await bookDao.getBookById(id);
        if (book) books.push(book);
      }
      await BookDeleter.deleteBooks(books);
      this.selectedBookIds = [];
      this.isSelectMode = false;
      UiUtil.showToast(this.getUIContext(), { message: '已删除 ' + count + ' 本', duration: 1500 });
      this.loadBooks();
    } catch (e) {
      console.error('[Bookshelf] batch remove error:', e);
      UiUtil.showToast(this.getUIContext(), { message: '删除失败', duration: 1500 });
    }
  }

  private async updateTocForVisible(): Promise<void> {
    // 对齐安卓：!isLocal && canUpdate
    const targets = this.currentTargetBooks().filter((book: Book): boolean => {
      if (!book.bookUrl) return false;
      if (book.origin === LOCAL_BOOK_ORIGIN) return false;
      if (!book.canUpdate) return false;
      // 网络书至少要有书源标识
      return !!(book.originUrl || book.origin);
    });
    if (targets.length === 0) {
      UiUtil.showToast(this.getUIContext(), { message: '没有可更新目录的书籍（本地书/已关闭更新已跳过）', duration: 1800 });
      this.isRefreshing = false;
      return;
    }
    this.isRefreshing = true;
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const bookDao = new BookTable(db);
      const chapterDao = new ChapterTable(db);
      const aiProfileDao = new AiBookProfileTable(db);
      // 对齐安卓：目录刷新后自动缓存 当前章..+N 章（auto_cache_size，0 关闭）
      const settings = SettingsStore.getInstance();
      await settings.init(UiUtil.getHostContext(this.getUIContext()));
      const autoCacheNum = await settings.getAutoCacheSize();
      let success = 0;
      let failed = 0;
      for (const book of targets) {
        try {
          const source = await BookSourceResolver.resolve(book);
          if (!source) throw new Error('解析规则不可用');
          const aiProfile = await aiProfileDao.getByBookId(book.id);
          const rawChapters = await globalSourceExecutor.getToc(source, book.tocUrl || book.bookUrl);
          const chapters = aiProfile ? normalizeAiChapters(rawChapters) : rawChapters;
          if (chapters.length === 0) throw new Error('目录为空');

          // 增量合并目录，按 URL 保留已读状态和正文缓存。
          await chapterDao.replaceTocPreserveContent(book.id, chapters);
          book.chapterCount = chapters.length;
          book.totalChapterNum = chapters.length;
          book.latestChapterTitle = chapters[chapters.length - 1].title || '';

          if (aiProfile) {
            try {
              const info = await globalSourceExecutor.getBookInfo(source, book.bookUrl);
              if (info.name) book.name = info.name;
              if (info.author) book.author = info.author;
              if (info.coverUrl) book.coverUrl = info.coverUrl;
              if (info.introduce) book.introduce = info.introduce;
              if (info.wordCount) book.wordCount = info.wordCount;
              if (info.kind) book.kind = info.kind;
              if (info.lastUpdateTime) book.lastUpdateTime = info.lastUpdateTime;
              const html = await NetUtil.httpGet(book.bookUrl, undefined, 25000);
              const metadata = extractAiBookMetadata(html, book.bookUrl);
              if (metadata.name) book.name = metadata.name;
              if (metadata.author) book.author = metadata.author;
              if (metadata.coverUrl) book.coverUrl = metadata.coverUrl;
              if (metadata.introduce) book.introduce = metadata.introduce;
              if (metadata.wordCount) book.wordCount = metadata.wordCount;
              if (metadata.kind) book.kind = metadata.kind;
              if (metadata.lastUpdateTime) book.lastUpdateTime = metadata.lastUpdateTime;
            } catch (_metadataError) { /* 目录刷新不因元数据失败而回滚 */ }
            await aiProfileDao.markRefresh(book.id, true);
          }
          await bookDao.updateBook(book);
          success++;

          // 自动缓存 当前章..+N 章（BookCacheService 会跳过已缓存章节）
          if (autoCacheNum > 0) {
            const items: CacheChapterItem[] = chapters.map((ch: BookSourceChapter, idx: number): CacheChapterItem => {
              return { index: ch.index >= 0 ? ch.index : idx, title: ch.title || '', url: ch.url || '' };
            });
            const startIdx = Math.max(0, Math.min(book.durChapterIndex, items.length - 1));
            const endIdx = Math.min(startIdx + autoCacheNum, items.length - 1);
            BookCacheService.getInstance().cacheBook({
              bookId: book.id, bookName: book.name, bookUrl: book.bookUrl, source: source,
              chapters: items, startIndex: startIdx, endIndex: endIdx,
              context: UiUtil.getHostContext(this.getUIContext()),
            }).catch((e: Error) => {
              console.warn('[Bookshelf] auto cache fail: ' + book.name + ' - ' + e.message);
            });
          }
        } catch (_bookError) {
          failed++;
          if (await aiProfileDao.getByBookId(book.id)) await aiProfileDao.markRefresh(book.id, false);
        }
      }
      UiUtil.showToast(this.getUIContext(), { message: '目录更新完成：成功 ' + success + '，失败 ' + failed, duration: 2000 });
      this.loadBooks();
    } catch (_e) {
      UiUtil.showToast(this.getUIContext(), { message: '更新目录失败', duration: 1500 });
    }
    this.isRefreshing = false;
  }

  private toBookChapters(bookId: number, chapters: BookSourceChapter[]): BookChapter[] {
    const now = Date.now();
    return chapters.map((ch: BookSourceChapter, index: number): BookChapter => {
      const item = createDefaultChapter();
      item.bookId = bookId;
      item.index = ch.index >= 0 ? ch.index : index;
      item.title = ch.title || '';
      item.url = ch.url || '';
      item.createTime = now;
      item.updateTime = now;
      return item;
    });
  }

  private saveConfig(): void {
    const cfg = GlobalConfig.getInstance();
    cfg.groupStyle = this.groupStyle;
    cfg.sortMode = this.sortMode;
    cfg.sortOrder = this.sortOrder;
    cfg.layoutMode = this.layoutMode;
    cfg.gridColumns = this.gridColumns;
    cfg.gridStyle = this.gridStyle;
    cfg.showDivider = this.showDivider;
    cfg.coverWidth = this.coverWidth;
    cfg.isCompact = this.isCompact;
    cfg.titleMaxLines = this.titleMaxLines;
    cfg.coverShadow = this.coverShadow;
    cfg.showUnread = this.showUnread;
    cfg.showTip = this.showTip;
    cfg.showLastUpdateTime = this.showLastUpdateTime;
    cfg.showBookIntro = this.showBookIntro;
    cfg.showLatestChapter = this.showLatestChapter;
    cfg.showTag = this.showTag;
    cfg.introMaxLines = this.introMaxLines;
    cfg.syncToAppStorage();
    cfg.save();
  }

  private getIntroMaxLines(): number {
    return this.introMaxLines === 0 ? 99 : this.introMaxLines;
  }

  getNewChaptersCount(book: Book): number {
    const count = (book.totalChapterNum || 0) - (book.durChapterIndex || 0);
    return count > 0 ? count : 0;
  }

  async continueRead(book: Book): Promise<void> {
    // PDF 使用 foliate + PDF.js 原版阅读链路。
    if (book.origin === LOCAL_BOOK_ORIGIN && book.kind === 'PDF') {
      UiUtil.pushUrl(this.getUIContext(), {
        url: 'pages/ReaderPage',
        params: { bookName: book.name, bookUrl: book.bookUrl }
      });
      return;
    }
    // MOBI/AZW/AZW3 本地书统一使用 foliate-js 图文引擎。
    if (book.origin === LOCAL_BOOK_ORIGIN &&
      (book.kind === 'MOBI' || book.kind === 'AZW' || book.kind === 'AZW3')) {
      UiUtil.pushUrl(this.getUIContext(), {
        url: 'pages/ReaderPage',
        params: { bookName: book.name, bookUrl: book.bookUrl }
      });
      return;
    }
    // EPUB 本地书：根据引擎选择阅读方式
    if (book.origin === LOCAL_BOOK_ORIGIN && book.kind === 'EPUB') {
      try {
        const engine = await EpubEngineConfig.getEngine();
        if (engine !== EpubEngineType.NOVEL) {
          UiUtil.pushUrl(this.getUIContext(), {
            url: 'pages/ReaderPage',
            params: {
              bookName: book.name,
              bookUrl: book.bookUrl,
              epubEngine: engine === EpubEngineType.FOLIATE ? 'foliate' : 'epub_js',
            }
          });
          return;
        }
      } catch (_e) { /* 默认小说引擎 */ }
    }
    // 小说阅读引擎（默认）
    const targetPage = book.isManga ? 'pages/ComicReadPage' : 'pages/ReadPage';
    UiUtil.pushUrl(this.getUIContext(), {
      url: targetPage,
      params: { bookUrl: book.bookUrl }
    });
  }

  async removeFromShelf(book: Book): Promise<void> {
    try {
      await BookDeleter.deleteBook(book);
      UiUtil.showToast(this.getUIContext(), { message: '已删除《' + book.name + '》', duration: 1500 });
      this.loadBooks();
    } catch (e) {
      console.error('[Bookshelf] remove error:', e);
      UiUtil.showToast(this.getUIContext(), { message: '删除失败', duration: 1500 });
    }
  }

  private confirmClearBookCache(book: Book): void {
    UiUtil.showDialog(this.getUIContext(), {
      title: '清除缓存',
      message: `清除《${book.name}》已缓存的章节内容？目录和阅读进度会保留。`,
      buttons: [
        { text: '取消', color: ThemeColors.secondaryText(this.isDark) },
        { text: '清除', color: ThemeColors.warning(this.isDark) }
      ]
    }).then((result) => {
      if (result.index === 1) this.clearBookCache(book);
    });
  }

  private async clearBookCache(book: Book): Promise<void> {
    try {
      await AppDatabase.getInstance().waitForInit();
      const chapterDao = new ChapterTable(AppDatabase.getInstance().rdbStore);
      await chapterDao.clearContentByBookId(book.id);
      // 连带清理漫画图片缓存和封面缓存（保留目录和进度）
      await MangaImageLoader.clearCacheForBook(book.id);
      await BookCoverUtil.clearCacheForBook(book.id);
      UiUtil.showToast(this.getUIContext(), { message: '已清除《' + book.name + '》缓存', duration: 1500 });
    } catch (_e) {
      UiUtil.showToast(this.getUIContext(), { message: '清除缓存失败', duration: 1500 });
    }
  }

  showContextMenu(book: Book): void {
    const isLocal = book.origin === LOCAL_BOOK_ORIGIN;
    const updateLabel = book.canUpdate ? '关闭更新（完本）' : '开启更新';
    const statusText = isLocal ? '' : ('\n目录更新: ' + (book.canUpdate ? '开启' : '已关闭'));
    if (isLocal) {
      UiUtil.showDialog(this.getUIContext(), {
        title: book.name,
        message: '作者: ' + (book.author || '未知'),
        buttons: [
          { text: '详情', color: ThemeColors.primary(this.isDark) },
          { text: '清除缓存', color: ThemeColors.warning(this.isDark) },
          { text: '删除', color: ThemeColors.error(this.isDark) },
          { text: '取消', color: ThemeColors.secondaryText(this.isDark) }
        ]
      }).then((res: Object) => {
        const idx = (res as Record<string, Object>)['index'] as number;
        if (idx === 0) {
          UiUtil.pushUrl(this.getUIContext(), { url: 'pages/BookInfoPage', params: {
            name: book.name, author: book.author, coverUrl: book.coverUrl,
            noteUrl: book.bookUrl, origin: book.origin, originUrl: book.originUrl,
            introduce: book.introduce || '', kind: book.kind || ''
          }});
        } else if (idx === 1) {
          this.confirmClearBookCache(book);
        } else if (idx === 2) {
          this.confirmRemove(book);
        }
      });
      return;
    }

    UiUtil.showDialog(this.getUIContext(), {
      title: book.name,
      message: '作者: ' + (book.author || '未知') + statusText,
      buttons: [
        { text: '详情', color: ThemeColors.primary(this.isDark) },
        { text: updateLabel, color: ThemeColors.primary(this.isDark) },
        { text: '清除缓存', color: ThemeColors.warning(this.isDark) },
        { text: '删除', color: ThemeColors.error(this.isDark) },
        { text: '取消', color: ThemeColors.secondaryText(this.isDark) }
      ]
    }).then(async (res: Object) => {
      const idx = (res as Record<string, Object>)['index'] as number;
      if (idx === 0) {
        UiUtil.pushUrl(this.getUIContext(), { url: 'pages/BookInfoPage', params: {
          name: book.name, author: book.author, coverUrl: book.coverUrl,
          noteUrl: book.bookUrl, origin: book.origin, originUrl: book.originUrl,
          introduce: book.introduce || '', kind: book.kind || ''
        }});
      } else if (idx === 1) {
        await this.toggleBookCanUpdate_(book);
      } else if (idx === 2) {
        this.confirmClearBookCache(book);
      } else if (idx === 3) {
        this.confirmRemove(book);
      }
    });
  }

  /** 切换是否允许更新目录（对齐安卓 allow_update / canUpdate） */
  private async toggleBookCanUpdate_(book: Book): Promise<void> {
    try {
      await AppDatabase.getInstance().waitForInit();
      const dao = new BookTable(AppDatabase.getInstance().rdbStore);
      const latest = await dao.getBookById(book.id);
      const target = latest ? latest : await dao.getBookByUrl(book.bookUrl);
      if (!target) {
        UiUtil.showToast(this.getUIContext(), { message: '书籍不存在', duration: 1200 });
        return;
      }
      target.canUpdate = !target.canUpdate;
      await dao.updateBook(target);
      UiUtil.showToast(this.getUIContext(), {
        message: target.canUpdate ? '已开启更新' : '已关闭更新（下拉刷新将跳过）',
        duration: 1500
      });
      await this.loadBooks();
    } catch (e) {
      console.error('[Bookshelf] toggle canUpdate failed:', e);
      UiUtil.showToast(this.getUIContext(), { message: '设置失败', duration: 1200 });
    }
  }

  confirmRemove(book: Book): void {
    UiUtil.showDialog(this.getUIContext(), {
      title: '删除书籍',
      message: `确定删除《${book.name}》及其全部数据吗？\n（章节内容、本地文件将一并清除）`,
      buttons: [
        { text: '取消', color: ThemeColors.secondaryText(this.isDark) },
        { text: '移除', color: ThemeColors.error(this.isDark) }
      ]
    }).then((result) => {
      if (result.index === 1) this.removeFromShelf(book);
    });
  }

  getProgressPercent(book: Book): number {
    if (book.totalChapterNum <= 0) return 0;
    return Math.min(100, Math.round((book.durChapterIndex / book.totalChapterNum) * 100));
  }

  formatTime(ts: number): string {
    if (!ts) return '';
    const d = new Date(ts);
    const now = new Date();
    const diffDay = Math.floor((now.getTime() - d.getTime()) / 86400000);
    if (diffDay === 0) return '今天';
    if (diffDay === 1) return '昨天';
    if (diffDay < 7) return diffDay + '天前';
    return `${d.getMonth() + 1}/${d.getDate()}`;
  }

  build() { Stack() {
    Column().width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark)) {
      // 顶部栏
      Row() {
        Text($r('app.string.ui_f7d77d7da3')).fontSize(20).fontWeight(FontWeight.Bold).fontColor(ThemeColors.onBackground(this.isDark))
        Blank()
        if (this.filteredBooks.length > 0) {
          Text(this.filteredBooks.length + '本').fontSize(13).fontColor(ThemeColors.onBackground(this.isDark)).margin({ right: 8 })
        }
        // 云端书库入口
        Button() {
          Text('☁').fontSize(20).fontColor(ThemeColors.onBackground(this.isDark))
        }
        .width(40).height(40)
        .backgroundColor(ThemeColors.transparent())
        .accessibilityText('云端书库')
        .margin({ right: 2 })
        .onClick(() => {
          UiUtil.pushUrl(this.getUIContext(), { url: 'pages/CloudBookPage' });
        })
        Button($r('app.string.ui_32ffb8c287')).fontSize(14).fontColor(ThemeColors.onPrimary(this.isDark))
          .height(40).padding({ left: 10, right: 10 })
        .backgroundColor(ThemeColors.primary(this.isDark)).borderRadius(16).margin({ right: 6 })
        .onClick(() => { UiUtil.pushUrl(this.getUIContext(), { url: 'pages/SearchPage' }); })
        Button() {
          Text((this.layoutMode === 0) ? '▦' : '☰').fontSize(16).fontColor(ThemeColors.onBackground(this.isDark))
        }.width(40).height(40).backgroundColor(ThemeColors.transparent())
        .accessibilityText(this.layoutMode === 0 ? '切换到列表布局' : '切换到网格布局')
        .onClick(() => { this.onLayoutToggle(); })
        Button() {
          Text(this.sortLabels[this.sortMode]).fontSize(12).fontColor(ThemeColors.onBackground(this.isDark))
        }.height(40).padding({ left: 8, right: 8 })
        .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).borderRadius(14).margin({ left: 4 })
        .onClick(() => { this.onSortToggle(); })
        Button() { Text($r('app.string.ui_b7ed67990b')).fontSize(22).fontColor(ThemeColors.onBackground(this.isDark)) }.width(40).height(40).backgroundColor(ThemeColors.transparent()).accessibilityText($r('app.string.ui_77836d3a99')).onClick(() => { this.showMenu = !this.showMenu; })
      }.padding({ left: 16, right: 12, top: 12 }).width('100%')

      // 书架过滤栏。不要使用 CSS calc() 宽度，ArkUI 真机会将其压缩为接近 0 宽。
      Row() {
        Row({ space: 6 }) {
          Text($r('app.string.ui_1b0a1f59a5'))
            .width(26)
            .fontSize(18)
            .textAlign(TextAlign.Center)
            .fontColor(ThemeColors.secondaryText(this.isDark))

          TextInput({ placeholder: '过滤书名、作者或简介', text: this.searchText })
            .layoutWeight(1)
            .height(42)
            .padding(0)
            .fontSize(15)
            .fontColor(ThemeColors.onSurface(this.isDark))
            .placeholderColor(ThemeColors.secondaryText(this.isDark))
            .caretColor(ThemeColors.primary(this.isDark))
            .backgroundColor(ThemeColors.transparent())
            .onFocus((): void => { this.isShelfSearchFocused = true; })
            .onBlur((): void => { this.isShelfSearchFocused = false; })
            .onChange((value: string): void => { this.onSearchChange(value); })

          if (this.searchText.length > 0) {
            Button() {
              Text('×')
                .fontSize(19)
                .fontColor(ThemeColors.secondaryText(this.isDark))
            }
            .width(44)
            .height(44)
            .padding(0)
            .backgroundColor(ThemeColors.transparent())
            .borderRadius(22)
            .accessibilityText('清除过滤文字')
            .onClick((): void => { this.onSearchChange(''); })
          }
        }
        .layoutWeight(1)
        .height(46)
        .padding({ left: 10, right: 5 })
        .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
        .borderRadius(23)
        .border({
          width: this.isShelfSearchFocused ? 2 : 1,
          color: this.isShelfSearchFocused ?
            ThemeColors.primary(this.isDark) : ThemeColors.outlineVariant(this.isDark)
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8 })

      // 分类标签 (groupStyle: 0=show, 1=hide)
      if (this.groupStyle === 0) {
        Scroll() {
          Row() {
            ForEach(this.groups, (group: BookGroupItem, index: number) => {
              Column() {
                Text(group.name).fontSize(14)
                  .fontColor(this.activeTabIndex === index ? ThemeColors.primary(this.isDark) : ThemeColors.secondaryText(this.isDark))
                  .fontWeight(this.activeTabIndex === index ? FontWeight.Bold : FontWeight.Normal)
                  .padding({ top: 8, bottom: 8 })
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                if (this.activeTabIndex === index) {
                  Row().width('60%').height(2).backgroundColor(ThemeColors.primary(this.isDark)).borderRadius(1)
                }
              }
              .width(88).alignItems(HorizontalAlign.Center)
              .onClick(() => { this.onTabChange(index); })
            })
          }.padding({ left: 16, right: 16, top: 4 })
        }
        .width('100%')
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
      }

      if (this.isSelectMode) {
        Row() {
          Text('已选 ' + this.selectedBookIds.length + ' / ' + this.filteredBooks.length)
            .fontSize(13).fontColor(ThemeColors.onBackground(this.isDark)).layoutWeight(1)
          Button($r('app.string.common_select_all')).fontSize(13).fontColor(ThemeColors.primary(this.isDark))
            .height(40).backgroundColor(Color.Transparent).padding({ left: 8, right: 8 })
            .onClick(() => { this.selectAllVisible(); })
          Button($r('app.string.common_export')).fontSize(13).fontColor(ThemeColors.primary(this.isDark))
            .height(40).backgroundColor(Color.Transparent).padding({ left: 8, right: 8 })
            .onClick(() => { this.openExportDialog(this.currentTargetBooks()); })
          Button($r('app.string.ui_2f752c005e')).fontSize(13).fontColor(ThemeColors.error(this.isDark))
            .height(40).backgroundColor(Color.Transparent).padding({ left: 8, right: 8 })
            .onClick(() => { this.removeSelectedFromShelf(); })
        }.width('100%').height(40).padding({ left: 16, right: 12 })
        .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
      }

      // 内容
      if (this.isLoading && !this.isRefreshing) {
        Column() {
          LoadingProgress().color(ThemeColors.primary(this.isDark))
        }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      } else {
        Refresh({ refreshing: $$this.isRefreshing }) {
          if (this.filteredBooks.length === 0) {
            Scroll() {
              Column() {
                Text($r('app.string.ui_a2cd7e5079')).fontSize(18).margin({ top: 100 }).fontColor(ThemeColors.secondaryText(this.isDark))
                if (this.searchText) {
                  Text($r('app.string.ui_9065e08914')).fontSize(16).fontColor(ThemeColors.onBackground(this.isDark)).margin({ top: 12 })
                  Text($r('app.string.ui_228b298850')).fontSize(13).fontColor(ThemeColors.onBackground(this.isDark)).margin({ top: 4 })
                } else if (this.activeTabIndex > 0) {
                  Text($r('app.string.ui_a14ef60f5d')).fontSize(16).fontColor(ThemeColors.onBackground(this.isDark)).margin({ top: 12 })
                  Text($r('app.string.ui_81e9ebaa90')).fontSize(13).fontColor(ThemeColors.onBackground(this.isDark)).margin({ top: 4 })
                } else {
                  Text($r('app.string.ui_6543d688f9')).fontSize(16).fontColor(ThemeColors.onBackground(this.isDark)).margin({ top: 12 })
                  Text($r('app.string.ui_81e9ebaa90')).fontSize(13).fontColor(ThemeColors.onBackground(this.isDark)).margin({ top: 4 })
                }
              }.width('100%').height('100%').alignItems(HorizontalAlign.Center)
            }.width('100%').height('100%')
          } else if (this.layoutMode === 0) {
            List() {
              LazyForEach(this.bookDataSource_, (book: Book) => {
                ListItem() {
                  this.buildListItem(book)
                }.border({ width: { bottom: this.showDivider ? 1 : 0 }, color: ThemeColors.outlineVariant(this.isDark) })
                .onClick(() => { this.isSelectMode ? this.toggleBookSelection(book.id) : this.continueRead(book); })
                .gesture(LongPressGesture().onAction(() => { this.onBookLongPress(book); }))
              }, (book: Book): string => String(book.id))
            }.width('100%').margin({ top: 4 })
		          } else {
		            Grid() {
		              LazyForEach(this.bookDataSource_, (book: Book) => {
		                GridItem() {
		                  this.buildGridItem(book)
		                }.onClick(() => { this.isSelectMode ? this.toggleBookSelection(book.id) : this.continueRead(book); })
		                .priorityGesture(LongPressGesture().onAction(() => { this.onBookLongPress(book); }))
		              }, (book: Book): string => String(book.id))
			            }.columnsTemplate(new Array(Math.max(1, this.computeGridColumns_())).fill('1fr').join(' ')).columnsGap(8).rowsGap(8)
			            .padding({ left: 16, right: 16, top: 8 })
			          }
	        }.layoutWeight(1).width('100%').onRefreshing(() => { this.onRefresh(); }).refreshOffset(64)
      }
    }
    // ---- 书架菜单 ----
    if (this.showMenu) {
      Column().width('100%').height('100%').position({ top: 0, left: 0 }).onClick(() => { this.showMenu = false; })
      Column() {
        this.mi('添加远程书籍', () => { this.showMenu = false; UiUtil.pushUrl(this.getUIContext(), { url: 'pages/SearchPage' }); })
        this.mi('添加本地书籍', () => { this.showMenu = false; this.addLocalBooks(); })
        this.mi('更新目录', () => { this.showMenu = false; this.updateTocForVisible(); })
        this.mi('布局设置', () => { this.showMenu = false; this.cfgDlg?.open(); })
        this.mi('分组管理', () => { this.showMenu = false; this.groupDlg?.open(); })
        this.mi('添加URL', () => { this.showMenu = false; this.addUrlDlg?.open(); })
        this.mi(this.isSelectMode ? '退出选择模式' : '选择模式', () => { this.showMenu = false; this.toggleSelectMode(); })
        this.mi('书架管理', () => { this.showMenu = false; UiUtil.pushUrl(this.getUIContext(), { url: 'pages/BookshelfManagePage' }); })
        this.mi('缓存/导出', () => { this.showMenu = false; UiUtil.pushUrl(this.getUIContext(), { url: 'pages/BookCachePage' }); })
        this.mi('导出书架', () => { this.showMenu = false; this.openExportDialog(this.currentTargetBooks()); })
        this.mi('导入书架', () => { this.showMenu = false; this.importDlg?.open(); })
        this.mi('日志', () => { this.showMenu = false; UiUtil.showToast(this.getUIContext(), { message: '日志面板待接入', duration: 1500 }); })
      }
      .position({ top: 8, right: 8 }).backgroundColor(ThemeColors.surface(this.isDark))
      .borderRadius(12).shadow({ radius: 8, color: ThemeColors.shadow(this.isDark) }).width(180)
    }
    // 导入进度遮罩（居中 + 最大宽度 420vp）
    if (this.isImporting) {
      Column() {
        Column() {
          LoadingProgress().color(ThemeColors.primary(this.isDark)).width(48).height(48)
          Text(this.importProgress || '正在导入...')
            .fontSize(14).fontColor(ThemeColors.onSurface(this.isDark))
            .margin({ top: 12 }).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .padding(24).backgroundColor(ThemeColors.surface(this.isDark))
        .borderRadius(12).alignItems(HorizontalAlign.Center)
        .constraintSize({ maxWidth: 420 })
      }
      .width('100%').height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
  }
  .width('100%').height('100%')
  }

  @Builder
  mi(label: string, cb: () => void) {
    Row() {
      Text(label).fontSize(14).fontColor(ThemeColors.onSurface(this.isDark))
    }
    .width('100%').height(44).padding({ left: 16, right: 16 })
    .justifyContent(FlexAlign.Start).alignItems(VerticalAlign.Center)
    .onClick(cb)
  }

  @Builder
  buildListItem(book: Book) {
    Row() {
      if (this.isSelectMode) {
        Text(this.isSelected(book.id) ? '✓' : '')
          .fontSize(16).fontColor(ThemeColors.onPrimary(this.isDark)).fontWeight(FontWeight.Bold)
          .width(24).height(24).textAlign(TextAlign.Center)
          .backgroundColor(this.isSelected(book.id) ? ThemeColors.primary(this.isDark) : ThemeColors.strongScrim(this.isDark))
          .borderRadius(12).margin({ right: 8 })
      }
      BookCover({ name: book.name, coverUrl: book.coverUrl, coverWidth: this.coverWidth, coverHeight: Math.round(this.coverWidth * 1.375) })
        .margin({ right: 12 })
        .shadow({ radius: this.coverShadow ? 6 : 0, color: ThemeColors.shadow(this.isDark), offsetY: 2 })
      Column() {
        Row() {
          Text(book.name).fontSize(15).fontWeight(FontWeight.Bold).fontColor(ThemeColors.onBackground(this.isDark))
            .maxLines(this.titleMaxLines).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          if (this.showUnread && this.getNewChaptersCount(book) > 0) {
            Text('+' + this.getNewChaptersCount(book))
              .fontSize(10).fontColor(ThemeColors.onPrimary(this.isDark)).fontWeight(FontWeight.Bold)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .backgroundColor(ThemeColors.error(this.isDark)).borderRadius(8).margin({ left: 4 })
          }
        }.width('100%').alignItems(VerticalAlign.Center)
        if (!this.isCompact) {
          Text(book.author || '未知作者').fontSize(12).fontColor(ThemeColors.onBackground(this.isDark))
            .alignSelf(ItemAlign.Start).margin({ top: 2 })
        }
        if (!this.isCompact && book.durChapterTitle) {
          Text(book.durChapterTitle).fontSize(11).fontColor(ThemeColors.onBackground(this.isDark))
            .alignSelf(ItemAlign.Start).margin({ top: 1 })
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }
        if (!this.isCompact && this.showLatestChapter && book.latestChapterTitle && book.latestChapterTitle !== book.durChapterTitle) {
          Text('最新: ' + book.latestChapterTitle).fontSize(11)
            .fontColor(ThemeColors.primary(this.isDark))
            .alignSelf(ItemAlign.Start).margin({ top: 1 })
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }
        if (!this.isCompact) {
          Row() {
            Row().width(this.getProgressPercent(book) + '%').height(3).backgroundColor(ThemeColors.primary(this.isDark)).borderRadius(2)
          }.width('100%').height(3).margin({ top: 3 }).backgroundColor(ThemeColors.outlineVariant(this.isDark)).borderRadius(2)
        }
        if (!this.isCompact && this.showBookIntro && book.introduce) {
          Text(book.introduce).fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark))
            .maxLines(this.getIntroMaxLines()).textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%').margin({ top: 2 })
        }
        Row() {
          if (this.showLastUpdateTime && book.lastOpenTime > 0) Text(this.formatTime(book.lastOpenTime)).fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark))
          Blank()
          if (book.totalChapterNum > 0) {
            Text(book.durChapterIndex + '/' + book.totalChapterNum + ' (' + this.getProgressPercent(book) + '%)')
              .fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark))
          }
        }.width('100%').margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .constraintSize({ minHeight: Math.round(this.coverWidth * 1.375) })
      .justifyContent(FlexAlign.Center)
      if (!this.isSelectMode) {
        Button() { Text($r('app.string.ui_0951b9a022')).fontSize(14).fontColor(ThemeColors.error(this.isDark)) }
          .width(40).height(40).backgroundColor(ThemeColors.transparent())
          .accessibilityText($r('app.string.common_close')).onClick(() => { this.confirmRemove(book); })
      }
    }.padding({ left: 12, right: 4 }).width('100%')
  }

  @Builder
  buildGridItem(book: Book) {
    Column() {
      Stack() {
        BookCover({ name: book.name, coverUrl: book.coverUrl, coverWidth: this.coverWidth * 1.5, coverHeight: Math.round(this.coverWidth * 1.5 * 1.4) })
          .shadow({ radius: this.coverShadow ? 6 : 0, color: ThemeColors.shadow(this.isDark), offsetY: 2 })
        if (this.showUnread && this.getNewChaptersCount(book) > 0) {
          Text('+' + this.getNewChaptersCount(book))
            .fontSize(10).fontColor(ThemeColors.onPrimary(this.isDark)).fontWeight(FontWeight.Bold)
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .backgroundColor(ThemeColors.error(this.isDark)).borderRadius(8).position({ top: 4, right: 4 })
        }
        if (this.isSelectMode) {
          Text(this.isSelected(book.id) ? '✓' : '')
            .fontSize(18).fontColor(ThemeColors.onPrimary(this.isDark)).fontWeight(FontWeight.Bold)
            .width(28).height(28).textAlign(TextAlign.Center)
            .backgroundColor(this.isSelected(book.id) ? ThemeColors.primary(this.isDark) : ThemeColors.strongScrim(this.isDark))
            .borderRadius(14).position({ top: 4, left: 4 })
        }
      }.width('100%').height(Math.round(this.coverWidth * 1.5 * 1.4))
      if (this.gridStyle !== 2) {
        Text(book.name).fontSize(13).fontWeight(FontWeight.Medium).fontColor(ThemeColors.onBackground(this.isDark))
          .maxLines(this.gridStyle === 1 ? 1 : this.titleMaxLines).textOverflow({ overflow: TextOverflow.Ellipsis })
          .width(this.coverWidth * 1.5)
          .margin({ top: 4 })
          .textAlign(TextAlign.Center)
        if (this.gridStyle === 0) {
          Text(book.author || '未知作者').fontSize(11).fontColor(ThemeColors.onBackground(this.isDark))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .width(this.coverWidth * 1.5)
            .textAlign(TextAlign.Center)
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Center)
  }
}
