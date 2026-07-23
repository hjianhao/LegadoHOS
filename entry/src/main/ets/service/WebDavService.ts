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
import { BookProgress } from '../model/BookProgress';
import { AppDatabase } from '../data/database/AppDatabase';
import { BookTable } from '../data/database/BookTable';
import { SettingsStore } from '../data/preferences/SettingsStore';
import fileFs from '@ohos.file.fs';
import util from '@ohos.util';
import rcp from '@hms.collaboration.rcp';
import { common } from '@kit.AbilityKit';
import { WebDavHttp, WebDavParseOptions, WebDavPropEntry } from './cloud/WebDavHttp';

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
 * 默认备份文件名（无设备名时）
 * 正式命名由 BackupConfig.getNowZipFileName() 负责。
 */
function getDefaultBackupFileName(): string {
  const d = new Date();
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `backup${y}-${m}-${day}.zip`;
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

  /**
   * 确保 WebDAV 相关 PersistentStorage 键在启动阶段已注册。
   * 备份设置页是懒加载模块，若不在启动时注册，AppStorage 读到的
   * webdav_sync_progress 会是 undefined，进度上传会被静默跳过。
   */
  static ensurePersistentProps(): void {
    PersistentStorage.persistProp('webdav_url', 'https://dav.jianguoyun.com/dav/');
    PersistentStorage.persistProp('webdav_user', '');
    PersistentStorage.persistProp('webdav_password', '');
    PersistentStorage.persistProp('webdav_path', 'legado');
    PersistentStorage.persistProp('webdav_auto_sync', false);
    PersistentStorage.persistProp('webdav_sync_progress', true);
    PersistentStorage.persistProp('webdav_sync_progress_plus', false);
  }

  /** 进度同步开关：未配置时默认开启（对齐安卓 AppConfig.syncBookProgress 默认 true） */
  static isProgressSyncEnabled(): boolean {
    WebDavService.ensurePersistentProps();
    const syncOn = AppStorage.get<boolean>('webdav_sync_progress');
    return syncOn !== false;
  }

  async initFromStorage(context: common.Context): Promise<void> {
    try {
      WebDavService.ensurePersistentProps();
      const url = AppStorage.get<string>('webdav_url') || '';
      const user = AppStorage.get<string>('webdav_user') || '';
      const path = AppStorage.get<string>('webdav_path') || 'legado';
      if (!url || !user) {
        console.info('[WebDav] initFromStorage skip: url/user empty');
        return; // 从未配置过
      }
      let pwd = '';
      try {
        const s = SettingsStore.getInstance();
        await s.init(context);
        pwd = await s.getWebDavPassword();
      } catch (_e) { /* 密码读取失败按空处理 */ }
      // 兼容旧版本：密码只写在 PersistentStorage.webdav_password 时也能恢复
      if (!pwd) {
        pwd = AppStorage.get<string>('webdav_password') || '';
        if (pwd) {
          try {
            const s = SettingsStore.getInstance();
            await s.setWebDavPassword(pwd);
            console.info('[WebDav] migrated plaintext password into SettingsStore');
          } catch (_e) { /* ignore migrate fail */ }
        }
      }
      const autoSync = AppStorage.get<boolean>('webdav_auto_sync') ?? false;
      this.configure({
        serverUrl: url,
        username: user,
        password: pwd,
        path: path,
        autoSync: autoSync,
        syncInterval: 60,
      });
      console.info('[WebDav] config restored from storage, user=' + user
        + ', hasPwd=' + (pwd.length > 0)
        + ', syncProgress=' + WebDavService.isProgressSyncEnabled());
    } catch (e) {
      console.warn('[WebDav] initFromStorage fail:', (e as Error).message);
    }
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
    const files = await this.listFiles('');
    // 对齐安卓：仅展示 backup* 文件，并按修改时间倒序
    const backups = files.filter((f) => {
      const n = (f.name || '').toLowerCase();
      return n.startsWith('backup') && (n.endsWith('.zip') || n === 'backup.zip' || n.startsWith('backup'));
    });
    backups.sort((a, b) => {
      const ta = Date.parse(a.lastModified) || 0;
      const tb = Date.parse(b.lastModified) || 0;
      if (tb !== ta) return tb - ta;
      return b.name.localeCompare(a.name);
    });
    return backups;
  }

  /** 是否存在指定备份文件名 */
  async hasBackup(name: string): Promise<boolean> {
    if (!this.config || !name) return false;
    try {
      const files = await this.listBackups();
      return files.some((f) => f.name === name);
    } catch {
      return false;
    }
  }

  /** 最近一份备份（按 lastModified） */
  async lastBackup(): Promise<WebDavFileInfo | null> {
    const files = await this.listBackups();
    return files.length > 0 ? files[0] : null;
  }

  /**
   * 列出 bookProgress 目录。与 listFiles 不同：PROPFIND 失败会抛错，
   * 让 downloadAll 能退化为逐本 GET，而不是把空列表当成“云端无进度”。
   */
  private async listProgressFiles_(): Promise<WebDavFileInfo[]> {
    if (!this.config) throw new Error('WebDAV not configured');
    const url = this.normalizeUrl(WebDavService.PROGRESS_DIR);
    const auth = this.getAuthHeader();
    const requestBody =
      '<?xml version="1.0" encoding="utf-8"?>\n' +
      '<D:propfind xmlns:D="DAV:">\n' +
      '  <D:allprop/>\n' +
      '</D:propfind>';
    console.info('[WebDav] PROPFIND progress dir:', url);
    const respBody = await NetUtil.httpCustomMethod('PROPFIND', url, requestBody, {
      ...auth,
      'Depth': '1',
    }, 30000);
    if (!respBody) {
      throw new Error('empty PROPFIND response');
    }
    return this.parsePropfindResponse(respBody);
  }

  async uploadBackupFile(zipPath: string, preferredName?: string): Promise<string> {
    if (!this.config) throw new Error('WebDAV not configured');
    const fileName = (preferredName && preferredName.trim()) ? preferredName.trim() : getDefaultBackupFileName();
    await this.ensureDirectory('');
    const zipBytes = this.readFileBytes(zipPath);

    // 直接上传二进制（ArrayBuffer），不做 String.fromCharCode 转换
    // String 会被 RCP 按 UTF-8 编码，导致二进制数据损坏
    const url = this.normalizeUrl(fileName);
    const authVal = this.getAuthHeader()['Authorization'] || '';

    console.info('[WebDav] Uploading binary:', fileName, zipBytes.length, 'bytes');
    let session: rcp.Session | null = null;
    try {
      session = rcp.createSession({
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
      console.info('[WebDav] Binary upload status:', response.statusCode);

      if (response.statusCode < 200 || response.statusCode >= 400) {
        throw new Error(`上传失败: HTTP ${response.statusCode}`);
      }
    } catch (err) {
      throw new Error('上传失败: ' + (err as Error).message);
    } finally {
      if (session) {
        try {
          session.close();
        } catch (err) {
          console.warn('[WebDav] close upload session failed:', (err as Error).message);
        }
      }
    }
    return fileName;
  }

  private readFileBytes(path: string): Uint8Array {
    let file: fileFs.File | null = null;
    try {
      const stat = fileFs.statSync(path);
      const buf = new ArrayBuffer(stat.size);
      file = fileFs.openSync(path, fileFs.OpenMode.READ_ONLY);
      fileFs.readSync(file.fd, buf);
      return new Uint8Array(buf);
    } catch (err) {
      throw new Error(`读取上传文件失败: ${path}: ${(err as Error).message}`);
    } finally {
      if (file) {
        try {
          fileFs.closeSync(file);
        } catch (err) {
          console.warn('[WebDav] close upload file failed:', (err as Error).message);
        }
      }
    }
  }

  /**
   * 确保 WebDAV 目录存在
   * @param path 相对于配置根路径的目录，空字符串表示根路径本身
   */
  async ensureDirectory(path: string): Promise<void> {
    if (!this.config) return;
    const auth = this.getAuthHeader();
    // 逐级创建目录：先根路径，再 bookProgress 等子目录。
    // 坚果云等服务对不存在的父目录直接 MKCOL 子路径会失败。
    const segments: string[] = [];
    const rootPath = (this.config.path || '').replace(/^\/+|\/+$/g, '');
    if (rootPath) {
      for (const seg of rootPath.split('/')) {
        if (seg) segments.push(seg);
      }
    }
    const rel = (path || '').replace(/^\/+|\/+$/g, '');
    if (rel) {
      for (const seg of rel.split('/')) {
        if (seg) segments.push(seg);
      }
    }
    let built = this.config.serverUrl.replace(/\/+$/, '');
    for (const seg of segments) {
      built += '/' + seg;
      try {
        await NetUtil.httpCustomMethod('MKCOL', built, undefined, auth, 10000);
      } catch {
        // 已存在 / 不支持 MKCOL：忽略
      }
    }
  }

  async downloadBackup(name: string): Promise<string> {
    if (!this.config) throw new Error('WebDAV not configured');
    const url = this.normalizeUrl(name);
    const auth = this.getAuthHeader();
    const authVal = auth['Authorization'] || '';

    // 直接下载二进制数据（不能用文本方式，ZIP 文件会被损坏）
    console.info('[WebDav] Downloading backup:', url);
    let session: rcp.Session | null = null;
    try {
      session = rcp.createSession({
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
        throw new Error(`下载失败: HTTP ${response.statusCode}`);
      }

      if (!response.body) {
        throw new Error('下载失败: 空响应');
      }

      // 直接写二进制数据到文件
      const tempPath = `/data/storage/el2/base/haps/entry/files/restore_${name}`;
      try {
        fileFs.unlinkSync(tempPath);
      } catch (_e) {}
      const bodyBytes = new Uint8Array(response.body);
      let file: fileFs.File | null = null;
      try {
        file = fileFs.openSync(tempPath, fileFs.OpenMode.CREATE | fileFs.OpenMode.WRITE_ONLY);
        fileFs.writeSync(file.fd, bodyBytes.buffer);
        console.info('[WebDav] Downloaded:', bodyBytes.length, 'bytes to', tempPath);
      } catch (err) {
        throw new Error(`写入备份文件失败: ${tempPath}: ${(err as Error).message}`);
      } finally {
        if (file) {
          try {
            fileFs.closeSync(file);
          } catch (err) {
            console.warn('[WebDav] close backup file failed:', (err as Error).message);
          }
        }
      }
      return tempPath;
    } catch (err) {
      throw new Error('下载失败: ' + (err as Error).message);
    } finally {
      if (session) {
        try {
          session.close();
        } catch (err) {
          console.warn('[WebDav] close download session failed:', (err as Error).message);
        }
      }
    }
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
    if (!this.config) {
      console.warn('[WebDav] uploadBookProgress skipped: not configured');
      return;
    }
    if (!WebDavService.isProgressSyncEnabled()) {
      console.info('[WebDav] uploadBookProgress skipped: sync disabled');
      return;
    }
    if (!this.config.password) {
      console.warn('[WebDav] uploadBookProgress skipped: empty password');
      return;
    }
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
    console.info('[WebDav] Uploading progress:', book.name, '→', url);
    await NetUtil.httpPut(url, json, {
      ...this.getAuthHeader(),
      'Content-Type': 'application/json',
      'Overwrite': 'T',
    });
    console.info('[WebDav] Progress uploaded:', book.name, 'ch=', book.durChapterIndex, 'pos=', book.durChapterPos);
  }

  /**
   * 下载单本书的阅读进度
   */
  async downloadBookProgress(name: string, author: string): Promise<BookProgress | null> {
    if (!this.config) return null;
    if (!this.config.password) {
      console.warn('[WebDav] downloadBookProgress skipped: empty password');
      return null;
    }
    try {
      const url = this.progressUrl(name, author);
      console.info('[WebDav] GET progress:', name, '→', url);
      const json = await NetUtil.httpGet(url, this.getAuthHeader());
      if (json) {
        const p = JSON.parse(json) as BookProgress;
        if (typeof p.durChapterIndex === 'number') {
          console.info('[WebDav] Progress downloaded:', name, 'ch=', p.durChapterIndex, 'pos=', p.durChapterPos);
          return p;
        }
        console.warn('[WebDav] Progress JSON invalid for', name);
      }
    } catch (e) {
      // 404/无文件是常态，只记 info；认证/网络错误要 warn
      const msg = (e as Error).message || String(e);
      if (msg.indexOf('404') >= 0 || msg.indexOf('Not Found') >= 0) {
        console.info('[WebDav] No cloud progress for', name);
      } else {
        console.warn('[WebDav] downloadBookProgress failed:', name, msg);
      }
    }
    return null;
  }

  /**
   * 解析 WebDAV lastModified（RFC1123 / ISO / 数字毫秒）为时间戳。
   * 解析失败返回 0，调用方应退化为“总是下载并按章节比较”。
   */
  private parseLastModifiedMs_(value: string): number {
    if (!value) return 0;
    const trimmed = value.trim();
    if (!trimmed) return 0;
    // 纯数字（秒或毫秒）
    if (/^\d+$/.test(trimmed)) {
      const n = Number(trimmed);
      if (!Number.isFinite(n) || n <= 0) return 0;
      // 10 位按秒，13 位按毫秒
      return n < 1e12 ? n * 1000 : n;
    }
    const ms = Date.parse(trimmed);
    return Number.isFinite(ms) ? ms : 0;
  }

  /**
   * 启动/刷新时批量下载所有在架书籍的云端进度。
   * 对齐 Android downloadAllBookProgress：
   * - 优先 PROPFIND 列目录 + 时间戳过滤
   * - 列目录失败时退化为逐本 GET（坚果云等对 PROPFIND 不稳）
   * - 仅当云端章节更远时覆盖本地（章内精确位置由开书 syncFromCloud 处理）
   * @returns 实际更新了本地进度的书本数量
   */
  async downloadAllBookProgress(): Promise<number> {
    if (!this.config) {
      console.info('[WebDav] downloadAllBookProgress skipped: not configured');
      return 0;
    }
    if (!WebDavService.isProgressSyncEnabled()) {
      console.info('[WebDav] downloadAllBookProgress skipped: sync disabled');
      return 0;
    }
    if (!this.config.password) {
      console.warn('[WebDav] downloadAllBookProgress skipped: empty password');
      return 0;
    }

    let updated = 0;
    try {
      const db = AppDatabase.getInstance();
      if (!db.rdbStore) {
        console.warn('[WebDav] downloadAllBookProgress: db not ready');
        return 0;
      }
      const bookTable = new BookTable(db.rdbStore);
      const allBooks = await bookTable.getAllShelfBooksSimple();
      if (allBooks.length === 0) {
        console.info('[WebDav] downloadAllBookProgress: empty shelf');
        return 0;
      }

      // 列目录（失败不致命）。
      // 注意：listFiles 在 PROPFIND 失败时也会返回 []，不能把“空数组”当成“云端无文件”。
      let fileMap = new Map<string, number>();
      let listed = false;
      try {
        const files = await this.listProgressFiles_();
        for (const f of files) {
          if (!f.isDirectory && f.name.endsWith('.json')) {
            fileMap.set(f.name, this.parseLastModifiedMs_(f.lastModified));
          }
        }
        listed = true;
        console.info('[WebDav] progress dir listed:', fileMap.size, 'files for', allBooks.length, 'books');
        // 目录存在但解析结果为空：可能是 PROPFIND 内容不完整/中文文件名解析失败。
        // 对书架规模做有限逐本 GET 兜底（最多 30 本），避免“永远同步不到”。
        if (fileMap.size === 0 && allBooks.length > 0) {
          console.warn('[WebDav] progress dir empty after list, fallback to per-book GET');
          listed = false;
        }
      } catch (e) {
        console.warn('[WebDav] list progress dir failed, fallback to per-book GET:', (e as Error).message);
        fileMap = new Map<string, number>();
        listed = false;
      }

      let probed = 0;
      const maxProbe = listed ? allBooks.length : Math.min(allBooks.length, 30);
      for (const book of allBooks) {
        if (!listed && probed >= maxProbe) {
          console.info('[WebDav] per-book GET probe limit reached:', maxProbe);
          break;
        }
        const fileName = this.progressFileName(book.name, book.author);

        if (listed) {
          // 列目录成功：没有对应文件就跳过；有文件且时间戳不新也跳过
          if (!fileMap.has(fileName)) {
            continue;
          }
          const cloudMod = fileMap.get(fileName) || 0;
          if (cloudMod > 0 && book.syncTime > 0 && cloudMod <= book.syncTime) {
            continue;
          }
        } else {
          probed++;
        }

        const cloud = await this.downloadBookProgress(book.name, book.author);
        if (!cloud) continue;

        // 冲突解决：云端章节更远才覆盖本地。
        // 云端 durChapterPos 是字符偏移，本地是分页索引，不能直接写入本地 pos。
        if (cloud.durChapterIndex > book.durChapterIndex) {
          await bookTable.updateReadingProgress(
            book.bookUrl,
            cloud.durChapterIndex,
            cloud.durChapterTitle || '',
            0,
            0
          );
          updated++;
          console.info('[WebDav] Progress restored from cloud:', book.name,
            '→ chapter', cloud.durChapterIndex, '(was', book.durChapterIndex + ')');
        } else {
          console.info('[WebDav] Cloud not ahead for', book.name,
            'local=', book.durChapterIndex, 'cloud=', cloud.durChapterIndex);
        }

        // 只有成功拿到云端进度后才 bump syncTime，避免“空列表/失败”把后续同步永久挡掉
        await bookTable.updateSyncTime(book.bookUrl, Date.now());
      }
      console.info('[WebDav] downloadAllBookProgress done, updated=', updated);
    } catch (e) {
      console.warn('[WebDav] downloadAllBookProgress error:', (e as Error).message);
    }
    return updated;
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
    return WebDavHttp.basicAuthHeader(this.config.username, this.config.password);
  }

  /**
   * 备份/进度列举：过滤目录，仅保留文件。
   * 解析逻辑下沉到 WebDavHttp，避免与云端书库分叉；过滤策略保持备份兼容。
   */
  private parsePropfindResponse(xml: string): WebDavFileInfo[] {
    const opts: WebDavParseOptions = {
      includeDirectories: false,
      requestUrl: '',
    };
    const entries: WebDavPropEntry[] = WebDavHttp.parsePropfindResponse(xml, opts);
    const files: WebDavFileInfo[] = [];
    for (let i = 0; i < entries.length; i++) {
      const e = entries[i];
      if (!e.name || e.isDirectory) {
        continue;
      }
      files.push({
        name: e.name,
        path: e.href,
        lastModified: e.lastModified,
        contentLength: e.contentLength,
        isDirectory: false,
      });
    }
    return files;
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
    return WebDavHttp.base64Encode(str);
  }
}
