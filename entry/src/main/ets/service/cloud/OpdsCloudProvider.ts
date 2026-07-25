/**
 * OPDS 只读在线书库 Provider。
 *
 * 将 navigation/subsection 映射为目录，将 acquisition 映射为可下载文件，
 * 从而复用现有云端书库的浏览、下载、导入和 Binding 流程。
 */
import fileFs from '@ohos.file.fs';
import {
  CLOUD_PROVIDER_OPDS,
  CloudCredential,
  CloudSource,
  isProjectGutenbergSource,
  parseOpdsCloudConfig,
} from '../../model/CloudSource';
import { NetUtil } from '../../util/NetUtil';
import { CloudPath } from './CloudPath';
import {
  CloudFile,
  CloudListPage,
  CloudProviderCapabilities,
  CloudStorageProvider,
  createEmptyCloudFile,
  createEmptyCloudListPage,
} from './CloudStorageProvider';
import { OpdsAcquisitionEntry, OpdsCatalogPage, OpdsParser } from './OpdsParser';
import { WebDavHttp } from './WebDavHttp';

const OPDS_FEED_SEGMENT = 'feed';
const OPDS_BOOK_SEGMENT = 'book';
const OPDS_ANONYMOUS = 'anonymous';
const GUTENDEX_BOOKS_ENDPOINT = 'https://gutendex.com/books/';

/** 将 Gutenberg 容易被 403 的搜索/分类 feed 映射到备用元数据 API。 */
export function mapGutenbergFeedToGutendex(requestUrl: string): string {
  const url = (requestUrl || '').trim();
  if (!new RegExp('^https?://(?:www\\.)?gutenberg\\.org/ebooks/search\\.opds(?:[/?#]|$)', 'i').test(url)) {
    return '';
  }
  const sortOrder = queryValue_(url, 'sort_order').toLowerCase();
  if (sortOrder === 'downloads') {
    return GUTENDEX_BOOKS_ENDPOINT + '?sort=popular';
  }
  if (sortOrder === 'release_date') {
    return GUTENDEX_BOOKS_ENDPOINT + '?sort=descending';
  }
  if (sortOrder === 'random') {
    // Gutendex 没有 random 排序；每天选择一个不同的升序分页作为近似随机目录。
    const page = (Math.floor(Date.now() / 86400000) % 2000) + 1;
    return GUTENDEX_BOOKS_ENDPOINT + '?sort=ascending&page=' + page.toString();
  }
  const query = queryValue_(url, 'query');
  if (query) {
    return GUTENDEX_BOOKS_ENDPOINT + '?search=' + encodeURIComponent(query);
  }
  return GUTENDEX_BOOKS_ENDPOINT + '?sort=popular';
}

function queryValue_(url: string, name: string): string {
  const match = url.match(new RegExp('[?&]' + name + '=([^&#]*)', 'i'));
  if (!match) {
    return '';
  }
  try {
    return decodeURIComponent((match[1] || '').replace(new RegExp('\\+', 'g'), ' '));
  } catch (_e) {
    return match[1] || '';
  }
}

export class OpdsCloudProvider implements CloudStorageProvider {
  readonly type: string = CLOUD_PROVIDER_OPDS;

  getCapabilities(): CloudProviderCapabilities {
    return {
      canCreateDirectory: false,
      canDelete: false,
      canMove: false,
      supportsEtag: false,
      supportsRangeDownload: false,
    };
  }

  async testConnection(source: CloudSource, credential: CloudCredential): Promise<void> {
    this.assertSource_(source);
    const payload = await this.requestCatalog_(source, credential, source.endpoint);
    OpdsParser.parse(payload, source.endpoint);
  }

  async list(
    source: CloudSource,
    credential: CloudCredential,
    remotePath: string,
    _cursor?: string
  ): Promise<CloudListPage> {
    this.assertSource_(source);
    const path = CloudPath.normalizeRemotePath(remotePath || '');
    const requestUrl = path ? this.feedUrlFromPath_(path) : source.endpoint;
    let payload = '';
    try {
      payload = await this.requestCatalog_(source, credential, requestUrl);
    } catch (e) {
      throw new Error(this.toUserMessage_(e));
    }

    let catalog: OpdsCatalogPage;
    try {
      catalog = OpdsParser.parse(payload, requestUrl);
    } catch (e) {
      throw new Error('OPDS 目录解析失败：' + ((e as Error).message || String(e)));
    }
    return this.catalogToPage_(catalog, path);
  }

