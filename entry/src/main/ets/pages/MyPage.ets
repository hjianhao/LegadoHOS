/**
 * 我的页面 - 支持跳转到子页
 */
import { AppTheme } from '../theme/AppTheme';
import { ThemeColors } from '../theme/ThemeColors';
import router from '@ohos.router';
import { UiUtil } from '../util/UiUtil';

interface MenuEntry { icon: string; title: string; desc: string; page: string; }

@Component
export struct MyPage {
  @StorageLink('isDark') isDark: boolean = false;
  aboutToAppear(): void { this.isDark = AppTheme.getInstance().isDark; }

  goTo(page: string): void {
    if (page) {
      UiUtil.pushUrl(this.getUIContext(), { url: page }, router.RouterMode.Single);
    }
  }

  build() {
    Column() {
      Text($r('app.string.ui_a7d09a6235')).fontSize(28).fontWeight(FontWeight.Bold).width(64).height(64).textAlign(TextAlign.Center)
        .backgroundColor(ThemeColors.primaryContainer(this.isDark)).borderRadius(32)
        .margin({ top: 32 }).fontColor(ThemeColors.primary(this.isDark)).accessibilityText($r('app.string.ui_c24e01964b'))
      Text($r('app.string.ui_c24e01964b')).fontSize(20).fontWeight(FontWeight.Bold).margin({ top: 8 }).fontColor(ThemeColors.onBackground(this.isDark))
      Text($r('app.string.ui_7ac19ee157')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 4 })

      List() {
        ForEach([
          { icon: '设', title: '设置', desc: '阅读、搜索、主题等全局设置', page: 'pages/SettingsPage' },
          { icon: '源', title: '书源管理', desc: '管理书源、在线导入', page: 'pages/BookSourcePage' },
          { icon: '净', title: '替换净化', desc: '正文/标题替换规则管理', page: 'pages/ReplaceRulePage' },
          { icon: '字', title: '字体管理', desc: '导入、删除自定义字体', page: 'pages/FontManagerPage' },
          { icon: '记', title: '阅读记录', desc: '阅读时长、统计', page: 'pages/ReadRecordPage' },
          { icon: '签', title: '书签管理', desc: '书签、笔记', page: 'pages/BookmarkPage' },
          { icon: '网', title: 'Web 远程管理', desc: '启动 Web 服务', page: 'pages/WebServicePage' },
          { icon: '介', title: '关于', desc: '版本、许可', page: 'pages/AboutPage' },
        ] as MenuEntry[], (item: MenuEntry) => {
          ListItem() {
            Row() {
              Text(item.icon).fontSize(22).margin({ right: 14 }).fontColor(ThemeColors.onBackground(this.isDark))
              Column() {
                Text(item.title).fontSize(15).fontWeight(FontWeight.Medium)
                  .alignSelf(ItemAlign.Start).fontColor(ThemeColors.onBackground(this.isDark))
                Text(item.desc).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
                  .alignSelf(ItemAlign.Start)
              }
              .layoutWeight(1).alignItems(HorizontalAlign.Start)
              Text($r('app.string.ui_091385be99')).fontSize(18).fontColor(ThemeColors.secondaryText(this.isDark))
            }.padding(14).width('100%')
          }
          .border({ width: { bottom: 1 }, color: ThemeColors.outlineVariant(this.isDark) })
          .accessibilityText(item.title).accessibilityDescription(item.desc)
          .onClick(() => { if (item.page) { this.goTo(item.page); } })
        })
      }
      .width('100%').layoutWeight(1)
    }
    .width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
    .alignItems(HorizontalAlign.Center)
  }
}
