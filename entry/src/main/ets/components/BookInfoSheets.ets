/**
 * BookInfo 底部弹出面板组件
 *
 * 参考 legado-with-MD3 架构：
 *   ChangeBookSourceComposeViewModel  + ChangeSourceSearchUseCase + BookInfoSheets.kt
 *
 * 核心逻辑（对齐 Legado）：
 *   1. 优先使用 ExplorePage 搜索结果（通过 router params 传入的 sourceUrls/sourceNoteUrls）
 *      —— 这相当于 Legado 中的 searchBookDao 缓存
 *   2. 只有源数组为空时才触发网络搜索
 *   3. 搜索并发数从 AppStorage('searchConcurrency') 读取（默认 16），与 ExplorePage 一致
 *
 * 使用 CustomDialog + DialogAlignment.Bottom 模拟 BottomSheet 效果
 */
import { BookSource, BookSourceChapter } from '../model/BookSource';
import { SearchResult } from '../model/SearchResult';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { Book, BookType, BookGroup } from '../model/Book';
import promptAction from '@ohos.promptAction';
import { NetUtil } from '../util/NetUtil';
import { BookTable } from '../data/database/BookTable';
import { BookGroupTable } from '../data/database/BookGroupTable';
import { ReadRecordTable } from '../data/database/ReadRecordTable';
import { UiUtil } from '../util/UiUtil';
import { ThemeColors } from '../theme/ThemeColors';

/** 每日阅读记录数据结构 */
interface SessionInfo {
  time: string;
  dur: number;
}

interface RecordDayInfo {
  date: string;
  totalMinutes: number;
  sessions: SessionInfo[];
}

// =====================================================================
// ChangeCoverSheet — 换封面弹窗
// =====================================================================
@CustomDialog
export struct ChangeCoverSheet {
  controller: CustomDialogController;
  bookName: string = '';
  bookAuthor: string = '';
  @State coverResults: SearchResult[] = [];
  @State isSearching: boolean = false;
  onSelect?: (coverUrl: string) => void;

  aboutToAppear(): void {
    this.searchCovers();
  }

  async searchCovers(): Promise<void> {
    this.isSearching = true;
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const dao = new BookSourceTable(db);
      const sources = await dao.getEnabledSources();
      const enabled: BookSource[] = [];
      for (const s of sources) {
        if (s.enabled && s.ruleSearchUrl) {
          enabled.push(s);
        }
      }
      const keyword = this.bookName + ' ' + this.bookAuthor;
      const results = await globalSourceExecutor.search(keyword, enabled.slice(0, 8));
      this.coverResults = results.filter(r => r.coverUrl);
    } catch (_e) {
      /* ignore */
    }
    this.isSearching = false;
  }

  build() {
    Column() {
      Row() {
        Text('更换封面').fontSize(16).fontWeight(FontWeight.Bold)
        Blank()
        Button() { Text('✕').fontSize(16).fontColor('#666') }
          .width(32).height(32).backgroundColor('transparent')
          .onClick(() => { this.controller.close(); })
      }
      .width('100%').padding({ left: 16, right: 8, top: 16, bottom: 8 })

      if (this.isSearching) {
        LoadingProgress().width(40).height(40).margin({ top: 20 })
        Text('搜索封面中...').fontSize(13).fontColor('#999').margin({ top: 8, bottom: 20 })
      } else if (this.coverResults.length === 0) {
        Text('未找到封面').fontSize(13).fontColor('#999').margin(20)
      } else {
        Text('已找到 ' + this.coverResults.length + ' 个封面').fontSize(12).fontColor('#999').padding(8)
      }

      if (this.coverResults.length > 0) {
        Grid() {
          ForEach(this.coverResults, (item: SearchResult) => {
            GridItem() {
              Column() {
                Image(item.coverUrl)
                  .width('100%').aspectRatio(5 / 7)
                  .objectFit(ImageFit.Cover).borderRadius(4)
                Text(item.origin).fontSize(10).fontColor('#999').maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 4 })
              }
              .width('100%').padding(4)
              .onClick(() => {
                if (this.onSelect && item.coverUrl) this.onSelect(item.coverUrl);
                this.controller.close();
              })
            }
          })
        }
        .columnsTemplate('1fr 1fr 1fr')
        .columnsGap(8).rowsGap(8)
        .width('100%').padding({ left: 12, right: 12, bottom: 24 })
        .layoutWeight(1)
      }
    }
    .width('100%').height(420)
    .backgroundColor('#FFFFFF')
    .borderRadius({ topLeft: 16, topRight: 16 })
  }
}

