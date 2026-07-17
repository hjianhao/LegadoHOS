/**
 * 书源表 — 核心表
 */
import relationalStore from '@ohos.data.relationalStore';
import { BookSource, parseBookSource } from '../../model/BookSource';
import { RdbUtil } from './RdbUtil';

export const BookSourceTableCreate = `
  CREATE TABLE IF NOT EXISTS book_sources (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_name TEXT NOT NULL,
    source_url TEXT DEFAULT '',
    source_type INTEGER DEFAULT 0,
    source_group TEXT DEFAULT '',
    enabled INTEGER DEFAULT 1,
    weight INTEGER DEFAULT 0,
    custom_order INTEGER DEFAULT 0,
    rule_search_url TEXT DEFAULT '',
    rule_search_list TEXT DEFAULT '',
    rule_search_name TEXT DEFAULT '',
    rule_search_author TEXT DEFAULT '',
    rule_search_cover TEXT DEFAULT '',
    rule_search_note_url TEXT DEFAULT '',
    rule_search_kind TEXT DEFAULT '',
    rule_search_word_count TEXT DEFAULT '',
    rule_search_last_update_time TEXT DEFAULT '',
    rule_search_introduce TEXT DEFAULT '',
    rule_book_info_init TEXT DEFAULT '',
    rule_book_info_name TEXT DEFAULT '',
    rule_book_info_author TEXT DEFAULT '',
    rule_book_info_cover TEXT DEFAULT '',
    rule_book_info_introduce TEXT DEFAULT '',
    rule_book_info_kind TEXT DEFAULT '',
    rule_book_info_word_count TEXT DEFAULT '',
    rule_book_info_last_update_time TEXT DEFAULT '',
    rule_book_info_from TEXT DEFAULT '',
    rule_toc_url TEXT DEFAULT '',
    rule_toc TEXT DEFAULT '',
    rule_toc_title TEXT DEFAULT '',
    rule_toc_url_item TEXT DEFAULT '',
    rule_book_content_url TEXT DEFAULT '',
    rule_book_content TEXT DEFAULT '',
    rule_book_content_next TEXT DEFAULT '',
    rule_book_content_replace_regex TEXT DEFAULT '',
    rule_explores TEXT DEFAULT '',
    rule_review TEXT DEFAULT '',
    script TEXT DEFAULT '',
    header TEXT DEFAULT '',
    variable_comment TEXT DEFAULT '',
    raw_json TEXT DEFAULT '',
      rule_book_info_toc_url TEXT DEFAULT '',
      cover_decode_js TEXT DEFAULT '',
      is_ai_generated INTEGER DEFAULT 0,
      create_time INTEGER DEFAULT 0,
    update_time INTEGER DEFAULT 0
  );
`;

export interface PreviewItem {
  name: string;
  url: string;
  status: 'new' | 'update' | 'existing';
  source: BookSource;
  rawJson: string;
  checked: boolean;
}

export class BookSourceTable {
  static readonly TABLE_NAME = 'book_sources';
  private rdbStore: relationalStore.RdbStore;

  constructor(rdbStore: relationalStore.RdbStore) {
    this.rdbStore = rdbStore;
  }

