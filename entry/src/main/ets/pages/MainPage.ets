/**
 * 主页面 — Tab 框架
 */
import { BookshelfPage } from './BookshelfPage';
import { DiscoverPage } from './DiscoverPage';
import { MyPage } from './MyPage';
import { RssMainPage } from './RssMainPage';
import { ThemeColors } from '../theme/ThemeColors';

interface TabCfg {
  icon: ResourceStr;
  label: string;
}

@Entry
@Component
struct MainPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State currentTab: number = 0;
  @State isWideLayout: boolean = false;

  private tabs: TabCfg[] = [
    { icon: $r('app.media.ic_bookshelf'), label: '书架' },
    { icon: $r('app.media.ic_discover'), label: '发现' },
    { icon: $r('app.media.ic_rss'), label: 'RSS' },
    { icon: $r('app.media.ic_profile'), label: '我的' },
  ];

  build() {
    Tabs({
      barPosition: this.isWideLayout ? BarPosition.Start : BarPosition.End,
      index: this.currentTab
    }) {
      TabContent() { BookshelfPage() }.tabBar(this.buildTab(this.tabs[0], 0))
      TabContent() { DiscoverPage() }.tabBar(this.buildTab(this.tabs[1], 1))
      TabContent() { RssMainPage() }.tabBar(this.buildTab(this.tabs[2], 2))
      TabContent() { MyPage() }.tabBar(this.buildTab(this.tabs[3], 3))
    }
    .vertical(this.isWideLayout)
    .barWidth(this.isWideLayout ? 96 : '100%')
    .barHeight(this.isWideLayout ? '100%' : 64)
    .scrollable(false)
    .animationDuration(220)
    .onChange((index: number): void => { this.currentTab = index; })
    .width('100%').height('100%')
    .backgroundColor(ThemeColors.background(this.isDark))
    .onAreaChange((_oldArea: Area, newArea: Area): void => {
      const width = Number(newArea.width);
      if (!Number.isNaN(width)) this.isWideLayout = width >= 840;
    })
  }

  @Builder
  private buildTab(tab: TabCfg, index: number) {
    Column({ space: 3 }) {
      Image(tab.icon)
        .width(24).height(24)
        .fillColor(this.currentTab === index
          ? ThemeColors.primary(this.isDark)
          : ThemeColors.secondaryText(this.isDark))
      Text(tab.label)
        .fontSize(12)
        .fontWeight(this.currentTab === index ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.currentTab === index
          ? ThemeColors.primary(this.isDark)
          : ThemeColors.secondaryText(this.isDark))
    }
    .width(this.isWideLayout ? 96 : '100%')
    .height(56)
    .justifyContent(FlexAlign.Center)
    .accessibilityText(tab.label)
    .accessibilityDescription('双击切换到' + tab.label)
  }
}