  async search(
    source: CloudSource,
    credential: CloudCredential,
    keyword: string,
    _cursor?: string
  ): Promise<CloudListPage> {
    this.assertSource_(source);
    const key = (keyword || '').trim();
    if (!key) {
      return await this.list(source, credential, '');
    }
    let requestUrl = '';
    if (isProjectGutenbergSource(source)) {
      requestUrl = GUTENDEX_BOOKS_ENDPOINT + '?search=' + encodeURIComponent(key);
    } else {
      requestUrl = await this.searchUrl_(source, credential, key);
    }
    let payload = '';
    try {
      payload = await this.requestCatalog_(source, credential, requestUrl);
      const catalog = OpdsParser.parse(payload, requestUrl);
      return this.catalogToPage_(catalog, '');
    } catch (e) {
      throw new Error(this.toUserMessage_(e));
    }
  }

  private catalogToPage_(catalog: OpdsCatalogPage, path: string): CloudListPage {
    const page = createEmptyCloudListPage();
    const items: CloudFile[] = [];
    for (let i = 0; i < catalog.navigation.length; i++) {
      const nav = catalog.navigation[i];
      if (!this.isHttpUrl_(nav.url)) {
        continue;
      }
      const parent = nav.isNextPage ? CloudPath.parent(path) : path;
      const label = nav.isNextPage
        ? ((catalog.title || '目录') + ' · ' + (nav.title || '下一页'))
        : nav.title;
      const file = createEmptyCloudFile();
      file.name = nav.isNextPage ? '下一页 ›' : nav.title;
      file.isDirectory = true;
      file.remotePath = CloudPath.join(parent, this.feedSegment_(nav.url, label));
      file.contentType = 'application/atom+xml;profile=opds-catalog';
      file.remoteId = nav.url;
      items.push(file);
    }
    for (let i = 0; i < catalog.acquisitions.length; i++) {
      const acquisition = catalog.acquisitions[i];
      if (!this.isHttpUrl_(acquisition.url)) {
        continue;
      }
      const file = this.acquisitionToFile_(path, acquisition);
      // 只展示当前导入引擎实际支持的格式；图片/HTML 链接不会伪装成书籍。
      if (OpdsParser.extensionFor(file.contentType, acquisition.url)) {
        items.push(file);
      }
    }
    page.items = items;
    page.nextCursor = '';
    page.pathLabels = this.pathLabels_(path);
    return page;
  }

  async stat(
    _source: CloudSource,
    _credential: CloudCredential,
    remotePath: string
  ): Promise<CloudFile | null> {
    const path = CloudPath.normalizeRemotePath(remotePath || '');
    if (!path) {
      return null;
    }
    const decoded = this.decodeBookSegment_(CloudPath.basename(path));
    if (!decoded) {
      return null;
    }
    const file = createEmptyCloudFile();
    file.remotePath = path;
    file.name = decoded.name;
    file.isDirectory = false;
    file.size = decoded.size;
    file.modifiedAt = decoded.updatedAt;
    file.contentType = decoded.contentType;
    file.remoteId = decoded.remoteId || decoded.url;
    return file;
  }

