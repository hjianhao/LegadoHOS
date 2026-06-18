/**
 * 书架页面 — 完整功能版（参照 legado-with-MD3）
 *
 * 功能：
 * - 分组标签：全部 / 在读 / 已完本
 * - 搜索过滤（书名 + 作者）
 * - 排序切换：最后阅读 / 书名 / 更新时间
 * - 布局切换：列表 / 网格（3列）
 * - 每个条目：封面、书名、作者、当前章节、最新章节、更新数徽章、进度条
 * - 点击阅读 / 点击✕移除
 */
import { Book } from '../model/Book';
import { AppTheme } from '../theme/AppTheme';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookTable } from '../data/database/BookTable';
import { BookCover } from '../components/BookCover';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';

@Component
export struct BookshelfPage {
  @State books: Book[] = [];
  @State filteredBooks: Book[] = [];
  @State isLoading: boolean = true;
  @State isDark: boolean = false;
  @State activeTabIndex: number = 0;
  @State searchText: string = '';
  @State isListView: boolean = true;
  @State sortMode: number = 0;

  private tabs: string[] = ['全部', '在读', '已完本'];
  private sortLabels: string[] = ['最后阅读', '书名', '更新时间'];

  aboutToAppear(): void {
    this.isDark = AppTheme.getInstance().isDark;
    this.loadBooks();
  }

  onPageShow(): void {
    this.loadBooks();
  }

