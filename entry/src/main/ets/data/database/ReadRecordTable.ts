import relationalStore from '@ohos.data.relationalStore';
import { ReadRecord, ReadRecordDetail } from '../../model/ReadRecord';

const READ_RECORD_TABLE = 'read_records';
const READ_DETAIL_TABLE = 'read_record_details';

export const ReadRecordTableCreate = `
  CREATE TABLE IF NOT EXISTS ${READ_RECORD_TABLE} (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    book_id INTEGER NOT NULL,
    record_date TEXT NOT NULL,
    duration INTEGER DEFAULT 0,
    chapter_count INTEGER DEFAULT 0,
    start_time INTEGER DEFAULT 0
  );
`;

export const ReadRecordDetailTableCreate = `
  CREATE TABLE IF NOT EXISTS ${READ_DETAIL_TABLE} (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    record_id INTEGER,
    book_id INTEGER NOT NULL,
    chapter_index INTEGER DEFAULT 0,
    start_time INTEGER DEFAULT 0,
    duration INTEGER DEFAULT 0
  );
`;

export class ReadRecordTable {
  private rdbStore: relationalStore.RdbStore;
  constructor(rdbStore: relationalStore.RdbStore) { this.rdbStore = rdbStore; }

  async updateOrInsert(record: ReadRecord): Promise<void> {
    const p = new relationalStore.RdbPredicates(READ_RECORD_TABLE);
    p.equalTo('book_id', record.bookId);
    p.equalTo('record_date', record.date);
    const rs = await this.rdbStore.query(p, []);
    if (rs.goToFirstRow()) {
      const id = rs.getLong(rs.getColumnIndex('id'));
      rs.close();
      const up = new relationalStore.RdbPredicates(READ_RECORD_TABLE);
      up.equalTo('id', id);
      await this.rdbStore.update({
        'duration': record.duration, 'chapter_count': record.chapterCount,
      }, up);
    } else {
      rs.close();
      await this.rdbStore.insert(READ_RECORD_TABLE, {
        'book_id': record.bookId, 'record_date': record.date,
        'duration': record.duration, 'chapter_count': record.chapterCount,
        'start_time': record.startTime,
      });
    }
  }

  async getByBookId(bookId: number): Promise<ReadRecord[]> {
    const p = new relationalStore.RdbPredicates(READ_RECORD_TABLE);
    p.equalTo('book_id', bookId);
    p.orderByDesc('record_date');
    const rs = await this.rdbStore.query(p, []);
    const list: ReadRecord[] = [];
    while (rs.goToNextRow()) {
      list.push({
        id: rs.getLong(rs.getColumnIndex('id')),
        bookId: rs.getLong(rs.getColumnIndex('book_id')),
        date: rs.getString(rs.getColumnIndex('record_date')) || '',
        duration: rs.getLong(rs.getColumnIndex('duration')),
        chapterCount: rs.getLong(rs.getColumnIndex('chapter_count')),
        startTime: rs.getLong(rs.getColumnIndex('start_time')),
      });
    }
    rs.close();
    return list;
  }

  async getTotalDuration(bookId: number): Promise<number> {
    // 直接用 SQL 查询
    const sql = `SELECT SUM(duration) as total FROM ${READ_RECORD_TABLE} WHERE book_id = ?`;
    const rs = await this.rdbStore.querySql(sql, [bookId]);
    let total = 0;
    if (rs.goToFirstRow()) total = rs.getLong(0);
    rs.close();
    return total;
  }
}
