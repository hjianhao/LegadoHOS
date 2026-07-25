/**
 * WebDAV 云存储 Provider（云端书库）
 *
 * 与备份 WebDavService 独立：多来源、独立 rootPath、list 保留目录。
 */
import fileFs from '@ohos.file.fs';
import rcp from '@hms.collaboration.rcp';
import {
  CloudCredential,
  CLOUD_PROVIDER_WEBDAV,
  CloudSource,
  createDefaultWebDavCloudConfig,
  WebDavCloudConfig,
} from '../../model/CloudSource';
import { CloudPath } from './CloudPath';
import {
  CloudFile,
  CloudListPage,
  CloudProviderCapabilities,
  CloudStorageProvider,
  createEmptyCloudFile,
  createEmptyCloudListPage,
} from './CloudStorageProvider';
import { WebDavHttp, WebDavParseOptions, WebDavPropEntry } from './WebDavHttp';
import { NetUtil } from '../../util/NetUtil';

export class WebDavCloudProvider implements CloudStorageProvider {
  readonly type: string = CLOUD_PROVIDER_WEBDAV;

  getCapabilities(): CloudProviderCapabilities {
    return {
      canCreateDirectory: true,
      canDelete: true,
      canMove: false,
      supportsEtag: true,
      supportsRangeDownload: false,
    };
  }

  async testConnection(source: CloudSource, credential: CloudCredential): Promise<void> {
    this.assertSource_(source, credential);
    const url = this.rootUrl_(source);
    const auth = WebDavHttp.basicAuthHeader(credential.username, credential.secret);
    const cfg = this.readConfig_(source);
    try {
      await NetUtil.httpCustomMethod('OPTIONS', url, '', auth, cfg.connectTimeoutMs);
      return;
    } catch (optErr) {
      // 部分服务不支持 OPTIONS，退化为 PROPFIND Depth:0
      console.info('[WebDavCloud] OPTIONS failed, try PROPFIND Depth:0:',
        WebDavHttp.toUserMessage(optErr as Object));
    }
    try {
      await WebDavHttp.propfind(url, auth, '0', cfg.connectTimeoutMs);
    } catch (e) {
      throw new Error(WebDavHttp.toUserMessage(e as Object));
    }
  }

