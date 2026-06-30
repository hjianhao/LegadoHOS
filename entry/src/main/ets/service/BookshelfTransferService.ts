import { AppDatabase } from '../data/database/AppDatabase';
import { BookTable } from '../data/database/BookTable';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { ChapterTable } from '../data/database/ChapterTable';
import { Book, BookGroup, BookType, createDefaultBook } from '../model/Book';
import { BookChapter, createDefaultChapter } from '../model/BookChapter';
import { BookSource, BookSourceBookInfo, BookSourceChapter } from '../model/BookSource';
import { SearchResult } from '../model/SearchResult';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { NetUtil } from '../util/NetUtil';

export interface BookshelfExportItem {
  name: string;
  author: string;
  intro: string;
}

export interface BookshelfTransferResult {
  success: number;
  skipped: number;
  failed: number;
  messages: string[];
}

interface ImportItem {
  name: string;
  author: string;
  intro: string;
}

interface BookUpsertFields {
  name: string;
  author: string;
  coverUrl: string;
  bookUrl: string;
  origin: string;
  originUrl: string;
  kind: string;
  wordCount: string;
  introduce: string;
  lastUpdateTime: string;
  latestChapterTitle: string;
  totalChapterNum: number;
}

export class BookshelfTransferService {
  static async exportBookshelf(books?: Book[]): Promise<string> {
    await AppDatabase.getInstance().waitForInit();
    const bookDao = new BookTable(AppDatabase.getInstance().rdbStore);
    const list = books || await bookDao.getAllShelfBooks();
    const items: BookshelfExportItem[] = list.map((book: Book): BookshelfExportItem => {
      return {
        name: book.name || '',
        author: book.author || '',
        intro: book.introduce || '',
      };
    });
    return JSON.stringify(items, null, 2);
  }