// =====================================================================
// ChangeSourceSheet — 换源面板（核心）
// 对齐 Legado ChangeBookSourceComposeViewModel 逻辑：
//   initData → getDbSearchBooks() → 有→展示, 空→startSearch()
// =====================================================================
@CustomDialog
export struct ChangeSourceSheet {
  controller: CustomDialogController;
  @StorageLink('isDark') isDark: boolean = false;
  bookName: string = '';
  bookAuthor: string = '';
  currentOriginUrl: string = '';
  /** 单章换源模式：仅改变标题提示与点击行为（直接回调，不弹"作为新书"选项） */
  singleChapterMode: boolean = false;
  /** 是否允许"作为新书加入书架"（阅读页关闭） */
  allowAddAsNew: boolean = true;
  @State keyword: string = '';
  @State results: SearchResult[] = [];
  @State isSearching: boolean = false;
  @State searchProgress: string = '';
  /** 对齐 Legado "校验作者" 开关 */
  @State checkAuthor: boolean = true;
  onReplace?: (result: SearchResult) => void;
  onAddAsNew?: (result: SearchResult) => void;

  // ====== 对齐 Legado：缓存数据 ======
  /**
   * 从搜索结果页传入的已知源数组（相当于 Legado searchBookDao 缓存）。
   * 格式：[{origin, originUrl, noteUrl}, ...]
   * 为空时走网络搜索。
   */
  cachedSources: SearchResult[] = [];

  // 内部状态：是否已完成初始化
  private initialized: boolean = false;
  // 搜索去重用（对齐 Legado searchJob?.cancel()）
  private searching: boolean = false;

  aboutToAppear(): void {
    if (this.initialized) return;
    this.initialized = true;
    this.keyword = this.bookName;
    // 对齐 Legado ChangeBookSourceComposeViewModel.initData():
    // 1) getDbSearchBooks() → 展示缓存
    // 2) 缓存空 → startSearch()
    if (this.cachedSources.length > 0) {
      this.showCachedSources();
    } else {
      this.searchSources();
    }
  }

  /**
   * 对齐 Legado getDbSearchBooks() — 从缓存中筛选精确匹配的源
   * 过滤逻辑与 ChangeBookSourceComposeViewModel.initData → getDbSearchBooks 一致：
   *   fName == name && (!checkAuthor || fAuthor.contains(author))
   */
  showCachedSources(): void {
    const targetName = this.bookName.replace(/\s/g, '');
    const targetAuthor = this.bookAuthor.replace(/\s/g, '');
    const expandedSources = this.expandCachedSources(this.cachedSources);
    // 只保留精确匹配书名 + 可选匹配作者的源
    const matched = expandedSources.filter((r: SearchResult) => {
      const rname = (r.name || '').replace(/\s/g, '');
      if (rname !== targetName) return false;
      // 对齐 Legado: !checkAuthor || fAuthor.contains(author)
      if (this.checkAuthor && targetAuthor) {
        const rauthor = (r.author || '').replace(/\s/g, '');
        if (rauthor && !rauthor.includes(targetAuthor) && !targetAuthor.includes(rauthor)) return false;
      }
      return true;
    });
    this.results = matched.sort((a: SearchResult, b: SearchResult) => {
      let sa = 0;
      let sb = 0;
      if (a.originUrl === this.currentOriginUrl) sa -= 1000;
      if (b.originUrl === this.currentOriginUrl) sb -= 1000;
      return sb - sa;
    });
    // 缓存中没有精确匹配结果时回退到网络搜索
    if (this.results.length === 0) {
      this.cachedSources = [];
      this.searchSources();
    }
  }

