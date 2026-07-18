/**
 * 书籍导出服务（TXT / EPUB）
 *
 * 对齐安卓 Legado ExportBookService 的产品逻辑：
 * - 只导出 chapters 表中已缓存的章节内容
 * - 可选先调用 BookCacheService 下载缺失章节
 * - 可选应用用户替换净化规则
 * - TXT：文件头（书名/作者/简介）+ 逐章 标题+正文，流式写入
 * - EPUB：EPUB 2.0 + NCX，结构见 EpubBuilder
 */
import { AppDatabase } from '../data/database/AppDatabase';
import { ChapterTable } from '../data/database/ChapterTable';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { ReplaceRuleTable } from '../data/database/ReplaceRuleTable';
import { BookChapter } from '../model/BookChapter';
import { BookSource } from '../model/BookSource';
import { ContentReplaceEngine } from '../engine/book/ContentReplace';
import { EpubBuilder, EpubChapter, EpubData } from '../engine/book/EpubBuilder';
import { BookCacheService, CacheChapterItem } from './BookCacheService';
import { HtmlUtil } from '../util/HtmlUtil';
import fileIo from '@ohos.file.fs';
import notificationManager from '@ohos.notificationManager';
import { common } from '@kit.AbilityKit';

/** 导出所需的书籍信息（Book 模型或页面字段均可适配） */
export interface ExportBookInfo {
  id: number;
  name: string;
  author: string;
  introduce: string;
  coverUrl: string;
  bookUrl: string;
  origin: string;
  originUrl: string;
}

export interface ExportOptions {
  /** 正文中包含章节标题（默认 true，仅 TXT 使用） */
  includeTitle: boolean;
  /** 应用替换净化规则（默认 true） */
  useReplace: boolean;
  /** 先下载缺失章节再导出（默认 false：仅导出已缓存） */
  downloadMissing: boolean;
  /** 下载保活 + EPUB 模板读取所需上下文 */
  context?: common.Context;
  onProgress?: (phase: 'download' | 'write', done: number, total: number, message: string) => void;
}

export interface ExportResult {
  success: boolean;
  fileName: string;
  exported: number;
  /** 未缓存被跳过的章节数 */
  skipped: number;
  error: string;
}

export class BookExportService {
  /** 建议文件名：`书名 作者：xxx.txt/epub`，过滤文件系统非法字符 */
  static suggestFileName(book: ExportBookInfo, ext: string = '.txt'): string {
    const name = BookExportService.sanitizeFileName(book.name) || '未命名';
    const author = BookExportService.sanitizeFileName(book.author);
    return author ? name + ' 作者：' + author + ext : name + ext;
  }

  /** 目录与缓存统计 */
  static async getCacheStats(bookId: number): Promise<{ total: number; cached: number }> {
    await AppDatabase.getInstance().waitForInit();
    const chapterTable = new ChapterTable(AppDatabase.getInstance().rdbStore);
    const chapters = await chapterTable.getChaptersByBookId(bookId);
    let cached = 0;
    for (const ch of chapters) {
      if (BookExportService.isChapterCached(ch)) cached++;
    }
    return { total: chapters.length, cached: cached };
  }

  static isChapterCached(ch: BookChapter): boolean {
    return (ch.isCached || ch.isDownloaded) && !!ch.content && ch.content.length > 10;
  }

