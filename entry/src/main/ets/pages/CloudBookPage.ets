/**
 * 云端书籍页
 *
 * 两级结构：
 * 1) 书库列表：展示已配置的云端来源
 * 2) 目录浏览：进入某来源后读取并显示远程目录
 */
import { AppDatabase } from '../data/database/AppDatabase';
import { CloudCredentialStore } from '../data/preferences/CloudCredentialStore';
import { SettingsStore } from '../data/preferences/SettingsStore';
import {
  CloudBookListItem,
  displayStateLabel,
  formatFileSize,
  formatModifiedAt,
  CLOUD_DISPLAY_CLOUD_ONLY,
  CLOUD_DISPLAY_DIRECTORY,
  CLOUD_DISPLAY_DOWNLOADED,
  CLOUD_DISPLAY_DOWNLOADING,
  CLOUD_DISPLAY_ERROR,
  CLOUD_DISPLAY_OUTDATED,
} from '../model/CloudBookListItem';
import { CloudSource, cloudProviderDisplayName } from '../model/CloudSource';
import {
  CloudBookRepository,
  CLOUD_SORT_NAME_ASC,
  CLOUD_SORT_NAME_DESC,
  CLOUD_SORT_TIME_ASC,
  CLOUD_SORT_TIME_DESC,
  CloudBookSortMode,
} from '../service/cloud/CloudBookRepository';
import {
  CloudTransferManager,
  CloudTransferTask,
  CLOUD_TRANSFER_FAILED,
  CLOUD_TRANSFER_SUCCESS,
} from '../service/cloud/CloudTransferManager';
import { CloudPath } from '../service/cloud/CloudPath';
import { CloudSourceRepository } from '../service/cloud/CloudSourceRepository';
import { ensureCloudProvidersRegistered } from '../service/cloud/CloudProviderBootstrap';
import { OptionItem, OptionSelectSheet } from '../components/BookInfoSheets';
import { ThemeColors } from '../theme/ThemeColors';
import { UiUtil } from '../util/UiUtil';
import { common } from '@kit.AbilityKit';

@Entry
@Component
export struct CloudBookPage {
  @StorageLink('isDark') isDark: boolean = false;

  /** false = 书库列表；true = 已进入某来源目录 */
  @State inBrowse: boolean = false;
  @State sources: CloudSource[] = [];
  @State currentSourceId: number = 0;
  @State currentSourceName: string = '';
  @State currentRootPath: string = '';
  @State currentPath: string = '';
  @State breadcrumbNames: string[] = [];
  @State breadcrumbPaths: string[] = [];
  @State allItems: CloudBookListItem[] = [];
  @State viewItems: CloudBookListItem[] = [];
  @State searchKey: string = '';
  @State sortMode: CloudBookSortMode = CLOUD_SORT_NAME_ASC;
  @State sortLabel: string = '名称';
  @State isLoading: boolean = true;
  @State errorText: string = '';
  @State statusHint: string = '';
  @State selectMode: boolean = false;
  @State selectedPaths: string[] = [];
  @State downloadHint: string = '';

  private repo_: CloudBookRepository | null = null;
  private optionSheetController: CustomDialogController | null = null;
  private transferListener_: ((task: CloudTransferTask) => void) | null = null;

  aboutToAppear(): void {
    this.bootstrap_();
    this.bindTransfer_();
  }

  aboutToDisappear(): void {
    this.unbindTransfer_();
  }

  /**
   * 拦截系统返回键 / 侧滑手势。
   * 目录浏览是页内状态，不是路由栈；不拦截会直接退出到「我的」。
   * @returns true 表示已消费返回事件
   */
  onBackPress(): boolean {
    if (this.inBrowse) {
      if (this.currentPath) {
        // 子目录 → 上级
        this.loadDirectory_(CloudPath.parent(this.currentPath));
      } else {
        // 书库根 → 书库列表
        this.exitToLibraryList_();
      }
      return true;
    }
    // 书库列表：交给系统 pop 页面
    return false;
  }

  onPageShow(): void {
    if (this.isLoading) {
      return;
    }
    // 从管理页返回：刷新书库列表；若正在浏览则刷新当前目录
    this.reloadSources_().then(() => {
      if (this.inBrowse && this.currentSourceId > 0) {
        return this.loadDirectory_(this.currentPath);
      }
      return Promise.resolve();
    }).catch(() => {});
  }

  private bindTransfer_(): void {
    if (this.transferListener_) {
      return;
    }
    this.transferListener_ = (task: CloudTransferTask): void => {
      this.onTransferUpdate_(task);
    };
    CloudTransferManager.getInstance().subscribe(this.transferListener_);
  }

