/** 优书网发现：书库板块。 */
import { ThemeColors } from '../theme/ThemeColors';
import { UiUtil } from '../util/UiUtil';
import {
  YOUSHU_BOOKS_URL,
  YoushuBookItem,
  YoushuBookPage,
  YoushuBookService,
  YoushuFilterGroup,
  YoushuFilterOption,
} from '../service/YoushuBookService';
import { YoushuBooklistPage } from './YoushuBooklistPage';

@Component
export struct YoushuExplorePage {
  @StorageLink('isDark') isDark: boolean = false;
  @State selectedSection: number = 0;

  build() {
    Column() {
      Tabs({ barPosition: BarPosition.Start, index: this.selectedSection }) {
        TabContent() {
          YoushuLibraryPage()
        }.tabBar(this.buildSection('书库', 0))
        TabContent() {
          YoushuBooklistPage()
        }.tabBar(this.buildSection('书单', 1))
      }
      .width('100%').layoutWeight(1).barHeight(50).scrollable(false)
      .backgroundColor(ThemeColors.background(this.isDark))
      .onChange((index: number): void => { this.selectedSection = index; })
    }.width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
  }

  @Builder
  private buildSection(label: string, index: number) {
    Text(label).fontSize(13).fontWeight(this.selectedSection === index ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.selectedSection === index ? ThemeColors.primary(this.isDark) : ThemeColors.secondaryText(this.isDark))
      .height(44).padding({ left: 20, right: 20 }).textAlign(TextAlign.Center)
      .border({ width: this.selectedSection === index ? 1 : 0,
        color: ThemeColors.primary(this.isDark) }).borderRadius(22)
      .accessibilityText(label).accessibilityDescription('双击切换到优书网' + label)
  }
}

