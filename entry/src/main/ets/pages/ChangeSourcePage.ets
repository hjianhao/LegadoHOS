/**
 * 换源页面 — 展示已缓存的源 + 支持刷新重新搜索
 *
 * 数据源优先级：
 *   1. aboutToAppear 时从 book_sources_cache 表加载已缓存的源 → 立即展示
 *   2. 用户点击"刷新" → 重新搜索所有书源 → 更新缓存 → 更新列表
 *
 * 过滤：TextInput 输入文字实时过滤（匹配源名/书名/作者）
 *
 * 使用流程：
 *   - 书籍详情页"换源" → 跳转到此 → 展示缓存源 → 点击源 → 返回详情页刷新
 *   - 阅读页"换源" → 跳转到此 → 展示缓存源 → 点击源 → 返回阅读页加载新源内容
 */
import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { BookSourcesCacheTable, SourceCacheEntry } from '../data/database/BookSourcesCacheTable';
import { BookSource } from '../model/BookSource';
import { SearchResult, createSearchResult, getBookNameKey } from '../model/SearchResult';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { SourceSwitchStore } from '../util/SourceSwitchStore';

@Entry
@Component
export struct ChangeSourcePage {
  @StorageLink('isDark') isDark: boolean = false;

  // ---- 来自 router params ----
  private bookName: string = '';
  private bookAuthor: string = '';
  private sourceOriginUrl: string = '';

  // ---- 状态 ----
  @State isSearching: boolean = false;
  @State searchProgress: string = '';
  @State filterText: string = '';
  @State results: SearchResult[] = [];       // 当前展示的结果（已过滤）
  @State allResults: SearchResult[] = [];    // 所有结果（原始，未过滤）
  @State isFromCache: boolean = false;       // 是否来自缓存（非实时搜索）

