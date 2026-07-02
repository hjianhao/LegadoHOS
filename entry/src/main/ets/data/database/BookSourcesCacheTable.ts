/**
 * 书籍书源缓存表 — 持久化搜索结果的源信息
 *
 * 当 SearchPage/ExplorePage 搜索到书籍的多源结果时，
 * 每个源写入一行，keyed by (book_name, book_author)。
 * ChangeSourcePage 打开时优先从该表加载，点击刷新才重新搜索。
 */
import relationalStore from '@ohos.data.relationalStore';
import { RdbUtil } from './RdbUtil';

export const BookSourcesCacheTableCreate = `
  CREATE TABLE IF NOT EXISTS book_sources_cache (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    book_name TEXT NOT NULL,
    book_author TEXT DEFAULT '',
    source_name TEXT DEFAULT '',
    source_url TEXT DEFAULT '',
    note_url TEXT DEFAULT '',
    cover_url TEXT DEFAULT '',
    kind TEXT DEFAULT '',
    word_count TEXT DEFAULT '',
    last_update_time TEXT DEFAULT '',
    introduce TEXT DEFAULT '',
    create_time INTEGER DEFAULT 0
  );
`;

export class BookSourcesCacheTable {
  static readonly TABLE_NAME = 'book_sources_cache';
  private rdbStore: relationalStore.RdbStore;

  constructor(rdbStore: relationalStore.RdbStore) {
    this.rdbStore = rdbStore;
  }

  /**
   * 为某本书插入一批源（先清再插，保证原子性）
   */
  async replaceSources(bookName: string, bookAuthor: string, sources: SourceCacheEntry[]): Promise<void> {
    const now = Date.now();
    // 先删除旧记录
    await this.deleteSourcesByBook(bookName, bookAuthor);
    // 批量插入
    for (const s of sources) {
      const row: relationalStore.ValuesBucket = {
        'book_name': bookName,
        'book_author': bookAuthor || '',
        'source_name': s.sourceName || '',
        'source_url': s.sourceUrl || '',
        'note_url': s.noteUrl || '',
        'cover_url': s.coverUrl || '',
        'kind': s.kind || '',
        'word_count': s.wordCount || '',
        'last_update_time': s.lastUpdateTime || '',
        'introduce': s.introduce || '',
        'create_time': now,
      };
      await RdbUtil.insert(this.rdbStore, BookSourcesCacheTable.TABLE_NAME, row);
    }
  }

  /**
   * 获取某本书缓存的源列表
   */
  async getSourcesByBook(bookName: string, bookAuthor: string): Promise<SourceCacheEntry[]> {
    const predicates = new relationalStore.RdbPredicates(BookSourcesCacheTable.TABLE_NAME);
    predicates.equalTo('book_name', bookName);
    predicates.equalTo('book_author', bookAuthor || '');
    const resultSet = await RdbUtil.query(this.rdbStore, predicates, []);
    const entries: SourceCacheEntry[] = [];
    while (RdbUtil.next(resultSet)) {
      entries.push({
        sourceName: RdbUtil.string(resultSet, 'source_name') || '',
        sourceUrl: RdbUtil.string(resultSet, 'source_url') || '',
        noteUrl: RdbUtil.string(resultSet, 'note_url') || '',
        coverUrl: RdbUtil.string(resultSet, 'cover_url') || '',
        kind: RdbUtil.string(resultSet, 'kind') || '',
        wordCount: RdbUtil.string(resultSet, 'word_count') || '',
        lastUpdateTime: RdbUtil.string(resultSet, 'last_update_time') || '',
        introduce: RdbUtil.string(resultSet, 'introduce') || '',
      });
    }
    RdbUtil.close(resultSet);
    return entries;
  }

  /**
   * 删除某本书的源缓存
   */
  async deleteSourcesByBook(bookName: string, bookAuthor: string): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(BookSourcesCacheTable.TABLE_NAME);
    predicates.equalTo('book_name', bookName);
    predicates.equalTo('book_author', bookAuthor || '');
    await RdbUtil.delete(this.rdbStore, predicates);
  }
}

/** 源缓存条目 */
export interface SourceCacheEntry {
  sourceName: string;
  sourceUrl: string;
  noteUrl: string;
  coverUrl: string;
  kind: string;
  wordCount: string;
  lastUpdateTime: string;
  introduce: string;
}
