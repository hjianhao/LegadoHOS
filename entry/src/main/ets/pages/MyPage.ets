/**
 * 我的页面
 *
 * 宽屏：左导航（固定/限宽）+ 右详情（layoutWeight 吃剩余空间）
 * 窄屏：单列 + classic router
 *
 * 真机踩坑：Row 里仅 .width(280) 会被 List 内容撑满整屏，右侧 layoutWeight 变成 0。
 * 必须 constraintSize maxWidth + flexShrink(0) + 右侧 minWidth(0)。
 */
import { AppTheme } from '../theme/AppTheme';
import { ThemeColors } from '../theme/ThemeColors';
import { UiUtil } from '../util/UiUtil';
import { WindowLayout } from '../util/WindowLayout';
import display from '@ohos.display';
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

/** 左侧导航固定宽度（vp） */
const NAV_PANE_WIDTH = 300;

@Component
export struct MyPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State localWidthVp: number = 0;
  @State useSplitNav: boolean = false;
  /**
   * 当前详情页。用 @State 驱动右侧重建；同时写入 AppStorage 供 UiUtil.back 清空。
   */
  @State selectedPage: string = '';
  /** UiUtil.back 清空详情时递增，驱动本页同步 */
  @StorageLink('myEmbeddedDetailCleared') @Watch('onEmbeddedCleared') embeddedClearToken: number = 0;

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
    AppStorage.setOrCreate('myEmbeddedDetail', '');
    AppStorage.setOrCreate('myEmbeddedDetailCleared', 0);
    this.syncSplitFromDisplay('aboutToAppear');
    // 宽屏默认打开设置，避免右侧空白被误认为「没分栏」
    if (this.useSplitNav && this.selectedPage.length === 0) {
      this.selectPage('pages/SettingsPage');
    }
  }

  onPageShow(): void {
    this.syncSplitFromDisplay('onPageShow');
  }

  private onEmbeddedCleared(): void {
    // 子页点返回：右侧回到默认「设置」（不销毁分栏）
    if (this.useSplitNav) {
      this.selectPage('pages/SettingsPage');
    }
  }

  private syncSplitFromDisplay(reason: string): void {
    try {
      const d = display.getDefaultDisplaySync();
      const density = d.densityPixels > 0.1 ? d.densityPixels : 2.5;
      this.applySplitState(d.width / density, d.height / density, reason + '/display');
      return;
    } catch (e) {
      console.warn('[MyPage] display probe failed:', e);
    }
    if (WindowLayout.widthVp >= 600) {
      this.applySplitState(WindowLayout.widthVp, WindowLayout.heightVp, reason + '/cached');
    }
  }

  private applySplitState(wVp: number, hVp: number, reason: string): void {
    if (wVp <= 0) {
      return;
    }
    this.localWidthVp = wVp;
    const split = wVp >= 600;
    this.useSplitNav = split;
    WindowLayout.update(wVp, hVp);
    console.info('[MyPage] useSplitNav=' + this.useSplitNav + ' wVp=' + wVp.toFixed(1) +
      ' reason=' + reason);
  }

  private selectPage(page: string): void {
    this.selectedPage = page;
    AppStorage.setOrCreate('myEmbeddedDetail', page);
  }

  private clearDetail(): void {
    this.selectedPage = '';
    AppStorage.setOrCreate('myEmbeddedDetail', '');
  }

  goTo(page: string): void {
    if (!page) {
      return;
    }
    if (!this.useSplitNav && this.localWidthVp < 600) {
      this.syncSplitFromDisplay('goTo');
    }
    console.info('[MyPage] goTo ' + page + ' split=' + this.useSplitNav +
      ' wVp=' + this.localWidthVp);
    if (this.useSplitNav) {
      this.selectPage(page);
      return;
    }
    UiUtil.pushUrl(this.getUIContext(), { url: page });
  }

  build() {
    if (this.useSplitNav) {
      this.buildSplitLayout()
    } else {
      this.buildCompactLayout()
    }
  }

  /**
   * 左右分栏：左侧硬约束宽度，右侧吃满剩余。
   * 不用会把左栏撑满的「仅 .width(n)」。
   */
  @Builder
  private buildSplitLayout() {
    Row() {
      // —— 左：导航 ——
      Column() {
        this.buildProfileHeader(true)
        List() {
          ForEach(this.menuItems, (item: MenuEntry) => {
            ListItem() {
              this.buildMenuRow(item, true)
            }
            .width(NAV_PANE_WIDTH)
            .accessibilityText(item.title)
            .accessibilityDescription(item.desc)
            .onClick(() => {
              this.goTo(item.page);
            })
          }, (item: MenuEntry) => item.page)
        }
        .width(NAV_PANE_WIDTH)
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
        .divider({
          strokeWidth: 0,
        })
      }
      .width(NAV_PANE_WIDTH)
      .constraintSize({ minWidth: NAV_PANE_WIDTH, maxWidth: NAV_PANE_WIDTH })
      .height('100%')
      .flexShrink(0)
      .flexGrow(0)
      .clip(true)
      .backgroundColor(ThemeColors.surface(this.isDark))

      // 分隔线
      Column()
        .width(1)
        .height('100%')
        .backgroundColor(ThemeColors.outlineVariant(this.isDark))
        .flexShrink(0)

      // —— 右：详情 ——
      Column() {
        if (this.selectedPage.length === 0) {
          this.buildEmptyDetail()
        } else {
          this.buildEmbeddedDetail()
        }
      }
      .layoutWeight(1)
      .flexGrow(1)
      .flexShrink(1)
      .constraintSize({ minWidth: 0 })
      .height('100%')
      .clip(true)
      .backgroundColor(ThemeColors.background(this.isDark))
    }
    .width('100%')
    .height('100%')
    .alignItems(VerticalAlign.Top)
    .backgroundColor(ThemeColors.background(this.isDark))
    .onAreaChange((_o: Area, area: Area) => {
      const w = typeof area.width === 'number' ? area.width : Number(area.width);
      if (Number.isFinite(w) && w > 0) {
        console.info('[MyPage] split Row area w=' + w + ' selected=' + this.selectedPage);
      }
    })
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
    // 必须包一层限制宽高，避免 @Entry 子页按整屏测量
    Column() {
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
    .width('100%')
    .height('100%')
    .clip(true)
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
    .width(splitMode ? NAV_PANE_WIDTH : '100%')
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
          .margin({ right: 8 })
      }
      Text(item.icon)
        .fontSize(splitMode ? 18 : 22)
        .margin({ right: 10 })
        .fontColor(this.selectedPage === item.page
          ? ThemeColors.primary(this.isDark)
          : ThemeColors.onBackground(this.isDark))
      Column() {
        Text(item.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .alignSelf(ItemAlign.Start)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor(this.selectedPage === item.page
            ? ThemeColors.primary(this.isDark)
            : ThemeColors.onBackground(this.isDark))
        Text(item.desc)
          .fontSize(11)
          .fontColor(ThemeColors.secondaryText(this.isDark))
          .alignSelf(ItemAlign.Start)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .constraintSize({ minWidth: 0 })
      if (!splitMode) {
        Text($r('app.string.ui_091385be99'))
          .fontSize(18)
          .fontColor(ThemeColors.secondaryText(this.isDark))
      }
    }
    .padding({
      left: splitMode ? 10 : 14,
      right: splitMode ? 10 : 14,
      top: splitMode ? 10 : 14,
      bottom: splitMode ? 10 : 14
    })
    .width(splitMode ? NAV_PANE_WIDTH - 16 : '100%')
    .backgroundColor(splitMode && this.selectedPage === item.page
      ? ThemeColors.primaryContainer(this.isDark)
      : ThemeColors.transparent())
    .borderRadius(splitMode ? 10 : 0)
    .margin(splitMode ? { left: 8, right: 8, top: 2, bottom: 2 } : { left: 0, right: 0, top: 0, bottom: 0 })
    .border(splitMode
      ? { width: 0 }
      : { width: { bottom: 1 }, color: ThemeColors.outlineVariant(this.isDark) })
  }
}
