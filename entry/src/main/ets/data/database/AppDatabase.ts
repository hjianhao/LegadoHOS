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
import { RSSSourceTable, RSSSourceTableCreate, RSSArticleTableCreate, RSSArticleTable, RssStarTable } from './RSSSourceTable';

import { CacheTable, CacheTableCreate, TxtTocRuleTable, TxtTocRuleTableCreate } from './CacheTable';

import { SearchResultTable, SearchResultTableCreate } from './SearchResultTable';
import { SearchKeywordTable, SearchKeywordTableCreate } from './SearchKeywordTable';
import { RdbUtil } from './RdbUtil';

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

  get rssSourceTable(): RSSSourceTable {
    return new RSSSourceTable(this.rdbStore);
  }

  get rssArticleTable(): RSSArticleTable {
    return new RSSArticleTable(this.rdbStore);
  }

  get rssStarTable(): RssStarTable {
    return new RssStarTable(this.rdbStore);
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

    this.rdbStore_ = await RdbUtil.getRdbStore(context, config);

    // 建表（仅在首次创建时执行）
    await RdbUtil.executeSql(this.rdbStore_, BookTableCreate);
    await RdbUtil.executeSql(this.rdbStore_, ChapterTableCreate);
    await RdbUtil.executeSql(this.rdbStore_, BookSourceTableCreate);
    await RdbUtil.executeSql(this.rdbStore_, BookmarkTableCreate);
    await RdbUtil.executeSql(this.rdbStore_, ReadRecordTableCreate);
    await RdbUtil.executeSql(this.rdbStore_, ReadRecordDetailTableCreate);
    await RdbUtil.executeSql(this.rdbStore_, ReplaceRuleTableCreate);
    await RdbUtil.executeSql(this.rdbStore_, RSSSourceTableCreate);
    await RdbUtil.executeSql(this.rdbStore_, RSSArticleTableCreate);
    await RdbUtil.executeSql(this.rdbStore_, CacheTableCreate);
    await RdbUtil.executeSql(this.rdbStore_, TxtTocRuleTableCreate);
    await RdbUtil.executeSql(this.rdbStore_, SearchResultTableCreate);
    await RdbUtil.executeSql(this.rdbStore_, SearchKeywordTableCreate);

    // 数据库迁移：为已有表添加新列
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN header TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN raw_json TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_search_url TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_search_list TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_search_name TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_search_author TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_search_cover TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_search_note_url TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_search_kind TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_search_word_count TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_search_last_update_time TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_search_introduce TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_book_info_init TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_book_info_name TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_book_info_author TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN is_ai_generated INTEGER DEFAULT 0"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN create_time INTEGER DEFAULT 0"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN update_time INTEGER DEFAULT 0"); } catch (_e) { /* 列已存在 */ }
    // books 表迁移
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE books ADD COLUMN can_update INTEGER DEFAULT 1"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_book_info_cover TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_book_info_introduce TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_book_info_kind TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_book_info_word_count TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_book_info_last_update_time TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_book_info_from TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_toc_url TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_toc TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_toc_title TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_toc_url_item TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_book_content_url TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_book_content TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_book_content_next TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_explores TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_review TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN script TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_book_info_toc_url TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE search_results ADD COLUMN source_name TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE books ADD COLUMN latest_chapter_title TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE books ADD COLUMN remark TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE books ADD COLUMN sync_time INTEGER DEFAULT 0"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_book_content_replace_regex TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN cover_decode_js TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN variable_comment TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }

    // 从 raw_json 重新解析规则字段（适用于已有 raw_json 但缺少规则列的旧数据）
    try { await this.reparseSourceRules(); } catch (_e) { /* 忽略 */ }

    console.info('[AppDatabase] Database initialized successfully');
  }

  /** 从 raw_json 重新解析规则字段，修复旧导入缺少规则列的问题 */
  private async reparseSourceRules(): Promise<void> {
    const rs = await RdbUtil.querySql(this.rdbStore_,
      "SELECT id, raw_json FROM book_sources WHERE raw_json IS NOT NULL AND raw_json != ''"
    );
    if (rs.rowCount === 0) { RdbUtil.close(rs); return; }
    let fixedCount = 0;
    while (RdbUtil.next(rs)) {
      const id = RdbUtil.long(rs, 'id');
      const rawJson = RdbUtil.string(rs, 'raw_json');
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
        const row: relationalStore.ValuesBucket = {
          'id': id,
          'rule_search_url': toStr(obj['ruleSearchUrl'] || rs2['searchUrl'] || obj['searchUrl'] || ''),
          'rule_search_list': toStr(obj['ruleSearchList'] || rs2['bookList'] || obj['searchList'] || ''),
          'rule_search_name': toStr(obj['ruleSearchName'] || rs2['name'] || ''),
          'rule_search_author': toStr(obj['ruleSearchAuthor'] || rs2['author'] || ''),
          'rule_search_cover': toStr(obj['ruleSearchCover'] || rs2['coverUrl'] || ''),
          'rule_search_note_url': toStr(obj['ruleSearchNoteUrl'] || rs2['bookUrl'] || ''),
          'rule_search_kind': toStr(obj['ruleSearchKind'] || rs2['kind'] || ''),
          'rule_search_word_count': toStr(obj['ruleSearchWordCount'] || rs2['wordCount'] || ''),
          'rule_search_last_update_time': toStr(obj['ruleSearchLastUpdateTime'] || rs2['lastUpdateTime'] || ''),
          'rule_search_introduce': toStr(obj['ruleSearchIntroduce'] || rs2['intro'] || rs2['introduce'] || ''),
          'rule_book_info_init': toStr(obj['ruleBookInfoInit'] || bi['init'] || ''),
          'rule_book_info_name': toStr(obj['ruleBookInfoName'] || bi['name'] || ''),
          'rule_book_info_author': toStr(obj['ruleBookInfoAuthor'] || bi['author'] || ''),
          'rule_book_info_cover': toStr(obj['ruleBookInfoCover'] || bi['coverUrl'] || ''),
          'rule_book_info_introduce': toStr(obj['ruleBookInfoIntroduce'] || bi['intro'] || ''),
          'rule_book_info_kind': toStr(obj['ruleBookInfoKind'] || bi['kind'] || ''),
          'rule_book_info_word_count': toStr(obj['ruleBookInfoWordCount'] || bi['wordCount'] || ''),
          'rule_book_info_last_update_time': toStr(obj['ruleBookInfoLastUpdateTime'] || bi['lastUpdateTime'] || ''),
          'rule_book_info_toc_url': toStr(obj['ruleBookInfoTocUrl'] || bi['tocUrl'] || obj['tocUrl'] || ''),
          'rule_toc_url': toStr(obj['ruleTocUrl'] || rtc['tocUrl'] || ''),
          'rule_toc': toStr(typeof obj['ruleToc'] === 'object' ? (obj['ruleToc'] as Record<string, Object>)['chapterList'] || '' : obj['ruleToc'] || rtc['chapterList'] || ''),
          'rule_toc_title': toStr(obj['ruleTocTitle'] || rtc['chapterName'] || ''),
          'rule_toc_url_item': toStr(obj['ruleTocUrlItem'] || rtc['chapterUrl'] || ''),
          'rule_book_content_url': toStr(obj['ruleBookContentUrl'] || rc['contentUrl'] || ''),
          'rule_book_content': (() => {
            const rbcRaw = obj['ruleBookContent'] || rc['content'] || '';
            let rbc = typeof rbcRaw === 'string' ? rbcRaw : JSON.stringify(rbcRaw);
            // 修复狗狗书籍：textNodes 无法提取 <br/> 分段内容，改用 html
            if (rbc === 'id.content@textNodes' && toStr(obj['bookSourceUrl']) === 'http://www.qiushu.info') {
              rbc = 'id.content@html';
            }
            return rbc;
          })(),
          'rule_book_content_next': toStr(obj['ruleBookContentNext'] || rc['nextContentUrl'] || ''),
          'rule_book_content_replace_regex': (() => {
            let regex = toStr(obj['ruleBookContentReplaceRegex'] || rc['replaceRegex'] || '');
            // 狗狗书籍默认清洗规则（<br> → 换行 + 垃圾过滤）
            if (!regex && toStr(obj['bookSourceUrl']) === 'http://www.qiushu.info') {
              regex = '##<br\\s*\\/?>|\\n\\s*\\n##\\n|###<[^>]+>|&nbsp;|read_di\\(\\);|最新网址|txt下载|手机阅读|www\\.qiushu\\.info|m\\.qiushu\\.info|记住本站网址##';
            }
            return regex;
          })(),
          'source_url': (() => {
            let url = toStr(obj['bookSourceUrl'] || '');
            // 唐三中文域名迁移 .com → .info
            if (url === 'http://www.xtangsanshu.com') url = 'http://www.xtangsanshu.info';
            return url;
          })(),
          // ruleExplore.bookList 是发现页内的书籍 CSS 选择器，不是发现分类。
          // 分类由 exploreUrl 提供；这里只保留旧版 HOS 的 ruleExplores 兼容字段。
          'rule_explores': toStr(obj['ruleExplores'] || ''),
          'update_time': Number(obj['lastUpdateTime'] ?? obj['updateTime'] ?? 0) || 0,
          'header': toStr(obj['header'] || ''),
        };
        const pred = new relationalStore.RdbPredicates('book_sources');
        pred.equalTo('id', id);
        await RdbUtil.update(this.rdbStore_, row, pred);
        fixedCount++;
      } catch (_e) { /* 跳过解析失败的行 */ }
    }
    RdbUtil.close(rs);
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
export { SearchKeywordTable } from './SearchKeywordTable';
