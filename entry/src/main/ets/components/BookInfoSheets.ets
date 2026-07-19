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
import { SettingsStore } from '../data/preferences/SettingsStore';

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
  @StorageLink('isDark') isDark: boolean = false;
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
        Text($r('app.string.ui_8c7609ffeb')).fontColor(ThemeColors.onSurface(this.isDark)).fontSize(16).fontWeight(FontWeight.Bold)
        Blank()
        Button() { Text($r('app.string.ui_0951b9a022')).fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark)) }
          .width(40).height(40).backgroundColor(ThemeColors.transparent())
          .accessibilityText($r('app.string.common_close')).onClick(() => { this.controller.close(); })
      }
      .width('100%').padding({ left: 16, right: 8, top: 16, bottom: 8 })

      if (this.isSearching) {
        LoadingProgress().width(40).height(40).margin({ top: 20 })
        Text($r('app.string.ui_6f0d03e371')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 8, bottom: 20 })
      } else if (this.coverResults.length === 0) {
        Text($r('app.string.ui_e3b9e029b5')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).margin(20)
      } else {
        Text('已找到 ' + this.coverResults.length + ' 个封面').fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).padding(8)
      }

      if (this.coverResults.length > 0) {
        Grid() {
          ForEach(this.coverResults, (item: SearchResult) => {
            GridItem() {
              Column() {
                Image(item.coverUrl)
                  .accessibilityText((item.origin || '候选') + '封面')
                  .width('100%').aspectRatio(5 / 7)
                  .objectFit(ImageFit.Cover).borderRadius(4)
                Text(item.origin).fontSize(10).fontColor(ThemeColors.secondaryText(this.isDark)).maxLines(1)
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
    .width('100%').height(420).constraintSize({ maxWidth: 640, maxHeight: '80%' })
    .backgroundColor(ThemeColors.surface(this.isDark))
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
  /** 当前书籍的书源类型（BookSource.sourceType：0 文本 2 漫画；-1 未知），用于类型一致性检查 */
  currentSourceType: number = -1;
  @State keyword: string = '';
  @State results: SearchResult[] = [];
  @State isSearching: boolean = false;
  @State searchProgress: string = '';
  /** 对齐 Legado "校验作者" 开关（持久化到 SettingsStore） */
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
  // 每次搜索独立的任务 ID：旧任务回调不得覆盖新任务
  private searchTaskId_: number = 0;

  aboutToAppear(): void {
    if (this.initialized) return;
    this.initialized = true;
    this.keyword = this.bookName;
    // 读取持久化的"校验作者"设置
    SettingsStore.getInstance()
      .init(UiUtil.getHostContext(this.getUIContext()))
      .then(async () => {
        this.checkAuthor = await SettingsStore.getInstance().getChangeSourceCheckAuthor();
      })
      .catch(() => {});
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
      // 对齐 Legado: !checkAuthor || fAuthor.contains(author)；结果无作者信息视为不匹配
      if (this.checkAuthor && targetAuthor) {
        const rauthor = (r.author || '').replace(/\s/g, '');
        if (!this.authorMatches_(rauthor, targetAuthor)) return false;
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
    // 对齐 Legado searchJob?.cancel() — 取消前一次搜索（任务 ID 递增使旧任务失效）
    const myTaskId = ++this.searchTaskId_;
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
	          if (!this.searching || myTaskId !== this.searchTaskId_) return;
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
	        () => !this.searching || myTaskId !== this.searchTaskId_
	      );

      // 等待期间已有更新的搜索发起，丢弃本次结果
      if (myTaskId !== this.searchTaskId_) return;

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
    if (myTaskId === this.searchTaskId_) {
      this.isSearching = false;
      this.searchProgress = '';
    }
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
      // 校验作者（对齐 Legado checkAuthor 开关）；结果无作者信息视为不匹配
      if (this.checkAuthor && targetAuthor) {
        const rauthor = (r.author || '').replace(/\s/g, '');
        if (!this.authorMatches_(rauthor, targetAuthor)) return false;
      }
      return true;
    });
  }

  /** 作者匹配（对齐 Legado fAuthor.contains(author)；空作者视为不匹配） */
  private authorMatches_(resultAuthor: string, targetAuthor: string): boolean {
    if (!resultAuthor) return false;
    return resultAuthor.includes(targetAuthor) || targetAuthor.includes(resultAuthor);
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Text(this.singleChapterMode ? '单章换源' : '更换书源').fontColor(ThemeColors.onSurface(this.isDark)).fontSize(16).fontWeight(FontWeight.Bold)
        Blank()
        Button() { Text($r('app.string.ui_0951b9a022')).fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark)) }
          .width(40).height(40).backgroundColor(ThemeColors.transparent())
          .accessibilityText($r('app.string.common_close')).onClick(() => {
            this.searching = false; // 对齐 Legado: dispose 时 stopSearch
            this.controller.close();
          })
      }
      .width('100%').padding({ left: 16, right: 8, top: 16, bottom: 8 })

      // 搜索栏 + 刷新按钮
      Row() {
        TextInput({ text: this.keyword, placeholder: $r('app.string.ui_7f4ffe6a5d') })
          .layoutWeight(1).height(44).fontSize(13)
          .borderRadius(22).backgroundColor(ThemeColors.surfaceVariant(this.isDark))
          .padding({ left: 12, right: 12 })
          .onChange((value: string) => { this.keyword = value; })
        Button() { Text($r('app.string.common_search')).fontSize(13).fontColor(ThemeColors.onPrimary(this.isDark)) }
          .height(40).width(56).margin({ left: 8 }).padding(0)
          .backgroundColor(ThemeColors.primary(this.isDark)).borderRadius(18)
          .onClick(() => { this.searchSources(); })
        Button() { Text($r('app.string.common_refresh')).fontSize(13).fontColor(ThemeColors.onBackground(this.isDark)) }
          .height(40).width(56).margin({ left: 4 }).padding(0)
          .backgroundColor(ThemeColors.outlineVariant(this.isDark)).borderRadius(18)
          .onClick(() => { this.cachedSources = []; this.searchSources(); })
      }
      .width('100%').padding({ left: 16, right: 16, bottom: 4 })

      // 校验作者开关（对齐 Legado checkAuthor）
      Row() {
        Text($r('app.string.ui_12d4cdea63')).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
        Toggle({ type: ToggleType.Checkbox, isOn: this.checkAuthor })
          .selectedColor(ThemeColors.primary(this.isDark))
          .margin({ left: 6 })
          .onChange((isOn: boolean) => {
            this.checkAuthor = isOn;
            // 持久化开关状态（对齐 Legado 换源设置）
            SettingsStore.getInstance().setChangeSourceCheckAuthor(isOn).catch(() => {});
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
        Text(this.searchProgress).fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark))
          .width('100%').padding({ left: 16, right: 16, bottom: 4 })
      }

	      // 结果列表（点击行直接替换源）
	      if (this.isSearching && this.results.length === 0) {
	        Column() {
	          LoadingProgress().width(40).height(40).margin({ top: 30 })
	          Text($r('app.string.ui_ab0501d882')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 8 })
	        }.width('100%').layoutWeight(1)
	      } else if (this.results.length === 0) {
        Column() {
          Text($r('app.string.ui_7266978dd6')).fontSize(14).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 30 })
          Text($r('app.string.ui_8dbff19fd7')).fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 4 })
        }.width('100%').layoutWeight(1)
      } else {
        List() {
          ForEach(this.results, (item: SearchResult) => {
            ListItem() {
              Row() {
                // 当前源标识（前置）
                if (item.originUrl === this.currentOriginUrl) {
                  Text($r('app.string.ui_698a879938')).fontSize(14).fontColor(ThemeColors.success(this.isDark)).fontWeight(FontWeight.Bold)
                    .margin({ right: 6 })
                }
                Column() {
                  Row() {
                    Text(item.name || '未知').fontColor(ThemeColors.onSurface(this.isDark)).fontSize(14).fontWeight(FontWeight.Medium)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    if (item.originUrl === this.currentOriginUrl) {
                      Text($r('app.string.ui_25e74dceac')).fontSize(10).fontColor(ThemeColors.success(this.isDark)).margin({ left: 6 })
                        .backgroundColor(ThemeColors.successContainer(this.isDark)).borderRadius(4).padding({ left: 4, right: 4 })
                    }
                  }.alignItems(VerticalAlign.Center)
                  Text(item.author || '').fontSize(12).fontColor(ThemeColors.secondaryText(this.isDark))
                    .maxLines(1).margin({ top: 2 })
                  Row() {
                    Text(item.origin || '未知').fontSize(11)
                      .fontColor(item.originUrl === this.currentOriginUrl ? ThemeColors.success(this.isDark) : ThemeColors.primary(this.isDark))
                      .maxLines(1)
                    if (item.wordCount) {
                      Text(' · ' + item.wordCount).fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark))
                    }
                  }.margin({ top: 2 })
                }
                .layoutWeight(1).alignItems(HorizontalAlign.Start)
              }
              .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
            }
            .border({ width: { bottom: 0.5 }, color: ThemeColors.surfaceVariant(this.isDark) })
            .onClick(() => { this.onResultClick_(item); })
          })
        }
        .layoutWeight(1).width('100%')
      }
    }
    .width('100%').height('70%').constraintSize({ maxWidth: 720, maxHeight: 760 })
    .backgroundColor(ThemeColors.surface(this.isDark))
    .borderRadius({ topLeft: 16, topRight: 16 })
  }

  /** 网络搜索的原始结果（用于"校验作者"开关切换后本地重过滤） */
  private rawResults_: SearchResult[] = [];

  /** 点击候选源：先检查书籍类型是否一致（对齐 Legado），再选择替换或作为新书 */
  private onResultClick_(item: SearchResult): void {
    this.isTypeMismatch_(item)
      .then((mismatch: boolean) => {
        if (!mismatch) {
          this.proceedWithCandidate_(item);
          return;
        }
        // @CustomDialog 中不再嵌套第二个 CustomDialogController，避免生命周期冲突。
        UiUtil.showDialog(this.getUIContext(), {
          title: '书籍类型不一致',
          message: '当前书籍与所选书源的类型不同（如小说/漫画），换源后可能无法正常阅读',
          buttons: [
            { text: '取消', color: ThemeColors.secondaryText(this.isDark) },
            { text: '仍然换源', color: ThemeColors.warning(this.isDark) }
          ]
        }).then((result: promptAction.ShowDialogSuccessResponse) => {
          if (result.index === 1) this.proceedWithCandidate_(item);
        });
      })
      .catch(() => { this.proceedWithCandidate_(item); });
  }

  /** 候选源类型与当前书籍类型是否不一致（无法判定时放行） */
  private async isTypeMismatch_(item: SearchResult): Promise<boolean> {
    if (this.currentSourceType < 0 || !item.originUrl) return false;
    try {
      await AppDatabase.getInstance().waitForInit();
      const dao = new BookSourceTable(AppDatabase.getInstance().rdbStore);
      const sources = await dao.getAllSources();
      const norm = item.originUrl.replace(/\/+$/, '');
      const src = sources.find(s => s.sourceUrl === item.originUrl) ||
        sources.find(s => s.sourceUrl.replace(/\/+$/, '') === norm) || null;
      if (!src) return false;
      return src.sourceType !== this.currentSourceType;
    } catch (_e) {
      return false;
    }
  }

  private proceedWithCandidate_(item: SearchResult): void {
    if (this.singleChapterMode || !this.allowAddAsNew) {
      this.confirmReplace_(item);
      return;
    }
    UiUtil.showDialog(this.getUIContext(), {
      title: item.name || '',
      message: (item.origin || '') + (item.author ? ' · ' + item.author : ''),
      buttons: [
        { text: '取消', color: ThemeColors.secondaryText(this.isDark) },
        { text: '替换当前书籍', color: ThemeColors.primary(this.isDark) },
        { text: '作为新书加入书架', color: ThemeColors.primary(this.isDark) }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 1) {
        this.confirmReplace_(item);
      } else if (result.index === 2) {
        if (this.onAddAsNew) this.onAddAsNew(item);
        this.searching = false;
        this.controller.close();
      }
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
  @StorageLink('isDark') isDark: boolean = false;
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
        Text($r('app.string.ui_d3c09574cc')).fontColor(ThemeColors.onSurface(this.isDark)).fontSize(16).fontWeight(FontWeight.Bold)
        Blank()
        Button() { Text($r('app.string.common_done')).fontSize(14).fontColor(ThemeColors.primary(this.isDark)) }
          .backgroundColor(ThemeColors.transparent())
          .onClick(() => {
            if (this.onConfirm) this.onConfirm(this.selectedGroupId);
            this.controller.close();
          })
      }
      .width('100%').padding({ left: 16, right: 12, top: 16, bottom: 8 })

      if (this.isLoading) {
        LoadingProgress().color(ThemeColors.primary(this.isDark)).margin({ top: 20 })
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
                Text(item.name).fontColor(ThemeColors.onSurface(this.isDark)).fontSize(14).margin({ left: 8 })
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
    .width('100%').height(360).constraintSize({ maxWidth: 640, maxHeight: '70%' })
    .backgroundColor(ThemeColors.surface(this.isDark))
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
        Text($r('app.string.ui_c3733c356a')).fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark))
        Blank()
        Button() { Text($r('app.string.ui_0951b9a022')).fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark)) }
          .width(40).height(40).backgroundColor(ThemeColors.transparent())
          .accessibilityText($r('app.string.common_close')).onClick(() => { this.controller.close(); })
      }
      .width('100%').padding({ left: 16, right: 8, top: 16, bottom: 8 })

      // 总阅读时长
      Column() {
        Text($r('app.string.ui_9958d93233')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
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
          Text($r('app.string.ui_d3cf87651f')).fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 2 })
        }.layoutWeight(1)
        Column() {
          Text(this.totalChapterNum.toString()).fontSize(22).fontWeight(FontWeight.Bold)
            .fontColor(ThemeColors.onBackground(this.isDark))
          Text($r('app.string.ui_783198abda')).fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 2 })
        }.layoutWeight(1)
        Column() {
          Text(this.progressPercent + '%').fontSize(22).fontWeight(FontWeight.Bold)
            .fontColor(ThemeColors.onBackground(this.isDark))
          Text($r('app.string.ui_035b6a0cf4')).fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ top: 2 })
        }.layoutWeight(1)
      }
      .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 16 })

      // 时间线
      Text($r('app.string.ui_48dcb13745')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
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
                  Text(this.dailyRecords[di].totalMinutes + ' 分钟').fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark))
                }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 4 })

                // 显示该日期的阅读会话
                ForEach(this.dailyRecords[di].sessions, (sess: SessionInfo, si: number) => {
                  Row() {
                    Text(this.dailyRecords[di].sessions[si].time).fontSize(12)
                      .fontColor(ThemeColors.secondaryText(this.isDark))
                    Text(' 阅读 ' + Math.floor(this.dailyRecords[di].sessions[si].dur / 60) + ' 分钟')
                      .fontSize(11).fontColor(ThemeColors.secondaryText(this.isDark)).margin({ left: 8 })
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
        Text($r('app.string.ui_367b6ee56c')).fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
          .width('100%').padding(24).textAlign(TextAlign.Center)
      }
    }
    .width('100%').height('60%').constraintSize({ maxWidth: 720, maxHeight: 680 })
    .backgroundColor(ThemeColors.surface(this.isDark))
    .borderRadius({ topLeft: 16, topRight: 16 })
  }
}

