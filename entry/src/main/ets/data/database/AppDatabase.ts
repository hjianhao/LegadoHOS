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
import { AiBookProfileTableCreate } from './AiBookProfileTable';
import {
  SourceRevisionIndexUrl,
  SourceRevisionTableCreate,
} from './SourceRevisionTable';
import {
  CloudSourceTable,
  CloudSourceTableCreate,
} from './CloudSourceTable';
import {
  CloudBookBindingTable,
  CloudBookBindingTableCreate,
  CloudBookBindingIndexBookId,
  CloudBookBindingIndexSourceId,
} from './CloudBookBindingTable';
import { RdbUtil } from './RdbUtil';
import { BookSourceFormat, isQysgSourceObject } from '../../model/BookSource';

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

  get cloudSourceTable(): CloudSourceTable {
    return new CloudSourceTable(this.rdbStore);
  }

  get cloudBookBindingTable(): CloudBookBindingTable {
    return new CloudBookBindingTable(this.rdbStore);
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
    // replace_rules 旧表 schema（scope 枚举 + scope_value 列）与安卓字符串子串语义不兼容，
    // 仅在检测到旧 schema（存在 scope_value 列）时 DROP 重建；新表无条件 DROP 会清空用户规则
    let isOldReplaceRuleSchema = false;
    const schemaRs = await RdbUtil.querySql(this.rdbStore_, 'PRAGMA table_info(replace_rules)', []);
    while (RdbUtil.next(schemaRs)) {
      if (RdbUtil.string(schemaRs, 'name') === 'scope_value') {
        isOldReplaceRuleSchema = true;
        break;
      }
    }
    RdbUtil.close(schemaRs);
    if (isOldReplaceRuleSchema) {
      await RdbUtil.executeSql(this.rdbStore_, 'DROP TABLE IF EXISTS replace_rules');
    }
    await RdbUtil.executeSql(this.rdbStore_, ReplaceRuleTableCreate);
    await RdbUtil.executeSql(this.rdbStore_, RSSSourceTableCreate);
    await RdbUtil.executeSql(this.rdbStore_, RSSArticleTableCreate);
    await RdbUtil.executeSql(this.rdbStore_, CacheTableCreate);
    await RdbUtil.executeSql(this.rdbStore_, TxtTocRuleTableCreate);
    await RdbUtil.executeSql(this.rdbStore_, SearchResultTableCreate);
    await RdbUtil.executeSql(this.rdbStore_, SearchKeywordTableCreate);
    await RdbUtil.executeSql(this.rdbStore_, AiBookProfileTableCreate);
    await RdbUtil.executeSql(this.rdbStore_, SourceRevisionTableCreate);
    await RdbUtil.executeSql(this.rdbStore_, SourceRevisionIndexUrl);
    // 云端书库：先 sources 后 bindings；对已有用户库幂等
    await RdbUtil.executeSql(this.rdbStore_, CloudSourceTableCreate);
    await RdbUtil.executeSql(this.rdbStore_, CloudBookBindingTableCreate);
    await RdbUtil.executeSql(this.rdbStore_, CloudBookBindingIndexBookId);
    await RdbUtil.executeSql(this.rdbStore_, CloudBookBindingIndexSourceId);

    // 数据库迁移：为已有表添加新列
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN header TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN raw_json TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN source_format INTEGER DEFAULT 0"); } catch (_e) { /* 列已存在 */ }
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
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE books ADD COLUMN charset TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE chapters ADD COLUMN start INTEGER DEFAULT 0"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE chapters ADD COLUMN end INTEGER DEFAULT 0"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE chapters ADD COLUMN is_vip INTEGER DEFAULT 0"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE chapters ADD COLUMN is_pay INTEGER DEFAULT 0"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE chapters ADD COLUMN chapter_update_time TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN rule_book_content_replace_regex TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN cover_decode_js TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await RdbUtil.executeSql(this.rdbStore_, "ALTER TABLE book_sources ADD COLUMN variable_comment TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }

    // 从 raw_json 重新解析规则字段（适用于已有 raw_json 但缺少规则列的旧数据）
    try { await this.reparseSourceRules(); } catch (_e) { /* 忽略 */ }

    // Android 以书源 URL 作为主键。旧版 HOS 允许空 URL/重复 URL，会导致列表键、
    // 选择状态、开关和校验结果相互覆盖；迁移时保留每个 URL 更新时间最新的记录。
    await RdbUtil.executeSql(this.rdbStore_,
      "DELETE FROM book_sources WHERE source_url IS NULL OR trim(source_url) = ''");
    await RdbUtil.executeSql(this.rdbStore_,
      `DELETE FROM book_sources
       WHERE id NOT IN (
         SELECT candidate.id FROM book_sources candidate
         WHERE candidate.id = (
           SELECT chosen.id FROM book_sources chosen
           WHERE chosen.source_url = candidate.source_url
           ORDER BY chosen.update_time DESC, chosen.id ASC
           LIMIT 1
         )
       )`);
    await RdbUtil.executeSql(this.rdbStore_,
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_book_sources_source_url ON book_sources(source_url)');

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
        const nested = (value: Object): Record<string, Object> => {
          if (value && typeof value === 'object' && !Array.isArray(value)) {
            return value as Record<string, Object>;
          }
          if (typeof value === 'string') {
            try {
              const parsed: Object = JSON.parse(value);
              if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
                return parsed as Record<string, Object>;
              }
            } catch (_e) { /* 普通字符串规则 */ }
          }
          return {};
        };
        const rs2: Record<string, Object> = nested(obj['ruleSearch']);
        const toStr = (val: Object): string => {
          if (typeof val === 'string') return val;
          if (val === null || val === undefined) return '';
          return JSON.stringify(val);
        };
        const bi: Record<string, Object> = nested(obj['ruleBookInfo']);
        const rtc: Record<string, Object> = nested(obj['ruleToc']);
        const rc: Record<string, Object> = nested(obj['ruleContent']);
        const rawToc = obj['ruleToc'];
        // raw_json 只作为"旧导入缺列"的兜底：查询现有行，任一规则列已有值
        // 就保留（用户可能在 App 里手动编辑过，raw_json 未必同步，无条件
        // 覆盖会丢失这些编辑——如可乐小说 ruleTocUrl 列有 /chapter/ 跳转
        // JS，而 raw_json 里 tocUrl 为空，覆盖后 AES 密钥缓存逻辑失效）。
        const cur = await RdbUtil.querySql(this.rdbStore_,
          "SELECT rule_search_url, rule_search_list, rule_search_name, rule_search_author, " +
          "rule_search_cover, rule_search_note_url, rule_search_kind, rule_search_word_count, " +
          "rule_search_last_update_time, rule_search_introduce, rule_book_info_init, " +
          "rule_book_info_name, rule_book_info_author, rule_book_info_cover, " +
          "rule_book_info_introduce, rule_book_info_kind, rule_book_info_word_count, " +
          "rule_book_info_last_update_time, rule_book_info_toc_url, rule_toc_url, rule_toc, " +
          "rule_toc_title, rule_toc_url_item, rule_book_content_url, rule_book_content, " +
          "rule_book_content_next, rule_book_content_replace_regex, source_url, rule_explores, header " +
          "FROM book_sources WHERE id = " + id);
        // 一次性读取全部现有列值（游标只能前进，先读完整行再关闭）
        const curMap: Record<string, string> = {};
        const curCols = ['rule_search_url', 'rule_search_list', 'rule_search_name',
          'rule_search_author', 'rule_search_cover', 'rule_search_note_url', 'rule_search_kind',
          'rule_search_word_count', 'rule_search_last_update_time', 'rule_search_introduce',
          'rule_book_info_init', 'rule_book_info_name', 'rule_book_info_author',
          'rule_book_info_cover', 'rule_book_info_introduce', 'rule_book_info_kind',
          'rule_book_info_word_count', 'rule_book_info_last_update_time',
          'rule_book_info_toc_url', 'rule_toc_url', 'rule_toc', 'rule_toc_title',
          'rule_toc_url_item', 'rule_book_content_url', 'rule_book_content',
          'rule_book_content_next', 'rule_book_content_replace_regex',
          'source_url', 'rule_explores', 'header'];
        if (RdbUtil.next(cur)) {
          for (const col of curCols) {
            curMap[col] = RdbUtil.string(cur, col);
          }
        }
        RdbUtil.close(cur);
        // 新值（raw_json）优先，空则保留列中已有值
        const pick = (col: string, fresh: string): string => fresh || curMap[col] || '';
        const row: relationalStore.ValuesBucket = {
          'id': id,
          // 旧版本没有 source_format 列。复用统一识别逻辑，外链型 qysg 也要
          // 迁移为轻悦时光格式，避免升级后又显示为 Legado。
          'source_format': isQysgSourceObject(obj) ? BookSourceFormat.QYSG : BookSourceFormat.LEGADO,
          'rule_search_url': pick('rule_search_url', (() => {
            let searchUrl = toStr(obj['ruleSearchUrl'] || rs2['searchUrl'] || obj['searchUrl'] || '');
            // 悠久小说网：AI 生成时误标 webView，站点实际支持直接 HTTP POST 搜索，
            // webView:true 会让每次搜索都弹完整 WebView 交互框。验证后移除该标记。
            if (searchUrl.includes('searchbooks.php') && searchUrl.includes('ujxsw') &&
              /"webView"\s*:\s*true/i.test(searchUrl)) {
              searchUrl = searchUrl.replace(/,\s*"webView"\s*:\s*true/i, '');
            }
            return searchUrl;
          })()),
          'rule_search_list': pick('rule_search_list', toStr(obj['ruleSearchList'] || rs2['bookList'] || obj['searchList'] || '')),
          'rule_search_name': pick('rule_search_name', toStr(obj['ruleSearchName'] || rs2['name'] || '')),
          'rule_search_author': pick('rule_search_author', toStr(obj['ruleSearchAuthor'] || rs2['author'] || '')),
          'rule_search_cover': pick('rule_search_cover', toStr(obj['ruleSearchCover'] || rs2['coverUrl'] || '')),
          'rule_search_note_url': pick('rule_search_note_url', toStr(obj['ruleSearchNoteUrl'] || rs2['bookUrl'] || '')),
          'rule_search_kind': pick('rule_search_kind', toStr(obj['ruleSearchKind'] || rs2['kind'] || '')),
          'rule_search_word_count': pick('rule_search_word_count', toStr(obj['ruleSearchWordCount'] || rs2['wordCount'] || '')),
          'rule_search_last_update_time': pick('rule_search_last_update_time', toStr(obj['ruleSearchLastUpdateTime'] ||
            rs2['updateTime'] || rs2['lastUpdateTime'] || '')),
          'rule_search_introduce': pick('rule_search_introduce', toStr(obj['ruleSearchIntroduce'] || rs2['intro'] || rs2['introduce'] || '')),
          'rule_book_info_init': pick('rule_book_info_init', toStr(obj['ruleBookInfoInit'] || bi['init'] || '')),
          'rule_book_info_name': pick('rule_book_info_name', toStr(obj['ruleBookInfoName'] || bi['name'] || '')),
          'rule_book_info_author': pick('rule_book_info_author', toStr(obj['ruleBookInfoAuthor'] || bi['author'] || '')),
          'rule_book_info_cover': pick('rule_book_info_cover', toStr(obj['ruleBookInfoCover'] || bi['coverUrl'] || '')),
          'rule_book_info_introduce': pick('rule_book_info_introduce', toStr(obj['ruleBookInfoIntroduce'] || bi['intro'] || '')),
          'rule_book_info_kind': pick('rule_book_info_kind', toStr(obj['ruleBookInfoKind'] || bi['kind'] || '')),
          'rule_book_info_word_count': pick('rule_book_info_word_count', toStr(obj['ruleBookInfoWordCount'] || bi['wordCount'] || '')),
          'rule_book_info_last_update_time': pick('rule_book_info_last_update_time', toStr(obj['ruleBookInfoLastUpdateTime'] ||
            bi['updateTime'] || bi['lastUpdateTime'] || '')),
          'rule_book_info_toc_url': pick('rule_book_info_toc_url', toStr(obj['ruleBookInfoTocUrl'] || bi['tocUrl'] || obj['tocUrl'] || '')),
          'rule_toc_url': pick('rule_toc_url', toStr(obj['ruleTocUrl'] || rtc['tocUrl'] || '')),
          'rule_toc': pick('rule_toc', toStr(typeof rawToc === 'string' && Object.keys(rtc).length === 0
            ? rawToc : rtc['chapterList'] || '')),
          'rule_toc_title': pick('rule_toc_title', toStr(obj['ruleTocTitle'] || rtc['chapterName'] || '')),
          'rule_toc_url_item': pick('rule_toc_url_item', toStr(obj['ruleTocUrlItem'] || rtc['chapterUrl'] || '')),
          'rule_book_content_url': pick('rule_book_content_url', toStr(obj['ruleBookContentUrl'] || rc['contentUrl'] || '')),
          'rule_book_content': pick('rule_book_content', (() => {
            const rbcRaw = obj['ruleBookContent'] || rc['content'] || '';
            let rbc = typeof rbcRaw === 'string' ? rbcRaw : JSON.stringify(rbcRaw);
            // 狗狗书籍兼容：wap 线路 #nr1 是文本+<br>+&nbsp; 分段结构。
            // @text 会把段落折叠成一行（Android jsoup 同样），@textNodes
            // 才按段换行（HtmlParser collectTextNodes 处理 <br>/&nbsp; 边界）。
            // 旧布局 id.content 容器在 wap 线路无匹配，保持原有的 @html 兜底。
            if (toStr(obj['bookSourceUrl']) === 'http://www.qiushu.info') {
              if (rbc === 'id.content@textNodes') {
                rbc = 'id.content@html';
              } else if (rbc === 'id.nr1@text') {
                rbc = 'id.nr1@textNodes';
              }
            }
            return rbc;
          })()),
          'rule_book_content_next': pick('rule_book_content_next', toStr(obj['ruleBookContentNext'] || rc['nextContentUrl'] || '')),
          'rule_book_content_replace_regex': pick('rule_book_content_replace_regex', (() => {
            let regex = toStr(obj['ruleBookContentReplaceRegex'] || rc['replaceRegex'] || '');
            // 狗狗书籍：清除分页尾注（本章未完，请点击下一页继续阅读）。
            // 已导入的书源 replaceRegex 为旧值 ##求书网.* 时自动升级。
            if (toStr(obj['bookSourceUrl']) === 'http://www.qiushu.info') {
              if (regex === '##求书网.*') {
                regex = '##求书网.*|[（(]本章未完[^）)]*[）)]';
              } else if (!regex) {
                // 旧布局 id.content@html 的默认清洗规则（<br> → 换行 + 垃圾过滤）
                regex = '##<br\\s*\\/?>|\\n\\s*\\n##\\n|###<[^>]+>|&nbsp;|read_di\\(\\);|最新网址|txt下载|手机阅读|www\\.qiushu\\.info|m\\.qiushu\\.info|记住本站网址##';
              }
            }
            return regex;
          })()),
          'source_url': pick('source_url', (() => {
            let url = toStr(obj['bookSourceUrl'] || '');
            // 唐三中文域名迁移 .com → .info
            if (url === 'http://www.xtangsanshu.com') url = 'http://www.xtangsanshu.info';
            return url;
          })()),
          // ruleExplore.bookList 是发现页内的书籍 CSS 选择器，不是发现分类。
          // 分类由 exploreUrl 提供；这里只保留旧版 HOS 的 ruleExplores 兼容字段。
          'rule_explores': pick('rule_explores', toStr(obj['ruleExplores'] || '')),
          'update_time': Number(obj['lastUpdateTime'] ?? obj['updateTime'] ?? 0) || 0,
          'header': pick('header', toStr(obj['header'] || '')),
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
export { AiBookProfileTable } from './AiBookProfileTable';
export { SourceRevisionTable } from './SourceRevisionTable';
