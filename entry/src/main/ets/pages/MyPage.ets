/**
 * 我的页面
 *
 * 布局策略（对齐鸿蒙系统设置 / doc/ref/pad.md）：
 * - Compact：单列菜单，点击后整页 push
 * - Medium：单列全宽菜单（不再限宽居中），点击后整页 push
 * - Expanded+：MainPage 启用 Navigation Split，本页作为左侧导航；
 *   点击菜单用 replace 切换右侧详情，并高亮当前项
 */
import { AppTheme } from '../theme/AppTheme';
import { ThemeColors } from '../theme/ThemeColors';
import router from '@ohos.router';
import { UiUtil } from '../util/UiUtil';
import { WindowLayout, WindowSizeClass } from '../util/WindowLayout';
import { NavRouter, NavPageName } from '../util/NavRouter';

interface MenuEntry {
  icon: string;
  title: string;
  desc: string;
  page: string;
}

@Component
export struct MyPage {
  @StorageLink('isDark') isDark: boolean = false;
  @StorageProp('windowSizeClass') sizeClass: WindowSizeClass = WindowSizeClass.COMPACT;
  /** 当前选中的子页面（pages/Xxx），用于分栏高亮 */
  @State selectedPage: string = '';

  private readonly menuItems: MenuEntry[] = [
    { icon: '设', title: '设置', desc: '阅读、搜索、主题等全局设置', page: 'pages/SettingsPage' },
    { icon: '源', title: '书源管理', desc: '管理书源、在线导入', page: 'pages/BookSourcePage' },
    { icon: '净', title: '替换净化', desc: '正文/标题替换规则管理', page: 'pages/ReplaceRulePage' },
    { icon: '字', title: '字体管理', desc: '导入、删除自定义字体', page: 'pages/FontManagerPage' },
    { icon: '记', title: '阅读记录', desc: '阅读时长、统计', page: 'pages/ReadRecordPage' },
    { icon: '签', title: '书签管理', desc: '书签、笔记', page: 'pages/BookmarkPage' },
    { icon: '网', title: 'Web 远程管理', desc: '启动 Web 服务', page: 'pages/WebServicePage' },
    { icon: '介', title: '关于', desc: '版本、许可', page: 'pages/AboutPage' },
  ];

  aboutToAppear(): void {
    this.isDark = AppTheme.getInstance().isDark;
  }

  /** 分栏模式下右侧详情返回后清除高亮 */
  onPageShow(): void {
    if (NavRouter.depth() === 0) {
      this.selectedPage = '';
    }
  }

  /** 是否处于「我的」左右分栏（与 MainPage.isMySplitLayout 一致） */
  private get isSplitNav(): boolean {
    return this.sizeClass >= WindowSizeClass.EXPANDED;
  }

  goTo(page: string): void {
    if (!page) {
      return;
    }
    const pageName = (page.startsWith('pages/') ? page.substring('pages/'.length) : page) as NavPageName;
    // 平板分栏：替换右侧详情，避免堆栈
    if (this.isSplitNav) {
      if (this.selectedPage === page && NavRouter.depth() > 0) {
        return;
      }
      if (NavRouter.replace(pageName)) {
        this.selectedPage = page;
        return;
      }
    }
    // 手机 / 中等宽度：栈式进入
    if (NavRouter.push(pageName)) {
      this.selectedPage = page;
      return;
    }
    UiUtil.pushUrl(this.getUIContext(), { url: page }, router.RouterMode.Single);
    this.selectedPage = page;
  }

  build() {
    Column() {
      // 头像与标题区：分栏时更紧凑，单列时保持原有视觉
      this.buildProfileHeader()

      List() {
        ForEach(this.menuItems, (item: MenuEntry) => {
          ListItem() {
            this.buildMenuRow(item)
          }
          .accessibilityText(item.title)
          .accessibilityDescription(item.desc)
          .onClick(() => {
            this.goTo(item.page);
          })
        }, (item: MenuEntry) => item.page)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(this.isSplitNav ? BarState.Auto : BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemeColors.background(this.isDark))
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private buildProfileHeader() {
    Column() {
      Text($r('app.string.ui_a7d09a6235'))
        .fontSize(this.isSplitNav ? 22 : 28)
        .fontWeight(FontWeight.Bold)
        .width(this.isSplitNav ? 52 : 64)
        .height(this.isSplitNav ? 52 : 64)
        .textAlign(TextAlign.Center)
        .backgroundColor(ThemeColors.primaryContainer(this.isDark))
        .borderRadius(this.isSplitNav ? 26 : 32)
        .margin({ top: this.isSplitNav ? 20 : 32 })
        .fontColor(ThemeColors.primary(this.isDark))
        .accessibilityText($r('app.string.ui_c24e01964b'))
      Text($r('app.string.ui_c24e01964b'))
        .fontSize(this.isSplitNav ? 17 : 20)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 8 })
        .fontColor(ThemeColors.onBackground(this.isDark))
      Text($r('app.string.ui_7ac19ee157'))
        .fontSize(12)
        .fontColor(ThemeColors.secondaryText(this.isDark))
        .margin({ top: 4, bottom: this.isSplitNav ? 12 : 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private buildMenuRow(item: MenuEntry) {
    Row() {
      // 选中指示条（分栏时显示）
      if (this.isSplitNav) {
        Column()
          .width(3)
          .height(28)
          .borderRadius(2)
          .backgroundColor(this.selectedPage === item.page
            ? ThemeColors.primary(this.isDark)
            : ThemeColors.transparent())
          .margin({ right: 10 })
      }
      Text(item.icon)
        .fontSize(this.isSplitNav ? 20 : 22)
        .margin({ right: 12 })
        .fontColor(this.selectedPage === item.page
          ? ThemeColors.primary(this.isDark)
          : ThemeColors.onBackground(this.isDark))
      Column() {
        Text(item.title)
          .fontSize(this.isSplitNav ? 15 : 15)
          .fontWeight(this.selectedPage === item.page ? FontWeight.Medium : FontWeight.Medium)
          .alignSelf(ItemAlign.Start)
          .fontColor(this.selectedPage === item.page
            ? ThemeColors.primary(this.isDark)
            : ThemeColors.onBackground(this.isDark))
        if (!this.isSplitNav || item.desc.length > 0) {
          Text(item.desc)
            .fontSize(12)
            .fontColor(ThemeColors.secondaryText(this.isDark))
            .alignSelf(ItemAlign.Start)
            .maxLines(this.isSplitNav ? 1 : 2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (!this.isSplitNav) {
        Text($r('app.string.ui_091385be99'))
          .fontSize(18)
          .fontColor(ThemeColors.secondaryText(this.isDark))
      }
    }
    .padding({
      left: this.isSplitNav ? 12 : 14,
      right: 14,
      top: this.isSplitNav ? 12 : 14,
      bottom: this.isSplitNav ? 12 : 14
    })
    .width('100%')
    .backgroundColor(this.isSplitNav && this.selectedPage === item.page
      ? ThemeColors.primaryContainer(this.isDark)
      : ThemeColors.transparent())
    .borderRadius(this.isSplitNav ? 12 : 0)
    .margin(this.isSplitNav ? { left: 8, right: 8, top: 2, bottom: 2 } : {})
    .border(this.isSplitNav
      ? { width: 0 }
      : { width: { bottom: 1 }, color: ThemeColors.outlineVariant(this.isDark) })
  }
}
