/**
 * 网络工具 — 基于 RCP（支持 DNS/代理）
 * 替代 @ohos.net.http，修复 DNS 无法解析问题
 */
import rcp from '@hms.collaboration.rcp';
import http from '@ohos.net.http';
import util from '@ohos.util';
import zlib from '@ohos.zlib';
import { CookieStore } from './CookieStore';
import { DISABLE_COOKIE_HEADER, REQUEST_GROUP_HEADER } from '../engine/source/SourceNetworkPolicy';

interface PooledSession {
  session: rcp.Session;
  activeRequests: number;
  retired: boolean;
}

interface RequestGroupState {
  cancelled: boolean;
  sessions: Set<rcp.Session>;
  systemRequests: Set<http.HttpRequest>;
}

export class NetUtil {
  private static requestGroups_: Map<string, RequestGroupState> = new Map();
  private static gbkEncodeMap_: Map<string, number[]> | null = null;

  static startRequestGroup(id: string): void {
    if (id) NetUtil.requestGroups_.set(id, { cancelled: false, sessions: new Set(), systemRequests: new Set() });
  }

  static cancelRequestGroup(id: string): void {
    const group = NetUtil.requestGroups_.get(id);
    if (!group) return;
    group.cancelled = true;
    group.sessions.forEach((session: rcp.Session) => {
      try { session.close(); } catch (_error) { /* already closed */ }
    });
    group.systemRequests.forEach((request: http.HttpRequest) => {
      try { request.destroy(); } catch (_error) { /* already destroyed */ }
    });
    group.sessions.clear();
    group.systemRequests.clear();
  }

  static finishRequestGroup(id: string): void {
    if (!id) return;
    NetUtil.cancelRequestGroup(id);
    NetUtil.requestGroups_.delete(id);
  }
  /** 请求前注入持久化的 Cookie 头（不覆盖显式设置的 Cookie，含空字符串=禁用） */
  private static injectCookie_(url: string, headers: Record<string, string>): void {
    try {
      // 调用方已声明 Cookie（即使为空）则完全不注入，避免干扰 OAuth 等接口
      const keys = Object.keys(headers);
      for (let i = 0; i < keys.length; i++) {
        if (keys[i].toLowerCase() === 'cookie') {
          return;
        }
      }
      const cookie = CookieStore.getInstance().getCookie(url);
      if (!cookie) return;
      headers['Cookie'] = cookie;
    } catch (_e) { /* CookieStore 未初始化时忽略 */ }
  }

  // ========== DNS 配置 ==========

  /** 自定义 DNS 服务器列表（逗号分隔的 IP），为空则使用系统 DNS */
  private static dnsServers: string = '8.8.8.8,114.114.114.114,223.5.5.5,1.1.1.1';
  /** 是否启用自定义 DNS */
  private static dnsEnabled: boolean = true;

  // ========== 代理配置 ==========

  private static proxyHost: string = '';
  private static proxyPort: number = 0;

  // ========== 配置变更标记（DNS/Proxy 变更后需重建 session） ==========
  private static configVersion: number = 0;
  private static sessionConfigVersion: number = -1;

  // ========== 公共配置方法 ==========

  static setDns(servers: string, enabled: boolean = true): void {
    NetUtil.dnsServers = servers;
    NetUtil.dnsEnabled = enabled;
    NetUtil.configVersion++;
    console.info('[NetUtil] DNS set:', servers, 'enabled:', enabled);
  }

  static setProxy(host: string, port: number): void {
    NetUtil.proxyHost = host;
    NetUtil.proxyPort = port;
    NetUtil.configVersion++;
    console.info('[NetUtil] Proxy set:', host, port);
  }

  static clearProxy(): void {
    NetUtil.proxyHost = '';
    NetUtil.proxyPort = 0;
    NetUtil.configVersion++;
  }

  /** 获取当前 DNS/Proxy 配置快照（供 Worker 使用） */
  static getNetworkConfig(): { dnsServers: string; dnsEnabled: boolean; proxyHost: string; proxyPort: number; timeout: number } {
    return {
      dnsServers: NetUtil.dnsServers,
      dnsEnabled: NetUtil.dnsEnabled,
      proxyHost: NetUtil.proxyHost,
      proxyPort: NetUtil.proxyPort,
      timeout: NetUtil.getDefaultTimeout(),
    };
  }

