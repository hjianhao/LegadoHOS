/** 发现聚合页：书源发现与站点发现并列展示。 */
import { ExplorePage } from './ExplorePage';
import { YoushuExplorePage } from './YoushuExplorePage';
import { LkongExplorePage } from './LkongExplorePage';
import { ThemeColors } from '../theme/ThemeColors';

@Component
export struct DiscoverPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State selectedTab: number = 0;

  build() {
    Column() {
      Tabs({ barPosition: BarPosition.Start, index: this.selectedTab }) {
        TabContent() {
          ExplorePage()
        }.tabBar(this.buildTab('书源发现', 0))
        TabContent() {
          YoushuExplorePage()
        }.tabBar(this.buildTab('优书网发现', 1))
        TabContent() {
          LkongExplorePage()
        }.tabBar(this.buildTab('龙空推书', 2))
      }
      .width('100%').layoutWeight(1).barHeight(52).scrollable(false)
      .backgroundColor(ThemeColors.background(this.isDark))
      .onChange((index: number): void => { this.selectedTab = index; })
    }.width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
  }

  @Builder
  private buildTab(label: string, index: number) {
    Text(label).fontSize(14).fontWeight(this.selectedTab === index ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.selectedTab === index ? ThemeColors.onPrimary(this.isDark) : ThemeColors.onSurface(this.isDark))
      .backgroundColor(this.selectedTab === index ? ThemeColors.primary(this.isDark) : ThemeColors.surfaceVariant(this.isDark))
      .height(44).padding({ left: 10, right: 10 }).textAlign(TextAlign.Center).borderRadius(22)
      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      .accessibilityText(label).accessibilityDescription('双击切换到' + label)
  }
}
