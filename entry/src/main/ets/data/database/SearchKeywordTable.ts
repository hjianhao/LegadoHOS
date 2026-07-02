/**
 * 搜索关键词历史表
 * 参照 legado-with-MD3 SearchKeywordDao.kt
 */
import relationalStore from '@ohos.data.relationalStore';
import { SearchKeyword } from '../../model/SearchKeyword';
import { RdbUtil } from './RdbUtil';

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
      const rs = await RdbUtil.query(this.db, predicates, ['word', 'usage', 'last_use_time']);
      const items: SearchKeyword[] = [];
      while (RdbUtil.next(rs)) {
        items.push({
          word: RdbUtil.string(rs, 'word'),
          usage: RdbUtil.long(rs, 'usage'),
          lastUseTime: RdbUtil.long(rs, 'last_use_time'),
        });
      }
      RdbUtil.close(rs);
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
      const rs = await RdbUtil.query(this.db, predicates, ['word', 'usage', 'last_use_time']);
      const items: SearchKeyword[] = [];
      while (RdbUtil.next(rs)) {
        items.push({
          word: RdbUtil.string(rs, 'word'),
          usage: RdbUtil.long(rs, 'usage'),
          lastUseTime: RdbUtil.long(rs, 'last_use_time'),
        });
      }
      RdbUtil.close(rs);
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
      const rs = await RdbUtil.query(this.db, predicates, ['word', 'usage']);
      if (RdbUtil.next(rs)) {
        const oldUsage = RdbUtil.long(rs, 'usage');
        RdbUtil.close(rs);
        // 更新
        const updatePredicates = new relationalStore.RdbPredicates(SearchKeywordTable.TABLE_NAME);
        updatePredicates.equalTo('word', key);
        await RdbUtil.update(this.db, {
          word: key,
          usage: oldUsage + 1,
          last_use_time: Date.now(),
        }, updatePredicates);
      } else {
        RdbUtil.close(rs);
        // 插入新记录
        const row: relationalStore.ValuesBucket = {
          word: key,
          usage: 1,
          last_use_time: Date.now(),
        };
        await RdbUtil.insert(this.db, SearchKeywordTable.TABLE_NAME, row);
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
      await RdbUtil.delete(this.db, predicates);
    } catch (_e) { /* ignore */ }
  }

  /**
   * 清空所有搜索历史
   */
  async deleteAll(): Promise<void> {
    try {
      const predicates = new relationalStore.RdbPredicates(SearchKeywordTable.TABLE_NAME);
      await RdbUtil.delete(this.db, predicates);
    } catch (_e) { /* ignore */ }
  }

  /**
   * 获取历史总数
   */
  async count(): Promise<number> {
    try {
      const predicates = new relationalStore.RdbPredicates(SearchKeywordTable.TABLE_NAME);
      const rs = await RdbUtil.query(this.db, predicates, ['COUNT(*) as cnt']);
      if (RdbUtil.next(rs)) {
        const cnt = RdbUtil.long(rs, 'cnt');
        RdbUtil.close(rs);
        return cnt;
      }
      RdbUtil.close(rs);
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
      const rs = await RdbUtil.query(this.db, predicates, ['word', 'last_use_time']);
      const items: { word: string; time: number }[] = [];
      while (RdbUtil.next(rs)) {
        items.push({
          word: RdbUtil.string(rs, 'word'),
          time: RdbUtil.long(rs, 'last_use_time'),
        });
      }
      RdbUtil.close(rs);
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