  // ========== HTTP 请求 ==========

  /** 获取全局超时设置（默认 60s） */
  static getDefaultTimeout(): number {
    try {
      const t = AppStorage.get<number>('network_timeout');
      if (t && t > 0) return t * 1000;  // 存储单位：秒，返回值：毫秒
    } catch (_) { /* ignore */ }
    return 60000;
  }

  static async httpGet(url: string, headers?: Record<string, string>, timeout?: number): Promise<string> {
    return NetUtil.httpRequest('GET', url, undefined, headers, timeout || NetUtil.getDefaultTimeout());
  }

  /**
   * 使用 HarmonyOS 系统 HTTP 栈执行 GET。
   * 仅供明确需要绕开 RCP 请求指纹的站点级兼容逻辑使用。
   */
  static async httpGetSystem(url: string, headers?: Record<string, string>, timeout?: number): Promise<string> {
    return await NetUtil.systemHttpRequest(
      'GET',
      NetUtil.normalizeUrl(url),
      '',
      NetUtil.buildHeaders(headers),
      timeout || NetUtil.getDefaultTimeout()
    );
  }

  /**
   * 下载二进制数据（不进行文本解码，不做 gzip 解压）
   * 用于下载图片、加密文件等二进制内容
   */
  static async httpGetBinary(url: string, headers?: Record<string, string>, timeout?: number): Promise<ArrayBuffer> {
    const startMs: number = Date.now();
    try {
      const requestUrl = NetUtil.normalizeUrl(url);
      const h = NetUtil.buildHeaders(headers);
      const cookieEnabled = NetUtil.prepareCookiePolicy_(h);
      if (cookieEnabled) NetUtil.injectCookie_(requestUrl, h);
      const reqHeaders = h as rcp.RequestHeaders;
      const request = new rcp.Request(requestUrl, 'GET', reqHeaders, '');

      // 使用独立 session（不与主 session 共享，避免被其他请求的 session 重建取消）
      const tf: number = timeout || NetUtil.getDefaultTimeout();
      const cfg: rcp.Configuration = {
        transfer: { timeout: { connectMs: tf, transferMs: tf } },
        security: { remoteValidation: 'system' } as rcp.SecurityConfiguration,
      };
      const session = rcp.createSession({ requestConfiguration: cfg } as rcp.SessionConfiguration);

      const response = await session.fetch(request);
      const binHeaders = (response.headers || {}) as Record<string, string | string[] | undefined>;
      if (cookieEnabled) {
        CookieStore.getInstance().setCookiesFromResponse(requestUrl, binHeaders['set-cookie']);
      }
      console.info('[NetUtil] GET(binary)', requestUrl.substring(0, 80), '->', response.statusCode,
        '(' + (Date.now() - startMs) + 'ms)');
      if (response.statusCode < 200 || response.statusCode >= 400) {
        throw new Error(`HTTP ${response.statusCode}`);
      }
      if (response.body === undefined || response.body === null) {
        return new ArrayBuffer(0);
      }
      // 返回原始 ArrayBuffer（复制一份避免被 session 复用）
      const src = new Uint8Array(response.body);
      const copy = new Uint8Array(src.length);
      copy.set(src);
      return copy.buffer;
    } catch (e) {
      const errMsg: string = (e as Error).message || String(e);
      console.error('[NetUtil] GET(binary)', NetUtil.normalizeUrl(url).substring(0, 80), 'FAILED:', errMsg);
      throw new Error(errMsg);
    }
  }

  static async httpPost(url: string, body: string, headers?: Record<string, string>, timeout?: number): Promise<string> {
    const h = NetUtil.buildHeaders(headers);
    if (!h['Content-Type'] && !h['content-type']) {
      h['Content-Type'] = 'application/x-www-form-urlencoded';
    }
    return NetUtil.httpRequest('POST', url, body, h, timeout || NetUtil.getDefaultTimeout());
  }

