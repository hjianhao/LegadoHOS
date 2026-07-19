import { AppDatabase } from '../data/database/AppDatabase';
import { AiBookProfileTable } from '../data/database/AiBookProfileTable';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { Book } from '../model/Book';
import { BookSource, parseBookSource } from '../model/BookSource';

/** 统一解析正式书源与 AI 单本解析档案。 */
export class BookSourceResolver {
  static async resolve(book: Book): Promise<BookSource | null> {
    await AppDatabase.getInstance().waitForInit();
    const db = AppDatabase.getInstance().rdbStore;
    const sourceDao = new BookSourceTable(db);
    const sources = await sourceDao.getAllSources();
    const regular = sources.find((source: BookSource): boolean =>
      source.sourceUrl === book.originUrl || source.sourceName === book.origin);
    if (regular) return regular;
    return await this.resolveAiProfile_(book.id, book.bookUrl);
  }

  static async resolveByIdentity(bookId: number, bookUrl: string, originUrl: string,
    originName: string): Promise<BookSource | null> {
    await AppDatabase.getInstance().waitForInit();
    const db = AppDatabase.getInstance().rdbStore;
    const sources = await new BookSourceTable(db).getAllSources();
    const regular = sources.find((source: BookSource): boolean =>
      source.sourceUrl === originUrl || source.sourceName === originName);
    if (regular) return regular;
    return await this.resolveAiProfile_(bookId, bookUrl);
  }

  private static async resolveAiProfile_(bookId: number, bookUrl: string): Promise<BookSource | null> {
    const dao = new AiBookProfileTable(AppDatabase.getInstance().rdbStore);
    const profile = bookId > 0 ? await dao.getByBookId(bookId) : await dao.getByBookUrl(bookUrl);
    if (!profile || !profile.sourceJson) return null;
    try {
      return parseBookSource(JSON.parse(profile.sourceJson));
    } catch (e) {
      console.warn('[BookSourceResolver] invalid AI profile:', (e as Error).message);
      return null;
    }
  }
}
