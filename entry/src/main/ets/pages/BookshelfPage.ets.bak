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
 * - 点击阅读 / 长按菜单(详情/删除)
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
  @State isLoading: boolean = false;
  @State isRefreshing: boolean = false;
  @State isDark: boolean = false;
  @State activeTabIndex: number = 0;
  @State searchText: string = '';
  @State isListView: boolean = true;
  @State sortMode: number = 0;

  private tabs: string[] = ['全部', '在读', '已完本'];
  private sortLabels: string[] = ['最后阅读', '书名', '更新时间'];

  aboutToAppear(): void {
    this.isDark = AppTheme.getInstance().isDark;
    this.sortMode = AppStorage.get<number>('shelfSortMode') || 0;
    this.loadBooks();
  }

  onPageShow(): void {
    this.loadBooks();
  }

  async loadBooks(): Promise<void> {
    if (!this.isRefreshing) this.isLoading = true;
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
    this.isRefreshing = false;
  }

  async onRefresh(): Promise<void> {
    this.isRefreshing = true;
    await this.loadBooks();
  }

  applyFilters(): void {
    let result = [...this.books];
    if (this.activeTabIndex === 1) {
      result = result.filter(b =>
        b.durChapterIndex > 0 &&
        (b.totalChapterNum <= 0 || b.durChapterIndex < b.totalChapterNum)
      );
    } else if (this.activeTabIndex === 2) {
      result = result.filter(b =>
        b.totalChapterNum > 0 && b.durChapterIndex >= b.totalChapterNum
      );
    }
    if (this.searchText.trim()) {
      const q = this.searchText.trim().toLowerCase();
      result = result.filter(b =>
        b.name.toLowerCase().includes(q) ||
        (b.author && b.author.toLowerCase().includes(q))
      );
    }
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
    AppStorage.set<number>('shelfSortMode', this.sortMode);
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
        tocUrl: book.tocUrl,
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

  showContextMenu(book: Book): void {
    promptAction.showDialog({
      title: book.name,
      message: '作者: ' + (book.author || '未知'),
      buttons: [
        { text: '详情', color: '#0078D7' },
        { text: '删除', color: '#FF5722' },
        { text: '取消', color: '#888' }
      ]
    }).then((res: Object) => {
      const idx = (res as Record<string, Object>)['index'] as number;
      if (idx === 0) {
        router.pushUrl({ url: 'pages/BookInfoPage', params: {
          name: book.name, author: book.author, coverUrl: book.coverUrl,
          noteUrl: book.bookUrl, origin: book.origin, originUrl: book.originUrl,
          introduce: book.introduce || '', kind: book.kind || ''
        }});
      } else if (idx === 1) {
        this.confirmRemove(book);
      }
    });
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
    Column().width('100%').height('100%').backgroundColor(this.isDark ? '#121212' : '#F5F5F5') {
      // 顶部栏
      Row() {
        Text('\uD83D\uDCDA 书架').fontSize(20).fontWeight(FontWeight.Bold)
        Blank()
        if (this.filteredBooks.length > 0) {
          Text(this.filteredBooks.length + '本').fontSize(13).fontColor('#888').margin({ right: 8 })
        }
        Button('\uD83D\uDD0D 搜书').fontSize(14).fontColor('#FFF')
          .height(32).padding({ left: 10, right: 10 })
          .backgroundColor('#0078D7').borderRadius(16).margin({ right: 6 })
          .onClick(() => { router.pushUrl({ url: 'pages/SearchPage' }); })
        Button() {
          Text(this.isListView ? '▦' : '☰').fontSize(16).fontColor('#666')
        }.width(36).height(36).backgroundColor('transparent')
        .onClick(() => { this.onLayoutToggle(); })
        Button() {
          Text(this.sortLabels[this.sortMode]).fontSize(12).fontColor('#666')
        }.height(28).padding({ left: 8, right: 8 })
        .backgroundColor(this.isDark ? '#333' : '#E0E0E0').borderRadius(14).margin({ left: 4 })
        .onClick(() => { this.onSortToggle(); })
      }.padding({ left: 16, right: 12, top: 12 }).width('100%')

      // 搜索栏
      TextInput({ placeholder: '搜索书名或作者...', text: this.searchText })
        .width('calc(100% - 32)').height(36).margin({ left: 16, right: 16, top: 8 })
        .padding({ left: 12 }).backgroundColor(this.isDark ? '#333' : '#FFF')
        .borderRadius(18).fontSize(14).placeholderColor('#999')
        .onChange((value: string) => { this.onSearchChange(value); })

      // 分类标签
      Row() {
        ForEach(this.tabs, (tab: string, index: number) => {
          Column() {
            Text(tab).fontSize(14)
              .fontColor(this.activeTabIndex === index ? '#0078D7' : (this.isDark ? '#AAA' : '#888'))
              .fontWeight(this.activeTabIndex === index ? FontWeight.Bold : FontWeight.Normal)
              .padding({ top: 8, bottom: 8 })
            if (this.activeTabIndex === index) {
              Row().width('60%').height(2).backgroundColor('#0078D7').borderRadius(1)
            }
          }.onClick(() => { this.onTabChange(index); }).layoutWeight(1).alignItems(HorizontalAlign.Center)
        })
      }.width('100%').padding({ left: 16, right: 16, top: 4 })

      // 内容
      if (this.isLoading && !this.isRefreshing) {
        LoadingProgress().color('#0078D7').margin({ top: 100 })
      } else if (this.filteredBooks.length === 0) {
        Column() {
          Text('\uD83D\uDCDA').fontSize(64).margin({ top: 100 })
          if (this.searchText) {
            Text('没有匹配的书籍').fontSize(16).fontColor('#888').margin({ top: 12 })
            Text('试试其他关键词').fontSize(13).fontColor('#AAA').margin({ top: 4 })
          } else if (this.activeTabIndex > 0) {
            Text('该分类下没有书籍').fontSize(16).fontColor('#888').margin({ top: 12 })
            Text('去搜索添加书籍吧').fontSize(13).fontColor('#AAA').margin({ top: 4 })
          } else {
            Text('书架是空的').fontSize(16).fontColor('#888').margin({ top: 12 })
            Text('去搜索添加书籍吧').fontSize(13).fontColor('#AAA').margin({ top: 4 })
          }
        }.width('100%').alignItems(HorizontalAlign.Center).layoutWeight(1)
      } else {
        Refresh({ refreshing: this.isRefreshing }) {
          if (this.isListView) {
            List() {
              ForEach(this.filteredBooks, (book: Book) => {
                ListItem() {
                  this.buildListItem(book)
                }.border({ width: { bottom: 1 }, color: this.isDark ? '#333' : '#E8E8E8' })
                .onClick(() => { this.continueRead(book); })
                .gesture(LongPressGesture().onAction(() => { this.showContextMenu(book); }))
              })
            }.width('100%').margin({ top: 4 })
          } else {
            Grid() {
              ForEach(this.filteredBooks, (book: Book) => {
                GridItem() {
                  this.buildGridItem(book)
                }.onClick(() => { this.continueRead(book); })
                .gesture(LongPressGesture().onAction(() => { this.showContextMenu(book); }))
              })
            }.columnsTemplate('1fr 1fr 1fr').columnsGap(8).rowsGap(8)
            .padding({ left: 16, right: 16, top: 8 })
          }
        }.layoutWeight(1).width('100%').onRefreshing(() => { this.onRefresh(); }).refreshOffset(64)
      }
    }
  }

  @Builder
  buildListItem(book: Book) {
    Row() {
      BookCover({ name: book.name, coverUrl: book.coverUrl, coverWidth: 52, coverHeight: 70 }).margin({ right: 12 })
      Column() {
        Row() {
          Text(book.name).fontSize(15).fontWeight(FontWeight.Bold)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          if (this.getNewChaptersCount(book) > 0) {
            Text('+' + this.getNewChaptersCount(book))
              .fontSize(10).fontColor('#FFF').fontWeight(FontWeight.Bold)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .backgroundColor('#F44336').borderRadius(8).margin({ left: 4 })
          }
        }.width('100%').alignItems(VerticalAlign.Center)
        Text(book.author || '未知作者').fontSize(12).fontColor('#888')
          .alignSelf(ItemAlign.Start).margin({ top: 2 })
        if (book.durChapterTitle) {
          Text(book.durChapterTitle).fontSize(11).fontColor('#AAA')
            .alignSelf(ItemAlign.Start).margin({ top: 1 })
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }
        if (book.latestChapterTitle && book.latestChapterTitle !== book.durChapterTitle) {
          Text('最新: ' + book.latestChapterTitle).fontSize(11)
            .fontColor(this.isDark ? '#009688' : '#00897B')
            .alignSelf(ItemAlign.Start).margin({ top: 1 })
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }
        Row() {
          Row().width(this.getProgressPercent(book) + '%').height(3).backgroundColor('#0078D7').borderRadius(2)
        }.width('100%').height(3).margin({ top: 3 }).backgroundColor(this.isDark ? '#444' : '#E0E0E0').borderRadius(2)
        Row() {
          if (book.lastOpenTime > 0) Text(this.formatTime(book.lastOpenTime)).fontSize(10).fontColor('#999')
          Blank()
          if (book.totalChapterNum > 0) {
            Text(book.durChapterIndex + '/' + book.totalChapterNum + ' (' + this.getProgressPercent(book) + '%)')
              .fontSize(10).fontColor('#999')
          }
        }.width('100%').margin({ top: 2 })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start).height(72).justifyContent(FlexAlign.Center)
      Button() { Text('✕').fontSize(14).fontColor('#F44336') }
        .width(36).height(36).backgroundColor('transparent')
        .onClick(() => { this.confirmRemove(book); })
    }.padding({ left: 12, right: 4 }).width('100%')
  }

  @Builder
  buildGridItem(book: Book) {
    Column() {
      Stack() {
        BookCover({ name: book.name, coverUrl: book.coverUrl, coverWidth: 120, coverHeight: 168 })
        if (this.getNewChaptersCount(book) > 0) {
          Text('+' + this.getNewChaptersCount(book))
            .fontSize(10).fontColor('#FFF').fontWeight(FontWeight.Bold)
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .backgroundColor('#F44336').borderRadius(8).position({ top: 4, right: 4 })
        }
      }.width('100%').height(172)
      Text(book.name).fontSize(13).fontWeight(FontWeight.Medium)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        .margin({ top: 4 }).fontColor(this.isDark ? '#CCC' : '#333')
      Text(book.author || '未知作者').fontSize(11).fontColor('#888')
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
    }.width('100%').onClick(() => { this.continueRead(book); })
  }
}
