/**
 * 本地书籍导入引擎
 *
 * 功能：
 * - 通过 DocumentViewPicker 选择本地文件（txt/epub/mobi/pdf）
 * - 拷贝到应用沙箱目录（files/books/）避免 URI 失效
 * - 调用对应 Parser 解析，获取元数据 + 章节列表
 * - EPUB：TaskPool(@Concurrent) 解压到目录，DirEpubParser 从目录解析
 * - 创建 Book 记录（origin='本地', canUpdate=false）
 * - 章节全量写入 chapters 表（content 已填充, isCached=1）
 *
 * 数据流：
 *   picker URI -> copyToSandbox -> Parser.parse() -> Book + Chapters -> DB
 */
import fileFs from '@ohos.file.fs';
import { Book, BookType, createDefaultBook } from '../../model/Book';
import { BookChapter } from '../../model/BookChapter';
import { BookTable } from '../../data/database/BookTable';
import { ChapterTable } from '../../data/database/ChapterTable';
import { AppDatabase } from '../../data/database/AppDatabase';
import { TxtParser } from './TxtParser';
import { MobiParser } from './MobiParser';
import { PdfParser } from './PdfParser';
import { DirEpubParser } from './DirEpubParser';
import { HtmlUtil } from '../../util/HtmlUtil';

/** 本地书来源标识 */
export const LOCAL_BOOK_ORIGIN = '本地';

/** 沙箱目录下的书籍存储子目录 */
const BOOKS_DIR = 'books';

/** 导入结果 */
export interface ImportResult {
  success: boolean;
  bookId: number;
  bookName: string;
  chapterCount: number;
  error?: string;
}

/** 待导入文件项 */
export interface ImportFileItem {
  uri: string;
  fileName: string;
  epubDir?: string;    // EPUB 解压目标目录（由调用方预先计算，保证与 TaskPool 一致）
}

/** 统一的本地书籍元数据 */
export interface LocalBookMeta {
  title: string;
  author: string;
  description: string;
  subject: string;
  coverPath: string;     // 封面本地文件路径（空字符串表示无封面）
}

/** 批量导入结果 */
export interface BatchImportResult {
  success: number;
  failed: number;
  details: ImportResult[];
}

/** 文件类型元信息 */
interface FileTypeInfo {
  extension: string;
  parser: 'txt' | 'epub' | 'mobi' | 'pdf';
}

export class LocalBookEngine {
  private sandboxDir_: string = '';

  /**
   * 获取沙箱书籍目录路径（延迟初始化）
   */
  private getSandboxDir(context?: Context): string {
    if (this.sandboxDir_) return this.sandboxDir_;
    const base = context?.filesDir || globalThis.getContext()?.filesDir || '';
    this.sandboxDir_ = `${base}/${BOOKS_DIR}`;
    // 确保目录存在
    try {
      if (!fileFs.accessSync(this.sandboxDir_)) {
        fileFs.mkdirSync(this.sandboxDir_, true);
      }
    } catch (_e) {
      // 目录可能已存在，忽略
    }
    return this.sandboxDir_;
  }

  /**
   * 拷贝 picker URI 对应的文件到沙箱目录
   * @returns 沙箱中的文件路径
   */
  async copyToSandbox(uri: string, fileName: string, context?: Context): Promise<string> {
    const dir = this.getSandboxDir(context);
    // 生成唯一文件名，避免重名覆盖
    const safeName = this.sanitizeFileName_(fileName);
    const destPath = `${dir}/${safeName}`;

    // 如果目标文件已存在（重复导入），直接返回已有路径
    try {
      if (fileFs.accessSync(destPath)) {
        return destPath;
      }
    } catch (_e) { /* not exist, continue */ }

    // 拷贝文件
    const srcFile = fileFs.openSync(uri, fileFs.OpenMode.READ_ONLY);
    try {
      const destFile = fileFs.openSync(destPath, fileFs.OpenMode.CREATE | fileFs.OpenMode.WRITE_ONLY);
      try {
        await fileFs.copyFile(srcFile.fd, destFile.fd);
      } finally {
        fileFs.closeSync(destFile);
      }
    } finally {
      fileFs.closeSync(srcFile);
    }

    return destPath;
  }

