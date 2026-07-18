/**
 * 书籍表
 * 对应原 Legado books 表
 */
import relationalStore from '@ohos.data.relationalStore';
import { Book, BookType, BookGroup, createDefaultBook } from '../../model/Book';
import { RdbUtil } from './RdbUtil';

export const BookTableCreate = `
  CREATE TABLE IF NOT EXISTS books (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    author TEXT DEFAULT '',
    cover_url TEXT DEFAULT '',
    custom_cover_path TEXT DEFAULT '',
    book_url TEXT DEFAULT '',
    origin TEXT DEFAULT '',
    origin_url TEXT DEFAULT '',
    type INTEGER DEFAULT 0,
    group_id INTEGER DEFAULT 0,
    toc_url TEXT DEFAULT '',
    chapter_count INTEGER DEFAULT 0,
    total_chapter_num INTEGER DEFAULT 0,
    latest_chapter_title TEXT DEFAULT '',
    dur_chapter_title TEXT DEFAULT '',
    dur_chapter_index INTEGER DEFAULT 0,
    dur_chapter_pos INTEGER DEFAULT 0,
    dur_chapter_progress REAL DEFAULT 0.0,
    is_read INTEGER DEFAULT 0,
    is_audio INTEGER DEFAULT 0,
    is_manga INTEGER DEFAULT 0,
    is_shelf INTEGER DEFAULT 1,
    book_order INTEGER DEFAULT 0,
    can_update INTEGER DEFAULT 1,
    kind TEXT DEFAULT '',
    word_count TEXT DEFAULT '',
    introduce TEXT DEFAULT '',
    remark TEXT DEFAULT '',
    last_update_time TEXT DEFAULT '',
	    last_open_time INTEGER DEFAULT 0,
	    create_time INTEGER DEFAULT 0,
	    update_time INTEGER DEFAULT 0,
	    sync_time INTEGER DEFAULT 0
	  );
`;

export class BookTable {
  static readonly TABLE_NAME = 'books';

  private rdbStore: relationalStore.RdbStore;

  constructor(rdbStore: relationalStore.RdbStore) {
    this.rdbStore = rdbStore;
  }

  // ---- 书架查询 ----
  async getAllShelfBooks(): Promise<Book[]> {
    const predicates = new relationalStore.RdbPredicates(BookTable.TABLE_NAME);
    predicates.equalTo('is_shelf', 1);
    predicates.orderByDesc('last_open_time');
    const resultSet = await RdbUtil.query(this.rdbStore, predicates, []);
    return this.toBooks(resultSet);
  }

  async getBooksByGroup(groupId: number): Promise<Book[]> {
    const predicates = new relationalStore.RdbPredicates(BookTable.TABLE_NAME);
    predicates.equalTo('is_shelf', 1);
    if (groupId >= BookGroup.CUSTOM) {
      predicates.equalTo('group_id', groupId);
    }
    predicates.orderByDesc('last_open_time');
    const resultSet = await RdbUtil.query(this.rdbStore, predicates, []);
    return this.toBooks(resultSet);
  }

  async getBookByName(name: string, author: string): Promise<Book | null> {
    const predicates = new relationalStore.RdbPredicates(BookTable.TABLE_NAME);
    predicates.equalTo('name', name);
    predicates.equalTo('author', author);
    const resultSet = await RdbUtil.query(this.rdbStore, predicates, []);
    const books = this.toBooks(resultSet);
    return books.length > 0 ? books[0] : null;
  }

  async getBookById(id: number): Promise<Book | null> {
    const predicates = new relationalStore.RdbPredicates(BookTable.TABLE_NAME);
    predicates.equalTo('id', id);
    const resultSet = await RdbUtil.query(this.rdbStore, predicates, []);
    const books = this.toBooks(resultSet);
    return books.length > 0 ? books[0] : null;
  }

  async getBookByUrl(bookUrl: string): Promise<Book | null> {
    const predicates = new relationalStore.RdbPredicates(BookTable.TABLE_NAME);
    predicates.equalTo('book_url', bookUrl);
    const resultSet = await RdbUtil.query(this.rdbStore, predicates, []);
    const books = this.toBooks(resultSet);
    return books.length > 0 ? books[0] : null;
  }

  async searchBooks(keyword: string): Promise<Book[]> {
    const predicates = new relationalStore.RdbPredicates(BookTable.TABLE_NAME);
    predicates.like('name', `%${keyword}%`);
    predicates.or();
    predicates.like('author', `%${keyword}%`);
    const resultSet = await RdbUtil.query(this.rdbStore, predicates, []);
    return this.toBooks(resultSet);
  }

  // ---- CRUD ----
  async insertBook(book: Book): Promise<number> {
    const row = this.toRow(book);
    return await RdbUtil.insert(this.rdbStore, BookTable.TABLE_NAME, row);
  }

