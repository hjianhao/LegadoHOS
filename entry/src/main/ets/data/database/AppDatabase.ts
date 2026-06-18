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
    try { await this.rdbStore_.executeSql("ALTER TABLE search_results ADD COLUMN source_name TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }
    try { await this.rdbStore_.executeSql("ALTER TABLE books ADD COLUMN latest_chapter_title TEXT DEFAULT ''"); } catch (_e) { /* 列已存在 */ }

    console.info('[AppDatabase] Database initialized successfully');
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