  /**
   * 按书源声明的 charset 编码 application/x-www-form-urlencoded 请求体。
   *
   * HarmonyOS TextEncoder 只提供 UTF-8，但大量旧小说站的 POST 搜索接口仍按
   * GBK/GB18030 解释百分号字节。这里用系统 TextDecoder 反向建立 GBK 双字节
   * 映射（只初始化一次），让请求体保持 ASCII 百分号形式，避免 RCP 再次按
   * UTF-8 改写原始字节。
   */
  static encodeFormBody(body: string, charset: string): string {
    const normalized = (charset || '').toLowerCase().replace(/[_-]/g, '');
    if (!body || !normalized || (normalized !== 'gbk' && normalized !== 'gb2312' &&
      normalized !== 'gb18030')) return body || '';
    return body.split('&').map((part: string): string => {
      const separator = part.indexOf('=');
      if (separator < 0) return part;
      const rawName = part.substring(0, separator);
      const rawValue = part.substring(separator + 1);
      const decode = (value: string): string => {
        try { return decodeURIComponent(value.replace(/\+/g, ' ')); } catch (_e) { return value; }
      };
      return NetUtil.encodeFormComponent_(decode(rawName), true) + '=' +
        NetUtil.encodeFormComponent_(decode(rawValue), false);
    }).join('&');
  }

  private static encodeFormComponent_(value: string, _isName: boolean): string {
    if (!value) return '';
    const map = NetUtil.getGbkEncodeMap_();
    const bytes: number[] = [];
    for (let index = 0; index < value.length; index++) {
      let char = value.charAt(index);
      const first = value.charCodeAt(index);
      if (first >= 0xD800 && first <= 0xDBFF && index + 1 < value.length) {
        const second = value.charCodeAt(index + 1);
        if (second >= 0xDC00 && second <= 0xDFFF) {
          char = value.substring(index, index + 2);
          index++;
        }
      }
      const mapped = map.get(char);
      if (mapped) {
        for (const byte of mapped) bytes.push(byte);
        continue;
      }
      // ASCII 和 GBK 不支持的字符（例如 emoji）回退为 UTF-8，至少不丢失参数。
      const utf8 = new util.TextEncoder().encodeInto(char);
      for (const byte of utf8) bytes.push(byte);
    }
    let result = '';
    for (const byte of bytes) {
      const safe = (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) ||
        (byte >= 0x61 && byte <= 0x7A) || byte === 0x2D || byte === 0x2E ||
        byte === 0x5F || byte === 0x7E;
      result += safe ? String.fromCharCode(byte) : '%' + byte.toString(16).toUpperCase().padStart(2, '0');
    }
    return result;
  }

  private static getGbkEncodeMap_(): Map<string, number[]> {
    if (NetUtil.gbkEncodeMap_) return NetUtil.gbkEncodeMap_;
    const map = new Map<string, number[]>();
    try {
      const decoder = new util.TextDecoder('gb18030', { fatal: false });
      for (let lead = 0x81; lead <= 0xFE; lead++) {
        for (let trail = 0x40; trail <= 0xFE; trail++) {
          if (trail === 0x7F) continue;
          const decoded = decoder.decodeToString(new Uint8Array([lead, trail]));
          if (!decoded || decoded.includes('\uFFFD') || decoded.length !== 1 || map.has(decoded)) continue;
          map.set(decoded, [lead, trail]);
        }
      }
    } catch (error) {
      console.warn('[NetUtil] GBK encoder map initialization failed:', (error as Error).message);
    }
    // 即使系统编码器不可用也缓存空表，后续请求使用 UTF-8 回退，不反复阻塞。
    NetUtil.gbkEncodeMap_ = map;
    console.info('[NetUtil] GBK encoder map ready:', map.size, 'characters');
    return map;
  }

  /**
   * 使用 HarmonyOS 系统 HTTP 栈提交表单。
   * 用于少数拒绝 RCP HTTP/2 POST、强制要求 Content-Length 的旧站点。
   */
  static async httpPostSystem(url: string, body: string, headers?: Record<string, string>, timeout?: number): Promise<string> {
    const h = NetUtil.buildHeaders(headers);
    if (!h['Content-Type'] && !h['content-type']) {
      h['Content-Type'] = 'application/x-www-form-urlencoded';
    }
    if (!h['Content-Length'] && !h['content-length']) {
      h['Content-Length'] = body.length.toString();
    }
    return await NetUtil.systemHttpRequest('POST', NetUtil.normalizeUrl(url), body, h,
      timeout || NetUtil.getDefaultTimeout());
  }

  static async httpPut(url: string, body: string, headers?: Record<string, string>, timeout?: number): Promise<string> {
    return NetUtil.httpRequest('PUT', url, body, NetUtil.buildHeaders(headers), timeout || NetUtil.getDefaultTimeout());
  }

