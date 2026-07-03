/**
 * WebDAV 同步服务
 *
 * 实现阅读进度同步和备份/恢复功能。
 * 兼容 Legado 的 WebDAV 数据格式。
 *
 * WebDAV 协议基于 HTTP 扩展，支持：
 * - PROPFIND（列表）
 * - GET（下载）
 * - PUT（上传）
 * - MKCOL（创建目录）
 * - DELETE（删除）
 *
 * 目录结构：
 *   {serverUrl}/{path}/    ← 配置的路径，备份文件直接放在这里
 */
import { NetUtil } from '../util/NetUtil';
import { ZipWriter } from '../util/ZipWriter';
import { BookProgress } from '../model/BookProgress';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookTable } from '../data/database/BookTable';
import fileFs from '@ohos.file.fs';
import util from '@ohos.util';
import rcp from '@hms.collaboration.rcp';

export interface WebDavConfig {
  serverUrl: string;
  username: string;
  password: string;
  path: string;            // 同步根路径
  autoSync: boolean;
  syncInterval: number;    // 分钟
}

export interface WebDavFileInfo {
  name: string;
  path: string;
  lastModified: string;
  contentLength: number;
  isDirectory: boolean;
}

/**
 * 获取 getBackupFileName 返回的名称
 */
function getBackupFileName(): string {
  return `backup_${new Date().toISOString().slice(0, 10)}.zip`;
}

export class WebDavService {
  private static instance: WebDavService;
  private config: WebDavConfig | null = null;
  private encoder: util.TextEncoder = new util.TextEncoder();

  private constructor() {}

  static getInstance(): WebDavService {
    if (!WebDavService.instance) {
      WebDavService.instance = new WebDavService();
    }
    return WebDavService.instance;
  }

  configure(config: WebDavConfig): void {
    this.config = config;
  }

  getConfig(): WebDavConfig | null {
    return this.config;
  }

  isConfigured(): boolean {
    return !!this.config && !!this.config.serverUrl && !!this.config.username;
  }

  async testConnection(): Promise<boolean> {
    if (!this.config) return false;
    try {
      // OPTIONS 是标准 HTTP 方法，所有 WebDAV 服务器都应支持
      await NetUtil.httpCustomMethod('OPTIONS', this.normalizeUrl(''), undefined, {
        ...this.getAuthHeader(),
      }, 15000);
      return true;
    } catch {
      return false;
    }
  }

  /**
   * 通过 RCP PROPFIND 获取文件列表
   *
   * 坚果云对 PROPFIND 有严格的客户端限制。
   * 使用 NetUtil session（与 OPTIONS/PUT 同一 session，已验证可用）发起。
   */
  /**
   * 通过 NetUtil.session 发 PROPFIND 获取文件列表
   */
  async listFiles(path: string = ''): Promise<WebDavFileInfo[]> {
    if (!this.config) return [];
    const url = this.normalizeUrl(path);
    const auth = this.getAuthHeader();

    const requestBody =
      '<?xml version="1.0" encoding="utf-8"?>\n' +
      '<D:propfind xmlns:D="DAV:">\n' +
      '  <D:allprop/>\n' +
      '</D:propfind>';

    try {
      console.info('[WebDav] PROPFIND:', url);
      const respBody = await NetUtil.httpCustomMethod('PROPFIND', url, requestBody, {
        ...auth,
        'Depth': '1',
      }, 30000);
      if (respBody) {
        const parsed = this.parsePropfindResponse(respBody);
        console.info('[WebDav] PROPFIND parsed:', parsed.length, 'files');
        return parsed;
      }
    } catch (e) {
      console.warn('[WebDav] PROPFIND failed:', (e as Error).message);
    }

    return [];
  }

  async listBackups(): Promise<WebDavFileInfo[]> {
    return this.listFiles('');
  }