  /**
   * 搜索页展示的是合并后的书籍结果，一条结果可能包含多个源。
   * 换源面板需要还原成逐源列表，否则 sourceCount=2 的搜索结果进入详情后只会显示第一源。
   */
  private expandCachedSources(sources: SearchResult[]): SearchResult[] {
    const expanded: SearchResult[] = [];
    for (const item of sources) {
      const origins = item.sourceOrigins || [];
      const originUrls = item.sourceOriginUrls || [];
      const noteUrls = item.sourceNoteUrls || [];
      const maxLen = Math.max(origins.length, originUrls.length, noteUrls.length);
      if (maxLen <= 1) {
        expanded.push(item);
        continue;
      }
      for (let i = 0; i < maxLen; i++) {
        const origin = origins[i] || item.origin || '';
        const originUrl = originUrls[i] || (origin === item.origin ? item.originUrl : '');
        const noteUrl = noteUrls[i] || (originUrl === item.originUrl ? item.noteUrl : '');
        if (!originUrl && !noteUrl) continue;
        expanded.push({
          key: (originUrl || item.originUrl || '') + '|' + (noteUrl || item.noteUrl || ''),
          name: item.name,
          author: item.author,
          coverUrl: item.coverUrl,
          noteUrl: noteUrl || item.noteUrl,
          origin: origin || item.origin,
          originUrl: originUrl || item.originUrl,
          kind: item.kind,
          wordCount: item.wordCount,
          lastUpdateTime: item.lastUpdateTime,
          latestChapterTitle: item.latestChapterTitle,
          introduce: item.introduce,
          helperMsg: item.helperMsg,
          duration: item.duration,
          searchTime: item.searchTime,
          sourceCount: 1,
          sourceOrigins: [origin || item.origin],
          sourceOriginUrls: [originUrl || item.originUrl],
          sourceNoteUrls: [noteUrl || item.noteUrl],
        });
      }
    }
    return expanded;
  }

