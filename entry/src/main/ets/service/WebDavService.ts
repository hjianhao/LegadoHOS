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
import fileFs from '@ohos.file.fs';
import util from '@ohos.util';
import rcp from '@hms.collaboration.rcp';
import http from '@ohos.net.http';

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

  async listFiles(path: string = ''): Promise<WebDavFileInfo[]> {
    if (!this.config) return [];
    const url = this.normalizeUrl(path);
    const auth = this.getAuthHeader();
    const authVal = auth['Authorization'] || '';

    // 方法1：@ohos.net.http GET
    try {
      const result = await this.httpRequestString(http.RequestMethod.GET, url, { 'Authorization': authVal });
      if (result) {
        const p = this.parsePropfindResponse(result);
        if (p.length > 0) return p;
        const h = this.parseHtmlListing(result);
        if (h.length > 0) return h;
      }
    } catch (e) {
      console.warn('[WebDav] GET failed:', (e as Error).message);
    }

    // 方法2：RCP PUT + Overwrite:T 试写一个测试文件，看目录是否可用
    // 但不适用于列表

    return [];
  }

  /** 使用 @ohos.net.http 发送请求并返回响应文本 */
  private httpRequestString(method: http.RequestMethod, url: string, header: Record<string, string>): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      const req = http.createHttp();
      req.request(url, { method, header, connectTimeout: 15000, readTimeout: 20000 },
        (err: Error, data: http.HttpResponse) => {
          req.destroy();
          if (err) { reject(err); return; }
          if (data && data.result) resolve(String(data.result));
          else reject(new Error('empty response'));
        });
    });
  }

  async uploadBackupZip(zip: ZipWriter): Promise<string> {
    if (!this.config) throw new Error('WebDAV not configured');
    const fileName = getBackupFileName();
    // 确保目录存在（坚果云不会自动创建目录）
    await this.ensureDirectory('');
    const zipBytes = zip.build();
    // 分批转字符串避免 String.fromCharCode(...largeArray) 栈溢出
    const chunkSize = 16384;
    let body = '';
    for (let i = 0; i < zipBytes.length; i += chunkSize) {
      const chunk = zipBytes.slice(i, Math.min(i + chunkSize, zipBytes.length));
      body += String.fromCharCode(...chunk);
    }
    await NetUtil.httpPut(this.normalizeUrl(fileName), body, {
      ...this.getAuthHeader(), 'Content-Type': 'application/zip', 'Overwrite': 'T',
    });
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

  async listBackups(): Promise<WebDavFileInfo[]> {
    try {
      return (await this.listFiles('')).filter(f => !f.isDirectory && f.name.endsWith('.zip'));
    } catch {
      return [];
    }
  }

  async downloadBackup(name: string): Promise<string> {
    if (!this.config) throw new Error('WebDAV not configured');
    const url = this.normalizeUrl(name);
    const respText = await NetUtil.httpGet(url, this.getAuthHeader());
    if (!respText) throw new Error('下载失败');
    const tempPath = `/data/storage/el2/base/haps/entry/files/restore_${name}`;
    try { fileFs.unlinkSync(tempPath); } catch (_) { }
    const bytes = this.encoder.encodeInto(respText);
    const file = fileFs.openSync(tempPath, fileFs.OpenMode.CREATE | fileFs.OpenMode.WRITE_ONLY);
    try { fileFs.writeSync(file.fd, bytes.buffer as ArrayBuffer); } finally { fileFs.closeSync(file); }
    return tempPath;
  }

  async deleteBackup(name: string): Promise<void> {
    if (!this.config) return;
    try {
      await NetUtil.httpCustomMethod('DELETE', this.normalizeUrl(name), undefined, this.getAuthHeader(), 10000);
    } catch { /* ignore */ }
  }

  async uploadBookProgress(bookName: string, bookAuthor: string, progress: string): Promise<void> {
    if (!this.config) return;
    const fileName = `progress_${bookName}_${bookAuthor}.json`.replace(/[<>:"/\\|?*]/g, '_');
    await NetUtil.httpPut(this.normalizeUrl(fileName), progress, {
      ...this.getAuthHeader(), 'Content-Type': 'application/json',
    });
  }

  async downloadBookProgress(bookName: string, bookAuthor: string): Promise<string | null> {
    if (!this.config) return null;
    const fileName = `progress_${bookName}_${bookAuthor}.json`.replace(/[<>:"/\\|?*]/g, '_');
    try {
      return await NetUtil.httpGet(this.normalizeUrl(fileName), this.getAuthHeader());
    } catch {
      return null;
    }
  }

  async syncAllProgress(localProgress: Record<string, string>): Promise<Record<string, string>> {
    const merged: Record<string, string> = {};
    for (const [bookKey, localJson] of Object.entries(localProgress)) {
      const remote = await this.downloadBookProgress(bookKey, '');
      if (remote) {
        try {
          const localP = JSON.parse(localJson)['durChapterIndex'] || 0;
          const remoteP = JSON.parse(remote)['durChapterIndex'] || 0;
          merged[bookKey] = remoteP > localP ? remote : localJson;
        } catch { merged[bookKey] = localJson; }
      } else {
        merged[bookKey] = localJson;
      }
    }
    return merged;
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
    // 过滤掉当前目录自身（href == path 的条目）
    return files.filter(f => f.name !== '');
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
    const b64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let result = '';
    for (let i = 0; i < str.length; i += 3) {
      const b0 = str.charCodeAt(i), b1 = str.charCodeAt(i + 1) || 0, b2 = str.charCodeAt(i + 2) || 0;
      result += b64[b0 >> 2];
      result += b64[((b0 & 3) << 4) | (b1 >> 4)];
      result += (i + 1 < str.length) ? b64[((b1 & 0xF) << 2) | (b2 >> 6)] : '=';
      result += (i + 2 < str.length) ? b64[b2 & 0x3F] : '=';
    }
    return result;
  }
}
