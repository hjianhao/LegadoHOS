import relationalStore from '@ohos.data.relationalStore';
import { BookChapter, createDefaultChapter } from '../../model/BookChapter';
import { BookSourceChapter } from '../../model/BookSource';
import { RdbUtil } from './RdbUtil';

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
    const rs = await RdbUtil.query(this.rdbStore, predicates, []);
    return this.toChapters(rs);
  }

  async getChapterById(id: number): Promise<BookChapter | null> {
    const predicates = new relationalStore.RdbPredicates(ChapterTable.TABLE_NAME);
    predicates.equalTo('id', id);
    const rs = await RdbUtil.query(this.rdbStore, predicates, []);
    const chapters = this.toChapters(rs);
    return chapters.length > 0 ? chapters[0] : null;
  }

  async getChapterByIndex(bookId: number, index: number): Promise<BookChapter | null> {
    const predicates = new relationalStore.RdbPredicates(ChapterTable.TABLE_NAME);
    predicates.equalTo('book_id', bookId);
    predicates.equalTo('chapter_index', index);
    const rs = await RdbUtil.query(this.rdbStore, predicates, []);
    const chapters = this.toChapters(rs);
    return chapters.length > 0 ? chapters[0] : null;
  }

  async insertChapters(chapters: BookChapter[]): Promise<void> {
    const rows: Array<relationalStore.ValuesBucket> = [];
    for (const ch of chapters) {
      rows.push(this.toRow(ch));
    }
    if (rows.length > 0) {
      await RdbUtil.batchInsert(this.rdbStore, ChapterTable.TABLE_NAME, rows);
    }
  }

  async updateChapter(chapter: BookChapter): Promise<void> {
    const row = this.toRow(chapter);
    const predicates = new relationalStore.RdbPredicates(ChapterTable.TABLE_NAME);
    predicates.equalTo('id', chapter.id);
    await RdbUtil.update(this.rdbStore, row, predicates);
  }

  async deleteChaptersByBookId(bookId: number): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(ChapterTable.TABLE_NAME);
    predicates.equalTo('book_id', bookId);
    await RdbUtil.delete(this.rdbStore, predicates);
  }

  async clearContentByBookId(bookId: number): Promise<void> {
    const predicates = new relationalStore.RdbPredicates(ChapterTable.TABLE_NAME);
    predicates.equalTo('book_id', bookId);
    await RdbUtil.update(this.rdbStore, {
      'content': '',
      'content_length': 0,
      'is_cached': 0,
      'is_downloaded': 0,
      'update_time': Date.now(),
    }, predicates);
  }

  async getChapterCount(bookId: number): Promise<number> {
    const predicates = new relationalStore.RdbPredicates(ChapterTable.TABLE_NAME);
    predicates.equalTo('book_id', bookId);
    const rs = await RdbUtil.query(this.rdbStore, predicates, []);
    let count = 0;
    try { while (RdbUtil.next(rs)) { count++; } } catch (_catchErr) {}
    RdbUtil.close(rs);
    return count;
  }

  /** 已缓存章节数（content_length > 10，只查 id 列不加载内容，供列表页轮询） */
  async getCachedChapterCount(bookId: number): Promise<number> {
    const predicates = new relationalStore.RdbPredicates(ChapterTable.TABLE_NAME);
    predicates.equalTo('book_id', bookId);
    predicates.greaterThan('content_length', 10);
    const rs = await RdbUtil.query(this.rdbStore, predicates, ['id']);
    let count = 0;
    try { while (RdbUtil.next(rs)) { count++; } } catch (_catchErr) {}
    RdbUtil.close(rs);
    return count;
  }

  /** 整书目录落库，按规范化 URL 保留阅读、缓存、下载及音频状态。 */
  async replaceTocPreserveContent(bookId: number, chapters: BookSourceChapter[]): Promise<void> {
    const oldChapters = await this.getChaptersByBookId(bookId);
    const oldByUrl = new Map<string, BookChapter>();
    for (const old of oldChapters) {
      const key = (old.url || '').replace(/#.*$/, '');
      if (key) oldByUrl.set(key, old);
    }
    await this.deleteChaptersByBookId(bookId);
    const now = Date.now();
    const newChapters: BookChapter[] = chapters.map((ch: BookSourceChapter, idx: number): BookChapter => {
      const key = (ch.url || '').replace(/#.*$/, '');
      const old = oldByUrl.get(key);
      const item = old || createDefaultChapter();
      item.id = 0;
      item.bookId = bookId;
      item.index = ch.index >= 0 ? ch.index : idx;
      item.title = ch.title || '';
      item.url = key;
      item.createTime = old ? old.createTime : now;
      item.updateTime = now;
      return item;
    });
    await this.insertChapters(newChapters);
  }

  private toChapters(rs: relationalStore.ResultSet): BookChapter[] {
    const chapters: BookChapter[] = [];
    while (RdbUtil.next(rs)) {
      chapters.push({
        id: RdbUtil.long(rs, 'id'),
        bookId: RdbUtil.long(rs, 'book_id'),
        index: RdbUtil.long(rs, 'chapter_index'),
        volumeIndex: RdbUtil.long(rs, 'volume_index'),
        title: RdbUtil.string(rs, 'title') || '',
        url: RdbUtil.string(rs, 'url') || '',
        content: RdbUtil.string(rs, 'content') || '',
        contentLength: RdbUtil.long(rs, 'content_length'),
        isRead: RdbUtil.long(rs, 'is_read') === 1,
        isDownloaded: RdbUtil.long(rs, 'is_downloaded') === 1,
        isCached: RdbUtil.long(rs, 'is_cached') === 1,
        duration: RdbUtil.long(rs, 'duration'),
        audioUrl: RdbUtil.string(rs, 'audio_url') || '',
        createTime: RdbUtil.long(rs, 'create_time'),
        updateTime: RdbUtil.long(rs, 'update_time'),
        start: RdbUtil.long(rs, 'start'),
        end: RdbUtil.long(rs, 'end'),
      });
    }
    RdbUtil.close(rs);
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
      'start': ch.start,
      'end': ch.end,
    };
  }
}
