/** 书源管理：对齐 Android Legado 的核心管理能力，并采用 HarmonyOS 标准列表与底部弹层。 */
import { BookSource, serializeBookSource } from '../model/BookSource';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { ImportSourceDialog } from './ImportSourceDialog';
import { GroupManageDialog } from './GroupManageDialog';
import { SourceGroupAssignDialog } from '../components/source/SourceGroupAssignDialog';
import { SourceCheckConfigDialog } from '../components/source/SourceCheckConfigDialog';
import { SourceChecker, CheckConfig, CheckResult, CheckDetail } from '../service/SourceChecker';
import { SourceLoginDialog } from '../components/source/SourceLoginDialog';
import picker from '@ohos.file.picker';
import fileIo from '@ohos.file.fs';
import { WebViewEngine } from '../components/WebViewEngine';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';
import { AppBackButton } from '../components/common/AppTitleBar';
import { BookSourceChangeNotifier } from '../service/BookSourceChangeNotifier';

@Entry
@Component
export struct BookSourcePage {
  @StorageLink('isDark') isDark: boolean = false;
  @State sources: BookSource[] = [];
  @State filtered: BookSource[] = [];
  @State displayed: BookSource[] = [];
  @State searchText: string = '';
  @State sortMode: number = 0;
  @State sortAscending: boolean = true;
  @State groupFilter: string = '';
  @State groupByDomain: boolean = false;
  @State isLoading: boolean = true;
  @State selectedIds: number[] = [];
  @State isSelectMode_: boolean = false;
  @State selectedSet_: Set<number> = new Set();
  @State enabledStateVersion_: number = 0;
  @State exploreStateVersion_: number = 0;
  @State listRevision_: number = 0;
  private suppressClick_: boolean = false;
  @State showSortMenu: boolean = false;
  @State contextMenuId: number = 0;
  @State operationBusy_: boolean = false;
  @State isChecking: boolean = false;
  @State checkProgress: number = 0;
  @State checkTotal: number = 0;
  @State checkResults: CheckResult[] = [];
  @State checkResByUrl: Map<string, CheckResult> = new Map();
  @State showCheckSummary: boolean = false;
  private dao_: BookSourceTable | null = null;
  private groups_: string[] = [];
  private sortLabels_: string[] = ['手动', '名称', 'URL', '权重', '更新时间', '响应', '启用'];
  private importDlg?: CustomDialogController;
  private groupManageDlg?: CustomDialogController;
  private groupAssignDlg?: CustomDialogController;
  private loginDlg?: CustomDialogController;
  private checkConfigDlg?: CustomDialogController;
  private activeChecker_: SourceChecker | null = null;
  private loadRequestId_: number = 0;
  private checkRequestId_: number = 0;
  private isActive_: boolean = false;

  aboutToAppear(): void {
    this.isActive_ = true;
    this.importDlg = new CustomDialogController({
      builder: ImportSourceDialog({
        controller: this.importDlg!,
        onImportSuccess: async (): Promise<void> => { await this.load(); }
      }), autoCancel: true, alignment: UiUtil.adaptiveDialogAlignment(), customStyle: true
    });
    this.groupManageDlg = new CustomDialogController({
      builder: GroupManageDialog({
        controller: this.groupManageDlg!,
        onGroupChanged: async (): Promise<void> => { await this.load(); }
      }), autoCancel: true, alignment: UiUtil.adaptiveDialogAlignment(), customStyle: true
    });
    void this.load();
  }

  /** 从新建/编辑页返回时重新读取数据库，避免列表保留旧的页面内存状态。 */
  onPageShow(): void {
    this.isActive_ = true;
    // 首次进入由 aboutToAppear 负责加载，避免两个生命周期并发查询后旧结果覆盖新结果。
    if (!this.isLoading || this.sources.length > 0) void this.load();
  }

  aboutToDisappear(): void {
    this.isActive_ = false;
    this.loadRequestId_++;
    this.checkRequestId_++;
    this.activeChecker_?.cancel();
    this.activeChecker_ = null;
    this.isChecking = false;
  }