  async list(
    source: CloudSource,
    credential: CloudCredential,
    remotePath: string,
    _cursor?: string
  ): Promise<CloudListPage> {
    this.assertSource_(source, credential);
    const path = CloudPath.normalizeRemotePath(remotePath || '');
    // list 目标始终是目录
    const url = this.ensureDirUrl_(this.fileUrl_(source, path));
    const auth = WebDavHttp.basicAuthHeader(credential.username, credential.secret);
    const cfg = this.readConfig_(source);
    let xml = '';
    try {
      console.info('[WebDavCloud] PROPFIND list:', WebDavHttp.sanitizeUrlForLog(url));
      xml = await WebDavHttp.propfind(url, auth, '1', cfg.transferTimeoutMs);
    } catch (e) {
      throw new Error(WebDavHttp.toUserMessage(e as Object));
    }
    const parseOpts: WebDavParseOptions = {
      includeDirectories: true,
      requestUrl: url,
    };
    const entries = WebDavHttp.parsePropfindResponse(xml, parseOpts);
    const page = createEmptyCloudListPage();
    const items: CloudFile[] = [];
    for (let i = 0; i < entries.length; i++) {
      const file = this.entryToCloudFile_(entries[i], source, path);
      if (file) {
        items.push(file);
      }
    }
    // 目录优先，再按名称
    items.sort((a: CloudFile, b: CloudFile): number => {
      if (a.isDirectory !== b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.localeCompare(b.name);
    });
    page.items = items;
    page.nextCursor = '';
    console.info('[WebDavCloud] list items=', items.length, 'path=', path);
    return page;
  }

  /**
   * 优先使用 RFC 5323 SEARCH；服务端未实现 DASL 时递归 PROPFIND，
   * 保证常见 WebDAV 服务也能按文件名搜索。
   */
  async search(
    source: CloudSource,
    credential: CloudCredential,
    keyword: string,
    _cursor?: string,
    remotePath?: string
  ): Promise<CloudListPage> {
    this.assertSource_(source, credential);
    const key = (keyword || '').trim();
    const path = CloudPath.normalizeRemotePath(remotePath || '');
    if (!key) {
      return await this.list(source, credential, path);
    }
    const url = this.ensureDirUrl_(this.fileUrl_(source, path));
    const auth = WebDavHttp.basicAuthHeader(credential.username, credential.secret);
    const cfg = this.readConfig_(source);
    try {
      console.info('[WebDavCloud] SEARCH:', WebDavHttp.sanitizeUrlForLog(url));
      const xml = await WebDavHttp.search(url, auth, key, cfg.transferTimeoutMs);
      const entries = WebDavHttp.parsePropfindResponse(xml, {
        includeDirectories: true,
        requestUrl: '',
      });
      const items: CloudFile[] = [];
      for (let i = 0; i < entries.length; i++) {
        const file = this.entryToCloudFile_(entries[i], source, path);
        if (file && (file.name || '').toLowerCase().indexOf(key.toLowerCase()) >= 0) {
          items.push(file);
        }
      }
      return this.searchPage_(items);
    } catch (e) {
      if (!this.shouldFallbackSearch_(e as Object)) {
        throw new Error(WebDavHttp.toUserMessage(e as Object));
      }
      console.info('[WebDavCloud] SEARCH unsupported, fallback to recursive PROPFIND:',
        WebDavHttp.toUserMessage(e as Object));
      return await this.recursiveSearch_(source, credential, path, key);
    }
  }

  async stat(
    source: CloudSource,
    credential: CloudCredential,
    remotePath: string
  ): Promise<CloudFile | null> {
    this.assertSource_(source, credential);
    const path = CloudPath.normalizeRemotePath(remotePath || '');
    const url = this.fileUrl_(source, path);
    const auth = WebDavHttp.basicAuthHeader(credential.username, credential.secret);
    const cfg = this.readConfig_(source);
    let xml = '';
    try {
      xml = await WebDavHttp.propfind(url, auth, '0', cfg.connectTimeoutMs);
    } catch (e) {
      const msg = (e as Error).message || '';
      if (msg.indexOf('404') >= 0) {
        return null;
      }
      throw new Error(WebDavHttp.toUserMessage(e as Object));
    }
    const parseOpts: WebDavParseOptions = {
      includeDirectories: true,
      requestUrl: '', // Depth 0 只有自身，不剔除
    };
    const entries = WebDavHttp.parsePropfindResponse(xml, parseOpts);
    // Depth 0 可能被 isSelf 过滤掉；关闭 requestUrl 后应有 1 条
    // 若仍空，手动从原始再取
    if (entries.length === 0) {
      // 使用 include 且 requestUrl 为空时，自身应保留
      return null;
    }
    // 找与 path 匹配的项，或第一条
    for (let i = 0; i < entries.length; i++) {
      const file = this.entryToCloudFile_(entries[i], source, CloudPath.parent(path));
      if (file) {
        // 强制 remotePath 为请求的 path
        file.remotePath = path;
        if (!file.name && path) {
          file.name = CloudPath.basename(path);
        }
        return file;
      }
    }
    return null;
  }

  async downloadToFile(
    source: CloudSource,
    credential: CloudCredential,
    remotePath: string,
    tempPath: string,
    onProgress?: (received: number, total: number) => void
  ): Promise<void> {
    this.assertSource_(source, credential);
    const path = CloudPath.normalizeRemotePath(remotePath);
    if (!path) {
      throw new Error('不能下载根目录');
    }
    const url = this.fileUrl_(source, path);
    const auth = WebDavHttp.basicAuthHeader(credential.username, credential.secret);
    const cfg = this.readConfig_(source);
    let session: rcp.Session | null = null;
    try {
      session = rcp.createSession({
        requestConfiguration: {
          transfer: { timeout: { connectMs: cfg.connectTimeoutMs, transferMs: cfg.transferTimeoutMs } },
        },
      });
      const headers: rcp.RequestHeaders = {
        'Authorization': auth['Authorization'] || '',
      };
      const request = new rcp.Request(url, 'GET' as rcp.HttpMethod, headers, '');
      const response = await session.fetch(request);
      if (response.statusCode < 200 || response.statusCode >= 400) {
        throw new Error('HTTP ' + response.statusCode);
      }
      if (response.body === undefined || response.body === null) {
        throw new Error('下载失败: 空响应');
      }
      const bodyBytes = new Uint8Array(response.body);
      try {
        fileFs.unlinkSync(tempPath);
      } catch (_e) { /* ok */ }
      // 确保父目录
      const slash = tempPath.lastIndexOf('/');
      if (slash > 0) {
        const dir = tempPath.substring(0, slash);
        try {
          if (!fileFs.accessSync(dir)) {
            fileFs.mkdirSync(dir, true);
          }
        } catch (_mk) { /* ignore */ }
      }
      let file: fileFs.File | null = null;
      try {
        file = fileFs.openSync(tempPath, fileFs.OpenMode.CREATE | fileFs.OpenMode.WRITE_ONLY);
        fileFs.writeSync(file.fd, bodyBytes.buffer);
      } finally {
        if (file) {
          try {
            fileFs.closeSync(file);
          } catch (_c) { /* ignore */ }
        }
      }
      if (onProgress) {
        onProgress(bodyBytes.length, bodyBytes.length);
      }
      console.info('[WebDavCloud] downloaded', bodyBytes.length, 'bytes',
        WebDavHttp.sanitizeUrlForLog(url));
    } catch (e) {
      throw new Error(WebDavHttp.toUserMessage(e as Object));
    } finally {
      if (session) {
        try {
          session.close();
        } catch (_e) { /* ignore */ }
      }
    }
  }

  async uploadFile(
    source: CloudSource,
    credential: CloudCredential,
    localPath: string,
    remotePath: string,
    onProgress?: (sent: number, total: number) => void
  ): Promise<CloudFile> {
    this.assertSource_(source, credential);
    const path = CloudPath.normalizeRemotePath(remotePath);
    if (!path) {
      throw new Error('上传路径不能为空');
    }
    const url = this.fileUrl_(source, path);
    const auth = WebDavHttp.basicAuthHeader(credential.username, credential.secret);
    const cfg = this.readConfig_(source);
    let file: fileFs.File | null = null;
    let session: rcp.Session | null = null;
    try {
      const stat = fileFs.statSync(localPath);
      const buf = new ArrayBuffer(stat.size);
      file = fileFs.openSync(localPath, fileFs.OpenMode.READ_ONLY);
      fileFs.readSync(file.fd, buf);
      const bytes = new Uint8Array(buf);

      session = rcp.createSession({
        requestConfiguration: {
          transfer: { timeout: { connectMs: cfg.connectTimeoutMs, transferMs: cfg.transferTimeoutMs } },
        },
      });
      const headers: rcp.RequestHeaders = {
        'Authorization': auth['Authorization'] || '',
        'Content-Type': 'application/octet-stream',
        'Overwrite': 'T',
      };
      const request = new rcp.Request(url, 'PUT' as rcp.HttpMethod, headers, bytes.buffer as ArrayBuffer);
      const response = await session.fetch(request);
      if (response.statusCode < 200 || response.statusCode >= 400) {
        throw new Error('HTTP ' + response.statusCode);
      }
      if (onProgress) {
        onProgress(bytes.length, bytes.length);
      }
    } catch (e) {
      throw new Error(WebDavHttp.toUserMessage(e as Object));
    } finally {
      if (file) {
        try {
          fileFs.closeSync(file);
        } catch (_e) { /* ignore */ }
      }
      if (session) {
        try {
          session.close();
        } catch (_e) { /* ignore */ }
      }
    }
    const st = await this.stat(source, credential, path);
    if (st) {
      return st;
    }
    const fallback = createEmptyCloudFile();
    fallback.remotePath = path;
    fallback.name = CloudPath.basename(path);
    fallback.isDirectory = false;
    return fallback;
  }

  async createDirectory(
    source: CloudSource,
    credential: CloudCredential,
    remotePath: string
  ): Promise<void> {
    this.assertSource_(source, credential);
    const path = CloudPath.normalizeRemotePath(remotePath);
    if (!path) {
      throw new Error('目录路径不能为空');
    }
    const url = this.fileUrl_(source, path);
    const auth = WebDavHttp.basicAuthHeader(credential.username, credential.secret);
    const cfg = this.readConfig_(source);
    try {
      await NetUtil.httpCustomMethod('MKCOL', url, '', auth, cfg.connectTimeoutMs);
    } catch (e) {
      const msg = (e as Error).message || '';
      // 405/409 常表示已存在
      if (msg.indexOf('405') >= 0 || msg.indexOf('409') >= 0 || msg.indexOf('301') >= 0) {
        return;
      }
      throw new Error(WebDavHttp.toUserMessage(e as Object));
    }
  }

  async delete(
    source: CloudSource,
    credential: CloudCredential,
    remotePath: string
  ): Promise<void> {
    this.assertSource_(source, credential);
    const path = CloudPath.normalizeRemotePath(remotePath);
    if (!path) {
      throw new Error('不能删除根目录');
    }
    const url = this.fileUrl_(source, path);
    const auth = WebDavHttp.basicAuthHeader(credential.username, credential.secret);
    const cfg = this.readConfig_(source);
    try {
      await NetUtil.httpCustomMethod('DELETE', url, '', auth, cfg.connectTimeoutMs);
    } catch (e) {
      throw new Error(WebDavHttp.toUserMessage(e as Object));
    }
  }

  // ---- private ----

  private assertSource_(source: CloudSource, credential: CloudCredential): void {
    if (!source || !source.endpoint) {
      throw new Error('未配置服务器地址');
    }
    if (!credential || !credential.username) {
      throw new Error('未配置用户名');
    }
  }

  private readConfig_(source: CloudSource): WebDavCloudConfig {
    const defaults = createDefaultWebDavCloudConfig();
    if (!source.configJson) {
      return defaults;
    }
    try {
      const obj = JSON.parse(source.configJson) as Record<string, number | string>;
      if (typeof obj['connectTimeoutMs'] === 'number' && (obj['connectTimeoutMs'] as number) > 0) {
        defaults.connectTimeoutMs = obj['connectTimeoutMs'] as number;
      }
      if (typeof obj['transferTimeoutMs'] === 'number' && (obj['transferTimeoutMs'] as number) > 0) {
        defaults.transferTimeoutMs = obj['transferTimeoutMs'] as number;
      }
      if (typeof obj['charset'] === 'string' && (obj['charset'] as string).length > 0) {
        defaults.charset = obj['charset'] as string;
      }
    } catch (_e) {
      // ignore bad json
    }
    return defaults;
  }

  private async recursiveSearch_(
    source: CloudSource,
    credential: CloudCredential,
    remotePath: string,
    keyword: string
  ): Promise<CloudListPage> {
    const key = keyword.toLowerCase();
    const queue: string[] = [remotePath];
    const visited = new Set<string>();
    const matches: CloudFile[] = [];
    let scanned = 0;
    const maxEntries = 5000;
    while (queue.length > 0 && scanned < maxEntries) {
      const dir = queue.shift();
      if (dir === undefined || visited.has(dir)) {
        continue;
      }
      visited.add(dir);
      let childPage: CloudListPage;
      try {
        childPage = await this.list(source, credential, dir);
      } catch (e) {
        if (dir === remotePath) {
          throw e;
        }
        console.warn('[WebDavCloud] skip unreadable search directory:', dir,
          WebDavHttp.toUserMessage(e as Object));
        continue;
      }
      for (let i = 0; i < childPage.items.length && scanned < maxEntries; i++) {
        const file = childPage.items[i];
        scanned++;
        if ((file.name || '').toLowerCase().indexOf(key) >= 0) {
          matches.push(file);
        }
        if (file.isDirectory && !visited.has(file.remotePath)) {
          queue.push(file.remotePath);
        }
      }
    }
    if (queue.length > 0) {
      console.warn('[WebDavCloud] recursive search truncated at', maxEntries, 'entries');
    }
    const page = this.searchPage_(matches);
    page.nextCursor = queue.length > 0 ? 'truncated' : '';
    return page;
  }

  private searchPage_(input: CloudFile[]): CloudListPage {
    const unique = new Map<string, CloudFile>();
    for (let i = 0; i < input.length; i++) {
      const file = input[i];
      if (file.remotePath && !unique.has(file.remotePath)) {
        unique.set(file.remotePath, file);
      }
    }
    const items = Array.from(unique.values());
    items.sort((a: CloudFile, b: CloudFile): number => {
      if (a.isDirectory !== b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.localeCompare(b.name);
    });
    const page = createEmptyCloudListPage();
    page.items = items;
    page.nextCursor = '';
    return page;
  }

  private shouldFallbackSearch_(error: Object): boolean {
    const message = error instanceof Error ? (error.message || '') : String(error);
    const lower = message.toLowerCase();
    if (message.indexOf('401') >= 0 || lower.indexOf('unauthorized') >= 0) {
      return false;
    }
    return message.indexOf('HTTP ') >= 0 || lower.indexOf('not implemented') >= 0 ||
      lower.indexOf('unsupported') >= 0 || lower.indexOf('search') >= 0 ||
      lower.indexOf('method') >= 0;
  }

  private rootUrl_(source: CloudSource): string {
    // 集合 URL 补尾斜杠，兼容 Nextcloud / 坚果云对目录 PROPFIND 的要求
    return this.ensureDirUrl_(WebDavHttp.joinUrl(
      source.endpoint,
      CloudPath.normalizeRootPath(source.rootPath || '')
    ));
  }

  private fileUrl_(source: CloudSource, remotePath: string): string {
    const combined = WebDavHttp.combineRelative(
      CloudPath.normalizeRootPath(source.rootPath || ''),
      CloudPath.normalizeRemotePath(remotePath || '')
    );
    return WebDavHttp.joinUrl(source.endpoint, combined);
  }

  /** 目录列举/检测用 URL 补全尾斜杠。 */
  private ensureDirUrl_(url: string): string {
    if (!url) {
      return url;
    }
    return url.endsWith('/') ? url : url + '/';
  }

  /**
   * 将 PROPFIND 条目转为 CloudFile。
   * parentRemotePath：当前 list 所在目录的 remotePath（用于相对 href 兜底）。
   */
  private entryToCloudFile_(
    entry: WebDavPropEntry,
    source: CloudSource,
    parentRemotePath: string
  ): CloudFile | null {
    let remote = WebDavHttp.hrefToRemotePath(entry.href, source.endpoint, source.rootPath);
    if (remote === null) {
      // 相对名兜底：拼到当前目录
      if (entry.name) {
        try {
          remote = parentRemotePath
            ? CloudPath.join(parentRemotePath, entry.name)
            : entry.name;
        } catch (_e) {
          return null;
        }
      } else {
        return null;
      }
    }
    // list 子目录时，跳过与 parent 完全相同的项
    const parent = CloudPath.normalizeRemotePath(parentRemotePath || '');
    if (remote === parent && parent !== '') {
      // 可能是自身
    }
    const file = createEmptyCloudFile();
    file.remotePath = remote;
    file.name = entry.name || CloudPath.basename(remote);
    file.isDirectory = entry.isDirectory;
    file.size = entry.contentLength;
    file.modifiedAt = WebDavHttp.parseLastModifiedMs(entry.lastModified);
    file.etag = entry.etag;
    file.contentType = entry.contentType;
    file.remoteId = entry.etag || '';
    return file;
  }
}
