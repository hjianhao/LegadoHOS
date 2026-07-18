/** 书源管理：对齐 Android Legado 的核心管理能力，并采用 HarmonyOS 标准列表与底部弹层。 */
import { BookSource } from '../model/BookSource';
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

@Entry
@Component
struct BookSourcePage {
  @StorageLink('isDark') isDark: boolean = false;
  @State sources: BookSource[] = [];
  @State filtered: BookSource[] = [];
  @State searchText: string = '';
  @State sortMode: number = 0;
  @State sortAscending: boolean = true;
  @State groupFilter: string = '';
  @State groupByDomain: boolean = false;
  @State isLoading: boolean = true;
  @State selectedUrls: string[] = [];
  private selectedSet_: Set<string> = new Set();
  @State showSortMenu: boolean = false;
  @State contextMenuUrl: string = '';
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

  aboutToAppear(): void {
    this.importDlg = new CustomDialogController({
      builder: ImportSourceDialog({
        controller: this.importDlg!, onImportSuccess: () => { this.load(); }
      }), autoCancel: true, alignment: DialogAlignment.Bottom, customStyle: true
    });
    this.groupManageDlg = new CustomDialogController({
      builder: GroupManageDialog({
        controller: this.groupManageDlg!, onGroupChanged: () => { this.load(); }
      }), autoCancel: true, alignment: DialogAlignment.Bottom, customStyle: true
    });
    this.load();
  }

