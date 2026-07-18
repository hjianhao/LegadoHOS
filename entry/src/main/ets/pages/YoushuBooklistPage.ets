/** 优书网发现：书单列表板块。 */
import { ThemeColors } from '../theme/ThemeColors';
import { UiUtil } from '../util/UiUtil';
import { YoushuLoginDialog } from '../components/YoushuLoginDialog';
import {
  YOUSHU_BOOKLISTS_URL,
  YoushuBooklistItem,
  YoushuBooklistPage as YoushuBooklistPageData,
  YoushuBooklistService,
} from '../service/YoushuBooklistService';
import { YoushuFilterGroup, YoushuFilterOption } from '../service/YoushuBookService';

@Component
export struct YoushuBooklistPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State filters: YoushuFilterGroup[] = [];
  @State booklists: YoushuBooklistItem[] = [];
  @State currentUrl: string = YOUSHU_BOOKLISTS_URL;
  @State nextPageUrl: string = '';
  @State pageStats: string = '';
  @State isLoading: boolean = true;
  @State isRefreshing: boolean = false;
  @State isLoadingMore: boolean = false;
  @State filterExpanded: boolean = true;
  @State loggedIn: boolean = false;
  @State errorMessage: string = '';

  private requestId: number = 0;
  private isActive: boolean = false;
  private loginDialog?: CustomDialogController;

  aboutToAppear(): void {
    this.isActive = true;
    if (this.booklists.length === 0) void this.loadPage(YOUSHU_BOOKLISTS_URL, false);
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
      const page = await YoushuBooklistService.loadPage(url);
      if (!this.isActive || runId !== this.requestId) return;
      this.applyPage(page, append);
    } catch (e) {
      if (!this.isActive || runId !== this.requestId) return;
      this.errorMessage = (e as Error).message || '加载失败';
      if (append) UiUtil.showToast(this.getUIContext(), { message: '下一页加载失败', duration: 1500 });
    } finally {
      if (this.isActive && runId === this.requestId) {
        this.isLoading = false;
        this.isRefreshing = false;
        this.isLoadingMore = false;
      }
    }
  }

  private applyPage(page: YoushuBooklistPageData, append: boolean): void {
    this.filters = page.filters;
    this.booklists = append ? [...this.booklists, ...page.booklists] : page.booklists;
    this.currentUrl = page.currentUrl;
    this.nextPageUrl = page.nextPageUrl;
    this.pageStats = page.pageStats;
    this.loggedIn = page.loggedIn;
    this.errorMessage = '';
  }

  private refresh(): void {
    this.isRefreshing = true;
    void this.loadPage(this.currentUrl || YOUSHU_BOOKLISTS_URL, false);
  }

  private selectFilter(option: YoushuFilterOption): void {
    if (option.selected || this.isLoading) return;
    this.booklists = [];
    this.nextPageUrl = '';
    void this.loadPage(option.url, false);
  }

  private openDetail(item: YoushuBooklistItem): void {
    UiUtil.pushUrl(this.getUIContext(), {
      url: 'pages/YoushuBooklistDetailPage', params: { detailUrl: item.detailUrl, title: item.title }
    });
  }

  private openLogin(): void {
    this.loginDialog = new CustomDialogController({
      builder: YoushuLoginDialog({
        controller: this.loginDialog!,
        onLoginSuccess: (): void => {
          if (this.isActive) void this.loadPage(this.currentUrl || YOUSHU_BOOKLISTS_URL, false);
        }
      }),
      autoCancel: true,
      customStyle: true,
      alignment: DialogAlignment.Center,
    });
    this.loginDialog.open();
  }

  private async logout(): Promise<void> {
    await YoushuBooklistService.logout();
    this.loggedIn = false;
    UiUtil.showToast(this.getUIContext(), { message: '已退出优书网登录', duration: 1500 });
    void this.loadPage(YOUSHU_BOOKLISTS_URL, false);
  }

  build() {
    Column() {
      Row() {
        Column() {
          Text($r('app.string.ui_6938ad92fa')).fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor(ThemeColors.onBackground(this.isDark))
          Text($r('app.string.ui_df517e0dd3'))
            .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 2 })
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button(this.loggedIn ? '已登录' : '登录').fontSize(12).height(44)
          .fontColor(this.loggedIn ? ThemeColors.primary(this.isDark) : ThemeColors.onPrimary(this.isDark))
          .backgroundColor(this.loggedIn ? ThemeColors.surfaceVariant(this.isDark) : ThemeColors.primary(this.isDark))
          .borderRadius(16).padding({ left: 12, right: 12 })
          .onClick((): void => {
            if (this.loggedIn) {
              UiUtil.showAlertDialog(this.getUIContext(), {
                title: '优书网账号', message: '当前已登录，是否退出登录？',
                primaryButton: { value: '取消', action: (): void => {} },
                secondaryButton: { value: '退出', fontColor: ThemeColors.error(this.isDark),
                  action: (): void => { void this.logout(); } }
              });
            } else {
              this.openLogin();
            }
          })
        Button(this.filterExpanded ? '收起筛选' : '展开筛选').fontSize(12).height(44)
          .fontColor(ThemeColors.primary(this.isDark)).margin({ left: 10 })
          .backgroundColor(Color.Transparent)
          .accessibilityText(this.filterExpanded ? '收起筛选条件' : '展开筛选条件')
          .onClick((): void => { this.filterExpanded = !this.filterExpanded; })
      }.width('100%').padding({ left: 16, right: 16, top: 10, bottom: 8 })

      if (this.isLoading && this.booklists.length === 0) {
        Column() {
          LoadingProgress().width(32).height(32).color(ThemeColors.primary(this.isDark))
          Text($r('app.string.ui_d11ef1d8a3')).fontSize(13)
            .fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 10 })
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else if (this.errorMessage && this.booklists.length === 0) {
        Column() {
          Text($r('app.string.ui_b1ea604569')).fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.onBackground(this.isDark))
          Text(this.errorMessage).fontSize(12).fontColor(ThemeColors.error(this.isDark))
            .margin({ top: 8 }).padding({ left: 24, right: 24 }).textAlign(TextAlign.Center)
          Button($r('app.string.common_retry')).margin({ top: 16 })
            .onClick((): void => { void this.loadPage(this.currentUrl || YOUSHU_BOOKLISTS_URL, false); })
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
                }.width('100%').padding({ left: 12, right: 12, top: 10, bottom: 4 })
                  .backgroundColor(ThemeColors.surface(this.isDark)).borderRadius(12)
                  .border({ width: 1, color: ThemeColors.outlineVariant(this.isDark) })
              }.margin({ left: 12, right: 12, bottom: 4 })
            }
            ListItem() {
              Row() {
                Text('书单列表 · ' + this.booklists.length.toString() + ' 条已加载').layoutWeight(1)
                  .fontSize(13).fontWeight(FontWeight.Medium).fontColor(ThemeColors.onBackground(this.isDark))
                if (this.pageStats) Text(this.pageStats).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
              }.width('100%').padding({ left: 16, right: 16, top: 4, bottom: 2 })
            }
            ForEach(this.booklists, (item: YoushuBooklistItem) => {
              ListItem() { this.buildBooklistRow(item) }
            }, (item: YoushuBooklistItem): string => item.id)
            if (this.isLoadingMore) {
              ListItem() {
                Row() {
                  LoadingProgress().width(20).height(20).color(ThemeColors.primary(this.isDark))
                  Text($r('app.string.ui_d5d58840ea')).fontSize(12).margin({ left: 8 })
                    .fontColor(ThemeColors.secondaryText(this.isDark))
                }.width('100%').justifyContent(FlexAlign.Center).padding(16)
              }
            } else if (!this.nextPageUrl && this.booklists.length > 0) {
              ListItem() {
                Text($r('app.string.ui_3471e133fa')).width('100%').textAlign(TextAlign.Center).fontSize(12)
                  .fontColor(ThemeColors.secondaryText(this.isDark)).padding(16)
              }
            }
          }.layoutWeight(1).width('100%')
            .onReachEnd((): void => { void this.loadPage(this.nextPageUrl, true); })
        }.layoutWeight(1).width('100%').onRefreshing((): void => { this.refresh(); })
      }
    }.width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
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
            .margin({ right: 6, bottom: 7 }).onClick((): void => { this.selectFilter(option); })
        }, (option: YoushuFilterOption): string => option.url)
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).margin({ bottom: 4 })
  }

  @Builder
  private buildBooklistRow(item: YoushuBooklistItem) {
    Row() {
      Image(item.coverUrl).width(66).height(88).objectFit(ImageFit.Cover).accessibilityText(item.title + '封面')
        .borderRadius(7).backgroundColor(ThemeColors.surfaceVariant(this.isDark)).margin({ right: 12 })
      Column() {
        Text(item.title).fontSize(15).fontWeight(FontWeight.Medium).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor(ThemeColors.onSurface(this.isDark))
          .alignSelf(ItemAlign.Start)
        Text('来自 ' + (item.creator || '-') + ' · ' + (item.bookCount || '-') + ' · ' + (item.followerCount || '-'))
          .fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 5 })
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).alignSelf(ItemAlign.Start)
        Text('评分 ' + item.rating + ' · ' + item.ratingCount + ' · 字数 ' + (item.wordCount || '-'))
          .fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 4 })
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).alignSelf(ItemAlign.Start)
        if (item.recentBook) {
          Text('最近：' + item.recentBook + (item.recentUpdate ? ' · ' + item.recentUpdate : ''))
            .fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 4 })
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).alignSelf(ItemAlign.Start)
        }
        if (item.description) {
          Text(item.description).fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark))
            .margin({ top: 5 }).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            .alignSelf(ItemAlign.Start)
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').padding(12).margin({ left: 12, right: 12 })
      .backgroundColor(ThemeColors.surface(this.isDark)).borderRadius(12)
      .border({ width: 1, color: ThemeColors.outlineVariant(this.isDark) })
      .onClick((): void => { this.openDetail(item); })
  }
}
