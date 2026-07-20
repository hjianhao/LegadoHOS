/**
 * 主页面 - Tab 框架
 *
 * 平板适配：
 * - 每个页签独立 Navigation + NavPathStack，支持页签内子页面导航栈
 * - 侧栏宽度按窗口分级（96vp / 200vp）
 * - NavDestination 路由表注册管理类页面，阅读器仍走 router（全屏目的页）
 */
import { BookshelfPage } from './BookshelfPage';
import { DiscoverPage } from './DiscoverPage';
import { MyPage } from './MyPage';
import { RssMainPage } from './RssMainPage';
import { ThemeColors } from '../theme/ThemeColors';
import { KeyboardAvoidMode as UIKeyboardAvoidMode } from '@kit.ArkUI';
import { ShareImportPayload } from '../service/ShareImportService';
import { ImportSourceDialog } from './ImportSourceDialog';
import { UiUtil } from '../util/UiUtil';
import { WindowLayout, WindowSizeClass } from '../util/WindowLayout';
import { NavRouter } from '../util/NavRouter';
import { BookSourcePage } from './BookSourcePage';
import { SettingsPage } from './SettingsPage';
import { SearchPage } from './SearchPage';
import { BookInfoPage } from './BookInfoPage';
import { ChapterListPage } from './ChapterListPage';
import { ChangeSourcePage } from './ChangeSourcePage';
import { BookshelfManagePage } from './BookshelfManagePage';
import { ReplaceRulePage } from './ReplaceRulePage';
import { FontManagerPage } from './FontManagerPage';
import { BackupSettingsPage } from './BackupSettingsPage';
import { AiConfigPage } from './AiConfigPage';
import { AiImportBookPage } from './AiImportBookPage';
import { CacheManagePage } from './CacheManagePage';
import { ReadRecordPage } from './ReadRecordPage';
import { RssSourceManagePage } from './RssSourceManagePage';
import { AboutPage } from './AboutPage';
import { BookSourceEditPage } from './BookSourceEditPage';
import { BookSourceDebugPage } from './BookSourceDebugPage';
import { ReplaceRuleEditPage } from './ReplaceRuleEditPage';
import fileIo from '@ohos.file.fs';
import util from '@ohos.util';

interface TabCfg {
  icon: ResourceStr;
  label: string;
}

@Entry
@Component
struct MainPage {
  @StorageLink('isDark') isDark: boolean = false;
  @State currentTab: number = 0;
  @StorageProp('windowSizeClass') sizeClass: WindowSizeClass = WindowSizeClass.COMPACT;
  @StorageLink('pendingShareImport') @Watch('onShareImport') pendingShareImport: ShareImportPayload | null = null;

  private lastShareImportId: number = 0;
  private shareImportDlg?: CustomDialogController;

  // 每个页签独立的导航栈
  @State bookshelfStack: NavPathStack = new NavPathStack();
  @State discoverStack: NavPathStack = new NavPathStack();
  @State rssStack: NavPathStack = new NavPathStack();
  @State myStack: NavPathStack = new NavPathStack();

  private tabs: TabCfg[] = [
    { icon: $r('app.media.ic_bookshelf'), label: '书架' },
    { icon: $r('app.media.ic_discover'), label: '发现' },
    { icon: $r('app.media.ic_rss'), label: 'RSS' },
    { icon: $r('app.media.ic_profile'), label: '我的' },
  ];

  /** 是否使用宽屏侧栏布局（>= MEDIUM） */
  private get isWideLayout(): boolean {
    return this.sizeClass >= WindowSizeClass.MEDIUM;
  }

  /** 侧栏宽度 */
  private get sideBarWidth(): number {
    if (!this.isWideLayout) return 0;
    if (this.sizeClass >= WindowSizeClass.LARGE) return 200;
    return 96;
  }

  aboutToAppear(): void {
    this.getUIContext().setKeyboardAvoidMode(UIKeyboardAvoidMode.RESIZE);
    // 注册各页签的 NavPathStack
    NavRouter.registerStack(0, this.bookshelfStack);
    NavRouter.registerStack(1, this.discoverStack);
    NavRouter.registerStack(2, this.rssStack);
    NavRouter.registerStack(3, this.myStack);
    NavRouter.setActiveTab(0);
    this.consumeShareImport(this.pendingShareImport);
  }

  private onShareImport(): void {
    this.consumeShareImport(this.pendingShareImport);
  }

  private consumeShareImport(p: ShareImportPayload | null): void {
    if (!p || p.id === this.lastShareImportId) return;
    this.lastShareImportId = p.id;
    if (p.kind === 'json') {
      this.openSharedJsonImport(p);
    } else if (p.kind === 'book') {
      this.currentTab = 0;
    } else {
      UiUtil.showToast(this.getUIContext(), { message: '不支持的文件类型: ' + p.fileName, duration: 2000 });
    }
  }

