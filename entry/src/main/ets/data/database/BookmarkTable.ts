import relationalStore from '@ohos.data.relationalStore';
import { Bookmark } from '../../model/Bookmark';
import { RdbUtil } from './RdbUtil';

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
    const rs = await RdbUtil.query(this.rdbStore, predicates, []);
    return this.toBookmarks(rs);
  }

  /** 全部书签（按书名/章节/位置排序，供全局书签列表） */
  async getAll(): Promise<Bookmark[]> {
    const predicates = new relationalStore.RdbPredicates(BookmarkTable.TABLE_NAME);
    predicates.orderByAsc('book_name');
    predicates.orderByAsc('chapter_index');
    predicates.orderByAsc('chapter_pos');
    const rs = await RdbUtil.query(this.rdbStore, predicates, []);
    return this.toBookmarks(rs);
  }

  async insert(bookmark: Bookmark): Promise<number> {
    return await RdbUtil.insert(this.rdbStore, BookmarkTable.TABLE_NAME, {
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

  async update(bookmark: Bookmark): Promise<void> {
    const p = new relationalStore.RdbPredicates(BookmarkTable.TABLE_NAME);
    p.equalTo('id', bookmark.id);
    await RdbUtil.update(this.rdbStore, {
      'book_id': bookmark.bookId,
      'book_name': bookmark.bookName,
      'book_author': bookmark.bookAuthor,
      'chapter_index': bookmark.chapterIndex,
      'chapter_name': bookmark.chapterName,
      'chapter_pos': bookmark.chapterPos,
      'text': bookmark.text,
      'note': bookmark.note,
      'update_time': bookmark.updateTime,
    }, p);
  }

  async delete(id: number): Promise<void> {
    const p = new relationalStore.RdbPredicates(BookmarkTable.TABLE_NAME);
    p.equalTo('id', id);
    await RdbUtil.delete(this.rdbStore, p);
  }

  private toBookmarks(rs: relationalStore.ResultSet): Bookmark[] {
    const list: Bookmark[] = [];
    while (RdbUtil.next(rs)) {
      list.push({
        id: RdbUtil.long(rs, 'id'),
        bookId: RdbUtil.long(rs, 'book_id'),
        bookName: RdbUtil.string(rs, 'book_name') || '',
        bookAuthor: RdbUtil.string(rs, 'book_author') || '',
        chapterIndex: RdbUtil.long(rs, 'chapter_index'),
        chapterName: RdbUtil.string(rs, 'chapter_name') || '',
        chapterPos: RdbUtil.long(rs, 'chapter_pos'),
        text: RdbUtil.string(rs, 'text') || '',
        note: RdbUtil.string(rs, 'note') || '',
        createTime: RdbUtil.long(rs, 'create_time'),
        updateTime: RdbUtil.long(rs, 'update_time'),
      });
    }
    RdbUtil.close(rs);
    return list;
  }
}