  async downloadToFile(
    source: CloudSource,
    credential: CloudCredential,
    remotePath: string,
    tempPath: string,
    onProgress?: (received: number, total: number) => void
  ): Promise<void> {
    const path = CloudPath.normalizeRemotePath(remotePath);
    const decoded = this.decodeBookSegment_(CloudPath.basename(path));
    if (!decoded || !this.isHttpUrl_(decoded.url)) {
      throw new Error('OPDS 下载地址无效');
    }
    const cfg = parseOpdsCloudConfig(source.configJson);
    let body: ArrayBuffer;
    try {
      body = await NetUtil.httpGetBinary(
        decoded.url,
        this.downloadHeaders_(source, credential, decoded.url),
        cfg.transferTimeoutMs
      );
    } catch (e) {
      throw new Error(this.toUserMessage_(e));
    }
    const bytes = new Uint8Array(body);
    if (bytes.length === 0) {
      throw new Error('OPDS 下载返回空文件');
    }
    let file: fileFs.File | null = null;
    try {
      try {
        fileFs.unlinkSync(tempPath);
      } catch (_e) { /* 文件不存在 */ }
      file = fileFs.openSync(tempPath, fileFs.OpenMode.CREATE | fileFs.OpenMode.WRITE_ONLY);
      fileFs.writeSync(file.fd, body);
    } finally {
      if (file) {
        try {
          fileFs.closeSync(file);
        } catch (_e) { /* ignore */ }
      }
    }
    if (onProgress) {
      onProgress(bytes.length, decoded.size > 0 ? decoded.size : bytes.length);
    }
  }

  async uploadFile(
    _source: CloudSource,
    _credential: CloudCredential,
    _localPath: string,
    _remotePath: string,
    _onProgress?: (sent: number, total: number) => void
  ): Promise<CloudFile> {
    throw new Error('OPDS 是只读书库，不支持上传');
  }

  private acquisitionToFile_(parentPath: string, entry: OpdsAcquisitionEntry): CloudFile {
    const file = createEmptyCloudFile();
    file.name = OpdsParser.fileName(entry);
    file.isDirectory = false;
    file.size = entry.size;
    file.modifiedAt = entry.updatedAt;
    file.contentType = entry.contentType;
    file.remoteId = entry.remoteId || entry.url;
    file.remotePath = CloudPath.join(parentPath, this.bookSegment_(entry, file.name));
    return file;
  }

  private async requestCatalog_(
    source: CloudSource,
    credential: CloudCredential,
    requestUrl: string
  ): Promise<string> {
    const headers = this.catalogHeaders_(source, credential, requestUrl);
    const timeout = parseOpdsCloudConfig(source.configJson).connectTimeoutMs;
    try {
      return await NetUtil.httpGet(requestUrl, headers, timeout);
    } catch (e) {
      let lastError: Object = e as Object;
      let message = (e as Error).message || String(e);
      const network = NetUtil.getNetworkConfig();
      const lowerMessage = message.toLowerCase();
      const shouldRetrySystem = message.indexOf('HTTP 403') >= 0 ||
        lowerMessage.indexOf('timeout') >= 0 || lowerMessage.indexOf('timed out') >= 0;
      if (shouldRetrySystem && !network.proxyHost) {
        console.warn('[OpdsCloudProvider] RCP request failed, retrying with system HTTP:', requestUrl);
        try {
          return await NetUtil.httpGetSystem(requestUrl, headers, timeout);
        } catch (systemError) {
          lastError = systemError as Object;
          message = (systemError as Error).message || String(systemError);
        }
      }
      if (message.indexOf('HTTP 403') >= 0 && isProjectGutenbergSource(source)) {
        if (this.sameCatalogUrl_(source.endpoint, requestUrl)) {
          console.warn('[OpdsCloudProvider] Gutenberg OPDS blocked, using fallback navigation');
          return this.gutenbergFallbackCatalog_();
        }
        const fallbackUrl = mapGutenbergFeedToGutendex(requestUrl);
        if (fallbackUrl) {
          console.warn('[OpdsCloudProvider] Gutenberg category blocked, using Gutendex:', fallbackUrl);
          return await this.requestCatalog_(source, credential, fallbackUrl);
        }
      }
      throw lastError;
    }
  }

