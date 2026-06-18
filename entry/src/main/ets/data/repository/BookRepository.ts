/**
 * 书籍仓库 — 封装书籍相关数据库操作
 */
import { AppDatabase } from '../database/AppDatabase';
import { BookTable } from '../database/BookTable';
import { ChapterTable } from '../database/ChapterTable';
import { Book } from '../../model/Book';

export class BookRepository {
  private bookTable: BookTable;
  private chapterTable: ChapterTable;

  constructor() {
    const db = AppDatabase.getInstance().rdbStore;
    this.bookTable = new BookTable(db);
    this.chapterTable = new ChapterTable(db);
  }

  async getShelfBooks(): Promise<Book[]> {
    return await this.bookTable.getAllShelfBooks();
  }

  async addBook(book: Book): Promise<number> {
    book.createTime = Date.now();
    book.updateTime = Date.now();
    return await this.bookTable.insertBook(book);
  }

  async removeBook(id: number): Promise<void> {
    await this.chapterTable.deleteChaptersByBookId(id);
    await this.bookTable.deleteBook(id);
  }

  async getBookByName(name: string, author: string): Promise<Book | null> {
    return await this.bookTable.getBookByName(name, author);
  }

  async updateReadingProgress(
    bookId: number,
    chapterIndex: number,
    chapterTitle: string,
    chapterPos: number,
    progress: number
  ): Promise<void> {
    const book = await this.bookTable.getBookById(bookId);
    if (!book) return;
    book.durChapterIndex = chapterIndex;
    book.durChapterTitle = chapterTitle;
    book.durChapterPos = chapterPos;
    book.durChapterProgress = progress;
    book.lastOpenTime = Date.now();
    book.updateTime = Date.now();
    await this.bookTable.updateBook(book);
  }
}