  // 内部状态
  private searching: boolean = false;

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, string>;
    this.bookName = params['bookName'] || '';
    this.bookAuthor = params['bookAuthor'] || '';
    this.sourceOriginUrl = params['sourceOriginUrl'] || '';
    this.filterText = '';
    // 优先从缓存加载
    this.loadFromCache();
  }

  /** 从 book_sources_cache 加载缓存源 */
  private async loadFromCache(): Promise<void> {
    if (!this.bookName) return;
    try {
      await AppDatabase.getInstance().waitForInit();
      const db = AppDatabase.getInstance().rdbStore;
      const cacheDao = new BookSourcesCacheTable(db);
      const cached = await cacheDao.getSourcesByBook(this.bookName, this.bookAuthor);
      if (cached.length > 0) {
        this.allResults = this.cachedToResults(cached);
        this.applyFilter();
        this.isFromCache = true;
        return;
      }
    } catch (_e) { /* ignore */ }
    // 无缓存 → 自动搜索
    this.startSearch();
  }

  /** 将 SourceCacheEntry 转为 SearchResult */
  private cachedToResults(cached: SourceCacheEntry[]): SearchResult[] {
    // 先按（sourceName, sourceUrl）去重
    const seen = new Set<string>();
    const uniq: SourceCacheEntry[] = [];
    for (const c of cached) {
      const key = c.sourceUrl || c.sourceName;
      if (key && !seen.has(key)) {
        seen.add(key);
        uniq.push(c);
      }
    }
    return uniq.map(c => {
      const r = createSearchResult();
      r.key = c.sourceUrl + '|' + c.noteUrl;
      r.name = this.bookName;
      r.author = this.bookAuthor;
      r.coverUrl = c.coverUrl;
      r.noteUrl = c.noteUrl;
      r.origin = c.sourceName;
      r.originUrl = c.sourceUrl;
      r.kind = c.kind;
      r.wordCount = c.wordCount;
      r.lastUpdateTime = c.lastUpdateTime;
      r.introduce = c.introduce;
      r.searchTime = Date.now();
      r.sourceCount = 0;
      r.sourceOrigins = [c.sourceName];
      r.sourceUrls = [c.sourceUrl];
      r.sourceNoteUrls = [c.noteUrl];
      return r;
    });
  }

  /** 过滤文本变化时实时过滤 */
  onFilterChange(value: string): void {
    this.filterText = value;
    this.applyFilter();
  }

  /** 应用过滤 */
  applyFilter(): void {
    const ft = this.filterText.trim().toLowerCase();
    if (!ft) {
      this.results = this.allResults;
      return;
    }
    this.results = this.allResults.filter(r => {
      return (r.origin || '').toLowerCase().includes(ft) ||
             (r.name || '').toLowerCase().includes(ft) ||
             (r.author || '').toLowerCase().includes(ft);
    });
  }

  /** 开始搜索 */
  private startSearch(): void {
    this.isFromCache = false;
    this.searchSources();
  }

  /** 刷新：重新搜索所有书源 */
  onRefresh(): void {
    this.isFromCache = false;
    this.searchSources();
  }

  /** 排序：当前源置顶，多源优先 */
  private sortResults(results: SearchResult[]): SearchResult[] {
    return results.sort((a: SearchResult, b: SearchResult) => {
      let sa = 0;
      let sb = 0;
      if (a.originUrl === this.sourceOriginUrl) sa -= 1000;
      if (b.originUrl === this.sourceOriginUrl) sb -= 1000;
      sa += (a.sourceCount || 1);
      sb += (b.sourceCount || 1);
      return sb - sa;
    });
  }

  /** 搜索所有书源（增量显示结果） */
  async searchSources(): Promise<void> {
    if (!this.bookName.trim()) return;
    this.searching = true;
    this.isSearching = true;
    this.allResults = [];
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
        promptAction.showToast({ message: '没有启用的书源', duration: 2000 });
        this.isSearching = false;
        return;
      }

      const rawResults = await globalSourceExecutor.search(
        this.bookName.trim(), enabled,
        (merged: SearchResult[], processed: number, total: number) => {
          if (!this.searching) return;
          // 增量更新：每完成一个书源，就过滤并展示结果（同 SearchPage 的增量显示）
          const filtered = this.filterResults(merged);
          this.allResults = this.sortResults(filtered);
          this.searchProgress = '已搜 ' + processed + '/' + total + ' 个源，找到 ' + merged.length + ' 条';
          this.applyFilter();
        }
      );
      console.info('[ChangeSrc] searchSources complete: keyword="' + this.bookName + '" enabled=' + enabled.length
        + ' rawResults=' + rawResults.length);

      // 最终一致性：确保最终结果正确（增量回调已保证实时更新）
      this.allResults = this.sortResults(this.filterResults(rawResults));

      // 更新缓存表
      this.updateCache(rawResults);
    } catch (err) {
      console.error('[ChangeSourcePage] searchSources failed:', (err as Error).message);
    }

    this.applyFilter();
    this.isSearching = false;
    this.searchProgress = '';
  }

  /** 将搜索结果持久化到缓存表（只缓存目标书的源，不对应则清空） */
  private async updateCache(results: SearchResult[]): Promise<void> {
    try {
      const db = AppDatabase.getInstance().rdbStore;
      const cacheDao = new BookSourcesCacheTable(db);
      // 只保留过滤后命中目标书的结果
      const targetResults = this.filterResults(results);
      const allSources: SourceCacheEntry[] = [];
      for (const r of targetResults) {
        if (!r.sourceOrigins || r.sourceOrigins.length === 0) continue;
        for (let i = 0; i < r.sourceOrigins.length; i++) {
          allSources.push({
            sourceName: r.sourceOrigins[i] || '',
            sourceUrl: r.sourceUrls[i] || '',
            noteUrl: r.sourceNoteUrls[i] || '',
            coverUrl: r.coverUrl || '',
            kind: r.kind || '',
            wordCount: r.wordCount || '',
            lastUpdateTime: r.lastUpdateTime || '',
            introduce: r.introduce || '',
          });
        }
      }
      await cacheDao.replaceSources(this.bookName, this.bookAuthor, allSources);
    } catch (_e) { /* ignore */ }
  }

	  /** 过滤结果：精确匹配书名（换源场景只需要同一本书的源） */
	  private filterResults(raw: SearchResult[]): SearchResult[] {
	    const targetName = this.bookName;
	    const targetKey = getBookNameKey(targetName);
	    console.info('[ChangeSrc] filterResults: bookName="' + this.bookName
	      + '" targetKey="' + targetKey + '" totalRaw=' + raw.length);
	    if (!targetKey) return raw;
	    const matched = raw.filter(r => {
	      const rKey = getBookNameKey(r.name || '');
	      // 1. 归一化键精确匹配
	      if (rKey === targetKey) return true;
	      // 2. 去空格后包含匹配
	      const cleanTarget = targetName.replace(/\s/g, '');
	      const cleanName = (r.name || '').replace(/\s/g, '');
	      if (cleanName.includes(cleanTarget) || cleanTarget.includes(cleanName)) return true;
	      console.info('[ChangeSrc]  FILTERED_OUT: name="' + (r.name || '') + '"');
	      return false;
	    });
		    // 3. 按归一化 key 再次合并（兼容同书不同 merge key 导致的重复条目）
		    const dedupMap = new Map<string, SearchResult>();
		    for (const r of matched) {
		      const key = getBookNameKey(r.name || '');
		      const existing = dedupMap.get(key);
		      if (existing) {
		        // 合并源信息
		        existing.sourceCount += r.sourceCount;
		        // 手动合并去重（ArkTS 不支持 Set + 展开）
		        const seenOrigins = new Set<string>();
		        const mergedOrigins: string[] = [];
		        for (const o of existing.sourceOrigins.concat(r.sourceOrigins)) {
		          if (!seenOrigins.has(o)) { seenOrigins.add(o); mergedOrigins.push(o); }
		        }
		        existing.sourceOrigins = mergedOrigins;
		        const seenUrls = new Set<string>();
		        const mergedUrls: string[] = [];
		        for (const u of existing.sourceUrls.concat(r.sourceUrls || [])) {
		          if (!seenUrls.has(u)) { seenUrls.add(u); mergedUrls.push(u); }
		        }
		        existing.sourceUrls = mergedUrls;
		        const seenNoteUrls = new Set<string>();
		        const mergedNoteUrls: string[] = [];
		        for (const nu of existing.sourceNoteUrls.concat(r.sourceNoteUrls || [])) {
		          if (!seenNoteUrls.has(nu)) { seenNoteUrls.add(nu); mergedNoteUrls.push(nu); }
		        }
		        existing.sourceNoteUrls = mergedNoteUrls;
		        // 保留更好的作者
		        if (r.author && (!existing.author || existing.author.length > r.author.length)) {
		          existing.author = r.author;
		        }
		      } else {
		        // 手动复制 r（ArkTS 不支持对象展开）
		        const copy: SearchResult = {
		          key: r.key, name: r.name, author: r.author,
		          coverUrl: r.coverUrl, noteUrl: r.noteUrl,
		          origin: r.origin, originUrl: r.originUrl,
		          kind: r.kind, wordCount: r.wordCount, lastUpdateTime: r.lastUpdateTime,
		          introduce: r.introduce, helperMsg: r.helperMsg,
		          duration: r.duration, searchTime: r.searchTime,
		          sourceCount: r.sourceCount,
		          sourceOrigins: r.sourceOrigins,
		          sourceUrls: r.sourceUrls,
		          sourceNoteUrls: r.sourceNoteUrls,
		        };
		        dedupMap.set(key, copy);
		      }
		    }
			    // 展开：每个去重结果拆成每源一行，展示格式与缓存一致
			    const expanded: SearchResult[] = [];
			    const entries = Array.from(dedupMap.entries());
			    for (const ent of entries) {
			      const merged = ent[1];
			      for (let i = 0; i < merged.sourceOrigins.length; i++) {
			        const row = createSearchResult();
			        row.name = merged.name;
			        row.author = merged.author;
			        row.coverUrl = merged.coverUrl;
			        row.noteUrl = merged.sourceNoteUrls[i] || merged.noteUrl;
			        row.origin = merged.sourceOrigins[i] || '未知';
			        row.originUrl = merged.sourceUrls[i] || '';
			        row.kind = merged.kind;
			        row.wordCount = merged.wordCount;
			        row.lastUpdateTime = merged.lastUpdateTime;
			        row.introduce = merged.introduce;
			        row.sourceCount = 1;
			        row.sourceOrigins = [row.origin];
			        row.sourceUrls = [row.originUrl];
			        row.sourceNoteUrls = [row.noteUrl];
			        expanded.push(row);
			      }
			    }
			    console.info('[ChangeSrc] filterResults kept=' + matched.length + ' dedup=' + dedupMap.size + ' expand=' + expanded.length + '/' + raw.length);
			    for (const k of expanded) {
			      console.info('[ChangeSrc]  KEPT: origin="' + (k.origin || '') + '"');
			    }
			    return expanded;
	  }

  /** 选择源并返回 */
  onSourceSelect(item: SearchResult): void {
    SourceSwitchStore.selectedSource = item;
    router.back();
  }

  build() {
    Column() {
      // ===== 顶部导航栏 =====
      Row() {
        Button() {
          Text('←').fontSize(18).fontColor(this.isDark ? '#FFF' : '#333')
        }
        .width(40).height(40).backgroundColor('transparent')
        .onClick((): void => { this.searching = false; router.back(); })

        Text('更换书源').fontSize(16).fontWeight(FontWeight.Bold)
          .fontColor(this.isDark ? '#FFF' : '#333')

        Blank()
      }
      .width('100%').padding({ left: 8, right: 8, top: 8 })

      // ===== 过滤 + 刷新 操作行 =====
      Row() {
        // 过滤输入框
        TextInput({ placeholder: '输入文字过滤源...', text: this.filterText })
          .layoutWeight(1).height(36).fontSize(13)
          .borderRadius(18)
          .backgroundColor(this.isDark ? '#333' : '#F5F5F5')
          .fontColor(this.isDark ? '#FFF' : '#333')
          .padding({ left: 12, right: 12 })
          .onChange((value: string) => { this.onFilterChange(value); })

        // 过滤按钮
        Button('🔍').fontSize(14).height(36).width(44).margin({ left: 6 })
          .backgroundColor('#0078D7').fontColor('#FFF').borderRadius(18)
          .onClick(() => { this.applyFilter(); })

        // 刷新按钮（重新搜索）
        Button('🔄').fontSize(14).height(36).width(44).margin({ left: 6 })
          .backgroundColor(this.isDark ? '#555' : '#E0E0E0')
          .fontColor(this.isDark ? '#FFF' : '#333').borderRadius(18)
          .onClick(() => { this.onRefresh(); })
      }
      .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 4 })

      // ===== 状态提示 =====
      if (this.isSearching) {
        Text(this.searchProgress || '搜索中...').fontSize(11).fontColor('#999')
          .width('100%').padding({ left: 16, right: 16, bottom: 4 })
      } else if (this.isFromCache && this.allResults.length > 0) {
        Text('缓存源，点击刷新重新搜索').fontSize(11).fontColor('#999')
          .width('100%').padding({ left: 16, right: 16, bottom: 4 })
      }

      // ===== 源列表 =====
      if (this.isSearching && this.allResults.length === 0) {
        // 搜索中且无缓存结果
        Column() {
          LoadingProgress().width(40).height(40).margin({ top: 30 })
          Text('搜索中...').fontSize(13).fontColor('#999').margin({ top: 8 })
        }.width('100%').layoutWeight(1)
      } else if (this.results.length === 0) {
        Column() {
          Text('没有找到书源').fontSize(14).fontColor('#999').margin({ top: 30 })
          Text(this.isFromCache ? '试试点击刷新重新搜索' : '试试修改过滤词').fontSize(12).fontColor('#CCC').margin({ top: 4 })
        }.width('100%').layoutWeight(1)
      } else {
        List() {
          ForEach(this.results, (item: SearchResult) => {
            ListItem() {
              Row() {
                Column() {
                  Row() {
                    Text(item.origin || '未知').fontSize(14).fontWeight(FontWeight.Medium)
                      .fontColor(item.originUrl === this.sourceOriginUrl ? '#4CAF50' : (this.isDark ? '#FFF' : '#333'))
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    if (item.originUrl === this.sourceOriginUrl) {
                      Text('  当前').fontSize(11).fontColor('#4CAF50')
                    }
                  }.alignSelf(ItemAlign.Start)

                  Text((item.name || '') + ' · ' + (item.author || ''))
                    .fontSize(12).fontColor(this.isDark ? '#AAA' : '#888')
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .alignSelf(ItemAlign.Start).margin({ top: 2 })

                  if (item.wordCount) {
                    Text('字数: ' + item.wordCount).fontSize(11).fontColor('#AAA')
                      .alignSelf(ItemAlign.Start).margin({ top: 2 })
                  }
                }
                .layoutWeight(1).alignItems(HorizontalAlign.Start)
              }
              .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
            }
            .border({ width: { bottom: 0.5 }, color: this.isDark ? '#333' : '#EEEEEE' })
            .onClick(() => { this.onSourceSelect(item); })
          })
        }
        .layoutWeight(1).width('100%')
      }
    }
    .width('100%').height('100%')
    .backgroundColor(this.isDark ? '#121212' : '#F5F5F5')
  }
}
