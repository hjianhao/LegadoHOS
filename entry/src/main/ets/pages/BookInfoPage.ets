import { AppTheme } from '../theme/AppTheme';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookTable } from '../data/database/BookTable';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { Book, BookType, BookGroup } from '../model/Book';
import { BookSource } from '../model/BookSource';
import { Chapter } from '../model/Chapter';
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
    // 尝试从详情页提取封面
    this.tryFetchCover();
    this.isLoading = false;
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
        chapterCount: 0,
        totalChapterNum: 0,
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

  changeSource(): void {
    promptAction.showToast({ message: '换源功能开发中', duration: 1500 });
  }

  build() {
    Column() {
      // 顶部导航栏
      Row() {
        Button() {
          Text('←').fontSize(18).fontColor(this.isDark ? '#FFF' : '#333')
        }
        .width(40).height(40).backgroundColor('transparent')
        .onClick((): void => { router.back(); })
        Text('书籍详情').fontSize(18).fontWeight(FontWeight.Bold).margin({ left: 8 })
        Blank()
      }.width('100%').padding(12)

      Scroll() {
        Column() {
          // 书籍信息头部
          Row() {
            // 书籍封面
            BookCover({
              name: this.bookName,
              coverUrl: this.coverUrl,
              coverWidth: 110,
              coverHeight: 155
            }).margin({ right: 16 })

            Column() {
              Text(this.bookName).fontSize(18).fontWeight(FontWeight.Bold)
                .alignSelf(ItemAlign.Start).maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis }).lineHeight(24)
              Text(this.bookAuthor).fontSize(14).fontColor('#888')
                .alignSelf(ItemAlign.Start).margin({ top: 4 })
              if (this.origin) {
                Text('来源: ' + this.origin).fontSize(12).fontColor('#AAA')
                  .alignSelf(ItemAlign.Start).margin({ top: 4 })
              }
              if (this.kind) {
                Text(this.kind).fontSize(12).fontColor('#0078D7')
                  .alignSelf(ItemAlign.Start).margin({ top: 4 })
              }
              if (this.wordCount) {
                Text(this.wordCount).fontSize(12).fontColor('#888')
                  .alignSelf(ItemAlign.Start).margin({ top: 2 })
              }
            }
            .layoutWeight(1).alignItems(HorizontalAlign.Start)
          }.width('100%').padding(16)

          // 操作按钮
          Row() {
            Button(this.isInShelf ? '已在书架' : '+ 加入书架')
              .fontSize(13).height(38).layoutWeight(1).margin({ right: 4 })
              .backgroundColor(this.isInShelf ? '#999' : '#0078D7').fontColor('#FFF')
              .borderRadius(19).enabled(!this.isInShelf)
              .onClick((): void => { this.addToShelf() })

            Button('开始阅读').fontSize(13).height(38).layoutWeight(1).margin({ left: 4, right: 4 })
              .backgroundColor('#4CAF50').fontColor('#FFF').borderRadius(19)
              .onClick((): void => { this.startRead() })

            Button('换源').fontSize(13).height(38).layoutWeight(1).margin({ left: 4 })
              .backgroundColor('#FF9800').fontColor('#FFF').borderRadius(19)
              .onClick((): void => { this.changeSource() })
          }
          .width('100%').padding({ left: 16, right: 16, bottom: 12 })

          // 简介
          if (this.introduce) {
            Column() {
              Text('简介').fontSize(15).fontWeight(FontWeight.Bold)
                .alignSelf(ItemAlign.Start).margin({ bottom: 6 })
              Text(this.introduce).fontSize(13).fontColor('#666')
                .lineHeight(20).alignSelf(ItemAlign.Start)
            }.width('100%').padding(16).alignItems(HorizontalAlign.Start)
          }
        }.width('100%')
      }
      .layoutWeight(1).width('100%')
    }
    .width('100%').height('100%')
    .backgroundColor(this.isDark ? '#121212' : '#F5F5F5')
  }
}
