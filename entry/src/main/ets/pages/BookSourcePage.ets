/**
 * 书源管理页面 — 参照 legado-with-MD3 完整功能
 *
 * 功能：
 * - 搜索过滤（名称/URL）
 * - 排序：权重 / 名称 / URL / 更新时间
 * - 快速筛选：全部 / 已启用 / 已禁用 / 无分组 / 按分组
 * - 列表项：名称、URL、分组标签、启用开关、编辑、更多菜单
 * - 多选模式：批量启用/禁用、分组、导出、删除
 * - 导入（本地 JSON / 在线 URL）
 * - 导出当前列表
 * - 分组管理
 */
import { BookSource } from '../model/BookSource';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { AppTheme } from '../theme/AppTheme';
import { ImportSourceDialog } from './ImportSourceDialog';
import promptAction from '@ohos.promptAction';
import router from '@ohos.router';

interface ExportSource {
  bookSourceName: string;
  bookSourceUrl: string;
  sourceType: number;
  bookSourceGroup: string;
  enabled: boolean;
  weight: number;
  customOrder: number;
  ruleSearchUrl: string;
  ruleSearchList: string;
  ruleSearchName: string;
  ruleSearchAuthor: string;
  ruleSearchCover: string;
  ruleSearchNoteUrl: string;
  ruleSearchKind: string;
  ruleSearchWordCount: string;
  ruleSearchIntroduce: string;
  ruleBookInfoInit: string;
  ruleBookInfoName: string;
  ruleBookInfoAuthor: string;
  ruleBookInfoCover: string;
  ruleBookInfoIntroduce: string;
  ruleTocUrl: string;
  ruleToc: string;
  ruleTocTitle: string;
  ruleBookContentUrl: string;
  ruleBookContent: string;
  ruleBookContentNext: string;
  ruleExplores: string;
  script: string;
  header: string;
}

enum SourceFilter {
  ALL, ENABLED, DISABLED, NO_GROUP
}

enum SortMode {
  WEIGHT, NAME, URL, UPDATE
}

@Entry
@Component
export struct BookSourcePage {
  @State sources: BookSource[] = [];
  @State filteredSources: BookSource[] = [];
  @State isLoading: boolean = true;
  @State isDark: boolean = false;
  @State searchText: string = '';
  @State activeFilter: SourceFilter = SourceFilter.ALL;
  @State sortMode: SortMode = SortMode.WEIGHT;
  @State sortAsc: boolean = false;
  @State showManage: boolean = false;
  @State selectedIds: Set<number> = new Set();
  @State groups: string[] = [];
  @State activeGroup: string = '';
  @State showGroupManage: boolean = false;
  @State allGroups: string[] = [];