  private async load(): Promise<void> {
    const requestId = ++this.loadRequestId_;
    this.isLoading = true;
    try {
      await AppDatabase.getInstance().waitForInit();
      const dao = new BookSourceTable(AppDatabase.getInstance().rdbStore);
      const sources = await dao.getAllSources();
      if (!this.isActive_ || requestId !== this.loadRequestId_) return;
      this.dao_ = dao;
      this.sources = sources;
      // ForEach 会复用键相同的列表项；完整重载后递增版本，确保编辑、导入和分组变更
      // 得到的新对象能够替换旧列表项，而不是继续显示旧字段。
      this.listRevision_++;
      this.buildGroups();
      this.applyFilters();
      this.selectedIds = this.selectedIds.filter((id: number): boolean =>
        this.sources.some((source: BookSource): boolean => source.id === id));
      this.syncSelectedSet_();
      if (this.selectedIds.length === 0) this.isSelectMode_ = false;
    } catch (e) {
      if (this.isActive_ && requestId === this.loadRequestId_) {
        UiUtil.showToast(this.getUIContext(), { message: '加载书源失败：' + String(e), duration: 2000 });
      }
    }
    if (this.isActive_ && requestId === this.loadRequestId_) this.isLoading = false;
  }

  private splitGroups(group: string): string[] {
    return (group || '').split(/[,，;；|｜\n\r\t]+/)
      .map((item: string): string => item.trim()).filter((item: string): boolean => item.length > 0);
  }

  private buildGroups(): void {
    const groups: string[] = [];
    this.sources.forEach((source: BookSource) => this.splitGroups(source.group).forEach((group: string) => {
      if (!groups.includes(group)) groups.push(group);
    }));
    this.groups_ = ['全部', '已启用', '已禁用', '未分组', '需登录', '发现已启用', '发现已停用', ...groups.sort()];
  }

  private applyFilters(): void {
    let list = this.sources.slice();
    const query = this.searchText.trim().toLowerCase();
    if (query) list = list.filter((source: BookSource): boolean =>
      source.sourceName.toLowerCase().includes(query) || source.sourceUrl.toLowerCase().includes(query)
        || (source.group || '').toLowerCase().includes(query)
        || (source.bookSourceComment || '').toLowerCase().includes(query));
    if (this.groupFilter === '已启用') list = list.filter((source: BookSource): boolean => source.enabled);
    else if (this.groupFilter === '已禁用') list = list.filter((source: BookSource): boolean => !source.enabled);
    else if (this.groupFilter === '未分组') list = list.filter((source: BookSource): boolean => !source.group.trim());
    else if (this.groupFilter === '需登录') list = list.filter((source: BookSource): boolean => !!source.loginUrl);
    else if (this.groupFilter === '发现已启用') list = list.filter((source: BookSource): boolean => source.enabledExplore);
    else if (this.groupFilter === '发现已停用') list = list.filter((source: BookSource): boolean => !source.enabledExplore);
    else if (this.groupFilter && this.groupFilter !== '全部') {
      list = list.filter((source: BookSource): boolean => this.splitGroups(source.group).includes(this.groupFilter));
    }
    const direction = this.sortAscending ? 1 : -1;
    list.sort((a: BookSource, b: BookSource): number => {
      let result = 0;
      if (this.sortMode === 0) result = (a.customOrder || 0) - (b.customOrder || 0);
      else if (this.sortMode === 1) result = a.sourceName.localeCompare(b.sourceName);
      else if (this.sortMode === 2) result = a.sourceUrl.localeCompare(b.sourceUrl);
      else if (this.sortMode === 3) result = (a.weight || 0) - (b.weight || 0);
      else if (this.sortMode === 4) result = (a.updateTime || 0) - (b.updateTime || 0);
      else if (this.sortMode === 5) result = (a.respondTime || 0) - (b.respondTime || 0);
      else result = Number(a.enabled) - Number(b.enabled);
      if (result === 0) result = a.sourceName.localeCompare(b.sourceName, 'zh-CN');
      if (result === 0) result = a.id - b.id;
      return result * direction;
    });
    this.filtered = list;
    this.updateDisplayList_();
  }

