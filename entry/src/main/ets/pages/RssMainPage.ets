/**
 * RSS 主页 — 显示已订阅的 RSS 源列表
 */
import { AppDatabase } from '../data/database/AppDatabase';
import { RSSSource } from '../model/RSSSource';
import router from '@ohos.router';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';

@Component
export struct RssMainPage {
  @StorageProp('isDark') isDark: boolean = false;
  @StorageLink('rssRefreshKey') @Watch('onRefreshKeyChanged') rssRefreshKey: number = 0;
  @State sources: RSSSource[] = [];
  @State isLoading: boolean = true;
  @State isRefreshing: boolean = false;

  private db: AppDatabase = AppDatabase.getInstance();

  aboutToAppear() {
    this.loadData();
  }

  onRefreshKeyChanged(): void {
    this.loadData();
  }

  async loadData() {
    this.isLoading = true;
    try {
      await this.db.waitForInit();
      this.sources = await this.db.rssSourceTable.getEnabledSources();
    } catch (e) {
      console.error('[RssMainPage] loadData failed: ' + e);
    } finally {
      this.isLoading = false;
      this.isRefreshing = false;
    }
  }

  private onRefresh(): void {
    this.isRefreshing = true;
    this.loadData();
  }

  private onToManage(): void {
    UiUtil.pushUrl(this.getUIContext(), { url: 'pages/RssSourceManagePage' });
  }

  build() {
    Column() {
      Row() {
        Text('订阅').fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark))
        Blank()
        Button({ type: ButtonType.Normal }) {
          Text('↻').fontSize(18).fontColor(ThemeColors.primary(this.isDark))
        }
        .backgroundColor('transparent').margin({ right: 8 })
        .onClick((): void => { this.onRefresh(); })
        Button({ type: ButtonType.Normal }) {
          Text('管理').fontSize(14).fontColor(ThemeColors.primary(this.isDark))
        }
        .backgroundColor('transparent')
        .onClick((): void => { this.onToManage(); })
      }
      .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 8 })

      if (this.isLoading && !this.isRefreshing) {
        LoadingProgress().color(ThemeColors.primary(this.isDark))
      } else if (this.sources.length === 0) {
        Column() {
          Text('暂无订阅源').fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark))
          Text('点击右上角「管理」添加 RSS 订阅源')
            .fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 8 })
          Button('去管理')
            .margin({ top: 16 })
            .onClick((): void => { this.onToManage(); })
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      } else {
        Refresh({ refreshing: $$this.isRefreshing }) {
          Scroll() {
            Column() {
              ForEach(this.sources, (source: RSSSource) => {
                Row() {
                  if (source.sourceIcon) {
                    Image(source.sourceIcon)
                      .width(40).height(40).borderRadius(8).objectFit(ImageFit.Cover)
                  } else {
                    Text('📰').fontSize(30)
                  }
                  Column() {
                    Text(source.sourceName).fontSize(15)
                      .fontColor(ThemeColors.onBackground(this.isDark))
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    if (source.sourceGroup) {
                      Text(source.sourceGroup).fontSize(11)
                        .fontColor(ThemeColors.primary(this.isDark)).margin({ top: 2 })
                        .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                        .border({ radius: 3 }).borderColor(ThemeColors.primary(this.isDark)).borderWidth(0.5)
                    }
                  }
                  .layoutWeight(1).alignItems(HorizontalAlign.Start).margin({ left: 10 })
                  Text('>').fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark))
                }
                .padding({ left: 16, right: 16, top: 12, bottom: 12 }).width('100%')
                .onClick((): void => {
                  UiUtil.pushUrl(this.getUIContext(), {
                    url: 'pages/RssArticlesPage',
                    params: { sourceUrl: source.sourceUrl, sourceName: source.sourceName }
                  });
                })
              })
            }.width('100%')
          }.layoutWeight(1)
        }
        .onRefreshing((): void => { this.onRefresh(); })
      }
    }
    .width('100%').height('100%')
    .backgroundColor(ThemeColors.background(this.isDark))
  }
}
