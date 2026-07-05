/**
 * 我的页面 - 支持跳转到子页
 */
import { AppTheme } from '../theme/AppTheme';
import router from '@ohos.router';
import { UiUtil } from '../util/UiUtil';

interface MenuEntry { icon: string; title: string; desc: string; page: string; }

@Component
export struct MyPage {
  private cs() { return AppTheme.getInstance().colorScheme; }
  @StorageLink('isDark') isDark: boolean = false;
  aboutToAppear(): void { this.isDark = AppTheme.getInstance().isDark; }

  goTo(page: string): void {
    if (page) {
      UiUtil.pushUrl(this.getUIContext(), { url: page }, router.RouterMode.Single);
    }
  }

  build() {
    Column() {
      Text('\uD83D\uDC64').fontSize(48).margin({ top: 32 })
      Text('Legado HOS').fontSize(20).fontWeight(FontWeight.Bold).margin({ top: 8 })
      Text('v1.0.0').fontSize(13).fontColor('#888').margin({ top: 4 })

      List() {
        ForEach([
          { icon: '\u2699\uFE0F', title: '设置', desc: '阅读、搜索、主题等全局设置', page: 'pages/SettingsPage' },
          { icon: '\uD83D\uDCDA', title: '书源管理', desc: '管理书源、在线导入', page: 'pages/BookSourcePage' },
          { icon: '\uD83D\uDCCA', title: '阅读记录', desc: '阅读时长、统计', page: 'pages/ReadRecordPage' },
          { icon: '\uD83D\uDCD6', title: '书签管理', desc: '书签、笔记', page: 'pages/BookmarkPage' },
          { icon: '\uD83C\uDF10', title: 'Web 远程管理', desc: '启动 Web 服务', page: 'pages/WebServicePage' },
          { icon: '\u2139\uFE0F', title: '关于', desc: '版本、许可', page: 'pages/AboutPage' },
        ] as MenuEntry[], (item: MenuEntry) => {
          ListItem() {
            Row() {
              Text(item.icon).fontSize(22).margin({ right: 14 })
              Column() {
                Text(item.title).fontSize(15).fontWeight(FontWeight.Medium)
                  .alignSelf(ItemAlign.Start)
                Text(item.desc).fontSize(12).fontColor('#888')
                  .alignSelf(ItemAlign.Start)
              }
              .layoutWeight(1).alignItems(HorizontalAlign.Start)
              Text('>').fontSize(18).fontColor('#888')
            }.padding(14).width('100%')
          }
          .border({ width: { bottom: 1 }, color: this.isDark ? '#333' : '#E8E8E8' })
          .onClick(() => { if (item.page) { this.goTo(item.page); } })
        })
      }
      .width('100%').layoutWeight(1)
    }
    .width('100%').height('100%').backgroundColor(this.cs().background)
    .alignItems(HorizontalAlign.Center)
  }
}