  async loadBooks(): Promise<void> {
    this.isLoading = true;
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const bookDao = new BookTable(db);
      const result = await bookDao.getAllShelfBooks();
      this.books = result;
      this.applyFilters();
    } catch (e) {
      console.error('[Bookshelf] load error:', e);
    }
    this.isLoading = false;
  }

  applyFilters(): void {
    let result = [...this.books];

    // 分组过滤
    if (this.activeTabIndex === 1) {
      // 在读：有阅读进度但未读完
      result = result.filter(b =>
        b.durChapterIndex > 0 &&
        (b.totalChapterNum <= 0 || b.durChapterIndex < b.totalChapterNum)
      );
    } else if (this.activeTabIndex === 2) {
      // 已完本：已读完
      result = result.filter(b =>
        b.totalChapterNum > 0 && b.durChapterIndex >= b.totalChapterNum
      );
    }

    // 搜索过滤
    if (this.searchText.trim()) {
      const q = this.searchText.trim().toLowerCase();
      result = result.filter(b =>
        b.name.toLowerCase().includes(q) ||
        (b.author && b.author.toLowerCase().includes(q))
      );
    }

    // 排序
    if (this.sortMode === 0) {
      result.sort((a, b) => (b.lastOpenTime || 0) - (a.lastOpenTime || 0));
    } else if (this.sortMode === 1) {
      result.sort((a, b) => a.name.localeCompare(b.name));
    } else if (this.sortMode === 2) {
      result.sort((a, b) => (b.lastUpdateTime || '').localeCompare(a.lastUpdateTime || ''));
    }

    this.filteredBooks = result;
  }

  onTabChange(index: number): void {
    this.activeTabIndex = index;
    this.applyFilters();
  }

  onSearchChange(value: string): void {
    this.searchText = value;
    this.applyFilters();
  }

  onSortToggle(): void {
    this.sortMode = (this.sortMode + 1) % 3;
    this.applyFilters();
  }

  onLayoutToggle(): void {
    this.isListView = !this.isListView;
  }

  getNewChaptersCount(book: Book): number {
    const count = (book.totalChapterNum || 0) - (book.durChapterIndex || 0);
    return count > 0 ? count : 0;
  }

  continueRead(book: Book): void {
    router.pushUrl({
      url: 'pages/ReadPage',
      params: {
        name: book.name, author: book.author, coverUrl: book.coverUrl,
        bookUrl: book.bookUrl, origin: book.origin, originUrl: book.originUrl,
        durChapterIndex: book.durChapterIndex,
        durChapterTitle: book.durChapterTitle,
        durChapterPos: book.durChapterPos,
        introduce: book.introduce, kind: book.kind, wordCount: book.wordCount,
      }
    });
  }

  async removeFromShelf(book: Book): Promise<void> {
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const bookDao = new BookTable(db);
      book.isShelf = false;
      await bookDao.updateBook(book);
      promptAction.showToast({ message: '已从书架移除', duration: 1500 });
      this.loadBooks();
    } catch (e) {
      console.error('[Bookshelf] remove error:', e);
    }
  }

  confirmRemove(book: Book): void {
    promptAction.showDialog({
      title: '移除书籍',
      message: `确定将《${book.name}》从书架移除吗？`,
      buttons: [
        { text: '取消', color: '#888' },
        { text: '移除', color: '#F44336' }
      ]
    }).then((result) => {
      if (result.index === 1) this.removeFromShelf(book);
    });
  }

  getCoverColor(name: string): string {
    const colors = ['#455A64', '#5C6BC0', '#26A69A', '#EC407A', '#AB47BC',
      '#42A5F5', '#66BB6A', '#FF7043', '#8D6E63', '#78909C', '#7E57C2', '#29B6F6'];
    if (!name) return colors[0];
    return colors[name.charCodeAt(0) % colors.length];
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

  build() {
    Column()
    .width('100%').height('100%')
    .backgroundColor(this.isDark ? '#121212' : '#F5F5F5')
    {
      // ===== 顶部栏 =====
      Row() {
        Text('\uD83D\uDCDA 书架').fontSize(20).fontWeight(FontWeight.Bold)
        Blank()
        if (this.filteredBooks.length > 0) {
          Text(this.filteredBooks.length + '本').fontSize(13).fontColor('#888').margin({ right: 8 })
        }
        // 布局切换
        Button() {
          Text(this.isListView ? '▦' : '☰').fontSize(16).fontColor('#666')
        }
        .width(36).height(36).backgroundColor('transparent')
        .onClick(() => { this.onLayoutToggle(); })
        // 排序切换
        Button() {
          Text(this.sortLabels[this.sortMode]).fontSize(12).fontColor('#666')
        }
        .height(28).padding({ left: 8, right: 8 })
        .backgroundColor(this.isDark ? '#333' : '#E0E0E0')
        .borderRadius(14).margin({ left: 4 })
        .onClick(() => { this.onSortToggle(); })
      }.padding({ left: 16, right: 12, top: 12 }).width('100%')

      // ===== 搜索栏 =====
      TextInput({ placeholder: '搜索书名或作者...', text: this.searchText })
        .width('calc(100% - 32)').height(36).margin({ left: 16, right: 16, top: 8 })
        .padding({ left: 12 })
        .backgroundColor(this.isDark ? '#333' : '#FFF')
        .borderRadius(18).fontSize(14)
        .placeholderColor('#999')
        .onChange((value: string) => { this.onSearchChange(value); })

      // ===== 分类标签 =====
      Row() {
        ForEach(this.tabs, (tab: string, index: number) => {
          Column() {
            Text(tab).fontSize(14)
              .fontColor(this.activeTabIndex === index
                ? '#0078D7'
                : (this.isDark ? '#AAA' : '#888'))
              .fontWeight(this.activeTabIndex === index ? FontWeight.Bold : FontWeight.Normal)
              .padding({ top: 8, bottom: 8 })
            // 下划线
            if (this.activeTabIndex === index) {
              Row().width('60%').height(2).backgroundColor('#0078D7').borderRadius(1)
            }
          }
          .onClick(() => { this.onTabChange(index); })
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)
        })
      }.width('100%').padding({ left: 16, right: 16, top: 4 })

      // ===== 内容区域 =====
      if (this.isLoading) {
        LoadingProgress().color('#0078D7').margin({ top: 100 })
      } else if (this.filteredBooks.length === 0) {
        Column() {
          Text('\uD83D\uDCDA').fontSize(64).margin({ top: 100 })
          if (this.searchText) {
            Text('没有匹配的书籍').fontSize(16).fontColor('#888').margin({ top: 12 })
            Text('试试其他关键词').fontSize(13).fontColor('#AAA').margin({ top: 4 })
          } else if (this.activeTabIndex > 0) {
            Text('该分类下没有书籍').fontSize(16).fontColor('#888').margin({ top: 12 })
            Text('去发现页搜索添加书籍吧').fontSize(13).fontColor('#AAA').margin({ top: 4 })
          } else {
            Text('书架是空的').fontSize(16).fontColor('#888').margin({ top: 12 })
            Text('去发现页搜索添加书籍吧').fontSize(13).fontColor('#AAA').margin({ top: 4 })
          }
        }.width('100%').alignItems(HorizontalAlign.Center).layoutWeight(1)
      } else if (this.isListView) {
        // ----- 列表视图 -----
        List() {
          ForEach(this.filteredBooks, (book: Book) => {
            ListItem() {
              this.buildListItem(book)
            }
            .border({ width: { bottom: 1 }, color: this.isDark ? '#333' : '#E8E8E8' })
            .onClick(() => { this.continueRead(book); })
          })
        }.width('100%').layoutWeight(1).margin({ top: 4 })
      } else {
        // ----- 网格视图 -----
        Grid() {
          ForEach(this.filteredBooks, (book: Book) => {
            GridItem() {
              this.buildGridItem(book)
            }
            .onClick(() => { this.continueRead(book); })
          })
        }
        .columnsTemplate('1fr 1fr 1fr')
        .columnsGap(8)
        .rowsGap(8)
        .padding({ left: 16, right: 16, top: 8 })
        .layoutWeight(1)
      }
    }
  }

  @Builder
  buildListItem(book: Book) {
    Row() {
      // 封面
      BookCover({
        name: book.name,
        coverUrl: book.coverUrl,
        coverWidth: 52,
        coverHeight: 70
      }).margin({ right: 12 })

      // 文字信息
      Column() {
        // 第一行：书名 + 新章节徽章
        Row() {
          Text(book.name).fontSize(15).fontWeight(FontWeight.Bold)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          if (this.getNewChaptersCount(book) > 0) {
            Text('+' + this.getNewChaptersCount(book))
              .fontSize(10).fontColor('#FFF').fontWeight(FontWeight.Bold)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .backgroundColor('#F44336').borderRadius(8)
              .margin({ left: 4 })
          }
        }.width('100%').alignItems(VerticalAlign.Center)

        // 作者
        Text(book.author || '未知作者').fontSize(12).fontColor('#888')
          .alignSelf(ItemAlign.Start).margin({ top: 2 })

        // 当前章节
        if (book.durChapterTitle) {
          Text(book.durChapterTitle).fontSize(11).fontColor('#AAA')
            .alignSelf(ItemAlign.Start).margin({ top: 1 })
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }

        // 最新章节（与当前不同时才显示）
        if (book.latestChapterTitle &&
            book.latestChapterTitle !== book.durChapterTitle) {
          Text('最新: ' + book.latestChapterTitle).fontSize(11)
            .fontColor(this.isDark ? '#009688' : '#00897B')
            .alignSelf(ItemAlign.Start).margin({ top: 1 })
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }

        // 进度条
        Row() {
          Row().width(this.getProgressPercent(book) + '%').height(3)
            .backgroundColor('#0078D7').borderRadius(2)
        }
        .width('100%').height(3).margin({ top: 3 })
        .backgroundColor(this.isDark ? '#444' : '#E0E0E0').borderRadius(2)

        // 底部：时间 + 进度文字
        Row() {
          if (book.lastOpenTime > 0) {
            Text(this.formatTime(book.lastOpenTime)).fontSize(10).fontColor('#999')
          }
          Blank()
          if (book.totalChapterNum > 0) {
            Text(book.durChapterIndex + '/' + book.totalChapterNum +
                 ' (' + this.getProgressPercent(book) + '%)')
              .fontSize(10).fontColor('#999')
          }
        }.width('100%').margin({ top: 2 })
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start)
      .height(72).justifyContent(FlexAlign.Center)

      // 删除按钮
      Button() { Text('✕').fontSize(14).fontColor('#F44336') }
        .width(36).height(36).backgroundColor('transparent')
        .onClick(() => { this.confirmRemove(book); })
    }.padding({ left: 12, right: 4 }).width('100%')
  }

  @Builder
  buildGridItem(book: Book) {
    Column() {
      // 封面区
      Stack() {
        BookCover({
          name: book.name,
          coverUrl: book.coverUrl,
          coverWidth: 120,
          coverHeight: 168
        })

        // 新章节徽章
        if (this.getNewChaptersCount(book) > 0) {
          Text('+' + this.getNewChaptersCount(book))
            .fontSize(10).fontColor('#FFF').fontWeight(FontWeight.Bold)
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .backgroundColor('#F44336').borderRadius(8)
            .position({ top: 4, right: 4 })
        }

        // 底部进度条浮层
        if (book.totalChapterNum > 0 && this.getProgressPercent(book) > 0) {
          Row() {
            Row().width(this.getProgressPercent(book) + '%').height(3)
              .backgroundColor('#0078D7').borderRadius(2)
          }
          .width('100%').height(3)
          .backgroundColor('#00000033').borderRadius(2)
          .position({ bottom: 0 })
        }
      }

      // 书名
      Text(book.name).fontSize(13).fontWeight(FontWeight.Medium)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        .margin({ top: 4 }).fontColor(this.isDark ? '#CCC' : '#333')

      // 作者
      Text(book.author || '未知作者').fontSize(11).fontColor('#888')
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
    }
    .width('100%')
  }
}