  private getDomain(url: string): string {
    return url.replace(/^https?:\/\//, '').split('/')[0] || '其他';
  }

  private updateDisplayList_(): void {
    if (!this.groupByDomain) {
      this.displayed = this.filtered.slice();
      return;
    }
    this.displayed = this.filtered.slice().sort((a: BookSource, b: BookSource): number => {
      const domain = this.getDomain(a.sourceUrl).localeCompare(this.getDomain(b.sourceUrl));
      return domain !== 0 ? domain : a.sourceName.localeCompare(b.sourceName);
    });
  }

  private syncSelectedSet_(): void {
    this.selectedSet_ = new Set(this.selectedIds);
  }

  private isSelectMode(): boolean { return this.isSelectMode_; }
  private isSelected(id: number): boolean { return this.selectedSet_.has(id); }
  private isSourceEnabled(source: BookSource): boolean {
    return this.enabledStateVersion_ >= 0 && source.enabled;
  }
  private isExploreEnabled(source: BookSource): boolean {
    return this.exploreStateVersion_ >= 0 && source.enabledExplore;
  }

  private setSelected(id: number, selected: boolean): void {
    // Checkbox 的 select 属性变化也可能触发 onChange，因此按目标值更新，避免程序性选中后又被反转取消。
    setTimeout(() => {
      const currentlySelected = this.selectedSet_.has(id);
      if (currentlySelected === selected) return;
      if (selected) {
        this.selectedIds = [...this.selectedIds, id];
      } else {
        this.selectedIds = this.selectedIds.filter((item: number): boolean => item !== id);
      }
      this.syncSelectedSet_();
      // 最后一项被取消时退出选择模式
      if (this.selectedIds.length === 0) this.isSelectMode_ = false;
      this.contextMenuId = 0;
    }, 0);
  }

  private toggleSelect(id: number): void {
    this.setSelected(id, !this.selectedSet_.has(id));
  }

  private selectedSources(): BookSource[] {
    return this.sources.filter((source: BookSource): boolean => this.selectedSet_.has(source.id));
  }

  private toggleSelectAll(): void {
    setTimeout(() => {
      const visibleIds = this.filtered.map((source: BookSource): number => source.id);
      const all = visibleIds.length > 0 && visibleIds.every((id: number): boolean => this.selectedSet_.has(id));
      this.selectedIds = all ? [] : visibleIds;
      this.syncSelectedSet_();
    }, 0);
  }

  private enterSelectMode(id: number): void {
    // 抑制长按后紧接着触发的 click 事件，避免立即 toggleSelect 取消选中
    this.suppressClick_ = true;
    setTimeout(() => {
      this.selectedIds = [id];
      this.syncSelectedSet_();
      this.isSelectMode_ = true;
      this.contextMenuId = 0;
      // 下一帧解除抑制
      setTimeout(() => { this.suppressClick_ = false; }, 50);
    }, 0);
  }

  private exitSelectMode(): void {
    setTimeout(() => {
      this.selectedIds = [];
      this.syncSelectedSet_();
      this.isSelectMode_ = false;
    }, 0);
  }

  private async batchEnable(enabled: boolean): Promise<void> {
    const selected = this.selectedSources();
    const ids = selected.map((source: BookSource): number => source.id);
    if (!this.dao_ || ids.length === 0) return;
    await this.runOperation_(async (): Promise<void> => {
      await this.dao_!.batchSetEnabled(ids, enabled);
      selected.forEach((source: BookSource) => { source.enabled = enabled; });
      this.enabledStateVersion_++;
      this.applyFilters();
      this.clearSelection_();
    });
  }

  private async batchExplore(enabled: boolean): Promise<void> {
    const selected = this.selectedSources();
    const ids = selected.map((source: BookSource): number => source.id);
    if (!this.dao_ || ids.length === 0) return;
    await this.runOperation_(async (): Promise<void> => {
      await this.dao_!.batchSetExploreEnabled(ids, enabled);
      selected.forEach((source: BookSource) => { source.enabledExplore = enabled; });
      this.exploreStateVersion_++;
      BookSourceChangeNotifier.notify();
      this.applyFilters();
      this.clearSelection_();
    });
  }

  private async batchMoveToEdge(toTop: boolean): Promise<void> {
    const ids = this.selectedSources().map((source: BookSource): number => source.id);
    if (!this.dao_ || ids.length === 0) return;
    await this.runOperation_(async (): Promise<void> => {
      await this.dao_!.moveSourcesToEdge(ids, toTop);
      this.sortMode = 0;
      this.sortAscending = true;
      this.clearSelection_();
      await this.load();
    });
  }

  private openAssignGroup(): void {
    const ids = this.selectedSources().map((source: BookSource): number => source.id);
    if (ids.length === 0) return;
    this.groupAssignDlg = new CustomDialogController({
      builder: SourceGroupAssignDialog({
        controller: this.groupAssignDlg!, sourceIds: ids,
        onChanged: async (): Promise<void> => {
          this.clearSelection_();
          await this.load();
        }
      }), autoCancel: true, alignment: UiUtil.adaptiveDialogAlignment(), customStyle: true
    });
    this.groupAssignDlg.open();
  }

  private confirmDelete(): void {
    const selected = this.selectedSources();
    if (selected.length === 0) return;
    UiUtil.showDialog(this.getUIContext(), {
      title: '删除书源', message: '确定删除已选的 ' + selected.length + ' 个书源？此操作不可撤销。',
      buttons: [
        { text: '取消', color: ThemeColors.secondaryText(this.isDark) },
        { text: '删除', color: ThemeColors.error(this.isDark) }
      ]
    }).then(async (result) => {
      if (result.index !== 1 || !this.dao_) return;
      await this.runOperation_(async (): Promise<void> => {
        await this.dao_!.batchDelete(selected.map((source: BookSource): number => source.id));
        BookSourceChangeNotifier.notify();
        this.clearSelection_();
        await this.load();
      });
    });
  }

  private async doExport(): Promise<void> {
    const target = this.selectedIds.length > 0 ? this.selectedSources() : this.filtered;
    if (!this.dao_ || target.length === 0) {
      UiUtil.showToast(this.getUIContext(), { message: '没有可导出的书源', duration: 1500 });
      return;
    }
    if (this.operationBusy_) return;
    this.operationBusy_ = true;
    let openedFile: fileIo.File | null = null;
    try {
      const documentPicker = new picker.DocumentViewPicker(this.getUIContext().getHostContext()!);
      const suffix = new Date().toISOString().substring(0, 10).replace(/-/g, '');
      const uris = await documentPicker.save({ newFileNames: ['bookSources_' + suffix + '.json'] });
      if (!uris || uris.length === 0) return;
      const json = await this.dao_.exportSources(target);
      openedFile = fileIo.openSync(
        uris[0], fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(openedFile.fd, json);
      UiUtil.showToast(this.getUIContext(), { message: '已导出 ' + target.length + ' 个书源', duration: 1800 });
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: '导出失败：' + String(e), duration: 2000 });
    } finally {
      if (openedFile) {
        try { fileIo.closeSync(openedFile); } catch (_e) { /* ignore */ }
      }
      this.operationBusy_ = false;
    }
  }

