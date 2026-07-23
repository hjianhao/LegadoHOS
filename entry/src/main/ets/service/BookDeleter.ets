/**
 * 统一书籍删除服务
 *
 * 彻底删除一本书的所有资源：DB 记录 + 本地文件 + 所有缓存。
 * 所有删除入口（书架长按删除、批量删除、详情页移出书架、管理页移出书架）
 * 以及换源时删重复记录，都统一调用此服务，避免清理逻辑散落各处。
 *
 * 清理范围：
 * - DB: chapters（含缓存正文）、ai_book_profiles、bookmarks、read_records + read_record_details、books
 * - 文件: 本地书原始文件（originUrl）、EPUB 解压目录（tocUrl）、EPUB 封面（customCoverPath）
 * - 缓存: 漫画图片缓存（manga_cache_v3/{bookId}/）、封面缓存（covers/{bookId}.jpg）
 */
import fileFs from '@ohos.file.fs';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookTable } from '../data/database/BookTable';
import { ChapterTable } from '../data/database/ChapterTable';
import { BookmarkTable } from '../data/database/BookmarkTable';
import { ReadRecordTable } from '../data/database/ReadRecordTable';
import { AiBookProfileTable } from '../data/database/AiBookProfileTable';
import { Book } from '../model/Book';
import { LocalBookEngine, LOCAL_BOOK_ORIGIN } from '../engine/book/LocalBookEngine';
import { MangaImageLoader } from '../util/MangaImageLoader';
import { BookCoverUtil } from '../util/BookCoverUtil';
import { FileUtil } from '../util/FileUtil';
import { CloudBookBindingRepository } from './cloud/CloudBookBindingRepository';

export class BookDeleter {
  /**
   * 彻底删除一本书：DB 记录 + 本地文件 + 所有缓存。
   * 每一步都独立 try-catch，单步失败不影响其他清理。
   */
  static async deleteBook(book: Book): Promise<void> {
    if (!book || book.id <= 0) return;
    await AppDatabase.getInstance().waitForInit();
    const db = AppDatabase.getInstance().rdbStore;
    const bookId: number = book.id;

    // 0. 云端 Binding：默认仅解绑，不删远端文件（阶段 4）
    try {
      await new CloudBookBindingRepository().unlinkBook(bookId);
    } catch (e) {
      console.warn('[BookDeleter] unlink cloud binding failed:', bookId, (e as Error).message);
    }

    // 1. DB: chapters（含缓存正文）
    try {
      await new ChapterTable(db).deleteChaptersByBookId(bookId);
    } catch (e) { console.warn('[BookDeleter] delete chapters failed:', bookId, (e as Error).message); }

    // 2. DB: ai_book_profiles
    try {
      await new AiBookProfileTable(db).deleteByBookId(bookId);
    } catch (e) { console.warn('[BookDeleter] delete ai_profile failed:', bookId, (e as Error).message); }

    // 3. DB: bookmarks
    try {
      await new BookmarkTable(db).deleteByBookId(bookId);
    } catch (e) { console.warn('[BookDeleter] delete bookmarks failed:', bookId, (e as Error).message); }

    // 4. DB: read_records + read_record_details
    try {
      await new ReadRecordTable(db).deleteByBookId(bookId);
    } catch (e) { console.warn('[BookDeleter] delete read_records failed:', bookId, (e as Error).message); }

    // 5. DB: books 行（BookTable.deleteBook 内部也会清 ai_book_profiles，这里再调一次确保干净）
    try {
      await new BookTable(db).deleteBook(bookId);
    } catch (e) { console.warn('[BookDeleter] delete book row failed:', bookId, (e as Error).message); }

    // 6~8. 文件清理：仅本地书（originUrl/tocUrl/customCoverPath 是本地路径）
    if (LocalBookEngine.isLocalBook(book)) {
      // 6. 本地书原始文件（txt/epub/azw3/pdf 等）
      BookDeleter.deleteFileIfExists_(book.originUrl);
      // 7. EPUB 解压目录（递归删除）
      BookDeleter.removeDirIfExists_(book.tocUrl);
      // 8. EPUB 封面文件（books/covers/<title>.<ext>）
      BookDeleter.deleteFileIfExists_(book.customCoverPath);
    }

    // 9. 缓存: 漫画图片缓存（manga_cache_v3/{bookId}/）
    try {
      await MangaImageLoader.clearCacheForBook(bookId);
    } catch (e) { console.warn('[BookDeleter] clear manga cache failed:', bookId, (e as Error).message); }

    // 10. 缓存: 封面缓存（covers/{bookId}.jpg）
    try {
      await BookCoverUtil.clearCacheForBook(bookId);
    } catch (e) { console.warn('[BookDeleter] clear cover cache failed:', bookId, (e as Error).message); }

    console.info('[BookDeleter] deleted book:', bookId, book.name);
  }

  /** 批量删除 */
  static async deleteBooks(books: Book[]): Promise<void> {
    for (const book of books) {
      await BookDeleter.deleteBook(book);
    }
  }

  /** 删除文件（存在才删，不存在静默） */
  private static deleteFileIfExists_(filePath: string): void {
    if (!filePath) return;
    try {
      if (fileFs.accessSync(filePath)) {
        fileFs.unlinkSync(filePath);
      }
    } catch (_) { /* 文件可能已被删除 */ }
  }

  /** 递归删除目录（存在才删，不存在静默） */
  private static removeDirIfExists_(dirPath: string): void {
    if (!dirPath) return;
    FileUtil.removeDirRecursive(dirPath);
  }
}
