/**
 * 书源表 — 核心表
 */
import relationalStore from '@ohos.data.relationalStore';
import { BookSource, parseBookSource } from '../../model/BookSource';

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
    rule_explores TEXT DEFAULT '',
    rule_review TEXT DEFAULT '',
    script TEXT DEFAULT '',
    header TEXT DEFAULT '',
    raw_json TEXT DEFAULT '',
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
    const rs = await this.rdbStore.query(predicates, []);
    return this.toSources(rs);
  }

  async getEnabledSources(): Promise<BookSource[]> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.equalTo('enabled', 1);
    predicates.orderByDesc('weight');
    const rs = await this.rdbStore.query(predicates, []);
    return this.toSources(rs);
  }

  async getSourceById(id: number): Promise<BookSource | null> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.equalTo('id', id);
    const rs = await this.rdbStore.query(predicates, []);
    const sources = this.toSources(rs);
    return sources.length > 0 ? sources[0] : null;
  }

  async insertSource(source: BookSource): Promise<number> {
    const row = this.toRow(source);
    return await this.rdbStore.insert(BookSourceTable.TABLE_NAME, row);
  }

  async updateSource(source: BookSource): Promise<void> {
    const row = this.toRow(source);
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.equalTo('id', source.id);
    await this.rdbStore.update(row, predicates);
  }

  async deleteSource(id: number): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.equalTo('id', id);
    await this.rdbStore.delete(predicates);
  }

  async toggleByUrl(url: string, enabled: boolean): Promise<void> {
    const p = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    p.equalTo('source_url', url);
    await this.rdbStore.update({ 'enabled': enabled ? 1 : 0 }, p);
  }

  async deleteByUrl(url: string): Promise<void> {
    const p = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    p.equalTo('source_url', url);
    await this.rdbStore.delete(p);
  }

  async batchDeleteByUrl(urls: string[]): Promise<void> {
    for (const u of urls) await this.deleteByUrl(u);
  }

  async toggleEnabled(id: number, enabled: boolean): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.equalTo('id', id);
    await this.rdbStore.update({ 'enabled': enabled ? 1 : 0 }, predicates);
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
      // 去重
      const exists = await this.getSourceByUrl(source.sourceUrl);
      if (exists) {
        source.id = exists.id;
        await this.updateSource(source);
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
      const exist = await this.getSourceByUrl(src.sourceUrl);
      const status = exist ? ((exist.updateTime || 0) < (src.updateTime || 0) ? 'update' : 'existing') : 'new';
      result.push({ name: src.sourceName, url: src.sourceUrl, status, source: src, rawJson: raw, checked: status !== 'existing' });
    }
    return result;
  }

  async importSelected(items: PreviewItem[], keepName: boolean, keepGroup: boolean, keepEnabled: boolean, customGroup: string): Promise<number> {
    let count = 0;
    for (const item of items) {
      if (!item.checked) continue;
      const src = item.source;
      if (keepName) { const exist = await this.getSourceByUrl(src.sourceUrl); if (exist) src.sourceName = exist.sourceName; }
      if (!keepGroup) src.group = customGroup || src.group;
      if (keepEnabled) { const exist = await this.getSourceByUrl(src.sourceUrl); if (exist) src.enabled = exist.enabled; }
      setSourceRawJson(src, item.rawJson);
      const exist = await this.getSourceByUrl(src.sourceUrl);
      if (exist) { src.id = exist.id; await this.updateSource(src); }
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
    const rs = await this.rdbStore.query(predicates, []);
    return this.toSources(rs);
  }

  async getSourcesByGroup(group: string): Promise<BookSource[]> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.contains('source_group', group);
    predicates.orderByDesc('weight');
    const rs = await this.rdbStore.query(predicates, []);
    return this.toSources(rs);
  }

  async getDisabledSources(): Promise<BookSource[]> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.equalTo('enabled', 0);
    predicates.orderByDesc('weight');
    const rs = await this.rdbStore.query(predicates, []);
    return this.toSources(rs);
  }

  async getNoGroupSources(): Promise<BookSource[]> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.equalTo('source_group', '');
    predicates.or();
    predicates.isNull('source_group');
    predicates.orderByDesc('weight');
    const rs = await this.rdbStore.query(predicates, []);
    return this.toSources(rs);
  }

  async getAllGroups(): Promise<string[]> {
    const sql = 'SELECT DISTINCT source_group FROM ' + BookSourceTable.TABLE_NAME +
      ' WHERE source_group IS NOT NULL AND source_group != \'\' ORDER BY source_group ASC';
    const rs = await this.rdbStore.querySql(sql);
    const groups: string[] = [];
    while (rs.goToNextRow()) {
      const g = rs.getString(0);
      if (g) {
        // 单个书源可能有多个逗号分隔的分组
        const parts = g.split(',').map((s: string) => s.trim()).filter((s: string) => s);
        for (const p of parts) {
          if (!groups.includes(p)) groups.push(p);
        }
      }
    }
    rs.close();
    return groups;
  }

  async batchSetEnabled(ids: number[], enabled: boolean): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.in('id', ids);
    await this.rdbStore.update({ 'enabled': enabled ? 1 : 0 }, predicates);
  }

  async batchDelete(ids: number[]): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.in('id', ids);
    await this.rdbStore.delete(predicates);
  }

  async updateSourceGroup(id: number, group: string): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.equalTo('id', id);
    await this.rdbStore.update({ 'source_group': group }, predicates);
  }

  async batchUpdateGroup(ids: number[], group: string): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.in('id', ids);
    await this.rdbStore.update({ 'source_group': group }, predicates);
  }

  private async getSourceByUrl(url: string): Promise<BookSource | null> {
    const predicates = new relationalStore.RdbPredicates(BookSourceTable.TABLE_NAME);
    predicates.equalTo('source_url', url);
    const rs = await this.rdbStore.query(predicates, []);
    const sources = this.toSources(rs);
    return sources.length > 0 ? sources[0] : null;
  }

  private toSources(rs: relationalStore.ResultSet): BookSource[] {
    const sources: BookSource[] = [];
    while (rs.goToNextRow()) {
      let source: BookSource = {
        id: rs.getLong(rs.getColumnIndex('id')),
        sourceName: rs.getString(rs.getColumnIndex('source_name')) || '',
        sourceUrl: rs.getString(rs.getColumnIndex('source_url')) || '',
        sourceType: rs.getLong(rs.getColumnIndex('source_type')),
        group: rs.getString(rs.getColumnIndex('source_group')) || '',
        enabled: rs.getLong(rs.getColumnIndex('enabled')) === 1,
        weight: rs.getLong(rs.getColumnIndex('weight')),
        customOrder: rs.getLong(rs.getColumnIndex('custom_order')),
        ruleSearchUrl: rs.getString(rs.getColumnIndex('rule_search_url')) || '',
        ruleSearchList: rs.getString(rs.getColumnIndex('rule_search_list')) || '',
        ruleSearchName: rs.getString(rs.getColumnIndex('rule_search_name')) || '',
        ruleSearchAuthor: rs.getString(rs.getColumnIndex('rule_search_author')) || '',
        ruleSearchCover: rs.getString(rs.getColumnIndex('rule_search_cover')) || '',
        ruleSearchNoteUrl: rs.getString(rs.getColumnIndex('rule_search_note_url')) || '',
        ruleSearchKind: rs.getString(rs.getColumnIndex('rule_search_kind')) || '',
        ruleSearchWordCount: rs.getString(rs.getColumnIndex('rule_search_word_count')) || '',
        ruleSearchLastUpdateTime: rs.getString(rs.getColumnIndex('rule_search_last_update_time')) || '',
        ruleSearchIntroduce: rs.getString(rs.getColumnIndex('rule_search_introduce')) || '',
        ruleBookInfoInit: rs.getString(rs.getColumnIndex('rule_book_info_init')) || '',
        ruleBookInfoName: rs.getString(rs.getColumnIndex('rule_book_info_name')) || '',
        ruleBookInfoAuthor: rs.getString(rs.getColumnIndex('rule_book_info_author')) || '',
        ruleBookInfoCover: rs.getString(rs.getColumnIndex('rule_book_info_cover')) || '',
        ruleBookInfoIntroduce: rs.getString(rs.getColumnIndex('rule_book_info_introduce')) || '',
        ruleBookInfoKind: rs.getString(rs.getColumnIndex('rule_book_info_kind')) || '',
        ruleBookInfoWordCount: rs.getString(rs.getColumnIndex('rule_book_info_word_count')) || '',
        ruleBookInfoLastUpdateTime: rs.getString(rs.getColumnIndex('rule_book_info_last_update_time')) || '',
        ruleBookInfoFrom: rs.getString(rs.getColumnIndex('rule_book_info_from')) || '',
        ruleTocUrl: rs.getString(rs.getColumnIndex('rule_toc_url')) || '',
        ruleToc: rs.getString(rs.getColumnIndex('rule_toc')) || '',
        ruleTocTitle: rs.getString(rs.getColumnIndex('rule_toc_title')) || '',
        ruleTocUrlItem: rs.getString(rs.getColumnIndex('rule_toc_url_item')) || '',
        ruleBookContentUrl: rs.getString(rs.getColumnIndex('rule_book_content_url')) || '',
        ruleBookContent: rs.getString(rs.getColumnIndex('rule_book_content')) || '',
        ruleBookContentNext: rs.getString(rs.getColumnIndex('rule_book_content_next')) || '',
        ruleExplores: rs.getString(rs.getColumnIndex('rule_explores')) || '',
        ruleReview: rs.getString(rs.getColumnIndex('rule_review')) || '',
        script: rs.getString(rs.getColumnIndex('script')) || '',
        header: rs.getString(rs.getColumnIndex('header')) || '',
        createTime: rs.getLong(rs.getColumnIndex('create_time')),
        updateTime: rs.getLong(rs.getColumnIndex('update_time')),
      };

      // 如果平铺规则为空，尝试从 raw_json 重新解析嵌套格式
      if (!source.ruleSearchList && !source.ruleSearchName) {
        const rawJson = rs.getString(rs.getColumnIndex('raw_json')) || '';
        if (rawJson) {
          try {
            const parsed = JSON.parse(rawJson);
            const fixed = parseBookSource(parsed);
            if (fixed.ruleSearchList) {
              source.ruleSearchList = fixed.ruleSearchList;
              source.ruleSearchName = fixed.ruleSearchName;
              source.ruleSearchAuthor = fixed.ruleSearchAuthor;
              source.ruleSearchCover = fixed.ruleSearchCover;
              source.ruleSearchNoteUrl = fixed.ruleSearchNoteUrl;
              source.ruleSearchUrl = source.ruleSearchUrl || fixed.ruleSearchUrl;
            }
          } catch (_e) { /* ignore parse errors */ }
        }
      }

      sources.push(source);
    }
    rs.close();
    return sources;
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
      'rule_explores': source.ruleExplores,
      'rule_review': source.ruleReview,
      'script': source.script,
      'header': source.header,
      'raw_json': (source as any).rawJson || '',
      'create_time': source.createTime,
      'update_time': source.updateTime,
    };
  }
}

export function setSourceRawJson(source: BookSource, rawJson: string): void {
  (source as any).rawJson = rawJson;
}