  /**
   * 发送自定义 HTTP 请求方法（PROPFIND / MKCOL / DELETE 等）
   */
  static async httpCustomMethod(method: string, url: string, body?: string, headers?: Record<string, string>, timeout?: number): Promise<string> {
    return NetUtil.httpRequest(method, url, body || '', NetUtil.buildHeaders(headers), timeout || NetUtil.getDefaultTimeout());
  }

  // ========== 内部实现 ==========

  /** 不同超时配置使用独立 Session，避免并发请求因 Session 重建而互相取消。 */
  private static sessionPool_: Map<number, PooledSession> = new Map();

  private static acquireSession(timeout: number): PooledSession {
    try {
      // DNS/Proxy 配置变化后淘汰旧池；仍有请求的 Session 等请求结束后再关闭。
      if (NetUtil.sessionConfigVersion !== NetUtil.configVersion) {
        NetUtil.sessionPool_.forEach((entry: PooledSession) => {
          entry.retired = true;
          if (entry.activeRequests === 0) {
            try { entry.session.close(); } catch (_) { /* ignore */ }
          }
        });
        NetUtil.sessionPool_.clear();
        NetUtil.sessionConfigVersion = NetUtil.configVersion;
      }
      let entry = NetUtil.sessionPool_.get(timeout);
      if (!entry) {
        const secCfg: rcp.SecurityConfiguration = {
          remoteValidation: 'system',
          tlsRange: {
            min: 'TlsV1.0' as rcp.TlsVersion,
            max: 'TlsV1.3' as rcp.TlsVersion
          }
        };

        // 构建 Configuration，应用 DNS 和 Proxy
        const cfg: rcp.Configuration = {
          transfer: {
            timeout: { connectMs: timeout, transferMs: timeout }
          },
          security: secCfg
        };

        // DNS 配置：dnsRules 为 IpAndPort[] (DnsServers)
        if (NetUtil.dnsEnabled && NetUtil.dnsServers) {
          const dnsList = NetUtil.dnsServers.split(',').map(s => s.trim()).filter(s => s);
          if (dnsList.length > 0) {
            const dnsServers: rcp.IpAndPort[] = dnsList.map(ip => ({ ip: ip, port: 53 }));
            cfg.dns = { dnsRules: dnsServers } as rcp.DnsConfiguration;
            console.info('[NetUtil] DNS applied:', dnsList.join(','));
          }
        }

        // Proxy 配置：ProxyConfiguration = 'system' | 'no-proxy' | WebProxy
        if (NetUtil.proxyHost && NetUtil.proxyPort > 0) {
          cfg.proxy = { url: 'http://' + NetUtil.proxyHost + ':' + NetUtil.proxyPort } as rcp.WebProxy;
          console.info('[NetUtil] Proxy applied:', NetUtil.proxyHost + ':' + NetUtil.proxyPort);
        }

        const sessionCfg: rcp.SessionConfiguration = {
          requestConfiguration: cfg
        };
        entry = {
          session: rcp.createSession(sessionCfg),
          activeRequests: 0,
          retired: false
        };
        NetUtil.sessionPool_.set(timeout, entry);
        console.info('[NetUtil] Session created, timeout:', timeout, 'ms');
      }
      entry.activeRequests++;
      return entry;
    } catch (err) {
      throw err;
    }
  }

  private static releaseSession(entry: PooledSession): void {
    entry.activeRequests = Math.max(0, entry.activeRequests - 1);
    if (entry.retired && entry.activeRequests === 0) {
      try { entry.session.close(); } catch (_) { /* ignore */ }
    }
  }

  /** 淘汰发生连接错误的会话；等待其余并发请求结束后再关闭。 */
  private static retireSession(timeout: number, entry: PooledSession): void {
    if (NetUtil.sessionPool_.get(timeout) === entry) {
      NetUtil.sessionPool_.delete(timeout);
    }
    entry.retired = true;
    if (entry.activeRequests === 0) {
      try { entry.session.close(); } catch (_) { /* ignore */ }
    }
  }

  /** 仅重试 TLS/连接重置等瞬时网络错误，不重试 HTTP 状态码错误。 */
  private static isTransientConnectionError(message: string): boolean {
    return /(SSL connect error|connection reset|connection refused|socket|network is unreachable|1007900035|osErr\s*104)/i.test(message);
  }

