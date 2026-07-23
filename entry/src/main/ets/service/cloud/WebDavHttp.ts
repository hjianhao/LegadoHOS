/**
 * WebDAV 共享协议工具
 *
 * 供备份 WebDavService 与云端书库 WebDavCloudProvider 复用。
 * 不含备份业务语义（如过滤目录、backup* 文件名）。
 */
import util from '@ohos.util';
import { NetUtil } from '../../util/NetUtil';

export interface WebDavPropEntry {
  /** 服务端 href（已尽量转为 path 形态，可能仍含百分号编码） */
  href: string;
  name: string;
  isDirectory: boolean;
  contentLength: number;
  lastModified: string;
  etag: string;
  contentType: string;
}

export interface WebDavParseOptions {
  /** 是否保留目录项；备份列表为 false，云端浏览为 true */
  includeDirectories: boolean;
  /**
   * 本次 PROPFIND 请求的完整 URL。
   * 用于剔除 Depth:1 返回的“目录自身”条目。
   */
  requestUrl: string;
}

export class WebDavHttp {
  private static encoder_: util.TextEncoder = new util.TextEncoder();

  static propfindAllPropBody(): string {
    return '<?xml version="1.0" encoding="utf-8"?>\n' +
      '<D:propfind xmlns:D="DAV:">\n' +
      '  <D:allprop/>\n' +
      '</D:propfind>';
  }

  static basicAuthHeader(username: string, secret: string): Record<string, string> {
    const credentials = (username || '') + ':' + (secret || '');
    const encoded = WebDavHttp.base64Encode(credentials);
    const headers: Record<string, string> = {};
    headers['Authorization'] = 'Basic ' + encoded;
    return headers;
  }

  static base64Encode(str: string): string {
    const bytes = WebDavHttp.encoder_.encodeInto(str);
    const b64 = new util.Base64Helper();
    return b64.encodeToStringSync(bytes);
  }

  /**
   * 拼接 endpoint 与若干相对路径段。
   * 各段内部可含 `/`；会对每一路径段做 encodeURIComponent（保留已编码的 %）。
   */
  static joinUrl(endpoint: string, relativePath: string): string {
    let base = (endpoint || '').trim().replace(new RegExp('/+$'), '');
    const rel = (relativePath || '').replace(new RegExp('^/+'), '').replace(new RegExp('/+$'), '');
    if (!rel) {
      return base;
    }
    const encoded = WebDavHttp.encodePath(rel);
    return base + '/' + encoded;
  }

  /** 将 rootPath + remotePath 拼成相对路径（未编码）。 */
  static combineRelative(rootPath: string, remotePath: string): string {
    const root = (rootPath || '').replace(new RegExp('^/+|/+$', 'g'), '');
    const remote = (remotePath || '').replace(new RegExp('^/+|/+$', 'g'), '');
    if (root && remote) {
      return root + '/' + remote;
    }
    return root || remote || '';
  }