  private sourceScope(source: BookSource): string {
    return '{"type":"source","sources":[{"name":' + JSON.stringify(source.sourceName) +
      ',"url":' + JSON.stringify(source.sourceUrl) + '}]}';
  }

  private openSearch(source: BookSource): void {
    UiUtil.pushUrl(this.getUIContext(), {
      url: 'pages/SearchPage', params: { searchScope: this.sourceScope(source) }
    });
  }

  private openDebug(source: BookSource): void {
    UiUtil.pushUrl(this.getUIContext(), {
      url: 'pages/BookSourceDebugPage', params: { sourceUrl: source.sourceUrl }
    });
  }

  private openLogin(source: BookSource): void {
    this.loginDlg = new CustomDialogController({
      builder: SourceLoginDialog({
        controller: this.loginDlg!, sourceId: source.id, sourceUrl: source.sourceUrl,
        sourceName: source.sourceName, loginUrl: source.loginUrl, loginUi: source.loginUi,
        jsLib: source.jsLib || '', variableComment: source.variableComment || '',
        sourceJson: serializeBookSource(source)
      }), autoCancel: true, customStyle: true, alignment: DialogAlignment.Center
    });
    this.loginDlg.open();
  }

  private async moveToEdge(source: BookSource, top: boolean): Promise<void> {
    if (!this.dao_) return;
    await this.runOperation_(async (): Promise<void> => {
      await this.dao_!.moveSourceToEdge(source.id, top);
      this.contextMenuId = 0;
      this.sortMode = 0;
      this.sortAscending = true;
      await this.load();
    });
  }

  private async toggleExplore(source: BookSource): Promise<void> {
    if (!this.dao_) return;
    const enabled = !this.isExploreEnabled(source);
    await this.runOperation_(async (): Promise<void> => {
      await this.dao_!.batchSetExploreEnabled([source.id], enabled);
      source.enabledExplore = enabled;
      this.exploreStateVersion_++;
      BookSourceChangeNotifier.notify();
      this.applyFilters();
      this.contextMenuId = 0;
    });
  }

  private openCheckConfig(): void {
    if (this.selectedIds.length === 0) return;
    this.checkConfigDlg = new CustomDialogController({
      builder: SourceCheckConfigDialog({
        controller: this.checkConfigDlg!, onStart: (config: CheckConfig) => { this.startCheck(config); }
      }), autoCancel: true, alignment: UiUtil.adaptiveDialogAlignment(), customStyle: true
    });
    this.checkConfigDlg.open();
  }

