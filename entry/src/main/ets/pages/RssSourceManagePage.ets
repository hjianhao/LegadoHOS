/**
 * RSS 源管理页
 * 对应 Android RssSourceScreen — 管理所有 RSS 订阅源
 * 功能：列表、搜索、筛选、导入导出、批量操作
 */
import { AppDatabase } from '../data/database/AppDatabase';
import { RSSSource } from '../model/RSSSource';
import { AppTheme } from '../theme/AppTheme';
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import http from '@ohos.net.http';

// ArkTS 兼容的浅拷贝
function copyUiState(prev: ManageUiState, overrides: Partial<ManageUiState>): ManageUiState {
  return {
    items: overrides.items !== undefined ? overrides.items : prev.items,
    groups: overrides.groups !== undefined ? overrides.groups : prev.groups,
    searchKey: overrides.searchKey !== undefined ? overrides.searchKey : prev.searchKey,
    isSearch: overrides.isSearch !== undefined ? overrides.isSearch : prev.isSearch,
    filterMode: overrides.filterMode !== undefined ? overrides.filterMode : prev.filterMode,
    selectedIds: overrides.selectedIds !== undefined ? overrides.selectedIds : prev.selectedIds,
    isLoading: overrides.isLoading !== undefined ? overrides.isLoading : prev.isLoading,
  };
}

// JSON 导入数据辅助类型
type JsonValue = string | number | boolean | null;

function jsGetStr(obj: Record<string, JsonValue>, key: string, def: string): string {
  const v = obj[key];
  if (v === null || v === undefined) return def;
  return String(v);
}

function jsGetBool(obj: Record<string, JsonValue>, key: string, def: boolean): boolean {
  const v = obj[key];
  if (v === null || v === undefined) return def;
  if (typeof v === 'boolean') return v;
  if (typeof v === 'number') return v !== 0;
  return def;
}

interface ManageUiState {
  items: RSSSource[];
  groups: string[];
  searchKey: string;
  isSearch: boolean;
  filterMode: string; // ''=全部, 'enabled', 'disabled', 'nologin', 'nogroup', 或分组名
  selectedIds: Set<string>;
  isLoading: boolean;
}

const KEY_PREFIX_GROUP = 'group:';

@Entry
@Component
export struct RssSourceManagePage {
  @StorageLink('isDark') isDark: boolean = false;
  @State uiState: ManageUiState = {
    items: [],
    groups: [],
    searchKey: '',
    isSearch: false,
    filterMode: '',
    selectedIds: new Set(),
    isLoading: true,
  };

  private db: AppDatabase = AppDatabase.getInstance();

  aboutToAppear() {
    this.loadAll();
  }

  async loadAll() {
    this.uiState = copyUiState(this.uiState, { isLoading: true });
    try {
      await this.db.waitForInit();
      const all = await this.db.rssSourceTable.getAll();
      const groups = await this.db.rssSourceTable.getAllGroups();
      this.uiState = copyUiState(this.uiState, {
        items: this.applyFilter(all),
        groups: groups,
        isLoading: false,
      });
    } catch (e) {
      console.error('[RssSourceManagePage] 加载失败: ' + e);
      this.uiState = copyUiState(this.uiState, { isLoading: false });
    }
  }

  applyFilter(sources: RSSSource[]): RSSSource[] {
    const mode = this.uiState.filterMode;
    const key = this.uiState.searchKey.toLowerCase();

    let filtered = sources;

    // 关键词过滤
    if (key) {
      filtered = filtered.filter(s =>
        s.sourceName.toLowerCase().includes(key) ||
        s.sourceUrl.toLowerCase().includes(key) ||
        (s.sourceGroup || '').toLowerCase().includes(key)
      );
    }

    // 模式过滤
    if (mode === 'enabled') return filtered.filter(s => s.enabled);
    if (mode === 'disabled') return filtered.filter(s => !s.enabled);
    if (mode === 'login') return filtered.filter(s => !!s.loginUrl);
    if (mode === 'nogroup') return filtered.filter(s => !s.sourceGroup);
    if (mode.startsWith(KEY_PREFIX_GROUP)) {
      const group = mode.substring(KEY_PREFIX_GROUP.length);
      return filtered.filter(s => (s.sourceGroup || '').includes(group));
    }

    return filtered;
  }

