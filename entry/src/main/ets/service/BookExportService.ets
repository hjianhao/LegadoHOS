/**
 * 书籍导出服务（TXT / EPUB / 漫画图片 ZIP）
 *
 * 对齐安卓 Legado ExportBookService 的产品逻辑：
 * - 只导出 chapters 表中已缓存的章节内容
 * - 可选先调用 BookCacheService 下载缺失章节
 * - 可选应用用户替换净化规则
 * - TXT：文件头（书名/作者/简介）+ 逐章 标题+正文，流式写入
 * - EPUB：EPUB 2.0 + NCX，漫画图片内嵌到 EPUB，结构见 EpubBuilder
 * - 漫画 ZIP：图片按章节/页序组织，并写入 manifest.json
 */
import { AppDatabase } from '../data/database/AppDatabase';
import { ChapterTable } from '../data/database/ChapterTable';
import { BookSourceTable } from '../data/database/BookSourceTable';
import { ReplaceRuleTable } from '../data/database/ReplaceRuleTable';
import { BookChapter } from '../model/BookChapter';
import { BookSource, isImageSource } from '../model/BookSource';
import { ContentReplaceEngine } from '../engine/book/ContentReplace';
import { EpubBuilder, EpubChapter, EpubData, EpubImage } from '../engine/book/EpubBuilder';
import { BookCacheService, CacheChapterItem } from './BookCacheService';
import { HtmlUtil } from '../util/HtmlUtil';
import { globalSourceExecutor } from '../engine/source/SourceExecutor';
import { MangaImageLoader } from '../util/MangaImageLoader';
import { ZipWriter } from '../util/ZipWriter';
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
  /** 书籍是否为漫画；未传入时导出服务会根据书源自动判断。 */
  isManga?: boolean;
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
  /** 漫画导出的图片数（TXT 导出为 0）。 */
  exportedImages?: number;
  error: string;
}

/** 目录与缓存统计 */
export interface CacheStats {
  total: number;
  cached: number;
}

interface PreparedComicPage {
  title: string;
  path: string;
  bytes: Uint8Array;
  mediaType: string;
}

interface PreparedComicChapter {
  index: number;
  title: string;
  pages: PreparedComicPage[];
}

interface PreparedComicResult {
  chapters: PreparedComicChapter[];
  skipped: number;
}

interface ComicManifestChapter {
  index: number;
  title: string;
  pages: string[];
}

export class BookExportService {
  /** 建议文件名：`书名 作者：xxx.txt/epub`，过滤文件系统非法字符 */
  static suggestFileName(book: ExportBookInfo, ext: string = '.txt'): string {
    const name = BookExportService.sanitizeFileName(book.name) || '未命名';
    const author = BookExportService.sanitizeFileName(book.author);
    return author ? name + ' 作者：' + author + ext : name + ext;
  }