  static async importBookshelfText(text: string, groupId: number = BookGroup.ALL,
    onProgress?: (done: number, total: number, message: string) => void): Promise<BookshelfTransferResult> {
    const content = await BookshelfTransferService.resolveText(text);
    const items = BookshelfTransferService.parseImportItems(content);
    const result: BookshelfTransferResult = { success: 0, skipped: 0, failed: 0, messages: [] };
    if (items.length === 0) {
      result.failed = 1;
      result.messages.push('没有找到可导入的书籍');
      return result;
    }

    await AppDatabase.getInstance().waitForInit();
    const db = AppDatabase.getInstance().rdbStore;
    const bookDao = new BookTable(db);
    const sourceDao = new BookSourceTable(db);
    const sources = (await sourceDao.getEnabledSources()).filter((source: BookSource) => !!source.ruleSearchUrl);

    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      const title = item.name || '未命名';
      if (onProgress) onProgress(i + 1, items.length, '搜索 ' + title);
      try {
        const existing = await bookDao.getBookByName(item.name, item.author);
        if (existing && existing.isShelf) {
          result.skipped++;
          continue;
        }
        if (sources.length === 0) {
          result.failed++;
          result.messages.push(title + ': 没有可搜索的书源');
          continue;
        }
        const keyword = (item.name + ' ' + item.author).trim();
        const found = await globalSourceExecutor.search(keyword, sources);
        const picked = BookshelfTransferService.pickSearchResult(found, item);
        if (!picked) {
          result.failed++;
          result.messages.push(title + ': 未搜索到匹配书籍');
          continue;
        }
        await BookshelfTransferService.upsertFromSearchResult(picked, groupId, item.intro);
        result.success++;
      } catch (e) {
        result.failed++;
        result.messages.push(title + ': ' + ((e as Error).message || '导入失败'));
      }
    }
    return result;
  }

  static async addBooksByUrl(input: string, groupId: number = BookGroup.ALL,
    onProgress?: (done: number, total: number, message: string) => void): Promise<BookshelfTransferResult> {
    const urls = input.split(/\r?\n/)
      .map((line: string): string => line.trim())
      .filter((line: string): boolean => line.length > 0);
    const result: BookshelfTransferResult = { success: 0, skipped: 0, failed: 0, messages: [] };
    if (urls.length === 0) {
      result.failed = 1;
      result.messages.push('没有输入书籍 URL');
      return result;
    }

    await AppDatabase.getInstance().waitForInit();
    const db = AppDatabase.getInstance().rdbStore;
    const bookDao = new BookTable(db);
    const sourceDao = new BookSourceTable(db);
    const sources = await sourceDao.getEnabledSources();

    for (let i = 0; i < urls.length; i++) {
      const url = urls[i];
      if (onProgress) onProgress(i + 1, urls.length, '添加 ' + url);
      try {
        const existing = await bookDao.getBookByUrl(url);
        if (existing && existing.isShelf) {
          result.skipped++;
          continue;
        }
        const source = BookshelfTransferService.findSourceForUrl(url, sources);
        if (!source) {
          result.failed++;
          result.messages.push(url + ': 找不到匹配书源');
          continue;
        }
        const info = await globalSourceExecutor.getBookInfo(source, url);
        const chapters = await globalSourceExecutor.getToc(source, url);
        const name = info.name || BookshelfTransferService.nameFromUrl(url);
        await BookshelfTransferService.upsertBook({
          name: name,
          author: info.author || '',
          coverUrl: info.coverUrl || '',
          bookUrl: url,
          origin: source.sourceName || '',
          originUrl: source.sourceUrl || '',
          kind: info.kind || '',
          wordCount: info.wordCount || '',
          introduce: info.introduce || '',
          lastUpdateTime: info.lastUpdateTime || '',
          latestChapterTitle: chapters.length > 0 ? chapters[chapters.length - 1].title : '',
          totalChapterNum: chapters.length,
        }, groupId, chapters);
        result.success++;
      } catch (e) {
        result.failed++;
        result.messages.push(url + ': ' + ((e as Error).message || '添加失败'));
      }
    }
    return result;
  }

  static async upsertFromSearchResult(item: SearchResult, groupId: number = BookGroup.ALL, introOverride: string = ''): Promise<number> {
    const source = await BookshelfTransferService.findSourceByUrl(item.originUrl);
    let info: BookSourceBookInfo = {
      name: '', author: '', coverUrl: '', introduce: '', kind: '', wordCount: '', lastUpdateTime: '', chapters: [],
    };
    let chapters: BookSourceChapter[] = [];
    if (source) {
      try {
        info = await globalSourceExecutor.getBookInfo(source, item.noteUrl);
      } catch (_e) { /* keep search result data */ }
      try {
        chapters = await globalSourceExecutor.getToc(source, item.noteUrl);
      } catch (_e) { /* toc is optional for import */ }
    }
    return BookshelfTransferService.upsertBook({
      name: info.name || item.name,
      author: info.author || item.author,
      coverUrl: info.coverUrl || item.coverUrl,
      bookUrl: item.noteUrl,
      origin: item.origin,
      originUrl: item.originUrl,
      kind: info.kind || item.kind,
      wordCount: info.wordCount || item.wordCount,
      introduce: info.introduce || item.introduce || introOverride,
      lastUpdateTime: info.lastUpdateTime || item.lastUpdateTime,
      latestChapterTitle: item.latestChapterTitle || (chapters.length > 0 ? chapters[chapters.length - 1].title : ''),
      totalChapterNum: chapters.length,
    }, groupId, chapters);
  }

  private static async upsertBook(fields: BookUpsertFields, groupId: number, chapters: BookSourceChapter[]): Promise<number> {
    await AppDatabase.getInstance().waitForInit();
    const db = AppDatabase.getInstance().rdbStore;
    const bookDao = new BookTable(db);
    const chapterDao = new ChapterTable(db);
    const bookUrl = fields.bookUrl || '';
    const now = Date.now();
    let book = bookUrl ? await bookDao.getBookByUrl(bookUrl) : null;
    if (!book) {
      book = createDefaultBook();
      book.createTime = now;
    }
    book.name = fields.name || book.name;
    book.author = fields.author || book.author;
    book.coverUrl = fields.coverUrl || book.coverUrl;
    book.bookUrl = bookUrl || book.bookUrl;
    book.origin = fields.origin || book.origin;
    book.originUrl = fields.originUrl || book.originUrl;
    book.kind = fields.kind || book.kind;
    book.wordCount = fields.wordCount || book.wordCount;
    book.introduce = fields.introduce || book.introduce;
    book.lastUpdateTime = fields.lastUpdateTime || book.lastUpdateTime;
    book.latestChapterTitle = fields.latestChapterTitle || book.latestChapterTitle;
    book.totalChapterNum = fields.totalChapterNum || book.totalChapterNum;
    book.chapterCount = book.totalChapterNum;
    book.type = BookType.TEXT;
    book.groupId = groupId;
    book.isShelf = true;
    book.updateTime = now;
    if (book.id > 0) {
      await bookDao.updateBook(book);
    } else {
      book.id = await bookDao.insertBook(book);
    }
    if (chapters.length > 0) {
      await chapterDao.deleteChaptersByBookId(book.id);
      await chapterDao.insertChapters(BookshelfTransferService.toBookChapters(book.id, chapters));
    }
    return book.id;
  }

  private static toBookChapters(bookId: number, chapters: BookSourceChapter[]): BookChapter[] {
    const now = Date.now();
    return chapters.map((ch: BookSourceChapter, idx: number): BookChapter => {
      const item = createDefaultChapter();
      item.bookId = bookId;
      item.index = ch.index >= 0 ? ch.index : idx;
      item.title = ch.title || '';
      item.url = ch.url || '';
      item.createTime = now;
      item.updateTime = now;
      return item;
    });
  }

  private static async resolveText(text: string): Promise<string> {
    const value = text.trim();
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return await NetUtil.httpGet(value);
    }
    return value;
  }

  private static parseImportItems(text: string): ImportItem[] {
    const parsed = JSON.parse(text) as Object;
    const rawItems = Array.isArray(parsed) ? parsed as Object[] : [parsed];
    const items: ImportItem[] = [];
    for (const raw of rawItems) {
      const row = raw as Record<string, Object>;
      const name = ((row['name'] || row['bookName'] || '') as string).trim();
      if (!name) continue;
      items.push({
        name: name,
        author: ((row['author'] || '') as string).trim(),
        intro: ((row['intro'] || row['introduce'] || '') as string).trim(),
      });
    }
    return items;
  }

  private static pickSearchResult(results: SearchResult[], item: ImportItem): SearchResult | null {
    const name = item.name.trim();
    const author = item.author.trim();
    const exact = results.find((r: SearchResult): boolean => {
      return r.name === name && (!author || r.author === author);
    });
    if (exact) return exact;
    const sameName = results.find((r: SearchResult): boolean => r.name === name);
    if (sameName) return sameName;
    return results.length > 0 ? results[0] : null;
  }

  private static async findSourceByUrl(sourceUrl: string): Promise<BookSource | null> {
    if (!sourceUrl) return null;
    const dao = new BookSourceTable(AppDatabase.getInstance().rdbStore);
    return await dao.getSourceByUrl(sourceUrl);
  }

  private static findSourceForUrl(url: string, sources: BookSource[]): BookSource | null {
    for (const source of sources) {
      if (BookshelfTransferService.urlMatchesSource(url, source)) return source;
    }
    return null;
  }

  private static urlMatchesSource(url: string, source: BookSource): boolean {
    const sourceUrl = (source.sourceUrl || '').replace(/\/+$/, '');
    if (sourceUrl && url.startsWith(sourceUrl)) return true;
    const host = BookshelfTransferService.getHost(url);
    const sourceHost = BookshelfTransferService.getHost(source.sourceUrl || '');
    return !!host && !!sourceHost && host === sourceHost;
  }

  private static getHost(url: string): string {
    const match = url.match(/^https?:\/\/([^\/]+)/i);
    return match ? match[1].toLowerCase() : '';
  }

  private static nameFromUrl(url: string): string {
    const clean = url.replace(/[?#].*$/, '').replace(/\/+$/, '');
    const parts = clean.split('/');
    return parts.length > 0 ? parts[parts.length - 1] : url;
  }
}