@Component
struct YoushuLibraryPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State filters: YoushuFilterGroup[] = [];
  @State books: YoushuBookItem[] = [];
  @State currentUrl: string = YOUSHU_BOOKS_URL;
  @State nextPageUrl: string = '';
  @State pageStats: string = '';
  @State isLoading: boolean = true;
  @State isRefreshing: boolean = false;
  @State isLoadingMore: boolean = false;
  @State filterExpanded: boolean = true;
  @State errorMessage: string = '';

  private requestId: number = 0;
  private isActive: boolean = false;

  aboutToAppear(): void {
    this.isActive = true;
    if (this.books.length === 0) void this.loadPage(YOUSHU_BOOKS_URL, false);
  }

  aboutToDisappear(): void {
    this.isActive = false;
    this.requestId++;
  }

  private async loadPage(url: string, append: boolean): Promise<void> {
    if (append) {
      if (this.isLoadingMore || !url) return;
      this.isLoadingMore = true;
    } else {
      this.isLoading = !this.isRefreshing;
      this.errorMessage = '';
    }
    const runId = ++this.requestId;
    try {
      const page = await YoushuBookService.loadPage(url);
      if (!this.isActive || runId !== this.requestId) return;
      this.applyPage(page, append);
    } catch (e) {
      if (!this.isActive || runId !== this.requestId) return;
      this.errorMessage = (e as Error).message || '加载失败';
      if (append) {
        UiUtil.showToast(this.getUIContext(), { message: '下一页加载失败', duration: 1500 });
      }
    } finally {
      if (this.isActive && runId === this.requestId) {
        this.isLoading = false;
        this.isRefreshing = false;
        this.isLoadingMore = false;
      }
    }
  }

  private applyPage(page: YoushuBookPage, append: boolean): void {
    this.filters = page.filters;
    this.books = append ? [...this.books, ...page.books] : page.books;
    this.currentUrl = page.currentUrl;
    this.nextPageUrl = page.nextPageUrl;
    this.pageStats = page.pageStats;
    this.errorMessage = '';
  }

  private refresh(): void {
    this.isRefreshing = true;
    void this.loadPage(this.currentUrl || YOUSHU_BOOKS_URL, false);
  }

  private selectFilter(option: YoushuFilterOption): void {
    if (option.selected || this.isLoading) return;
    this.books = [];
    this.nextPageUrl = '';
    void this.loadPage(option.url, false);
  }

  private openSearch(book: YoushuBookItem): void {
    UiUtil.pushUrl(this.getUIContext(), {
      url: 'pages/SearchPage',
      params: { key: book.author ? book.name + ' ' + book.author : book.name,
        bookName: book.name, author: book.author }
    });
  }

  build() {
    Column() {
      Row() {
        Column() {
          Text($r('app.string.ui_2c598c6710')).fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor(ThemeColors.onBackground(this.isDark))
          Text($r('app.string.ui_74b2e1c7af'))
            .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 2 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button(this.filterExpanded ? '收起筛选' : '展开筛选')
          .fontSize(12).fontColor(ThemeColors.primary(this.isDark))
          .height(44).backgroundColor(Color.Transparent)
          .accessibilityText(this.filterExpanded ? '收起筛选条件' : '展开筛选条件')
          .onClick((): void => { this.filterExpanded = !this.filterExpanded; })
      }.width('100%').padding({ left: 16, right: 16, top: 10, bottom: 8 })

      if (this.isLoading && this.books.length === 0) {
        Column() {
          LoadingProgress().width(32).height(32).color(ThemeColors.primary(this.isDark))
          Text($r('app.string.ui_ef45ebc684')).fontSize(13)
            .fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 10 })
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else if (this.errorMessage && this.books.length === 0) {
        Column() {
          Text($r('app.string.ui_2f3e5c58fd')).fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.onBackground(this.isDark))
          Text(this.errorMessage).fontSize(12).fontColor(ThemeColors.error(this.isDark))
            .margin({ top: 8 }).padding({ left: 24, right: 24 }).textAlign(TextAlign.Center)
          Button($r('app.string.common_retry')).margin({ top: 16 })
            .onClick((): void => { void this.loadPage(this.currentUrl || YOUSHU_BOOKS_URL, false); })
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else {
        Refresh({ refreshing: $$this.isRefreshing }) {
          List({ space: 8 }) {
            if (this.filterExpanded) {
              ListItem() {
                Column() {
                  ForEach(this.filters, (group: YoushuFilterGroup) => {
                    this.buildFilterGroup(group)
                  }, (group: YoushuFilterGroup): string => group.name)
                }
                .width('100%').padding({ left: 12, right: 12, top: 10, bottom: 4 })
                .backgroundColor(ThemeColors.surface(this.isDark)).borderRadius(12)
                .border({ width: 1, color: ThemeColors.outlineVariant(this.isDark) })
              }.margin({ left: 12, right: 12, bottom: 4 })
            }

            ListItem() {
              Row() {
                Text('作品列表 · ' + this.books.length.toString() + ' 条已加载')
                  .fontSize(13).fontWeight(FontWeight.Medium)
                  .fontColor(ThemeColors.onBackground(this.isDark)).layoutWeight(1)
                if (this.pageStats) {
                  Text(this.pageStats).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
                }
              }.width('100%').padding({ left: 16, right: 16, top: 4, bottom: 2 })
            }

            ForEach(this.books, (book: YoushuBookItem) => {
              ListItem() { this.buildBookRow(book) }
            }, (book: YoushuBookItem): string => book.id)

            if (this.isLoadingMore) {
              ListItem() {
                Row() {
                  LoadingProgress().width(20).height(20).color(ThemeColors.primary(this.isDark))
                  Text($r('app.string.ui_d5d58840ea')).fontSize(12)
                    .fontColor(ThemeColors.secondaryText(this.isDark)).margin({ left: 8 })
                }.width('100%').justifyContent(FlexAlign.Center).padding(16)
              }
            } else if (!this.nextPageUrl && this.books.length > 0) {
              ListItem() {
                Text($r('app.string.ui_3471e133fa')).width('100%').textAlign(TextAlign.Center).fontSize(12)
                  .fontColor(ThemeColors.secondaryText(this.isDark)).padding(16)
              }
            }
          }
          .layoutWeight(1).width('100%')
          .onReachEnd((): void => { void this.loadPage(this.nextPageUrl, true); })
        }
        .layoutWeight(1).width('100%')
        .onRefreshing((): void => { this.refresh(); })
      }
    }
    .width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
  }

  @Builder
  private buildFilterGroup(group: YoushuFilterGroup) {
    Column() {
      Text(group.name).fontSize(12).fontWeight(FontWeight.Medium)
        .fontColor(ThemeColors.secondaryText(this.isDark)).alignSelf(ItemAlign.Start)
        .margin({ left: 4, bottom: 6 })
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(group.options, (option: YoushuFilterOption) => {
          Text(option.name).fontSize(12)
            .fontColor(option.selected ? ThemeColors.onPrimary(this.isDark) : ThemeColors.onSurface(this.isDark))
            .backgroundColor(option.selected ? ThemeColors.primary(this.isDark) : ThemeColors.surfaceVariant(this.isDark))
            .borderRadius(14).padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .constraintSize({ minHeight: 44 })
            .accessibilityText(group.name + '：' + option.name)
            .margin({ right: 6, bottom: 7 })
            .onClick((): void => { this.selectFilter(option); })
        }, (option: YoushuFilterOption): string => option.url)
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).margin({ bottom: 4 })
  }

  @Builder
  private buildBookRow(book: YoushuBookItem) {
    Column() {
      Row() {
        Text(book.name).fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.onSurface(this.isDark)).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        Text(book.status).fontSize(11).fontColor(ThemeColors.primary(this.isDark))
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).borderRadius(8)
      }.width('100%')
      Row() {
        Text('评分 ' + book.rating + ' · ' + book.ratingCount).layoutWeight(1)
          .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
        Text('作者 ' + (book.author || '-')).layoutWeight(1)
          .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
      }.width('100%').margin({ top: 7 })
      Row() {
        Text('总点击 ' + (book.totalVisits || '-')).layoutWeight(1)
          .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
        Text('更新 ' + (book.lastUpdate || '-')).layoutWeight(1)
          .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
      }.width('100%').margin({ top: 5 })
    }
    .width('100%').padding(14)
    .backgroundColor(ThemeColors.surface(this.isDark)).borderRadius(12)
    .border({ width: 1, color: ThemeColors.outlineVariant(this.isDark) })
    .margin({ left: 12, right: 12 })
    .onClick((): void => { this.openSearch(book); })
  }
}