  async uploadBackupZip(zip: ZipWriter): Promise<string> {
    if (!this.config) throw new Error('WebDAV not configured');
    const fileName = getBackupFileName();
    await this.ensureDirectory('');
    const zipBytes = zip.build();

    // 直接上传二进制（ArrayBuffer），不做 String.fromCharCode 转换
    // String 会被 RCP 按 UTF-8 编码，导致二进制数据损坏
    const url = this.normalizeUrl(fileName);
    const authVal = this.getAuthHeader()['Authorization'] || '';

    console.info('[WebDav] Uploading binary:', fileName, zipBytes.length, 'bytes');
    const session = rcp.createSession({
      requestConfiguration: {
        transfer: { timeout: { connectMs: 15000, transferMs: 60000 } }
      }
    });
    const request = new rcp.Request(
      url,
      'PUT' as rcp.HttpMethod,
      {
        'Authorization': authVal,
        'Content-Type': 'application/zip',
        'Overwrite': 'T',
      } as rcp.RequestHeaders,
      zipBytes.buffer as ArrayBuffer
    );
    const response = await session.fetch(request);
    session.close();
    console.info('[WebDav] Binary upload status:', response.statusCode);

    if (response.statusCode < 200 || response.statusCode >= 400) {
      throw new Error(`上传失败: HTTP ${response.statusCode}`);
    }
    return fileName;
  }

  /**
   * 确保 WebDAV 目录存在
   * @param path 相对于配置根路径的目录，空字符串表示根路径本身
   */
  async ensureDirectory(path: string): Promise<void> {
    if (!this.config) return;
    const url = this.normalizeUrl(path);
    const auth = this.getAuthHeader();
    // 直接 MKCOL 创建目录（如果已存在，服务器会返回 405 或 409，不影响后续 PUT）
    try {
      await NetUtil.httpCustomMethod('MKCOL', url, undefined, auth, 10000);
    } catch {
      // MKCOL 失败（目录已存在、方法不支持等情况），忽略
    }
  }

  async downloadBackup(name: string): Promise<string> {
    if (!this.config) throw new Error('WebDAV not configured');
    const url = this.normalizeUrl(name);
    const auth = this.getAuthHeader();
    const authVal = auth['Authorization'] || '';

    // 直接下载二进制数据（不能用文本方式，ZIP 文件会被损坏）
    console.info('[WebDav] Downloading backup:', url);
    const session = rcp.createSession({
      requestConfiguration: {
        transfer: { timeout: { connectMs: 15000, transferMs: 60000 } }
      }
    });

    const request = new rcp.Request(
      url,
      'GET' as rcp.HttpMethod,
      { 'Authorization': authVal } as rcp.RequestHeaders,
      ''
    );

    const response = await session.fetch(request);
    console.info('[WebDav] Download status:', response.statusCode);

    if (response.statusCode < 200 || response.statusCode >= 400) {
      session.close();
      throw new Error(`下载失败: HTTP ${response.statusCode}`);
    }

    if (!response.body) {
      session.close();
      throw new Error('下载失败: 空响应');
    }

    // 直接写二进制数据到文件
    const tempPath = `/data/storage/el2/base/haps/entry/files/restore_${name}`;
    try { fileFs.unlinkSync(tempPath); } catch (_) { }
    const bodyBytes = new Uint8Array(response.body);
    const file = fileFs.openSync(tempPath, fileFs.OpenMode.CREATE | fileFs.OpenMode.WRITE_ONLY);
    try {
      fileFs.writeSync(file.fd, bodyBytes.buffer);
      console.info('[WebDav] Downloaded:', bodyBytes.length, 'bytes to', tempPath);
    } finally {
      fileFs.closeSync(file);
    }
    session.close();
    return tempPath;
  }

  async deleteBackup(name: string): Promise<void> {
    if (!this.config) return;
    try {
      await NetUtil.httpCustomMethod('DELETE', this.normalizeUrl(name), undefined, this.getAuthHeader(), 10000);
    } catch { /* ignore */ }
  }

  // ---- 阅读进度同步 ----

  /** 进度文件存储子目录（对齐 Android Legado） */
  private static readonly PROGRESS_DIR = 'bookProgress';