  private startCheck(config: CheckConfig): void {
    const requestId = ++this.checkRequestId_;
    const targets = this.selectedSources();
    if (targets.length === 0) return;
    this.isChecking = true;
    this.checkProgress = 0;
    this.checkTotal = targets.length;
    this.checkResults = [];
    this.checkResByUrl = new Map();
    this.showCheckSummary = false;
    this.clearSelection_();
    this.activeChecker_ = new SourceChecker(config);
    this.activeChecker_.checkSources(targets, (completed: number, total: number, result: CheckResult) => {
      if (!this.isActive_ || requestId !== this.checkRequestId_) return;
      this.checkProgress = completed;
      this.checkTotal = total;
      this.checkResults = [...this.checkResults, result];
      const map = new Map(this.checkResByUrl);
      map.set(result.sourceUrl, result);
      this.checkResByUrl = map;
      const search = result.details.find((item: CheckDetail): boolean => item.name === '搜索' && item.passed);
      const source = targets.find((item: BookSource): boolean => item.sourceUrl === result.sourceUrl);
      if (search && source && this.dao_) {
        this.dao_.updateRespondTime(source.id, search.duration).then(() => {
          source.respondTime = search.duration;
          this.applyFilters();
        }).catch((e: Error) => {
          console.warn('[BookSourcePage] update respond time failed:', e.message);
        });
      }
    }).then(() => {
      if (!this.isActive_ || requestId !== this.checkRequestId_) return;
      this.isChecking = false;
      this.showCheckSummary = true;
      this.activeChecker_ = null;
    }).catch((e: Error) => {
      if (!this.isActive_ || requestId !== this.checkRequestId_) return;
      this.isChecking = false;
      this.activeChecker_ = null;
      UiUtil.showToast(this.getUIContext(), { message: '校验失败：' + e.message, duration: 2000 });
    });
  }

  private cancelCheck(): void {
    this.checkRequestId_++;
    this.activeChecker_?.cancel();
    this.activeChecker_ = null;
    this.isChecking = false;
    if (this.checkResults.length > 0) this.showCheckSummary = true;
    UiUtil.showToast(this.getUIContext(), { message: '已停止校验', duration: 1200 });
  }

  private clearSelection_(): void {
    this.selectedIds = [];
    this.syncSelectedSet_();
    this.isSelectMode_ = false;
  }

