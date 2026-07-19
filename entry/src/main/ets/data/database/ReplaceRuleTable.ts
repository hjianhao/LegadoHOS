import relationalStore from '@ohos.data.relationalStore';
import { ReplaceRule } from '../../model/ReplaceRule';
import { RdbUtil } from './RdbUtil';

/**
 * 替换净化规则表 — 列名对齐安卓 replace_rules（snake_case）。
 * 注意：`group`/`order` 是 SQL 保留字，分别用 rule_group / sort_order 列名。
 */
export const ReplaceRuleTableCreate = `
  CREATE TABLE IF NOT EXISTS replace_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    rule_name TEXT DEFAULT '',
    rule_group TEXT DEFAULT '',
    pattern TEXT DEFAULT '',
    replacement TEXT DEFAULT '',
    scope TEXT DEFAULT '',
    scope_title INTEGER DEFAULT 0,
    scope_content INTEGER DEFAULT 1,
    exclude_scope TEXT DEFAULT '',
    is_enabled INTEGER DEFAULT 1,
    is_regex INTEGER DEFAULT 1,
    timeout_millisecond INTEGER DEFAULT 3000,
    sort_order INTEGER DEFAULT 0
  );
`;

export class ReplaceRuleTable {
  static readonly TABLE_NAME = 'replace_rules';
  private rdbStore: relationalStore.RdbStore;

  constructor(rdbStore: relationalStore.RdbStore) {
    this.rdbStore = rdbStore;
  }

  /** 全部规则，按 sort_order 升序 */
  async getAll(): Promise<ReplaceRule[]> {
    const predicates = new relationalStore.RdbPredicates(ReplaceRuleTable.TABLE_NAME);
    predicates.orderByAsc('sort_order');
    const rs = await RdbUtil.query(this.rdbStore, predicates, []);
    return this.toRules(rs);
  }

  async insert(rule: ReplaceRule): Promise<number> {
    return RdbUtil.insert(this.rdbStore, ReplaceRuleTable.TABLE_NAME, this.toRow(rule));
  }

  async update(rule: ReplaceRule): Promise<number> {
    const predicates = new relationalStore.RdbPredicates(ReplaceRuleTable.TABLE_NAME);
    predicates.equalTo('id', rule.id);
    return RdbUtil.update(this.rdbStore, this.toRow(rule), predicates);
  }

  async deleteById(id: number): Promise<number> {
    const predicates = new relationalStore.RdbPredicates(ReplaceRuleTable.TABLE_NAME);
    predicates.equalTo('id', id);
    return RdbUtil.delete(this.rdbStore, predicates);
  }

  async deleteByIds(ids: number[]): Promise<void> {
    for (const id of ids) {
      await this.deleteById(id);
    }
  }

  async updateEnabled(id: number, enabled: boolean): Promise<number> {
    const predicates = new relationalStore.RdbPredicates(ReplaceRuleTable.TABLE_NAME);
    predicates.equalTo('id', id);
    const row: relationalStore.ValuesBucket = { 'is_enabled': enabled ? 1 : 0 };
    return RdbUtil.update(this.rdbStore, row, predicates);
  }

  async updateEnabledByIds(ids: number[], enabled: boolean): Promise<void> {
    for (const id of ids) {
      await this.updateEnabled(id, enabled);
    }
  }

  async getMaxOrder(): Promise<number> {
    const rs = await RdbUtil.querySql(this.rdbStore,
      'SELECT MAX(sort_order) AS max_order FROM replace_rules', []);
    let maxOrder = 0;
    if (RdbUtil.next(rs)) {
      maxOrder = RdbUtil.long(rs, 'max_order');
    }
    RdbUtil.close(rs);
    return maxOrder;
  }

  async getMinOrder(): Promise<number> {
    const rs = await RdbUtil.querySql(this.rdbStore,
      'SELECT MIN(sort_order) AS min_order FROM replace_rules', []);
    let minOrder = 0;
    if (RdbUtil.next(rs)) {
      minOrder = RdbUtil.long(rs, 'min_order');
    }
    RdbUtil.close(rs);
    return minOrder;
  }

  /**
   * 正文 scope 匹配查询（安卓同款 SQL）：
   * 启用且作用于正文，scope 子串命中书名/书源 URL（或为空），且 excludeScope 不命中。
   * name/origin 走 bindArgs 占位符，禁止字符串拼接。
   */
  async findEnabledByContentScope(name: string, origin: string): Promise<ReplaceRule[]> {
    return this.findEnabledByScope('scope_content', name, origin);
  }

  /** 标题 scope 匹配查询，同 findEnabledByContentScope，换成 scope_title 列 */
  async findEnabledByTitleScope(name: string, origin: string): Promise<ReplaceRule[]> {
    return this.findEnabledByScope('scope_title', name, origin);
  }

  private async findEnabledByScope(scopeColumn: string, name: string, origin: string): Promise<ReplaceRule[]> {
    const sql = `SELECT * FROM replace_rules WHERE is_enabled = 1 AND ${scopeColumn} = 1
      AND (scope LIKE '%' || ? || '%' OR scope LIKE '%' || ? || '%' OR scope IS NULL OR scope = '')
      AND (exclude_scope IS NULL OR (exclude_scope NOT LIKE '%' || ? || '%' AND exclude_scope NOT LIKE '%' || ? || '%'))
      ORDER BY sort_order`;
    const bindArgs: Array<relationalStore.ValueType> = [name, origin, name, origin];
    const rs = await RdbUtil.querySql(this.rdbStore, sql, bindArgs);
    return this.toRules(rs);
  }

  private toRules(rs: relationalStore.ResultSet): ReplaceRule[] {
    const list: ReplaceRule[] = [];
    while (RdbUtil.next(rs)) {
      list.push(this.toEntity(rs));
    }
    RdbUtil.close(rs);
    return list;
  }

  private toEntity(rs: relationalStore.ResultSet): ReplaceRule {
    return {
      id: RdbUtil.long(rs, 'id'),
      name: RdbUtil.string(rs, 'rule_name'),
      group: RdbUtil.string(rs, 'rule_group'),
      pattern: RdbUtil.string(rs, 'pattern'),
      replacement: RdbUtil.string(rs, 'replacement'),
      scope: RdbUtil.string(rs, 'scope'),
      scopeTitle: RdbUtil.long(rs, 'scope_title') === 1,
      scopeContent: RdbUtil.long(rs, 'scope_content') === 1,
      excludeScope: RdbUtil.string(rs, 'exclude_scope'),
      isEnabled: RdbUtil.long(rs, 'is_enabled') === 1,
      isRegex: RdbUtil.long(rs, 'is_regex') === 1,
      timeoutMillisecond: RdbUtil.long(rs, 'timeout_millisecond'),
      order: RdbUtil.long(rs, 'sort_order'),
    };
  }

  /** id 不写入，由 AUTOINCREMENT 分配 */
  private toRow(rule: ReplaceRule): relationalStore.ValuesBucket {
    return {
      'rule_name': rule.name,
      'rule_group': rule.group,
      'pattern': rule.pattern,
      'replacement': rule.replacement,
      'scope': rule.scope,
      'scope_title': rule.scopeTitle ? 1 : 0,
      'scope_content': rule.scopeContent ? 1 : 0,
      'exclude_scope': rule.excludeScope,
      'is_enabled': rule.isEnabled ? 1 : 0,
      'is_regex': rule.isRegex ? 1 : 0,
      'timeout_millisecond': rule.timeoutMillisecond,
      'sort_order': rule.order,
    };
  }
}