  private async openSharedJsonImport(p: ShareImportPayload): Promise<void> {
    try {
      const f = fileIo.openSync(p.uris[0], fileIo.OpenMode.READ_ONLY);
      const s = fileIo.statSync(f.fd);
      const buf = new ArrayBuffer(s.size);
      fileIo.readSync(f.fd, buf);
      fileIo.closeSync(f);
      const json = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf), { stream: false });
      this.shareImportDlg = new CustomDialogController({
        builder: ImportSourceDialog({
          controller: this.shareImportDlg!,
          initialJson: json,
          onImportSuccess: () => {
            UiUtil.showToast(this.getUIContext(), { message: '书源已导入', duration: 1500 });
          }
        }),
        autoCancel: true, alignment: UiUtil.adaptiveDialogAlignment(), customStyle: true
      });
      this.shareImportDlg.open();
    } catch (e) {
      console.error('[MainPage] openSharedJsonImport failed: ' + ((e as Error)?.message || e));
      UiUtil.showToast(this.getUIContext(), { message: '读取分享文件失败: ' + p.fileName, duration: 2000 });
    }
  }

  /** NavDestination 路由表：按页面名匹配组件 */
  @Builder
  navDestination(name: string, _param: object) {
    if (name === 'pages/BookSourcePage') {
      BookSourcePage()
    } else if (name === 'pages/SettingsPage') {
      SettingsPage()
    } else if (name === 'pages/SearchPage') {
      SearchPage()
    } else if (name === 'pages/BookInfoPage') {
      BookInfoPage()
    } else if (name === 'pages/ChapterListPage') {
      ChapterListPage()
    } else if (name === 'pages/ChangeSourcePage') {
      ChangeSourcePage()
    } else if (name === 'pages/BookshelfManagePage') {
      BookshelfManagePage()
    } else if (name === 'pages/ReplaceRulePage') {
      ReplaceRulePage()
    } else if (name === 'pages/FontManagerPage') {
      FontManagerPage()
    } else if (name === 'pages/BackupSettingsPage') {
      BackupSettingsPage()
    } else if (name === 'pages/AiConfigPage') {
      AiConfigPage()
    } else if (name === 'pages/AiImportBookPage') {
      AiImportBookPage()
    } else if (name === 'pages/CacheManagePage') {
      CacheManagePage()
    } else if (name === 'pages/ReadRecordPage') {
      ReadRecordPage()
    } else if (name === 'pages/RssSourceManagePage') {
      RssSourceManagePage()
    } else if (name === 'pages/AboutPage') {
      AboutPage()
    } else if (name === 'pages/BookSourceEditPage') {
      BookSourceEditPage()
    } else if (name === 'pages/BookSourceDebugPage') {
      BookSourceDebugPage()
    } else if (name === 'pages/ReplaceRuleEditPage') {
      ReplaceRuleEditPage()
    } else {
      // 未注册的页面回退到空白
      Column() {
        Text('页面未注册: ' + name).fontSize(14).fontColor(ThemeColors.error(this.isDark))
      }.width('100%').height('100%').justifyContent(FlexAlign.Center)
    }
  }

  build() {
    Tabs({
      barPosition: this.isWideLayout ? BarPosition.Start : BarPosition.End,
      index: this.currentTab
    }) {
      TabContent() {
        Navigation(this.bookshelfStack) {
          BookshelfPage()
        }
        .navDestination(this.navDestination)
        .hideTitleBar(true)
        .mode(NavigationMode.Stack)
      }.tabBar(this.buildTab(this.tabs[0], 0))

      TabContent() {
        Navigation(this.discoverStack) {
          DiscoverPage()
        }
        .navDestination(this.navDestination)
        .hideTitleBar(true)
        .mode(NavigationMode.Stack)
      }.tabBar(this.buildTab(this.tabs[1], 1))

      TabContent() {
        Navigation(this.rssStack) {
          RssMainPage()
        }
        .navDestination(this.navDestination)
        .hideTitleBar(true)
        .mode(NavigationMode.Stack)
      }.tabBar(this.buildTab(this.tabs[2], 2))

      TabContent() {
        Navigation(this.myStack) {
          MyPage()
        }
        .navDestination(this.navDestination)
        .hideTitleBar(true)
        .mode(NavigationMode.Stack)
      }.tabBar(this.buildTab(this.tabs[3], 3))
    }
    .vertical(this.isWideLayout)
    .barWidth(this.isWideLayout ? this.sideBarWidth : '100%')
    .barHeight(this.isWideLayout ? '100%' : 64)
    .scrollable(false)
    .animationDuration(220)
    .onChange((index: number): void => {
      this.currentTab = index;
      NavRouter.setActiveTab(index);
    })
    .width('100%').height('100%')
    .backgroundColor(ThemeColors.background(this.isDark))
    .onAreaChange((_oldArea: Area, newArea: Area): void => {
      const width = typeof newArea.width === 'number' ? newArea.width : Number(newArea.width);
      const height = typeof newArea.height === 'number' ? newArea.height : Number(newArea.height);
      if (Number.isFinite(width) && Number.isFinite(height) && width > 0 && height > 0) {
        const widthVp = this.getUIContext().px2vp(width);
        const heightVp = this.getUIContext().px2vp(height);
        WindowLayout.update(widthVp, heightVp);
      }
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
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width(this.isWideLayout ? this.sideBarWidth : '100%')
    .height(56)
    .justifyContent(FlexAlign.Center)
    .accessibilityText(tab.label)
    .accessibilityDescription('双击切换到' + tab.label)
  }
}