  /** 对齐 Legado startSearch() — 网络搜索 */
  async searchSources(): Promise<void> {
    if (!this.keyword.trim()) return;
    // 对齐 Legado searchJob?.cancel() — 取消前一次搜索
    this.searching = true;
    this.isSearching = true;
    this.results = [];

    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const dao = new BookSourceTable(db);
      const sources = await dao.getEnabledSources();
      const enabled: BookSource[] = [];
      for (const s of sources) {
        if (s.enabled && s.ruleSearchUrl) {
          enabled.push(s);
        }
      }
      if (enabled.length === 0) {
        UiUtil.showToast(this.getUIContext(), { message: '没有启用的书源，请先导入书源', duration: 2000 });
        this.isSearching = false;
        return;
      }

	      // 对齐 Legado ChangeSourceSearchUseCase: flatMapMerge(concurrency)
	      // ArkTS 没有 Flow，但我们用全局单例 SourceExecutor 自带的并发池
	      // 进度回调对齐 Legado ChangeSourceSearchEvent.Progress
	      const rawResults = await globalSourceExecutor.search(
	        this.keyword.trim(), enabled,
	        (merged: SearchResult[], processed: number, total: number) => {
	          // 检查是否已取消
	          if (!this.searching) return;
	          this.searchProgress = '已搜 ' + processed + '/' + total + ' 个源，找到 ' + merged.length + ' 条';
          this.rawResults_ = merged;
	          // 增量更新结果列表：筛选 + 展开逐源展示
	          const filtered = this.filterResults(merged);
	          if (filtered.length > 0) {
	            this.results = this.expandCachedSources(filtered).sort((a: SearchResult, b: SearchResult) => {
	              let sa = 0;
	              let sb = 0;
	              if (a.originUrl === this.currentOriginUrl) sa -= 1000;
	              if (b.originUrl === this.currentOriginUrl) sb -= 1000;
	              const na = (a.name || '').replace(/\s/g, '');
	              const nb = (b.name || '').replace(/\s/g, '');
	              const bn = this.bookName.replace(/\s/g, '');
	              if (na === bn) sa += 50;
	              if (nb === bn) sb += 50;
	              sa += (a.sourceCount || 1);
	              sb += (b.sourceCount || 1);
	              return sb - sa;
	            });
	          }
	        },
	        1,
	        // 关闭面板时真正取消底层搜索任务（对齐 Legado searchJob?.cancel()）
	        () => !this.searching
	      );

      // 对齐 Legado：搜索结果中只保留同书名/同作者的
      const filtered = this.filterResults(rawResults);
      this.rawResults_ = rawResults;

      // 展开合并结果：一条 SearchResult 可能包含多个源（sourceOrigins），换源面板需要逐源展示
      this.results = this.expandCachedSources(filtered).sort((a: SearchResult, b: SearchResult) => {
        let sa = 0;
        let sb = 0;
        if (a.originUrl === this.currentOriginUrl) sa -= 1000;
        if (b.originUrl === this.currentOriginUrl) sb -= 1000;
        const na = (a.name || '').replace(/\s/g, '');
        const nb = (b.name || '').replace(/\s/g, '');
        const bn = this.bookName.replace(/\s/g, '');
        if (na === bn) sa += 50;
        if (nb === bn) sb += 50;
        // 来源多的排前面
        sa += (a.sourceCount || 1);
        sb += (b.sourceCount || 1);
        return sb - sa;
      });
    } catch (err) {
      console.error('[ChangeSrc] searchSources failed:', (err as Error).message);
    }
    this.isSearching = false;
    this.searchProgress = '';
  }

  /**
   * 对齐 Legado ChangeSourceSearchUseCase.searchSource() 的过滤逻辑:
   *   fName == name && (!checkAuthor || fAuthor.contains(author))
   */
  private filterResults(raw: SearchResult[]): SearchResult[] {
    const targetName = this.bookName.replace(/\s/g, '');
    if (!targetName) return raw;
    const targetAuthor = this.bookAuthor.replace(/\s/g, '');
    return raw.filter(r => {
      const rname = (r.name || '').replace(/\s/g, '');
      if (!rname) return false;
      // 放宽匹配：精确匹配 + 互相包含（含最小长度门限），防止残缺书名被误匹配
      let nameMatched = false;
      if (rname === targetName) {
        nameMatched = true;
      } else if (rname.includes(targetName)) {
        // rname 完全包含 targetName（搜索结果书名包含完整的目标书名）
        nameMatched = true;
      } else if (targetName.includes(rname)) {
        // targetName 包含 rname：仅当 rname 长度 ≥ 4 个非英文且 ≥ targetName 的 80% 才通过
        const cnLen = (s: string): number => s.replace(/[a-zA-Z0-9]/g, '').length;
        const rl = cnLen(rname);
        const tl = cnLen(targetName);
        if (rl >= 4 && rl >= tl * 0.8) nameMatched = true;
      }
      if (!nameMatched) {
        // 去核心分隔符后的精确匹配
        const rcore = rname.replace(/[的之·•\-—\s（(）)]/g, '');
        const tcore = targetName.replace(/[的之·•\-—\s（(）)]/g, '');
        nameMatched = rcore === tcore;
      }
      if (!nameMatched) return false;
      // 校验作者（对齐 Legado checkAuthor 开关）；结果无作者信息时保留
      if (this.checkAuthor && targetAuthor) {
        const rauthor = (r.author || '').replace(/\s/g, '');
        if (rauthor && !rauthor.includes(targetAuthor) && !targetAuthor.includes(rauthor)) return false;
      }
      return true;
    });
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Text(this.singleChapterMode ? '单章换源' : '更换书源').fontSize(16).fontWeight(FontWeight.Bold)
        Blank()
        Button() { Text('✕').fontSize(16).fontColor('#666') }
          .width(32).height(32).backgroundColor('transparent')
          .onClick(() => {
            this.searching = false; // 对齐 Legado: dispose 时 stopSearch
            this.controller.close();
          })
      }
      .width('100%').padding({ left: 16, right: 8, top: 16, bottom: 8 })

      // 搜索栏 + 刷新按钮
      Row() {
        TextInput({ text: this.keyword, placeholder: '搜索书名' })
          .layoutWeight(1).height(36).fontSize(13)
          .borderRadius(18).backgroundColor('#F5F5F5')
          .padding({ left: 12, right: 12 })
          .onChange((value: string) => { this.keyword = value; })
        Button('搜索').fontSize(13).height(36).width(56).margin({ left: 8 })
          .backgroundColor('#0078D7').fontColor('#FFF').borderRadius(18)
          .onClick(() => { this.searchSources(); })
        Button('刷新').fontSize(13).height(36).width(56).margin({ left: 4 })
          .backgroundColor(ThemeColors.outlineVariant(this.isDark))
          .fontColor(ThemeColors.onBackground(this.isDark)).borderRadius(18)
          .onClick(() => { this.cachedSources = []; this.searchSources(); })
      }
      .width('100%').padding({ left: 16, right: 16, bottom: 4 })

      // 校验作者开关（对齐 Legado checkAuthor）
      Row() {
        Text('校验作者').fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
        Toggle({ type: ToggleType.Checkbox, isOn: this.checkAuthor })
          .selectedColor('#0078D7')
          .margin({ left: 6 })
          .onChange((isOn: boolean) => {
            this.checkAuthor = isOn;
            // 已有结果按新开关重新过滤
            if (this.cachedSources.length > 0) {
              this.showCachedSources();
            } else if (this.rawResults_.length > 0) {
              this.results = this.sortResults_(this.expandCachedSources(this.filterResults(this.rawResults_)));
            }
          })
      }
      .width('100%').padding({ left: 16, right: 16, bottom: 4 })

      // 进度提示
      if (this.searchProgress) {
        Text(this.searchProgress).fontSize(11).fontColor('#999')
          .width('100%').padding({ left: 16, right: 16, bottom: 4 })
      }

	      // 结果列表（点击行直接替换源）
	      if (this.isSearching && this.results.length === 0) {
	        Column() {
	          LoadingProgress().width(40).height(40).margin({ top: 30 })
	          Text('搜索中...').fontSize(13).fontColor('#999').margin({ top: 8 })
	        }.width('100%').layoutWeight(1)
	      } else if (this.results.length === 0) {
        Column() {
          Text('没有找到其他书源').fontSize(14).fontColor('#999').margin({ top: 30 })
          Text('试试修改搜索词或点击刷新').fontSize(12).fontColor('#CCC').margin({ top: 4 })
        }.width('100%').layoutWeight(1)
      } else {
        List() {
          ForEach(this.results, (item: SearchResult) => {
            ListItem() {
              Row() {
                // 当前源标识（前置）
                if (item.originUrl === this.currentOriginUrl) {
                  Text('✓').fontSize(14).fontColor('#4CAF50').fontWeight(FontWeight.Bold)
                    .margin({ right: 6 })
                }
                Column() {
                  Row() {
                    Text(item.name || '未知').fontSize(14).fontWeight(FontWeight.Medium)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    if (item.originUrl === this.currentOriginUrl) {
                      Text('当前').fontSize(10).fontColor('#4CAF50').margin({ left: 6 })
                        .backgroundColor('#E8F5E9').borderRadius(4).padding({ left: 4, right: 4 })
                    }
                  }.alignItems(VerticalAlign.Center)
                  Text(item.author || '').fontSize(12).fontColor('#888')
                    .maxLines(1).margin({ top: 2 })
                  Row() {
                    Text(item.origin || '未知').fontSize(11)
                      .fontColor(item.originUrl === this.currentOriginUrl ? '#4CAF50' : '#0078D7')
                      .maxLines(1)
                    if (item.wordCount) {
                      Text(' · ' + item.wordCount).fontSize(11).fontColor('#AAA')
                    }
                  }.margin({ top: 2 })
                }
                .layoutWeight(1).alignItems(HorizontalAlign.Start)
              }
              .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
            }
            .border({ width: { bottom: 0.5 }, color: '#EEEEEE' })
            .onClick(() => { this.onResultClick_(item); })
          })
        }
        .layoutWeight(1).width('100%')
      }
    }
    .width('100%').height('70%')
    .backgroundColor(ThemeColors.surface(this.isDark))
    .borderRadius({ topLeft: 16, topRight: 16 })
  }

  /** 网络搜索的原始结果（用于"校验作者"开关切换后本地重过滤） */
  private rawResults_: SearchResult[] = [];

  /** 点击候选源：对齐 Legado —— 可选择替换当前书籍或作为新书添加 */
  private onResultClick_(item: SearchResult): void {
    if (this.singleChapterMode || !this.allowAddAsNew) {
      this.confirmReplace_(item);
      return;
    }
    ActionSheet.show({
      title: item.name || '',
      message: (item.origin || '') + (item.author ? ' · ' + item.author : ''),
      sheets: [
        {
          title: '替换当前书籍',
          action: () => { this.confirmReplace_(item); }
        },
        {
          title: '作为新书加入书架',
          action: () => {
            if (this.onAddAsNew) this.onAddAsNew(item);
            this.searching = false;
            this.controller.close();
          }
        },
      ]
    });
  }

  private confirmReplace_(item: SearchResult): void {
    if (this.onReplace) this.onReplace(item);
    this.searching = false;
    this.controller.close();
  }

  /** 候选源排序：当前源置底，书名精确匹配与多来源优先 */
  private sortResults_(list: SearchResult[]): SearchResult[] {
    return list.sort((a: SearchResult, b: SearchResult) => {
      let sa = 0;
      let sb = 0;
      if (a.originUrl === this.currentOriginUrl) sa -= 1000;
      if (b.originUrl === this.currentOriginUrl) sb -= 1000;
      const na = (a.name || '').replace(/\s/g, '');
      const nb = (b.name || '').replace(/\s/g, '');
      const bn = this.bookName.replace(/\s/g, '');
      if (na === bn) sa += 50;
      if (nb === bn) sb += 50;
      sa += (a.sourceCount || 1);
      sb += (b.sourceCount || 1);
      return sb - sa;
    });
  }
}

