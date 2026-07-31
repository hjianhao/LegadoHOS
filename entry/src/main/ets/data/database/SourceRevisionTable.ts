import relationalStore from '@ohos.data.relationalStore';
import { SourceRevision } from '../../model/SourceRevision';
import { RdbUtil } from './RdbUtil';

export const SourceRevisionTableCreate = `
  CREATE TABLE IF NOT EXISTS source_revisions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_id INTEGER DEFAULT 0,
    source_url TEXT NOT NULL,
    before_json TEXT NOT NULL,
    after_json TEXT NOT NULL,
    reason TEXT DEFAULT '',
    changed_fields TEXT DEFAULT '',
    created_at INTEGER DEFAULT 0,
    applied INTEGER DEFAULT 0
  )
`;

export const SourceRevisionIndexUrl =
  'CREATE INDEX IF NOT EXISTS idx_source_revisions_url ON source_revisions(source_url, created_at DESC)';

export class SourceRevisionTable {
  static readonly TABLE_NAME = 'source_revisions';
  private db_: relationalStore.RdbStore;

  constructor(db: relationalStore.RdbStore) {
    this.db_ = db;
  }

  async insert(revision: SourceRevision): Promise<number> {
    return await RdbUtil.insert(this.db_, SourceRevisionTable.TABLE_NAME, {
      'source_id': revision.sourceId,
      'source_url': revision.sourceUrl,
      'before_json': revision.beforeJson,
      'after_json': revision.afterJson,
      'reason': revision.reason,
      'changed_fields': revision.changedFields,
      'created_at': revision.createdAt,
      'applied': revision.applied ? 1 : 0,
    });
  }

  async getLatestApplied(sourceUrl: string): Promise<SourceRevision | null> {
    const predicates = new relationalStore.RdbPredicates(SourceRevisionTable.TABLE_NAME);
    predicates.equalTo('source_url', sourceUrl);
    predicates.equalTo('applied', 1);
    predicates.orderByDesc('created_at');
    predicates.limitAs(1);
    const rs = await RdbUtil.query(this.db_, predicates, []);
    const revision = RdbUtil.next(rs) ? this.fromResult_(rs) : null;
    RdbUtil.close(rs);
    return revision;
  }

  async markRolledBack(id: number): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(SourceRevisionTable.TABLE_NAME);
    predicates.equalTo('id', id);
    await RdbUtil.update(this.db_, { 'applied': 0 }, predicates);
  }

  private fromResult_(rs: relationalStore.ResultSet): SourceRevision {
    return {
      id: RdbUtil.long(rs, 'id'),
      sourceId: RdbUtil.long(rs, 'source_id'),
      sourceUrl: RdbUtil.string(rs, 'source_url') || '',
      beforeJson: RdbUtil.string(rs, 'before_json') || '',
      afterJson: RdbUtil.string(rs, 'after_json') || '',
      reason: RdbUtil.string(rs, 'reason') || '',
      changedFields: RdbUtil.string(rs, 'changed_fields') || '',
      createdAt: RdbUtil.long(rs, 'created_at'),
      applied: RdbUtil.long(rs, 'applied') === 1,
    };
  }
}
