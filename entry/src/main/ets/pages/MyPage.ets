/**
 * 我的页面
 *
 * 布局（对齐鸿蒙系统设置）：
 * - 窄屏：单列菜单，classic router 整页打开
 * - 宽屏：手写左导航 / 右内嵌详情
 *
 * 宽屏判定多源：本页 onAreaChange 实测宽度 + windowWidthVp + windowIsWide + sizeSizeClass
 * （真机曾出现 AppStorage 未更新导致一直走手机路径，见 test/search.log）
 */
import { AppTheme } from '../theme/AppTheme';
import { ThemeColors } from '../theme/ThemeColors';
import { UiUtil } from '../util/UiUtil';
import { WindowLayout, WindowSizeClass } from '../util/WindowLayout';
import { SettingsPage } from './SettingsPage';
import { BookSourcePage } from './BookSourcePage';
import { ReplaceRulePage } from './ReplaceRulePage';
import { FontManagerPage } from './FontManagerPage';
import { ReadRecordPage } from './ReadRecordPage';
import { BookmarkPage } from './BookmarkPage';
import { WebServicePage } from './WebServicePage';
import { AboutPage } from './AboutPage';

interface MenuEntry {
  icon: string;
  title: string;
  desc: string;
  page: string;
}

@Component
export struct MyPage {
  @StorageLink('isDark') isDark: boolean = false;
  @StorageProp('windowSizeClass') sizeClassNum: number = 0;
  @StorageProp('windowIsWide') isWideFlag: boolean = false;
  @StorageProp('windowWidthVp') windowWidthVp: number = 360;
  /** 本页实测宽度（vp） */
  @State localWidthVp: number = 0;
  /** 与 UiUtil.back 约定：清空该键即关闭右侧内嵌详情 */
  @StorageLink('myEmbeddedDetail') selectedPage: string = '';

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
    AppStorage.setOrCreate('myEmbeddedDetail', this.selectedPage || '');
    // 用全局已算好的宽度做首帧兜底（Ability 已初始化时立即分栏）
    if (WindowLayout.widthVp >= 600) {
      this.localWidthVp = WindowLayout.widthVp;
    } else if (this.windowWidthVp >= 600) {
      this.localWidthVp = this.windowWidthVp;
    }
    console.info('[MyPage] aboutToAppear localW=' + this.localWidthVp +
      ' winW=' + this.windowWidthVp + ' class=' + this.sizeClassNum +
      ' wide=' + this.isWideFlag + ' staticW=' + WindowLayout.widthVp);
  }

  /**
   * 是否左右分栏。
   * 任一信号达到宽屏阈值即启用，避免 StorageProp 单点失效。
   */
  private get isSplitNav(): boolean {
    if (this.localWidthVp >= 600) {
      return true;
    }
    if (this.windowWidthVp >= 600) {
      return true;
    }
    if (this.isWideFlag) {
      return true;
    }
    if (this.sizeClassNum >= WindowSizeClass.MEDIUM) {
      return true;
    }
    if (WindowLayout.isWide || WindowLayout.widthVp >= 600) {
      return true;
    }
    return false;
  }

  private get navPaneWidth(): number {
    const w = Math.max(this.localWidthVp, this.windowWidthVp, WindowLayout.widthVp);
    if (w >= 1200) {
      return 320;
    }
    return 280;
  }

  goTo(page: string): void {
    if (!page) {
      return;
    }
    console.info('[MyPage] goTo ' + page + ' split=' + this.isSplitNav +
      ' localW=' + this.localWidthVp + ' winW=' + this.windowWidthVp);
    if (this.isSplitNav) {
      this.selectedPage = page;
      return;
    }
    UiUtil.pushUrl(this.getUIContext(), { url: page });
  }

  build() {
    Column() {
      if (this.isSplitNav) {
        this.buildSplitLayout()
      } else {
        this.buildCompactLayout()
      }
    }
    .width('100%')
    .height('100%')
    .onAreaChange((_old: Area, area: Area) => {
      const w = typeof area.width === 'number' ? area.width : Number(area.width);
      const h = typeof area.height === 'number' ? area.height : Number(area.height);
      if (Number.isFinite(w) && w > 0) {
        if (Math.abs(w - this.localWidthVp) > 0.5) {
          this.localWidthVp = w;
          console.info('[MyPage] onAreaChange w=' + w + ' h=' + h + ' split=' + (w >= 600));
        }
        if (Number.isFinite(h) && h > 0) {
          // 内容区宽度变化时同步全局（侧栏模式下内容区会小于全屏，但通常仍 >=600）
          // 仅当明显更大时更新，避免用窄内容区覆盖全屏宽
          if (w >= WindowLayout.widthVp - 1 || WindowLayout.widthVp < 600) {
            WindowLayout.update(w, h);
          }
        }
      }
    })
  }

  @Builder
  private buildSplitLayout() {
    Row() {
      Column() {
        this.buildProfileHeader(true)
        List() {
          ForEach(this.menuItems, (item: MenuEntry) => {
            ListItem() {
              this.buildMenuRow(item, true)
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
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width(this.navPaneWidth)
      .height('100%')
      .backgroundColor(ThemeColors.surface(this.isDark))

      Divider()
        .vertical(true)
        .strokeWidth(0.5)
        .color(ThemeColors.outlineVariant(this.isDark))

      Column() {
        if (this.selectedPage.length === 0) {
          this.buildEmptyDetail()
        } else {
          this.buildEmbeddedDetail()
        }
      }
      .layoutWeight(1)
      .height('100%')
      .backgroundColor(ThemeColors.background(this.isDark))
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemeColors.background(this.isDark))
  }

  @Builder
  private buildCompactLayout() {
    Column() {
      this.buildProfileHeader(false)
      List() {
        ForEach(this.menuItems, (item: MenuEntry) => {
          ListItem() {
            this.buildMenuRow(item, false)
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
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemeColors.background(this.isDark))
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private buildEmptyDetail() {
    Column() {
      Text('请选择左侧功能')
        .fontSize(16)
        .fontColor(ThemeColors.secondaryText(this.isDark))
      Text('设置、书源、字体等将显示在这里')
        .fontSize(13)
        .fontColor(ThemeColors.secondaryText(this.isDark))
        .margin({ top: 8 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private buildEmbeddedDetail() {
    if (this.selectedPage === 'pages/SettingsPage') {
      SettingsPage()
    } else if (this.selectedPage === 'pages/BookSourcePage') {
      BookSourcePage()
    } else if (this.selectedPage === 'pages/ReplaceRulePage') {
      ReplaceRulePage()
    } else if (this.selectedPage === 'pages/FontManagerPage') {
      FontManagerPage()
    } else if (this.selectedPage === 'pages/ReadRecordPage') {
      ReadRecordPage()
    } else if (this.selectedPage === 'pages/BookmarkPage') {
      BookmarkPage()
    } else if (this.selectedPage === 'pages/WebServicePage') {
      WebServicePage()
    } else if (this.selectedPage === 'pages/AboutPage') {
      AboutPage()
    } else {
      this.buildEmptyDetail()
    }
  }

  @Builder
  private buildProfileHeader(splitMode: boolean) {
    Column() {
      Text($r('app.string.ui_a7d09a6235'))
        .fontSize(splitMode ? 22 : 28)
        .fontWeight(FontWeight.Bold)
        .width(splitMode ? 52 : 64)
        .height(splitMode ? 52 : 64)
        .textAlign(TextAlign.Center)
        .backgroundColor(ThemeColors.primaryContainer(this.isDark))
        .borderRadius(splitMode ? 26 : 32)
        .margin({ top: splitMode ? 20 : 32 })
        .fontColor(ThemeColors.primary(this.isDark))
        .accessibilityText($r('app.string.ui_c24e01964b'))
      Text($r('app.string.ui_c24e01964b'))
        .fontSize(splitMode ? 17 : 20)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 8 })
        .fontColor(ThemeColors.onBackground(this.isDark))
      Text($r('app.string.ui_7ac19ee157'))
        .fontSize(12)
        .fontColor(ThemeColors.secondaryText(this.isDark))
        .margin({ top: 4, bottom: splitMode ? 12 : 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private buildMenuRow(item: MenuEntry, splitMode: boolean) {
    Row() {
      if (splitMode) {
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
        .fontSize(splitMode ? 20 : 22)
        .margin({ right: 12 })
        .fontColor(this.selectedPage === item.page
          ? ThemeColors.primary(this.isDark)
          : ThemeColors.onBackground(this.isDark))
      Column() {
        Text(item.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .alignSelf(ItemAlign.Start)
          .fontColor(this.selectedPage === item.page
            ? ThemeColors.primary(this.isDark)
            : ThemeColors.onBackground(this.isDark))
        Text(item.desc)
          .fontSize(12)
          .fontColor(ThemeColors.secondaryText(this.isDark))
          .alignSelf(ItemAlign.Start)
          .maxLines(splitMode ? 1 : 2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      if (!splitMode) {
        Text($r('app.string.ui_091385be99'))
          .fontSize(18)
          .fontColor(ThemeColors.secondaryText(this.isDark))
      }
    }
    .padding({
      left: splitMode ? 12 : 14,
      right: 14,
      top: splitMode ? 12 : 14,
      bottom: splitMode ? 12 : 14
    })
    .width('100%')
    .backgroundColor(splitMode && this.selectedPage === item.page
      ? ThemeColors.primaryContainer(this.isDark)
      : ThemeColors.transparent())
    .borderRadius(splitMode ? 12 : 0)
    .margin(splitMode ? { left: 8, right: 8, top: 2, bottom: 2 } : { left: 0, right: 0, top: 0, bottom: 0 })
    .border(splitMode
      ? { width: 0 }
      : { width: { bottom: 1 }, color: ThemeColors.outlineVariant(this.isDark) })
  }
}