  private unbindTransfer_(): void {
    if (this.transferListener_) {
      CloudTransferManager.getInstance().unsubscribe(this.transferListener_);
      this.transferListener_ = null;
    }
  }

  private onTransferUpdate_(task: CloudTransferTask): void {
    if (!this.inBrowse || task.sourceId !== this.currentSourceId) {
      return;
    }
    // 刷新进度叠加
    this.refreshTransferOverlay_();
    if (task.status === CLOUD_TRANSFER_SUCCESS) {
      this.downloadHint = '已下载: ' + task.fileName;
      // 成功后静默刷新目录状态
      this.loadDirectory_(this.currentPath, true);
    } else if (task.status === CLOUD_TRANSFER_FAILED) {
      this.downloadHint = '失败: ' + (task.error || task.fileName);
    }
  }

  private refreshTransferOverlay_(): void {
    if (!this.repo_) {
      return;
    }
    const overlaid = this.repo_.applyTransferOverlay(this.allItems);
    this.allItems = overlaid;
    this.applyFilterSort_();
  }

  private async bootstrap_(): Promise<void> {
    this.isLoading = true;
    this.errorText = '';
    try {
      ensureCloudProvidersRegistered();
      await AppDatabase.getInstance().waitForInit();
      const ctx = this.getUIContext().getHostContext() as common.Context;
      if (ctx) {
        await SettingsStore.getInstance().init(ctx);
        await CloudCredentialStore.getInstance().init(ctx);
      } else if (!CloudCredentialStore.getInstance().isReady()) {
        throw new Error('无法获取 Context，凭证存储未就绪');
      }
      this.repo_ = new CloudBookRepository();

      // 路由可深链进入某来源：?sourceId=&path=
      const params = UiUtil.getParams(this.getUIContext()) as Record<string, Object>;
      let preferSourceId = 0;
      let preferPath = '';
      if (params) {
        const sid = params['sourceId'];
        if (typeof sid === 'number') {
          preferSourceId = sid as number;
        } else if (typeof sid === 'string') {
          preferSourceId = parseInt(sid as string, 10) || 0;
        }
        const p = params['path'];
        if (typeof p === 'string') {
          try {
            preferPath = CloudPath.normalizeRemotePath(decodeURIComponent(p as string));
          } catch (_e) {
            preferPath = '';
          }
        }
      }

      await this.reloadSources_();

      // 默认停在书库列表；仅路由指定 sourceId 时直接进入目录
      if (preferSourceId > 0 && this.findSource_(preferSourceId)) {
        await this.enterSource_(preferSourceId, preferPath);
      } else {
        this.inBrowse = false;
        this.currentSourceId = 0;
        this.clearBrowseState_();
      }
    } catch (e) {
      this.errorText = (e as Error).message || '初始化失败';
      console.error('[CloudBookPage] bootstrap failed:', this.errorText);
    } finally {
      this.isLoading = false;
    }
  }

  private async reloadSources_(): Promise<void> {
    const sourceRepo = new CloudSourceRepository();
    const all = await sourceRepo.listAll();
    this.sources = all.slice();
    if (this.currentSourceId > 0 && this.findSource_(this.currentSourceId)) {
      this.applySourceMeta_(this.currentSourceId);
    }
  }

  private findSource_(id: number): CloudSource | null {
    for (let i = 0; i < this.sources.length; i++) {
      if (this.sources[i].id === id) {
        return this.sources[i];
      }
    }
    return null;
  }

  private applySourceMeta_(sourceId: number): void {
    const s = this.findSource_(sourceId);
    if (s) {
      this.currentSourceName = s.name;
      this.currentRootPath = s.rootPath || '';
    } else {
      this.currentSourceName = '';
      this.currentRootPath = '';
    }
  }

  private clearBrowseState_(): void {
    this.currentPath = '';
    this.breadcrumbNames = [];
    this.breadcrumbPaths = [];
    this.allItems = [];
    this.viewItems = [];
    this.searchKey = '';
    this.statusHint = '';
    this.errorText = '';
    this.currentSourceName = '';
    this.currentRootPath = '';
  }