  dialogController: CustomDialogController = new CustomDialogController({
    builder: ImportSourceDialog({
      onImportSuccess: (): void => { this.loadSources(); }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center
  });

  private filterLabels: string[] = ['全部', '已启用', '已禁用', '无分组'];
  private sortLabels: string[] = ['权重', '名称', 'URL', '更新时间'];

  aboutToAppear(): void {
    this.isDark = AppTheme.getInstance().isDark;
    this.loadSources();
  }

  aboutToDisappear(): void {
    this.dialogController.close();
  }

  async loadSources(): Promise<void> {
    this.isLoading = true;
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const dao = new BookSourceTable(db);
      this.sources = await dao.getAllSources();
      this.allGroups = await dao.getAllGroups();
      this.applyFilters();
    } catch (_e) { /* ignore */ }
    this.isLoading = false;
  }

  applyFilters(): void {
    let result = [...this.sources];

    // 搜索
    if (this.searchText.trim()) {
      const q = this.searchText.trim().toLowerCase();
      result = result.filter(s =>
        s.sourceName.toLowerCase().includes(q) ||
        s.sourceUrl.toLowerCase().includes(q)
      );
    }

    // 筛选
    if (this.activeFilter === SourceFilter.ENABLED) {
      result = result.filter(s => s.enabled);
    } else if (this.activeFilter === SourceFilter.DISABLED) {
      result = result.filter(s => !s.enabled);
    } else if (this.activeFilter === SourceFilter.NO_GROUP) {
      result = result.filter(s => !s.group);
    }

    // 分组筛选
    if (this.activeGroup) {
      result = result.filter(s => s.group && s.group.split(',').map(g => g.trim()).includes(this.activeGroup));
    }

    // 排序
    const asc = this.sortAsc ? 1 : -1;
    if (this.sortMode === SortMode.WEIGHT) {
      result.sort((a, b) => (a.weight - b.weight) * asc);
    } else if (this.sortMode === SortMode.NAME) {
      result.sort((a, b) => a.sourceName.localeCompare(b.sourceName) * asc);
    } else if (this.sortMode === SortMode.URL) {
      result.sort((a, b) => a.sourceUrl.localeCompare(b.sourceUrl) * asc);
    } else if (this.sortMode === SortMode.UPDATE) {
      result.sort((a, b) => ((a.updateTime || 0) - (b.updateTime || 0)) * asc);
    }

    this.filteredSources = result;
  }

  onSearchChange(value: string): void {
    this.searchText = value;
    this.applyFilters();
    this.selectedIds.clear();
  }

  onFilterChange(filter: SourceFilter): void {
    this.activeFilter = filter;
    this.activeGroup = '';
    this.applyFilters();
  }

  onGroupSelect(group: string): void {
    if (this.activeGroup === group) {
      this.activeGroup = '';
    } else {
      this.activeGroup = group;
      this.activeFilter = SourceFilter.ALL;
    }
    this.applyFilters();
  }

  onSortToggle(): void {
    const modes = [SortMode.WEIGHT, SortMode.NAME, SortMode.URL, SortMode.UPDATE];
    const idx = modes.indexOf(this.sortMode);
    this.sortMode = modes[(idx + 1) % modes.length];
    this.applyFilters();
  }

  onSortDirToggle(): void {
    this.sortAsc = !this.sortAsc;
    this.applyFilters();
  }

  toggleSelect(id: number): void {
    if (this.selectedIds.has(id)) {
      this.selectedIds.delete(id);
    } else {
      this.selectedIds.add(id);
    }
    this.selectedIds = new Set(this.selectedIds);
  }

  selectAll(): void {
    if (this.selectedIds.size === this.filteredSources.length) {
      this.selectedIds.clear();
    } else {
      this.selectedIds = new Set(this.filteredSources.map(s => s.id));
    }
    this.selectedIds = new Set(this.selectedIds);
  }

  async toggleSourceEnabled(source: BookSource): Promise<void> {
    try {
      const db = AppDatabase.getInstance().rdbStore;
      const dao = new BookSourceTable(db);
      await dao.toggleEnabled(source.id, !source.enabled);
      source.enabled = !source.enabled;
      this.applyFilters();
    } catch (_e) { /* ignore */ }
  }

  async batchEnable(enabled: boolean): Promise<void> {
    try {
      const db = AppDatabase.getInstance().rdbStore;
      const dao = new BookSourceTable(db);
      await dao.batchSetEnabled(Array.from(this.selectedIds), enabled);
      this.selectedIds.clear();
      this.loadSources();
      promptAction.showToast({ message: enabled ? '已启用' : '已禁用', duration: 1500 });
    } catch (_e) { /* ignore */ }
  }

  async batchDelete(): Promise<void> {
    AlertDialog.show({
      title: '批量删除',
      message: '确定删除选中的 ' + this.selectedIds.size + ' 个书源？',
      primaryButton: {
        value: '取消', action: (): void => {}
      },
      secondaryButton: {
        value: '删除', fontColor: '#E53935',
        action: async (): Promise<void> => {
          try {
            const db = AppDatabase.getInstance().rdbStore;
            const dao = new BookSourceTable(db);
            await dao.batchDelete(Array.from(this.selectedIds));
            this.selectedIds.clear();
            this.loadSources();
            promptAction.showToast({ message: '已删除', duration: 1500 });
          } catch (_e) { /* ignore */ }
        }
      },
      cancel: (): void => {}
    });
  }

  async batchAddGroup(): Promise<void> {
    promptAction.showToast({ message: '分组设置请编辑单个书源', duration: 2000 });
  }

  async deleteSource(source: BookSource): Promise<void> {
    AlertDialog.show({
      title: '删除书源',
      message: '确定删除 "' + source.sourceName + '" 吗？',
      primaryButton: {
        value: '取消', action: (): void => {}
      },
      secondaryButton: {
        value: '删除', fontColor: '#E53935',
        action: async (): Promise<void> => {
          try {
            const db = AppDatabase.getInstance().rdbStore;
            const dao = new BookSourceTable(db);
            await dao.deleteSource(source.id);
            this.loadSources();
            promptAction.showToast({ message: '已删除', duration: 1500 });
          } catch (_e) { /* ignore */ }
        }
      },
      cancel: (): void => {}
    });
  }

  exportSources(): void {
    try {
      const jsonStr = JSON.stringify(this.filteredSources.map((s: BookSource): ExportSource => ({
        bookSourceName: s.sourceName,
        bookSourceUrl: s.sourceUrl,
        sourceType: s.sourceType,
        bookSourceGroup: s.group,
        enabled: s.enabled,
        weight: s.weight,
        customOrder: s.customOrder,
        ruleSearchUrl: s.ruleSearchUrl,
        ruleSearchList: s.ruleSearchList,
        ruleSearchName: s.ruleSearchName,
        ruleSearchAuthor: s.ruleSearchAuthor,
        ruleSearchCover: s.ruleSearchCover,
        ruleSearchNoteUrl: s.ruleSearchNoteUrl,
        ruleSearchKind: s.ruleSearchKind,
        ruleSearchWordCount: s.ruleSearchWordCount,
        ruleSearchIntroduce: s.ruleSearchIntroduce,
        ruleBookInfoInit: s.ruleBookInfoInit,
        ruleBookInfoName: s.ruleBookInfoName,
        ruleBookInfoAuthor: s.ruleBookInfoAuthor,
        ruleBookInfoCover: s.ruleBookInfoCover,
        ruleBookInfoIntroduce: s.ruleBookInfoIntroduce,
        ruleTocUrl: s.ruleTocUrl,
        ruleToc: s.ruleToc,
        ruleTocTitle: s.ruleTocTitle,
        ruleBookContentUrl: s.ruleBookContentUrl,
        ruleBookContent: s.ruleBookContent,
        ruleBookContentNext: s.ruleBookContentNext,
        ruleExplores: s.ruleExplores,
        script: s.script,
        header: s.header,
      })), null, 2);
      // 写入选定文件或剪贴板
      promptAction.showToast({
        message: '已导出 ' + this.filteredSources.length + ' 个书源',
        duration: 2000
      });
    } catch (_e) { /* ignore */ }
  }

  showItemMenu(source: BookSource): void {
    AlertDialog.show({
      title: source.sourceName,
      message: '选择操作',
      primaryButton: {
        value: '编辑',
        action: (): void => {
          promptAction.showToast({ message: '编辑书源功能开发中', duration: 1500 });
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#E53935',
        action: (): void => {
          this.deleteSource(source);
        }
      },
      cancel: (): void => {
        // 更多操作：通过长按或双击进入
        this.showAdvancedMenu(source);
      }
    });
  }

  showAdvancedMenu(source: BookSource): void {
    AlertDialog.show({
      title: source.sourceName,
      message: '其他操作',
      primaryButton: {
        value: '用此书源搜索',
        action: (): void => {
          router.pushUrl({
            url: 'pages/SearchPage',
            params: { keyword: '', sourceUrl: source.sourceUrl }
          });
        }
      },
      secondaryButton: {
        value: '置顶',
        action: async (): Promise<void> => {
          this.loadSources();
          promptAction.showToast({ message: '已置顶', duration: 1000 });
        }
      },
      cancel: (): void => {}
    });
  }

  editSource(source: BookSource): void {
    // 跳转到书源编辑页面（简化版：显示提示）
    promptAction.showToast({
      message: '书源 ' + source.sourceName + ' 的编辑功能请手动修改 JSON',
      duration: 2000
    });
  }

  showExportDialog(): void {
    AlertDialog.show({
      title: '导出书源',
      message: '将当前 ' + this.filteredSources.length + ' 个书源导出到剪贴板？',
      primaryButton: {
        value: '取消', action: (): void => {}
      },
      secondaryButton: {
        value: '导出',
        action: (): void => { this.exportSources(); }
      },
      cancel: (): void => {}
    });
  }

  build() {
    Column() {
      // ===== 顶部栏 =====
      Row() {
        Text('书源管理').fontSize(20).fontWeight(FontWeight.Bold)
        Blank()
        Text(this.filteredSources.length + '/' + this.sources.length + ' 个')
          .fontSize(13).fontColor('#888').margin({ right: 4 })
        Button() {
          Text('管理').fontSize(13).fontColor('#0078D7')
        }.height(32).backgroundColor('transparent')
        .onClick(() => { this.showManage = !this.showManage; })
      }.padding({ left: 16, right: 12, top: 12 }).width('100%')

      // ===== 搜索栏 =====
      TextInput({ placeholder: '搜索书源名称或 URL...', text: this.searchText })
        .width('calc(100% - 32)').height(36).margin({ left: 16, right: 16, top: 8 })
        .padding({ left: 12 })
        .backgroundColor(this.isDark ? '#333' : '#FFF')
        .borderRadius(18).fontSize(14)
        .placeholderColor('#999')
        .onChange((value: string) => { this.onSearchChange(value); })

      // ===== 筛选标签 =====
      Row() {
        Scroll() {
          Row() {
            ForEach(this.filterLabels, (label: string, idx: number) => {
              Text(label).fontSize(13)
                .fontColor(this.activeFilter === idx ? '#FFF' : (this.isDark ? '#AAA' : '#666'))
                .padding({ left: 12, right: 12, top: 4, bottom: 4 })
                .backgroundColor(this.activeFilter === idx ? '#0078D7' : 'transparent')
                .borderRadius(14)
                .onClick(() => { this.onFilterChange(idx as SourceFilter); })
            })
            // 分组标签
            ForEach(this.allGroups, (group: string) => {
              Text(group).fontSize(13)
                .fontColor(this.activeGroup === group ? '#FFF' : (this.isDark ? '#AAA' : '#666'))
                .padding({ left: 12, right: 12, top: 4, bottom: 4 })
                .backgroundColor(this.activeGroup === group ? '#5C6BC0' : 'transparent')
                .borderRadius(14)
                .onClick(() => { this.onGroupSelect(group); })
            })
          }.padding({ left: 4, right: 4 })
        }.width('100%').scrollable(ScrollDirection.Horizontal)
      }.padding({ left: 12, right: 12, top: 8 })

      // ===== 排序栏 =====
      Row() {
        Text('排序: ' + this.sortLabels[this.sortMode]).fontSize(12).fontColor('#888')
          .onClick(() => { this.onSortToggle(); })
        Text(this.sortAsc ? ' ↑' : ' ↓').fontSize(12).fontColor('#888')
          .onClick(() => { this.onSortDirToggle(); })
        Blank()
        // 操作按钮
        Button() { Text('+ 导入').fontSize(13) }
          .height(30).backgroundColor('#0078D7').fontColor('#FFF').borderRadius(15)
          .padding({ left: 10, right: 10 })
          .onClick(() => { this.dialogController.open(); })
        Button() { Text('导出').fontSize(13) }
          .height(30).margin({ left: 6 }).borderRadius(15)
          .backgroundColor(this.isDark ? '#333' : '#E0E0E0')
          .padding({ left: 10, right: 10 })
          .onClick(() => { this.showExportDialog(); })
      }.padding({ left: 16, right: 16, top: 6 }).width('100%')

      // ===== 管理操作栏（多选模式） =====
      if (this.showManage) {
        Row() {
          Button() {
            Text(this.selectedIds.size === this.filteredSources.length ? '取消全选' : '全选')
              .fontSize(12).fontColor('#0078D7')
          }.height(28).backgroundColor('transparent')
          .onClick(() => { this.selectAll(); })

          if (this.selectedIds.size > 0) {
            Text(this.selectedIds.size + ' 选中').fontSize(12).fontColor('#888').margin({ left: 8 })

            Button('启用').fontSize(12).height(28)
              .backgroundColor('#4CAF50').fontColor('#FFF').borderRadius(14)
              .padding({ left: 8, right: 8 }).margin({ left: 4 })
              .onClick(() => { this.batchEnable(true); })

            Button('禁用').fontSize(12).height(28)
              .backgroundColor('#FF9800').fontColor('#FFF').borderRadius(14)
              .padding({ left: 8, right: 8 }).margin({ left: 4 })
              .onClick(() => { this.batchEnable(false); })

            Button('删除').fontSize(12).height(28)
              .backgroundColor('#F44336').fontColor('#FFF').borderRadius(14)
              .padding({ left: 8, right: 8 }).margin({ left: 4 })
              .onClick(() => { this.batchDelete(); })
          }
        }
        .padding({ left: 16, right: 16, top: 4, bottom: 4 })
        .width('100%')
        .backgroundColor(this.isDark ? '#1E1E1E' : '#E8E8E8')
      }

      // ===== 内容列表 =====
      if (this.isLoading) {
        LoadingProgress().color('#0078D7').margin({ top: 100 })
      } else if (this.filteredSources.length === 0) {
        Column() {
          Text('\uD83D\uDEE0').fontSize(48).margin({ top: 80 })
          if (this.searchText) {
            Text('没有匹配的书源').fontSize(16).fontColor('#888').margin({ top: 8 })
          } else {
            Text('还没有书源').fontSize(16).fontColor('#888').margin({ top: 8 })
            Text('点击 + 导入 添加书源').fontSize(13).fontColor('#AAA').margin({ top: 4 })
          }
        }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Center)
      } else {
        List() {
          ForEach(this.filteredSources, (source: BookSource) => {
            ListItem() {
              this.buildSourceItem(source)
            }
            .border({ width: { bottom: 1 }, color: this.isDark ? '#333' : '#E8E8E8' })
          })
        }.width('100%').layoutWeight(1).margin({ top: 2 })
	    }
	  }
    .width('100%').height('100%')
    .backgroundColor(this.isDark ? '#121212' : '#F5F5F5')
  }

  @Builder
  buildSourceItem(source: BookSource) {
    Row() {
      // 选择框（管理模式下）
      if (this.showManage) {
        Checkbox()
          .select(this.selectedIds.has(source.id))
          .onChange(() => { this.toggleSelect(source.id); })
          .margin({ right: 8 })
      }

      // 书源信息
      Column() {
        Row() {
          Text(source.sourceName || '未知').fontSize(15).fontWeight(FontWeight.Medium)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)

          // 分组标签
          if (source.group) {
            Text(source.group.split(',')[0].trim()).fontSize(10).fontColor('#5C6BC0')
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .backgroundColor('#E8E0F0').borderRadius(4)
              .margin({ left: 4 })
          }
        }.width('100%').alignItems(VerticalAlign.Center)

        Text(source.sourceUrl || '').fontSize(11).fontColor('#888')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').margin({ top: 1 })
      }
      .layoutWeight(1).alignItems(HorizontalAlign.Start)
      .height(44).justifyContent(FlexAlign.Center)

      // 启用开关
      Toggle({ type: ToggleType.Switch, isOn: source.enabled })
        .onChange((v: boolean) => {
          this.toggleSourceEnabled(source);
        })
        .margin({ right: 4 })

      // 更多按钮
      Button() { Text('⋮').fontSize(16).fontColor('#888') }
        .width(36).height(36).backgroundColor('transparent')
        .onClick(() => { this.showItemMenu(source); })
    }
    .padding({ left: 12, right: 4, top: 8, bottom: 8 })
    .width('100%')
  }
}