  /**
   * RCP 不会像 OkHttp HttpUrl 一样自动编码 URL 中的非 ASCII 字符。
   * 使用标准 URL 规范化，编码中文查询参数并保留已有的百分号编码。
   */
  private static normalizeUrl(rawUrl: string): string {
    try {
      return rawUrl
        .replace(/[^\x00-\x7F]+/g, (part: string): string => encodeURIComponent(part))
        .replace(/ /g, '%20');
    } catch (_e) {
      return rawUrl;
    }
  }

  /**
   * 部分 Cloudflare 节点会直接重置 RCP 的 TLS 握手。
   * 连接层失败时改用系统 HTTP 栈，避免单一 TLS 实现导致整条书源线路不可用。
   */
  private static async systemHttpRequest(
    method: string,
    requestUrl: string,
    body: string,
    headers: Record<string, string>,
    timeout: number,
    requestGroup: string = ''
  ): Promise<string> {
    const request = http.createHttp();
    const group = requestGroup ? NetUtil.requestGroups_.get(requestGroup) : undefined;
    if (requestGroup && (!group || group.cancelled)) throw new Error('校验已取消');
    group?.systemRequests.add(request);
    try {
      const cookieEnabled = NetUtil.prepareCookiePolicy_(headers);
      if (cookieEnabled) NetUtil.injectCookie_(requestUrl, headers);
      const response = await request.request(requestUrl, {
        method: method.toUpperCase() as http.RequestMethod,
        header: headers,
        extraData: body,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: timeout,
        readTimeout: timeout,
      });
      const respHeaders = (response.header || {}) as Record<string, string | string[] | undefined>;
      if (cookieEnabled) {
        CookieStore.getInstance().setCookiesFromResponse(requestUrl, respHeaders['set-cookie']);
      }
      console.info('[NetUtil] System HTTP', method, requestUrl, '→', response.responseCode);
      if (response.responseCode < 200 || response.responseCode >= 400) {
        const errorText = await NetUtil.httpResultToText(response.result, requestUrl);
        throw new Error(`HTTP ${response.responseCode}: ${errorText.substring(0, 200)}`);
      }
      return await NetUtil.httpResultToText(response.result, requestUrl);
    } finally {
      group?.systemRequests.delete(request);
      request.destroy();
    }
  }

  private static async httpResultToText(result: string | Object | ArrayBuffer, url: string): Promise<string> {
    if (typeof result === 'string') return result;
    if (result instanceof ArrayBuffer) {
      return await NetUtil.decodeBody(new Uint8Array(result), url);
    }
    return JSON.stringify(result);
  }

