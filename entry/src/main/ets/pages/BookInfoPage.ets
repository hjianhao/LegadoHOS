import { AppTheme } from '../theme/AppTheme';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookTable } from '../data/database/BookTable';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { ChapterTable } from '../data/database/ChapterTable';
import { Book, BookType, BookGroup } from '../model/Book';
import { BookSource } from '../model/BookSource';
import { BookSourceChapter } from '../model/BookSource';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { ChapterCache } from '../util/ChapterCache';
import { NetUtil } from '../util/NetUtil';
import { BookCover } from '../components/BookCover';
import { SearchResult } from '../model/SearchResult';
import {
  ChangeCoverSheet,
  ChangeSourceSheet,
  GroupSelectSheet,
  BookReadRecordSheet,
  RemarkEditDialog
} from '../components/BookInfoSheets';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';

@Entry
@Component
export struct BookInfoPage {
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
  @State isDark: boolean = false;
  @State isLoading: boolean = true;
  @State isRefreshing: boolean = false;
  @State isBusy: boolean = false;
  @State isInShelf: boolean = false;
  @State sourceHeader: string = '';
  @State sourceCount: number = 1;
  @State chapterCount: number = 0;
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

  private cachedSearchResults: SearchResult[] = [];
  private coverDlg?: CustomDialogController;
  private sourceDlg?: CustomDialogController;
  private groupDlg?: CustomDialogController;
  private readRecordDlg?: CustomDialogController;
  private remarkDlg?: CustomDialogController

  aboutToAppear(): void {
    this.isDark = AppTheme.getInstance().isDark;
    const params = router.getParams() as Record<string, string>;
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
    this.tryFetchBookInfo();
    this.tryFetchCover();
    this.isLoading = false;
  }