  private async searchUrl_(
    source: CloudSource,
    credential: CloudCredential,
    keyword: string
  ): Promise<string> {
    const rootPayload = await this.requestCatalog_(source, credential, source.endpoint);
    const root = OpdsParser.parse(rootPayload, source.endpoint);
    if (!root.searchUrl) {
      throw new Error('该 OPDS 书库未声明远程搜索能力');
    }
    let template = root.searchUrl;
    const type = (root.searchType || '').toLowerCase();
    if (type.indexOf('opensearchdescription') >= 0) {
      const descriptor = await this.requestCatalog_(source, credential, root.searchUrl);
      template = OpdsParser.parseOpenSearchTemplate(descriptor, root.searchUrl);
    }
    if (template.indexOf('{searchTerms}') < 0) {
      throw new Error('OPDS 搜索链接缺少 {searchTerms} 模板');
    }
    let requestUrl = template.split('{searchTerms}').join(encodeURIComponent(keyword));
    // OpenSearch 可选参数未赋值时应从模板中移除。
    requestUrl = requestUrl.replace(new RegExp('\\{[^}]+\\?\\}', 'g'), '');
    // Gutenberg 的旧描述仍可能返回 http://m.gutenberg.org，主动升级 HTTPS。
    requestUrl = requestUrl.replace(new RegExp('^http://m\\.gutenberg\\.org/', 'i'),
      'https://www.gutenberg.org/');
    if (!this.isHttpUrl_(requestUrl)) {
      throw new Error('OPDS 搜索地址无效');
    }
    return requestUrl;
  }

  private gutenbergFallbackCatalog_(): string {
    return JSON.stringify({
      metadata: { title: 'Project Gutenberg（备用目录）' },
      navigation: [
        { title: '热门书籍', href: GUTENDEX_BOOKS_ENDPOINT + '?sort=popular',
          type: 'application/opds+json' },
        { title: '最新收录', href: GUTENDEX_BOOKS_ENDPOINT + '?sort=descending',
          type: 'application/opds+json' },
        { title: '英语书籍', href: GUTENDEX_BOOKS_ENDPOINT + '?languages=en',
          type: 'application/opds+json' },
        { title: '法语书籍', href: GUTENDEX_BOOKS_ENDPOINT + '?languages=fr',
          type: 'application/opds+json' },
        { title: '德语书籍', href: GUTENDEX_BOOKS_ENDPOINT + '?languages=de',
          type: 'application/opds+json' },
        { title: '西班牙语书籍', href: GUTENDEX_BOOKS_ENDPOINT + '?languages=es',
          type: 'application/opds+json' },
        { title: '中文书籍', href: GUTENDEX_BOOKS_ENDPOINT + '?languages=zh',
          type: 'application/opds+json' },
        { title: '小说', href: GUTENDEX_BOOKS_ENDPOINT + '?topic=fiction',
          type: 'application/opds+json' },
        { title: '儿童文学', href: GUTENDEX_BOOKS_ENDPOINT + '?topic=children',
          type: 'application/opds+json' },
        { title: '历史', href: GUTENDEX_BOOKS_ENDPOINT + '?topic=history',
          type: 'application/opds+json' },
      ],
      links: [{
        rel: 'search',
        href: GUTENDEX_BOOKS_ENDPOINT + '?search={searchTerms}',
        type: 'application/opds+json',
      }],
    });
  }

  private sameCatalogUrl_(first: string, second: string): boolean {
    return (first || '').trim().replace(new RegExp('/+$'), '') ===
      (second || '').trim().replace(new RegExp('/+$'), '');
  }

  private catalogHeaders_(
    source: CloudSource,
    credential: CloudCredential,
    requestUrl: string
  ): Record<string, string> {
    const headers = this.commonHeaders_(source, credential, requestUrl);
    headers['Accept'] =
      'application/atom+xml;profile=opds-catalog, application/opds+json, application/json;q=0.9, application/xml;q=0.8';
    return headers;
  }

  private downloadHeaders_(
    source: CloudSource,
    credential: CloudCredential,
    requestUrl: string
  ): Record<string, string> {
    const headers = this.commonHeaders_(source, credential, requestUrl);
    headers['Accept'] = 'application/epub+zip, application/pdf, text/plain, application/octet-stream;q=0.8';
    return headers;
  }

  private commonHeaders_(
    source: CloudSource,
    credential: CloudCredential,
    requestUrl: string
  ): Record<string, string> {
    const cfg = parseOpdsCloudConfig(source.configJson);
    const headers: Record<string, string> = {
      'User-Agent': cfg.userAgent,
      'Accept-Encoding': 'identity',
    };
    const username = credential ? (credential.username || '').trim() : '';
    const secret = credential ? (credential.secret || '') : '';
    if (username && secret && !(username === OPDS_ANONYMOUS && secret === OPDS_ANONYMOUS) &&
      this.sameOrigin_(source.endpoint, requestUrl)) {
      const auth = WebDavHttp.basicAuthHeader(username, secret);
      headers['Authorization'] = auth['Authorization'];
    }
    return headers;
  }

