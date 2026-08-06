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

/** RCP 有些版本把 Set-Cookie 放在 response.cookies，而不是 headers。 */
function responseSetCookies(response: rcp.Response): string | string[] | undefined {
  const headers = (response.headers || {}) as Record<string, string | string[] | undefined>;
  let headerValue = headers['set-cookie'];
  if (!headerValue) {
    for (const key of Object.keys(headers)) {
      if (key.toLowerCase() === 'set-cookie') {
        headerValue = headers[key];
        break;
      }
    }
  }
  const cookies = response.cookies || [];
  const lines: string[] = [];
  if (headerValue) {
    if (Array.isArray(headerValue)) lines.push(...headerValue);
    else lines.push(String(headerValue));
  }
  for (const item of cookies) {
    if (item && item.name) lines.push(item.name + '=' + (item.value || ''));
  }
  console.info('[NetUtil] response cookies combined=', lines.length);
  return lines.length > 0 ? lines : undefined;
}

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
        CookieStore.getInstance().setCookiesFromResponse(requestUrl, responseSetCookies(response));
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
      const encodedName = NetUtil.encodeFormComponent_(decode(rawName), true);
      const encodedValue = NetUtil.encodeFormComponent_(decode(rawValue), false);
      // 系统编码器不可用（GBK 映射表为空且 UTF-8 回退失效，如单测 mock 环境）
      // 时编码结果为空串，此时保留原 UTF-8 百分号形式，避免请求体参数丢失。
      if (!encodedName || !encodedValue) return part;
      return encodedName + '=' + encodedValue;
    }).join('&');
  }

  /**
   * 按书源 charset 编码单个 URL 查询组件（如搜索 URL 中的 {{key}}）。
   *
   * GBK/GB2312/GB18030 站点按自身编码解释 URL 参数，UTF-8 百分号字节会被
   * 解码成乱码并返回空结果页（如 yqk.net 按 gb2312 解码 UTF-8 的"穿越"）。
   * 复用上面的 GBK 映射输出正确字节；其余 charset（含未声明）保持 UTF-8。
   */
  static encodeUrlComponent(value: string, charset: string): string {
    const normalized = (charset || '').toLowerCase().replace(/[_-]/g, '');
    if (!value) return '';
    if (normalized === 'gbk' || normalized === 'gb2312' || normalized === 'gb18030') {
      const encoded = NetUtil.encodeFormComponent_(value, false);
      // 系统编码器不可用时（GBK 映射表为空且 UTF-8 回退失效，如单测 mock
      // 环境）不应返回空串丢失关键词，回退到标准 encodeURIComponent。
      return encoded || encodeURIComponent(value);
    }
    return encodeURIComponent(value);
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
   * 手动跟随重定向链，处理"中间跳 Set-Cookie 后才放行"的防盗链站点。
   *
   * 典型场景（如 yimixs 的 /jd-fw-key）：POST /search → 302 /jd-fw-key?url=/search
   * → 302 回 /search，且 /jd-fw-key 的 302 响应里带 token/random Set-Cookie。
   * RCP 自动跟随时不把中间跳的 Set-Cookie 存进 CookieStore，导致带 cookie
   * 才能通过的 /search 无限循环。这里关闭自动重定向，逐跳保存 Set-Cookie，
   * 一旦 Location 回到已访问地址（循环闭合，cookie 已种好），用原始请求
   * （method/body/cookie 全保留）重放一次，得到真实响应。
   */
  private static async manualRedirectWithCookieGate_(
    method: string, url: string, body: string, headers: Record<string, string>,
    timeout: number, requestGroup: string, cookieEnabled: boolean
  ): Promise<string> {
    const session = NetUtil.createSession_(timeout, false);
    let curMethod: string = method.toUpperCase();
    let curUrl: string = url;
    let curBody: string = body;
    const visited: string[] = [normalizeVisitedUrl_(url)];
    try {
      for (let hop = 0; hop < 6; hop++) {
        const group = requestGroup ? NetUtil.requestGroups_.get(requestGroup) : undefined;
        if (requestGroup && (!group || group.cancelled)) throw new Error('校验已取消');
        const h = { ...headers };
        if (cookieEnabled) NetUtil.injectCookie_(curUrl, h);
        const request = new rcp.Request(curUrl, curMethod as rcp.HttpMethod, h as rcp.RequestHeaders, curBody || '');
        const response = await session.fetch(request);
        const respHeaders = (response.headers || {}) as Record<string, string | string[] | undefined>;
        // 中间跳的 Set-Cookie 必须立刻进 CookieStore，下一跳才能带上。
        if (cookieEnabled) {
          await CookieStore.getInstance().setCookiesFromResponse(curUrl, responseSetCookies(response));
        }
        console.info('[NetUtil] manual-redirect hop' + hop, curMethod, curUrl, '→', response.statusCode);
        const status: number = response.statusCode;
        if (status >= 300 && status < 400) {
          const locationRaw = respHeaders['location'];
          const location: string = Array.isArray(locationRaw) ? (locationRaw[0] || '') : (locationRaw || '');
          if (!location) {
            throw new Error('重定向响应缺少 Location: ' + status);
          }
          const next = resolveRelativeUrl_(curUrl, location);
          if (visited.indexOf(normalizeVisitedUrl_(next)) >= 0) {
            // 循环闭合：cookie 已种好，跳出跟随，重放原始请求。
            console.info('[NetUtil] redirect loop closed at', next.substring(0, 100) + ', replaying original ' + method);
            break;
          }
          visited.push(normalizeVisitedUrl_(next));
          curUrl = next;
          if (status === 302 || status === 303) {
            // 浏览器语义：302/303 转 GET 并丢弃 body（307/308 保留）。
            curMethod = 'GET';
            curBody = '';
          }
          continue;
        }
        if (status >= 200 && status < 300) {
          if (response.body === undefined || response.body === null) return '';
          return await NetUtil.decodeBody(new Uint8Array(response.body), curUrl);
        }
        throw new Error('手动跟随重定向遇到 HTTP ' + status);
      }
    } finally {
      try { session.close(); } catch (_error) { /* ignore */ }
    }
    // 循环闭合或跳数耗尽：带已种好的 cookie 重放原始请求。
    const replay = NetUtil.createSession_(timeout, false);
    try {
      const h = { ...headers };
      if (cookieEnabled) NetUtil.injectCookie_(url, h);
      const request = new rcp.Request(url, method.toUpperCase() as rcp.HttpMethod, h as rcp.RequestHeaders, body || '');
      const response = await replay.fetch(request);
      const respHeaders = (response.headers || {}) as Record<string, string | string[] | undefined>;
      if (cookieEnabled) {
        await CookieStore.getInstance().setCookiesFromResponse(url, responseSetCookies(response));
      }
      console.info('[NetUtil] manual-redirect replay', method, url, '→', response.statusCode);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw new Error('防盗链重放仍返回 HTTP ' + response.statusCode);
      }
      if (response.body === undefined || response.body === null) return '';
      return await NetUtil.decodeBody(new Uint8Array(response.body), url);
    } finally {
      try { replay.close(); } catch (_error) { /* ignore */ }
    }
  }

  /**
   * POST 带 body 的请求手动逐跳跟随重定向。
   *
   * RCP 自动跟随时把 301 也按浏览器语义转成 GET 并丢弃 body，但很多站点
   * （如帝国 CMS 的 /e/search/index.php 搜索接口）的 301 是 http→https
   * 或域名迁移，关键词全在 POST body 里，一丢就返回"没有搜索到相关的
   * 内容"。因此带 body 的 POST 一律关闭自动重定向逐跳跟随：301/307/308
   * 保留 method+body，302/303 转 GET（提交成功后关键词已进 URL）。
   * 循环场景抛 1007900047，由上层 manualRedirectWithCookieGate_ 兜底
   * （与 GET 循环同一路径）。
   */
  private static async manualFollowPost_(
    method: string, url: string, body: string, headers: Record<string, string>,
    timeout: number, requestGroup: string, cookieEnabled: boolean
  ): Promise<string> {
    const session = NetUtil.createSession_(timeout, false);
    let curMethod: string = method.toUpperCase();
    let curUrl: string = url;
    let curBody: string = body;
    const visited: string[] = [normalizeVisitedUrl_(url)];
    try {
      for (let hop = 0; hop < 10; hop++) {
        const group = requestGroup ? NetUtil.requestGroups_.get(requestGroup) : undefined;
        if (requestGroup && (!group || group.cancelled)) throw new Error('校验已取消');
        const h = { ...headers };
        if (cookieEnabled) NetUtil.injectCookie_(curUrl, h);
        const request = new rcp.Request(curUrl, curMethod as rcp.HttpMethod, h as rcp.RequestHeaders, curBody || '');
        const response = await session.fetch(request);
        const respHeaders = (response.headers || {}) as Record<string, string | string[] | undefined>;
        // 中间跳的 Set-Cookie 必须立刻进 CookieStore，下一跳才能带上。
        if (cookieEnabled) {
          await CookieStore.getInstance().setCookiesFromResponse(curUrl, responseSetCookies(response));
        }
        console.info('[NetUtil] manual-post hop' + hop, curMethod, curUrl, '→', response.statusCode);
        const status: number = response.statusCode;
        if (status >= 300 && status < 400) {
          const locationRaw = respHeaders['location'];
          const location: string = Array.isArray(locationRaw) ? (locationRaw[0] || '') : (locationRaw || '');
          if (!location) {
            throw new Error('重定向响应缺少 Location: ' + status);
          }
          const next = resolveRelativeUrl_(curUrl, location);
          if (visited.indexOf(normalizeVisitedUrl_(next)) >= 0) {
            // 循环闭合：交给上层 cookie 门兜底（与 GET 循环同一路径）。
            throw new Error('Number of redirects hit maximum amount (manual POST follow)');
          }
          visited.push(normalizeVisitedUrl_(next));
          curUrl = next;
          if (!shouldKeepPostBodyOnRedirect_(status)) {
            // 302/303 转 GET 丢 body（提交成功后关键词已进 URL）；
            // 301/307/308 保留 POST（域名迁移场景 body 必须带过去）。
            curMethod = 'GET';
            curBody = '';
          }
          continue;
        }
        if (status >= 200 && status < 300) {
          if (response.body === undefined || response.body === null) return '';
          return await NetUtil.decodeBody(new Uint8Array(response.body), curUrl);
        }
        throw new Error('手动跟随重定向遇到 HTTP ' + status);
      }
      throw new Error('Number of redirects hit maximum amount (manual POST follow)');
    } finally {
      try { session.close(); } catch (_error) { /* ignore */ }
    }
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
      const useSystemMarker = headers['X-Legado-Use-System-Http'] === '1';
      delete headers['X-Legado-Use-System-Http'];
      const cookieEnabled = NetUtil.prepareCookiePolicy_(headers);
      // 登录令牌的 java.get() 使用系统栈，是为了绕过 RCP 丢失重复
      // Set-Cookie；此请求不能再注入旧 Cookie，但仍要保存新 Cookie。
      if (cookieEnabled && !useSystemMarker) NetUtil.injectCookie_(requestUrl, headers);
      const response = await request.request(requestUrl, {
        method: method.toUpperCase() as http.RequestMethod,
        header: headers,
        extraData: body,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: timeout,
        readTimeout: timeout,
      });
      const respHeaders = (response.header || {}) as Record<string, string | string[] | undefined>;
      const systemCookies: string[] = [];
      const headerCookie = respHeaders['set-cookie'];
      if (headerCookie) {
        if (Array.isArray(headerCookie)) systemCookies.push(...headerCookie);
        else systemCookies.push(String(headerCookie));
      }
      const cookieHeader = String(response.cookies || '');
      if (cookieHeader) {
        for (const part of cookieHeader.split(';')) {
          const trimmed = part.trim();
          if (trimmed.indexOf('=') > 0) systemCookies.push(trimmed);
        }
      }
      if (cookieEnabled) {
        CookieStore.getInstance().setCookiesFromResponse(requestUrl,
          systemCookies.length > 0 ? systemCookies : undefined);
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
    // cookie 开关：重定向手动跟随流程也要遵守同一策略。
    // 注意不删除 baseHeaders 中的禁用标记——fallback 的 systemHttpRequest
    // 需要靠它决定是否注入 cookie。
    const cookieEnabled = baseHeaders[DISABLE_COOKIE_HEADER] !== '1';
    // 带 body 的 POST 关闭自动重定向逐跳跟随：RCP 自动跟随会按浏览器语义
    // 把 301/302 转 GET 并丢弃 body，而 OkHttp（Android Legado）保留 POST
    // body 继续跳转，帝国 CMS 等站点的搜索接口依赖该行为——body 一丢就
    // 返回"没有搜索到"空结果页。
    const followPostManually: boolean = method.toUpperCase() === 'POST' && (body || '') !== '';
    let lastError: string = '';
    for (let attempt = 0; attempt < 2; attempt++) {
      let sessionEntry: PooledSession | null = null;
      let dedicatedSession: rcp.Session | null = null;
      const group = requestGroup ? NetUtil.requestGroups_.get(requestGroup) : undefined;
      try {
        if (requestGroup && (!group || group.cancelled)) throw new Error('校验已取消');
        if (followPostManually) {
          return await NetUtil.manualFollowPost_(
            method, requestUrl, body || '', baseHeaders, timeout, requestGroup, cookieEnabled);
        }
        const h = { ...baseHeaders };
        NetUtil.prepareCookiePolicy_(h);
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
          CookieStore.getInstance().setCookiesFromResponse(requestUrl, responseSetCookies(response));
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
        if (attempt === 0 && isRedirectLoopError(lastError)) {
          try {
            // 重定向链在某处循环：多半是中间跳才种下防盗链 cookie。
            // 手动逐跳跟随并保存 Set-Cookie，循环回到原地址后重放原始请求。
            return await NetUtil.manualRedirectWithCookieGate_(
              method, requestUrl, body || '', baseHeaders, timeout, requestGroup, cookieEnabled);
          } catch (redirectError) {
            lastError = (redirectError as Error).message || String(redirectError);
            // 手动跟随失败：中间跳的 cookie 已种入 CookieStore，
            // 下一轮普通请求（cookie 已就位）可能直接成功。
            continue;
          }
        }
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

  private static createSession_(timeout: number, autoRedirect: boolean = true): rcp.Session {
    const security: rcp.SecurityConfiguration = {
      remoteValidation: 'system',
      tlsRange: { min: 'TlsV1.0' as rcp.TlsVersion, max: 'TlsV1.3' as rcp.TlsVersion }
    };
    const configuration: rcp.Configuration = {
      // autoRedirect=false 用于手动跟随重定向链：防盗链站点（如 yimixs 的
      // /jd-fw-key）在中间跳 Set-Cookie 后才放行原地址，RCP 自动跟随会丢失
      // 中间跳 cookie 导致循环，需要逐跳保存后再重放原始请求。
      transfer: { timeout: { connectMs: timeout, transferMs: timeout }, autoRedirect: autoRedirect },
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
      // 部分站点会按 Accept-Encoding 协商返回不同版本：只支持 identity 时返回
      // 降级页面（例如必去小说网的桌面版不含搜索表单，浏览器版才返回完整
      // 移动页）。声明 gzip 让服务器返回完整内容，decodeBody 已有解压兜底；
      // 若 RCP 已自动解压，looksCompressed 不会命中，行为不变。
      'Accept-Encoding': 'gzip, deflate',
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
    if (declared) {
      const decoder = util.TextDecoder.create(declared, { fatal: false } as Record<string, Object>);
      return decoder.decodeToString(bodyBytes);
    }
    // 没有 charset 声明的短响应（如搜索拦截 alert 脚本页）常是纯 GBK 页面：
    // 按 UTF-8 解码会出现 U+FFFD 乱码，导致 alert 文案不可读、只能靠猜。
    // 此时同时用 gb18030 解码，取替换字符更少的一方——真 UTF-8 文本一个
    // 替换字符都不会有，不会被误切。
    const utf8Text = util.TextDecoder.create('utf-8', { fatal: false } as Record<string, Object>)
      .decodeToString(bodyBytes);
    if (NetUtil.countReplacementChar_(utf8Text) === 0) return utf8Text;
    const gbkText = util.TextDecoder.create('gb18030', { fatal: false } as Record<string, Object>)
      .decodeToString(bodyBytes);
    return NetUtil.countReplacementChar_(gbkText) < NetUtil.countReplacementChar_(utf8Text) ? gbkText : utf8Text;
  }

  private static countReplacementChar_(text: string): number {
    let count = 0;
    for (let i = 0; i < text.length; i++) {
      if (text.charCodeAt(i) === 0xFFFD) count++;
    }
    return count;
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

/** RCP 自动跟随重定向次数耗尽（默认 50 跳）时报错 1007900047。 */
export function isRedirectLoopError(message: string): boolean {
  return message.includes('Number of redirects hit maximum amount') || message.includes('1007900047');
}

/**
 * 重定向跳转时是否保留 POST method+body。
 * - 301/307/308 保留：301 常是 http→https / 域名迁移（如爱久久网
 *   jjjxsw.com → ijjxsxzw.com），body 必须带过去；307/308 语义本就要求保留。
 * - 302/303 转 GET 丢 body：302 是"提交成功请跳转"（帝国 CMS 搜索返回
 *   result/?searchid=xxx），关键词已由服务器转成 searchid 放进 URL，
 *   body 无用且 result 页不接受 POST。
 * RCP 自动跟随把所有 3xx 都按浏览器语义处理（301 也丢 body），这是
 * manualFollowPost_ 逐跳跟随要修正的行为。
 */
export function shouldKeepPostBodyOnRedirect_(status: number): boolean {
  return status !== 302 && status !== 303;
}

/** 解析重定向 Location（绝对 URL / 协议相对 / 根相对 / 路径相对）。 */
export function resolveRelativeUrl_(baseUrl: string, location: string): string {
  const loc = location.trim();
  if (/^https?:\/\//i.test(loc)) return loc;
  const schemeEnd = baseUrl.indexOf('://');
  if (schemeEnd < 0) return loc;
  const slashAfterHost = baseUrl.indexOf('/', schemeEnd + 3);
  const origin = slashAfterHost < 0 ? baseUrl : baseUrl.substring(0, slashAfterHost);
  if (loc.startsWith('//')) return baseUrl.substring(0, schemeEnd + 3) + loc.substring(2);
  if (loc.startsWith('/')) return origin + loc;
  // 相对路径：基于 baseUrl 目录（不含 query）。
  if (slashAfterHost < 0) return origin + '/' + loc;
  const qIndex = baseUrl.indexOf('?', slashAfterHost);
  const path = (qIndex >= 0 ? baseUrl.substring(0, qIndex) : baseUrl);
  const lastSlash = path.lastIndexOf('/');
  return (lastSlash > schemeEnd + 3 ? path.substring(0, lastSlash + 1) : path + '/') + loc;
}

/**
 * visited 集合用的规范化 URL：解码百分号、去掉 fragment、压缩路径重复斜杠。
 * 防盗链站点常把 Location 写成 %2Fsearch 之类的编码形式，解码后是
 * //search（前面的字面 / 加上解码出的 /），压缩后才能真正与
 * 已访问的 /search 地址对上，否则循环闭合检测失效。
 */
export function normalizeVisitedUrl_(url: string): string {
  try {
    const decoded = decodeURIComponent(url);
    const hashIndex = decoded.indexOf('#');
    const clean = hashIndex >= 0 ? decoded.substring(0, hashIndex) : decoded;
    const schemeEnd = clean.indexOf('://');
    if (schemeEnd < 0) return clean;
    const slashAfterHost = clean.indexOf('/', schemeEnd + 3);
    if (slashAfterHost < 0) return clean;
    const origin = clean.substring(0, schemeEnd + 3) + clean.substring(schemeEnd + 3, slashAfterHost);
    const path = clean.substring(slashAfterHost).replace(/\/{2,}/g, '/');
    return origin + path;
  } catch (_e) {
    return url;
  }
}