  /** 从书库列表进入某来源根目录（或指定 path） */
  private async enterSource_(sourceId: number, remotePath: string = ''): Promise<void> {
    const s = this.findSource_(sourceId);
    if (!s) {
      UiUtil.showToast(this.getUIContext(), { message: '来源不存在', duration: 1500 });
      return;
    }
    if (!s.enabled) {
      UiUtil.showToast(this.getUIContext(), { message: '该来源已禁用', duration: 1500 });
      return;
    }
    this.currentSourceId = sourceId;
    this.applySourceMeta_(sourceId);
    this.inBrowse = true;
    this.searchKey = '';
    await this.loadDirectory_(remotePath || '');
  }

  /** 退出目录，回到书库列表 */
  private exitToLibraryList_(): void {
    this.inBrowse = false;
    this.currentSourceId = 0;
    this.clearBrowseState_();
    this.isLoading = false;
  }

  private async loadDirectory_(remotePath: string, silent: boolean = false): Promise<void> {
    if (this.currentSourceId <= 0) {
      return;
    }
    if (!this.repo_) {
      this.repo_ = new CloudBookRepository();
    }
    if (!silent) {
      this.isLoading = true;
      this.errorText = '';
    }
    this.statusHint = '';
    try {
      const path = CloudPath.normalizeRemotePath(remotePath || '');
      const result = await this.repo_.listDirectory(this.currentSourceId, path);
      this.currentPath = result.remotePath;
      this.applySourceMeta_(result.source.id);

      const names: string[] = [];
      const paths: string[] = [];
      for (let i = 0; i < result.breadcrumbs.length; i++) {
        names.push(result.breadcrumbs[i].name);
        paths.push(result.breadcrumbs[i].path);
      }
      this.breadcrumbNames = names;
      this.breadcrumbPaths = paths;

      this.allItems = this.repo_.applyTransferOverlay(result.items.slice());
      this.applyFilterSort_();
      this.statusHint = result.items.length + ' 项';
    } catch (e) {
      if (!silent) {
        this.errorText = (e as Error).message || '加载失败';
        this.allItems = [];
        this.viewItems = [];
      }
      console.warn('[CloudBookPage] loadDirectory failed:', (e as Error).message);
    } finally {
      if (!silent) {
        this.isLoading = false;
      }
    }
  }

  private applyFilterSort_(): void {
    if (!this.repo_) {
      this.repo_ = new CloudBookRepository();
    }
    this.viewItems = this.repo_.filterAndSort(this.allItems, this.searchKey, this.sortMode);
  }

  private enterDir_(item: CloudBookListItem): void {
    if (!item.file.isDirectory) {
      return;
    }
    this.searchKey = '';
    this.loadDirectory_(item.file.remotePath);
  }

  private goBreadcrumb_(index: number): void {
    if (index < 0) {
      this.loadDirectory_('');
      return;
    }
    if (index >= this.breadcrumbPaths.length) {
      return;
    }
    this.loadDirectory_(this.breadcrumbPaths[index]);
  }

  private goUp_(): void {
    if (!this.currentPath) {
      // 已在来源根：返回书库列表
      this.exitToLibraryList_();
      return;
    }
    this.loadDirectory_(CloudPath.parent(this.currentPath));
  }

  private onBack_(): void {
    if (this.inBrowse) {
      if (this.currentPath) {
        this.goUp_();
      } else {
        this.exitToLibraryList_();
      }
      return;
    }
    UiUtil.back(this.getUIContext());
  }

  private openManage_(): void {
    UiUtil.pushUrl(this.getUIContext(), { url: 'pages/CloudSourceManagePage' });
  }

  private openEditSource_(sourceId: number): void {
    if (sourceId > 0) {
      UiUtil.pushUrl(this.getUIContext(), {
        url: 'pages/CloudSourceEditPage',
        params: { sourceId: sourceId },
      });
    } else {
      UiUtil.pushUrl(this.getUIContext(), { url: 'pages/CloudSourceEditPage' });
    }
  }

  private showOptionSheet_(title: string, message: string, options: OptionItem[]): void {
    if (this.optionSheetController) {
      try {
        this.optionSheetController.close();
      } catch (_e) { /* ignore */ }
      this.optionSheetController = null;
    }
    this.optionSheetController = new CustomDialogController({
      builder: OptionSelectSheet({
        title: title,
        message: message,
        options: options,
      }),
      autoCancel: true,
      alignment: UiUtil.adaptiveDialogAlignment(),
      customStyle: true,
      cornerRadius: 16,
    });
    this.optionSheetController.open();
  }