  private feedSegment_(url: string, title: string): string {
    return OPDS_FEED_SEGMENT + '|' + this.encode_(url) + '|' + this.encode_(title || '目录');
  }

  private bookSegment_(entry: OpdsAcquisitionEntry, name: string): string {
    return OPDS_BOOK_SEGMENT + '|' +
      this.encode_(entry.url) + '|' +
      this.encode_(name) + '|' +
      this.encode_(entry.contentType) + '|' +
      entry.size.toString() + '|' +
      entry.updatedAt.toString() + '|' +
      this.encode_(entry.remoteId || entry.url);
  }

  private feedUrlFromPath_(remotePath: string): string {
    const segment = CloudPath.basename(remotePath);
    const parts = segment.split('|');
    if (parts.length < 2 || parts[0] !== OPDS_FEED_SEGMENT) {
      throw new Error('OPDS 目录路径无效');
    }
    const url = this.decode_(parts[1]);
    if (!this.isHttpUrl_(url)) {
      throw new Error('OPDS 目录地址无效');
    }
    return url;
  }

  private decodeBookSegment_(segment: string): OpdsBookPath | null {
    const parts = (segment || '').split('|');
    if (parts.length < 7 || parts[0] !== OPDS_BOOK_SEGMENT) {
      return null;
    }
    const row: OpdsBookPath = {
      url: this.decode_(parts[1]),
      name: this.decode_(parts[2]),
      contentType: this.decode_(parts[3]),
      size: parseInt(parts[4], 10) || 0,
      updatedAt: parseInt(parts[5], 10) || 0,
      remoteId: this.decode_(parts[6]),
    };
    return row;
  }

  private pathLabels_(remotePath: string): string[] {
    if (!remotePath) {
      return [];
    }
    const parts = remotePath.split('/');
    const labels: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const segment = parts[i].split('|');
      if (segment.length >= 3 && segment[0] === OPDS_FEED_SEGMENT) {
        labels.push(this.decode_(segment[2]) || '目录');
      } else {
        labels.push(parts[i]);
      }
    }
    return labels;
  }

  private encode_(value: string): string {
    return encodeURIComponent(value || '');
  }

  private decode_(value: string): string {
    try {
      return decodeURIComponent(value || '');
    } catch (_e) {
      return '';
    }
  }

  private sameOrigin_(first: string, second: string): boolean {
    const a = (first || '').match(new RegExp('^https?://([^/?#]+)', 'i'));
    const b = (second || '').match(new RegExp('^https?://([^/?#]+)', 'i'));
    return !!(a && b && a[1].toLowerCase() === b[1].toLowerCase());
  }

  private isHttpUrl_(url: string): boolean {
    return new RegExp('^https?://', 'i').test((url || '').trim());
  }

  private assertSource_(source: CloudSource): void {
    if (!source || !this.isHttpUrl_(source.endpoint)) {
      throw new Error('OPDS 地址必须是 HTTP(S) URL');
    }
  }

  private toUserMessage_(error: Object): string {
    const message = error instanceof Error ? (error.message || '') : String(error);
    if (message.indexOf('401') >= 0) {
      return 'OPDS 认证失败（401）：请检查账号和密码';
    }
    if (message.indexOf('403') >= 0) {
      return 'OPDS 服务拒绝访问（403）';
    }
    if (message.indexOf('404') >= 0) {
      return 'OPDS 目录不存在（404）：请检查地址';
    }
    if (message.toLowerCase().indexOf('timeout') >= 0) {
      return 'OPDS 连接超时';
    }
    return message ? message.substring(0, 200) : 'OPDS 请求失败';
  }
}

interface OpdsBookPath {
  url: string;
  name: string;
  contentType: string;
  size: number;
  updatedAt: number;
  remoteId: string;
}