// =====================================================================
// GroupSelectSheet — 分组选择弹窗（单选）
// =====================================================================
export interface GroupItem {
  name: string;
  id: number;
  selected: boolean;
}

@CustomDialog
export struct GroupSelectSheet {
  controller: CustomDialogController;
  @State groups: GroupItem[] = [];
  @State isLoading: boolean = true;
  @State selectedGroupId: number = 0;
  onConfirm?: (groupId: number) => void;

  aboutToAppear(): void {
    this.loadGroups();
  }

  async loadGroups(): Promise<void> {
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const dao = new BookGroupTable(db);
      const allGroups = await dao.getAllGroups();
      const items: GroupItem[] = [];
      for (const g of allGroups) {
        items.push({
          name: g.name,
          id: g.id,
          selected: g.id === this.selectedGroupId,
        });
      }
      this.groups = items;
      // 确保至少有一项选中
      if (this.groups.length > 0 && !this.groups.some(g => g.selected)) {
        this.groups[0].selected = true;
        this.selectedGroupId = this.groups[0].id;
      }
    } catch (e) {
      console.warn('[GroupSelect] load error:', (e as Error).message);
      // fallback: 使用硬编码
      this.groups = [
        { name: '全部', id: 0, selected: true },
        { name: '在读', id: 4, selected: false },
        { name: '未读', id: 5, selected: false },
      ];
    }
    this.isLoading = false;
  }

  build() {
    Column() {
      Row() {
        Text('选择分组').fontSize(16).fontWeight(FontWeight.Bold)
        Blank()
        Button() { Text('完成').fontSize(14).fontColor('#0078D7') }
          .backgroundColor('transparent')
          .onClick(() => {
            if (this.onConfirm) this.onConfirm(this.selectedGroupId);
            this.controller.close();
          })
      }
      .width('100%').padding({ left: 16, right: 12, top: 16, bottom: 8 })

      if (this.isLoading) {
        LoadingProgress().color('#0078D7').margin({ top: 20 })
      } else {
        List() {
          ForEach(this.groups, (item: GroupItem, index: number) => {
            ListItem() {
              Row() {
                // Radio 单选
                Radio({ value: String(item.id), group: 'bookGroup' })
                  .checked(item.selected)
                  .onChange(() => {
                    for (let i = 0; i < this.groups.length; i++) {
                      this.groups[i].selected = i === index;
                    }
                    this.selectedGroupId = item.id;
                  })
                Text(item.name).fontSize(14).margin({ left: 8 })
              }
              .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
              .onClick(() => {
                for (let i = 0; i < this.groups.length; i++) {
                  this.groups[i].selected = i === index;
                }
                this.selectedGroupId = item.id;
              })
            }
          })
        }
        .layoutWeight(1).width('100%')
      }
    }
    .width('100%').height(360)
    .backgroundColor('#FFFFFF')
    .borderRadius({ topLeft: 16, topRight: 16 })
  }
}