// =====================================================================
// EditBookInfoDialog — 编辑书名/作者弹窗
// =====================================================================
@CustomDialog
export struct EditBookInfoDialog {
  controller: CustomDialogController;
  @StorageLink('isDark') isDark: boolean = false;
  @State editName: string = '';
  @State editAuthor: string = '';
  onConfirm?: (name: string, author: string) => void;

  build() {
    Column() {
      Row() {
        Text('编辑书籍信息').fontColor(ThemeColors.onSurface(this.isDark)).fontSize(16).fontWeight(FontWeight.Bold)
        Blank()
        Button() { Text($r('app.string.ui_0951b9a022')).fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark)) }
          .width(40).height(40).backgroundColor(ThemeColors.transparent())
          .accessibilityText($r('app.string.common_close')).onClick(() => { this.controller.close(); })
      }
      .width('100%').padding({ left: 16, right: 8, top: 16, bottom: 8 })

      Column() {
        Text('书名')
          .fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
          .width('100%').padding({ left: 4, bottom: 4 })
        TextInput({ text: this.editName, placeholder: '输入书名' })
          .width('100%').height(48).fontSize(16)
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
          .borderRadius(12).padding({ left: 12, right: 12 })
          .onChange((value: string): void => { this.editName = value; })

        Text('作者')
          .fontSize(13).fontColor(ThemeColors.secondaryText(this.isDark))
          .width('100%').padding({ left: 4, bottom: 4, top: 12 })
        TextInput({ text: this.editAuthor, placeholder: '输入作者' })
          .width('100%').height(48).fontSize(14)
          .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
          .borderRadius(12).padding({ left: 12, right: 12 })
          .onChange((value: string): void => { this.editAuthor = value; })
      }
      .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })

      Button($r('app.string.common_save')).fontSize(14).fontColor(ThemeColors.onPrimary(this.isDark))
        .backgroundColor(ThemeColors.primary(this.isDark)).width('100%').height(44)
        .borderRadius(0)
        .margin({ top: 4 })
        .onClick(() => {
          if (this.onConfirm) this.onConfirm(this.editName, this.editAuthor);
          this.controller.close();
        })
    }
    .width('100%').height(280).constraintSize({ maxWidth: 640, maxHeight: '70%' })
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
  @StorageLink('isDark') isDark: boolean = false;
  @State remarkText: string = '';
  onConfirm?: (text: string) => void;

  build() {
    Column() {
      Row() {
        Text($r('app.string.ui_1c9313edc3')).fontColor(ThemeColors.onSurface(this.isDark)).fontSize(16).fontWeight(FontWeight.Bold)
        Blank()
        Button() { Text($r('app.string.ui_0951b9a022')).fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark)) }
          .width(40).height(40).backgroundColor(ThemeColors.transparent())
          .accessibilityText($r('app.string.common_close')).onClick(() => { this.controller.close(); })
      }
      .width('100%').padding({ left: 16, right: 8, top: 16, bottom: 8 })

      TextArea({ text: this.remarkText, placeholder: $r('app.string.ui_b2b1b960f6') })
        .width('100%').layoutWeight(1)
        .margin({ left: 16, right: 16, top: 8, bottom: 8 })
        .fontSize(14)
        .backgroundColor(ThemeColors.surfaceVariant(this.isDark))
        .borderRadius(8)
        .padding(12)
        .onChange((value: string): void => { this.remarkText = value; })

      Button($r('app.string.common_save')).fontSize(14).fontColor(ThemeColors.onPrimary(this.isDark))
        .backgroundColor(ThemeColors.primary(this.isDark)).width('100%').height(44)
        .borderRadius(0)
        .margin({ top: 4 })
        .onClick(() => {
          if (this.onConfirm) this.onConfirm(this.remarkText);
          this.controller.close();
        })
    }
    .width('100%').height(280).constraintSize({ maxWidth: 640, maxHeight: '70%' })
    .backgroundColor(ThemeColors.surface(this.isDark))
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
        Text($r('app.string.ui_e164fce278')).fontColor(ThemeColors.onSurface(this.isDark)).fontSize(16).fontWeight(FontWeight.Bold)
        Blank()
        Button() { Text($r('app.string.ui_0951b9a022')).fontSize(16).fontColor(ThemeColors.secondaryText(this.isDark)) }
          .width(40).height(40).backgroundColor(ThemeColors.transparent())
          .accessibilityText($r('app.string.common_close')).onClick(() => { this.controller.close(); })
      }
      .width('100%').padding({ left: 16, right: 8, top: 16, bottom: 8 })

      List({ scroller: this.scroller }) {
        ForEach(this.chapters, (ch: BookSourceChapter, index: number) => {
          ListItem() {
            Text(ch.title || ('第 ' + (index + 1) + ' 节'))
              .fontSize(14)
              .fontColor(index === this.currentIndex ? ThemeColors.primary(this.isDark) : ThemeColors.onBackground(this.isDark))
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
    .width('100%').height('70%').constraintSize({ maxWidth: 720, maxHeight: 760 })
    .backgroundColor(ThemeColors.surface(this.isDark))
    .borderRadius({ topLeft: 16, topRight: 16 })
  }
}


// =====================================================================
// OptionSelectSheet — 大字号选项弹窗（替代系统 ActionSheet）
// 用于换源方式选择、候选源"替换/加新书"选择等二选一/多选一场景
// =====================================================================
export interface OptionItem {
  title: string;
  description?: string;
  action: () => void;
}

@CustomDialog
export struct OptionSelectSheet {
  controller: CustomDialogController;
  @StorageLink('isDark') isDark: boolean = false;
  title: string = '';
  message: string = '';
  options: OptionItem[] = [];

  build() {
    Column() {
      if (this.title) {
        Text(this.title)
          .fontSize(17).fontWeight(FontWeight.Bold)
          .fontColor(ThemeColors.onBackground(this.isDark))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 24, right: 24, top: 20 })
      }
      if (this.message) {
        Text(this.message)
          .fontSize(13)
          .fontColor(ThemeColors.secondaryText(this.isDark))
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 24, right: 24, top: 6 })
      }
      Column() {
        ForEach(this.options, (opt: OptionItem, index: number) => {
          Column() {
            Text(opt.title)
              .fontSize(17)
              .fontColor(ThemeColors.onBackground(this.isDark))
            if (opt.description) {
              Text(opt.description)
                .fontSize(12)
                .fontColor(ThemeColors.secondaryText(this.isDark))
                .margin({ top: 3 })
            }
          }
          .width('100%')
          .padding({ top: 18, bottom: 18 })
          .alignItems(HorizontalAlign.Center)
          .border({
            width: { top: index === 0 ? 0 : 0.5 },
            color: ThemeColors.outlineVariant(this.isDark)
          })
          .onClick(() => {
            opt.action();
            this.controller.close();
          })
        }, (opt: OptionItem, index: number) => index + '|' + opt.title)
      }
      .width('100%')
      .margin({ top: 14 })

      Text($r('app.string.common_cancel'))
        .fontSize(17)
        .fontColor(ThemeColors.secondaryText(this.isDark))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 18, bottom: 18 })
        .margin({ top: 8 })
        .backgroundColor(ThemeColors.outlineVariant(this.isDark))
        .onClick(() => { this.controller.close(); })
    }
    .width('100%')
    .constraintSize({ maxWidth: 640, maxHeight: '90%' })
    .padding({ bottom: 16 })
    .backgroundColor(ThemeColors.surface(this.isDark))
    .borderRadius({ topLeft: 16, topRight: 16 })
  }
}
