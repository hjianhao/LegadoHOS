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
import { ZipCrc32Provider, ZipWriter } from '../util/ZipWriter';
import { taskpool } from '@kit.ArkTS';
import { crc32Concurrent } from '../util/ZipCrcTask';
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
  /** 目标 URI 已由用户确认覆盖时使用纯写入截断，避免文件提供方再次判定为重名。 */
  overwriteExisting?: boolean;
  /** 漫画 EPUB 拆分大小；设置为正数时每个文件最多包含指定章节数。 */
  epubChapterSize?: number;
  /** 拆分 EPUB 时是否按 epubOutputUris 输出多个文件。 */
  epubSplitOutput?: boolean;
  /** 拆分 EPUB 时由 Picker 直接返回的每个分卷文件 URI。 */
  epubOutputUris?: string[];
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
  /** 拆分导出时实际生成的文件名列表。 */
  fileNames?: string[];
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

/** 在后台线程计算 ZIP CRC；输入由 ZipWriter 复制后转移所有权。 */
const crc32WithTaskPool: ZipCrc32Provider = async (input: ArrayBuffer): Promise<number> => {
  const task: taskpool.Task = new taskpool.Task('zip-crc32', crc32Concurrent, input);
  task.setTransferList([input]);
  return await taskpool.execute(task, taskpool.Priority.LOW) as number;
};

export class BookExportService {
  /** 建议文件名：`书名 作者：xxx.txt/epub`，过滤文件系统非法字符 */
  static suggestFileName(book: ExportBookInfo, ext: string = '.txt'): string {
    const name = BookExportService.sanitizeFileName(book.name) || '未命名';
    const author = BookExportService.sanitizeFileName(book.author);
    return author ? name + ' 作者：' + author + ext : name + ext;
  }

  /** 建议拆分 EPUB 文件名，使用序号避免同名覆盖并保持排序稳定。 */
  static suggestSplitFileName(book: ExportBookInfo, ext: string = '.epub', partIndex: number = 1): string {
    const base = BookExportService.suggestFileName(book, ext);
    const suffix = ext.startsWith('.') ? ext : '.' + ext;
    const stem = base.endsWith(suffix) ? base.substring(0, base.length - suffix.length) : base;
    return stem + ' [' + Math.max(1, Math.floor(partIndex)) + ']' + suffix;
  }

