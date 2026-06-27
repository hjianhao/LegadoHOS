/**
 * 搜索关键词历史表
 * 参照 legado-with-MD3 SearchKeywordDao.kt
 */
import relationalStore from '@ohos.data.relationalStore';
import { SearchKeyword } from '../../model/SearchKeyword';

export const SearchKeywordTableCreate = `
  CREATE TABLE IF NOT EXISTS search_keywords (
    word TEXT PRIMARY KEY NOT NULL,
    usage INTEGER DEFAULT 1,
    last_use_time INTEGER DEFAULT 0
  )
`;

export class SearchKeywordTable {
  static readonly TABLE_NAME = 'search_keywords';
  private db: relationalStore.RdbStore;

  constructor(db: relationalStore.RdbStore) {
    this.db = db;
  }

  /**
   * 获取最近的搜索历史（按时间倒序）
   */
  async getRecent(limit: number = 20): Promise<SearchKeyword[]> {
    try {
      const predicates = new relationalStore.RdbPredicates(SearchKeywordTable.TABLE_NAME);
      predicates.orderByDesc('last_use_time');
      predicates.limitAs(limit);
      const rs = await this.db.query(predicates, ['word', 'usage', 'last_use_time']);
      const items: SearchKeyword[] = [];
      while (rs.goToNextRow()) {
        items.push({
          word: rs.getString(rs.getColumnIndex('word')),
          usage: rs.getLong(rs.getColumnIndex('usage')),
          lastUseTime: rs.getLong(rs.getColumnIndex('last_use_time')),
        });
      }
      rs.close();
      return items;
    } catch (_e) {
      return [];
    }
  }

  /**
   * 模糊搜索历史（按使用频率降序）
   */
  async search(key: string, limit: number = 20): Promise<SearchKeyword[]> {
    try {
      const predicates = new relationalStore.RdbPredicates(SearchKeywordTable.TABLE_NAME);
      predicates.like('word', '%' + key + '%');
      predicates.orderByDesc('usage');
      predicates.limitAs(limit);
      const rs = await this.db.query(predicates, ['word', 'usage', 'last_use_time']);
      const items: SearchKeyword[] = [];
      while (rs.goToNextRow()) {
        items.push({
          word: rs.getString(rs.getColumnIndex('word')),
          usage: rs.getLong(rs.getColumnIndex('usage')),
          lastUseTime: rs.getLong(rs.getColumnIndex('last_use_time')),
        });
      }
      rs.close();
      return items;
    } catch (_e) {
      return [];
    }
  }

  /**
   * 保存搜索关键词（已存在则更新使用次数和时间）
   */
  async save(word: string): Promise<void> {
    const key = word.trim();
    if (!key) return;
    try {
      // 先检查是否存在
      const predicates = new relationalStore.RdbPredicates(SearchKeywordTable.TABLE_NAME);
      predicates.equalTo('word', key);
      const rs = await this.db.query(predicates, ['word', 'usage']);
      if (rs.goToNextRow()) {
        const oldUsage = rs.getLong(rs.getColumnIndex('usage'));
        rs.close();
        // 更新
        const updatePredicates = new relationalStore.RdbPredicates(SearchKeywordTable.TABLE_NAME);
        updatePredicates.equalTo('word', key);
        await this.db.update({
          word: key,
          usage: oldUsage + 1,
          last_use_time: Date.now(),
        }, updatePredicates);
      } else {
        rs.close();
        // 插入新记录
        const row: relationalStore.ValuesBucket = {
          word: key,
          usage: 1,
          last_use_time: Date.now(),
        };
        await this.db.insert(SearchKeywordTable.TABLE_NAME, row);
      }
    } catch (_e) {
      // 插入失败（可能并发），忽略
    }
  }

  /**
   * 删除单个关键词
   */
  async delete(word: string): Promise<void> {
    try {
      const predicates = new relationalStore.RdbPredicates(SearchKeywordTable.TABLE_NAME);
      predicates.equalTo('word', word);
      await this.db.delete(predicates);
    } catch (_e) { /* ignore */ }
  }

  /**
   * 清空所有搜索历史
   */
  async deleteAll(): Promise<void> {
    try {
      const predicates = new relationalStore.RdbPredicates(SearchKeywordTable.TABLE_NAME);
      await this.db.delete(predicates);
    } catch (_e) { /* ignore */ }
  }

  /**
   * 获取历史总数
   */
  async count(): Promise<number> {
    try {
      const predicates = new relationalStore.RdbPredicates(SearchKeywordTable.TABLE_NAME);
      const rs = await this.db.query(predicates, ['COUNT(*) as cnt']);
      if (rs.goToNextRow()) {
        const cnt = rs.getLong(rs.getColumnIndex('cnt'));
        rs.close();
        return cnt;
      }
      rs.close();
      return 0;
    } catch (_e) {
      return 0;
    }
  }

  /**
   * 限制历史数量，超过 limit 时删除最旧的
   */
  async trimHistory(maxCount: number = 100): Promise<void> {
    try {
      const predicates = new relationalStore.RdbPredicates(SearchKeywordTable.TABLE_NAME);
      predicates.orderByDesc('last_use_time');
      const rs = await this.db.query(predicates, ['word', 'last_use_time']);
      const items: { word: string; time: number }[] = [];
      while (rs.goToNextRow()) {
        items.push({
          word: rs.getString(rs.getColumnIndex('word')),
          time: rs.getLong(rs.getColumnIndex('last_use_time')),
        });
      }
      rs.close();
      if (items.length > maxCount) {
        // 删除超出部分（最旧的）
        const toDelete = items.slice(maxCount);
        for (const item of toDelete) {
          await this.delete(item.word);
        }
      }
    } catch (_e) { /* ignore */ }
  }
}
