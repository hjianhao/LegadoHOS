/**
 * 应用数据库 — RDB 初始化与管理
 *
 * 使用 HarmonyOS @ohos.data.relationalStore
 * 对应原 Legado 的 Room + 28 张表的精简版（12 张核心表）
 */
import relationalStore from '@ohos.data.relationalStore';
import { BookTable, BookTableCreate } from './BookTable';
import { ChapterTable, ChapterTableCreate } from './ChapterTable';
import { BookSourceTable, BookSourceTableCreate } from './BookSourceTable';
import { BookmarkTable, BookmarkTableCreate } from './BookmarkTable';
import { ReadRecordTable, ReadRecordTableCreate, ReadRecordDetailTableCreate } from './ReadRecordTable';

import { ReplaceRuleTable, ReplaceRuleTableCreate } from './ReplaceRuleTable';
import { RSSSourceTable, RSSSourceTableCreate, RSSArticleTableCreate } from './RSSSourceTable';

import { CacheTable, CacheTableCreate, TxtTocRuleTable, TxtTocRuleTableCreate } from './CacheTable';

import { SearchResultTable, SearchResultTableCreate } from './SearchResultTable';

const DATABASE_NAME = 'legado_hos.db';
const DATABASE_VERSION = 1;

export class AppDatabase {
  private static instance: AppDatabase;
  private rdbStore_: relationalStore.RdbStore | null = null;
  private initPromise_: Promise<void> | null = null;

  private constructor() {}

  static getInstance(): AppDatabase {
    if (!AppDatabase.instance) {
      AppDatabase.instance = new AppDatabase();
    }
    return AppDatabase.instance;
  }

  get rdbStore(): relationalStore.RdbStore {
    if (!this.rdbStore_) {
      throw new Error('Database not initialized. Call init() first.');
    }
    return this.rdbStore_;
  }

  /**
   * 等待数据库初始化完成（供页面在 aboutToAppear 中调用）
   */
  async waitForInit(): Promise<void> {
    if (this.rdbStore_) {
      return;
    }
    if (!this.initPromise_) {
      throw new Error('Database init not started. Call init() first.');
    }
    await this.initPromise_;
  }

  /**
   * 初始化数据库
   * 在 Application 启动时调用
   */
  async init(context: Context): Promise<void> {
    // 避免重复初始化
    if (this.initPromise_) {
      return this.initPromise_;
    }
    this.initPromise_ = this.doInit(context);
    return this.initPromise_;
  }

  private async doInit(context: Context): Promise<void> {
    const config: relationalStore.StoreConfig = {
      name: DATABASE_NAME,
      securityLevel: relationalStore.SecurityLevel.S1,
    };

    this.rdbStore_ = await relationalStore.getRdbStore(context, config);

    // 建表（仅在首次创建时执行）
    await this.rdbStore_.executeSql(BookTableCreate);
    await this.rdbStore_.executeSql(ChapterTableCreate);
    await this.rdbStore_.executeSql(BookSourceTableCreate);
    await this.rdbStore_.executeSql(BookmarkTableCreate);
    await this.rdbStore_.executeSql(ReadRecordTableCreate);
    await this.rdbStore_.executeSql(ReadRecordDetailTableCreate);
    await this.rdbStore_.executeSql(ReplaceRuleTableCreate);
    await this.rdbStore_.executeSql(RSSSourceTableCreate);
    await this.rdbStore_.executeSql(RSSArticleTableCreate);
    await this.rdbStore_.executeSql(CacheTableCreate);
    await this.rdbStore_.executeSql(TxtTocRuleTableCreate);
    await this.rdbStore_.executeSql(SearchResultTableCreate);

    // 数据库迁移：为已有表添加新列
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN header TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN raw_json TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_search_url TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_search_list TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_search_name TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_search_author TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_search_cover TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_search_note_url TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_search_kind TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_search_word_count TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_search_last_update_time TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_search_introduce TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_book_info_init TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_book_info_name TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_book_info_author TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_book_info_cover TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_book_info_introduce TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_book_info_kind TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_book_info_word_count TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_book_info_last_update_time TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_book_info_from TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_toc_url TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_toc TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_toc_title TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_toc_url_item TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_book_content_url TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_book_content TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_book_content_next TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_explores TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_review TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN script TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE book_sources ADD COLUMN rule_book_info_toc_url TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE search_results ADD COLUMN source_name TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE books ADD COLUMN latest_chapter_title TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }

    // 从 raw_json 重新解析规则字段（适用于已有 raw_json 但缺少规则列的旧数据）
    try { await this.reparseSourceRules(); } catch (_e) { /* 忽略 */ }