  /**
   * 导入单个本地文件
   */
  async importBook(filePath: string, context?: Context, epubDirArg?: string): Promise<ImportResult> {
    console.info('[LocalBookEngine] importBook start:', filePath);
    try {
      const ext = this.getExtension_(filePath);
      const typeInfo = this.getFileTypeInfo_(ext);
      if (!typeInfo) {
        return { success: false, bookId: 0, bookName: '', chapterCount: 0, error: `不支持的文件格式: ${ext}` };
      }

		      // 调用对应 Parser 解析
		      let meta: LocalBookMeta;
		      let chapters: BookChapter[];
		      let epubDirForToc = '';
			      if (typeInfo.parser === 'epub') {
			        // EPUB：TaskPool 已在前面完成解压，直接解析目录
			        const epubDir = epubDirArg || (this.getSandboxDir(context) + '/epub/' + Date.now().toString(36));
			        // 从目录解析
			        const dirParser = new DirEpubParser(epubDir, true); // skipContent=true：内容从文件按需加载
			        const result = await dirParser.parse();
			        // 保存封面图片到沙箱 covers 目录
			        let coverPath = '';
			        if (result.meta.coverPath) {
			          const coverSrc = epubDir + '/' + result.opfDir + result.meta.coverPath;
			          try {
			            if (fileFs.accessSync(coverSrc)) {
			              const coverDir = `${this.getSandboxDir()}/covers`;
			              if (!fileFs.accessSync(coverDir)) {
			                fileFs.mkdirSync(coverDir, true);
			              }
			              const coverExt = result.meta.coverPath.replace(/^.*\.(jpg|jpeg|png|gif|webp)$/i, '.$1') || '.jpg';
			              coverPath = `${coverDir}/${result.meta.title.replace(/[\\/:*?"<>|]/g, '_')}${coverExt}`;
			              fileFs.copyFileSync(coverSrc, coverPath);
			            }
			          } catch (e) {
			            console.warn('[LocalBookEngine] Failed to save cover:', e);
			            coverPath = '';
			          }
			        }
			        meta = {
			          title: result.meta.title,
			          author: result.meta.author,
			          description: result.meta.description,
			          subject: '',
			          coverPath,
			        };
			        chapters = result.chapters;
			        // 保存 epubDir 到 tocUrl，供阅读时按需读文件
			        epubDirForToc = epubDir;
			        console.info('[LocalBookEngine] epub parsed:', chapters.length, 'chapters from', epubDir);
			      } else {
			        const fallback = await this.parseFile_(filePath, typeInfo.parser);
			        meta = fallback.meta;
			        chapters = fallback.chapters;
			      }
      console.info('[LocalBookEngine] parsed:', meta.title, chapters.length, 'chapters');

      if (chapters.length === 0) {
        return { success: false, bookId: 0, bookName: meta.title || '', chapterCount: 0, error: '未解析到任何章节' };
      }

      // 创建 Book 记录
      const db = AppDatabase.getInstance().rdbStore;
      const bookDao = new BookTable(db);
      const chapterDao = new ChapterTable(db);

      const bookUrl = `local://${filePath}`;
      // 检查是否已导入过 — 重新导入时删除旧记录
      const existing = await bookDao.getBookByUrl(bookUrl);
      if (existing) {
        console.info('[LocalBookEngine] already imported, re-importing:', existing.id, existing.name);
        await chapterDao.deleteChaptersByBookId(existing.id);
        await bookDao.deleteBook(existing.id);
      }
      console.info('[LocalBookEngine] creating book record...');

      const book = createDefaultBook();
      book.name = meta.title || this.getFileName_(filePath);
      book.author = meta.author;
      book.bookUrl = bookUrl;
      book.origin = LOCAL_BOOK_ORIGIN;
	      book.originUrl = filePath;
	      book.tocUrl = epubDirForToc;
      book.type = BookType.TEXT;
      book.totalChapterNum = chapters.length;
      book.chapterCount = chapters.length;
      book.latestChapterTitle = chapters[chapters.length - 1]?.title || '';
      book.isShelf = true;
      book.canUpdate = false;
      book.introduce = HtmlUtil.stripHtml(meta.description || meta.subject);
      book.kind = ext.toUpperCase();
      book.customCoverPath = meta.coverPath;
      book.coverUrl = meta.coverPath ? 'file://' + meta.coverPath : '';
      book.wordCount = chapters.reduce((sum, ch) => sum + (ch.contentLength || 0), 0).toString();
      book.createTime = Date.now();
      book.lastOpenTime = 0;
      book.id = await bookDao.insertBook(book);
      console.info('[LocalBookEngine] book created, id=' + book.id);

	      // 设置 bookId 并批量写入章节（EPUB 内容已解压到目录，DB 不存全文）
	      const now = Date.now();
	      const bookChapters: BookChapter[] = chapters.map((ch: BookChapter, idx: number): BookChapter => {
	        return {
	          id: 0,
	          bookId: book.id,
	          index: ch.index >= 0 ? ch.index : idx,
	          volumeIndex: ch.volumeIndex,
	          title: ch.title,
	          url: ch.url,
	          content: typeInfo.parser === 'epub' ? '' : ch.content,
	          contentLength: ch.contentLength,
	          isRead: false,
	          isDownloaded: true,
	          isCached: true,
	          duration: 0,
	          audioUrl: '',
	          createTime: now,
	          updateTime: now,
	        };
	      });
      await chapterDao.insertChapters(bookChapters);
      console.info('[LocalBookEngine] chapters inserted:', bookChapters.length);

	      console.info(`[LocalBookEngine] Imported: ${book.name}, ${chapters.length} chapters`);
	      // 解压到目录后删除原始文件（节省沙箱空间）
	      if (ext === 'epub') {
	        try { fileFs.unlinkSync(filePath); } catch (_) { /* 删除失败不影响导入结果 */ }
	      }
	      return {
        success: true,
        bookId: book.id,
        bookName: book.name,
        chapterCount: chapters.length,
      };
    } catch (e) {
      console.error(`[LocalBookEngine] Import failed: ${filePath}`, e);
      return {
        success: false,
        bookId: 0,
        bookName: '',
        chapterCount: 0,
        error: e instanceof Error ? e.message : String(e),
      };
    }
  }