  private static async httpRequest(method: string, url: string, body?: string, headers?: Record<string, string>, timeout: number = 30000): Promise<string> {
    const startMs: number = Date.now();
    const requestUrl = NetUtil.normalizeUrl(url);
    const baseHeaders = NetUtil.buildHeaders(headers);
    const requestGroup = baseHeaders[REQUEST_GROUP_HEADER] || '';
    delete baseHeaders[REQUEST_GROUP_HEADER];
    let lastError: string = '';
    for (let attempt = 0; attempt < 2; attempt++) {
      let sessionEntry: PooledSession | null = null;
      let dedicatedSession: rcp.Session | null = null;
      const group = requestGroup ? NetUtil.requestGroups_.get(requestGroup) : undefined;
      try {
        if (requestGroup && (!group || group.cancelled)) throw new Error('校验已取消');
        const h = { ...baseHeaders };
        const cookieEnabled = NetUtil.prepareCookiePolicy_(h);
        if (cookieEnabled) NetUtil.injectCookie_(requestUrl, h);
        const reqHeaders = h as rcp.RequestHeaders;
        const request = new rcp.Request(requestUrl, method.toUpperCase() as rcp.HttpMethod, reqHeaders, body || '');
        let session: rcp.Session;
        if (group) {
          dedicatedSession = NetUtil.createSession_(timeout);
          group.sessions.add(dedicatedSession);
          session = dedicatedSession;
        } else {
          sessionEntry = NetUtil.acquireSession(timeout);
          session = sessionEntry.session;
        }
        const response = await session.fetch(request);
        const respHeaders = (response.headers || {}) as Record<string, string | string[] | undefined>;
        if (cookieEnabled) {
          CookieStore.getInstance().setCookiesFromResponse(requestUrl, respHeaders['set-cookie']);
        }
        console.info('[NetUtil]', method, requestUrl, '→', response.statusCode, '(' + (Date.now() - startMs) + 'ms)');
        if (response.statusCode < 200 || response.statusCode >= 400) {
          let errorText = '';
          if (response.body !== undefined && response.body !== null) {
            const errorBytes = new Uint8Array(response.body);
            errorText = await NetUtil.decodeBody(errorBytes, requestUrl);
          }
          throw new Error(`HTTP ${response.statusCode}: ${errorText.substring(0, 200)}`);
        }
        if (response.body === undefined || response.body === null) return '';
        const uint8 = new Uint8Array(response.body);
        return await NetUtil.decodeBody(uint8, requestUrl);
      } catch (e) {
        lastError = (e as Error).message || String(e);
        if (attempt === 0 && NetUtil.isTransientConnectionError(lastError)) {
          console.warn('[NetUtil] Transient connection error, rebuilding session and retrying:', lastError);
          if (sessionEntry) NetUtil.retireSession(timeout, sessionEntry);
          continue;
        }
        break;
      } finally {
        if (dedicatedSession) {
          group?.sessions.delete(dedicatedSession);
          try { dedicatedSession.close(); } catch (_error) { /* ignore */ }
        }
        if (sessionEntry) NetUtil.releaseSession(sessionEntry);
      }
    }
    if (NetUtil.isTransientConnectionError(lastError) && !NetUtil.proxyHost) {
      try {
        console.warn('[NetUtil] RCP connection failed, falling back to system HTTP:', lastError);
        if (requestGroup && NetUtil.requestGroups_.get(requestGroup)?.cancelled) throw new Error('校验已取消');
        return await NetUtil.systemHttpRequest(method, requestUrl, body || '', baseHeaders, timeout, requestGroup);
      } catch (fallbackError) {
        lastError = (fallbackError as Error).message || String(fallbackError);
      }
    }
    const elapsedMs: number = Date.now() - startMs;
    console.error('[NetUtil]', method, requestUrl, 'FAILED (' + elapsedMs + 'ms):', lastError);
    throw new Error(lastError);
  }

  private static createSession_(timeout: number): rcp.Session {
    const security: rcp.SecurityConfiguration = {
      remoteValidation: 'system',
      tlsRange: { min: 'TlsV1.0' as rcp.TlsVersion, max: 'TlsV1.3' as rcp.TlsVersion }
    };
    const configuration: rcp.Configuration = {
      transfer: { timeout: { connectMs: timeout, transferMs: timeout } },
      security: security,
    };
    if (NetUtil.dnsEnabled && NetUtil.dnsServers) {
      const dnsList = NetUtil.dnsServers.split(',').map((value: string): string => value.trim())
        .filter((value: string): boolean => !!value);
      if (dnsList.length > 0) {
        configuration.dns = { dnsRules: dnsList.map((ip: string): rcp.IpAndPort => ({ ip: ip, port: 53 })) } as rcp.DnsConfiguration;
      }
    }
    if (NetUtil.proxyHost && NetUtil.proxyPort > 0) {
      configuration.proxy = { url: 'http://' + NetUtil.proxyHost + ':' + NetUtil.proxyPort } as rcp.WebProxy;
    }
    return rcp.createSession({ requestConfiguration: configuration } as rcp.SessionConfiguration);
  }

  private static buildHeaders(headers?: Record<string, string>): Record<string, string> {
    return {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      'Accept': 'text/html,application/json,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Encoding': 'identity',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      ...(headers || {}),
    };
  }

  private static prepareCookiePolicy_(headers: Record<string, string>): boolean {
    const disabled = headers[DISABLE_COOKIE_HEADER] === '1';
    delete headers[DISABLE_COOKIE_HEADER];
    return !disabled;
  }

