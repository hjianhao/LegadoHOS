import relationalStore from '@ohos.data.relationalStore';
import { RSSSource, RSSArticle } from '../../model/RSSSource';

export const RSSSourceTableCreate = `
  CREATE TABLE IF NOT EXISTS rss_sources (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_url TEXT NOT NULL,
    source_name TEXT DEFAULT '',
    group_id INTEGER DEFAULT 0,
    enabled INTEGER DEFAULT 1,
    create_time INTEGER DEFAULT 0,
    update_time INTEGER DEFAULT 0
  );
`;

export const RSSArticleTableCreate = `
  CREATE TABLE IF NOT EXISTS rss_articles (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source_id INTEGER,
    title TEXT DEFAULT '',
    content TEXT DEFAULT '',
    summary TEXT DEFAULT '',
    link TEXT DEFAULT '',
    author TEXT DEFAULT '',
    pub_date TEXT DEFAULT '',
    is_read INTEGER DEFAULT 0,
    is_star INTEGER DEFAULT 0,
    create_time INTEGER DEFAULT 0
  );
`;

export class RSSSourceTable {
  static readonly TABLE_NAME = 'rss_sources';
  private rdbStore: relationalStore.RdbStore;
  constructor(rdbStore: relationalStore.RdbStore) { this.rdbStore = rdbStore; }
  async getAll(): Promise<RSSSource[]> {
    const p = new relationalStore.RdbPredicates(RSSSourceTable.TABLE_NAME);
    const rs = await this.rdbStore.query(p, []);
    const list: RSSSource[] = [];
    while (rs.goToNextRow()) {
      list.push({
        id: rs.getLong(rs.getColumnIndex('id')),
        sourceUrl: rs.getString(rs.getColumnIndex('source_url')) || '',
        sourceName: rs.getString(rs.getColumnIndex('source_name')) || '',
        groupId: rs.getLong(rs.getColumnIndex('group_id')),
        enabled: rs.getLong(rs.getColumnIndex('enabled')) === 1,
        createTime: rs.getLong(rs.getColumnIndex('create_time')),
        updateTime: rs.getLong(rs.getColumnIndex('update_time')),
      });
    }
    rs.close();
    return list;
  }
}
