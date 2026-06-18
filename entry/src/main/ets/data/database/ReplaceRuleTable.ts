import relationalStore from '@ohos.data.relationalStore';
import { ReplaceRule, ReplaceScope } from '../../model/ReplaceRule';

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
    const rs = await this.rdbStore.query(p, []);
    const list: ReplaceRule[] = [];
    while (rs.goToNextRow()) {
      list.push({
        id: rs.getLong(rs.getColumnIndex('id')),
        name: rs.getString(rs.getColumnIndex('rule_name')) || '',
        pattern: rs.getString(rs.getColumnIndex('pattern')) || '',
        replacement: rs.getString(rs.getColumnIndex('replacement')) || '',
        isRegex: rs.getLong(rs.getColumnIndex('is_regex')) === 1,
        isEnabled: rs.getLong(rs.getColumnIndex('is_enabled')) === 1,
        scope: rs.getLong(rs.getColumnIndex('scope')),
        scopeValue: rs.getString(rs.getColumnIndex('scope_value')) || '',
        sortOrder: rs.getLong(rs.getColumnIndex('sort_order')),
        createTime: rs.getLong(rs.getColumnIndex('create_time')),
        updateTime: rs.getLong(rs.getColumnIndex('update_time')),
      });
    }
    rs.close();
    return list;
  }
}