  /**
   * 生成进度文件名（对齐 Android 的 getProgressFileName）
   */
  private progressFileName(name: string, author: string): string {
    const raw = `${name}_${author}`.replace(/[<>:"/\\|?*]/g, '_');
    return raw + '.json';
  }

  /** 进度文件在 WebDAV 上的路径 */
  private progressUrl(name: string, author: string): string {
    return this.normalizeUrl(`${WebDavService.PROGRESS_DIR}/${this.progressFileName(name, author)}`);
  }

  /**
   * 上传单本书的阅读进度
   */
  async uploadBookProgress(book: { name: string; author: string; durChapterIndex: number;
    durChapterPos: number; durChapterTitle: string }): Promise<void> {
    if (!this.config) return;
    await this.ensureDirectory(WebDavService.PROGRESS_DIR);

    const progress = {
      name: book.name,
      author: book.author,
      durChapterIndex: book.durChapterIndex,
      durChapterPos: book.durChapterPos,
      durChapterTime: Date.now(),
      durChapterTitle: book.durChapterTitle || '',
    };

    const url = this.progressUrl(book.name, book.author);
    const json = JSON.stringify(progress);
    await NetUtil.httpPut(url, json, {
      ...this.getAuthHeader(),
      'Content-Type': 'application/json',
      'Overwrite': 'T',
    });
    console.info('[WebDav] Progress uploaded:', book.name);
  }

  /**
   * 下载单本书的阅读进度
   */
  async downloadBookProgress(name: string, author: string): Promise<BookProgress | null> {
    if (!this.config) return null;
    try {
      const url = this.progressUrl(name, author);
      const json = await NetUtil.httpGet(url, this.getAuthHeader());
      if (json) {
        const p = JSON.parse(json) as BookProgress;
        if (typeof p.durChapterIndex === 'number') return p;
      }
    } catch { /* not found or parse error */ }
    return null;
  }

  /**
   * 启动时批量下载所有在架书籍的云端进度
   * 对齐 Android downloadAllBookProgress 逻辑
   */
  async downloadAllBookProgress(): Promise<void> {
    if (!this.config) return;

    try {
      // 列出 bookProgress/ 目录中的文件
      const files = await this.listFiles(WebDavService.PROGRESS_DIR);
      if (files.length === 0) return;

      // 构建文件名 → 上次修改时间的映射
      const fileMap = new Map<string, string>();
      for (const f of files) {
        if (!f.isDirectory && f.name.endsWith('.json')) {
          fileMap.set(f.name, f.lastModified);
        }
      }

      if (fileMap.size === 0) return;

      // 获取所有在架书籍
      const db = AppDatabase.getInstance();
      if (!db.rdbStore) return;
      const bookTable = new BookTable(db.rdbStore);
      const allBooks = await bookTable.getAllShelfBooksSimple();

      for (const book of allBooks) {
        const fileName = this.progressFileName(book.name, book.author);
        const fileLastMod = fileMap.get(fileName);
        if (!fileLastMod) continue;

        // 检查时间戳 — 云端文件不比本地 syncTime 新就跳过
        // （简单起见：首次 syncTime=0 时总是下载）
        if (book.syncTime > 0) {
          // lastModified 字段是字符串，简单比较
          if (fileLastMod <= String(book.syncTime)) continue;
        }

        const cloud = await this.downloadBookProgress(book.name, book.author);
        if (!cloud) continue;

        // 冲突解决：云端进度更远才覆盖
        if (cloud.durChapterIndex > book.durChapterIndex ||
          (cloud.durChapterIndex === book.durChapterIndex &&
           cloud.durChapterPos > book.durChapterPos)) {
          // 更新本地进度
          await bookTable.updateReadingProgress(
            book.bookUrl,
            cloud.durChapterIndex,
            cloud.durChapterTitle || '',
            0, // totalChapters unknown
            cloud.durChapterPos
          );
          console.info('[WebDav] Progress restored from cloud:', book.name,
            '→ chapter', cloud.durChapterIndex);
        }

        // 更新 syncTime
        await bookTable.updateSyncTime(book.bookUrl, Date.now());
      }
    } catch (e) {
      console.warn('[WebDav] downloadAllBookProgress error:', (e as Error).message);
    }
  }

  private normalizeUrl(path: string): string {
    if (!this.config) return '';
    let base = this.config.serverUrl.replace(/\/+$/, '');
    if (this.config.path) {
      base += '/' + this.config.path.replace(/^\/+|\/+$/g, '');
    }
    if (path) {
      base += '/' + path.replace(/^\/+/, '');
    }
    return base;
  }

  private getAuthHeader(): Record<string, string> {
    if (!this.config) return {};
    const credentials = `${this.config.username}:${this.config.password}`;
    const encoded = this.base64Encode(credentials);
    return { 'Authorization': `Basic ${encoded}` };
  }

  private parsePropfindResponse(xml: string): WebDavFileInfo[] {
    const files: WebDavFileInfo[] = [];
    if (!xml) return files;
    // 支持有/无命名空间前缀的 XML（如 <d:response> 或 <response>）
    const responseRegex = /<(?:[a-zA-Z]+:)?response[^>]*>([\s\S]*?)<\/(?:[a-zA-Z]+:)?response>/gi;
    let match: RegExpExecArray | null;
    while ((match = responseRegex.exec(xml)) !== null) {
      const block = match[1];
      const hrefMatch = block.match(/<(?:[a-zA-Z]+:)?href[^>]*>([\s\S]*?)<\/(?:[a-zA-Z]+:)?href>/i);
      if (!hrefMatch) continue;
      let href = hrefMatch[1].trim();
      // 某些服务器返回的 href 包含完整 URL，只取路径部分
      if (href.startsWith('http://') || href.startsWith('https://')) {
        // 去掉协议和主机部分：https://host:port/path → /path
        const m = href.match(/^https?:\/\/[^\/]+(\/.*)/);
        if (m) href = m[1];
      }
      const isDir = /<(?:[a-zA-Z]+:)?collection\s*\/>/i.test(block) ||
                    /<(?:[a-zA-Z]+:)?resourcetype[^>]*>[\s\S]*?<(?:[a-zA-Z]+:)?collection[\s\S]*?<\/(?:[a-zA-Z]+:)?resourcetype>/i.test(block);
      const modMatch = block.match(/<(?:[a-zA-Z]+:)?getlastmodified[^>]*>([\s\S]*?)<\/(?:[a-zA-Z]+:)?getlastmodified>/i);
      const sizeMatch = block.match(/<(?:[a-zA-Z]+:)?getcontentlength[^>]*>([\s\S]*?)<\/(?:[a-zA-Z]+:)?getcontentlength>/i);
      const name = href.split('/').filter(s => s).pop() || href;
      files.push({
        name, path: href,
        lastModified: modMatch ? modMatch[1].trim() : '',
        contentLength: sizeMatch ? parseInt(sizeMatch[1].trim()) || 0 : 0,
        isDirectory: isDir,
      });
    }
    // 过滤掉目录、空名、以及目录自身的条目
    return files.filter(f => f.name !== '' && !f.isDirectory);
  }

  /**
   * 从 HTML 响应中提取文件/目录列表（某些 WebDAV 服务器的备选方案）
   */
  private parseHtmlListing(html: string): WebDavFileInfo[] {
    const files: WebDavFileInfo[] = [];
    if (!html) return files;
    // 匹配 <a href="...">...</a>
    const linkRegex = /<a\s+[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi;
    let match: RegExpExecArray | null;
    while ((match = linkRegex.exec(html)) !== null) {
      const href = match[1].trim();
      const text = match[2].replace(/<[^>]+>/g, '').trim();
      if (!href || href === '../' || href === './' || href === '/') continue;
      // 跳过查询参数和锚点
      if (href.startsWith('?') || href.startsWith('#')) continue;
      const isDir = href.endsWith('/');
      const name = isDir ? href.replace(/\/$/, '') : href;
      files.push({
        name, path: href,
        lastModified: '',
        contentLength: 0,
        isDirectory: isDir,
      });
    }
    return files;
  }

  private base64Encode(str: string): string {
    // Use proper byte-level encoding (like OkHttp's Credentials.basic)
    const bytes = this.encoder.encodeInto(str);
    const b64 = new util.Base64Helper();
    return b64.encodeToStringSync(bytes);
  }
}