  async setFilterMode(mode: string) {
    this.uiState = copyUiState(this.uiState, { filterMode: mode });
    const all = await this.db.rssSourceTable.getAll();
    this.uiState = copyUiState(this.uiState, { items: this.applyFilter(all) });
  }

  async search(key: string) {
    this.uiState = copyUiState(this.uiState, { searchKey: key });
    const all = await this.db.rssSourceTable.getAll();
    this.uiState = copyUiState(this.uiState, { items: this.applyFilter(all) });
  }

  toggleSelect(sourceUrl: string) {
    const set = new Set(this.uiState.selectedIds);
    if (set.has(sourceUrl)) set.delete(sourceUrl);
    else set.add(sourceUrl);
    this.uiState = copyUiState(this.uiState, { selectedIds: set });
  }

  selectAll() {
    const set = new Set(this.uiState.items.map(s => s.sourceUrl));
    this.uiState = copyUiState(this.uiState, { selectedIds: set });
  }

  clearSelection() {
    this.uiState = copyUiState(this.uiState, { selectedIds: new Set() });
  }

  async deleteSource(sourceUrl: string) {
    try {
      await this.db.rssSourceTable.delete(sourceUrl);
      await this.db.rssArticleTable.delete(sourceUrl);
      promptAction.showToast({ message: '已删除' });
      this.loadAll();
    } catch (e) {
      promptAction.showToast({ message: `删除失败: ${e}` });
    }
  }

  async deleteSelected() {
    for (const url of this.uiState.selectedIds) {
      await this.db.rssSourceTable.delete(url);
      await this.db.rssArticleTable.delete(url);
    }
    promptAction.showToast({ message: `已删除 ${this.uiState.selectedIds.size} 个源` });
    this.uiState = copyUiState(this.uiState, { selectedIds: new Set() });
    this.loadAll();
  }

  async toggleEnabled(source: RSSSource) {
    await this.db.rssSourceTable.enable(source.sourceUrl, !source.enabled);
    this.loadAll();
  }

  async enableSelection(enable: boolean) {
    for (const url of this.uiState.selectedIds) {
      await this.db.rssSourceTable.enable(url, enable);
    }
    this.uiState = copyUiState(this.uiState, { selectedIds: new Set() });
    this.loadAll();
  }

  async topSource(source: RSSSource) {
    const min = await this.db.rssSourceTable.getMinOrder();
    await this.db.rssSourceTable.updateOrder(source.sourceUrl, min - 1);
    this.loadAll();
  }

  async bottomSource(source: RSSSource) {
    const max = await this.db.rssSourceTable.getMaxOrder();
    await this.db.rssSourceTable.updateOrder(source.sourceUrl, max + 1);
    this.loadAll();
  }

  openEdit(sourceUrl: string) {
    router.pushUrl({
      url: 'pages/RssSourceEditPage',
      params: { sourceUrl },
    });
  }

  openAdd() {
    router.pushUrl({ url: 'pages/RssSourceEditPage' });
  }

