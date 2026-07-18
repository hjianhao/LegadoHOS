/** 优书网书单详情：书单信息、书籍信息及书单评语。 */
import { ThemeColors } from '../theme/ThemeColors';
import { UiUtil } from '../util/UiUtil';
import { YoushuLoginDialog } from '../components/YoushuLoginDialog';
import {
  YoushuBooklistBook,
  YoushuBooklistDetail,
  YoushuBooklistService,
} from '../service/YoushuBooklistService';

@Entry
@Component
struct YoushuBooklistDetailPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State detailUrl: string = '';
  @State routeTitle: string = '';
  @State detail: YoushuBooklistDetail | null = null;
  @State books: YoushuBooklistBook[] = [];
  @State nextPageUrl: string = '';
  @State isLoading: boolean = true;
  @State isLoadingMore: boolean = false;
  @State errorMessage: string = '';

  private requestId: number = 0;
  private isActive: boolean = false;
  private loginDialog?: CustomDialogController;

  aboutToAppear(): void {
    this.isActive = true;
    const params = UiUtil.getParams(this.getUIContext()) as Record<string, Object>;
    this.detailUrl = String(params['detailUrl'] || '');
    this.routeTitle = String(params['title'] || '书单详情');
    void this.loadDetail(this.detailUrl, false);
  }

  aboutToDisappear(): void {
    this.isActive = false;
    this.requestId++;
  }

  private async loadDetail(url: string, append: boolean): Promise<void> {
    if (!url) {
      this.isLoading = false;
      this.errorMessage = '书单地址无效';
      return;
    }
    if (append) {
      if (this.isLoadingMore) return;
      this.isLoadingMore = true;
    } else {
      this.isLoading = true;
      this.errorMessage = '';
    }
    const runId = ++this.requestId;
    try {
      const page = await YoushuBooklistService.loadDetail(url);
      if (!this.isActive || runId !== this.requestId) return;
      if (append) {
        this.books = [...this.books, ...page.books];
      } else {
        this.detail = page;
        this.books = page.books;
      }
      this.nextPageUrl = page.nextPageUrl;
      if (!page.loginRequired && !page.title && page.books.length === 0) {
        this.errorMessage = '未能解析书单内容';
      }
    } catch (e) {
      if (!this.isActive || runId !== this.requestId) return;
      this.errorMessage = (e as Error).message || '加载失败';
      if (append) UiUtil.showToast(this.getUIContext(), { message: '下一页加载失败', duration: 1500 });
    } finally {
      if (this.isActive && runId === this.requestId) {
        this.isLoading = false;
        this.isLoadingMore = false;
      }
    }
  }

  private openSearch(book: YoushuBooklistBook): void {
    UiUtil.pushUrl(this.getUIContext(), {
      url: 'pages/SearchPage', params: { key: book.author ? book.name + ' ' + book.author : book.name,
        bookName: book.name, author: book.author }
    });
  }

  private openLogin(): void {
    this.loginDialog = new CustomDialogController({
      builder: YoushuLoginDialog({
        controller: this.loginDialog!,
        onLoginSuccess: (): void => { if (this.isActive) void this.loadDetail(this.detailUrl, false); }
      }),
      autoCancel: true,
      customStyle: true,
      alignment: DialogAlignment.Center,
    });
    this.loginDialog.open();
  }

  build() {
    Column() {
      Row() {
        Button($r('app.string.ui_8179643cdc')).fontSize(22).fontColor(ThemeColors.onBackground(this.isDark))
          .width(44).height(44).backgroundColor(Color.Transparent).accessibilityText($r('app.string.common_back'))
          .onClick((): void => { UiUtil.back(this.getUIContext()); })
        Text(this.detail?.title || this.routeTitle).fontSize(18).fontWeight(FontWeight.Medium)
          .fontColor(ThemeColors.onBackground(this.isDark)).margin({ left: 12 }).layoutWeight(1)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Button($r('app.string.ui_21f1e88275')).fontSize(12).height(44).padding({ left: 12, right: 12 })
          .fontColor(ThemeColors.onPrimary(this.isDark)).backgroundColor(ThemeColors.primary(this.isDark))
          .borderRadius(16).onClick((): void => { this.openLogin(); })
      }.width('100%').padding({ left: 16, right: 12, top: 10, bottom: 10 })

      if (this.isLoading && this.books.length === 0) {
        Column() {
          LoadingProgress().width(32).height(32).color(ThemeColors.primary(this.isDark))
          Text($r('app.string.ui_5ad84fbb32')).fontSize(13).margin({ top: 10 })
            .fontColor(ThemeColors.secondaryText(this.isDark))
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else if (this.detail?.loginRequired) {
        Column() {
          Text($r('app.string.ui_f52aef24a9')).fontSize(17).fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.onBackground(this.isDark))
          Text($r('app.string.ui_62c8d4d429')).fontSize(12).margin({ top: 8 })
            .fontColor(ThemeColors.secondaryText(this.isDark))
          Button($r('app.string.ui_24934124ef')).margin({ top: 18 })
            .fontColor(ThemeColors.onPrimary(this.isDark)).backgroundColor(ThemeColors.primary(this.isDark))
            .onClick((): void => { this.openLogin(); })
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else if (this.errorMessage && this.books.length === 0) {
        Column() {
          Text($r('app.string.ui_e977b63424')).fontSize(16).fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.onBackground(this.isDark))
          Text(this.errorMessage).fontSize(12).fontColor(ThemeColors.error(this.isDark))
            .margin({ top: 8 }).padding({ left: 24, right: 24 }).textAlign(TextAlign.Center)
          Button($r('app.string.common_retry')).margin({ top: 16 }).onClick((): void => { void this.loadDetail(this.detailUrl, false); })
        }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
      } else {
        List({ space: 10 }) {
          if (this.detail) {
            ListItem() { this.buildBooklistInfo(this.detail!) }
            ListItem() {
              Text('书单内书籍 · ' + this.books.length.toString() + ' 本已加载')
                .width('100%').fontSize(13).fontWeight(FontWeight.Medium)
                .fontColor(ThemeColors.onBackground(this.isDark))
                .padding({ left: 16, right: 16, top: 4, bottom: 2 })
            }
          }
          ForEach(this.books, (book: YoushuBooklistBook) => {
            ListItem() { this.buildBookRow(book) }
          }, (book: YoushuBooklistBook): string => book.position + '_' + book.id)
          if (this.isLoadingMore) {
            ListItem() {
              Row() {
                LoadingProgress().width(20).height(20).color(ThemeColors.primary(this.isDark))
                Text($r('app.string.ui_d5d58840ea')).fontSize(12).margin({ left: 8 })
                  .fontColor(ThemeColors.secondaryText(this.isDark))
              }.width('100%').justifyContent(FlexAlign.Center).padding(16)
            }
          } else if (!this.nextPageUrl && this.books.length > 0) {
            ListItem() {
              Text($r('app.string.ui_6378e1ddf7')).width('100%').textAlign(TextAlign.Center).fontSize(12)
                .fontColor(ThemeColors.secondaryText(this.isDark)).padding(16)
            }
          }
        }.layoutWeight(1).width('100%')
          .onReachEnd((): void => { void this.loadDetail(this.nextPageUrl, true); })
      }
    }.width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
  }

  @Builder
  private buildBooklistInfo(detail: YoushuBooklistDetail) {
    Column() {
      Row() {
        Image(detail.coverUrl).width(82).height(108).objectFit(ImageFit.Cover).borderRadius(8).accessibilityText(detail.title + '封面')
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).margin({ right: 14 })
        Column() {
          Text(detail.title).fontSize(17).fontWeight(FontWeight.Bold).maxLines(3)
            .fontColor(ThemeColors.onSurface(this.isDark)).alignSelf(ItemAlign.Start)
          Text('创建者 ' + (detail.creator || '-')).fontSize(12).margin({ top: 8 })
            .fontColor(ThemeColors.secondaryText(this.isDark)).alignSelf(ItemAlign.Start)
          Text('评分 ' + detail.rating + ' · ' + detail.ratingCount).fontSize(12).margin({ top: 5 })
            .fontColor(ThemeColors.secondaryText(this.isDark)).alignSelf(ItemAlign.Start)
          if (detail.metadata) {
            Text(detail.metadata).fontSize(11).margin({ top: 5 }).maxLines(2)
              .fontColor(ThemeColors.secondaryText(this.isDark)).alignSelf(ItemAlign.Start)
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%')
      if (detail.description) {
        Text(detail.description).fontSize(12).lineHeight(19).margin({ top: 12 })
          .fontColor(ThemeColors.onSurface(this.isDark)).alignSelf(ItemAlign.Start)
      }
      if (detail.stats.length > 0) {
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(detail.stats, (stat: string) => {
            Text(stat).fontSize(11).width('50%').padding({ top: 4, bottom: 4 })
              .fontColor(ThemeColors.secondaryText(this.isDark))
          }, (stat: string, index: number): string => index.toString() + stat)
        }.width('100%').margin({ top: 8 })
      }
    }.width('100%').padding(14).margin({ left: 12, right: 12 })
      .backgroundColor(ThemeColors.surface(this.isDark)).borderRadius(12)
      .border({ width: 1, color: ThemeColors.outlineVariant(this.isDark) })
  }

  @Builder
  private buildBookRow(book: YoushuBooklistBook) {
    Column() {
      Row() {
        Stack({ alignContent: Alignment.TopStart }) {
          Image(book.coverUrl).width(66).height(92).objectFit(ImageFit.Cover).borderRadius(7).accessibilityText(book.name + '封面')
            .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
          Text(book.position).fontSize(10).fontColor(ThemeColors.onPrimary(this.isDark))
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .backgroundColor(ThemeColors.primary(this.isDark)).borderRadius({ bottomRight: 6 })
        }.width(66).height(92).margin({ right: 12 })
        Column() {
          Text(book.name).fontSize(15).fontWeight(FontWeight.Medium).maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis }).fontColor(ThemeColors.onSurface(this.isDark))
            .alignSelf(ItemAlign.Start)
          Text((book.author || '未知作者') + (book.category ? ' · ' + book.category : ''))
            .fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 5 })
            .alignSelf(ItemAlign.Start)
          Text('评分 ' + book.rating + (book.ratingCount ? ' · ' + book.ratingCount : ''))
            .fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 4 })
            .alignSelf(ItemAlign.Start)
          Text('字数 ' + (book.wordCount || '-') + (book.updateTime ? ' · 更新 ' + book.updateTime : ''))
            .fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 4 })
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).alignSelf(ItemAlign.Start)
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%')
      if (book.review) {
        Column() {
          Text($r('app.string.ui_975c61b3f8')).fontSize(11).fontWeight(FontWeight.Medium)
            .fontColor(ThemeColors.primary(this.isDark)).alignSelf(ItemAlign.Start)
          Text(book.review).fontSize(12).lineHeight(19).margin({ top: 4 })
            .fontColor(ThemeColors.onSurface(this.isDark)).alignSelf(ItemAlign.Start)
        }.width('100%').padding(10).margin({ top: 10 })
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).borderRadius(8)
      }
      if (book.addedTime) {
        Text('加入书单：' + book.addedTime).fontSize(10).margin({ top: 7 })
          .fontColor(ThemeColors.secondaryText(this.isDark)).alignSelf(ItemAlign.End)
      }
    }.width('100%').padding(13).margin({ left: 12, right: 12 })
      .backgroundColor(ThemeColors.surface(this.isDark)).borderRadius(12)
      .border({ width: 1, color: ThemeColors.outlineVariant(this.isDark) })
      .onClick((): void => { this.openSearch(book); })
  }
}