  private async runOperation_(action: () => Promise<void>): Promise<void> {
    if (this.operationBusy_) return;
    this.operationBusy_ = true;
    try {
      await action();
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), {
        message: '操作失败：' + ((e as Error).message || String(e)), duration: 2000
      });
    } finally {
      this.operationBusy_ = false;
    }
  }

  private async setSourceEnabled_(source: BookSource, enabled: boolean): Promise<void> {
    if (!this.dao_ || this.operationBusy_ || source.enabled === enabled) return;
    const previous = source.enabled;
    await this.runOperation_(async (): Promise<void> => {
      try {
        await this.dao_!.toggleEnabled(source.id, enabled);
        source.enabled = enabled;
        this.enabledStateVersion_++;
        this.applyFilters();
      } catch (e) {
        source.enabled = previous;
        this.enabledStateVersion_++;
        console.error('[BookSourcePage] setSourceEnabled_ failed:', (e as Error).message);
      }
    });
  }

  private getCheckDetails(url: string): CheckDetail[] {
    const result = this.checkResByUrl.get(url);
    return result ? result.details : [];
  }

  build() {
    Column() {
      Row() {
        AppBackButton({ onBack: () => { UiUtil.back(this.getUIContext()); } })
        Column() {
          Text($r('app.string.ui_2e4bfce823')).fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor(ThemeColors.onBackground(this.isDark)).width('100%')
          Text(this.sources.length + ' 个书源' + (this.isSelectMode_ ? ' · 已选 ' + this.selectedIds.length : ''))
            .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).width('100%')
        }.layoutWeight(1)
        // 选择模式：显示"取消"按钮；非选择模式：显示新建/导入/分组按钮
        // 使用 visibility 避免条件渲染导致组件重建
        Button($r('app.string.common_cancel')).height(40).backgroundColor(ThemeColors.transparent()).fontColor(ThemeColors.primary(this.isDark))
          .visibility(this.isSelectMode_ ? Visibility.Visible : Visibility.Hidden)
          .onClick(() => { this.exitSelectMode(); })
        Button($r('app.string.ui_literal_0cda8d1c71')).fontSize(14).height(40).borderRadius(20).padding({ left: 16, right: 16 })
          .backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark))
          .visibility(this.isSelectMode_ ? Visibility.Hidden : Visibility.Visible)
          .onClick(() => { UiUtil.pushUrl(this.getUIContext(), { url: 'pages/BookSourceEditPage' }); })
        Button($r('app.string.common_import')).height(40).backgroundColor(ThemeColors.transparent()).fontColor(ThemeColors.primary(this.isDark))
          .visibility(this.isSelectMode_ ? Visibility.Hidden : Visibility.Visible)
          .onClick(() => { this.importDlg?.open(); })
        Button($r('app.string.ui_97d8a6c05b')).height(40).backgroundColor(ThemeColors.transparent()).fontColor(ThemeColors.primary(this.isDark))
          .visibility(this.isSelectMode_ ? Visibility.Hidden : Visibility.Visible)
          .onClick(() => { this.groupManageDlg?.open(); })
      }.height(64).padding({ left: 4, right: 8 }).width('100%')
        .backgroundColor(ThemeColors.surface(this.isDark))
        .border({ width: { bottom: 0.5 }, color: ThemeColors.outlineVariant(this.isDark) })

      Row() {
        TextInput({ placeholder: $r('app.string.ui_3be802f0e1'), text: this.searchText })
          .height(48).layoutWeight(1).borderRadius(24).padding({ left: 16, right: 12 })
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
          .fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark))
          .onChange((value: string) => { this.searchText = value; this.applyFilters(); })
        Button(this.sortLabels_[this.sortMode] + (this.sortAscending ? ' ↑' : ' ↓'))
          .height(48).borderRadius(24).margin({ left: 8 }).padding({ left: 14, right: 14 })
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).fontColor(ThemeColors.onSurface(this.isDark))
          .onClick(() => { this.showSortMenu = !this.showSortMenu; })
      }.padding({ left: 16, right: 16 }).width('100%')

      if (this.showSortMenu) {
        Column() {
          ForEach(this.sortLabels_, (label: string, index: number) => {
            Row() {
              Text(label).fontSize(15).layoutWeight(1)
                .fontColor(index === this.sortMode ? ThemeColors.primary(this.isDark) : ThemeColors.onSurface(this.isDark))
              if (index === this.sortMode) Text(this.sortAscending ? '升序' : '降序').fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
            }.height(48).padding({ left: 16, right: 16 }).width('100%')
              .backgroundColor(index === this.sortMode ? ThemeColors.surfaceVariant(this.isDark) : ThemeColors.surface(this.isDark))
              .onClick(() => {
                if (this.sortMode === index) this.sortAscending = !this.sortAscending;
                else { this.sortMode = index; this.sortAscending = true; }
                this.showSortMenu = false; this.applyFilters();
              })
          })
        }.width(180).padding({ top: 4, bottom: 4 }).borderRadius(16)
          .backgroundColor(ThemeColors.surface(this.isDark)).shadow({ radius: 12, color: ThemeColors.scrim(this.isDark) })
          .position({ x: 16, y: 116 }).zIndex(100)
      }

      Scroll() {
        Row() {
          ForEach(this.groups_, (group: string) => {
            Text(group).fontSize(13).height(44).padding({ left: 14, right: 14 })
              .fontColor(this.groupFilter === group ? ThemeColors.onPrimary(this.isDark) : ThemeColors.onSurface(this.isDark))
              .backgroundColor(this.groupFilter === group ? ThemeColors.primary(this.isDark) : ThemeColors.surfaceVariant(this.isDark))
              .borderRadius(22).margin({ right: 8 }).textAlign(TextAlign.Center)
              .onClick(() => { this.groupFilter = this.groupFilter === group ? '' : group; this.applyFilters(); })
          })
        }.padding({ left: 16, right: 8, top: 10, bottom: 8 })
      }.width('100%').scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)

      Row() {
        Toggle({ type: ToggleType.Switch, isOn: this.groupByDomain }).onChange((value: boolean) => {
          this.groupByDomain = value;
          this.updateDisplayList_();
        })
        Text($r('app.string.ui_4a8c9350fe')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ left: 8 })
        Blank()
        Text(this.filtered.length + ' 项').fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
      }.height(40).padding({ left: 16, right: 16 }).width('100%')

      if (this.isLoading) {
        Column() { LoadingProgress().color(ThemeColors.primary(this.isDark)); Text($r('app.string.ui_6ad638ae77')).fontSize(13).margin({ top: 10 }).fontColor(ThemeColors.secondaryText(this.isDark)) }
          .layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.filtered.length === 0) {
        Column() { Text($r('app.string.ui_198c2214f2')).fontSize(18).fontWeight(FontWeight.Medium); Text($r('app.string.ui_f49bb525e4')).fontSize(13).margin({ top: 8 }).fontColor(ThemeColors.secondaryText(this.isDark)) }
          .layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        List({ space: 4 }) {
          ForEach(this.displayed, (source: BookSource, index: number) => {
            ListItem() {
              Column() {
                if (this.groupByDomain &&
                  (index === 0 || this.getDomain(this.displayed[index - 1].sourceUrl) !==
                    this.getDomain(source.sourceUrl))) {
                  Text(this.getDomain(source.sourceUrl)).fontSize(13).fontWeight(FontWeight.Medium)
                    .fontColor(ThemeColors.primary(this.isDark)).width('100%')
                    .padding({ left: 8, right: 8, top: 8, bottom: 4 })
                }
                this.sourceItem(source)
              }.width('100%')
            }
          }, (source: BookSource): string =>
            this.listRevision_.toString() + ':' + source.id.toString() + ':' +
              (source.enabled ? '1' : '0') + ':' + (source.enabledExplore ? '1' : '0') + ':' +
              (source.respondTime || 0).toString())
        }.layoutWeight(1).padding({ left: 12, right: 12, bottom: this.isSelectMode_ ? 4 : 12 })
      }

      // 操作栏常驻 DOM，通过 visibility 控制显隐，避免选择/退出选择时大量组件创建/销毁阻塞主线程
      Scroll() {
        Row() {
          this.actionButton('全选', () => { this.toggleSelectAll(); })
          this.actionButton('启用', () => { this.batchEnable(true); })
          this.actionButton('禁用', () => { this.batchEnable(false); })
          this.actionButton('启用发现', () => { this.batchExplore(true); })
          this.actionButton('停用发现', () => { this.batchExplore(false); })
          this.actionButton('置顶', () => { this.batchMoveToEdge(true); })
          this.actionButton('置底', () => { this.batchMoveToEdge(false); })
          this.actionButton('分组', () => { this.openAssignGroup(); })
          this.actionButton('校验', () => { this.openCheckConfig(); })
          this.actionButton('导出', () => { this.doExport(); })
          Button($r('app.string.common_delete')).height(40).borderRadius(20).padding({ left: 16, right: 16 })
            .backgroundColor(ThemeColors.error(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark))
            .onClick(() => { this.confirmDelete(); })
        }.padding({ left: 12, right: 12, top: 8, bottom: 8 })
      }.height(this.isSelectMode_ ? 56 : 0).width('100%').scrollable(ScrollDirection.Horizontal)
        .backgroundColor(ThemeColors.surface(this.isDark)).scrollBar(BarState.Off)
        .visibility(this.isSelectMode_ ? Visibility.Visible : Visibility.Hidden)

      if (this.isChecking) {
        Row() {
          Progress({ value: this.checkProgress, total: Math.max(1, this.checkTotal), type: ProgressType.Ring })
            .width(28).height(28).color(ThemeColors.primary(this.isDark))
          Text('正在校验 ' + this.checkProgress + '/' + this.checkTotal).fontSize(13).layoutWeight(1)
            .fontColor(ThemeColors.onSurface(this.isDark)).margin({ left: 10 })
          Button($r('app.string.common_stop')).height(40).backgroundColor(ThemeColors.transparent()).fontColor(ThemeColors.error(this.isDark))
            .onClick(() => { this.cancelCheck(); })
        }.height(56).padding({ left: 16, right: 12 }).width('100%').backgroundColor(ThemeColors.surface(this.isDark))
      } else if (this.showCheckSummary && this.checkResults.length > 0) {
        Row() {
          Text('校验：通过 ' + this.checkResults.filter((item: CheckResult): boolean => item.status === 'success').length +
            ' · 部分 ' + this.checkResults.filter((item: CheckResult): boolean => item.status === 'partial').length +
            ' · 失败 ' + this.checkResults.filter((item: CheckResult): boolean => item.status === 'fail').length).fontColor(ThemeColors.onSurface(this.isDark))
            .fontSize(13).fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1)
          Button($r('app.string.common_close')).height(40).backgroundColor(ThemeColors.transparent()).fontColor(ThemeColors.primary(this.isDark))
            .onClick(() => { this.showCheckSummary = false; })
        }.height(52).padding({ left: 16, right: 12 }).width('100%').backgroundColor(ThemeColors.surface(this.isDark))
      }
      WebViewEngine().width(1).height(1).visibility(Visibility.Hidden)
    }.width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
      .onClick(() => { this.showSortMenu = false; this.contextMenuId = 0; })
  }

  @Builder
  actionButton(label: string, action: () => void) {
    Button(label).height(40).borderRadius(20).padding({ left: 14, right: 14 }).margin({ right: 6 })
      .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).fontColor(ThemeColors.onSurface(this.isDark))
      .enabled(!this.operationBusy_)
      .onClick(action)
  }

  @Builder
  sourceItem(source: BookSource) {
    Stack() {
      Row() {
        // Checkbox 常驻 DOM，通过 visibility 控制显隐，避免选择模式切换时大量组件创建/销毁导致主线程阻塞
        Checkbox({ name: source.id.toString(), group: 'book_sources' }).select(this.isSelected(source.id))
          .selectedColor(ThemeColors.primary(this.isDark)).margin({ right: 10 })
          .visibility(this.isSelectMode() ? Visibility.Visible : Visibility.Hidden)
          .onChange((selected: boolean) => { this.setSelected(source.id, selected); })
        Column() {
          Row() {
            Text(source.sourceName || '未命名书源').fontSize(16).fontWeight(FontWeight.Medium)
              .fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Toggle({ type: ToggleType.Switch, isOn: this.isSourceEnabled(source) }).onChange(async (enabled: boolean) => {
              await this.setSourceEnabled_(source, enabled);
            }).visibility(this.isSelectMode() ? Visibility.None : Visibility.Visible)
          }.width('100%')
          Text(source.sourceUrl).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').margin({ top: 3 })
          Row() {
            if (source.group) Text(source.group).fontSize(11).fontColor(ThemeColors.primary(this.isDark)).maxLines(1)
            Text('权重 ' + (source.weight || 0)).fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ left: source.group ? 10 : 0 })
            if (source.respondTime > 0) Text(source.respondTime + ' ms').fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ left: 10 })
            Text(this.isExploreEnabled(source) ? '发现启用' : '发现停用').fontSize(11)
              .fontColor(this.isExploreEnabled(source) ? ThemeColors.primary(this.isDark) : ThemeColors.error(this.isDark))
              .margin({ left: 10 })
          }.width('100%').margin({ top: 6 })
          if (this.checkResByUrl.has(source.sourceUrl)) {
            Row() {
              ForEach(this.getCheckDetails(source.sourceUrl), (detail: CheckDetail) => {
                Text((detail.passed ? '✓ ' : '! ') + detail.name).fontSize(10)
                  .fontColor(detail.passed ? ThemeColors.primary(this.isDark) : ThemeColors.error(this.isDark))
                  .margin({ right: 8 })
              }, (detail: CheckDetail): string => detail.name)
            }.width('100%').margin({ top: 6 })
          }
        }.layoutWeight(1).onClick(() => {
          if (this.suppressClick_) return;
          if (this.isSelectMode()) this.toggleSelect(source.id);
          else UiUtil.pushUrl(this.getUIContext(), { url: 'pages/BookSourceEditPage', params: { url: source.sourceUrl } });
        })
        Button($r('app.string.ui_b7ed67990b')).fontSize(22).width(40).height(40).backgroundColor(ThemeColors.transparent())
          .fontColor(ThemeColors.secondaryText(this.isDark))
          .visibility(this.isSelectMode() ? Visibility.None : Visibility.Visible)
          .accessibilityText($r('app.string.ui_77836d3a99'))
          .onClick(() => { this.contextMenuId = this.contextMenuId === source.id ? 0 : source.id; })
      }.width('100%').padding({ left: 12, right: 6, top: 12, bottom: 12 })
        .borderRadius(16).backgroundColor(this.isSelected(source.id) ? ThemeColors.surfaceVariant(this.isDark) : ThemeColors.surface(this.isDark))
        .gesture(LongPressGesture().onAction(() => {
          if (!this.isSelectMode_) this.enterSelectMode(source.id);
          else this.toggleSelect(source.id);
        }))

      if (this.contextMenuId === source.id) {
        Column() {
          if (source.loginUrl || source.loginUi) this.menuItem('登录', false, () => { this.contextMenuId = 0; this.openLogin(source); })
          this.menuItem('置顶', false, () => { this.moveToEdge(source, true); })
          this.menuItem('置底', false, () => { this.moveToEdge(source, false); })
          this.menuItem(this.isExploreEnabled(source) ? '停用发现' : '启用发现', false, () => { this.toggleExplore(source); })
          this.menuItem('搜索测试', false, () => { this.contextMenuId = 0; this.openSearch(source); })
          this.menuItem('规则调试', false, () => { this.contextMenuId = 0; this.openDebug(source); })
          this.menuItem('删除', true, () => {
            this.selectedIds = [source.id]; this.syncSelectedSet_();
            this.isSelectMode_ = false; this.contextMenuId = 0; this.confirmDelete();
          })
        }.width(136).padding({ top: 4, bottom: 4 }).borderRadius(16)
          .backgroundColor(ThemeColors.surface(this.isDark)).shadow({ radius: 12, color: ThemeColors.scrim(this.isDark) })
          .position({ right: 12, top: 48 }).zIndex(120)
      }
    }.width('100%')
  }

  @Builder
  menuItem(label: string, danger: boolean, action: () => void) {
    Text(label).fontSize(14).height(44).width('100%').padding({ left: 16, right: 16 })
      .fontColor(danger ? ThemeColors.error(this.isDark) : ThemeColors.onSurface(this.isDark))
      .onClick(action)
  }
}