  private async load(): Promise<void> {
    this.isLoading = true;
    try {
      await AppDatabase.getInstance().waitForInit();
      this.dao_ = new BookSourceTable(AppDatabase.getInstance().rdbStore);
      this.sources = await this.dao_.getAllSources();
      this.buildGroups();
      this.applyFilters();
      this.selectedUrls = this.selectedUrls.filter((url: string): boolean =>
        this.sources.some((source: BookSource): boolean => source.sourceUrl === url));
      this.syncSelectedSet_();
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: '加载书源失败：' + String(e), duration: 2000 });
    }
    this.isLoading = false;
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
        || (source.group || '').toLowerCase().includes(query));
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
      return result * direction;
    });
    this.filtered = list;
  }

  private getDomain(url: string): string {
    return url.replace(/^https?:\/\//, '').split('/')[0];
  }

  private getDisplayList(): BookSource[] {
    if (!this.groupByDomain) return this.filtered;
    return this.filtered.slice().sort((a: BookSource, b: BookSource): number => {
      const domain = this.getDomain(a.sourceUrl).localeCompare(this.getDomain(b.sourceUrl));
      return domain !== 0 ? domain : a.sourceName.localeCompare(b.sourceName);
    });
  }

  private syncSelectedSet_(): void {
    this.selectedSet_ = new Set(this.selectedUrls);
  }

  private isSelectMode(): boolean { return this.selectedUrls.length > 0; }
  private isSelected(url: string): boolean { return this.selectedSet_.has(url); }

  private toggleSelect(url: string): void {
    if (this.selectedSet_.has(url)) {
      this.selectedUrls = this.selectedUrls.filter((item: string): boolean => item !== url);
    } else {
      this.selectedUrls = [...this.selectedUrls, url];
    }
    this.syncSelectedSet_();
    this.contextMenuUrl = '';
  }

  private selectedSources(): BookSource[] {
    return this.sources.filter((source: BookSource): boolean => this.selectedSet_.has(source.sourceUrl));
  }

  private toggleSelectAll(): void {
    const visibleUrls = this.filtered.map((source: BookSource): string => source.sourceUrl);
    const all = visibleUrls.length > 0 && visibleUrls.every((url: string): boolean => this.selectedSet_.has(url));
    this.selectedUrls = all ? [] : visibleUrls;
    this.syncSelectedSet_();
  }

  private async batchEnable(enabled: boolean): Promise<void> {
    const ids = this.selectedSources().map((source: BookSource): number => source.id);
    if (!this.dao_ || ids.length === 0) return;
    await this.dao_.batchSetEnabled(ids, enabled);
    this.selectedUrls = [];
    this.syncSelectedSet_();
    await this.load();
  }

  private async batchExplore(enabled: boolean): Promise<void> {
    const ids = this.selectedSources().map((source: BookSource): number => source.id);
    if (!this.dao_ || ids.length === 0) return;
    await this.dao_.batchSetExploreEnabled(ids, enabled);
    this.selectedUrls = [];
    this.syncSelectedSet_();
    await this.load();
  }

  private openAssignGroup(): void {
    const ids = this.selectedSources().map((source: BookSource): number => source.id);
    if (ids.length === 0) return;
    this.groupAssignDlg = new CustomDialogController({
      builder: SourceGroupAssignDialog({
        controller: this.groupAssignDlg!, sourceIds: ids,
        onChanged: () => { this.selectedUrls = []; this.load(); }
      }), autoCancel: true, alignment: DialogAlignment.Bottom, customStyle: true
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
      await this.dao_.batchDelete(selected.map((source: BookSource): number => source.id));
      this.selectedUrls = [];
      this.syncSelectedSet_();
      await this.load();
    });
  }

  private async doExport(): Promise<void> {
    const target = this.selectedUrls.length > 0 ? this.selectedSources() : this.filtered;
    if (!this.dao_ || target.length === 0) {
      UiUtil.showToast(this.getUIContext(), { message: '没有可导出的书源', duration: 1500 });
      return;
    }
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const uris = await documentPicker.save({ newFileNames: ['bookSources.json'] });
      if (!uris || uris.length === 0) return;
      const json = await this.dao_.exportSources(target);
      const file = fileIo.openSync(uris[0], fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, json);
      fileIo.closeSync(file);
      UiUtil.showToast(this.getUIContext(), { message: '已导出 ' + target.length + ' 个书源', duration: 1800 });
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: '导出失败：' + String(e), duration: 2000 });
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
        jsLib: source.jsLib || '', variableComment: source.variableComment || ''
      }), autoCancel: true, customStyle: true, alignment: DialogAlignment.Center
    });
    this.loginDlg.open();
  }

  private async moveToEdge(source: BookSource, top: boolean): Promise<void> {
    if (!this.dao_) return;
    await this.dao_.moveSourceToEdge(source.id, top);
    this.contextMenuUrl = '';
    this.sortMode = 0;
    this.sortAscending = true;
    await this.load();
  }

  private async toggleExplore(source: BookSource): Promise<void> {
    if (!this.dao_) return;
    await this.dao_.batchSetExploreEnabled([source.id], !source.enabledExplore);
    this.contextMenuUrl = '';
    await this.load();
  }

  private openCheckConfig(): void {
    if (this.selectedUrls.length === 0) return;
    this.checkConfigDlg = new CustomDialogController({
      builder: SourceCheckConfigDialog({
        controller: this.checkConfigDlg!, onStart: (config: CheckConfig) => { this.startCheck(config); }
      }), autoCancel: true, alignment: DialogAlignment.Bottom, customStyle: true
    });
    this.checkConfigDlg.open();
  }

  private startCheck(config: CheckConfig): void {
    const targets = this.selectedSources();
    if (targets.length === 0) return;
    this.isChecking = true;
    this.checkProgress = 0;
    this.checkTotal = targets.length;
    this.checkResults = [];
    this.checkResByUrl = new Map();
    this.showCheckSummary = false;
    this.selectedUrls = [];
    this.syncSelectedSet_();
    this.activeChecker_ = new SourceChecker(config);
    this.activeChecker_.checkSources(targets, (completed: number, total: number, result: CheckResult) => {
      this.checkProgress = completed;
      this.checkTotal = total;
      this.checkResults = [...this.checkResults, result];
      const map = new Map(this.checkResByUrl);
      map.set(result.sourceUrl, result);
      this.checkResByUrl = map;
      const search = result.details.find((item: CheckDetail): boolean => item.name === '搜索' && item.passed);
      const source = targets.find((item: BookSource): boolean => item.sourceUrl === result.sourceUrl);
      if (search && source && this.dao_) this.dao_.updateRespondTime(source.id, search.duration);
    }).then(() => {
      this.isChecking = false;
      this.showCheckSummary = true;
      this.activeChecker_ = null;
    });
  }

  private cancelCheck(): void {
    this.activeChecker_?.cancel();
    this.isChecking = false;
  }

  private getCheckDetails(url: string): CheckDetail[] {
    const result = this.checkResByUrl.get(url);
    return result ? result.details : [];
  }

  build() {
    Column() {
      Row() {
        Button('‹').fontSize(26).width(40).height(40).backgroundColor('transparent')
          .fontColor(ThemeColors.onBackground(this.isDark)).onClick(() => { UiUtil.back(this.getUIContext()); })
        Column() {
          Text('书源管理').fontSize(20).fontWeight(FontWeight.Bold)
            .fontColor(ThemeColors.onBackground(this.isDark)).width('100%')
          Text(this.sources.length + ' 个书源' + (this.selectedUrls.length > 0 ? ' · 已选 ' + this.selectedUrls.length : ''))
            .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).width('100%')
        }.layoutWeight(1)
        if (this.selectedUrls.length > 0) {
          Button('取消').height(40).backgroundColor('transparent').fontColor(ThemeColors.primary(this.isDark))
            .onClick(() => { this.selectedUrls = []; this.syncSelectedSet_(); })
        } else {
          Button('+').fontSize(24).width(40).height(40).borderRadius(20)
            .backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark))
            .onClick(() => { UiUtil.pushUrl(this.getUIContext(), { url: 'pages/BookSourceEditPage' }); })
          Button('导入').height(40).backgroundColor('transparent').fontColor(ThemeColors.primary(this.isDark))
            .onClick(() => { this.importDlg?.open(); })
          Button('分组').height(40).backgroundColor('transparent').fontColor(ThemeColors.primary(this.isDark))
            .onClick(() => { this.groupManageDlg?.open(); })
        }
      }.height(64).padding({ left: 8, right: 8 }).width('100%')

      Row() {
        TextInput({ placeholder: '搜索名称、网址或分组', text: this.searchText })
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
            Text(group).fontSize(13).height(36).padding({ left: 14, right: 14 })
              .fontColor(this.groupFilter === group ? ThemeColors.onPrimary(this.isDark) : ThemeColors.onSurface(this.isDark))
              .backgroundColor(this.groupFilter === group ? ThemeColors.primary(this.isDark) : ThemeColors.surfaceVariant(this.isDark))
              .borderRadius(18).margin({ right: 8 }).textAlign(TextAlign.Center)
              .onClick(() => { this.groupFilter = this.groupFilter === group ? '' : group; this.applyFilters(); })
          })
        }.padding({ left: 16, right: 8, top: 10, bottom: 8 })
      }.width('100%').scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)

      Row() {
        Toggle({ type: ToggleType.Switch, isOn: this.groupByDomain }).onChange((value: boolean) => { this.groupByDomain = value; })
        Text('按域名归类显示').fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ left: 8 })
        Blank()
        Text(this.filtered.length + ' 项').fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
      }.height(40).padding({ left: 16, right: 16 }).width('100%')

      if (this.isLoading) {
        Column() { LoadingProgress().color(ThemeColors.primary(this.isDark)); Text('正在加载书源').fontSize(13).margin({ top: 10 }).fontColor(ThemeColors.secondaryText(this.isDark)) }
          .layoutWeight(1).justifyContent(FlexAlign.Center)
      } else if (this.filtered.length === 0) {
        Column() { Text('没有匹配的书源').fontSize(18).fontWeight(FontWeight.Medium); Text('可调整搜索或筛选条件').fontSize(13).margin({ top: 8 }).fontColor(ThemeColors.secondaryText(this.isDark)) }
          .layoutWeight(1).justifyContent(FlexAlign.Center)
      } else {
        List({ space: 4 }) {
          ForEach(this.getDisplayList(), (source: BookSource) => {
            ListItem() { this.sourceItem(source) }
          }, (source: BookSource): string => source.sourceUrl)
        }.layoutWeight(1).padding({ left: 12, right: 12, bottom: this.selectedUrls.length > 0 ? 4 : 12 })
      }

      if (this.selectedUrls.length > 0) {
        Scroll() {
          Row() {
            this.actionButton('全选', () => { this.toggleSelectAll(); })
            this.actionButton('启用', () => { this.batchEnable(true); })
            this.actionButton('禁用', () => { this.batchEnable(false); })
            this.actionButton('启用发现', () => { this.batchExplore(true); })
            this.actionButton('停用发现', () => { this.batchExplore(false); })
            this.actionButton('分组', () => { this.openAssignGroup(); })
            this.actionButton('校验', () => { this.openCheckConfig(); })
            this.actionButton('导出', () => { this.doExport(); })
            Button('删除').height(40).borderRadius(20).padding({ left: 16, right: 16 })
              .backgroundColor(ThemeColors.error(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark))
              .onClick(() => { this.confirmDelete(); })
          }.padding({ left: 12, right: 12, top: 8, bottom: 8 })
        }.height(56).width('100%').scrollable(ScrollDirection.Horizontal)
          .backgroundColor(ThemeColors.surface(this.isDark)).scrollBar(BarState.Off)
      }

      if (this.isChecking) {
        Row() {
          Progress({ value: this.checkProgress, total: Math.max(1, this.checkTotal), type: ProgressType.Ring })
            .width(28).height(28).color(ThemeColors.primary(this.isDark))
          Text('正在校验 ' + this.checkProgress + '/' + this.checkTotal).fontSize(13).layoutWeight(1)
            .fontColor(ThemeColors.onSurface(this.isDark)).margin({ left: 10 })
          Button('停止').height(40).backgroundColor('transparent').fontColor(ThemeColors.error(this.isDark))
            .onClick(() => { this.cancelCheck(); })
        }.height(56).padding({ left: 16, right: 12 }).width('100%').backgroundColor(ThemeColors.surface(this.isDark))
      } else if (this.showCheckSummary && this.checkResults.length > 0) {
        Row() {
          Text('校验：通过 ' + this.checkResults.filter((item: CheckResult): boolean => item.status === 'success').length +
            ' · 部分 ' + this.checkResults.filter((item: CheckResult): boolean => item.status === 'partial').length +
            ' · 失败 ' + this.checkResults.filter((item: CheckResult): boolean => item.status === 'fail').length)
            .fontSize(13).fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1)
          Button('关闭').height(40).backgroundColor('transparent').fontColor(ThemeColors.primary(this.isDark))
            .onClick(() => { this.showCheckSummary = false; })
        }.height(52).padding({ left: 16, right: 12 }).width('100%').backgroundColor(ThemeColors.surface(this.isDark))
      }
      WebViewEngine().width(1).height(1).visibility(Visibility.Hidden)
    }.width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
      .onClick(() => { this.showSortMenu = false; this.contextMenuUrl = ''; })
  }

  @Builder
  actionButton(label: string, action: () => void) {
    Button(label).height(40).borderRadius(20).padding({ left: 14, right: 14 }).margin({ right: 6 })
      .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).fontColor(ThemeColors.onSurface(this.isDark))
      .onClick(action)
  }

  @Builder
  sourceItem(source: BookSource) {
    Stack() {
      Row() {
        // Checkbox 常驻 DOM，通过 visibility 控制显隐，避免选择模式切换时大量组件创建/销毁导致主线程阻塞
        Checkbox({ name: source.sourceUrl, group: 'book_sources' }).select(this.isSelected(source.sourceUrl))
          .selectedColor(ThemeColors.primary(this.isDark)).margin({ right: 10 })
          .visibility(this.isSelectMode() ? Visibility.Visible : Visibility.None)
          .onChange(() => { this.toggleSelect(source.sourceUrl); })
        Column() {
          Row() {
            Text(source.sourceName || '未命名书源').fontSize(16).fontWeight(FontWeight.Medium)
              .fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Toggle({ type: ToggleType.Switch, isOn: source.enabled }).onChange(async (enabled: boolean) => {
              await this.dao_?.toggleByUrl(source.sourceUrl, enabled); await this.load();
            }).visibility(this.isSelectMode() ? Visibility.None : Visibility.Visible)
          }.width('100%')
          Text(source.sourceUrl).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').margin({ top: 3 })
          Row() {
            if (source.group) Text(source.group).fontSize(11).fontColor(ThemeColors.primary(this.isDark)).maxLines(1)
            Text('权重 ' + (source.weight || 0)).fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ left: source.group ? 10 : 0 })
            if (source.respondTime > 0) Text(source.respondTime + ' ms').fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ left: 10 })
            if (!source.enabledExplore) Text('发现停用').fontSize(11).fontColor(ThemeColors.error(this.isDark)).margin({ left: 10 })
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
          if (this.isSelectMode()) this.toggleSelect(source.sourceUrl);
          else UiUtil.pushUrl(this.getUIContext(), { url: 'pages/BookSourceEditPage', params: { url: source.sourceUrl } });
        })
        Button('⋮').fontSize(22).width(40).height(40).backgroundColor('transparent')
          .fontColor(ThemeColors.secondaryText(this.isDark))
          .visibility(this.isSelectMode() ? Visibility.None : Visibility.Visible)
          .onClick(() => { this.contextMenuUrl = this.contextMenuUrl === source.sourceUrl ? '' : source.sourceUrl; })
      }.width('100%').padding({ left: 12, right: 6, top: 12, bottom: 12 })
        .borderRadius(16).backgroundColor(this.isSelected(source.sourceUrl) ? ThemeColors.surfaceVariant(this.isDark) : ThemeColors.surface(this.isDark))
        .gesture(LongPressGesture().onAction(() => { this.toggleSelect(source.sourceUrl); }))

      if (this.contextMenuUrl === source.sourceUrl) {
        Column() {
          if (source.loginUrl || source.loginUi) this.menuItem('登录', false, () => { this.contextMenuUrl = ''; this.openLogin(source); })
          this.menuItem('置顶', false, () => { this.moveToEdge(source, true); })
          this.menuItem('置底', false, () => { this.moveToEdge(source, false); })
          this.menuItem(source.enabledExplore ? '停用发现' : '启用发现', false, () => { this.toggleExplore(source); })
          this.menuItem('搜索测试', false, () => { this.contextMenuUrl = ''; this.openSearch(source); })
          this.menuItem('规则调试', false, () => { this.contextMenuUrl = ''; this.openDebug(source); })
          this.menuItem('删除', true, () => { this.selectedUrls = [source.sourceUrl]; this.syncSelectedSet_(); this.contextMenuUrl = ''; this.confirmDelete(); })
        }.width(136).padding({ top: 4, bottom: 4 }).borderRadius(16)
          .backgroundColor(ThemeColors.surface(this.isDark)).shadow({ radius: 12, color: ThemeColors.scrim(this.isDark) })
          .position({ x: 'calc(100% - 148)', y: 48 }).zIndex(120)
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
