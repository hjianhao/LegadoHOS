/**
 * 替换净化规则管理页
 * 仿 BookSourcePage 结构：搜索 / 分组 chips / 列表启停 / 多选批量操作 / 导入导出。
 * 导入支持本地文件、剪贴板（PasteButton 安全控件）、网络链接三入口，
 * 兼容安卓新旧两种 JSON 格式（见 util/ReplaceRuleJson.ts）。
 */
import { ReplaceRule } from '../model/ReplaceRule';
import { AppDatabase } from '../data/database/AppDatabase';
import { ReplaceRuleTable } from '../data/database/ReplaceRuleTable';
import { parseReplaceRulesJson, replaceRulesToJsonText } from '../util/ReplaceRuleJson';
import picker from '@ohos.file.picker';
import fileIo from '@ohos.file.fs';
import util from '@ohos.util';
import pasteboard from '@ohos.pasteboard';
import { NetUtil } from '../util/NetUtil';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';
import { AppBackButton } from '../components/common/AppTitleBar';

@Entry
@Component
struct ReplaceRulePage {
  @StorageLink('isDark') isDark: boolean = false;
  @State rules: ReplaceRule[] = [];
  @State filtered: ReplaceRule[] = [];
  @State searchText: string = '';
  @State groupFilter: string = '全部';
  @State isLoading: boolean = true;
  @State isSelectMode_: boolean = false;
  @State selectedIds: number[] = [];
  @State selectedSet_: Set<number> = new Set();
  @State enabledStateVersion_: number = 0;
  @State contextMenuId: number = 0;
  @State showImportSheet: boolean = false;
  @State importUrlMode: boolean = false;
  @State importUrl: string = '';
  @State isImporting: boolean = false;
  private suppressClick_: boolean = false;
  private dao_: ReplaceRuleTable | null = null;
  private groups_: string[] = ['全部', '未分组'];

  aboutToAppear(): void {
    this.load();
  }