  async getAllSources(): Promise<BookSource[]> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.orderByDesc('weight');
    const rs = await RdbUtil.query(this.rdbStore, predicates, []);
    return this.toSources(rs);
  }

  async getEnabledSources(): Promise<BookSource[]> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.equalTo('enabled', 1);
    predicates.orderByDesc('weight');
    const rs = await RdbUtil.query(this.rdbStore, predicates, []);
    return this.toSources(rs);
  }

  async getSourceById(id: number): Promise<BookSource | null> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.equalTo('id', id);
    const rs = await RdbUtil.query(this.rdbStore, predicates, []);
    const sources = this.toSources(rs);
    return sources.length > 0 ? sources[0] : null;
  }

  async insertSource(source: BookSource): Promise<number> {
    const row = this.toRow(source);
    return await RdbUtil.insert(this.rdbStore, BookSourceTable.TABLE_NAME, row);
  }

  async updateSource(source: BookSource): Promise<void> {
    const row = this.toRow(source);
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.equalTo('id', source.id);
    await RdbUtil.update(this.rdbStore, row, predicates);
  }

  async deleteSource(id: number): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.equalTo('id', id);
    await RdbUtil.delete(this.rdbStore, predicates);
  }

  async toggleByUrl(url: string, enabled: boolean): Promise<void> {
    const p = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    p.equalTo('source_url', url);
    await RdbUtil.update(this.rdbStore, { 'enabled': enabled ? 1 : 0 }, p);
  }

  async deleteByUrl(url: string): Promise<void> {
    const p = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    p.equalTo('source_url', url);
    await RdbUtil.delete(this.rdbStore, p);
  }

  async batchDeleteByUrl(urls: string[]): Promise<void> {
    for (const u of urls) await this.deleteByUrl(u);
  }

  async toggleEnabled(id: number, enabled: boolean): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.equalTo('id', id);
    await RdbUtil.update(this.rdbStore, { 'enabled': enabled ? 1 : 0 }, predicates);
  }

  async importSources(jsonSources: string): Promise<number> {
    let sources: object[];
    const parsed = JSON.parse(jsonSources);
    if (Array.isArray(parsed)) {
      sources = parsed;
    } else {
      sources = [parsed];  // 单个对象自动包成数组
    }
    let count = 0;
    for (let i = 0; i < sources.length; i++) {
      const s = sources[i];
      const rawJson = JSON.stringify(s); // 保存原始 JSON 用于后续重新解析
      const source = parseBookSource(s);
      setSourceRawJson(source, rawJson);
      const existing = await this.getSourcesForImport(source.sourceUrl, source.sourceName);
      if (existing.length > 0) {
        const canonical = existing[0];
        source.id = canonical.id;
        source.variableComment = source.variableComment || this.pickVariable(existing);
        await this.updateSource(source);
        await this.deleteDuplicateSources(existing, canonical.id, source.sourceUrl);
      } else {
        await this.insertSource(source);
      }
      count++;
    }
    return count;
  }

  async exportSources(): Promise<string> {
    const sources = await this.getAllSources();
    return JSON.stringify(sources.map(s => ({
      bookSourceName: s.sourceName,
      bookSourceUrl: s.sourceUrl,
      sourceType: s.sourceType,
      group: s.group,
      enabled: s.enabled,
      weight: s.weight,
      ruleSearchUrl: s.ruleSearchUrl,
      ruleSearchList: s.ruleSearchList,
      ruleSearchName: s.ruleSearchName,
      ruleSearchAuthor: s.ruleSearchAuthor,
      ruleSearchCover: s.ruleSearchCover,
      ruleSearchNoteUrl: s.ruleSearchNoteUrl,
      ruleBookInfoInit: s.ruleBookInfoInit,
      ruleBookInfoName: s.ruleBookInfoName,
      ruleBookInfoAuthor: s.ruleBookInfoAuthor,
      ruleBookInfoCover: s.ruleBookInfoCover,
      ruleBookInfoIntroduce: s.ruleBookInfoIntroduce,
      ruleTocUrl: s.ruleTocUrl,
      ruleToc: s.ruleToc,
      ruleBookContentUrl: s.ruleBookContentUrl,
      ruleBookContent: s.ruleBookContent,
      ruleExplores: s.ruleExplores,
      script: s.script,
    })), null, 2);
  }

  // ---- 预览式导入 ----

  async importSourcesPreview(jsonText: string): Promise<PreviewItem[]> {
    const parsed = JSON.parse(jsonText);
    const arr = Array.isArray(parsed) ? parsed : [parsed];
    const result: PreviewItem[] = [];
    for (let i = 0; i < arr.length; i++) {
      const src = parseBookSource(arr[i]);
      const raw = JSON.stringify(arr[i]);
      const existing = await this.getSourcesForImport(src.sourceUrl, src.sourceName);
      const status = existing.length > 0 ? 'update' : 'new';
      result.push({ name: src.sourceName, url: src.sourceUrl, status, source: src, rawJson: raw, checked: true });
    }
    return result;
  }

  async importSelected(items: PreviewItem[], keepName: boolean, keepGroup: boolean, keepEnabled: boolean, customGroup: string): Promise<number> {
    let count = 0;
    for (const item of items) {
      if (!item.checked) continue;
      const src = item.source;
      const existing = await this.getSourcesForImport(src.sourceUrl, src.sourceName);
      const canonical = existing.length > 0 ? existing[0] : null;
      if (canonical && keepName) src.sourceName = canonical.sourceName;
      if (canonical && keepGroup) src.group = canonical.group;
      else if (!keepGroup) src.group = customGroup || src.group;
      if (canonical && keepEnabled) src.enabled = canonical.enabled;
      setSourceRawJson(src, item.rawJson);
      if (canonical) {
        src.id = canonical.id;
        src.variableComment = src.variableComment || this.pickVariable(existing);
        await this.updateSource(src);
        await this.deleteDuplicateSources(existing, canonical.id, src.sourceUrl);
      }
      else { await this.insertSource(src); }
      count++;
    }
    return count;
  }

  // ---- 搜索与过滤 ----

  async searchSources(keyword: string): Promise<BookSource[]> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.contains('source_name', keyword);
    predicates.or();
    predicates.contains('source_url', keyword);
    predicates.orderByDesc('weight');
    const rs = await RdbUtil.query(this.rdbStore, predicates, []);
    return this.toSources(rs);
  }

  async getSourcesByGroup(group: string): Promise<BookSource[]> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.contains('source_group', group);
    predicates.orderByDesc('weight');
    const rs = await RdbUtil.query(this.rdbStore, predicates, []);
    return this.toSources(rs);
  }

  async getDisabledSources(): Promise<BookSource[]> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.equalTo('enabled', 0);
    predicates.orderByDesc('weight');
    const rs = await RdbUtil.query(this.rdbStore, predicates, []);
    return this.toSources(rs);
  }

  async getNoGroupSources(): Promise<BookSource[]> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.equalTo('source_group', '');
    predicates.or();
    predicates.isNull('source_group');
    predicates.orderByDesc('weight');
    const rs = await RdbUtil.query(this.rdbStore, predicates, []);
    return this.toSources(rs);
  }

  async getAllGroups(): Promise<string[]> {
    const sql = 'SELECT DISTINCT source_group FROM ' + BookSourceTable.TABLE_NAME +
      ' WHERE source_group IS NOT NULL AND source_group != \'\' ORDER BY source_group ASC';
    const rs = await RdbUtil.querySql(this.rdbStore, sql);
    const groups: string[] = [];
    while (RdbUtil.next(rs)) {
      const g = RdbUtil.stringAt(rs, 0);
      if (g) {
        // 单个书源可能有多个逗号分隔的分组
        const parts = g.split(',').map((s: string) => s.trim()).filter((s: string) => s);
        for (const p of parts) {
          if (!groups.includes(p)) groups.push(p);
        }
      }
    }
    RdbUtil.close(rs);
    return groups;
  }

  async batchSetEnabled(ids: number[], enabled: boolean): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.in('id', ids);
    await RdbUtil.update(this.rdbStore, { 'enabled': enabled ? 1 : 0 }, predicates);
  }

  async batchDelete(ids: number[]): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.in('id', ids);
    await RdbUtil.delete(this.rdbStore, predicates);
  }

  async updateSourceGroup(id: number, group: string): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.equalTo('id', id);
    await RdbUtil.update(this.rdbStore, { 'source_group': group }, predicates);
  }

  async batchUpdateGroup(ids: number[], group: string): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.in('id', ids);
    await RdbUtil.update(this.rdbStore, { 'source_group': group }, predicates);
  }

  async getSourceByUrl(url: string): Promise<BookSource | null> {
    const sources = await this.getSourcesByUrl(url);
    return sources.length > 0 ? sources[0] : null;
  }

  /** 返回同 URL 的全部记录，最早创建的记录作为更新时的主记录。 */
  async getSourcesByUrl(url: string): Promise<BookSource[]> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.equalTo('source_url', url);
    predicates.orderByAsc('id');
    const rs = await RdbUtil.query(this.rdbStore, predicates, []);
    return this.toSources(rs);
  }

  /**
   * 更新导入先按 URL 匹配，并将同名的旧 URL 记录一并纳入合并范围。
   * 书源换线路时 bookSourceUrl 本身也会变化，仅按新 URL 无法更新旧记录。
   */
  private async getSourcesForImport(url: string, name: string): Promise<BookSource[]> {
    const byUrl = await this.getSourcesByUrl(url);
    if (!name) return byUrl;
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.equalTo('source_name', name);
    predicates.orderByAsc('id');
    const byName = this.toSources(await RdbUtil.query(this.rdbStore, predicates, []));
    const merged: BookSource[] = [];
    const ids = new Set<number>();
    for (const source of [...byUrl, ...byName]) {
      if (ids.has(source.id)) continue;
      ids.add(source.id);
      merged.push(source);
    }
    merged.sort((a: BookSource, b: BookSource) => a.id - b.id);
    return merged;
  }

  private pickVariable(sources: BookSource[]): string {
    for (const source of sources) {
      if (source.variableComment) return source.variableComment;
    }
    return '';
  }

  private async deleteDuplicateSources(sources: BookSource[], canonicalId: number, sourceUrl: string): Promise<void> {
    let removed = 0;
    for (const source of sources) {
      if (source.id === canonicalId) continue;
      await this.deleteSource(source.id);
      removed++;
    }
    if (removed > 0) {
      console.info('[BookSourceTable] Removed', removed, 'duplicate source records for', sourceUrl);
    }
  }

  /** 持久化 source.getVariable()/setVariable() 对应的书源变量。 */
  async updateVariable(id: number, sourceUrl: string, variable: string): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    if (id > 0) predicates.equalTo('id', id);
    else predicates.equalTo('source_url', sourceUrl);
    await RdbUtil.update(this.rdbStore, {
      'variable_comment': variable,
      'update_time': Date.now(),
    }, predicates);
  }

  private toSources(rs: relationalStore.ResultSet): BookSource[] {
    const sources: BookSource[] = [];
    while (RdbUtil.next(rs)) {
      let source: BookSource = {
        id: RdbUtil.long(rs, 'id'),
        sourceName: RdbUtil.string(rs, 'source_name') || '',
        sourceUrl: RdbUtil.string(rs, 'source_url') || '',
        sourceType: RdbUtil.long(rs, 'source_type'),
        group: RdbUtil.string(rs, 'source_group') || '',
        enabled: RdbUtil.long(rs, 'enabled') === 1,
        weight: RdbUtil.long(rs, 'weight'),
        customOrder: RdbUtil.long(rs, 'custom_order'),
        ruleSearchUrl: RdbUtil.string(rs, 'rule_search_url') || '',
        ruleSearchList: RdbUtil.string(rs, 'rule_search_list') || '',
        ruleSearchName: RdbUtil.string(rs, 'rule_search_name') || '',
        ruleSearchAuthor: RdbUtil.string(rs, 'rule_search_author') || '',
        ruleSearchCover: RdbUtil.string(rs, 'rule_search_cover') || '',
        ruleSearchNoteUrl: RdbUtil.string(rs, 'rule_search_note_url') || '',
        ruleSearchKind: RdbUtil.string(rs, 'rule_search_kind') || '',
        ruleSearchWordCount: RdbUtil.string(rs, 'rule_search_word_count') || '',
        ruleSearchLastUpdateTime: RdbUtil.string(rs, 'rule_search_last_update_time') || '',
        ruleSearchIntroduce: RdbUtil.string(rs, 'rule_search_introduce') || '',
        ruleBookInfoInit: RdbUtil.string(rs, 'rule_book_info_init') || '',
        ruleBookInfoName: RdbUtil.string(rs, 'rule_book_info_name') || '',
        ruleBookInfoAuthor: RdbUtil.string(rs, 'rule_book_info_author') || '',
        ruleBookInfoCover: RdbUtil.string(rs, 'rule_book_info_cover') || '',
        ruleBookInfoIntroduce: RdbUtil.string(rs, 'rule_book_info_introduce') || '',
        ruleBookInfoKind: RdbUtil.string(rs, 'rule_book_info_kind') || '',
        ruleBookInfoWordCount: RdbUtil.string(rs, 'rule_book_info_word_count') || '',
        ruleBookInfoLastUpdateTime: RdbUtil.string(rs, 'rule_book_info_last_update_time') || '',
        ruleBookInfoFrom: RdbUtil.string(rs, 'rule_book_info_from') || '',
        ruleTocUrl: RdbUtil.string(rs, 'rule_toc_url') || '',
        ruleToc: RdbUtil.string(rs, 'rule_toc') || '',
        ruleTocTitle: RdbUtil.string(rs, 'rule_toc_title') || '',
        ruleTocUrlItem: RdbUtil.string(rs, 'rule_toc_url_item') || '',
        ruleBookContentUrl: RdbUtil.string(rs, 'rule_book_content_url') || '',
        ruleBookContent: RdbUtil.string(rs, 'rule_book_content') || '',
        ruleBookContentNext: RdbUtil.string(rs, 'rule_book_content_next') || '',
        ruleBookContentReplaceRegex: RdbUtil.string(rs, 'rule_book_content_replace_regex') || '',
        ruleExplores: RdbUtil.string(rs, 'rule_explores') || '',
        ruleReview: RdbUtil.string(rs, 'rule_review') || '',
        script: RdbUtil.string(rs, 'script') || '',
        header: RdbUtil.string(rs, 'header') || '',
        ruleBookInfoTocUrl: RdbUtil.string(rs, 'rule_book_info_toc_url') || '',
        createTime: RdbUtil.long(rs, 'create_time'),
        updateTime: RdbUtil.long(rs, 'update_time'),
        ruleSearchCheckKeyWord: '',
        ruleSearchLastChapter: '',
        ruleBookInfoLastChapter: '',
        ruleBookInfoCanReName: '',
        ruleBookInfoDownloadUrls: '',
        ruleBookInfoRelatedBooks: '',
        ruleTocPreUpdateJs: '',
        ruleTocFormatJs: '',
        ruleTocIsVolume: '',
        ruleTocIsVip: '',
        ruleTocIsPay: '',
        ruleTocUpdateTime: '',
        ruleTocNextTocUrl: '',
        ruleBookContentSubContent: '',
        ruleBookContentTitle: '',
        ruleBookContentWebJs: '',
        ruleBookContentSourceRegex: '',
        ruleBookContentImageStyle: '',
        ruleBookContentImageDecode: '',
        ruleBookContentPayAction: '',
        ruleBookContentCallBackJs: '',
        respondTime: 0,
        concurrentRate: '',
        bookSourceComment: '',
        variableComment: RdbUtil.string(rs, 'variable_comment') || '',
        coverDecodeJs: RdbUtil.string(rs, 'cover_decode_js') || '',
        loginUrl: '',
        loginCheckJs: '',
        jsLib: '',
        bookUrlPattern: '',
        respond: 0,
        ruleExploreScreen: '',
        ruleExploreList: '',
        ruleExploreName: '',
        ruleExploreAuthor: '',
        ruleExploreCover: '',
        ruleExploreKind: '',
        ruleExploreWordCount: '',
        ruleExploreLastChapter: '',
        ruleExploreLastUpdateTime: '',
        ruleExploreNoteUrl: '',
        ruleExploreIntroduce: '',
        exploreUrl: '',
        loginUi: '',
        eventListener: false,
        customButton: false,
        homepageModules: '',
        enabledCookieJar: true,
        enabledExplore: true,
        exploreScreen: '',
        review: '',
        reviewUrl: '',
        reviewAvatar: '',
        reviewContent: '',
        reviewPostTime: '',
        reviewQuoteUrl: '',
        ruleReviewUrl: '',
        ruleReviewAvatar: '',
        ruleReviewContent: '',
        ruleReviewPostTime: '',
        ruleReviewQuoteUrl: '',
        rawJson: '',
        isAiGenerated: RdbUtil.long(rs, 'is_ai_generated') === 1,
      };

      // 从 raw_json 恢复完整数据
      const rawJson = RdbUtil.string(rs, 'raw_json') || '';
      if (rawJson) {
        source.rawJson = rawJson;
        try {
          const parsed = JSON.parse(rawJson);
          const fixed = parseBookSource(parsed);
          this.restoreRawOnlyFields(source, fixed);
          // 恢复 jsLib（聚合书源的核心脚本）
          if (fixed.jsLib) source.jsLib = fixed.jsLib;
          // 恢复 loginUrl（禁漫天堂等源依赖 loginUrl 初始化书源变量）
          if (fixed.loginUrl) source.loginUrl = fixed.loginUrl;
          if (fixed.loginCheckJs) source.loginCheckJs = fixed.loginCheckJs;
          if (fixed.loginUi) source.loginUi = fixed.loginUi;
          source.customButton = fixed.customButton;
          // 恢复 exploreUrl
          if (fixed.exploreUrl && !source.exploreUrl) {
            source.exploreUrl = fixed.exploreUrl;
          }
          // 如果有平铺规则为空，从嵌套格式恢复
          if (!source.ruleSearchList && !source.ruleSearchName && fixed.ruleSearchList) {
            source.ruleSearchList = fixed.ruleSearchList;
            source.ruleSearchName = fixed.ruleSearchName;
            source.ruleSearchAuthor = fixed.ruleSearchAuthor;
            source.ruleSearchCover = fixed.ruleSearchCover;
            source.ruleSearchNoteUrl = fixed.ruleSearchNoteUrl;
            source.ruleSearchUrl = source.ruleSearchUrl || fixed.ruleSearchUrl;
          }
          if (!source.ruleSearchKind) source.ruleSearchKind = fixed.ruleSearchKind;
          if (!source.ruleSearchWordCount) source.ruleSearchWordCount = fixed.ruleSearchWordCount;
          if (!source.ruleSearchLastUpdateTime) source.ruleSearchLastUpdateTime = fixed.ruleSearchLastUpdateTime;
          if (!source.ruleSearchIntroduce) source.ruleSearchIntroduce = fixed.ruleSearchIntroduce;
          source.ruleSearchLastChapter = fixed.ruleSearchLastChapter;
          if (!source.ruleBookInfoName) source.ruleBookInfoName = fixed.ruleBookInfoName;
          if (!source.ruleBookInfoAuthor) source.ruleBookInfoAuthor = fixed.ruleBookInfoAuthor;
          if (!source.ruleBookInfoCover) source.ruleBookInfoCover = fixed.ruleBookInfoCover;
          if (!source.ruleBookInfoIntroduce) source.ruleBookInfoIntroduce = fixed.ruleBookInfoIntroduce;
          if (!source.ruleBookInfoKind) source.ruleBookInfoKind = fixed.ruleBookInfoKind;
          if (!source.ruleBookInfoWordCount) source.ruleBookInfoWordCount = fixed.ruleBookInfoWordCount;
          if (!source.ruleBookInfoLastUpdateTime) source.ruleBookInfoLastUpdateTime = fixed.ruleBookInfoLastUpdateTime;
          if (!source.ruleBookInfoTocUrl) source.ruleBookInfoTocUrl = fixed.ruleBookInfoTocUrl;
          source.ruleBookInfoLastChapter = fixed.ruleBookInfoLastChapter;
          source.ruleTocNextTocUrl = fixed.ruleTocNextTocUrl;
          source.ruleBookContentReplaceRegex = fixed.ruleBookContentReplaceRegex;
          if (!source.ruleBookContentNext) source.ruleBookContentNext = fixed.ruleBookContentNext;
	          // 恢复 ruleExplore*（发现页规则）
	          if (fixed.ruleExploreList && !source.ruleExploreList) {
	            source.ruleExploreList = fixed.ruleExploreList;
	            source.ruleExploreName = fixed.ruleExploreName;
	            source.ruleExploreAuthor = fixed.ruleExploreAuthor;
	            source.ruleExploreCover = fixed.ruleExploreCover;
	            source.ruleExploreKind = fixed.ruleExploreKind;
	            source.ruleExploreWordCount = fixed.ruleExploreWordCount;
	            source.ruleExploreLastChapter = fixed.ruleExploreLastChapter;
	            source.ruleExploreLastUpdateTime = fixed.ruleExploreLastUpdateTime;
	            source.ruleExploreNoteUrl = fixed.ruleExploreNoteUrl;
	            source.ruleExploreIntroduce = fixed.ruleExploreIntroduce;
	          }
	          // 恢复 bookSourceComment（书源注释，包含可执行 JS 如 筛选="普通"）
	          if (fixed.bookSourceComment) source.bookSourceComment = fixed.bookSourceComment;
	        } catch (_e) { /* ignore parse errors */ }
      }

      sources.push(source);
    }
    RdbUtil.close(rs);
    return sources;
  }

  /**
   * 数据库未拆列的 Legado 扩展字段以 raw_json 为准恢复。
   * 必须包含 false/0/空字符串，更新导入才能真正清除旧配置而不是继续沿用默认值。
   */
  private restoreRawOnlyFields(source: BookSource, raw: BookSource): void {
    source.ruleSearchCheckKeyWord = raw.ruleSearchCheckKeyWord;
    source.ruleSearchLastChapter = raw.ruleSearchLastChapter;
    source.ruleBookInfoLastChapter = raw.ruleBookInfoLastChapter;
    source.ruleBookInfoCanReName = raw.ruleBookInfoCanReName;
    source.ruleBookInfoDownloadUrls = raw.ruleBookInfoDownloadUrls;
    source.ruleBookInfoRelatedBooks = raw.ruleBookInfoRelatedBooks;
    source.ruleTocPreUpdateJs = raw.ruleTocPreUpdateJs;
    source.ruleTocFormatJs = raw.ruleTocFormatJs;
    source.ruleTocIsVolume = raw.ruleTocIsVolume;
    source.ruleTocIsVip = raw.ruleTocIsVip;
    source.ruleTocIsPay = raw.ruleTocIsPay;
    source.ruleTocUpdateTime = raw.ruleTocUpdateTime;
    source.ruleTocNextTocUrl = raw.ruleTocNextTocUrl;
    source.ruleBookContentSubContent = raw.ruleBookContentSubContent;
    source.ruleBookContentTitle = raw.ruleBookContentTitle;
    source.ruleBookContentWebJs = raw.ruleBookContentWebJs;
    source.ruleBookContentSourceRegex = raw.ruleBookContentSourceRegex;
    source.ruleBookContentImageStyle = raw.ruleBookContentImageStyle;
    source.ruleBookContentImageDecode = raw.ruleBookContentImageDecode;
    source.ruleBookContentPayAction = raw.ruleBookContentPayAction;
    source.ruleBookContentCallBackJs = raw.ruleBookContentCallBackJs;
    source.respondTime = raw.respondTime;
    source.concurrentRate = raw.concurrentRate;
    source.bookSourceComment = raw.bookSourceComment;
    source.loginUrl = raw.loginUrl;
    source.loginCheckJs = raw.loginCheckJs;
    source.jsLib = raw.jsLib;
    source.bookUrlPattern = raw.bookUrlPattern;
    source.respond = raw.respond;
    source.ruleExploreScreen = raw.ruleExploreScreen;
    source.ruleExploreList = raw.ruleExploreList;
    source.ruleExploreName = raw.ruleExploreName;
    source.ruleExploreAuthor = raw.ruleExploreAuthor;
    source.ruleExploreCover = raw.ruleExploreCover;
    source.ruleExploreKind = raw.ruleExploreKind;
    source.ruleExploreWordCount = raw.ruleExploreWordCount;
    source.ruleExploreLastChapter = raw.ruleExploreLastChapter;
    source.ruleExploreLastUpdateTime = raw.ruleExploreLastUpdateTime;
    source.ruleExploreNoteUrl = raw.ruleExploreNoteUrl;
    source.ruleExploreIntroduce = raw.ruleExploreIntroduce;
    source.exploreUrl = raw.exploreUrl;
    source.loginUi = raw.loginUi;
    source.eventListener = raw.eventListener;
    source.customButton = raw.customButton;
    source.homepageModules = raw.homepageModules;
    source.enabledCookieJar = raw.enabledCookieJar;
    source.enabledExplore = raw.enabledExplore;
    source.exploreScreen = raw.exploreScreen;
    source.review = raw.review;
    source.reviewUrl = raw.reviewUrl;
    source.reviewAvatar = raw.reviewAvatar;
    source.reviewContent = raw.reviewContent;
    source.reviewPostTime = raw.reviewPostTime;
    source.reviewQuoteUrl = raw.reviewQuoteUrl;
    source.ruleReviewUrl = raw.ruleReviewUrl;
    source.ruleReviewAvatar = raw.ruleReviewAvatar;
    source.ruleReviewContent = raw.ruleReviewContent;
    source.ruleReviewPostTime = raw.ruleReviewPostTime;
    source.ruleReviewQuoteUrl = raw.ruleReviewQuoteUrl;
  }

  private toRow(source: BookSource): relationalStore.ValuesBucket {
    return {
      'source_name': source.sourceName,
      'source_url': source.sourceUrl,
      'source_type': source.sourceType,
      'source_group': source.group,
      'enabled': source.enabled ? 1 : 0,
      'weight': source.weight,
      'custom_order': source.customOrder,
      'rule_search_url': source.ruleSearchUrl,
      'rule_search_list': source.ruleSearchList,
      'rule_search_name': source.ruleSearchName,
      'rule_search_author': source.ruleSearchAuthor,
      'rule_search_cover': source.ruleSearchCover,
      'rule_search_note_url': source.ruleSearchNoteUrl,
      'rule_search_kind': source.ruleSearchKind,
      'rule_search_word_count': source.ruleSearchWordCount,
      'rule_search_last_update_time': source.ruleSearchLastUpdateTime,
      'rule_search_introduce': source.ruleSearchIntroduce,
      'rule_book_info_init': source.ruleBookInfoInit,
      'rule_book_info_name': source.ruleBookInfoName,
      'rule_book_info_author': source.ruleBookInfoAuthor,
      'rule_book_info_cover': source.ruleBookInfoCover,
      'rule_book_info_introduce': source.ruleBookInfoIntroduce,
      'rule_book_info_kind': source.ruleBookInfoKind,
      'rule_book_info_word_count': source.ruleBookInfoWordCount,
      'rule_book_info_last_update_time': source.ruleBookInfoLastUpdateTime,
      'rule_book_info_from': source.ruleBookInfoFrom,
      'rule_toc_url': source.ruleTocUrl,
      'rule_toc': source.ruleToc,
      'rule_toc_title': source.ruleTocTitle,
      'rule_toc_url_item': source.ruleTocUrlItem,
      'rule_book_content_url': source.ruleBookContentUrl,
      'rule_book_content': source.ruleBookContent,
      'rule_book_content_next': source.ruleBookContentNext,
      'rule_book_content_replace_regex': source.ruleBookContentReplaceRegex,
      'rule_explores': source.ruleExplores,
      'rule_review': source.ruleReview,
      'script': source.script,
      'header': source.header,
      'variable_comment': source.variableComment || '',
      'raw_json': (source as any).rawJson || '',
      'rule_book_info_toc_url': source.ruleBookInfoTocUrl,
      'cover_decode_js': source.coverDecodeJs || '',
      'is_ai_generated': source.isAiGenerated ? 1 : 0,
      'create_time': source.createTime,
      'update_time': source.updateTime,
    };
  }
}

export function setSourceRawJson(source: BookSource, rawJson: string): void {
  (source as any).rawJson = rawJson;
}
