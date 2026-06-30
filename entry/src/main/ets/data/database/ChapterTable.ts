import relationalStore from '@ohos.data.relationalStore';
import { BookChapter, createDefaultChapter } from '../../model/BookChapter';

export const ChapterTableCreate = `
  CREATE TABLE IF NOT EXISTS chapters (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    book_id INTEGER NOT NULL,
    chapter_index INTEGER DEFAULT 0,
    volume_index INTEGER DEFAULT 0,
    title TEXT DEFAULT '',
    url TEXT DEFAULT '',
    content TEXT DEFAULT '',
    content_length INTEGER DEFAULT 0,
    is_read INTEGER DEFAULT 0,
    is_downloaded INTEGER DEFAULT 0,
    is_cached INTEGER DEFAULT 0,
    duration INTEGER DEFAULT 0,
    audio_url TEXT DEFAULT '',
    create_time INTEGER DEFAULT 0,
    update_time INTEGER DEFAULT 0,
    FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
  );
`;

export class ChapterTable {
  static readonly TABLE_NAME = 'chapters';
  private rdbStore: relationalStore.RdbStore;

  constructor(rdbStore: relationalStore.RdbStore) {
    this.rdbStore = rdbStore;
  }

  async getChaptersByBookId(bookId: number): Promise<BookChapter[]> {
    const predicates = new relationalStore.RdbPredicates(ChapterTable.TABLE_NAME);
    predicates.equalTo('book_id', bookId);
    predicates.orderByAsc('chapter_index');
    const rs = await this.rdbStore.query(predicates, []);
    return this.toChapters(rs);
  }

  async getChapterById(id: number): Promise<BookChapter | null> {
    const predicates = new relationalStore.RdbPredicates(ChapterTable.TABLE_NAME);
    predicates.equalTo('id', id);
    const rs = await this.rdbStore.query(predicates, []);
    const chapters = this.toChapters(rs);
    return chapters.length > 0 ? chapters[0] : null;
  }

  async getChapterByIndex(bookId: number, index: number): Promise<BookChapter | null> {
    const predicates = new relationalStore.RdbPredicates(ChapterTable.TABLE_NAME);
    predicates.equalTo('book_id', bookId);
    predicates.equalTo('chapter_index', index);
    const rs = await this.rdbStore.query(predicates, []);
    const chapters = this.toChapters(rs);
    return chapters.length > 0 ? chapters[0] : null;
  }

  async insertChapters(chapters: BookChapter[]): Promise<void> {
    for (const ch of chapters) {
      const row = this.toRow(ch);
      await this.rdbStore.insert(ChapterTable.TABLE_NAME, row);
    }
  }

  async updateChapter(chapter: BookChapter): Promise<void> {
    const row = this.toRow(chapter);
    const predicates = new relationalStore.RdbPredicates(ChapterTable.TABLE_NAME);
    predicates.equalTo('id', chapter.id);
    await this.rdbStore.update(row, predicates);
  }

  async deleteChaptersByBookId(bookId: number): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(ChapterTable.TABLE_NAME);
    predicates.equalTo('book_id', bookId);
    await this.rdbStore.delete(predicates);
  }

  async clearContentByBookId(bookId: number): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(ChapterTable.TABLE_NAME);
    predicates.equalTo('book_id', bookId);
    await this.rdbStore.update({
      'content': '',
      'content_length': 0,
      'is_cached': 0,
      'update_time': Date.now(),
    }, predicates);
  }

  async getChapterCount(bookId: number): Promise<number> {
    const predicates = new relationalStore.RdbPredicates(ChapterTable.TABLE_NAME);
    predicates.equalTo('book_id', bookId);
    const rs = await this.rdbStore.query(predicates, []);
    let count = 0;
    try { while (rs.goToNextRow()) { count++; } } catch (_catchErr) {}
    rs.close();
    return count;
  }

  private toChapters(rs: relationalStore.ResultSet): BookChapter[] {
    const chapters: BookChapter[] = [];
    while (rs.goToNextRow()) {
      chapters.push({
        id: rs.getLong(rs.getColumnIndex('id')),
        bookId: rs.getLong(rs.getColumnIndex('book_id')),
        index: rs.getLong(rs.getColumnIndex('chapter_index')),
        volumeIndex: rs.getLong(rs.getColumnIndex('volume_index')),
        title: rs.getString(rs.getColumnIndex('title')) || '',
        url: rs.getString(rs.getColumnIndex('url')) || '',
        content: rs.getString(rs.getColumnIndex('content')) || '',
        contentLength: rs.getLong(rs.getColumnIndex('content_length')),
        isRead: rs.getLong(rs.getColumnIndex('is_read')) === 1,
        isDownloaded: rs.getLong(rs.getColumnIndex('is_downloaded')) === 1,
        isCached: rs.getLong(rs.getColumnIndex('is_cached')) === 1,
        duration: rs.getLong(rs.getColumnIndex('duration')),
        audioUrl: rs.getString(rs.getColumnIndex('audio_url')) || '',
        createTime: rs.getLong(rs.getColumnIndex('create_time')),
        updateTime: rs.getLong(rs.getColumnIndex('update_time')),
      });
    }
    rs.close();
    return chapters;
  }

  private toRow(ch: BookChapter): relationalStore.ValuesBucket {
    return {
      'book_id': ch.bookId,
      'chapter_index': ch.index,
      'volume_index': ch.volumeIndex,
      'title': ch.title,
      'url': ch.url,
      'content': ch.content,
      'content_length': ch.contentLength,
      'is_read': ch.isRead ? 1 : 0,
      'is_downloaded': ch.isDownloaded ? 1 : 0,
      'is_cached': ch.isCached ? 1 : 0,
      'duration': ch.duration,
      'audio_url': ch.audioUrl,
      'create_time': ch.createTime,
      'update_time': ch.updateTime,
    };
  }
}