  /** 从新建/编辑页返回时重新读取数据库，避免列表保留旧的页面内存状态。 */
  onPageShow(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.isLoading = true;
    try {
      await AppDatabase.getInstance().waitForInit();
      this.dao_ = new ReplaceRuleTable(AppDatabase.getInstance().rdbStore);
      this.rules = await this.dao_.getAll();
      this.buildGroups();
      this.applyFilters();
      this.selectedIds = this.selectedIds.filter((id: number): boolean =>
        this.rules.some((rule: ReplaceRule): boolean => rule.id === id));
      this.syncSelectedSet_();
      if (this.selectedIds.length === 0) this.isSelectMode_ = false;
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: '加载规则失败：' + String(e), duration: 2000 });
    }
    this.isLoading = false;
  }

  /** 一条规则的 group 可含多个分组，按 ,/;/， 等分隔符拆分（仿安卓 dealGroups，简化处理） */
  private splitGroups(group: string): string[] {
    return (group || '').split(/[,，;；|｜\n\r\t]+/)
      .map((item: string): string => item.trim()).filter((item: string): boolean => item.length > 0);
  }

  private buildGroups(): void {
    const groups: string[] = [];
    this.rules.forEach((rule: ReplaceRule) => this.splitGroups(rule.group).forEach((group: string) => {
      if (!groups.includes(group)) groups.push(group);
    }));
    this.groups_ = ['全部', ...groups.sort(), '未分组'];
  }

  private applyFilters(): void {
    let list = this.rules.slice();
    const query = this.searchText.trim().toLowerCase();
    if (query) {
      list = list.filter((rule: ReplaceRule): boolean =>
        rule.name.toLowerCase().includes(query) || rule.pattern.toLowerCase().includes(query)
          || rule.replacement.toLowerCase().includes(query) || rule.scope.toLowerCase().includes(query));
    }
    if (this.groupFilter === '未分组') {
      list = list.filter((rule: ReplaceRule): boolean => !rule.group.trim());
    } else if (this.groupFilter && this.groupFilter !== '全部') {
      list = list.filter((rule: ReplaceRule): boolean => this.splitGroups(rule.group).includes(this.groupFilter));
    }
    this.filtered = list;
  }

  private syncSelectedSet_(): void {
    this.selectedSet_ = new Set(this.selectedIds);
  }

  private isSelected(id: number): boolean { return this.selectedSet_.has(id); }

  private isRuleEnabled(rule: ReplaceRule): boolean {
    return this.enabledStateVersion_ >= 0 && rule.isEnabled;
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

  private selectedRules(): ReplaceRule[] {
    return this.rules.filter((rule: ReplaceRule): boolean => this.selectedSet_.has(rule.id));
  }

  private toggleSelectAll(): void {
    setTimeout(() => {
      const visibleIds = this.filtered.map((rule: ReplaceRule): number => rule.id);
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
    const ids = this.selectedIds.slice();
    if (!this.dao_ || ids.length === 0) return;
    await this.dao_.updateEnabledByIds(ids, enabled);
    this.selectedRules().forEach((rule: ReplaceRule) => { rule.isEnabled = enabled; });
    this.enabledStateVersion_++;
    this.applyFilters();
    this.exitSelectMode();
  }

  private confirmDelete(targets: ReplaceRule[]): void {
    if (targets.length === 0) return;
    this.contextMenuId = 0;
    UiUtil.showDialog(this.getUIContext(), {
      title: '删除规则', message: '确定删除 ' + targets.length + ' 条净化规则？此操作不可撤销。',
      buttons: [
        { text: '取消', color: ThemeColors.secondaryText(this.isDark) },
        { text: '删除', color: ThemeColors.error(this.isDark) }
      ]
    }).then(async (result) => {
      if (result.index !== 1 || !this.dao_) return;
      await this.dao_.deleteByIds(targets.map((rule: ReplaceRule): number => rule.id));
      this.selectedIds = [];
      this.syncSelectedSet_();
      this.isSelectMode_ = false;
      await this.load();
    });
  }

  /** 置顶 = sort_order 取 getMinOrder()-1，置底 = getMaxOrder()+1（列表按 sort_order 升序） */
  private async moveToEdge(rule: ReplaceRule, top: boolean): Promise<void> {
    if (!this.dao_) return;
    rule.order = top ? (await this.dao_.getMinOrder()) - 1 : (await this.dao_.getMaxOrder()) + 1;
    await this.dao_.update(rule);
    this.contextMenuId = 0;
    await this.load();
  }

  private openEdit(rule: ReplaceRule): void {
    UiUtil.pushUrl(this.getUIContext(), { url: 'pages/ReplaceRuleEditPage', params: { id: String(rule.id) } });
  }

  /** 导出：选中的规则（无选中则全部）序列化为安卓兼容 JSON 数组写文件 */
  private async doExport(): Promise<void> {
    const target = this.selectedIds.length > 0 ? this.selectedRules() : this.rules;
    if (target.length === 0) {
      UiUtil.showToast(this.getUIContext(), { message: '没有可导出的规则', duration: 1500 });
      return;
    }
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const uris = await documentPicker.save({ newFileNames: ['replaceRules.json'] });
      if (!uris || uris.length === 0) return;
      const json = replaceRulesToJsonText(target);
      const file = fileIo.openSync(uris[0], fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, json);
      fileIo.closeSync(file);
      UiUtil.showToast(this.getUIContext(), { message: '已导出 ' + target.length + ' 条规则', duration: 1800 });
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: '导出失败：' + String(e), duration: 2000 });
    }
  }

  private async doFileImport(): Promise<void> {
    this.closeImportSheet();
    try {
      const uris = await new picker.DocumentViewPicker().select();
      if (!uris || uris.length === 0) return;
      const f = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
      const s = fileIo.statSync(f.fd);
      const b = new ArrayBuffer(s.size);
      fileIo.readSync(f.fd, b);
      fileIo.closeSync(f);
      const td = util.TextDecoder.create('utf-8');
      const json = td.decodeToString(new Uint8Array(b), { stream: false });
      await this.importFromText(json);
    } catch (e) {
      console.error('[ReplaceRule] fileImport error: ' + e);
      UiUtil.showToast(this.getUIContext(), { message: '读取文件失败', duration: 1500 });
    }
  }

  /** PasteButton 授权成功后读取剪贴板（安全控件临时授权，无需声明 READ_PASTEBOARD） */
  private async doClipboardImport(): Promise<void> {
    this.closeImportSheet();
    try {
      const data = await pasteboard.getSystemPasteboard().getData();
      const text = data.getPrimaryText();
      if (!text || !text.trim()) {
        UiUtil.showToast(this.getUIContext(), { message: '剪贴板没有文本内容', duration: 1500 });
        return;
      }
      await this.importFromText(text);
    } catch (e) {
      console.error('[ReplaceRule] clipboardImport error: ' + e);
      UiUtil.showToast(this.getUIContext(), { message: '读取剪贴板失败', duration: 1500 });
    }
  }

  private async doUrlImport(): Promise<void> {
    const url = this.importUrl.trim();
    if (!url) {
      UiUtil.showToast(this.getUIContext(), { message: '请输入链接', duration: 1500 });
      return;
    }
    this.closeImportSheet();
    this.isImporting = true;
    try {
      const json = await NetUtil.httpGet(url);
      this.isImporting = false;
      await this.importFromText(json);
      return;
    } catch (e) {
      console.error('[ReplaceRule] urlImport error: ' + e);
    }
    this.isImporting = false;
    UiUtil.showToast(this.getUIContext(), { message: '下载失败，请检查链接', duration: 2000 });
  }

  /**
   * 解析并按 id 去重落库：id 不存在→新增；id 相同且 pattern/replacement/isRegex/scope
   * 一致→跳过；id 相同内容不同→更新。toast 统计（新增x/更新y/跳过z）。
   */
  private async importFromText(text: string): Promise<void> {
    let imported: ReplaceRule[] = [];
    try {
      imported = parseReplaceRulesJson(text);
    } catch (e) {
      UiUtil.showToast(this.getUIContext(), { message: '解析失败：' + (e as Error).message, duration: 2000 });
      return;
    }
    if (imported.length === 0) {
      UiUtil.showToast(this.getUIContext(), { message: '未找到有效的净化规则', duration: 2000 });
      return;
    }
    if (!this.dao_) return;
    const byId: Map<number, ReplaceRule> = new Map();
    this.rules.forEach((rule: ReplaceRule) => { byId.set(rule.id, rule); });
    let added = 0;
    let updated = 0;
    let skipped = 0;
    try {
      for (const rule of imported) {
        const old = byId.get(rule.id);
        if (!old) {
          await this.dao_.insert(rule);
          byId.set(rule.id, rule);
          added++;
        } else if (old.pattern === rule.pattern && old.replacement === rule.replacement
          && old.isRegex === rule.isRegex && old.scope === rule.scope) {
          skipped++;
        } else {
          await this.dao_.update(rule);
          byId.set(rule.id, rule);
          updated++;
        }
      }
      UiUtil.showToast(this.getUIContext(), {
        message: '导入完成：新增 ' + added + ' · 更新 ' + updated + ' · 跳过 ' + skipped, duration: 2500 });
    } catch (e) {
      console.error('[ReplaceRule] import save error: ' + e);
      UiUtil.showToast(this.getUIContext(), { message: '导入失败：' + String(e), duration: 2000 });
    }
    await this.load();
  }

  private closeImportSheet(): void {
    this.showImportSheet = false;
    this.importUrlMode = false;
    this.importUrl = '';
  }

  build() {
    Stack() {
      Column() {
        // ===== 标题栏 =====
        Row() {
          AppBackButton({ onBack: () => { UiUtil.back(this.getUIContext()); } })
          Column() {
            Text('替换净化').fontSize(20).fontWeight(FontWeight.Bold)
              .fontColor(ThemeColors.onBackground(this.isDark)).width('100%')
            Text(this.rules.length + ' 条规则' + (this.isSelectMode_ ? ' · 已选 ' + this.selectedIds.length : ''))
              .fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).width('100%')
          }.layoutWeight(1)
          Button('取消').height(40).backgroundColor(ThemeColors.transparent()).fontColor(ThemeColors.primary(this.isDark))
            .visibility(this.isSelectMode_ ? Visibility.Visible : Visibility.Hidden)
            .onClick(() => { this.exitSelectMode(); })
          Button('新建').fontSize(14).height(40).borderRadius(20).padding({ left: 16, right: 16 })
            .backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark))
            .visibility(this.isSelectMode_ ? Visibility.Hidden : Visibility.Visible)
            .onClick(() => { UiUtil.pushUrl(this.getUIContext(), { url: 'pages/ReplaceRuleEditPage' }); })
          Button('导入').height(40).backgroundColor(ThemeColors.transparent()).fontColor(ThemeColors.primary(this.isDark))
            .visibility(this.isSelectMode_ ? Visibility.Hidden : Visibility.Visible)
            .onClick(() => { this.showImportSheet = true; })
        }.height(64).padding({ left: 4, right: 8 }).width('100%')
          .backgroundColor(ThemeColors.surface(this.isDark))
          .border({ width: { bottom: 0.5 }, color: ThemeColors.outlineVariant(this.isDark) })

        // ===== 搜索框 =====
        Row() {
          TextInput({ placeholder: '搜索名称 / 替换内容 / 替换为 / 范围', text: this.searchText })
            .height(48).layoutWeight(1).borderRadius(24).padding({ left: 16, right: 12 })
            .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
            .fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark))
            .onChange((value: string) => { this.searchText = value; this.applyFilters(); })
        }.padding({ left: 16, right: 16 }).width('100%')

        // ===== 分组 chips =====
        Scroll() {
          Row() {
            ForEach(this.groups_, (group: string) => {
              Text(group).fontSize(13).height(36).padding({ left: 14, right: 14 })
                .fontColor(this.groupFilter === group ? ThemeColors.onPrimary(this.isDark) : ThemeColors.onSurface(this.isDark))
                .backgroundColor(this.groupFilter === group ? ThemeColors.primary(this.isDark) : ThemeColors.surfaceVariant(this.isDark))
                .borderRadius(18).margin({ right: 8 }).textAlign(TextAlign.Center)
                .onClick(() => { this.groupFilter = group; this.applyFilters(); })
            }, (group: string): string => group)
          }.padding({ left: 16, right: 8, top: 10, bottom: 8 })
        }.width('100%').scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)

        // ===== 规则列表 =====
        if (this.isLoading) {
          Column() {
            LoadingProgress().color(ThemeColors.primary(this.isDark))
            Text('加载中').fontSize(13).margin({ top: 10 }).fontColor(ThemeColors.secondaryText(this.isDark))
          }.layoutWeight(1).justifyContent(FlexAlign.Center)
        } else if (this.filtered.length === 0) {
          Column() {
            Text('暂无净化规则').fontSize(18).fontWeight(FontWeight.Medium).fontColor(ThemeColors.onSurface(this.isDark))
            Text('点击右上角新建或导入').fontSize(13).margin({ top: 8 }).fontColor(ThemeColors.secondaryText(this.isDark))
          }.layoutWeight(1).justifyContent(FlexAlign.Center)
        } else {
          List({ space: 4 }) {
            ForEach(this.filtered, (rule: ReplaceRule) => {
              ListItem() { this.ruleItem(rule) }
            }, (rule: ReplaceRule): string => String(rule.id))
          }.layoutWeight(1).padding({ left: 12, right: 12, bottom: this.isSelectMode_ ? 4 : 12 })
        }

        // ===== 批量操作栏（visibility 控制，避免组件反复创建销毁） =====
        Scroll() {
          Row() {
            this.actionButton('全选', () => { this.toggleSelectAll(); })
            this.actionButton('批量启用', () => { this.batchEnable(true); })
            this.actionButton('批量禁用', () => { this.batchEnable(false); })
            this.actionButton('导出', () => { this.doExport(); })
            Button('删除').height(40).borderRadius(20).padding({ left: 16, right: 16 })
              .backgroundColor(ThemeColors.error(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark))
              .onClick(() => { this.confirmDelete(this.selectedRules()); })
          }.padding({ left: 12, right: 12, top: 8, bottom: 8 })
        }.height(this.isSelectMode_ ? 56 : 0).width('100%').scrollable(ScrollDirection.Horizontal)
          .backgroundColor(ThemeColors.surface(this.isDark)).scrollBar(BarState.Off)
          .visibility(this.isSelectMode_ ? Visibility.Visible : Visibility.Hidden)

        if (this.isImporting) {
          Row() {
            LoadingProgress().width(24).height(24).color(ThemeColors.primary(this.isDark))
            Text('正在导入…').fontSize(13).fontColor(ThemeColors.onSurface(this.isDark)).margin({ left: 10 })
          }.height(48).padding({ left: 16 }).width('100%').backgroundColor(ThemeColors.surface(this.isDark))
        }
      }.width('100%').height('100%').backgroundColor(ThemeColors.background(this.isDark))
        .onClick(() => { this.contextMenuId = 0; })

      // ===== 导入方式底部弹层 =====
      if (this.showImportSheet) {
        Stack() {
          // 遮罩点击层（点弹层外部关闭）
          Column() {
          }.width('100%').height('100%').onClick(() => { this.closeImportSheet(); })
          Column() {
            Text('导入净化规则').fontSize(16).fontWeight(FontWeight.Bold)
              .fontColor(ThemeColors.onSurface(this.isDark))
              .padding({ left: 16, top: 16, bottom: 8 }).width('100%')
            if (!this.importUrlMode) {
              this.sheetItem('本地文件', () => { this.doFileImport(); })
              Row() {
                Text('剪贴板').fontSize(15).fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1)
                PasteButton()
                  .padding({ left: 12, right: 12 })
                  .onClick((event: ClickEvent, result: PasteButtonOnClickResult) => {
                    if (result === PasteButtonOnClickResult.SUCCESS) {
                      this.doClipboardImport();
                    } else {
                      UiUtil.showToast(this.getUIContext(), { message: '未获得剪贴板授权', duration: 1500 });
                    }
                  })
              }.height(48).padding({ left: 16, right: 16 }).width('100%')
              this.sheetItem('网络链接', () => { this.importUrlMode = true; })
              this.sheetItem('取消', () => { this.closeImportSheet(); })
            } else {
              TextInput({ placeholder: '输入规则 JSON 链接（http/https）', text: this.importUrl })
                .height(44).borderRadius(8).padding({ left: 12 }).fontSize(14).width('100%')
                .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
                .fontColor(ThemeColors.onSurface(this.isDark)).placeholderColor(ThemeColors.secondaryText(this.isDark))
                .onChange((value: string) => { this.importUrl = value; })
              Row() {
                Button('取消').fontSize(14).height(40).layoutWeight(1).borderRadius(8).margin({ right: 6 })
                  .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).fontColor(ThemeColors.onSurface(this.isDark))
                  .onClick(() => { this.closeImportSheet(); })
                Button('下载导入').fontSize(14).height(40).layoutWeight(1).borderRadius(8).margin({ left: 6 })
                  .backgroundColor(ThemeColors.primary(this.isDark)).fontColor(ThemeColors.onPrimary(this.isDark))
                  .onClick(() => { this.doUrlImport(); })
              }.width('100%').margin({ top: 12 })
            }
          }.width('100%').padding({ left: 8, right: 8, bottom: 24 })
            .backgroundColor(ThemeColors.surface(this.isDark))
            .borderRadius({ topLeft: 16, topRight: 16 })
        }.width('100%').height('100%')
          .backgroundColor(ThemeColors.strongScrim(this.isDark))
          .alignContent(Alignment.Bottom)
      }
    }.width('100%').height('100%')
  }

  @Builder
  actionButton(label: string, action: () => void) {
    Button(label).height(40).borderRadius(20).padding({ left: 14, right: 14 }).margin({ right: 6 })
      .backgroundColor(ThemeColors.surfaceVariant(this.isDark)).fontColor(ThemeColors.onSurface(this.isDark))
      .onClick(action)
  }

  @Builder
  sheetItem(label: string, action: () => void) {
    Text(label).fontSize(15).height(48).width('100%').padding({ left: 16, right: 16 })
      .fontColor(ThemeColors.onSurface(this.isDark))
      .onClick(action)
  }

  @Builder
  menuItem(label: string, danger: boolean, action: () => void) {
    Text(label).fontSize(14).height(44).width('100%').padding({ left: 16, right: 16 })
      .fontColor(danger ? ThemeColors.error(this.isDark) : ThemeColors.onSurface(this.isDark))
      .onClick(action)
  }

  @Builder
  ruleItem(rule: ReplaceRule) {
    Stack() {
      Row() {
        // Checkbox 常驻 DOM，通过 visibility 控制显隐，避免选择模式切换时大量组件创建/销毁
        Checkbox({ name: 'rr_' + rule.id, group: 'replace_rules' }).select(this.isSelected(rule.id))
          .selectedColor(ThemeColors.primary(this.isDark)).margin({ right: 10 })
          .visibility(this.isSelectMode_ ? Visibility.Visible : Visibility.Hidden)
          .onChange((selected: boolean) => { this.setSelected(rule.id, selected); })
        Column() {
          Row() {
            Text(rule.name || '未命名规则').fontSize(16).fontWeight(FontWeight.Medium)
              .fontColor(ThemeColors.onSurface(this.isDark)).layoutWeight(1)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Toggle({ type: ToggleType.Switch, isOn: this.isRuleEnabled(rule) })
              .onChange(async (enabled: boolean) => {
                await this.dao_?.updateEnabled(rule.id, enabled);
                rule.isEnabled = enabled;
                this.enabledStateVersion_++;
              })
              .visibility(this.isSelectMode_ ? Visibility.None : Visibility.Visible)
          }.width('100%')
          Text(rule.pattern).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%').margin({ top: 3 })
          Row() {
            if (rule.group) {
              Text(rule.group).fontSize(11).fontColor(ThemeColors.primary(this.isDark)).maxLines(1)
            }
            Text(rule.isRegex ? '正则' : '普通文本').fontSize(11)
              .fontColor(ThemeColors.secondaryText(this.isDark)).margin({ left: rule.group ? 10 : 0 })
            if (rule.scopeTitle) {
              Text('作用于标题').fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ left: 10 })
            }
            if (rule.scope) {
              Text('范围限定').fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ left: 10 })
            }
          }.width('100%').margin({ top: 6 })
        }.layoutWeight(1).onClick(() => {
          if (this.suppressClick_) return;
          if (this.isSelectMode_) this.toggleSelect(rule.id);
          else this.openEdit(rule);
        })
        Button('⋮').fontSize(22).width(40).height(40).backgroundColor(ThemeColors.transparent())
          .fontColor(ThemeColors.secondaryText(this.isDark))
          .visibility(this.isSelectMode_ ? Visibility.None : Visibility.Visible)
          .accessibilityText('更多操作')
          .onClick(() => { this.contextMenuId = this.contextMenuId === rule.id ? 0 : rule.id; })
      }.width('100%').padding({ left: 12, right: 6, top: 12, bottom: 12 })
        .borderRadius(16)
        .backgroundColor(this.isSelected(rule.id) ? ThemeColors.surfaceVariant(this.isDark) : ThemeColors.surface(this.isDark))
        .gesture(LongPressGesture().onAction(() => {
          if (!this.isSelectMode_) this.enterSelectMode(rule.id);
          else this.toggleSelect(rule.id);
        }))

      if (this.contextMenuId === rule.id) {
        Column() {
          this.menuItem('编辑', false, () => { this.contextMenuId = 0; this.openEdit(rule); })
          this.menuItem('置顶', false, () => { this.moveToEdge(rule, true); })
          this.menuItem('置底', false, () => { this.moveToEdge(rule, false); })
          this.menuItem('删除', true, () => { this.confirmDelete([rule]); })
        }.width(136).padding({ top: 4, bottom: 4 }).borderRadius(16)
          .backgroundColor(ThemeColors.surface(this.isDark)).shadow({ radius: 12, color: ThemeColors.scrim(this.isDark) })
          .position({ right: 12, top: 48 }).zIndex(120)
      }
    }.width('100%')
  }
}