// =====================================================================
// BookReadRecordSheet — 阅读记录弹窗
// =====================================================================
@CustomDialog
export struct BookReadRecordSheet {
  controller: CustomDialogController;
  @StorageLink('isDark') isDark: boolean = false;
  totalReadTime: number = 0;
  durChapterIndex: number = 0;
  totalChapterNum: number = 0;
  progressPercent: number = 0;
  bookName: string = '';
  bookAuthor: string = '';
  @State dailyRecords: RecordDayInfo[] = [];
  @State realTotalTime: number = 0;

  aboutToAppear(): void {
    this.loadReadRecords();
  }

  private async loadReadRecords(): Promise<void> {
    if (!this.bookName) return;
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      // 根据书名/作者查询 bookId
      const bookTable = new BookTable(db);
      const book = await bookTable.getBookByName(this.bookName, this.bookAuthor);
      if (!book || book.id <= 0) return;

      const recordTable = new ReadRecordTable(db);
      const totalDuration = await recordTable.getTotalDuration(book.id);
      this.realTotalTime = totalDuration * 1000; // 秒转毫秒

      const records = await recordTable.getByBookId(book.id);
      // 按日期分组 — ArkTS 不使用解构
      const dateKeys: string[] = [];
      const dateTotals: number[] = [];
      const dateSessions: SessionInfo[][] = [];
      for (let ri = 0; ri < records.length; ri++) {
        const r = records[ri];
        const date = r.date || '未知';
        let found = -1;
        for (let di = 0; di < dateKeys.length; di++) {
          if (dateKeys[di] === date) { found = di; break; }
        }
        if (found < 0) {
          found = dateKeys.length;
          dateKeys.push(date);
          dateTotals.push(0);
          dateSessions.push([]);
        }
        dateTotals[found] += r.duration;
        dateSessions[found].push({
          time: new Date(r.startTime).toLocaleTimeString(),
          dur: r.duration,
        });
      }
      // 排序（日期降序）
      const sorted: RecordDayInfo[] = [];
      for (let di = 0; di < dateKeys.length; di++) {
        sorted.push({
          date: dateKeys[di],
          totalMinutes: Math.floor(dateTotals[di] / 60),
          sessions: dateSessions[di],
        });
      }
      sorted.sort((a, b) => {
        if (a.date < b.date) return 1;
        if (a.date > b.date) return -1;
        return 0;
      });
      this.dailyRecords = sorted;
    } catch (_e) {
      console.error('[ReadRecord] loadReadRecords failed:', (_e as Error).message);
    }
  }

  private formatDuration(ms: number): string {
    if (ms <= 0) return '暂无记录';
    const totalSec = Math.floor(ms / 1000);
    const hours = Math.floor(totalSec / 3600);
    const minutes = Math.floor((totalSec % 3600) / 60);
    if (hours > 0) return hours + ' 小时 ' + minutes + ' 分钟';
    if (minutes > 0) return minutes + ' 分钟';
    return totalSec + ' 秒';
  }

  build() {
    Column() {
      Row() {
        Text('阅读记录').fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark))
        Blank()
        Button() { Text('✕').fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark)) }
          .width(32).height(32).backgroundColor('transparent')
          .onClick(() => { this.controller.close(); })
      }
      .width('100%').padding({ left: 16, right: 8, top: 16, bottom: 8 })

      // 总阅读时长
      Column() {
        Text('累计阅读时长').fontSize(13).fontColor('#999')
        Text(this.formatDuration(this.realTotalTime > 0 ? this.realTotalTime : this.totalReadTime))
          .fontSize(20).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark))
          .margin({ top: 4 })
      }
      .width('100%').padding(16).alignItems(HorizontalAlign.Center)

      Divider().strokeWidth(0.5).color(ThemeColors.outlineVariant(this.isDark))

      // 章节统计
      Row() {
        Column() {
          Text(this.durChapterIndex.toString()).fontSize(22).fontWeight(FontWeight.Bold)
            .fontColor(ThemeColors.onBackground(this.isDark))
          Text('当前章节').fontSize(11).fontColor('#999').margin({ top: 2 })
        }.layoutWeight(1)
        Column() {
          Text(this.totalChapterNum.toString()).fontSize(22).fontWeight(FontWeight.Bold)
            .fontColor(ThemeColors.onBackground(this.isDark))
          Text('总章节数').fontSize(11).fontColor('#999').margin({ top: 2 })
        }.layoutWeight(1)
        Column() {
          Text(this.progressPercent + '%').fontSize(22).fontWeight(FontWeight.Bold)
            .fontColor(ThemeColors.onBackground(this.isDark))
          Text('阅读进度').fontSize(11).fontColor('#999').margin({ top: 2 })
        }.layoutWeight(1)
      }
      .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 16 })

      // 时间线
      Text('阅读日历').fontSize(13).fontColor('#999')
        .width('100%').padding({ left: 16 })
        .margin({ top: 4, bottom: 4 })

      if (this.dailyRecords.length > 0) {
        Scroll() {
          Column() {
            ForEach(this.dailyRecords, (day: RecordDayInfo, di: number) => {
              Column() {
                Row() {
                  Text(this.dailyRecords[di].date).fontSize(13).fontWeight(FontWeight.Medium)
                    .fontColor(ThemeColors.primary(this.isDark))
                  Blank()
                  Text(this.dailyRecords[di].totalMinutes + ' 分钟').fontSize(11).fontColor('#999')
                }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 4 })

                // 显示该日期的阅读会话
                ForEach(this.dailyRecords[di].sessions, (sess: SessionInfo, si: number) => {
                  Row() {
                    Text(this.dailyRecords[di].sessions[si].time).fontSize(12)
                      .fontColor(ThemeColors.secondaryText(this.isDark))
                    Text(' 阅读 ' + Math.floor(this.dailyRecords[di].sessions[si].dur / 60) + ' 分钟')
                      .fontSize(11).fontColor('#999').margin({ left: 8 })
                  }
                  .width('100%').padding({ left: 28, right: 16, top: 2, bottom: 2 })
                })
              }
            })
          }.width('100%')
        }
        .layoutWeight(1).width('100%')
        .margin({ bottom: 16 })
      } else {
        Text('暂无阅读记录').fontSize(13).fontColor('#CCC')
          .width('100%').padding(24).textAlign(TextAlign.Center)
      }
    }
    .width('100%').height('60%')
    .backgroundColor(ThemeColors.surface(this.isDark))
    .borderRadius({ topLeft: 16, topRight: 16 })
  }
}

