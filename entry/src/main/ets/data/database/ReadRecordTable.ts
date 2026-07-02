import relationalStore from '@ohos.data.relationalStore';
import { ReadRecord, ReadRecordDetail } from '../../model/ReadRecord';
import { RdbUtil } from './RdbUtil';

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
    const rs = await RdbUtil.query(this.rdbStore, p, []);
    if (RdbUtil.first(rs)) {
      const id = RdbUtil.long(rs, 'id');
      RdbUtil.close(rs);
      const up = new relationalStore.RdbPredicates(READ_RECORD_TABLE);
      up.equalTo('id', id);
      await RdbUtil.update(this.rdbStore, {
        'duration': record.duration, 'chapter_count': record.chapterCount,
      }, up);
    } else {
      RdbUtil.close(rs);
      await RdbUtil.insert(this.rdbStore, READ_RECORD_TABLE, {
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
    const rs = await RdbUtil.query(this.rdbStore, p, []);
    const list: ReadRecord[] = [];
    while (RdbUtil.next(rs)) {
      list.push({
        id: RdbUtil.long(rs, 'id'),
        bookId: RdbUtil.long(rs, 'book_id'),
        date: RdbUtil.string(rs, 'record_date') || '',
        duration: RdbUtil.long(rs, 'duration'),
        chapterCount: RdbUtil.long(rs, 'chapter_count'),
        startTime: RdbUtil.long(rs, 'start_time'),
      });
    }
    RdbUtil.close(rs);
    return list;
  }

  async getTotalDuration(bookId: number): Promise<number> {
    // 直接用 SQL 查询
    const sql = `SELECT SUM(duration) as total FROM ${READ_RECORD_TABLE} WHERE book_id = ?`;
    const rs = await RdbUtil.querySql(this.rdbStore, sql, [bookId]);
    let total = 0;
    if (RdbUtil.first(rs)) total = RdbUtil.longAt(rs, 0);
    RdbUtil.close(rs);
    return total;
  }
}
