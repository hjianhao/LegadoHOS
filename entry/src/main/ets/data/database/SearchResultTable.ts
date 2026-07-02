import relationalStore from '@ohos.data.relationalStore';
import { RdbUtil } from './RdbUtil';

export const SearchResultTableCreate = `
  CREATE TABLE IF NOT EXISTS search_results (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    keyword TEXT NOT NULL,
    source_name TEXT DEFAULT '',
    book_name TEXT DEFAULT '',
    book_author TEXT DEFAULT '',
    cover_url TEXT DEFAULT '',
    note_url TEXT DEFAULT '',
    create_time INTEGER DEFAULT 0
  );
`;

export class SearchResultTable {
  static readonly TABLE_NAME = 'search_results';
  private rdbStore: relationalStore.RdbStore;
  constructor(rdbStore: relationalStore.RdbStore) { this.rdbStore = rdbStore; }

  async clearExpired(hours: number = 24): Promise<void> {
    const deadline = Date.now() - hours * 3600 * 1000;
    const p = new relationalStore.RdbPredicates(SearchResultTable.TABLE_NAME);
    p.lessThan('create_time', deadline);
    await RdbUtil.delete(this.rdbStore, p);
  }
}