  private showSortPicker_(): void {
    const options: OptionItem[] = [
      {
        title: '名称升序',
        action: () => {
          this.sortMode = CLOUD_SORT_NAME_ASC;
          this.sortLabel = '名称';
          this.applyFilterSort_();
        },
      },
      {
        title: '名称降序',
        action: () => {
          this.sortMode = CLOUD_SORT_NAME_DESC;
          this.sortLabel = '名称↓';
          this.applyFilterSort_();
        },
      },
      {
        title: '修改时间新→旧',
        action: () => {
          this.sortMode = CLOUD_SORT_TIME_DESC;
          this.sortLabel = '时间';
          this.applyFilterSort_();
        },
      },
      {
        title: '修改时间旧→新',
        action: () => {
          this.sortMode = CLOUD_SORT_TIME_ASC;
          this.sortLabel = '时间↑';
          this.applyFilterSort_();
        },
      },
    ];
    this.showOptionSheet_('排序方式', '', options);
  }

  private onItemClick_(item: CloudBookListItem): void {
    if (this.selectMode && !item.file.isDirectory) {
      this.toggleSelect_(item.file.remotePath);
      return;
    }
    if (item.file.isDirectory || item.displayState === CLOUD_DISPLAY_DIRECTORY) {
      this.enterDir_(item);
      return;
    }
    if (item.displayState === CLOUD_DISPLAY_DOWNLOADING) {
      UiUtil.showToast(this.getUIContext(), { message: '正在下载…', duration: 1200 });
      return;
    }
    if (item.displayState === CLOUD_DISPLAY_DOWNLOADED || item.displayState === CLOUD_DISPLAY_OUTDATED) {
      if (item.localBook && item.localFileExists) {
        UiUtil.pushUrl(this.getUIContext(), {
          url: 'pages/BookInfoPage',
          params: {
            bookUrl: item.localBook.bookUrl,
            noteUrl: item.localBook.bookUrl,
            origin: item.localBook.origin,
            originUrl: item.localBook.originUrl,
          },
        });
        return;
      }
      // 本地丢失：允许重新下载
      this.startDownload_(item);
      return;
    }
    if (!item.importSupported) {
      UiUtil.showToast(this.getUIContext(), {
        message: '暂不支持导入此格式',
        duration: 1500,
      });
      return;
    }
    // 云端 / 错误 → 下载
    this.startDownload_(item);
  }

  private startDownload_(item: CloudBookListItem): void {
    if (!this.repo_ || this.currentSourceId <= 0) {
      return;
    }
    if (!item.importSupported) {
      UiUtil.showToast(this.getUIContext(), { message: '不支持的格式', duration: 1500 });
      return;
    }
    this.downloadHint = '开始下载: ' + item.file.name;
    // 先本地标为下载中
    this.refreshTransferOverlay_();
    this.repo_.downloadAndImport(this.currentSourceId, item.file.remotePath, item.file)
      .then((r) => {
        if (r.success) {
          UiUtil.showToast(this.getUIContext(), {
            message: '已加入书架: ' + (r.bookName || item.file.name),
            duration: 2000,
          });
          this.loadDirectory_(this.currentPath, true);
        } else {
          UiUtil.showToast(this.getUIContext(), {
            message: r.error || '下载失败',
            duration: 2500,
          });
          this.refreshTransferOverlay_();
        }
      })
      .catch((e: Error) => {
        UiUtil.showToast(this.getUIContext(), {
          message: e.message || '下载失败',
          duration: 2500,
        });
      });
    // 立即叠加进度状态
    setTimeout(() => {
      this.refreshTransferOverlay_();
    }, 50);
  }

  private toggleSelect_(remotePath: string): void {
    const next: string[] = [];
    let found = false;
    for (let i = 0; i < this.selectedPaths.length; i++) {
      if (this.selectedPaths[i] === remotePath) {
        found = true;
      } else {
        next.push(this.selectedPaths[i]);
      }
    }
    if (!found) {
      next.push(remotePath);
    }
    this.selectedPaths = next;
  }

  private isSelected_(remotePath: string): boolean {
    return this.selectedPaths.indexOf(remotePath) >= 0;
  }

