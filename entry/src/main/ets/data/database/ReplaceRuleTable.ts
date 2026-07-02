import relationalStore from '@ohos.data.relationalStore';
import { ReplaceRule, ReplaceScope } from '../../model/ReplaceRule';
import { RdbUtil } from './RdbUtil';

export const ReplaceRuleTableCreate = `
  CREATE TABLE IF NOT EXISTS replace_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    rule_name TEXT NOT NULL,
    pattern TEXT DEFAULT '',
    replacement TEXT DEFAULT '',
    is_regex INTEGER DEFAULT 0,
    is_enabled INTEGER DEFAULT 1,
    scope INTEGER DEFAULT 0,
    scope_value TEXT DEFAULT '',
    sort_order INTEGER DEFAULT 0,
    create_time INTEGER DEFAULT 0,
    update_time INTEGER DEFAULT 0
  );
`;

export class ReplaceRuleTable {
  static readonly TABLE_NAME = 'replace_rules';
  private rdbStore: relationalStore.RdbStore;
  constructor(rdbStore: relationalStore.RdbStore) { this.rdbStore = rdbStore; }

  async getAllEnabled(): Promise<ReplaceRule[]> {
    const p = new relationalStore.RdbPredicates(ReplaceRuleTable.TABLE_NAME);
    p.equalTo('is_enabled', 1);
    p.orderByAsc('sort_order');
    const rs = await RdbUtil.query(this.rdbStore, p, []);
    const list: ReplaceRule[] = [];
    while (RdbUtil.next(rs)) {
      list.push({
        id: RdbUtil.long(rs, 'id'),
        name: RdbUtil.string(rs, 'rule_name') || '',
        pattern: RdbUtil.string(rs, 'pattern') || '',
        replacement: RdbUtil.string(rs, 'replacement') || '',
        isRegex: RdbUtil.long(rs, 'is_regex') === 1,
        isEnabled: RdbUtil.long(rs, 'is_enabled') === 1,
        scope: RdbUtil.long(rs, 'scope'),
        scopeValue: RdbUtil.string(rs, 'scope_value') || '',
        sortOrder: RdbUtil.long(rs, 'sort_order'),
        createTime: RdbUtil.long(rs, 'create_time'),
        updateTime: RdbUtil.long(rs, 'update_time'),
      });
    }
    RdbUtil.close(rs);
    return list;
  }
}
