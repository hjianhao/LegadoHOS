import relationalStore from '@ohos.data.relationalStore';
import { CacheEntry, TxtTocRule } from '../../model/CacheEntry';
import { RdbUtil } from './RdbUtil';

export const CacheTableCreate = `
  CREATE TABLE IF NOT EXISTS caches (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    cache_key TEXT UNIQUE NOT NULL,
    content TEXT DEFAULT '',
    content_type TEXT DEFAULT 'text',
    deadline INTEGER DEFAULT 0,
    create_time INTEGER DEFAULT 0,
    update_time INTEGER DEFAULT 0
  );
`;

export const TxtTocRuleTableCreate = `
  CREATE TABLE IF NOT EXISTS txt_toc_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    rule_name TEXT NOT NULL,
    rule_pattern TEXT DEFAULT '',
    is_enabled INTEGER DEFAULT 1,
    sort_order INTEGER DEFAULT 0,
    create_time INTEGER DEFAULT 0
  );
`;

export class CacheTable {
  static readonly TABLE_NAME = 'caches';
  private rdbStore: relationalStore.RdbStore;
  constructor(rdbStore: relationalStore.RdbStore) { this.rdbStore = rdbStore; }

  async get(key: string): Promise<string | null> {
    const p = new relationalStore.RdbPredicates(CacheTable.TABLE_NAME);
    p.equalTo('cache_key', key);
    const rs = await RdbUtil.query(this.rdbStore, p, []);
    if (RdbUtil.first(rs)) {
      const content = RdbUtil.string(rs, 'content');
      const deadline = RdbUtil.long(rs, 'deadline');
      RdbUtil.close(rs);
      if (deadline === 0 || deadline > Date.now()) return content;
    }
    RdbUtil.close(rs);
    return null;
  }

  async put(key: string, content: string, ttlMs: number = 0): Promise<void> {
    const deadline = ttlMs > 0 ? Date.now() + ttlMs : 0;
    const existing = await this.get(key);
    if (existing !== null) {
      const p = new relationalStore.RdbPredicates(CacheTable.TABLE_NAME);
      p.equalTo('cache_key', key);
      await RdbUtil.update(this.rdbStore, {
        'content': content, 'deadline': deadline, 'update_time': Date.now(),
      }, p);
    } else {
      await RdbUtil.insert(this.rdbStore, CacheTable.TABLE_NAME, {
        'cache_key': key, 'content': content, 'deadline': deadline,
        'create_time': Date.now(), 'update_time': Date.now(),
      });
    }
  }

  async clearExpired(): Promise<void> {
    const p = new relationalStore.RdbPredicates(CacheTable.TABLE_NAME);
    p.lessThan('deadline', Date.now());
    p.notEqualTo('deadline', 0);
    await RdbUtil.delete(this.rdbStore, p);
  }
}

export class TxtTocRuleTable {
  static readonly TABLE_NAME = 'txt_toc_rules';
  private rdbStore: relationalStore.RdbStore;
  constructor(rdbStore: relationalStore.RdbStore) { this.rdbStore = rdbStore; }

  async getAll(): Promise<TxtTocRule[]> {
    const p = new relationalStore.RdbPredicates(CacheTable.TABLE_NAME);
    p.orderByAsc('sort_order');
    const rs = await RdbUtil.query(this.rdbStore, p, []);
    const list: TxtTocRule[] = [];
    while (RdbUtil.next(rs)) {
      list.push({
        id: RdbUtil.long(rs, 'id'),
        name: RdbUtil.string(rs, 'rule_name') || '',
        rule: RdbUtil.string(rs, 'rule_pattern') || '',
        isEnabled: RdbUtil.long(rs, 'is_enabled') === 1,
        sortOrder: RdbUtil.long(rs, 'sort_order'),
        createTime: RdbUtil.long(rs, 'create_time'),
      });
    }
    RdbUtil.close(rs);
    return list;
  }
}
