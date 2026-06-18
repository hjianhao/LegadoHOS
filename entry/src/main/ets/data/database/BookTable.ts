/**
 * 书籍表
 * 对应原 Legado books 表
 */
import relationalStore from '@ohos.data.relationalStore';
import { Book, BookType, BookGroup, createDefaultBook } from '../../model/Book';

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
    kind TEXT DEFAULT '',
    word_count TEXT DEFAULT '',
    introduce TEXT DEFAULT '',
    last_update_time TEXT DEFAULT '',
    last_open_time INTEGER DEFAULT 0,
    create_time INTEGER DEFAULT 0,
    update_time INTEGER DEFAULT 0
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
    const resultSet = await this.rdbStore.query(predicates, []);
    return this.toBooks(resultSet);
  }

  async getBooksByGroup(groupId: number): Promise<Book[]> {
    const predicates = new relationalStore.RdbPredicates(BookTable.TABLE_NAME);
    predicates.equalTo('is_shelf', 1);
    if (groupId > BookGroup.CUSTOM) {
      predicates.equalTo('group_id', groupId);
    }
    predicates.orderByDesc('last_open_time');
    const resultSet = await this.rdbStore.query(predicates, []);
    return this.toBooks(resultSet);
  }

  async getBookByName(name: string, author: string): Promise<Book | null> {
    const predicates = new relationalStore.RdbPredicates(BookTable.TABLE_NAME);
    predicates.equalTo('name', name);
    predicates.equalTo('author', author);
    const resultSet = await this.rdbStore.query(predicates, []);
    const books = this.toBooks(resultSet);
    return books.length > 0 ? books[0] : null;
  }

  async getBookById(id: number): Promise<Book | null> {
    const predicates = new relationalStore.RdbPredicates(BookTable.TABLE_NAME);
    predicates.equalTo('id', id);
    const resultSet = await this.rdbStore.query(predicates, []);
    const books = this.toBooks(resultSet);
    return books.length > 0 ? books[0] : null;
  }

  async searchBooks(keyword: string): Promise<Book[]> {
    const predicates = new relationalStore.RdbPredicates(BookTable.TABLE_NAME);
    predicates.like('name', `%${keyword}%`);
    predicates.or();
    predicates.like('author', `%${keyword}%`);
    const resultSet = await this.rdbStore.query(predicates, []);
    return this.toBooks(resultSet);
  }

  // ---- CRUD ----
  async insertBook(book: Book): Promise<number> {
    const row = this.toRow(book);
    return await this.rdbStore.insert(BookTable.TABLE_NAME, row);
  }

  async updateBook(book: Book): Promise<void> {
    const row = this.toRow(book);
    const predicates = new relationalStore.RdbPredicates(BookTable.TABLE_NAME);
    predicates.equalTo('id', book.id);
    await this.rdbStore.update(row, predicates);
  }

  async deleteBook(id: number): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(BookTable.TABLE_NAME);
    predicates.equalTo('id', id);
    await this.rdbStore.delete(predicates);
  }

  async deleteBooks(ids: number[]): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(BookTable.TABLE_NAME);
    predicates.in('id', ids);
    await this.rdbStore.delete(predicates);
  }

  // ---- 工具 ----
  private toBooks(rs: relationalStore.ResultSet): Book[] {
    const books: Book[] = [];
    while (rs.goToNextRow()) {
      books.push({
        id: rs.getLong(rs.getColumnIndex('id')),
        name: rs.getString(rs.getColumnIndex('name')) || '',
        author: rs.getString(rs.getColumnIndex('author')) || '',
        coverUrl: rs.getString(rs.getColumnIndex('cover_url')) || '',
        customCoverPath: rs.getString(rs.getColumnIndex('custom_cover_path')) || '',
        bookUrl: rs.getString(rs.getColumnIndex('book_url')) || '',
        origin: rs.getString(rs.getColumnIndex('origin')) || '',
        originUrl: rs.getString(rs.getColumnIndex('origin_url')) || '',
        type: rs.getLong(rs.getColumnIndex('type')) as BookType,
        groupId: rs.getLong(rs.getColumnIndex('group_id')),
        tocUrl: rs.getString(rs.getColumnIndex('toc_url')) || '',
        chapterCount: rs.getLong(rs.getColumnIndex('chapter_count')),
        totalChapterNum: rs.getLong(rs.getColumnIndex('total_chapter_num')),
        latestChapterTitle: rs.getString(rs.getColumnIndex('latest_chapter_title')) || '',
        durChapterTitle: rs.getString(rs.getColumnIndex('dur_chapter_title')) || '',
        durChapterIndex: rs.getLong(rs.getColumnIndex('dur_chapter_index')),
        durChapterPos: rs.getLong(rs.getColumnIndex('dur_chapter_pos')),
        durChapterProgress: rs.getDouble(rs.getColumnIndex('dur_chapter_progress')),
        isRead: rs.getLong(rs.getColumnIndex('is_read')) === 1,
        isAudio: rs.getLong(rs.getColumnIndex('is_audio')) === 1,
        isManga: rs.getLong(rs.getColumnIndex('is_manga')) === 1,
        isShelf: rs.getLong(rs.getColumnIndex('is_shelf')) === 1,
        order: rs.getLong(rs.getColumnIndex('book_order')),
        kind: rs.getString(rs.getColumnIndex('kind')) || '',
        wordCount: rs.getString(rs.getColumnIndex('word_count')) || '',
        introduce: rs.getString(rs.getColumnIndex('introduce')) || '',
        lastUpdateTime: rs.getString(rs.getColumnIndex('last_update_time')) || '',
        lastOpenTime: rs.getLong(rs.getColumnIndex('last_open_time')),
        createTime: rs.getLong(rs.getColumnIndex('create_time')),
        updateTime: rs.getLong(rs.getColumnIndex('update_time')),
      });
    }
    rs.close();
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
      'kind': book.kind,
      'word_count': book.wordCount,
      'introduce': book.introduce,
      'last_update_time': book.lastUpdateTime,
      'last_open_time': book.lastOpenTime,
      'create_time': book.createTime,
      'update_time': book.updateTime,
    };
  }
}