// =====================================================================
// RemarkEditDialog — 编辑备注弹窗
// =====================================================================
@CustomDialog
export struct RemarkEditDialog {
  controller: CustomDialogController;
  @State remarkText: string = '';
  onConfirm?: (text: string) => void;

  build() {
    Column() {
      Row() {
        Text('编辑备注').fontSize(16).fontWeight(FontWeight.Bold)
        Blank()
        Button() { Text('✕').fontSize(16).fontColor('#666') }
          .width(32).height(32).backgroundColor('transparent')
          .onClick(() => { this.controller.close(); })
      }
      .width('100%').padding({ left: 16, right: 8, top: 16, bottom: 8 })

      TextArea({ text: this.remarkText, placeholder: '输入备注文字...' })
        .width('100%').layoutWeight(1)
        .margin({ left: 16, right: 16, top: 8, bottom: 8 })
        .fontSize(14)
        .backgroundColor('#F5F5F5')
        .borderRadius(8)
        .padding(12)
        .onChange((value: string): void => { this.remarkText = value; })

      Button('保存').fontSize(14).fontColor('#FFF')
        .backgroundColor('#0078D7').width('100%').height(44)
        .borderRadius(0)
        .margin({ top: 4 })
        .onClick(() => {
          if (this.onConfirm) this.onConfirm(this.remarkText);
          this.controller.close();
        })
    }
    .width('100%').height(280)
    .backgroundColor('#FFFFFF')
    .borderRadius({ topLeft: 16, topRight: 16 })
  }
}


