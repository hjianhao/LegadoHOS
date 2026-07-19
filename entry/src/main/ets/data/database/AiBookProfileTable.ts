import relationalStore from '@ohos.data.relationalStore';
import { AiBookProfile } from '../../model/AiBookProfile';
import { RdbUtil } from './RdbUtil';

export const AiBookProfileTableCreate = `
  CREATE TABLE IF NOT EXISTS ai_book_profiles (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    book_id INTEGER NOT NULL UNIQUE,
    book_url TEXT NOT NULL,
    base_url TEXT DEFAULT '',
    toc_url TEXT DEFAULT '',
    source_json TEXT NOT NULL,
    created_at INTEGER DEFAULT 0,
    updated_at INTEGER DEFAULT 0,
    last_refresh_at INTEGER DEFAULT 0,
    consecutive_failures INTEGER DEFAULT 0,
    rule_version INTEGER DEFAULT 1
  )
`;

export class AiBookProfileTable {
  static readonly TABLE_NAME = 'ai_book_profiles';
  private db_: relationalStore.RdbStore;

  constructor(db: relationalStore.RdbStore) {
    this.db_ = db;
  }

  async getByBookId(bookId: number): Promise<AiBookProfile | null> {
    const predicates = new relationalStore.RdbPredicates(AiBookProfileTable.TABLE_NAME);
    predicates.equalTo('book_id', bookId);
    const rs = await RdbUtil.query(this.db_, predicates, []);
    const profile = RdbUtil.next(rs) ? this.fromResult_(rs) : null;
    RdbUtil.close(rs);
    return profile;
  }

  async getByBookUrl(bookUrl: string): Promise<AiBookProfile | null> {
    const predicates = new relationalStore.RdbPredicates(AiBookProfileTable.TABLE_NAME);
    predicates.equalTo('book_url', bookUrl);
    const rs = await RdbUtil.query(this.db_, predicates, []);
    const profile = RdbUtil.next(rs) ? this.fromResult_(rs) : null;
    RdbUtil.close(rs);
    return profile;
  }

  async upsert(profile: AiBookProfile): Promise<number> {
    const old = await this.getByBookId(profile.bookId);
    const row = this.toRow_(profile);
    if (old) {
      const predicates = new relationalStore.RdbPredicates(AiBookProfileTable.TABLE_NAME);
      predicates.equalTo('book_id', profile.bookId);
      await RdbUtil.update(this.db_, row, predicates);
      return old.id;
    }
    return await RdbUtil.insert(this.db_, AiBookProfileTable.TABLE_NAME, row);
  }

  async deleteByBookId(bookId: number): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(AiBookProfileTable.TABLE_NAME);
    predicates.equalTo('book_id', bookId);
    await RdbUtil.delete(this.db_, predicates);
  }

  async markRefresh(bookId: number, success: boolean): Promise<void> {
    const old = await this.getByBookId(bookId);
    if (!old) return;
    const predicates = new relationalStore.RdbPredicates(AiBookProfileTable.TABLE_NAME);
    predicates.equalTo('book_id', bookId);
    await RdbUtil.update(this.db_, {
      'last_refresh_at': Date.now(),
      'updated_at': Date.now(),
      'consecutive_failures': success ? 0 : old.consecutiveFailures + 1,
    }, predicates);
  }

  private fromResult_(rs: relationalStore.ResultSet): AiBookProfile {
    return {
      id: RdbUtil.long(rs, 'id'),
      bookId: RdbUtil.long(rs, 'book_id'),
      bookUrl: RdbUtil.string(rs, 'book_url') || '',
      baseUrl: RdbUtil.string(rs, 'base_url') || '',
      tocUrl: RdbUtil.string(rs, 'toc_url') || '',
      sourceJson: RdbUtil.string(rs, 'source_json') || '',
      createdAt: RdbUtil.long(rs, 'created_at'),
      updatedAt: RdbUtil.long(rs, 'updated_at'),
      lastRefreshAt: RdbUtil.long(rs, 'last_refresh_at'),
      consecutiveFailures: RdbUtil.long(rs, 'consecutive_failures'),
      ruleVersion: RdbUtil.long(rs, 'rule_version') || 1,
    };
  }

  private toRow_(profile: AiBookProfile): relationalStore.ValuesBucket {
    return {
      'book_id': profile.bookId,
      'book_url': profile.bookUrl,
      'base_url': profile.baseUrl,
      'toc_url': profile.tocUrl,
      'source_json': profile.sourceJson,
      'created_at': profile.createdAt,
      'updated_at': profile.updatedAt,
      'last_refresh_at': profile.lastRefreshAt,
      'consecutive_failures': profile.consecutiveFailures,
      'rule_version': profile.ruleVersion,
    };
  }
}