  importFromUrl() {
    AlertDialog.show({
      title: '导入订阅源',
      message: '粘贴 RSS 源 JSON 或输入远程 JSON URL',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {},
      },
      cancel: () => {},
    });
    // 让用户粘贴 JSON — 通过 promptAction 输入
    promptAction.showDialog({
      title: '导入订阅源',
      message: '输入 RSS 源 JSON（数组格式）或 URL',
      buttons: [
        { text: '取消', color: '#666666' },
        { text: '导入', color: '#0078D7' },
      ],
	    }).then(async (data) => {
	      if (data.index === 1) {
	        await this.doImport('');
	      }
	    });
  }

  async doImport(input: string) {
    try {
      let jsonText = input.trim();

      // 如果是 URL，尝试获取远程内容
      if (jsonText.startsWith('http://') || jsonText.startsWith('https://')) {
        try {
          const req = http.createHttp();
          const resp = await req.request(jsonText, {
            method: http.RequestMethod.GET,
            header: { 'User-Agent': 'Mozilla/5.0' },
            connectTimeout: 10000,
            readTimeout: 10000,
            expectDataType: http.HttpDataType.STRING,
          });
          jsonText = String(resp.result);
          req.destroy();
        } catch (e) {
          promptAction.showToast({ message: `获取远程 JSON 失败: ${e}` });
          return;
        }
      }

      // 解析 JSON
      const parsedSources: Record<string, JsonValue>[] = [];
      try {
        const parsed = JSON.parse(jsonText) as Object;
        if (Array.isArray(parsed)) {
          for (let i = 0; i < parsed.length; i++) {
            parsedSources.push(parsed[i] as Record<string, JsonValue>);
          }
        } else if ((parsed as Record<string, JsonValue>)['sourceUrl']) {
          parsedSources.push(parsed as Record<string, JsonValue>);
        } else {
          promptAction.showToast({ message: 'JSON 格式无效，需要 RSS 源数组或对象' });
          return;
        }
      } catch (e) {
        // 尝试作为单 URL 导入 — 直接用输入 URL 创建一个源
        if (input.startsWith('http://') || input.startsWith('https://')) {
          const singleSource: Record<string, JsonValue> = {
            'sourceUrl': input,
            'sourceName': input.split('/').pop() || input,
            'enabled': true,
          };
          parsedSources.push(singleSource);
        } else {
          promptAction.showToast({ message: 'JSON 解析失败，请检查格式' });
          return;
        }
      }

      // 导入每个源
      let successCount = 0;
      let skipCount = 0;
      for (let si = 0; si < parsedSources.length; si++) {
        const s = parsedSources[si];
        try {
          const srcUrl = jsGetStr(s, 'sourceUrl', '') || jsGetStr(s, 'source_url', '');
          const exists = await this.db.rssSourceTable.has(srcUrl);
          if (exists) {
            skipCount++;
            continue;
          }

          const source: RSSSource = {
            sourceUrl: srcUrl,
            sourceName: jsGetStr(s, 'sourceName', '未命名') || jsGetStr(s, 'source_name', '未命名'),
            sourceIcon: jsGetStr(s, 'sourceIcon', '') || jsGetStr(s, 'source_icon', ''),
            sourceGroup: jsGetStr(s, 'sourceGroup', '') || jsGetStr(s, 'source_group', '') || null,
            sourceComment: jsGetStr(s, 'sourceComment', '') || jsGetStr(s, 'source_comment', '') || null,
            enabled: jsGetBool(s, 'enabled', true),
            variableComment: jsGetStr(s, 'variableComment', '') || null,
            jsLib: jsGetStr(s, 'jsLib', '') || null,
            enabledCookieJar: jsGetBool(s, 'enabledCookieJar', true),
            concurrentRate: jsGetStr(s, 'concurrentRate', '') || null,
            header: jsGetStr(s, 'header', '') || null,
            loginUrl: jsGetStr(s, 'loginUrl', '') || null,
            loginUi: jsGetStr(s, 'loginUi', '') || null,
            loginCheckJs: jsGetStr(s, 'loginCheckJs', '') || null,
            coverDecodeJs: jsGetStr(s, 'coverDecodeJs', '') || null,
            sortUrl: jsGetStr(s, 'sortUrl', '') || null,
            singleUrl: jsGetBool(s, 'singleUrl', false),
            articleStyle: Number(jsGetStr(s, 'articleStyle', '0')) || 0,
            ruleArticles: jsGetStr(s, 'ruleArticles', ''),
            ruleNextPage: jsGetStr(s, 'ruleNextPage', ''),
            ruleTitle: jsGetStr(s, 'ruleTitle', ''),
            rulePubDate: jsGetStr(s, 'rulePubDate', ''),
            ruleDescription: jsGetStr(s, 'ruleDescription', ''),
            ruleImage: jsGetStr(s, 'ruleImage', ''),
            ruleLink: jsGetStr(s, 'ruleLink', ''),
            ruleContent: jsGetStr(s, 'ruleContent', ''),
            contentWhitelist: jsGetStr(s, 'contentWhitelist', '') || null,
            contentBlacklist: jsGetStr(s, 'contentBlacklist', '') || null,
            shouldOverrideUrlLoading: jsGetStr(s, 'shouldOverrideUrlLoading', '') || null,
            style: jsGetStr(s, 'style', '') || null,
            enableJs: jsGetBool(s, 'enableJs', true),
            loadWithBaseUrl: jsGetBool(s, 'loadWithBaseUrl', true),
            injectJs: jsGetStr(s, 'injectJs', '') || null,
            preloadJs: jsGetStr(s, 'preloadJs', '') || null,
            startHtml: jsGetStr(s, 'startHtml', '') || null,
            startStyle: jsGetStr(s, 'startStyle', '') || null,
            startJs: jsGetStr(s, 'startJs', '') || null,
            showWebLog: jsGetBool(s, 'showWebLog', false),
            lastUpdateTime: Date.now(),
            customOrder: 0,
            type: Number(jsGetStr(s, 'type', '0')) || 0,
            preload: jsGetBool(s, 'preload', false),
            cacheFirst: jsGetBool(s, 'cacheFirst', false),
            searchUrl: jsGetStr(s, 'searchUrl', '') || null,
            redirectPolicy: jsGetStr(s, 'redirectPolicy', 'ASK_CROSS_ORIGIN'),
          };
          await this.db.rssSourceTable.insert(source);
          successCount++;
        } catch (_e) {
          skipCount++;
        }
      }

      const msg = `导入完成: ${successCount} 个成功, ${skipCount} 个跳过`;
      promptAction.showToast({ message: msg });
      this.loadAll();
    } catch (e) {
      promptAction.showToast({ message: `导入失败: ${e instanceof Error ? e.message : String(e)}` });
    }
  }

  showFilterPicker() {
    // 简化 — 用 AlertDialog 显示筛选选项
    const msg = '当前模式: ' + (() => {
      switch (this.uiState.filterMode) {
        case 'enabled': return '已启用';
        case 'disabled': return '已禁用';
        case 'login': return '需登录';
        case 'nogroup': return '未分组';
        case '': return '全部';
        default: return this.uiState.filterMode.startsWith(KEY_PREFIX_GROUP)
          ? '分组: ' + this.uiState.filterMode.substring(KEY_PREFIX_GROUP.length)
          : this.uiState.filterMode;
      }
    })();
    AlertDialog.show({
      title: '筛选',
      message: msg + '\n可用分组: ' + (this.uiState.groups.length > 0 ? this.uiState.groups.join(', ') : '无'),
      autoCancel: true,
      primaryButton: { value: '全部', action: () => this.setFilterMode('') },
      secondaryButton: { value: '已启用', action: () => this.setFilterMode('enabled') },
      cancel: () => {},
    });
  }

  build() {
    Column() {
      // ===== 顶部栏 =====
      Row() {
        Text('←').fontSize(22).fontColor('#0078D7')
          .onClick(() => router.back())
        Text('RSS 源管理').fontSize(18).fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#E0E0E0' : '#1A1A1A')
          .margin({ left: 8 })
        Blank()
        Button({ type: ButtonType.Normal }) {
          Text('筛选').fontSize(13).fontColor('#0078D7')
        }
        .backgroundColor('transparent').margin({ right: 4 })
        .onClick(() => this.showFilterPicker())
        Button({ type: ButtonType.Normal }) {
          Text('导入').fontSize(13).fontColor('#0078D7')
        }
        .backgroundColor('transparent').margin({ right: 4 })
        .onClick(() => this.importFromUrl())
        Button({ type: ButtonType.Normal }) {
          Text('添加').fontSize(14).fontColor('#0078D7').fontWeight(FontWeight.Bold)
        }
        .backgroundColor('transparent')
        .onClick(() => this.openAdd())
      }
      .width('100%').padding({ left: 8, right: 8, top: 8, bottom: 4 })

      // ===== 搜索栏 =====
      Search({ placeholder: '搜索订阅源...', value: this.uiState.searchKey })
        .onSubmit((val) => this.search(val))
        .onChange((val) => { if (!val) this.search(''); })
        .width('100%').padding({ left: 12, right: 12, bottom: 8 })

      // ===== 选中操作栏 =====
      if (this.uiState.selectedIds.size > 0) {
        Row() {
          Text(`已选 ${this.uiState.selectedIds.size} 项`)
            .fontSize(13).fontColor('#0078D7')
          Blank()
          Button({ type: ButtonType.Normal }) {
            Text('启用').fontSize(13).fontColor('#4CAF50')
          }.backgroundColor('transparent')
          .onClick(() => this.enableSelection(true))
          Button({ type: ButtonType.Normal }) {
            Text('禁用').fontSize(13).fontColor('#F44336')
          }.backgroundColor('transparent')
          .onClick(() => this.enableSelection(false))
          Button({ type: ButtonType.Normal }) {
            Text('删除').fontSize(13).fontColor('#F44336')
          }.backgroundColor('transparent')
          .onClick(() => this.deleteSelected())
        }
        .width('100%').padding({ left: 12, right: 12, bottom: 4 })
      }

      if (this.uiState.isLoading) {
        LoadingProgress().color('#0078D7')
      } else if (this.uiState.items.length === 0) {
        Column() {
          Text('暂无 RSS 源').fontSize(14).fontColor(this.isDark ? '#AAA' : '#888')
          Text('点击右上角「添加」新增 RSS 源')
            .fontSize(12).fontColor(this.isDark ? '#888' : '#AAA').margin({ top: 8 })
        }
        .width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      } else {
        Scroll() {
          Column() {
            ForEach(this.uiState.items, (source: RSSSource) => {
              Row() {
                // 选择框
                Toggle({ type: ToggleType.Checkbox, isOn: this.uiState.selectedIds.has(source.sourceUrl) })
                  .onChange(() => this.toggleSelect(source.sourceUrl))

                Column() {
                  Text(source.sourceName).fontSize(15)
                    .fontColor(this.isDark ? '#E0E0E0' : '#333')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(source.sourceUrl).fontSize(11)
                    .fontColor(this.isDark ? '#888' : '#AAA')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 2 })
                  Row() {
                    if (source.sourceGroup) {
                      Text(source.sourceGroup).fontSize(10).fontColor('#0078D7')
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                        .border({ radius: 4 }).borderColor('#0078D7').borderWidth(0.5)
                    }
                    if (!source.enabled) {
                      Text('已禁用').fontSize(10).fontColor('#F44336')
                        .margin({ left: 6 })
                    }
                  }
                  .margin({ top: 4 })
                }
                .layoutWeight(1).alignItems(HorizontalAlign.Start).margin({ left: 8 })

                // 操作按钮
                Button({ type: ButtonType.Normal }) {
                  Text('编辑').fontSize(12).fontColor('#0078D7')
                }
                .backgroundColor('transparent').margin({ right: 4 })
                .onClick(() => this.openEdit(source.sourceUrl))
                Button({ type: ButtonType.Normal }) {
                  Text('删除').fontSize(12).fontColor('#F44336')
                }
                .backgroundColor('transparent')
                .onClick(() => {
                  this.onDeleteClick(source.sourceUrl);
                })
              }
              .padding(12)
              .borderRadius(8)
              .backgroundColor(this.isDark ? '#1E1E1E' : '#FFFFFF')
              .margin({ left: 12, right: 12, top: 4, bottom: 4 })
              .width('100%')
            })
          }
          .width('100%')
        }
        .layoutWeight(1)
      }
    }
    .width('100%').height('100%')
    .backgroundColor(this.isDark ? '#121212' : '#F5F5F5')
  }

  private onDeleteClick(source: string): void {
    AlertDialog.show({
      title: '删除确认',
      message: '确定要删除此 RSS 源？相关文章也将被删除。',
      primaryButton: {
        value: '取消',
        action: () => { },
      },
      secondaryButton: {
        value: '删除',
        action: async () => {
          await this.deleteSource(source);
        },
      },
      cancel: () => { }
    });
  }
}