  /** 建议分卷输出使用的书名目录名，和导出文件名保持同样的净化规则。 */
  static suggestBookDirectoryName(book: ExportBookInfo): string {
    return BookExportService.sanitizeFileName(book.name) || '未命名';
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
      if (options.overwriteExisting) {
        try {
          file = fileIo.openSync(targetUri, fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        } catch (_e) {
          file = fileIo.openSync(targetUri,
            fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        }
      } else {
        file = fileIo.openSync(targetUri,
          fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      }
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
      ZipWriter.setCrc32Provider(crc32WithTaskPool);
      await EpubBuilder.build(data, targetUri, options.context,
        options.onProgress
          ? (done: number, total: number): void => {
            const title = done > 0 && done <= epubChapters.length ? epubChapters[done - 1].title : '';
            options.onProgress!('write', done, total, title);
          }
          : undefined, options.overwriteExisting === true);
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
      await MangaImageLoader.init();
      const cacheBefore = await MangaImageLoader.getCacheSizeForBook(book.id);
      console.info('[BookExport] comic cache before export: ' + cacheBefore + ' bytes, bookId=' + book.id);
      const chapters = await BookExportService.prepareChapters(book, options);
      if (!chapters) {
        result.error = '目录为空，请先加载目录';
        BookExportService.finishNotify(notifId, book.name, result);
        return result;
      }
      const cacheAfter = await MangaImageLoader.getCacheSizeForBook(book.id);
      console.info('[BookExport] comic cache after preparation: ' + cacheAfter + ' bytes, bookId=' + book.id);
      const splitSize = BookExportService.normalizedEpubChapterSize(options);
      if (options.epubSplitOutput === true && splitSize > 0 && chapters.length > splitSize) {
        // 拆分导出时逐章准备并在每个分卷完成后释放图片字节，避免 2GB 漫画一次性
        // 常驻内存。每个分卷都使用 Picker 直接返回的文件 URI，不能把目录 URI
        // 当作普通路径拼接子文件，否则 datashare 等文件提供方会拒绝操作。
        const outputUris = options.epubOutputUris || [];
        const expectedVolumeCount = Math.ceil(chapters.length / splitSize);
        if (outputUris.length < expectedVolumeCount) {
          throw new Error('文件选择器未返回完整的分卷文件位置');
        }
        const source = await BookExportService.resolveSource(book);
        const volume: PreparedComicChapter[] = [];
        let skipped = 0;
        let exported = 0;
        let exportedImages = 0;
        let partIndex = 0;
        const fileNames: string[] = [];
        for (const chapter of chapters) {
          const item = await BookExportService.prepareComicChapter(book, chapter, options, source);
          if (!item) {
            skipped++;
            continue;
          }
          volume.push(item);
          if (volume.length < splitSize) continue;

          partIndex++;
          const fileName = BookExportService.suggestSplitFileName(book, '.epub', partIndex);
          const outputUri = outputUris[partIndex - 1];
          if (!outputUri) throw new Error('无法取得第 ' + partIndex + ' 个分卷文件位置');
          await BookExportService.writeComicEpubVolume_(book, outputUri,
            volume, options, exported, chapters.length, options.overwriteExisting === true);
          fileNames.push(fileName);
          exported += volume.length;
          exportedImages += BookExportService.countComicImages(volume);
          volume.length = 0;
        }
        if (volume.length > 0) {
          partIndex++;
          const fileName = BookExportService.suggestSplitFileName(book, '.epub', partIndex);
          const outputUri = outputUris[partIndex - 1];
          if (!outputUri) throw new Error('无法取得第 ' + partIndex + ' 个分卷文件位置');
          await BookExportService.writeComicEpubVolume_(book, outputUri,
            volume, options, exported, chapters.length, options.overwriteExisting === true);
          fileNames.push(fileName);
          exported += volume.length;
          exportedImages += BookExportService.countComicImages(volume);
        }
        if (fileNames.length === 0) {
          result.skipped = skipped;
          result.error = skipped > 0 ? '没有完整缓存的漫画章节可导出' : '目录为空，请先加载目录';
          BookExportService.finishNotify(notifId, book.name, result);
          return result;
        }
        result.fileName = fileNames[0];
        result.fileNames = fileNames;
        result.exported = exported;
        result.exportedImages = exportedImages;
        result.skipped = skipped;
        result.success = true;
      } else {
        const prepared = await BookExportService.prepareComicChaptersFrom_(book, chapters, options);
        if (prepared.chapters.length === 0) {
          result.skipped = prepared.skipped;
          result.error = prepared.skipped > 0
            ? '没有完整缓存的漫画章节可导出' : '目录为空，请先加载目录';
          BookExportService.finishNotify(notifId, book.name, result);
          return result;
        }
        await BookExportService.writeComicEpubVolume_(book, targetUri, prepared.chapters,
          options, 0, prepared.chapters.length, options.overwriteExisting === true);
        result.exported = prepared.chapters.length;
        result.exportedImages = BookExportService.countComicImages(prepared.chapters);
        result.skipped = prepared.skipped;
        result.success = true;
      }
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
      const zip = ZipWriter.open(targetUri, options.overwriteExisting === true);
      try {
        ZipWriter.setCrc32Provider(crc32WithTaskPool);
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
    return {
      success: false,
      fileName: fileName,
      fileNames: [],
      exported: 0,
      skipped: 0,
      exportedImages: 0,
      error: '',
    };
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
    return await BookExportService.prepareComicChaptersFrom_(book, chapters, options);
  }

  private static async prepareComicChaptersFrom_(book: ExportBookInfo, chapters: BookChapter[],
    options: ExportOptions): Promise<PreparedComicResult> {
    const source = await BookExportService.resolveSource(book);
    const prepared: PreparedComicChapter[] = [];
    let skipped = 0;
    for (const chapter of chapters) {
      const item = await BookExportService.prepareComicChapter(book, chapter, options, source);
      if (item) prepared.push(item);
      else skipped++;
    }
    return { chapters: prepared, skipped: skipped };
  }

  /** 准备单个漫画章节，拆分 EPUB 时逐章调用以避免一次性持有全部图片。 */
  private static async prepareComicChapter(book: ExportBookInfo, chapter: BookChapter,
    options: ExportOptions, source: BookSource | null): Promise<PreparedComicChapter | null> {
    if (!BookExportService.isChapterCached(chapter)) return null;
    const baseUrl = chapter.url || book.bookUrl;
    const urls = globalSourceExecutor.extractImageUrls(chapter.content, baseUrl);
    if (urls.length === 0) return null;
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
    if (!complete || pages.length === 0) return null;
    return {
      index: chapter.index,
      title: chapter.title || ('第 ' + (chapter.index + 1) + ' 章'),
      pages: pages,
    };
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

  private static normalizedEpubChapterSize(options: ExportOptions): number {
    const value = options.epubChapterSize || 0;
    if (!Number.isFinite(value) || value < 1) return 0;
    return Math.floor(value);
  }

  private static countComicImages(chapters: PreparedComicChapter[]): number {
    let count = 0;
    for (const chapter of chapters) count += chapter.pages.length;
    return count;
  }

  /** 将一组漫画章节写入一个 EPUB，并把进度映射到整本书章节范围。 */
  private static async writeComicEpubVolume_(book: ExportBookInfo, targetUri: string,
    chapters: PreparedComicChapter[], options: ExportOptions, progressOffset: number,
    progressTotal: number, overwriteExisting: boolean): Promise<void> {
    const epubChapters: EpubChapter[] = [];
    const images: EpubImage[] = [];
    let imageBytes: number = 0;
    for (const chapter of chapters) {
      const contentLines: string[] = [];
      for (const page of chapter.pages) {
        contentLines.push('<img src="../Images/' + page.path + '" alt="' +
          BookExportService.escapeHtmlAttribute(page.title) + '" />');
        images.push({ path: page.path, bytes: page.bytes, mediaType: page.mediaType });
        imageBytes += page.bytes.length;
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
    console.info('[BookExport] comic volume: chapters=' + chapters.length
      + ', images=' + images.length + ', imageBytes=' + imageBytes);
    ZipWriter.setCrc32Provider(crc32WithTaskPool);
    await EpubBuilder.build(data, targetUri, options.context,
      options.onProgress
        ? (done: number, _total: number): void => {
          const title = done > 0 && done <= chapters.length ? chapters[done - 1].title : '';
          options.onProgress!('write', progressOffset + done, progressTotal, title);
        }
        : undefined, overwriteExisting);
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
        + (result.fileNames && result.fileNames.length > 1
          ? '，生成 ' + result.fileNames.length + ' 个文件' : '')
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
