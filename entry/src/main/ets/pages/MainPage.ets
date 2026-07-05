/**
 * 主页面 — Tab 框架
 */
import { BookshelfPage } from './BookshelfPage';
import { ExplorePage } from './ExplorePage';
import { MyPage } from './MyPage';
import { RssMainPage } from './RssMainPage';

interface TabCfg {
  icon: ResourceStr;
  label: string;
}

@Entry
@Component
struct MainPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State currentTab: number = 0;

  private tabs: TabCfg[] = [
    { icon: '\uD83D\uDCDA', label: '书架' },
    { icon: '\uD83D\uDD0D', label: '发现' },
    { icon: '\uD83D\uDCE1', label: 'RSS' },
    { icon: '\uD83D\uDC64', label: '我的' },
  ];

  build() {
    Column() {
      Stack() {
        if (this.currentTab === 0) { BookshelfPage() }
        else if (this.currentTab === 1) { ExplorePage() }
        else if (this.currentTab === 2) { RssMainPage() }
        else if (this.currentTab === 3) { MyPage() }
      }
      .width('100%')
      .layoutWeight(1)

      Row() {
        ForEach(this.tabs, (tab: TabCfg, idx: number) => {
          Column() {
            Text(tab.icon).fontSize(22).margin({ bottom: 2 })
            Text(tab.label).fontSize(11)
              .fontColor(this.currentTab === idx ? '#0078D7' : '#888')
          }
          .width('25%').padding({ top: 6, bottom: 6 })
          .onClick(() => { this.currentTab = idx; })
        })
      }
      .width('100%').height(56)
      .backgroundColor(this.isDark ? '#1E1E1E' : '#FFFFFF')
      .border({ width: { top: 1 }, color: this.isDark ? '#333' : '#E0E0E0' })
    }
    .width('100%').height('100%')
  }
}