  /**
   * 导出书籍为 TXT，写入 targetUri（DocumentViewPicker 保存/目录拼接得到）。
   */
  static async exportBookTxt(book: ExportBookInfo, targetUri: string,
    options: ExportOptions): Promise<ExportResult> {
    const result = BookExportService.newResult(BookExportService.suggestFileName(book, '.txt'));
    if (book.id <= 0) {
      result.error = '书籍未入库';
      return result;
    }

    const notifId = 3000 + (book.id % 10000);
    BookExportService.publishNotif(notifId, '导出书籍', '正在导出《' + book.name + '》...');

    const chapters = await BookExportService.prepareChapters(book, options);
    if (!chapters) {
      result.error = '目录为空，请先加载目录';
      BookExportService.finishNotify(notifId, book.name, result);
      return result;
    }
    const replaceEngine = await BookExportService.loadReplaceEngine(options.useReplace);

    // 写入文件
    let file: fileIo.File | null = null;
    try {
      file = fileIo.openSync(targetUri, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      const header = book.name + '\n作者：' + (book.author || '') + '\n简介：\n'
        + HtmlUtil.stripHtml(book.introduce || '') + '\n';
      fileIo.writeSync(file.fd, header);

      for (let i = 0; i < chapters.length; i++) {
        const ch = chapters[i];
        if (!BookExportService.isChapterCached(ch)) {
          result.skipped++;
          continue;
        }
        const body = BookExportService.applyReplace(replaceEngine, ch.content, book);
        const chunk = '\n\n' + (options.includeTitle ? ch.title + '\n' : '') + body;
        fileIo.writeSync(file.fd, chunk);
        result.exported++;
        if (options.onProgress) {
          options.onProgress('write', i + 1, chapters.length, ch.title);
        }
      }
      result.success = true;
    } catch (e) {
      result.error = (e as Error).message || '写入文件失败';
      console.error('[BookExport] write txt fail:', (e as Error).message);
    } finally {
      if (file) {
        try { fileIo.closeSync(file); } catch (_e) {}
      }
    }
    BookExportService.finishNotify(notifId, book.name, result);
    return result;
  }

  /**
   * 导出书籍为 EPUB（2.0 + NCX），写入 targetUri。
   */
  static async exportBookEpub(book: ExportBookInfo, targetUri: string,
    options: ExportOptions): Promise<ExportResult> {
    const result = BookExportService.newResult(BookExportService.suggestFileName(book, '.epub'));
    if (book.id <= 0) {
      result.error = '书籍未入库';
      return result;
    }

    const notifId = 3000 + (book.id % 10000);
    BookExportService.publishNotif(notifId, '导出书籍', '正在导出《' + book.name + '》(EPUB)...');

    const chapters = await BookExportService.prepareChapters(book, options);
    if (!chapters) {
      result.error = '目录为空，请先加载目录';
      return result;
    }
    const replaceEngine = await BookExportService.loadReplaceEngine(options.useReplace);

    const epubChapters: EpubChapter[] = [];
    for (const ch of chapters) {
      if (!BookExportService.isChapterCached(ch)) {
        result.skipped++;
        continue;
      }
      epubChapters.push({
        title: ch.title,
        content: BookExportService.applyReplace(replaceEngine, ch.content, book),
      });
    }
    if (epubChapters.length === 0) {
      result.error = '没有已缓存的章节可导出';
      BookExportService.finishNotify(notifId, book.name, result);
      return result;
    }

    const data: EpubData = {
      name: book.name,
      author: book.author || '',
      introduce: HtmlUtil.stripHtml(book.introduce || ''),
      coverUrl: book.coverUrl || '',
      chapters: epubChapters,
    };

    try {
      await EpubBuilder.build(data, targetUri, options.context,
        options.onProgress
          ? (done: number, total: number): void => {
            const title = done > 0 && done <= epubChapters.length ? epubChapters[done - 1].title : '';
            options.onProgress!('write', done, total, title);
          }
          : undefined);
      result.exported = epubChapters.length;
      result.success = true;
    } catch (e) {
      result.error = (e as Error).message || '生成 EPUB 失败';
      console.error('[BookExport] write epub fail:', (e as Error).message);
    }
    BookExportService.finishNotify(notifId, book.name, result);
    return result;
  }

  // ============================================================
  // 共享逻辑
  // ============================================================

  private static newResult(fileName: string): ExportResult {
    return { success: false, fileName: fileName, exported: 0, skipped: 0, error: '' };
  }

  /** 加载章节；可选先下载缺失章节后重新加载。目录为空返回 null */
  private static async prepareChapters(book: ExportBookInfo,
    options: ExportOptions): Promise<BookChapter[] | null> {
    await AppDatabase.getInstance().waitForInit();
    const chapterTable = new ChapterTable(AppDatabase.getInstance().rdbStore);
    let chapters = await chapterTable.getChaptersByBookId(book.id);
    if (chapters.length === 0) return null;

    if (options.downloadMissing) {
      const missing = chapters.filter((ch: BookChapter): boolean => !BookExportService.isChapterCached(ch));
      if (missing.length > 0) {
        const source = await BookExportService.resolveSource(book);
        if (source) {
          const items: CacheChapterItem[] = chapters.map((ch: BookChapter): CacheChapterItem => {
            return { index: ch.index, title: ch.title, url: ch.url };
          });
          const first = missing[0].index;
          const last = missing[missing.length - 1].index;
          await BookCacheService.getInstance().cacheBook({
            bookId: book.id,
            bookName: book.name,
            bookUrl: book.bookUrl,
            source: source,
            chapters: items,
            startIndex: first,
            endIndex: last,
            context: options.context,
            onProgress: options.onProgress
              ? (done: number, total: number, title: string): void => {
                options.onProgress!('download', done, total, title);
              }
              : undefined,
          });
          chapters = await chapterTable.getChaptersByBookId(book.id);
        } else {
          console.warn('[BookExport] no source resolved, export cached only: ' + book.originUrl);
        }
      }
    }
    return chapters;
  }

  private static async loadReplaceEngine(useReplace: boolean): Promise<ContentReplaceEngine | null> {
    if (!useReplace) return null;
    try {
      const engine = new ContentReplaceEngine();
      await engine.loadRules(new ReplaceRuleTable(AppDatabase.getInstance().rdbStore));
      return engine;
    } catch (e) {
      console.warn('[BookExport] load replace rules fail:', (e as Error).message);
      return null;
    }
  }

  private static applyReplace(engine: ContentReplaceEngine | null, content: string,
    book: ExportBookInfo): string {
    if (!engine) return content;
    try {
      return engine.apply(content, book.originUrl, book.bookUrl);
    } catch (_e) {
      return content;
    }
  }

  private static finishNotify(notifId: number, bookName: string, result: ExportResult): void {
    if (result.success) {
      BookExportService.publishNotif(notifId, '导出完成',
        '《' + bookName + '》已导出 ' + result.exported + ' 章'
        + (result.skipped > 0 ? '，跳过未缓存 ' + result.skipped + ' 章' : ''));
    } else {
      BookExportService.publishNotif(notifId, '导出失败', '《' + bookName + '》：' + result.error);
    }
  }

  private static publishNotif(id: number, title: string, text: string): void {
    try {
      const request: notificationManager.NotificationRequest = {
        id: id,
        content: {
          contentType: 0,
          normal: { title: title, text: text },
        },
      };
      notificationManager.publish(request, (err: Error) => {
        if (err) console.warn('[BookExport] notif error:', err.message);
      });
    } catch (e) {
      console.warn('[BookExport] notif error:', (e as Error).message);
    }
  }

  /** 按 originUrl / origin 解析书源（对齐 BookInfoPage 的匹配逻辑） */
  static async resolveSource(book: ExportBookInfo): Promise<BookSource | null> {
    try {
      const dao = new BookSourceTable(AppDatabase.getInstance().rdbStore);
      const sources = await dao.getAllSources();
      const matched = sources.find((s: BookSource): boolean =>
        s.sourceUrl === book.originUrl || s.sourceName === book.origin);
      return matched || null;
    } catch (e) {
      console.warn('[BookExport] resolveSource fail:', (e as Error).message);
      return null;
    }
  }

  private static sanitizeFileName(name: string): string {
    return (name || '')
      .replace(/:/g, '：')
      .replace(/[\\/*?"<>|\r\n]/g, '_')
      .trim();
  }
}
