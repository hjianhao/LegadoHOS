/**
 * 主页面 - Tab 框架
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

  /** 侧栏宽度：COMPACT 100%，MEDIUM/EXPANDED 96vp（图标），LARGE 200vp（图标+文字宽） */
  private get sideBarWidth(): number {
    if (!this.isWideLayout) return 0; // 底部 tab 时用 100%
    if (this.sizeClass >= WindowSizeClass.LARGE) return 200;
    return 96;
  }

  aboutToAppear(): void {
    // 统一启用 ArkUI 默认键盘避让，输入页和底部弹层在软键盘出现时自动压缩/平移。
    this.getUIContext().setKeyboardAvoidMode(UIKeyboardAvoidMode.RESIZE);
    // 「打开方式/分享」冷启动时 payload 可能已就绪
    this.consumeShareImport(this.pendingShareImport);
  }

  private onShareImport(): void {
    this.consumeShareImport(this.pendingShareImport);
  }

  /** 处理「打开方式/分享」收到的文件：json 弹书源导入预览，电子书切书架（书架页自行导入） */
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
        autoCancel: true, alignment: DialogAlignment.Bottom, customStyle: true
      });
      this.shareImportDlg.open();
    } catch (e) {
      console.error('[MainPage] openSharedJsonImport failed: ' + ((e as Error)?.message || e));
      UiUtil.showToast(this.getUIContext(), { message: '读取分享文件失败: ' + p.fileName, duration: 2000 });
    }
  }

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
    .barWidth(this.isWideLayout ? this.sideBarWidth : '100%')
    .barHeight(this.isWideLayout ? '100%' : 64)
    .scrollable(false)
    .animationDuration(220)
    .onChange((index: number): void => { this.currentTab = index; })
    .width('100%').height('100%')
    .backgroundColor(ThemeColors.background(this.isDark))
    .onAreaChange((_oldArea: Area, newArea: Area): void => {
      const width = typeof newArea.width === 'number' ? newArea.width : Number(newArea.width);
      const height = typeof newArea.height === 'number' ? newArea.height : Number(newArea.height);
      if (Number.isFinite(width) && Number.isFinite(height) && width > 0 && height > 0) {
        // px2vp 转换为 vp
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