  /**
   * 批量导入多个文件
   */
  async importBooks(
    items: ImportFileItem[],
    context?: Context,
    onProgress?: (current: number, total: number, name: string) => void
  ): Promise<BatchImportResult> {
    console.info('[DBG] importBooks called, items=' + items.length);
    const details: ImportResult[] = [];
    let success = 0;
    let failed = 0;

    for (let i = 0; i < items.length; i++) {
      const { uri, fileName } = items[i];
      onProgress?.(i + 1, items.length, fileName);

      try {
        // 先拷贝到沙箱
        const sandboxPath = await this.copyToSandbox(uri, fileName, context);
        // 解析并导入
        const result = await this.importBook(sandboxPath, context, items[i].epubDir);
        details.push(result);
        if (result.success) {
          success++;
        } else {
          failed++;
        }
      } catch (e) {
        failed++;
        details.push({
          success: false,
          bookId: 0,
          bookName: fileName,
          chapterCount: 0,
          error: e instanceof Error ? e.message : String(e),
        });
      }
    }

    return { success, failed, details };
  }

  /**
   * 判断 Book 是否为本地书
   */
  static isLocalBook(book: Book): boolean {
    return book.origin === LOCAL_BOOK_ORIGIN;
  }

  /** 生成 EPUB 解压目标目录（使用时间戳+随机数，避免文件名特殊字符问题） */
  static getEpubDir(context?: Context): string {
    const base = context?.filesDir || globalThis.getContext()?.filesDir || '';
    const id = Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
    return `${base}/books/epub/${id}`;
  }

  // ==================== 私有方法 ====================

  /**
   * 调用对应 Parser 解析文件（非 EPUB 格式）
   */
  private async parseFile_(
    filePath: string,
    parser: 'txt' | 'mobi' | 'pdf'
  ): Promise<{ meta: LocalBookMeta; chapters: BookChapter[] }> {
    switch (parser) {
      case 'txt': {
        const result = await TxtParser.parse(filePath);
        const title = this.getFileName_(filePath).replace(/\.[^.]+$/, '');
        const meta: LocalBookMeta = { title, author: '', description: '', subject: '', coverPath: '' };
        return { meta, chapters: result.chapters };
      }
      case 'mobi': {
        const mobiParser = new MobiParser(filePath);
        const result = await mobiParser.parse();
        const meta: LocalBookMeta = {
          title: result.meta.title, author: result.meta.author,
          description: result.meta.description, subject: '', coverPath: '',
        };
        return { meta, chapters: result.chapters };
      }
      case 'pdf': {
        const pdfParser = new PdfParser(filePath);
        const result = await pdfParser.parse();
        const meta: LocalBookMeta = {
          title: result.meta.title, author: result.meta.author,
          description: '', subject: result.meta.subject, coverPath: '',
        };
        return { meta, chapters: result.chapters };
      }
      default:
        throw new Error(`Unknown parser: ${parser}`);
    }
  }

  /**
   * 根据扩展名获取文件类型信息
   */
  private getFileTypeInfo_(ext: string): FileTypeInfo | null {
    const normalized = ext.toLowerCase();
    switch (normalized) {
      case 'txt':
        return { extension: normalized, parser: 'txt' };
      case 'epub':
        return { extension: normalized, parser: 'epub' };
      case 'mobi':
      case 'azw':
      case 'azw3':
        return { extension: normalized, parser: 'mobi' };
      case 'pdf':
        return { extension: normalized, parser: 'pdf' };
      default:
        return null;
    }
  }

  private getExtension_(filePath: string): string {
    const dot = filePath.lastIndexOf('.');
    return dot >= 0 ? filePath.slice(dot + 1).toLowerCase() : '';
  }

  private getFileName_(filePath: string): string {
    const slash = filePath.lastIndexOf('/');
    return slash >= 0 ? filePath.slice(slash + 1) : filePath;
  }

  /**
   * 文件名安全化：替换非法字符
   */
  private sanitizeFileName_(name: string): string {
    return name.replace(/[\\/:*?"<>|]/g, '_');
  }
}

/** 全局单例 */
export const localBookEngine = new LocalBookEngine();