  /** 按段编码相对路径，避免中文/空格导致 RCP 失败。 */
  static encodePath(relativePath: string): string {
    const rel = (relativePath || '').replace(new RegExp('^/+'), '').replace(new RegExp('/+$'), '');
    if (!rel) {
      return '';
    }
    const parts = rel.split('/');
    const out: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const p = parts[i];
      if (!p) {
        continue;
      }
      out.push(WebDavHttp.encodeSegment_(p));
    }
    return out.join('/');
  }

  /**
   * 解析 PROPFIND XML。
   * includeDirectories=false 时行为对齐旧版备份列表（去掉目录）。
   */
  static parsePropfindResponse(xml: string, options: WebDavParseOptions): WebDavPropEntry[] {
    const files: WebDavPropEntry[] = [];
    if (!xml) {
      return files;
    }
    const includeDirs = options.includeDirectories;
    const requestPath = WebDavHttp.normalizeHrefPath_(options.requestUrl || '');

    const responseRegex = new RegExp(
      '<(?:[a-zA-Z]+:)?response[^>]*>([\\s\\S]*?)<\\/(?:[a-zA-Z]+:)?response>',
      'gi'
    );
    let match: RegExpExecArray | null = responseRegex.exec(xml);
    while (match !== null) {
      const block = match[1];
      const hrefMatch = block.match(
        new RegExp('<(?:[a-zA-Z]+:)?href[^>]*>([\\s\\S]*?)<\\/(?:[a-zA-Z]+:)?href>', 'i')
      );
      if (!hrefMatch) {
        match = responseRegex.exec(xml);
        continue;
      }
      let href = hrefMatch[1].trim();
      // 解码 XML 实体
      href = href.replace(new RegExp('&amp;', 'g'), '&')
        .replace(new RegExp('&lt;', 'g'), '<')
        .replace(new RegExp('&gt;', 'g'), '>')
        .replace(new RegExp('&quot;', 'g'), '"');
      href = WebDavHttp.normalizeHrefPath_(href);

      const isDir = new RegExp('<(?:[a-zA-Z]+:)?collection\\s*\\/>', 'i').test(block) ||
        new RegExp(
          '<(?:[a-zA-Z]+:)?resourcetype[^>]*>[\\s\\S]*?<(?:[a-zA-Z]+:)?collection[\\s\\S]*?<\\/(?:[a-zA-Z]+:)?resourcetype>',
          'i'
        ).test(block) ||
        href.endsWith('/');

      const modMatch = block.match(
        new RegExp(
          '<(?:[a-zA-Z]+:)?getlastmodified[^>]*>([\\s\\S]*?)<\\/(?:[a-zA-Z]+:)?getlastmodified>',
          'i'
        )
      );
      const sizeMatch = block.match(
        new RegExp(
          '<(?:[a-zA-Z]+:)?getcontentlength[^>]*>([\\s\\S]*?)<\\/(?:[a-zA-Z]+:)?getcontentlength>',
          'i'
        )
      );
      const etagMatch = block.match(
        new RegExp('<(?:[a-zA-Z]+:)?getetag[^>]*>([\\s\\S]*?)<\\/(?:[a-zA-Z]+:)?getetag>', 'i')
      );
      const typeMatch = block.match(
        new RegExp(
          '<(?:[a-zA-Z]+:)?getcontenttype[^>]*>([\\s\\S]*?)<\\/(?:[a-zA-Z]+:)?getcontenttype>',
          'i'
        )
      );

      const pathNoSlash = href.replace(new RegExp('/+$'), '');
      const segs = pathNoSlash.split('/').filter((s: string) => s.length > 0);
      let rawName = segs.length > 0 ? segs[segs.length - 1] : '';
      let name = rawName;
      try {
        name = decodeURIComponent(rawName);
      } catch (_e) {
        name = rawName;
      }

      const entry: WebDavPropEntry = {
        href: href,
        name: name,
        isDirectory: isDir,
        contentLength: sizeMatch ? (parseInt(sizeMatch[1].trim(), 10) || 0) : 0,
        lastModified: modMatch ? modMatch[1].trim() : '',
        etag: etagMatch ? WebDavHttp.cleanEtag_(etagMatch[1].trim()) : '',
        contentType: typeMatch ? typeMatch[1].trim() : '',
      };

      // 跳过空名
      if (!entry.name) {
        match = responseRegex.exec(xml);
        continue;
      }
      // 跳过请求目标自身（目录自身）
      if (WebDavHttp.isSelfEntry_(entry.href, requestPath)) {
        match = responseRegex.exec(xml);
        continue;
      }
      if (!includeDirs && entry.isDirectory) {
        match = responseRegex.exec(xml);
        continue;
      }
      files.push(entry);
      match = responseRegex.exec(xml);
    }
    return files;
  }

  /**
   * 将服务端 href 收敛为相对 rootPath 的 remotePath。
   * 若 href 越界（不在 endpoint+rootPath 下）返回 null。
   */
  static hrefToRemotePath(href: string, endpoint: string, rootPath: string): string | null {
    const hrefPath = WebDavHttp.normalizeHrefPath_(href);
    if (!hrefPath) {
      return null;
    }
    // 期望前缀：endpoint path + rootPath
    let prefix = WebDavHttp.endpointPathPrefix_(endpoint);
    const root = (rootPath || '').replace(new RegExp('^/+|/+$', 'g'), '');
    if (root) {
      prefix = (prefix.endsWith('/') ? prefix : prefix + '/') + root;
    }
    prefix = prefix.replace(new RegExp('/+$'), '');
    const prefixSlash = prefix ? prefix + '/' : '/';

    let decodedHref = hrefPath;
    try {
      decodedHref = decodeURIComponent(hrefPath);
    } catch (_e) {
      decodedHref = hrefPath;
    }
    let decodedPrefix = prefix;
    try {
      decodedPrefix = decodeURIComponent(prefix);
    } catch (_e2) {
      decodedPrefix = prefix;
    }
    const decodedPrefixSlash = decodedPrefix ? decodedPrefix + '/' : '/';

    // 精确等于根 → remotePath ''
    const hrefTrim = decodedHref.replace(new RegExp('/+$'), '');
    const prefixTrim = decodedPrefix.replace(new RegExp('/+$'), '');
    if (hrefTrim === prefixTrim || hrefTrim === '') {
      return '';
    }

    if (decodedHref.startsWith(decodedPrefixSlash)) {
      let rel = decodedHref.substring(decodedPrefixSlash.length);
      rel = rel.replace(new RegExp('^/+|/+$', 'g'), '');
      // 安全：拒绝 ..
      if (rel.indexOf('..') >= 0) {
        return null;
      }
      return rel;
    }

    // 部分服务返回相对 href（仅文件名或子路径）
    if (!decodedHref.startsWith('/') && decodedHref.indexOf('://') < 0) {
      const rel = decodedHref.replace(new RegExp('^/+|/+$', 'g'), '');
      if (rel.indexOf('..') >= 0) {
        return null;
      }
      return rel;
    }

    // 兼容：href 未含 endpoint 前缀但以 root 开头
    if (root && (decodedHref === '/' + root || decodedHref.startsWith('/' + root + '/'))) {
      let rel = decodedHref.substring(('/' + root).length);
      rel = rel.replace(new RegExp('^/+|/+$', 'g'), '');
      if (rel.indexOf('..') >= 0) {
        return null;
      }
      return rel;
    }

    console.warn('[WebDavHttp] href out of root boundary, skip:', hrefPath.substring(0, 120));
    return null;
  }

  static parseLastModifiedMs(value: string): number {
    if (!value) {
      return 0;
    }
    const trimmed = value.trim();
    if (!trimmed) {
      return 0;
    }
    if (new RegExp('^\\d+$').test(trimmed)) {
      const n = Number(trimmed);
      if (!Number.isFinite(n) || n <= 0) {
        return 0;
      }
      return n < 1e12 ? n * 1000 : n;
    }
    const ms = Date.parse(trimmed);
    return Number.isFinite(ms) ? ms : 0;
  }

  /** 将底层错误转为用户可读中文（脱敏，不含密码）。 */
  static toUserMessage(err: Object): string {
    let msg = err instanceof Error ? (err.message || '') : String(err);
    msg = WebDavHttp.redactSecrets_(msg);
    const lower = msg.toLowerCase();
    if (msg.indexOf('401') >= 0 || lower.indexOf('unauthorized') >= 0) {
      return '认证失败（401）：请检查用户名或密码';
    }
    if (msg.indexOf('403') >= 0 || lower.indexOf('forbidden') >= 0) {
      return '无权限访问（403）：请检查账号权限或根目录';
    }
    if (msg.indexOf('404') >= 0 || lower.indexOf('not found') >= 0) {
      return '路径不存在（404）：请检查服务器地址或根目录';
    }
    if (lower.indexOf('timeout') >= 0 || lower.indexOf('timed out') >= 0) {
      return '连接超时：请检查网络或服务器地址';
    }
    if (lower.indexOf('network') >= 0 || lower.indexOf('dns') >= 0 ||
      lower.indexOf('unreachable') >= 0 || lower.indexOf('connection') >= 0) {
      return '网络错误：' + msg.substring(0, 120);
    }
    if (msg.indexOf('HTTP ') >= 0) {
      return '服务器错误：' + msg.substring(0, 160);
    }
    return msg ? msg.substring(0, 200) : '未知错误';
  }

  /** 日志用：去掉 URL 中的 user:pass@ 与 query 中的敏感参数。 */
  static sanitizeUrlForLog(url: string): string {
    if (!url) {
      return '';
    }
    let u = url;
    // https://user:pass@host → https://***@host
    u = u.replace(new RegExp('://([^/@\\s]+):([^/@\\s]+)@', 'g'), '://***:***@');
    // Authorization 头若混入字符串
    u = WebDavHttp.redactSecrets_(u);
    if (u.length > 160) {
      return u.substring(0, 160) + '…';
    }
    return u;
  }

  /**
   * 跨主机重定向时不应携带 Authorization。
   * RCP 自动跟随重定向时无法拦截；调用方在自定义跟随时使用本方法。
   */
  static shouldStripAuthOnRedirect(originalUrl: string, locationUrl: string): boolean {
    const a = WebDavHttp.extractHost_(originalUrl);
    const b = WebDavHttp.extractHost_(locationUrl);
    if (!a || !b) {
      return true;
    }
    return a.toLowerCase() !== b.toLowerCase();
  }

  private static extractHost_(url: string): string {
    const m = (url || '').match(new RegExp('^https?://([^/?#]+)', 'i'));
    return m ? m[1] : '';
  }

  private static redactSecrets_(text: string): string {
    let t = text || '';
    t = t.replace(new RegExp('Basic\\s+[A-Za-z0-9+/=]+', 'gi'), 'Basic ***');
    t = t.replace(new RegExp('(password|passwd|secret|token|authorization)\\s*[:=]\\s*[^\\s,;]+', 'gi'),
      '$1=***');
    return t;
  }

  /**
   * 发送 PROPFIND 并返回原始 XML。
   */
  static async propfind(
    url: string,
    auth: Record<string, string>,
    depth: string,
    timeoutMs: number
  ): Promise<string> {
    const headers: Record<string, string> = {};
    const authKeys = Object.keys(auth);
    for (let i = 0; i < authKeys.length; i++) {
      headers[authKeys[i]] = auth[authKeys[i]];
    }
    headers['Depth'] = depth;
    headers['Content-Type'] = 'application/xml; charset=utf-8';
    const body = WebDavHttp.propfindAllPropBody();
    return await NetUtil.httpCustomMethod('PROPFIND', url, body, headers, timeoutMs);
  }

  private static encodeSegment_(seg: string): string {
    // 已百分号编码的片段不重复编码
    try {
      if (seg.indexOf('%') >= 0) {
        const decoded = decodeURIComponent(seg);
        return encodeURIComponent(decoded);
      }
    } catch (_e) {
      // fall through
    }
    return encodeURIComponent(seg);
  }

  private static normalizeHrefPath_(href: string): string {
    let h = (href || '').trim();
    if (!h) {
      return '';
    }
    if (h.startsWith('http://') || h.startsWith('https://')) {
      const m = h.match(new RegExp('^https?:\\/\\/[^\\/]+(\\/.*)$'));
      if (m) {
        h = m[1];
      } else {
        // 仅 host 无 path
        h = '/';
      }
    }
    // 合并重复斜杠（保留开头）
    h = h.replace(new RegExp('([^:])\\/+', 'g'), '$1/');
    return h;
  }

  private static endpointPathPrefix_(endpoint: string): string {
    const e = (endpoint || '').trim();
    if (!e) {
      return '';
    }
    if (e.startsWith('http://') || e.startsWith('https://')) {
      const m = e.match(new RegExp('^https?:\\/\\/[^\\/]+(\\/.*)?$'));
      if (m && m[1]) {
        return m[1].replace(new RegExp('/+$'), '') || '';
      }
      return '';
    }
    return e.replace(new RegExp('/+$'), '');
  }

  private static isSelfEntry_(href: string, requestPath: string): boolean {
    if (!requestPath) {
      return false;
    }
    const a = href.replace(new RegExp('/+$'), '');
    const b = requestPath.replace(new RegExp('/+$'), '');
    if (a === b) {
      return true;
    }
    try {
      return decodeURIComponent(a) === decodeURIComponent(b);
    } catch (_e) {
      return false;
    }
  }

  private static cleanEtag_(raw: string): string {
    let s = (raw || '').trim();
    // 去掉弱标记 W/ 与引号
    if (s.indexOf('W/') === 0 || s.indexOf('w/') === 0) {
      s = s.substring(2).trim();
    }
    if (s.startsWith('"') && s.endsWith('"') && s.length >= 2) {
      s = s.substring(1, s.length - 1);
    }
    return s;
  }
}