// =====================================================================
// ChapterPickSheet — 单章换源的目标章节选择弹窗
// 对齐 Legado ChangeChapterSource: 选中源后展示其目录，用户挑选要加载的章节
// =====================================================================
@CustomDialog
export struct ChapterPickSheet {
  controller: CustomDialogController;
  @StorageLink('isDark') isDark: boolean = false;
  /** 新源的目录 */
  chapters: BookSourceChapter[] = [];
  /** 预选章节（按原阅读位置匹配） */
  currentIndex: number = 0;
  onPick?: (index: number) => void;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    // 滚动到预选章节附近
    if (this.currentIndex > 2) {
      setTimeout(() => { this.scroller.scrollToIndex(this.currentIndex - 2); }, 100);
    }
  }

  build() {
    Column() {
      Row() {
        Text('选择章节').fontSize(16).fontWeight(FontWeight.Bold)
        Blank()
        Button() { Text('✕').fontSize(16).fontColor('#666') }
          .width(32).height(32).backgroundColor('transparent')
          .onClick(() => { this.controller.close(); })
      }
      .width('100%').padding({ left: 16, right: 8, top: 16, bottom: 8 })

      List({ scroller: this.scroller }) {
        ForEach(this.chapters, (ch: BookSourceChapter, index: number) => {
          ListItem() {
            Text(ch.title || ('第 ' + (index + 1) + ' 节'))
              .fontSize(14)
              .fontColor(index === this.currentIndex ? '#0078D7' : ThemeColors.onBackground(this.isDark))
              .fontWeight(index === this.currentIndex ? FontWeight.Bold : FontWeight.Normal)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          }
          .border({ width: { bottom: 0.5 }, color: ThemeColors.outlineVariant(this.isDark) })
          .onClick(() => {
            if (this.onPick) this.onPick(index);
            this.controller.close();
          })
        }, (ch: BookSourceChapter, index: number) => index + '|' + (ch.url || ''))
      }
      .layoutWeight(1).width('100%')
    }
    .width('100%').height('70%')
    .backgroundColor(ThemeColors.surface(this.isDark))
    .borderRadius({ topLeft: 16, topRight: 16 })
  }
}