  private async downloadSelected_(): Promise<void> {
    if (!this.repo_ || this.currentSourceId <= 0 || this.selectedPaths.length === 0) {
      return;
    }
    const files: CloudBookListItem[] = [];
    for (let i = 0; i < this.allItems.length; i++) {
      const it = this.allItems[i];
      if (!it.file.isDirectory && this.isSelected_(it.file.remotePath) && it.importSupported) {
        files.push(it);
      }
    }
    if (files.length === 0) {
      UiUtil.showToast(this.getUIContext(), { message: '没有可下载的文件', duration: 1500 });
      return;
    }
    this.downloadHint = '批量下载 ' + files.length + ' 项…';
    this.selectMode = false;
    this.selectedPaths = [];
    const jobs: Promise<void>[] = [];
    for (let i = 0; i < files.length; i++) {
      const item = files[i];
      jobs.push(
        this.repo_.downloadAndImport(this.currentSourceId, item.file.remotePath, item.file).then((r) => {
          if (!r.success) {
            console.warn('[CloudBookPage] batch item failed:', item.file.name, r.error);
          }
        })
      );
    }
    this.refreshTransferOverlay_();
    try {
      for (let i = 0; i < jobs.length; i++) {
        await jobs[i];
      }
      await this.loadDirectory_(this.currentPath, true);
      let ok = 0;
      let fail = 0;
      for (let i = 0; i < files.length; i++) {
        const t = CloudTransferManager.getInstance().getTask(
          this.currentSourceId, files[i].file.remotePath);
        if (t && t.status === CLOUD_TRANSFER_SUCCESS) {
          ok++;
        } else {
          fail++;
        }
      }
      this.downloadHint = '批量完成: 成功 ' + ok + (fail > 0 ? ('，失败 ' + fail) : '');
      UiUtil.showToast(this.getUIContext(), { message: this.downloadHint, duration: 2500 });
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), {
        message: (e as Error).message || '批量下载失败',
        duration: 2000,
      });
    }
  }

  private stateColor_(state: string): string {
    if (state === CLOUD_DISPLAY_DOWNLOADED) {
      return ThemeColors.success(this.isDark);
    }
    if (state === CLOUD_DISPLAY_OUTDATED) {
      return ThemeColors.warning(this.isDark);
    }
    if (state === CLOUD_DISPLAY_ERROR) {
      return ThemeColors.error(this.isDark);
    }
    if (state === CLOUD_DISPLAY_DIRECTORY) {
      return ThemeColors.primary(this.isDark);
    }
    if (state === CLOUD_DISPLAY_DOWNLOADING) {
      return ThemeColors.primary(this.isDark);
    }
    return ThemeColors.secondaryText(this.isDark);
  }

  private progressText_(item: CloudBookListItem): string {
    if (!item.progress) {
      return '下载中…';
    }
    const r = item.progress.received;
    const t = item.progress.total;
    if (t > 0) {
      const pct = Math.min(100, Math.floor((r / t) * 100));
      return '下载中 ' + pct + '%';
    }
    if (r > 0) {
      return '已收 ' + formatFileSize(r);
    }
    return '下载中…';
  }

  private rootBreadcrumbLabel_(): string {
    if (this.currentSourceName) {
      return this.currentSourceName;
    }
    if (this.currentRootPath) {
      return this.currentRootPath;
    }
    return '根目录';
  }

  private previewLine_(source: CloudSource): string {
    try {
      return CloudPath.previewUrl(source.endpoint, source.rootPath, '');
    } catch (_e) {
      return source.endpoint;
    }
  }

  build() {
    Column() {
      // 顶栏
      Row() {
        Button({ type: ButtonType.Normal }) {
          Text('返回').fontSize(16).fontColor(ThemeColors.primary(this.isDark))
        }
        .backgroundColor(ThemeColors.transparent())
        .onClick(() => {
          this.onBack_();
        })

        Text(this.inBrowse ? (this.currentSourceName || '云端目录') : '云端书库')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark))
          .margin({ left: 8 })
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (!this.inBrowse) {
          Button({ type: ButtonType.Normal }) {
            Text('管理').fontSize(14).fontColor(ThemeColors.primary(this.isDark)).fontWeight(FontWeight.Bold)
          }
          .backgroundColor(ThemeColors.transparent())
          .onClick(() => {
            this.openManage_();
          })
        } else {
          Button({ type: ButtonType.Normal }) {
            Text('刷新').fontSize(14).fontColor(ThemeColors.primary(this.isDark)).fontWeight(FontWeight.Bold)
          }
          .backgroundColor(ThemeColors.transparent())
          .enabled(!this.isLoading)
          .onClick(() => {
            this.loadDirectory_(this.currentPath);
          })
        }
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 8, bottom: 4 })

      if (!this.inBrowse) {
        this.buildLibraryList_()
      } else {
        this.buildBrowse_()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemeColors.background(this.isDark))
  }

  /** 第一级：云端书库（来源）列表 */
  @Builder
  private buildLibraryList_() {
    Column() {
      Text('选择一个云端书库进入浏览。每个书库对应独立 WebDAV 根目录。')
        .fontSize(12)
        .fontColor(ThemeColors.secondaryText(this.isDark))
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })

      if (this.isLoading) {
        Column() {
          LoadingProgress().width(36).height(36).color(ThemeColors.primary(this.isDark))
          Text('加载中…').fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 8 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.errorText && this.sources.length === 0) {
        Column() {
          Text(this.errorText)
            .fontSize(14)
            .fontColor(ThemeColors.error(this.isDark))
            .padding({ left: 24, right: 24 })
            .textAlign(TextAlign.Center)
          Button('重试')
            .margin({ top: 12 })
            .onClick(() => {
              this.bootstrap_();
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.sources.length === 0) {
        Column() {
          Text('尚未配置云端书库')
            .fontSize(15)
            .fontColor(ThemeColors.secondaryText(this.isDark))
          Text('添加 WebDAV 来源后即可浏览云端书籍')
            .fontSize(12)
            .fontColor(ThemeColors.secondaryText(this.isDark))
            .margin({ top: 8 })
          Button('新增书库')
            .margin({ top: 16 })
            .backgroundColor(ThemeColors.primary(this.isDark))
            .fontColor(ThemeColors.onPrimary(this.isDark))
            .onClick(() => {
              this.openEditSource_(0);
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.sources, (source: CloudSource) => {
            ListItem() {
              Row() {
                Text('☁')
                  .fontSize(24)
                  .width(40)
                  .textAlign(TextAlign.Center)

                Column() {
                  Text(source.name)
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(ThemeColors.onSurface(this.isDark))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  Text(this.previewLine_(source))
                    .fontSize(11)
                    .fontColor(ThemeColors.secondaryText(this.isDark))
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 4 })
                    .width('100%')
                  Row() {
                    Text(cloudProviderDisplayName(source.providerType || 'webdav'))
                      .fontSize(10)
                      .fontColor(ThemeColors.primary(this.isDark))
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                      .border({
                        width: 0.5,
                        color: ThemeColors.primary(this.isDark),
                        radius: 4,
                      })
                    Text(source.rootPath ? ('根目录: ' + source.rootPath) : '根目录: (服务器根)')
                      .fontSize(10)
                      .fontColor(ThemeColors.secondaryText(this.isDark))
                      .margin({ left: 8 })
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    if (!source.enabled) {
                      Text('已禁用')
                        .fontSize(10)
                        .fontColor(ThemeColors.error(this.isDark))
                        .margin({ left: 6 })
                    }
                  }
                  .width('100%')
                  .margin({ top: 6 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                .margin({ left: 4 })

                Text('›')
                  .fontSize(22)
                  .fontColor(ThemeColors.secondaryText(this.isDark))
              }
              .width('100%')
              .padding(14)
              .backgroundColor(ThemeColors.surface(this.isDark))
              .borderRadius(12)
              .margin({ left: 12, right: 12, bottom: 10 })
              .opacity(source.enabled ? 1 : 0.55)
              .onClick(() => {
                this.enterSource_(source.id, '');
              })
            }
          }, (source: CloudSource) => source.id.toString() + '_' + source.updatedAt.toString())
        }
        .width('100%')
        .layoutWeight(1)
        .edgeEffect(EdgeEffect.Spring)

        // 底部快捷：新增
        Row() {
          Button('新增书库')
            .layoutWeight(1)
            .height(42)
            .backgroundColor(ThemeColors.primary(this.isDark))
            .fontColor(ThemeColors.onPrimary(this.isDark))
            .onClick(() => {
              this.openEditSource_(0);
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 16 })
      }
    }
    .width('100%')
    .layoutWeight(1)
  }

  /** 第二级：某书库内的目录浏览 */
  @Builder
  private buildBrowse_() {
    Column() {
      // 来源摘要 + 返回列表
      Row() {
        Column() {
          Text(this.currentRootPath ? ('根目录: ' + this.currentRootPath) : '根目录: (服务器根)')
            .fontSize(12)
            .fontColor(ThemeColors.secondaryText(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Button('书库列表')
          .fontSize(12)
          .height(30)
          .backgroundColor(ThemeColors.outlineVariant(this.isDark))
          .fontColor(ThemeColors.primary(this.isDark))
          .onClick(() => {
            this.exitToLibraryList_();
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 2, bottom: 6 })

      // 面包屑
      Scroll() {
        Row() {
          Text(this.rootBreadcrumbLabel_())
            .fontSize(13)
            .fontColor(this.currentPath ? ThemeColors.primary(this.isDark) : ThemeColors.onSurface(this.isDark))
            .fontWeight(this.currentPath ? FontWeight.Normal : FontWeight.Medium)
            .onClick(() => {
              this.goBreadcrumb_(-1);
            })
          ForEach(this.breadcrumbNames, (name: string, index: number) => {
            Row() {
              Text(' / ')
                .fontSize(13)
                .fontColor(ThemeColors.secondaryText(this.isDark))
              Text(name)
                .fontSize(13)
                .fontColor(index === this.breadcrumbNames.length - 1
                  ? ThemeColors.onSurface(this.isDark)
                  : ThemeColors.primary(this.isDark))
                .fontWeight(index === this.breadcrumbNames.length - 1
                  ? FontWeight.Medium : FontWeight.Normal)
                .onClick(() => {
                  this.goBreadcrumb_(index);
                })
            }
          }, (name: string, index: number) => name + '_' + index.toString() + '_' +
            (index < this.breadcrumbPaths.length ? this.breadcrumbPaths[index] : ''))
        }
        .padding({ left: 12, right: 12, bottom: 6 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')

      // 搜索 + 排序 + 多选下载
      Row() {
        Search({ placeholder: '搜索当前目录', value: this.searchKey })
          .layoutWeight(1)
          .height(40)
          .onChange((v: string) => {
            this.searchKey = v;
            this.applyFilterSort_();
          })
          .onSubmit((v: string) => {
            this.searchKey = v;
            this.applyFilterSort_();
          })
        Button(this.sortLabel)
          .fontSize(13)
          .height(36)
          .margin({ left: 8 })
          .backgroundColor(ThemeColors.outlineVariant(this.isDark))
          .fontColor(ThemeColors.onSurface(this.isDark))
          .onClick(() => {
            this.showSortPicker_();
          })
        Button(this.selectMode ? '取消' : '多选')
          .fontSize(13)
          .height(36)
          .margin({ left: 8 })
          .backgroundColor(ThemeColors.outlineVariant(this.isDark))
          .fontColor(ThemeColors.primary(this.isDark))
          .onClick(() => {
            this.selectMode = !this.selectMode;
            if (!this.selectMode) {
              this.selectedPaths = [];
            }
          })
      }
      .width('100%')
      .padding({ left: 12, right: 12, bottom: 8 })

      if (this.selectMode) {
        Row() {
          Text('已选 ' + this.selectedPaths.length + ' 项')
            .fontSize(13)
            .fontColor(ThemeColors.onSurface(this.isDark))
            .layoutWeight(1)
          Button('下载所选')
            .fontSize(13)
            .height(34)
            .backgroundColor(ThemeColors.primary(this.isDark))
            .fontColor(ThemeColors.onPrimary(this.isDark))
            .enabled(this.selectedPaths.length > 0)
            .onClick(() => {
              this.downloadSelected_();
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, bottom: 8 })
      }

      if (this.downloadHint) {
        Text(this.downloadHint)
          .fontSize(12)
          .fontColor(ThemeColors.secondaryText(this.isDark))
          .width('100%')
          .padding({ left: 16, right: 12, bottom: 4 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      if (this.currentPath) {
        Row() {
          Button('上级目录')
            .fontSize(12)
            .height(30)
            .backgroundColor(ThemeColors.transparent())
            .fontColor(ThemeColors.primary(this.isDark))
            .onClick(() => {
              this.goUp_();
            })
          if (this.statusHint) {
            Text(this.statusHint)
              .fontSize(12)
              .fontColor(ThemeColors.secondaryText(this.isDark))
              .margin({ left: 8 })
          }
        }
        .width('100%')
        .padding({ left: 8, right: 12, bottom: 4 })
      } else if (this.statusHint) {
        Text(this.statusHint)
          .fontSize(12)
          .fontColor(ThemeColors.secondaryText(this.isDark))
          .width('100%')
          .padding({ left: 16, right: 12, bottom: 4 })
      }

      if (this.isLoading) {
        Column() {
          LoadingProgress().width(36).height(36).color(ThemeColors.primary(this.isDark))
          Text('正在读取云端目录…')
            .fontSize(13)
            .fontColor(ThemeColors.secondaryText(this.isDark))
            .margin({ top: 8 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.errorText) {
        Column() {
          Text(this.errorText)
            .fontSize(14)
            .fontColor(ThemeColors.error(this.isDark))
            .padding({ left: 24, right: 24 })
            .textAlign(TextAlign.Center)
          Button('重试')
            .margin({ top: 12 })
            .onClick(() => {
              this.loadDirectory_(this.currentPath);
            })
          Button('返回书库列表')
            .margin({ top: 8 })
            .backgroundColor(ThemeColors.outlineVariant(this.isDark))
            .fontColor(ThemeColors.primary(this.isDark))
            .onClick(() => {
              this.exitToLibraryList_();
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.viewItems.length === 0) {
        Column() {
          Text(this.searchKey ? '无匹配文件' : '当前目录为空')
            .fontSize(14)
            .fontColor(ThemeColors.secondaryText(this.isDark))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List() {
          ForEach(this.viewItems, (item: CloudBookListItem) => {
            ListItem() {
              Row() {
                if (this.selectMode && !item.file.isDirectory) {
                  Text(this.isSelected_(item.file.remotePath) ? '☑' : '☐')
                    .fontSize(18)
                    .width(28)
                    .fontColor(ThemeColors.primary(this.isDark))
                }

                Text(item.file.isDirectory ? '📁' : '📄')
                  .fontSize(22)
                  .width(36)

                Column() {
                  Text(item.file.name)
                    .fontSize(15)
                    .fontColor(ThemeColors.onSurface(this.isDark))
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')

                  Row() {
                    if (!item.file.isDirectory) {
                      Text(item.displayState === CLOUD_DISPLAY_DOWNLOADING
                        ? this.progressText_(item)
                        : displayStateLabel(item.displayState))
                        .fontSize(10)
                        .fontColor(this.stateColor_(item.displayState))
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                        .border({
                          width: 0.5,
                          color: this.stateColor_(item.displayState),
                          radius: 4,
                        })
                      if (!item.importSupported && item.displayState === CLOUD_DISPLAY_CLOUD_ONLY) {
                        Text('不支持导入')
                          .fontSize(10)
                          .fontColor(ThemeColors.secondaryText(this.isDark))
                          .margin({ left: 6 })
                      }
                    }
                    if (item.file.size > 0 && !item.file.isDirectory &&
                      item.displayState !== CLOUD_DISPLAY_DOWNLOADING) {
                      Text(formatFileSize(item.file.size))
                        .fontSize(11)
                        .fontColor(ThemeColors.secondaryText(this.isDark))
                        .margin({ left: 8 })
                    }
                    if (item.file.modifiedAt > 0 && item.displayState !== CLOUD_DISPLAY_DOWNLOADING) {
                      Text(formatModifiedAt(item.file.modifiedAt))
                        .fontSize(11)
                        .fontColor(ThemeColors.secondaryText(this.isDark))
                        .margin({ left: 8 })
                    }
                  }
                  .margin({ top: 4 })
                  .width('100%')

                  if (item.displayState === CLOUD_DISPLAY_DOWNLOADING && item.progress &&
                    item.progress.total > 0) {
                    Progress({
                      value: Math.min(100, (item.progress.received / item.progress.total) * 100),
                      total: 100,
                      type: ProgressType.Linear,
                    })
                      .width('100%')
                      .height(4)
                      .color(ThemeColors.primary(this.isDark))
                      .margin({ top: 6 })
                  }

                  if (item.displayState === CLOUD_DISPLAY_ERROR && item.binding && item.binding.lastError) {
                    Text(item.binding.lastError)
                      .fontSize(11)
                      .fontColor(ThemeColors.error(this.isDark))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .margin({ top: 2 })
                      .width('100%')
                  }
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                .margin({ left: 4 })

                if (item.file.isDirectory) {
                  Text('›')
                    .fontSize(20)
                    .fontColor(ThemeColors.secondaryText(this.isDark))
                } else if (!this.selectMode &&
                  (item.displayState === CLOUD_DISPLAY_CLOUD_ONLY ||
                    item.displayState === CLOUD_DISPLAY_ERROR) &&
                  item.importSupported) {
                  Button('下载')
                    .fontSize(12)
                    .height(30)
                    .backgroundColor(ThemeColors.primary(this.isDark))
                    .fontColor(ThemeColors.onPrimary(this.isDark))
                    .onClick(() => {
                      this.startDownload_(item);
                    })
                }
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 12, bottom: 12 })
              .backgroundColor(ThemeColors.surface(this.isDark))
              .borderRadius(10)
              .margin({ left: 12, right: 12, bottom: 8 })
              .onClick(() => {
                this.onItemClick_(item);
              })
            }
          }, (item: CloudBookListItem) =>
            item.sourceId + '|' + item.file.remotePath + '|' + item.displayState + '|' +
            (item.progress ? item.progress.received : 0) + '|' +
            (item.file.isDirectory ? 'd' : 'f'))
        }
        .width('100%')
        .layoutWeight(1)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .layoutWeight(1)
  }
}