  async updateBook(book: Book): Promise<void> {
    const row = this.toRow(book);
    const predicates = new relationalStore.RdbPredicates(BookTable.TABLE_NAME);
    predicates.equalTo('id', book.id);
    await RdbUtil.update(this.rdbStore, row, predicates);
  }

  async deleteBook(id: number): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(BookTable.TABLE_NAME);
    predicates.equalTo('id', id);
    await RdbUtil.delete(this.rdbStore, predicates);
  }

  async deleteBooks(ids: number[]): Promise<void> {
    if (ids.length === 0) return;
    const predicates = new relationalStore.RdbPredicates(BookTable.TABLE_NAME);
    predicates.in('id', ids);
    await RdbUtil.delete(this.rdbStore, predicates);
  }

  async setShelfByIds(ids: number[], isShelf: boolean): Promise<void> {
    if (ids.length === 0) return;
    const predicates = new relationalStore.RdbPredicates(BookTable.TABLE_NAME);
    predicates.in('id', ids);
    await RdbUtil.update(this.rdbStore, {
      'is_shelf': isShelf ? 1 : 0,
      'update_time': Date.now(),
    }, predicates);
  }

  async batchUpdateGroup(ids: number[], groupId: number): Promise<void> {
    if (ids.length === 0) return;
    const predicates = new relationalStore.RdbPredicates(BookTable.TABLE_NAME);
    predicates.in('id', ids);
    await RdbUtil.update(this.rdbStore, {
      'group_id': groupId,
      'update_time': Date.now(),
    }, predicates);
  }

  async batchUpdateGroupForDelete(groupId: number): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(BookTable.TABLE_NAME);
    predicates.equalTo('group_id', groupId);
    await RdbUtil.update(this.rdbStore, {
      'group_id': BookGroup.ALL,
      'update_time': Date.now(),
    }, predicates);
  }

  async updateTocInfo(bookId: number, totalChapterNum: number, latestChapterTitle: string): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(BookTable.TABLE_NAME);
    predicates.equalTo('id', bookId);
    await RdbUtil.update(this.rdbStore, {
      'chapter_count': totalChapterNum,
      'total_chapter_num': totalChapterNum,
      'latest_chapter_title': latestChapterTitle,
      'update_time': Date.now(),
    }, predicates);
  }

  async getMinOrder(): Promise<number> {
    const rs = await RdbUtil.querySql(this.rdbStore, `SELECT MIN(book_order) FROM ${BookTable.TABLE_NAME}`, []);
    let minOrder = 0;
    if (RdbUtil.first(rs)) {
      minOrder = RdbUtil.longAt(rs, 0) || 0;
    }
    RdbUtil.close(rs);
    return minOrder;
  }

  async updateRemark(bookId: number, remark: string): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(BookTable.TABLE_NAME);
    predicates.equalTo('id', bookId);
    await RdbUtil.update(this.rdbStore, {
      'remark': remark,
      'update_time': Date.now(),
    }, predicates);
  }

  // ---- 工具 ----
  private toBooks(rs: relationalStore.ResultSet): Book[] {
    const books: Book[] = [];
    while (RdbUtil.next(rs)) {
      books.push({
        id: RdbUtil.long(rs, 'id'),
        name: RdbUtil.string(rs, 'name') || '',
        author: RdbUtil.string(rs, 'author') || '',
        coverUrl: RdbUtil.string(rs, 'cover_url') || '',
        customCoverPath: RdbUtil.string(rs, 'custom_cover_path') || '',
        bookUrl: RdbUtil.string(rs, 'book_url') || '',
        origin: RdbUtil.string(rs, 'origin') || '',
        originUrl: RdbUtil.string(rs, 'origin_url') || '',
        type: RdbUtil.long(rs, 'type') as BookType,
        groupId: RdbUtil.long(rs, 'group_id'),
        tocUrl: RdbUtil.string(rs, 'toc_url') || '',
        chapterCount: RdbUtil.long(rs, 'chapter_count'),
        totalChapterNum: RdbUtil.long(rs, 'total_chapter_num'),
        latestChapterTitle: RdbUtil.string(rs, 'latest_chapter_title') || '',
        durChapterTitle: RdbUtil.string(rs, 'dur_chapter_title') || '',
        durChapterIndex: RdbUtil.long(rs, 'dur_chapter_index'),
        durChapterPos: RdbUtil.long(rs, 'dur_chapter_pos'),
        durChapterProgress: RdbUtil.double(rs, 'dur_chapter_progress'),
        isRead: RdbUtil.long(rs, 'is_read') === 1,
        isAudio: RdbUtil.long(rs, 'is_audio') === 1,
        isManga: RdbUtil.long(rs, 'is_manga') === 1,
        isShelf: RdbUtil.long(rs, 'is_shelf') === 1,
        order: RdbUtil.long(rs, 'book_order'),
        canUpdate: RdbUtil.long(rs, 'can_update') !== 0,
        kind: RdbUtil.string(rs, 'kind') || '',
        wordCount: RdbUtil.string(rs, 'word_count') || '',
        introduce: RdbUtil.string(rs, 'introduce') || '',
        remark: RdbUtil.string(rs, 'remark') || '',
        lastUpdateTime: RdbUtil.string(rs, 'last_update_time') || '',
        lastOpenTime: RdbUtil.long(rs, 'last_open_time'),
        createTime: RdbUtil.long(rs, 'create_time'),
        updateTime: RdbUtil.long(rs, 'update_time'),
        syncTime: RdbUtil.long(rs, 'sync_time'),
        charset: RdbUtil.string(rs, 'charset') || '',
      });
    }
    RdbUtil.close(rs);
    return books;
  }

  private toRow(book: Book): relationalStore.ValuesBucket {
    return {
      'name': book.name,
      'author': book.author,
      'cover_url': book.coverUrl,
      'custom_cover_path': book.customCoverPath,
      'book_url': book.bookUrl,
      'origin': book.origin,
      'origin_url': book.originUrl,
      'type': book.type,
      'group_id': book.groupId,
      'toc_url': book.tocUrl,
      'chapter_count': book.chapterCount,
      'total_chapter_num': book.totalChapterNum,
      'latest_chapter_title': book.latestChapterTitle || '',
      'dur_chapter_title': book.durChapterTitle,
      'dur_chapter_index': book.durChapterIndex,
      'dur_chapter_pos': book.durChapterPos,
      'dur_chapter_progress': book.durChapterProgress,
      'is_read': book.isRead ? 1 : 0,
      'is_audio': book.isAudio ? 1 : 0,
      'is_manga': book.isManga ? 1 : 0,
      'is_shelf': book.isShelf ? 1 : 0,
      'book_order': book.order,
      'can_update': book.canUpdate ? 1 : 0,
      'kind': book.kind,
      'word_count': book.wordCount,
      'introduce': book.introduce,
      'remark': book.remark || '',
      'last_update_time': book.lastUpdateTime,
      'last_open_time': book.lastOpenTime,
      'create_time': book.createTime,
      'update_time': book.lastOpenTime, // 用最后阅读时间同时作为 update_time
      'sync_time': book.syncTime,
      'charset': book.charset || '',
    };
  }

  /** 快速更新阅读进度（无需构造完整 Book 对象） */
  async updateReadingProgress(bookUrl: string, chapterIndex: number, chapterTitle: string,
    totalChapters: number, chapterPos: number = 0): Promise<void> {
    const now = Date.now();
    const row: relationalStore.ValuesBucket = {
      'dur_chapter_index': chapterIndex,
      'dur_chapter_title': chapterTitle,
      'dur_chapter_pos': chapterPos,
      'last_open_time': now,
      'update_time': now,
    };
    if (totalChapters > 0) {
      row['total_chapter_num'] = totalChapters;
      row['chapter_count'] = totalChapters;
    }
    const pred = new relationalStore.RdbPredicates(BookTable.TABLE_NAME);
    pred.equalTo('book_url', bookUrl);
    await RdbUtil.update(this.rdbStore, row, pred);
  }

  /** 更新上次同步时间 */
  async updateSyncTime(bookUrl: string, syncTime: number): Promise<void> {
    const pred = new relationalStore.RdbPredicates(BookTable.TABLE_NAME);
    pred.equalTo('book_url', bookUrl);
    await RdbUtil.update(this.rdbStore, { 'sync_time': syncTime }, pred);
  }

  /** 获取所有在架书籍（用于批量同步） */
  async getAllShelfBooksSimple(): Promise<Array<{ name: string; author: string; bookUrl: string;
    durChapterIndex: number; durChapterPos: number; syncTime: number }>> {
    const rs = await RdbUtil.querySql(this.rdbStore,
      `SELECT name, author, book_url, dur_chapter_index, dur_chapter_pos, sync_time
       FROM ${BookTable.TABLE_NAME} WHERE is_shelf = 1`, []);
    const result: Array<{ name: string; author: string; bookUrl: string;
      durChapterIndex: number; durChapterPos: number; syncTime: number }> = [];
    while (RdbUtil.next(rs)) {
      result.push({
        name: RdbUtil.string(rs, 'name') || '',
        author: RdbUtil.string(rs, 'author') || '',
        bookUrl: RdbUtil.string(rs, 'book_url') || '',
        durChapterIndex: RdbUtil.long(rs, 'dur_chapter_index'),
        durChapterPos: RdbUtil.long(rs, 'dur_chapter_pos'),
        syncTime: RdbUtil.long(rs, 'sync_time'),
      });
    }
    RdbUtil.close(rs);
    return result;
  }
}