  /** 从源获取书籍详情和目录 */
  async tryFetchBookInfo(): Promise<void> {
    if (!this.noteUrl || !this.originUrl) return;
    this.isRefreshing = true;
    try {
      await AppDatabase.getInstance().waitForInit();
      const dao = new BookSourceTable(AppDatabase.getInstance().rdbStore);
      const sources = await dao.getAllSources();
      const matched = sources.find(s => s.sourceUrl === this.originUrl || s.sourceName === this.origin);
      if (!matched) return;
      // 获取书籍详情
      if (!this.introduce || !this.kind || !this.wordCount) {
        const info = await globalSourceExecutor.getBookInfo(matched, this.noteUrl);
        if (info.name && !this.bookName) this.bookName = info.name;
        if (info.author && !this.bookAuthor) this.bookAuthor = info.author;
        if (info.coverUrl && !this.coverUrl) this.coverUrl = info.coverUrl;
        if (info.introduce && !this.introduce) this.introduce = info.introduce;
        if (info.kind && !this.kind) this.kind = info.kind;
        if (info.wordCount && !this.wordCount) this.wordCount = info.wordCount;
      }
      // 获取目录统计
      const chapters = await globalSourceExecutor.getToc(matched, this.noteUrl);
      if (chapters.length > 0) {
        this.chapterCount = chapters.length;
        const last = chapters[chapters.length - 1];
        this.latestChapter = last.title || '';
        this.recentChapters = chapters.slice(0, 5);
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
          this.isInShelf = true;
          this.bookId = matched.id;
          if (matched.name) this.bookName = matched.name;
          if (matched.author) this.bookAuthor = matched.author;
          if (matched.coverUrl) this.coverUrl = matched.coverUrl;
          if (matched.customCoverPath) this.customCoverPath = matched.customCoverPath;
          if (matched.origin) this.origin = matched.origin;
          if (matched.originUrl) this.originUrl = matched.originUrl;
          if (matched.bookUrl) this.noteUrl = matched.bookUrl;
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
      promptAction.showToast({ message: '未在书架中', duration: 1500 });
      return;
    }
    promptAction.showDialog({
      title: '确认删除',
      message: '从书架中移除 "' + this.bookName + '"？',
      buttons: [
        { text: '取消', color: '#888' },
        { text: '删除', color: '#FF5722' }
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
        kind: '', wordCount: '', introduce: '', remark: '', lastUpdateTime: '', lastOpenTime: 0,
        createTime: 0, updateTime: Date.now()
      });
      this.isInShelf = false;
      this.bookId = 0;
      AppStorage.set<number>('shelfRefreshCounter', (AppStorage.get<number>('shelfRefreshCounter') || 0) + 1);
      promptAction.showToast({ message: '已从书架移除', duration: 1500 });
    } catch (_e) {
      promptAction.showToast({ message: '删除失败', duration: 2000 });
    }
  }

  private clearCache(): void {
    if (!this.bookId) {
      promptAction.showToast({ message: '未在书架中', duration: 1500 });
      return;
    }
    promptAction.showDialog({
      title: '清除缓存',
      message: '清除《' + this.bookName + '》已缓存的章节内容？目录和阅读进度会保留。',
      buttons: [
        { text: '取消', color: '#888' },
        { text: '清除', color: '#FF9800' }
      ]
    }).then((res: Object) => {
      if ((res as Record<string, Object>)['index'] === 1) this.doClearCache();
    });
  }

  private async doClearCache(): Promise<void> {
    try {
      const chapterTable = new ChapterTable(AppDatabase.getInstance().rdbStore);
      await chapterTable.clearContentByBookId(this.bookId);
      promptAction.showToast({ message: '成功清理缓存', duration: 1500 });
    } catch (_e) {
      promptAction.showToast({ message: '清理缓存失败', duration: 1500 });
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
      const dao = new BookSourceTable(db);
      const sources = await dao.getAllSources();
      const matched = sources.find(s => s.sourceUrl === this.originUrl);
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
      const now = Date.now();
      if (this.noteUrl) {
        const existing = await bookTable.getBookByUrl(this.noteUrl);
        if (existing) {
          if (!existing.isShelf) {
            existing.isShelf = true;
            existing.updateTime = now;
          }
          // 始终用详情页最新数据更新关键字段（包括 coverUrl）
          if (this.coverUrl && !existing.coverUrl) existing.coverUrl = this.coverUrl;
          if (this.customCoverPath && !existing.customCoverPath) existing.customCoverPath = this.customCoverPath;
          if (this.kind && !existing.kind) existing.kind = this.kind;
          if (this.wordCount && !existing.wordCount) existing.wordCount = this.wordCount;
          if (this.introduce && !existing.introduce) existing.introduce = this.introduce;
          if (this.origin && !existing.origin) existing.origin = this.origin;
          if (this.originUrl && !existing.originUrl) existing.originUrl = this.originUrl;
          existing.updateTime = now;
          await bookTable.updateBook(existing);
          this.isInShelf = true;
          this.bookId = existing.id;
          this.groupId = existing.groupId;
          this.durChapterTitle = existing.durChapterTitle || '';
          this.durChapterIndex = existing.durChapterIndex || 0;
          AppStorage.set<number>('shelfRefreshCounter', (AppStorage.get<number>('shelfRefreshCounter') || 0) + 1);
          promptAction.showToast({ message: '已加入书架', duration: 1500 });
          return;
        }
      }

      const book: Book = {
        id: 0,
        name: this.bookName,
        author: this.bookAuthor,
        coverUrl: this.coverUrl,
        customCoverPath: this.customCoverPath,
        bookUrl: this.noteUrl,
        origin: this.origin,
        originUrl: this.originUrl,
        type: BookType.TEXT,
        groupId: BookGroup.ALL,
        tocUrl: '',
        chapterCount: this.chapterCount,
        totalChapterNum: this.chapterCount,
        latestChapterTitle: '',
        durChapterTitle: '',
        durChapterIndex: 0,
        durChapterPos: 0,
        durChapterProgress: 0,
        isRead: false,
        isAudio: false,
        isManga: false,
        isShelf: true,
        order: 0,
        kind: this.kind,
        wordCount: this.wordCount,
        introduce: this.introduce,
        remark: '',
        lastUpdateTime: '',
        lastOpenTime: 0,
        createTime: Date.now(),
        updateTime: Date.now()
      };

      const id = await bookTable.insertBook(book);
      if (id > 0) {
        this.bookId = id;
        this.isInShelf = true;
        this.groupId = book.groupId;
        AppStorage.set<number>('shelfRefreshCounter', (AppStorage.get<number>('shelfRefreshCounter') || 0) + 1);
        promptAction.showToast({ message: '已加入书架', duration: 1500 });
      }
    } catch (err) {
      promptAction.showToast({ message: '加入书架失败', duration: 2000 });
    }
  }

  /**
   * 开始阅读（对齐 Android readBook + openReader）：
   * 1. 不在书架 → 隐式保存（标记 notShelf），加入数据库后再打开阅读器
   * 2. 已在书架 → 更新 lastOpenTime 后打开
   */
  async startRead(): Promise<void> {
    if (!this.isInShelf) {
      // 不在书架：隐式保存书籍（对齐 Android BookType.notShelf 语义）
      const saved = await this.saveBookImplicitly();
      if (!saved) {
        promptAction.showToast({ message: '保存失败，请重试', duration: 1500 });
        return;
      }
    } else if (this.bookId > 0) {
      // 已在书架：更新最后打开时间
      await this.updateLastOpenTime();
    }
    router.pushUrl({
      url: 'pages/ReadPage',
      params: {
        name: this.bookName,
        author: this.bookAuthor,
        bookUrl: this.noteUrl,
        origin: this.origin,
        originUrl: this.originUrl,
        header: this.sourceHeader,
        bookId: this.bookId,
        inBookshelf: this.isInShelf,
      }
    });
  }

  startReadAt(index: number): void {
    router.pushUrl({
      url: 'pages/ReadPage',
      params: {
        name: this.bookName,
        author: this.bookAuthor,
        bookUrl: this.noteUrl,
        origin: this.origin,
        originUrl: this.originUrl,
        header: this.sourceHeader,
        durChapterIndex: index,
        bookId: this.bookId,
        inBookshelf: this.isInShelf,
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

      const now = Date.now();
      const book: Book = {
        id: 0,
        name: this.bookName,
        author: this.bookAuthor,
        coverUrl: this.coverUrl,
        customCoverPath: this.customCoverPath,
        bookUrl: this.noteUrl,
        origin: this.origin,
        originUrl: this.originUrl,
        type: BookType.TEXT,
        groupId: BookGroup.ALL,
        tocUrl: '',
        chapterCount: this.chapterCount,
        totalChapterNum: this.chapterCount,
        latestChapterTitle: this.latestChapter,
        durChapterTitle: this.durChapterTitle,
        durChapterIndex: this.durChapterIndex,
        durChapterPos: 0,
        durChapterProgress: 0,
        isRead: false,
        isAudio: false,
        isManga: false,
        isShelf: false,  // 关键：不在书架（对齐 Android BookType.notShelf）
        order: 0,
        kind: this.kind,
        wordCount: this.wordCount,
        introduce: this.introduce,
        remark: this.remark,
        lastUpdateTime: this.lastUpdateTime,
        lastOpenTime: now,
        createTime: now,
        updateTime: now,
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
    this.origin = result.origin || this.origin;
    this.originUrl = result.originUrl || this.originUrl;
    this.noteUrl = result.noteUrl || this.noteUrl;
    if (result.coverUrl) this.coverUrl = result.coverUrl;
    if (result.kind) this.kind = result.kind;
    if (result.wordCount) this.wordCount = result.wordCount;
    if (result.introduce) this.introduce = result.introduce;
    this.sourceHeader = '';
    this.recentChapters = [];
    this.loadSourceHeader();
    this.tryFetchBookInfo();
    this.tryFetchCover();
    promptAction.showToast({ message: '已更换书源', duration: 1500 });
  }

  private addSourceAsNewBook(result: SearchResult): void {
    promptAction.showToast({ message: '已作为新书加入书架', duration: 1500 });
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
    promptAction.showToast({ message: '封面已更新', duration: 1200 });
  }

  showGroupSheet(): void {
    this.groupDlg = new CustomDialogController({
      builder: GroupSelectSheet({
        controller: this.groupDlg!,
        selectedGroupId: this.groupId,
        onConfirm: (gid: number) => {
          this.groupId = gid;
          promptAction.showToast({ message: '分组已更新', duration: 1500 });
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
          promptAction.showToast({ message: '备注已保存', duration: 1500 });
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      customStyle: true
    });
    this.remarkDlg.open();
  }

  openToc(): void {
    router.pushUrl({ url: 'pages/ChapterListPage', params: {
      from: 'BookInfoPage', bookName: this.bookName, bookAuthor: this.bookAuthor,
      bookUrl: this.noteUrl, originUrl: this.originUrl, origin: this.origin,
      header: this.sourceHeader,
    }});
  }

  build() {
    Stack() {
      // 背景层：对齐 Android BookInfoBackdrop，使用封面大图 + 遮罩 + 向下过渡到内容底色
      Column() {
        if (this.getDisplayCover()) {
          Image(this.getDisplayCover())
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
            [this.isDark ? '#263238AA' : '#DDE6E8AA', 0.0],
            [this.isDark ? '#121212E6' : '#FFFFFFD9', 0.56],
            [this.surfaceColor(), 0.74],
            [this.surfaceColor(), 1.0],
          ]
        })

      Column() {
        // 透明顶栏：返回 + 分享 + 更多，滚动顶部保持轻量
        Row() {
          Button() { Text('‹').fontSize(30).fontColor(this.primaryTextColor()) }
            .width(44).height(44).backgroundColor(Color.Transparent)
            .onClick((): void => { router.back(); })
          Blank()
          Button() { Text('↗').fontSize(20).fontColor(this.primaryTextColor()) }
            .width(44).height(44).backgroundColor(Color.Transparent)
            .onClick(() => {
              promptAction.showToast({ message: '分享功能待完善', duration: 1200 });
            })
          Button() { Text('⋮').fontSize(24).fontColor(this.primaryTextColor()) }
            .width(44).height(44).backgroundColor(Color.Transparent)
            .onClick(() => { this.showMoreMenu = !this.showMoreMenu; })
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
                  coverHeight: 157
                })
                  .borderRadius(8)
                  .shadow({ radius: 16, color: '#00000030', offsetX: 0, offsetY: 8 })
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
                    Text('作').fontSize(11).fontColor(this.secondaryTextColor())
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
                    Text('网').fontSize(11).fontColor(this.primaryColor())
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
                    promptAction.showToast({ message: this.originUrl || this.origin || '暂无书源信息', duration: 1500 });
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
                ['#00000000', 0.0],
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
            Text('书').fontSize(15).fontWeight(FontWeight.Bold).fontColor(this.fabTextColor())
            Text('阅读').fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.fabTextColor())
              .margin({ left: 8 })
          }
        }
        .height(54)
        .padding({ left: 18, right: 22 })
        .borderRadius(27)
        .backgroundColor(this.fabColor())
        .shadow({ radius: 18, color: '#00000030', offsetX: 0, offsetY: 8 })
        .margin({ right: 16, bottom: 16 })
        .onClick((): void => { this.startRead(); })
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)

      if (this.showMoreMenu) {
        this.buildOverflowMenu()
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
      Text('目录：' + (this.durChapterTitle || (this.isRefreshing ? '加载中' : '未开始阅读')))
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
        Text('|')
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
        Text('目录加载失败或书源暂无目录')
          .fontSize(12)
          .fontColor('#E35D5B')
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
      this.buildMenuItem('刷新', () => { this.showMoreMenu = false; this.tryFetchBookInfo(); })
      this.buildMenuItem('换封面', () => { this.showMoreMenu = false; this.showCoverSheet(); })
      this.buildMenuItem('书籍分组', () => { this.showMoreMenu = false; this.showGroupSheet(); })
      this.buildMenuItem('备注', () => { this.showMoreMenu = false; this.showRemarkDialog(); })
      if (this.isInShelf) {
        this.buildMenuItem('清缓存', () => { this.showMoreMenu = false; this.clearCache(); })
        this.buildMenuItem('移出书架', () => { this.showMoreMenu = false; this.removeFromShelf(); }, true)
      }
    }
    .width(150)
    .padding({ top: 8, bottom: 8 })
    .borderRadius(16)
    .backgroundColor(this.isDark ? '#2A2A2A' : '#FFFFFF')
    .shadow({ radius: 20, color: '#00000026', offsetX: 0, offsetY: 8 })
    .position({ x: 'calc(100% - 166vp)', y: 82 })
    .zIndex(30)
  }

  @Builder buildMenuItem(label: string, action: () => void, danger: boolean = false) {
    Text(label)
      .fontSize(14)
      .fontColor(danger ? '#E35D5B' : this.primaryTextColor())
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
    const cs = ['#455A64','#5C6BC0','#26A69A','#EC407A','#AB47BC','#42A5F5','#66BB6A','#FF7043'];
    return this.bookName ? cs[this.bookName.charCodeAt(0) % cs.length] : cs[0];
  }

  private surfaceColor(): string {
    return this.isDark ? '#121212' : '#FFFFFF';
  }

  private surfaceTranslucentColor(): string {
    return this.isDark ? '#121212CC' : '#FFFFFFD9';
  }

  private containerColor(): string {
    return this.isDark ? '#2A2A2A' : '#EEF2F3';
  }

  private containerLowColor(): string {
    return this.isDark ? '#1F1F1F' : '#F5F7F8';
  }

  private primaryTextColor(): string {
    return this.isDark ? '#F2F2F2' : '#1B1B1F';
  }

  private secondaryTextColor(): string {
    return this.isDark ? '#C6C6C6' : '#5F6368';
  }

  private tertiaryTextColor(): string {
    return this.isDark ? '#9A9A9A' : '#7A7D82';
  }

  private primaryColor(): string {
    return this.isDark ? '#8AB4F8' : '#2F6F8F';
  }

  private fabColor(): string {
    return this.isDark ? '#B8D7EA' : '#355F72';
  }

  private fabTextColor(): string {
    return this.isDark ? '#12313F' : '#FFFFFF';
  }
}
