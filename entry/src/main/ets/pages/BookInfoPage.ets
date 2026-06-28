import { AppTheme } from '../theme/AppTheme';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookTable } from '../data/database/BookTable';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { Book, BookType, BookGroup } from '../model/Book';
import { BookSource } from '../model/BookSource';
import { BookSourceChapter } from '../model/BookSource';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { ChapterCache } from '../util/ChapterCache';
import { NetUtil } from '../util/NetUtil';
import { BookCover } from '../components/BookCover';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';

@Entry
@Component
export struct BookInfoPage {
  @State bookName: string = '';
  @State bookAuthor: string = '';
  @State coverUrl: string = '';
  @State noteUrl: string = '';
  @State origin: string = '';
  @State originUrl: string = '';
  @State introduce: string = '';
  @State kind: string = '';
  @State wordCount: string = '';
  @State isDark: boolean = false;
  @State isLoading: boolean = true;
  @State isInShelf: boolean = false;
  @State sourceHeader: string = '';
  @State sourceCount: number = 1;
  @State chapterCount: number = 0;
  @State latestChapter: string = '';
  @State recentChapters: BookSourceChapter[] = [];
  @State introExpanded: boolean = false;
  @State durChapterTitle: string = '';     // 阅读进度
  @State durChapterIndex: number = 0;
  @State lastReadTime: string = '';        // 最后阅读时间
  @State bookId: number = 0;               // 书架中的 ID

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
  }

  /** 检查书籍是否已在书架 */
  async checkShelfStatus(): Promise<void> {
    if (!this.bookName && !this.noteUrl) return;
    try {
      await AppDatabase.getInstance().waitForInit();
      const bookTable = new BookTable(AppDatabase.getInstance().rdbStore);
      if (this.noteUrl) {
        const existing = await bookTable.searchBooks(this.bookName);
        const matched = existing.find(b => b.name === this.bookName || b.bookUrl === this.noteUrl);
        if (matched) {
          this.isInShelf = true;
          this.bookId = matched.id;
          this.durChapterTitle = matched.durChapterTitle || '';
          this.durChapterIndex = matched.durChapterIndex || 0;
          if (matched.lastOpenTime > 0) {
            const d = new Date(matched.lastOpenTime);
            this.lastReadTime = d.getMonth()+1 + '-' + d.getDate() + ' ' +
              String(d.getHours()).padStart(2,'0') + ':' + String(d.getMinutes()).padStart(2,'0');
          }
          console.info('[BookInfo] found in shelf, id=', matched.id, 'progress=', matched.durChapterTitle);
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
        kind: '', wordCount: '', introduce: '', lastUpdateTime: '', lastOpenTime: 0,
        createTime: 0, updateTime: Date.now()
      });
      this.isInShelf = false;
      this.bookId = 0;
      promptAction.showToast({ message: '已从书架移除', duration: 1500 });
    } catch (_e) {
      promptAction.showToast({ message: '删除失败', duration: 2000 });
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
      if (this.noteUrl) {
        const existing = await bookTable.getBookByUrl(this.noteUrl);
        if (existing) {
          if (!existing.isShelf) {
            existing.isShelf = true;
            await bookTable.updateBook(existing);
          }
          this.isInShelf = true;
          promptAction.showToast({ message: '已加入书架', duration: 1500 });
          return;
        }
      }

      const book: Book = {
        id: 0,
        name: this.bookName,
        author: this.bookAuthor,
        coverUrl: this.coverUrl,
        customCoverPath: '',
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
        lastUpdateTime: '',
        lastOpenTime: 0,
        createTime: Date.now(),
        updateTime: Date.now()
      };

      const id = await bookTable.insertBook(book);
      if (id > 0) {
        this.isInShelf = true;
        promptAction.showToast({ message: '已加入书架', duration: 1500 });
      }
    } catch (err) {
      promptAction.showToast({ message: '加入书架失败', duration: 2000 });
    }
  }

  startRead(): void {
    router.pushUrl({
      url: 'pages/ReadPage',
      params: {
        name: this.bookName,
        author: this.bookAuthor,
        bookUrl: this.noteUrl,
        origin: this.origin,
        originUrl: this.originUrl,
        header: this.sourceHeader
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
      }
    });
  }

  changeSource(): void {
    promptAction.showToast({ message: '换源功能开发中', duration: 1500 });
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
      Column() {
        // 顶部导航（透明底）
        Row() {
          Button() { Text('←').fontSize(20).fontColor('#FFF') }
            .width(40).height(40).backgroundColor('transparent')
            .onClick((): void => { router.back(); })
          Blank()
        }.width('100%').padding({ left: 8, top: 40 }).zIndex(10).position({ x: 0, y: 0 })

        Scroll() {
          Column() {
            // ===== 封面区 =====
            Column() {
              Row() {
                // 封面
                Stack() {
                  Column() {
                    Text(this.bookName ? this.bookName.charAt(0) : '?').fontSize(50).fontColor('#FFF').fontWeight(FontWeight.Bold)
                  }.width(140).height(180).borderRadius(10)
                    .backgroundColor(this.getCoverColor()).justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                  if (this.coverUrl) {
                    Image(this.coverUrl).width(140).height(180).borderRadius(10).objectFit(ImageFit.Cover)
                  }
                }.margin({ right: 16 })

                // 书名 + 作者
                Column() {
                  Text(this.bookName || '未知书名').fontSize(20).fontWeight(FontWeight.Bold)
                    .fontColor('#FFF').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .alignSelf(ItemAlign.Start)
                  Text(this.bookAuthor || '未知作者').fontSize(14).fontColor('rgba(255,255,255,0.8)')
                    .alignSelf(ItemAlign.Start).margin({ top: 6 })
                  if (this.origin) {
                    Text(this.origin).fontSize(12).fontColor('rgba(255,255,255,0.6)')
                      .alignSelf(ItemAlign.Start).margin({ top: 4 })
                  }
                  Blank()
                  // 统计行
                  Row() {
                    if (this.wordCount) { Text(this.wordCount).fontSize(11).fontColor('rgba(255,255,255,0.7)').margin({right:12}) }
                    if (this.chapterCount > 0) { Text(this.chapterCount + '章').fontSize(11).fontColor('rgba(255,255,255,0.7)').margin({right:12}) }
                    if (this.kind) { Text(this.kind).fontSize(11).fontColor('rgba(255,255,255,0.7)').padding({left:6,right:6}).backgroundColor('rgba(255,255,255,0.15)').borderRadius(4) }
                  }.alignSelf(ItemAlign.Start)
                }.layoutWeight(1).height(180)
              }.width('100%').padding(16)
            }.width('100%')
            .linearGradient({ direction: GradientDirection.Bottom, colors: [['#263238', 0.0], ['#37474F', 1.0]] })
            .padding({ top: 48 })

            // ===== 最新章节 =====
            if (this.latestChapter) {
              Row() {
                Column() {
                  Text('最新章节').fontSize(11).fontColor('#888')
                  Text(this.latestChapter).fontSize(13).fontColor(this.isDark ? '#CCC' : '#444')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                }.layoutWeight(1)
                Text('›').fontSize(18).fontColor('#CCC')
              }.width('100%').padding(16)
              .backgroundColor(this.isDark ? '#1A1A1A' : '#FFF')
              .border({ width: { bottom: 1 }, color: this.isDark ? '#333' : '#EEE' })
              .onClick(() => { this.openToc(); })
            }

            // ===== 最近章节 (前5章) =====
            if (this.recentChapters.length > 0) {
              Column() {
                Row() {
                  Text('目录 (' + this.chapterCount + '章)').fontSize(14).fontWeight(FontWeight.Medium).layoutWeight(1)
                  Text('全部 ›').fontSize(12).fontColor('#0078D7').onClick(() => { this.openToc(); })
                }.width('100%').padding({left:16,right:16,top:10,bottom:6})
                .backgroundColor(this.isDark ? '#1A1A1A' : '#FFF')
                .border({ width: { bottom: 1 }, color: this.isDark ? '#333' : '#EEE' })
                ForEach(this.recentChapters, (ch: BookSourceChapter, idx: number) => {
                  Row() {
                    Text(String(ch.index + 1)).fontSize(11).fontColor('#BBB').width(30)
                    Text(ch.title || '第' + (ch.index + 1) + '章').fontSize(13)
                      .fontColor(this.isDark ? '#CCC' : '#444').maxLines(1).layoutWeight(1)
                  }.width('100%').padding({left:16,right:16,top:8,bottom:8})
                  .backgroundColor(this.isDark ? '#1A1A1A' : '#FFF')
                  .border({ width: { bottom: 1 }, color: this.isDark ? '#333' : '#F0F0F0' })
                  .onClick(() => {
                    ChapterCache.chapters = [];
                    this.startReadAt(idx);
                  })
                }, (ch: BookSourceChapter) => ch.index.toString())
              }.onClick(() => { this.openToc(); })
            }

            // ===== 操作按钮 =====
            Row() {
              Button('开始阅读').fontSize(14).height(42).layoutWeight(1).margin({ right: 4 })
                .backgroundColor('#0078D7').fontColor('#FFF').borderRadius(21)
                .onClick((): void => { this.startRead() })
              Button(this.isInShelf ? '已在书架' : '加入书架').fontSize(12).height(42).width(100)
                .backgroundColor(this.isInShelf ? '#999' : '#4CAF50').fontColor('#FFF').borderRadius(21)
                .enabled(!this.isInShelf).onClick((): void => { this.addToShelf() })
            }.width('100%').padding(16)
            .backgroundColor(this.isDark ? '#1A1A1A' : '#FFF')
            .border({ width: { bottom: 1 }, color: this.isDark ? '#333' : '#EEE' })

            // 阅读进度
            if (this.isInShelf && this.durChapterTitle) {
              Row() {
                Text('📖 ' + this.durChapterTitle).fontSize(12).fontColor('#0078D7')
                  .maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis}).layoutWeight(1)
                if (this.lastReadTime) {
                  Text(this.lastReadTime).fontSize(11).fontColor('#AAA')
                }
              }.width('100%').padding({left:16,right:16,top:10,bottom:10})
              .backgroundColor(this.isDark ? '#1A1A1A' : '#FFF')
              .border({ width: { bottom: 1 }, color: this.isDark ? '#333' : '#EEE' })
            }

            // ===== 次操作 =====
            Row() {
              this.buildIconBtn('🔄', '换源', () => { this.changeSource(); })
              this.buildIconBtn('📋', '目录', () => { this.openToc(); })
              this.buildIconBtn('🔄', '刷新', () => { this.tryFetchBookInfo(); })
              if (this.isInShelf) {
                this.buildIconBtn('🗑️', '删除', () => { this.removeFromShelf(); })
              }
            }.width('100%').padding({left:8,right:8,top:6,bottom:6}).justifyContent(FlexAlign.SpaceEvenly)
            .backgroundColor(this.isDark ? '#1A1A1A' : '#FFF')
            .border({ width: { bottom: 1 }, color: this.isDark ? '#333' : '#EEE' })

            // ===== 简介 =====
            if (this.introduce) {
              Column() {
                Text('简介').fontSize(14).fontWeight(FontWeight.Medium)
                  .margin({ bottom: 6 }).alignSelf(ItemAlign.Start)
                Text(this.introduce).fontSize(13).fontColor('#888').lineHeight(20)
                  .maxLines(this.introExpanded ? 100 : 5).textOverflow({ overflow: TextOverflow.Ellipsis })
                  .alignSelf(ItemAlign.Start)
                if (this.introduce.length > 200) {
                  Text(this.introExpanded ? '收起' : '展开').fontSize(12).fontColor('#0078D7')
                    .margin({ top: 4 }).alignSelf(ItemAlign.Start)
                    .onClick(() => { this.introExpanded = !this.introExpanded; })
                }
              }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
              .backgroundColor(this.isDark ? '#1A1A1A' : '#FFF')
            }
          }.width('100%')
        }.layoutWeight(1).width('100%')
      }.width('100%').height('100%')
    }.width('100%').height('100%').backgroundColor(this.isDark ? '#121212' : '#F0F0F0')
  }

  @Builder buildIconBtn(icon: string, label: string, action: () => void) {
    Column() {
      Text(icon).fontSize(20)
      Text(label).fontSize(10).fontColor('#888').margin({top:2})
    }.onClick(action).padding({left:8,right:8})
  }

  private getCoverColor(): string {
    const cs = ['#455A64','#5C6BC0','#26A69A','#EC407A','#AB47BC','#42A5F5','#66BB6A','#FF7043'];
    return this.bookName ? cs[this.bookName.charCodeAt(0) % cs.length] : cs[0];
  }
}
