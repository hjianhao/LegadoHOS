/**
 * 缓存管理器
 * 管理书籍缓存、图片缓存、搜索缓存
 */
import { AppDatabase } from '../../data/database/AppDatabase';
import { CacheTable } from '../../data/database/CacheTable';
import { ChapterTable } from '../../data/database/ChapterTable';

/** 单本书的章节缓存统计 */
export interface BookCacheStat {
  bookId: number;
  name: string;
  author: string;
  /** 已缓存章节数 */
  chapters: number;
  /** 正文占用字节数（字符数估算） */
  size: number;
}

export class CacheManager {
  private static instance: CacheManager;
  private cacheTable: CacheTable;
  private chapterTable: ChapterTable;

  private constructor() {
    const rdb = AppDatabase.getInstance().rdbStore;
    this.cacheTable = new CacheTable(rdb);
    this.chapterTable = new ChapterTable(rdb);
  }

  static getInstance(): CacheManager {
    if (!CacheManager.instance) {
      CacheManager.instance = new CacheManager();
    }
    return CacheManager.instance;
  }

  /**
   * 获取缓存大小（估计值）
   */
  async getCacheSize(): Promise<number> {
    let total = 0;
    try {
      // 通过 SQL 统计
      const rdb = AppDatabase.getInstance().rdbStore;
      const rs = await rdb.querySql(
        'SELECT SUM(LENGTH(content)) as total FROM chapters WHERE is_cached = 1', []
      );
      if (rs.goToFirstRow()) {
        total = rs.getLong(0) || 0;
      }
      rs.close();

      // 加上缓存表
      const rs2 = await rdb.querySql(
        'SELECT SUM(LENGTH(content)) as total FROM caches', []
      );
      if (rs2.goToFirstRow()) {
        total += rs2.getLong(0) || 0;
      }
      rs2.close();
    } catch (err) {
      console.error('[CacheManager] Get size failed:', err);
    }
    return total;
  }

  /**
   * 清理过期缓存
   */
  async clearExpired(): Promise<number> {
    try {
      await this.cacheTable.clearExpired();
      console.info('[CacheManager] Expired cache cleared');
      return 0;
    } catch (err) {
      console.error('[CacheManager] Clear expired failed:', err);
      return 0;
    }
  }

  /**
   * 清理全部缓存
   */
  async clearAll(): Promise<void> {
    try {
      const rdb = AppDatabase.getInstance().rdbStore;
      // 清空章节内容（保留元数据）
      await rdb.executeSql('UPDATE chapters SET content = \'\', content_length = 0, is_cached = 0, is_downloaded = 0');
      // 清空缓存表
      await rdb.executeSql('DELETE FROM caches');
      console.info('[CacheManager] All cache cleared');
    } catch (err) {
      console.error('[CacheManager] Clear all failed:', err);
    }
  }

  /**
   * 清理指定书籍的缓存
   */
  async clearBookCache(bookId: number): Promise<void> {
    try {
      const rdb = AppDatabase.getInstance().rdbStore;
      await rdb.executeSql(
        'UPDATE chapters SET content = \'\', content_length = 0, is_cached = 0, is_downloaded = 0 WHERE book_id = ?',
        [bookId]
      );
    } catch (err) {
      console.error('[CacheManager] Clear book cache failed:', err);
    }
  }

  /**
   * 按书统计章节缓存（含已下架书籍，按占用大小倒序）
   */
  async getBookCacheStats(): Promise<BookCacheStat[]> {
    const stats: BookCacheStat[] = [];
    try {
      const rdb = AppDatabase.getInstance().rdbStore;
      const rs = await rdb.querySql(
        'SELECT c.book_id, b.name, b.author, COUNT(*) AS cnt, SUM(LENGTH(c.content)) AS total '
        + 'FROM chapters c JOIN books b ON b.id = c.book_id WHERE c.is_cached = 1 '
        + 'GROUP BY c.book_id ORDER BY total DESC', []);
      let has = rs.goToFirstRow();
      while (has) {
        stats.push({
          bookId: rs.getLong(0),
          name: rs.getString(1) || '',
          author: rs.getString(2) || '',
          chapters: rs.getLong(3),
          size: rs.getLong(4) || 0,
        });
        has = rs.goToNextRow();
      }
      rs.close();
    } catch (err) {
      console.error('[CacheManager] Get book stats failed:', err);
    }
    return stats;
  }

  /**
   * 格式化缓存大小
   */
  static formatSize(bytes: number): string {
    if (bytes < 1024) return `${bytes}B`;
    const kb = bytes / 1024;
    if (kb < 1024) return `${kb.toFixed(1)}KB`;
    const mb = kb / 1024;
    return `${mb.toFixed(1)}MB`;
  }
}