  /** 目录与缓存统计 */
  static async getCacheStats(bookId: number): Promise<CacheStats> {
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
    const replaceEngine = await BookExportService.loadReplaceEngine(options.useReplace, book);

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
        const body = BookExportService.applyReplace(replaceEngine, ch.content);
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
    if (await BookExportService.isComicBook(book)) {
      return BookExportService.exportComicEpub(book, targetUri, options);
    }
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
    const replaceEngine = await BookExportService.loadReplaceEngine(options.useReplace, book);

    const epubChapters: EpubChapter[] = [];
    for (const ch of chapters) {
      if (!BookExportService.isChapterCached(ch)) {
        result.skipped++;
        continue;
      }
      epubChapters.push({
        title: ch.title,
        content: BookExportService.applyReplace(replaceEngine, ch.content),
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

  /**
   * 导出漫画为内嵌图片的 EPUB。
   * 每章对应一个 XHTML，图片从 manga_cache_v3/{bookId} 读取，生成后无需网络即可阅读。
   */
  static async exportComicEpub(book: ExportBookInfo, targetUri: string,
    options: ExportOptions): Promise<ExportResult> {
    const result = BookExportService.newResult(BookExportService.suggestFileName(book, '.epub'));
    if (book.id <= 0) {
      result.error = '书籍未入库';
      return result;
    }
    const notifId = 3000 + (book.id % 10000);
    BookExportService.publishNotif(notifId, '导出漫画', '正在生成《' + book.name + '》(EPUB)...');
    try {
      const prepared = await BookExportService.prepareComicChapters(book, options);
      if (!prepared || prepared.chapters.length === 0) {
        result.skipped = prepared ? prepared.skipped : 0;
        result.error = prepared && prepared.skipped > 0
          ? '没有完整缓存的漫画章节可导出' : '目录为空，请先加载目录';
        BookExportService.finishNotify(notifId, book.name, result);
        return result;
      }
      const epubChapters: EpubChapter[] = [];
      const images: EpubImage[] = [];
      for (const chapter of prepared.chapters) {
        const contentLines: string[] = [];
        for (const page of chapter.pages) {
          contentLines.push('<img src="../Images/' + page.path + '" alt="' +
            BookExportService.escapeHtmlAttribute(page.title) + '" />');
          images.push({ path: page.path, bytes: page.bytes, mediaType: page.mediaType });
        }
        epubChapters.push({ title: chapter.title, content: contentLines.join('\n') });
      }
      const data: EpubData = {
        name: book.name,
        author: book.author || '',
        introduce: HtmlUtil.stripHtml(book.introduce || ''),
        coverUrl: book.coverUrl || '',
        chapters: epubChapters,
        images: images,
      };
      await EpubBuilder.build(data, targetUri, options.context,
        options.onProgress
          ? (done: number, total: number): void => {
            const title = done > 0 && done <= prepared.chapters.length
              ? prepared.chapters[done - 1].title : '';
            options.onProgress!('write', done, total, title);
          }
          : undefined);
      result.exported = prepared.chapters.length;
      result.exportedImages = images.length;
      result.skipped = prepared.skipped;
      result.success = true;
    } catch (e) {
      result.error = (e as Error).message || '生成漫画 EPUB 失败';
      console.error('[BookExport] write comic epub fail:', result.error);
    }
    BookExportService.finishNotify(notifId, book.name, result);
    return result;
  }

  /** 导出漫画为图片 ZIP，并附带 manifest.json 记录章节与图片顺序。 */
  static async exportComicZip(book: ExportBookInfo, targetUri: string,
    options: ExportOptions): Promise<ExportResult> {
    const result = BookExportService.newResult(BookExportService.suggestFileName(book, '.zip'));
    if (book.id <= 0) {
      result.error = '书籍未入库';
      return result;
    }
    const notifId = 3000 + (book.id % 10000);
    BookExportService.publishNotif(notifId, '导出漫画', '正在生成《' + book.name + '》(图片 ZIP)...');
    try {
      const prepared = await BookExportService.prepareComicChapters(book, options);
      if (!prepared || prepared.chapters.length === 0) {
        result.skipped = prepared ? prepared.skipped : 0;
        result.error = prepared && prepared.skipped > 0
          ? '没有完整缓存的漫画章节可导出' : '目录为空，请先加载目录';
        BookExportService.finishNotify(notifId, book.name, result);
        return result;
      }
      const manifestChapters: ComicManifestChapter[] = [];
      let totalImages = 0;
      for (const chapter of prepared.chapters) {
        manifestChapters.push({
          index: chapter.index,
          title: chapter.title,
          pages: chapter.pages.map((page: PreparedComicPage): string => page.path),
        });
        totalImages += chapter.pages.length;
      }
      const zip = ZipWriter.open(targetUri);
      try {
        const manifest = JSON.stringify({
          format: 'legado-comic-v1',
          name: book.name,
          author: book.author || '',
          chapters: manifestChapters,
        });
        await zip.addText('manifest.json', manifest);
        let done = 0;
        for (const chapter of prepared.chapters) {
          for (const page of chapter.pages) {
            await zip.addStored(page.path, page.bytes);
            done++;
            if (options.onProgress) {
              options.onProgress('write', done, totalImages, chapter.title);
            }
          }
        }
        await zip.finish();
      } catch (e) {
        zip.abort();
        throw e as Error;
      }
      result.exported = prepared.chapters.length;
      result.exportedImages = totalImages;
      result.skipped = prepared.skipped;
      result.success = true;
    } catch (e) {
      result.error = (e as Error).message || '生成漫画 ZIP 失败';
      console.error('[BookExport] write comic zip fail:', result.error);
    }
    BookExportService.finishNotify(notifId, book.name, result);
    return result;
  }

  // ============================================================
  // 共享逻辑
  // ============================================================

  private static newResult(fileName: string): ExportResult {
    return { success: false, fileName: fileName, exported: 0, skipped: 0, exportedImages: 0, error: '' };
  }

  private static async isComicBook(book: ExportBookInfo): Promise<boolean> {
    if (book.isManga === true) return true;
    try {
      const source = await BookExportService.resolveSource(book);
      return source !== null && isImageSource(source);
    } catch (_e) {
      return false;
    }
  }

  private static async prepareComicChapters(book: ExportBookInfo, options: ExportOptions):
    Promise<PreparedComicResult | null> {
    const chapters = await BookExportService.prepareChapters(book, options);
    if (!chapters) return null;
    const source = await BookExportService.resolveSource(book);
    const prepared: PreparedComicChapter[] = [];
    let skipped = 0;
    for (const chapter of chapters) {
      if (!BookExportService.isChapterCached(chapter)) {
        skipped++;
        continue;
      }
      const baseUrl = chapter.url || book.bookUrl;
      const urls = globalSourceExecutor.extractImageUrls(chapter.content, baseUrl);
      if (urls.length === 0) {
        skipped++;
        continue;
      }
      const pages: PreparedComicPage[] = [];
      let complete = true;
      for (let pageIndex = 0; pageIndex < urls.length; pageIndex++) {
        const url = urls[pageIndex];
        let bytes = await MangaImageLoader.readCachedImage(url, book.id);
        if (!bytes && options.downloadMissing && source) {
          const loaded = await MangaImageLoader.load(url, source, undefined, false, book.id);
          if (loaded !== url) {
            bytes = await MangaImageLoader.readCachedImage(url, book.id);
          }
        }
        if (!bytes || bytes.length === 0) {
          complete = false;
          break;
        }
        // 以文件魔数为准，避免源 URL 后缀与实际响应格式不一致导致 EPUB 解码失败。
        const ext = BookExportService.imageExtension(bytes);
        pages.push({
          title: '第 ' + (pageIndex + 1) + ' 页',
          path: 'chapters/' + String(chapter.index + 1).padStart(4, '0') + '/page_'
            + String(pageIndex + 1).padStart(4, '0') + '.' + ext,
          bytes: bytes,
          mediaType: BookExportService.imageMediaType(bytes, ext),
        });
      }
      if (!complete || pages.length === 0) {
        skipped++;
        continue;
      }
      prepared.push({ index: chapter.index, title: chapter.title || ('第 ' + (chapter.index + 1) + ' 章'), pages: pages });
    }
    return { chapters: prepared, skipped: skipped };
  }

  private static imageExtension(bytes: Uint8Array): string {
    if (bytes.length >= 12 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4E && bytes[3] === 0x47) return 'png';
    if (bytes.length >= 3 && bytes[0] === 0xFF && bytes[1] === 0xD8 && bytes[2] === 0xFF) return 'jpg';
    if (bytes.length >= 3 && bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46) return 'gif';
    if (bytes.length >= 12 && bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 && bytes[3] === 0x46
      && bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42 && bytes[11] === 0x50) return 'webp';
    return 'jpg';
  }

  private static imageMediaType(bytes: Uint8Array, ext: string): string {
    const detected = BookExportService.imageExtension(bytes);
    if (detected === 'png') return 'image/png';
    if (detected === 'gif') return 'image/gif';
    if (detected === 'webp') return 'image/webp';
    if (ext === 'svg') return 'image/svg+xml';
    return 'image/jpeg';
  }

  private static escapeHtmlAttribute(text: string): string {
    return (text || '').replace(/&/g, '&amp;').replace(/"/g, '&quot;')
      .replace(/</g, '&lt;').replace(/>/g, '&gt;');
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
            isManga: book.isManga || source.sourceType === 2,
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

  private static async loadReplaceEngine(useReplace: boolean,
    book: ExportBookInfo): Promise<ContentReplaceEngine | null> {
    if (!useReplace) return null;
    try {
      const engine = new ContentReplaceEngine();
      await engine.loadRules(new ReplaceRuleTable(AppDatabase.getInstance().rdbStore),
        book.name, book.originUrl);
      return engine;
    } catch (e) {
      console.warn('[BookExport] load replace rules fail:', (e as Error).message);
      return null;
    }
  }

  private static applyReplace(engine: ContentReplaceEngine | null, content: string): string {
    if (!engine) return content;
    try {
      return engine.applyContent(content);
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