  private static async decodeBody(bytes: Uint8Array, url: string): Promise<string> {
    let bodyBytes = bytes;
    if (NetUtil.looksCompressed(bytes)) {
      try {
        bodyBytes = await NetUtil.inflateBytes(bytes);
        console.info('[NetUtil] gzip/zlib decompressed:', url, bytes.length, '→', bodyBytes.length);
      } catch (e) {
        const errMsg: string = (e as Error).message || String(e);
        console.warn('[NetUtil] gzip/zlib decompress failed:', url, errMsg);
      }
    }
    // 很多中文小说站仍以 GBK/GB18030 返回 HTML。此前无论页面声明什么编码
    // 都按 UTF-8 解码，书名、作者和章节标题会变成 �，还可能让 Agent 误判
    // 目录/登录页面。响应头在 RCP 层不向调用方暴露，因此从 HTML 前缀读取
    // meta charset；JSON/API 没有声明时继续使用 UTF-8。
    const declared = NetUtil.detectHtmlCharset_(bodyBytes);
    const decoder = util.TextDecoder.create(declared || 'utf-8', { fatal: false } as Record<string, Object>);
    return decoder.decodeToString(bodyBytes);
  }

  private static detectHtmlCharset_(bytes: Uint8Array): string {
    if (!bytes || bytes.length === 0) return '';
    const limit = Math.min(bytes.length, 8192);
    let ascii = '';
    for (let i = 0; i < limit; i++) {
      const value = bytes[i];
      // HTML 标签、属性和 charset 名称都是 ASCII；非 ASCII 字节用空格替代，
      // 避免 UTF-8 解码失败导致正则无法识别 meta 标签。
      ascii += value < 128 ? String.fromCharCode(value) : ' ';
    }
    const direct = ascii.match(/<meta\b[^>]*\bcharset\s*=\s*["']?\s*([\w-]+)/i);
    const httpEquiv = ascii.match(/<meta\b[^>]*\bcontent\s*=\s*["'][^"']*charset\s*=\s*([\w-]+)/i);
    const raw = (direct && direct[1]) || (httpEquiv && httpEquiv[1]) || '';
    const normalized = raw.toLowerCase().replace(/_/g, '-');
    if (normalized === 'gb2312' || normalized === 'gbk') return 'gb18030';
    if (normalized === 'big5' || normalized === 'utf-8' || normalized === 'utf8' ||
      normalized === 'iso-8859-1' || normalized === 'windows-1252') {
      return normalized === 'utf8' ? 'utf-8' : normalized;
    }
    return '';
  }

  private static looksCompressed(bytes: Uint8Array): boolean {
    if (bytes.length < 2) return false;
    if (bytes[0] === 0x1f && bytes[1] === 0x8b) return true;
    return bytes[0] === 0x78;
  }

  private static async inflateBytes(bytes: Uint8Array): Promise<Uint8Array> {
    let outputSize: number = Math.max(bytes.length * 8, 64 * 1024);
    const input = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
    for (let attempt = 0; attempt < 5; attempt++) {
      let zip: zlib.Zip;
      try {
        zip = await zlib.createZip();
      } catch (err) {
        throw new Error('Create gzip/zlib inflater failed: ' + (err as Error).message);
      }

      const output = new ArrayBuffer(outputSize);
      const strm: zlib.ZStream = {
        nextIn: input,
        availableIn: bytes.byteLength,
        nextOut: output,
        availableOut: outputSize
      };
      let status: zlib.ReturnStatus = zlib.ReturnStatus.OK;
      try {
        const initStatus = await zip.inflateInit2(strm, 47);
        if (initStatus !== zlib.ReturnStatus.OK) {
          throw new Error('gzip/zlib init failed, status=' + initStatus);
        }
      } catch (err) {
        throw new Error('gzip/zlib init failed: ' + (err as Error).message);
      }

      try {
        status = await zip.inflate(strm, zlib.CompressFlushMode.FINISH);
      } catch (err) {
        throw new Error('gzip/zlib inflate failed: ' + (err as Error).message);
      } finally {
        try {
          await zip.inflateEnd(strm);
        } catch (err) {
          console.warn('[NetUtil] inflateEnd failed:', (err as Error).message);
        }
      }

      if (status === zlib.ReturnStatus.STREAM_END || status === zlib.ReturnStatus.OK) {
        const totalOut = strm.totalOut || 0;
        return new Uint8Array(output.slice(0, totalOut));
      }
      if (status === zlib.ReturnStatus.BUF_ERROR) {
        outputSize *= 2;
        continue;
      }
      throw new Error('gzip/zlib inflate status=' + status + ' totalOut=' + (strm.totalOut || 0));
    }
    throw new Error('gzip/zlib inflate output buffer too small');
  }
}