    console.info('[AppDatabase] Database initialized successfully');
  }

  /** 从 raw_json 重新解析规则字段，修复旧导入缺少规则列的问题 */
  private async reparseSourceRules(): Promise<void> {
    const rs = await this.rdbStore_.querySql(
      "SELECT id, raw_json FROM book_sources WHERE raw_json IS NOT NULL AND raw_json != '' AND rule_search_url = ''"
    );
    if (rs.rowCount === 0) { rs.close(); return; }
    let fixedCount = 0;
    while (rs.goToNextRow()) {
      const id = rs.getLong(rs.getColumnIndex('id'));
      const rawJson = rs.getString(rs.getColumnIndex('raw_json'));
      if (!rawJson) continue;
      try {
        const obj: Record<string, Object> = JSON.parse(rawJson) as Record<string, Object>;
        const rs2: Record<string, Object> = (obj['ruleSearch'] || {}) as Record<string, Object>;
        const toStr = (val: Object): string => {
          if (typeof val === 'string') return val;
          if (val === null || val === undefined) return '';
          return JSON.stringify(val);
        };
        const bi: Record<string, Object> = (obj['ruleBookInfo'] || {}) as Record<string, Object>;
        const rtc: Record<string, Object> = (obj['ruleToc'] || {}) as Record<string, Object>;
        const rc: Record<string, Object> = (obj['ruleContent'] || {}) as Record<string, Object>;
        const re: Record<string, Object> = (obj['ruleExplore'] || {}) as Record<string, Object>;
        const row: relationalStore.ValuesBucket = {
          'id': id,
          'rule_search_url': toStr(obj['ruleSearchUrl'] || rs2['searchUrl'] || obj['searchUrl'] || ''),
          'rule_search_list': toStr(obj['ruleSearchList'] || rs2['bookList'] || obj['searchList'] || ''),
          'rule_search_name': toStr(obj['ruleSearchName'] || rs2['name'] || ''),
          'rule_search_author': toStr(obj['ruleSearchAuthor'] || rs2['author'] || ''),
          'rule_search_cover': toStr(obj['ruleSearchCover'] || rs2['coverUrl'] || ''),
          'rule_search_note_url': toStr(obj['ruleSearchNoteUrl'] || rs2['bookUrl'] || ''),
          'rule_book_info_init': toStr(obj['ruleBookInfoInit'] || bi['init'] || ''),
          'rule_book_info_name': toStr(obj['ruleBookInfoName'] || bi['name'] || ''),
          'rule_book_info_author': toStr(obj['ruleBookInfoAuthor'] || bi['author'] || ''),
          'rule_book_info_cover': toStr(obj['ruleBookInfoCover'] || bi['coverUrl'] || ''),
          'rule_book_info_introduce': toStr(obj['ruleBookInfoIntroduce'] || bi['intro'] || ''),
          'rule_book_info_toc_url': toStr(obj['ruleBookInfoTocUrl'] || bi['tocUrl'] || obj['tocUrl'] || ''),
          'rule_toc_url': toStr(obj['ruleTocUrl'] || rtc['tocUrl'] || ''),
          'rule_toc': toStr(obj['ruleToc'] || rtc['chapterList'] || ''),
          'rule_toc_title': toStr(obj['ruleTocTitle'] || rtc['chapterName'] || ''),
          'rule_book_content_url': toStr(obj['ruleBookContentUrl'] || rc['contentUrl'] || ''),
          'rule_book_content': toStr(obj['ruleBookContent'] || rc['content'] || ''),
          'rule_explores': toStr(obj['ruleExplores'] || re['bookList'] || obj['exploreUrl'] || ''),
          'header': toStr(obj['header'] || ''),
        };
        const pred = new relationalStore.RdbPredicates('book_sources');
        pred.equalTo('id', id);
        await this.rdbStore_.update(row, pred);
        fixedCount++;
      } catch (_e) { /* 跳过解析失败的行 */ }
    }
    rs.close();
    if (fixedCount > 0) {
      console.info('[AppDatabase] Reparsed ' + fixedCount + ' source rules from raw_json');
    }
  }
}

// 导出所有表
export { BookTable } from './BookTable';
export { ChapterTable } from './ChapterTable';
export { BookSourceTable } from './BookSourceTable';
export { BookmarkTable } from './BookmarkTable';
export { ReadRecordTable } from './ReadRecordTable';

export { ReplaceRuleTable } from './ReplaceRuleTable';
export { RSSSourceTable } from './RSSSourceTable';

export { CacheTable, TxtTocRuleTable } from './CacheTable';

export { SearchResultTable } from './SearchResultTable';
