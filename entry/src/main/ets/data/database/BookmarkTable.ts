import relationalStore from '@ohos.data.relationalStore';
import { Bookmark } from '../../model/Bookmark';

export const BookmarkTableCreate = `
  CREATE TABLE IF NOT EXISTS bookmarks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    book_id INTEGER NOT NULL,
    book_name TEXT DEFAULT '',
    book_author TEXT DEFAULT '',
    chapter_index INTEGER DEFAULT 0,
    chapter_name TEXT DEFAULT '',
    chapter_pos INTEGER DEFAULT 0,
    text TEXT DEFAULT '',
    note TEXT DEFAULT '',
    create_time INTEGER DEFAULT 0,
    update_time INTEGER DEFAULT 0
  );
`;

export class BookmarkTable {
  static readonly TABLE_NAME = 'bookmarks';
  private rdbStore: relationalStore.RdbStore;

  constructor(rdbStore: relationalStore.RdbStore) {
    this.rdbStore = rdbStore;
  }

  async getByBookId(bookId: number): Promise<Bookmark[]> {
    const predicates = new relationalStore.RdbPredicates(BookmarkTable.TABLE_NAME);
    predicates.equalTo('book_id', bookId);
    predicates.orderByAsc('chapter_index');
    const rs = await this.rdbStore.query(predicates, []);
    return this.toBookmarks(rs);
  }

  async insert(bookmark: Bookmark): Promise<number> {
    return await this.rdbStore.insert(BookmarkTable.TABLE_NAME, {
      'book_id': bookmark.bookId,
      'book_name': bookmark.bookName,
      'book_author': bookmark.bookAuthor,
      'chapter_index': bookmark.chapterIndex,
      'chapter_name': bookmark.chapterName,
      'chapter_pos': bookmark.chapterPos,
      'text': bookmark.text,
      'note': bookmark.note,
      'create_time': bookmark.createTime,
      'update_time': bookmark.updateTime,
    });
  }

  async delete(id: number): Promise<void> {
    const p = new relationalStore.RdbPredicates(BookmarkTable.TABLE_NAME);
    p.equalTo('id', id);
    await this.rdbStore.delete(p);
  }

  private toBookmarks(rs: relationalStore.ResultSet): Bookmark[] {
    const list: Bookmark[] = [];
    while (rs.goToNextRow()) {
      list.push({
        id: rs.getLong(rs.getColumnIndex('id')),
        bookId: rs.getLong(rs.getColumnIndex('book_id')),
        bookName: rs.getString(rs.getColumnIndex('book_name')) || '',
        bookAuthor: rs.getString(rs.getColumnIndex('book_author')) || '',
        chapterIndex: rs.getLong(rs.getColumnIndex('chapter_index')),
        chapterName: rs.getString(rs.getColumnIndex('chapter_name')) || '',
        chapterPos: rs.getLong(rs.getColumnIndex('chapter_pos')),
        text: rs.getString(rs.getColumnIndex('text')) || '',
        note: rs.getString(rs.getColumnIndex('note')) || '',
        createTime: rs.getLong(rs.getColumnIndex('create_time')),
        updateTime: rs.getLong(rs.getColumnIndex('update_time')),
      });
    }
    rs.close();
    return list;
  }
}
