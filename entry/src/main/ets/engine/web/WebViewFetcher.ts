/**
 * WebView 获取器 — 为需要 JS 渲染的搜索源/正文提供网页内容
 *
 * 工作方式：
 * 1. 页面在 build() 中嵌入隐藏 Web 组件，将 controller 注册到 WebViewFetcher
 * 2. SourceExecutor 检测到需要 WebView 时，调用 WebViewFetcher.fetch(url)
 * 3. WebView 加载页面，onPageEnd 触发后轮询 document.readyState
 * 4. 等到 readyState === 'complete' 或超时，通过 runJavaScript 提取 HTML
 */
import web_webview from '@ohos.web.webview';
import connection from '@ohos.net.connection';

export class WebViewFetchResult {
  html: string = '';
  finalUrl: string = '';
}

/** 交互 WebView 需要复现的请求语义；POST 验证页不能丢掉原始 body。 */
export interface WebViewInteractiveRequest {
  method?: string;
  body?: string;
}

interface InteractivePageCacheEntry {
  html: string;
  cachedAt: number;
}

interface WebViewRequestQueueEntry {
  url: string;
  timeoutMs: number;
  headers: Record<string, string>;
  allowedRedirectHosts: string[];
  resolve: (result: WebViewFetchResult) => void;
  reject: (err: Error) => void;
}

export class WebViewFetcher {
  private static controller: web_webview.WebviewController | null = null;
  private static pendingResolve: ((result: WebViewFetchResult) => void) | null = null;
  private static pendingReject: ((err: Error) => void) | null = null;
  /** 当前 fetch 使用的 controller；页面销毁后据此识别遗留的挂起请求。 */
  private static pendingController: web_webview.WebviewController | null = null;
  /** startFetch 发起时刻；onPageEnd 缺失时兜底提取的计时基准。 */
  private static fetchStartedAt: number = 0;
  private static pendingUrl: string = '';
  private static timeoutId: number = -1;
  // 追踪页面加载次数（处理重定向场景）
  private static loadCount: number = 0;
  /** 最近一次页面结束时间；重载时重置，用于避免过早提取 WAF 探针页。 */
  private static lastPageEndAt: number = 0;
  /** 当前 fetch 已确认属于本次导航的 URL，防止队列切换后接收上一页迟到的 onPageEnd。 */
  private static activeNavigationUrls: Set<string> = new Set();
  /** 当前 fetch 允许的站点域名；为空表示保留原有的跨域重定向行为。 */
  private static pendingAllowedRedirectHosts: Set<string> = new Set();
  // 轮询定时器
  private static pollIntervalId: number = -1;
  /** 排队等待的最长时间；上游 WebView 卡住时不能让后续请求无限排队。 */
  private static readonly QUEUE_WAIT_TIMEOUT_MS: number = 8000;
  // 请求队列：排队等待的 fetch（WebView 同时只能处理一个）
  private static requestQueue: WebViewRequestQueueEntry[] = [];

  /** 与 Android Legado 后台 WebView 一致的默认桌面 UA。 */
  private static readonly DEFAULT_USER_AGENT: string =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  /**
   * 书源的 header 可能携带 Android/Mobile UA。WebView 若沿用它，很多站点
   * 会直接返回移动版或把移动版章节跳转到广告页；HTTP 请求仍保留书源 UA，
   * 这里只固定浏览器页面为桌面 UA。
   */
  static forceDesktopUserAgent: boolean = true;

  /** 等待 controller 注册的回调列表（waitForReady 使用） */
  private static readyWaiters: Array<() => void> = [];
  /**
   * 交互式 Cloudflare 验证处理器
   * 页面启动时注册，当请求被 Cloudflare 拦截时弹出 WebView 让用户手动验证
   */
  static interactiveFetcher: ((url: string, request?: WebViewInteractiveRequest) => Promise<string>) | null = null;

  /** 交互式验证的 Promise resolve（由 CloudflareDialog 调用） */
  static interactiveResolve: ((html: string) => void) | null = null;
  /** 当前交互 WebView 的用途；登录模式会在页面加载后自动打开登录面板。 */
  static interactivePurpose: 'challenge' | 'login' = 'challenge';
  /** 当前交互 WebView 的用户提示，由页面层传入，避免所有弹窗都显示成泛化“验证”。 */
  static interactiveReason: string = '';
  private static interactivePageCache: Map<string, InteractivePageCacheEntry> = new Map();
  private static readonly INTERACTIVE_CACHE_TTL_MS: number = 5 * 60 * 1000;
  private static readonly INTERACTIVE_CACHE_MAX_ENTRIES: number = 6;

  /** 请求是否需要交互式验证 */
  static needsInteractive(url: string, errorMsg: string): boolean {
    return !!(WebViewFetcher.interactiveFetcher) &&
      (errorMsg.includes('403') || errorMsg.includes('Cloudflare') || errorMsg.includes('503') || errorMsg.includes('page not found'));
  }

  /** 弹出交互式 WebView 验证 */
  static async fetchInteractive(url: string, purpose: 'challenge' | 'login' = 'challenge',
    reason: string = '', request?: WebViewInteractiveRequest,
    fetcherOverride?: (url: string, request?: WebViewInteractiveRequest) => Promise<string>): Promise<string> {
    WebViewFetcher.interactivePurpose = purpose;
    const cacheKey = WebViewFetcher.interactiveCacheKey(url, request);
    const cached = WebViewFetcher.interactivePageCache.get(cacheKey);
    // 登录模式必须重新打开页面，不能复用上次验证缓存，否则用户无法进入登录面板。
    if (purpose !== 'login' && cached && Date.now() - cached.cachedAt <= WebViewFetcher.INTERACTIVE_CACHE_TTL_MS) {
      WebViewFetcher.interactivePageCache.delete(cacheKey);
      cached.html = WebViewFetcher.decodeJavaScriptString(cached.html);
      if (WebViewFetcher.isReusableInteractiveHtml(cached.html)) {
        console.info('[WebViewFetcher] Reusing interactive HTML:', cacheKey.substring(0, 80));
        // 命中后移到 Map 末尾并续期，保证完整 Agent 链路最终复检时仍可复用。
        cached.cachedAt = Date.now();
        WebViewFetcher.interactivePageCache.set(cacheKey, cached);
        return cached.html;
      }
      console.info('[WebViewFetcher] Discarding unfinished interactive HTML:',
        cacheKey.substring(0, 80));
    }
    if (cached) WebViewFetcher.interactivePageCache.delete(cacheKey);
    const fetcher = fetcherOverride || WebViewFetcher.interactiveFetcher;
    if (!fetcher) {
      throw new Error('Interactive fetcher not registered');
    }
    WebViewFetcher.interactiveReason = reason;
    let rawHtml = '';
    try {
      rawHtml = await fetcher(url, request);
    } finally {
      WebViewFetcher.interactiveReason = '';
    }
    const html = WebViewFetcher.decodeJavaScriptString(rawHtml);
    if (WebViewFetcher.isReusableInteractiveHtml(html)) {
      WebViewFetcher.interactivePageCache.set(cacheKey, {
        html: html,
        cachedAt: Date.now(),
      });
      while (WebViewFetcher.interactivePageCache.size > WebViewFetcher.INTERACTIVE_CACHE_MAX_ENTRIES) {
        const oldestKey = WebViewFetcher.interactivePageCache.keys().next().value as string | undefined;
        if (!oldestKey) break;
        WebViewFetcher.interactivePageCache.delete(oldestKey);
      }
    }
    return html;
  }

  private static interactiveCacheKey(url: string, request?: WebViewInteractiveRequest): string {
    const normalized = (url || '')
      .replace(/#.*$/, '')
      .replace(/([?&])(?:t|_|timestamp)=\d+(?=&|$)/gi, '$1')
      .replace(/\?&/, '?')
      .replace(/[?&]$/, '');
    const body = request?.body || '';
    return body ? normalized + '|body:' + body : normalized;
  }

  private static isReusableInteractiveHtml(html: string): boolean {
    if (!html || html.length < 300) return false;
    return !WebViewFetcher.isInteractiveChallengeHtml(html);
  }

  // ========== DNS（DoH）配置 ==========

  /** 当前使用的 DoH URL（DNS-over-HTTPS），空字符串表示不配置 */
  private static dohUrl: string = '';
  /** DNS IP → DoH URL 映射表 */
  private static readonly DNS_IP_TO_DOH: Record<string, string> = {
    '8.8.8.8': 'https://dns.google/dns-query',
    '8.8.4.4': 'https://dns.google/dns-query',
    '1.1.1.1': 'https://cloudflare-dns.com/dns-query',
    '1.0.0.1': 'https://cloudflare-dns.com/dns-query',
    '208.67.222.222': 'https://dns.opendns.com/dns-query',
    '208.67.220.220': 'https://dns.opendns.com/dns-query',
    '114.114.114.114': 'https://dns.alidns.com/dns-query',
    '114.114.115.115': 'https://dns.alidns.com/dns-query',
    '223.5.5.5': 'https://dns.alidns.com/dns-query',
    '223.6.6.6': 'https://dns.alidns.com/dns-query',
  };
  /** 兜底 DoH URL（当 DNS IP 未匹配到时使用） */
  private static readonly DEFAULT_DOH_URL = 'https://dns.alidns.com/dns-query';

  // ========== 代理配置 ==========

  /** 当前使用的代理 URL */
  private static proxyUrl: string = '';

  // ========== 跳转次数限制 ==========

  /** 初始请求 URL（用于区分首次加载和重定向） */
  private static initialRequestUrl: string = '';
  /** 当前重定向计数（每次 fetch 重置） */
  private static redirectCount: number = 0;
  /** 最大允许重定向次数 */
  static maxRedirects: number = 20;

  // ========== 生命周期方法 ==========

  /** 页面在 build() 中调用，注册 WebView controller */
  static register(controller: web_webview.WebviewController): void {
    WebViewFetcher.controller = controller;
    // 通知所有等待注册的调用方
    while (WebViewFetcher.readyWaiters.length > 0) {
      const waiter = WebViewFetcher.readyWaiters.shift();
      if (waiter) waiter();
    }
  }

  /**
   * 等待 WebView controller 注册就绪。
   *
   * ArkUI 中父组件 aboutToAppear 先于 build() 执行，子组件 WebViewEngine 的
   * aboutToAppear（register）在 build 渲染时才触发。如果搜索在 aboutToAppear
   * 阶段通过路由参数自动触发，controller 可能尚未注册。此方法轮询等待注册完成。
   *
   * @param timeoutMs 等待超时（默认 3 秒）
   * @returns true 表示已就绪，false 表示超时
   */
  static waitForReady(timeoutMs: number = 3000): Promise<boolean> {
    if (WebViewFetcher.controller) return Promise.resolve(true);
    return new Promise<boolean>((resolve) => {
      let settled = false;
      const wrapped = (): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(true);
      };
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        // 超时后从等待列表中移除，防止泄漏
        const idx = WebViewFetcher.readyWaiters.indexOf(wrapped);
        if (idx >= 0) WebViewFetcher.readyWaiters.splice(idx, 1);
        resolve(false);
      }, timeoutMs);
      WebViewFetcher.readyWaiters.push(wrapped);
    });
  }

  /** 页面在 onPageEnd 中调用，追踪页面加载状态 */
  static onPageEnd(event?: { url: string }): void {
    if (!WebViewFetcher.pendingResolve) return;

    const currentUrl = event?.url || '';
    if (currentUrl && !WebViewFetcher.belongsToActiveNavigation(currentUrl)) {
      console.info('[WebViewFetcher] Ignoring stale onPageEnd:', currentUrl.substring(0, 60));
      return;
    }

    WebViewFetcher.loadCount++;
    WebViewFetcher.lastPageEndAt = Date.now();
    if (currentUrl) {
      WebViewFetcher.pendingUrl = currentUrl;
      WebViewFetcher.activeNavigationUrls.add(WebViewFetcher.normalizeNavigationUrl(currentUrl));
    }

    console.info('[WebViewFetcher] onPageEnd #' + WebViewFetcher.loadCount +
      ' url:', (currentUrl || '').substring(0, 60));

    // 清除旧的超时和轮询
    WebViewFetcher.clearTimers();

    // 设置新的超时（页面加载完成后等待 JS 渲染）
    // 从 15s 缩短到 5s：主要内容在 1-2s 内渲染，减少阻塞后续搜索
    WebViewFetcher.timeoutId = setTimeout(() => {
      console.info('[WebViewFetcher] Timeout reached, extracting HTML');
      WebViewFetcher.extractAndResolve();
    }, 5000);

    // 开始轮询 readyState（每 500ms 检查一次）
    WebViewFetcher.startPolling();
  }

  // ========== 核心 fetch 方法 ==========

  /** 提取页面内容，返回 Promise */
  static fetch(url: string, timeoutMs: number = 30000,
    headers: Record<string, string> = {}, allowedRedirectHosts: string[] = []): Promise<WebViewFetchResult> {
    if (!WebViewFetcher.controller) {
      return Promise.reject(new Error('WebView not registered'));
    }

    // 如果上一个 fetch 还没完成，排队等待而不是拒绝
    if (WebViewFetcher.pendingReject) {
      console.info('[WebViewFetcher] Previous fetch still pending, queueing request');
      return new Promise((resolve, reject) => {
        const entry: WebViewRequestQueueEntry = {
          url, timeoutMs, headers, allowedRedirectHosts, resolve, reject
        };
        WebViewFetcher.requestQueue.push(entry);
        // 排队请求必须有自己的等待上限：上游 fetch 若因页面销毁/控制器失效
        // 卡住，后续请求不能无限排队，应及时失败让调用方走 HTTP 兜底。
        setTimeout(() => {
          const index = WebViewFetcher.requestQueue.indexOf(entry);
          if (index < 0) return; // 已被队列处理
          WebViewFetcher.requestQueue.splice(index, 1);
          reject(new Error('WebView queue wait timeout'));
        }, WebViewFetcher.QUEUE_WAIT_TIMEOUT_MS);
      });
    }

    return WebViewFetcher.startFetch(url, timeoutMs, headers, allowedRedirectHosts);
  }

  /** 实际的 fetch 逻辑 */
  private static startFetch(url: string, timeoutMs: number,
    headers: Record<string, string>, allowedRedirectHosts: string[] = []): Promise<WebViewFetchResult> {
    return new Promise((resolve: (result: WebViewFetchResult) => void, reject: (err: Error) => void) => {
      const controller = WebViewFetcher.controller;
      if (!controller) {
        // 没有可用的 WebView（页面销毁后尚未重新注册）：立即失败并继续处理队列，
        // 而不是让后续请求全部挂到超时。
        reject(new Error('WebView not registered'));
        WebViewFetcher.processNext();
        return;
      }
      WebViewFetcher.pendingResolve = resolve;
      WebViewFetcher.pendingReject = reject;
      WebViewFetcher.pendingController = controller;
      WebViewFetcher.pendingUrl = url;
      WebViewFetcher.fetchStartedAt = Date.now();
      WebViewFetcher.loadCount = 0;
      WebViewFetcher.lastPageEndAt = 0;
      WebViewFetcher.initialRequestUrl = url;
      WebViewFetcher.redirectCount = 0;
      WebViewFetcher.activeNavigationUrls = new Set([WebViewFetcher.normalizeNavigationUrl(url)]);
      WebViewFetcher.pendingAllowedRedirectHosts = new Set(
        allowedRedirectHosts.map((host: string): string => WebViewFetcher.normalizeNavigationHost_(host))
          .filter((host: string): boolean => !!host)
      );

      // 设置总超时
      WebViewFetcher.timeoutId = setTimeout(() => {
        WebViewFetcher.clearTimers();
        WebViewFetcher.pendingResolve = null;
        WebViewFetcher.pendingReject = null;
        WebViewFetcher.pendingController = null;
        WebViewFetcher.pendingAllowedRedirectHosts.clear();
        reject(new Error('WebView load timeout'));
        WebViewFetcher.processNext();
      }, timeoutMs);

      // 加载 URL
      console.info('[WebViewFetcher] Loading:', url.substring(0, 80));
      let userAgent = WebViewFetcher.DEFAULT_USER_AGENT;
      const webHeaders: Array<web_webview.WebHeader> = [];
      Object.keys(headers).forEach((key: string) => {
        if (key.toLowerCase() === 'user-agent') {
          if (!WebViewFetcher.forceDesktopUserAgent) {
            userAgent = headers[key] || userAgent;
          } else if (headers[key] && headers[key] !== WebViewFetcher.DEFAULT_USER_AGENT) {
            console.info('[WebViewFetcher] Ignoring source User-Agent; using desktop UA');
          }
        } else {
          webHeaders.push({ headerKey: key, headerValue: headers[key] });
        }
      });
      try {
        controller.setCustomUserAgent(userAgent);
        controller.loadUrl(url, webHeaders);
      } catch (e) {
        // controller 已失效（组件销毁）时 loadUrl 会抛异常：清理状态并继续队列，
        // 避免 promise 永不结算导致调用方挂死。
        WebViewFetcher.clearTimers();
        WebViewFetcher.pendingResolve = null;
        WebViewFetcher.pendingReject = null;
        WebViewFetcher.pendingController = null;
        WebViewFetcher.pendingAllowedRedirectHosts.clear();
        reject(new Error('WebView load failed: ' + ((e as Error).message || String(e))));
        WebViewFetcher.processNext();
      }
    });
  }

  // ========== 跳转拦截（由 WebViewEngine.ets 的 onLoadIntercept 回调） ==========

  /**
   * WebView 即将加载 URL 时回调，用于限制重定向次数
   * 由 WebViewEngine.ets 的 .onLoadIntercept() 调用
   * @param url 即将加载的 URL
   * @returns true 阻止加载，false 允许加载
   */
  static onLoadIntercept(url: string): boolean {
    if (!WebViewFetcher.pendingResolve) return false;

    const targetHost = WebViewFetcher.navigationHost(url);
    if (targetHost && WebViewFetcher.pendingAllowedRedirectHosts.size > 0 &&
      !WebViewFetcher.pendingAllowedRedirectHosts.has(targetHost)) {
      console.warn('[WebViewFetcher] Blocked unrelated redirect to', url.substring(0, 120));
      // 不更新 pendingUrl/activeNavigationUrls：保留当前正文页，等待它的
      // onPageEnd/readyState 提取，而不是把广告页交给规则解析器。
      return true;
    }

    // 首次加载（与 fetch 传入的 URL 相同）不计为重定向
    if (url === WebViewFetcher.initialRequestUrl) {
      WebViewFetcher.activeNavigationUrls.add(WebViewFetcher.normalizeNavigationUrl(url));
      return false;
    }

    WebViewFetcher.activeNavigationUrls.add(WebViewFetcher.normalizeNavigationUrl(url));
    WebViewFetcher.pendingUrl = url;
    WebViewFetcher.redirectCount++;
    console.info('[WebViewFetcher] Redirect #' + WebViewFetcher.redirectCount + ' to:', url.substring(0, 60));

    if (WebViewFetcher.redirectCount > WebViewFetcher.maxRedirects) {
      console.warn('[WebViewFetcher] Too many redirects (' + WebViewFetcher.redirectCount + '), aborting');
      WebViewFetcher.clearTimers();
      const reject = WebViewFetcher.pendingReject;
      WebViewFetcher.pendingResolve = null;
      WebViewFetcher.pendingReject = null;
      WebViewFetcher.pendingController = null;
      WebViewFetcher.pendingAllowedRedirectHosts.clear();
      if (reject) reject(new Error('Too many redirects: ' + WebViewFetcher.redirectCount));
      WebViewFetcher.processNext();
      return true; // 阻止加载
    }

    return false; // 允许加载
  }

  // ========== DNS 配置 ==========

  /**
   * 从 DNS IP 列表推导 DoH URL
   * @param dnsStr 逗号分隔的 DNS IP 列表（如 "8.8.8.8,8.8.4.4"）
   * @returns 匹配的 DoH URL，或空字符串
   */
  private static resolveDohUrl(dnsStr: string): string {
    if (!dnsStr) return '';
    const ips = dnsStr.split(',').map(s => s.trim()).filter(s => s);
    for (const ip of ips) {
      const doh = WebViewFetcher.DNS_IP_TO_DOH[ip];
      if (doh) return doh;
    }
    // 未匹配到已知 DNS，使用兜底 DoH
    return WebViewFetcher.DEFAULT_DOH_URL;
  }

  /**
   * 配置 WebView 的 DNS-over-HTTPS（DoH）
   * 从 DNS IP 列表推导 DoH URL后调用 setHttpDns
   * @param dnsStr 逗号分隔的 DNS IP 列表
   */
  static configureDns(dnsStr: string): void {
    const dohUrl = WebViewFetcher.resolveDohUrl(dnsStr);
    WebViewFetcher.dohUrl = dohUrl;
    if (!dohUrl) {
      console.info('[WebViewFetcher] No DoH URL resolved, keeping system DNS');
      return;
    }
    try {
      web_webview.WebviewController.setHttpDns(
        web_webview.SecureDnsMode.AUTO,
        dohUrl
      );
      console.info('[WebViewFetcher] DNS configured: DoH=' + dohUrl);
    } catch (e) {
      console.warn('[WebViewFetcher] Failed to set DoH:', (e as Error).message);
    }
  }

  // ========== 代理配置 ==========

  /**
   * 配置 WebView 的 HTTP 代理（通过 connection.setAppHttpProxy，应用级生效）
   * @param proxyUrlStr 代理 URL（如 "http://127.0.0.1:8080"）
   */
  static configureProxy(proxyUrlStr: string): void {
    WebViewFetcher.proxyUrl = proxyUrlStr || '';
    if (!proxyUrlStr) {
      // 清空代理设置（设为空会清空）
      try {
        connection.setAppHttpProxy({ host: '', port: 0 } as connection.HttpProxy);
        console.info('[WebViewFetcher] Proxy cleared');
      } catch (e) {
        console.warn('[WebViewFetcher] Failed to clear proxy:', (e as Error).message);
      }
      return;
    }

    // 解析代理 URL → host:port
    const parsed = WebViewFetcher.parseProxyUrl(proxyUrlStr);
    if (!parsed) {
      console.warn('[WebViewFetcher] Invalid proxy URL:', proxyUrlStr);
      return;
    }

    try {
      connection.setAppHttpProxy({
        host: parsed.host,
        port: parsed.port,
        exclusionList: [],
      } as connection.HttpProxy);
      console.info('[WebViewFetcher] Proxy set: ' + parsed.host + ':' + parsed.port);
    } catch (e) {
      console.warn('[WebViewFetcher] Failed to set proxy:', (e as Error).message);
    }
  }

  /**
   * 解析代理 URL 为 host 和 port
   * 支持格式: "http://host:port", "host:port", "host"
   */
  private static parseProxyUrl(url: string): { host: string; port: number } | null {
    if (!url) return null;
    try {
      // 尝试标准 URL 解析（带协议头）
      let host = '';
      let port = 8080;
      const hasProto = /^https?:\/\//i.test(url);
      if (hasProto) {
        // 用简单字符串解析代替 URL class（ArkTS 兼容性）
        const withoutProto = url.replace(/^https?:\/\//i, '');
        const colonIdx = withoutProto.lastIndexOf(':');
        if (colonIdx > 0) {
          host = withoutProto.substring(0, colonIdx);
          port = parseInt(withoutProto.substring(colonIdx + 1)) || 8080;
        } else {
          host = withoutProto;
        }
      } else {
        const colonIdx = url.lastIndexOf(':');
        if (colonIdx > 0) {
          host = url.substring(0, colonIdx);
          port = parseInt(url.substring(colonIdx + 1)) || 8080;
        } else {
          host = url;
        }
      }
      return host ? { host, port } : null;
    } catch (_e) {
      return null;
    }
  }

  // ========== 统一配置入口 ==========

  /**
   * 统一配置 WebView 的网络设置（DNS + 代理）
   * 应与 NetUtil.configureFromSettings() 同时调用
   * @param dnsStr 逗号分隔的 DNS IP 列表
   * @param proxyUrlStr 代理 URL
   */
  static configureNetwork(dnsStr: string, proxyUrlStr: string): void {
    console.info('[WebViewFetcher] configureNetwork: dns=' + (dnsStr || '(empty)') + ' proxy=' + (proxyUrlStr || '(none)'));
    WebViewFetcher.configureDns(dnsStr);
    WebViewFetcher.configureProxy(proxyUrlStr);
  }

  // ========== 辅助方法 ==========

  /** 获取当前加载的 URL */
  static getCurrentUrl(): string {
    return WebViewFetcher.pendingUrl;
  }

  /** 检查是否已注册 */
  static isReady(): boolean {
    return WebViewFetcher.controller !== null;
  }

  /**
   * ArkWeb 会把 runJavaScript 的字符串结果再编码成 JSON 字符串。
   * 例如 outerHTML 返回 "\u003Chtml..."，需先反序列化后才能交给 HTML 解析器。
   */
  static decodeJavaScriptString(value: string): string {
    if (!value) return '';
    try {
      const decoded = JSON.parse(value) as unknown;
      return typeof decoded === 'string' ? decoded : value;
    } catch (_e) {
      return value;
    }
  }

  /**
   * 判断 HTML 是否已经包含小说详情/目录内容。
   *
   * 许多老站会把登录、注册和验证码表单隐藏在每个详情页里。仅凭
   * `searchcode.php`、`__17mb_input` 或 password input 会把这种正常页面
   * 错判为验证页。优先识别这些站点常见的详情容器，再决定是否需要交互。
   */
  static isLikelyBookDocumentHtml(html: string): boolean {
    if (!html) return false;
    const detailContainer = /<(?:article|main|section|div)\b[^>]*(?:id|class)=["'][^"']*(?:r_cons|r_tools|lastrecord|novel[_-]?list|book(?:info|[_-]?detail|[_-]?content)|chapter[_-]?list|catalog)[^"']*["']/i;
    if (detailContainer.test(html)) return true;

    // 兜底覆盖没有统一 class 命名的老站：页面同时有书籍标题、作者/简介/目录
    // 文案和书籍链接时，视为详情页，而不是独立登录页。
    const hasHeading = /<h[1-3]\b[^>]*>[\s\S]{1,300}<\/h[1-3]>/i.test(html);
    const hasBookLabel = /作者|简介|目录|最新章节|book\s*detail|novel\s*info/i.test(html);
    const hasBookLink = /href=["'][^"']*(?:bookbook|\/book(?:\/|[_-])|chapter|\/\d+\/\d+)[^"']*["']/i.test(html);
    return hasHeading && hasBookLabel && hasBookLink;
  }

  /**
   * 判断当前 DOM 是否仍停留在验证码/WAF 输入页。
   * 不能仅凭 challenge-platform/cloudflare 字样判断：很多正常页面也会加载 Cloudflare 统计脚本。
   */
  static isInteractiveChallengeHtml(html: string): boolean {
    if (!html) return true;
    // 图片验证码成功后，页面脚本甚至可能保留 Cloudflare/验证码相关脚本，
    // 但真实搜索结果已经出现；先识别结果，避免被脚本标记误判为未完成验证。
    const hasSearchResultMarkup = /<table\b[^>]*class=["'][^"']*\btable\b[^"']*["'][\s\S]*<tr\b[\s\S]*<td\b[\s\S]*<a\b[^>]*href=/i.test(html) ||
      /(?:book-coverlist|novel-row(?:-main)?|search[-_ ]?(?:item|result|row))/i.test(html);
    // 这些标记属于真正的 Cloudflare/WAF 挑战页。
    const hasStrongChallengeMarker = /_cf_chl_opt|cf-turnstile|cf-chl-widget|challenge-form|checking your browser|just a moment|cloudflare ray id|访问验证/i
      .test(html);
    if (hasStrongChallengeMarker && !hasSearchResultMarkup) return true;

    // 起点等站点的 WAF 会先返回一个很短的 probe.js 探针页，页面没有
    // Cloudflare 文案，也没有 onPageEnd 后的真实结果。若不识别它，校验会
    // 把探针页当成普通空搜索页，随后一直等待隐藏 WebView 超时。
    const hasProbeChallengeMarker = /(?:^|["'\/])(?:[A-Za-z0-9_-]+\/)?probe\.js(?:[?"'])/i.test(html) &&
      /\bbuid\s*=\s*["']f{8,}["']/i.test(html);
    if (hasProbeChallengeMarker && !hasSearchResultMarkup) return true;

    // 部分站点（如 zqb88.cn）使用 _guard/auto.js 做 JS 挑战：首次请求只返回
    // 一个极短的 <script src="/_guard/auto.js">，脚本执行后写入 Cookie 才
    // 能访问真实内容。这类页面没有书籍 DOM、没有 Cloudflare 文案，但内容
    // 极短且只有 guard 脚本引用，必须用交互/隐藏 WebView 完成 JS 验证。
    const hasGuardChallengeMarker = /<script\b[^>]*\bsrc\s*=\s*["'][^"']*\/_guard\/auto\.js["']/i.test(html) ||
      (html.length < 200 && /<script\b[^>]*\bsrc\s*=\s*["'][^"']*guard[^"']*\.js["']/i.test(html));
    if (hasGuardChallengeMarker && !hasSearchResultMarkup) return true;

    // searchcode.php 和 __17mb_input 也是一些老站隐藏登录/注册表单的字段，
    // 不能脱离页面上下文直接触发验证弹窗。详情页优先按普通页面处理；真正
    // 的挑战页通常没有书籍详情 DOM，或会带 challenge/captcha/verification 容器。
    const hasLegacyCaptchaMarker = /searchcode\.php|__17mb_input/i.test(html);
    const hasBookMarkup = WebViewFetcher.isLikelyBookDocumentHtml(html);
    // 图片验证码成功后，页面脚本可能仍保留 searchcode.php 和验证码代码，
    // 但搜索结果表格已经出现。此时应视为验证完成，否则“验证完成”按钮
    // 会永远把已成功的搜索页拦截掉。
    const hasChallengeContainer = /(?:id|class)=["'][^"']*(?:challenge|captcha|verification)[^"']*["']/i.test(html);
    if (hasLegacyCaptchaMarker && hasSearchResultMarkup) return false;
    if (hasLegacyCaptchaMarker && hasBookMarkup && !hasChallengeContainer) return false;
    if (hasLegacyCaptchaMarker && !hasBookMarkup) return true;

    // 不能仅凭“请输入验证码”判断挑战页：搬山人等站点会把注册表单
    // 隐藏在每个正常详情页中，注册表单也带有验证码占位文字。
    // 只有验证码输入控件/验证码图片与挑战表单同时出现时，才按普通
    // 验证码页处理；隐藏的登录/注册弹窗不触发交互验证。
    // 不能把脚本变量（如 smcaptchaStatus）或普通英文属性误当作页面文案。
    // 许多首页会预渲染登录二维码，HTML 中同时出现 captcha/code 字样，
    // 但页面并没有要求用户验证。真正的验证码页应有明确的提示文案，或
    // 配合下面严格的验证码控件标记出现。
    // 不使用裸 `code`：qrcode-img、code 属性等正常元素会造成误判。
    const hasCaptchaControl = /<(?:input|img|canvas)\b[^>]*(?:captcha|verification|verify|验证码|img[_-]?code)[^>]*>/i.test(html);
    const hasCaptchaText = /请输入验证码|验证码|verification\s*code/i.test(html) ||
      (/\bcaptcha\b/i.test(html) && hasCaptchaControl);
    if (!hasCaptchaText) return false;
    if (!hasCaptchaControl) return false;
    const hasHiddenLoginDialog = /<(?:form|div)\b[^>]*(?:login[_-]?regist|register_form|login_form)[^>]*>/i.test(html);
    if (hasHiddenLoginDialog && hasBookMarkup && !hasChallengeContainer) {
      return false;
    }
    return true;
  }

  // ========== 私有方法 ==========

  /** 开始轮询 document.readyState */
  private static startPolling(): void {
    WebViewFetcher.stopPolling();
    WebViewFetcher.pollIntervalId = setInterval(() => {
      if (!WebViewFetcher.controller || !WebViewFetcher.pendingResolve) {
        WebViewFetcher.stopPolling();
        return;
      }
      try {
      WebViewFetcher.controller.runJavaScript(
        'JSON.stringify({readyState: document.readyState, title: document.title})'
      ).then((json: string) => {
        try {
        const decoded = WebViewFetcher.decodeJavaScriptString(json);
        const state = JSON.parse(decoded) as { readyState: string; title: string };
        // readyState complete 可能只是 WAF 探针页，探针随后会触发重载。
        // 页面结束后稳定 1.5 秒再提取；若发生 onPageEnd，稳定窗口会重新计时。
        // onPageEnd 从未触发（lastPageEndAt === 0）时，页面加载满 3 秒且
        // readyState complete 也直接提取，避免控制器异常时挂到总超时。
        if (state.readyState === 'complete' && (
          (WebViewFetcher.lastPageEndAt > 0 &&
            Date.now() - WebViewFetcher.lastPageEndAt >= 1500) ||
          (WebViewFetcher.lastPageEndAt === 0 &&
            Date.now() - WebViewFetcher.fetchStartedAt >= 3000))) {
          console.info('[WebViewFetcher] readyState=complete, extracting');
          WebViewFetcher.clearTimers();
          WebViewFetcher.extractAndResolve();
        }
        } catch (_e) {
        // ignore parse errors
        }
      }).catch((_e: Error) => {
        console.warn('[WebViewFetcher] poll JS error (page probably closed)', _e.message);
        // 轮询 JS 失败说明页面/控制器已不可用：立即结算当前请求并处理队列，
        // 而不是挂到 startFetch 的总超时。
        WebViewFetcher.stopPolling();
        WebViewFetcher.clearTimers();
        const reject = WebViewFetcher.pendingReject;
        WebViewFetcher.pendingResolve = null;
        WebViewFetcher.pendingReject = null;
        WebViewFetcher.pendingController = null;
        if (reject) reject(new Error('WebView page closed: ' + _e.message));
        WebViewFetcher.processNext();
      });
      } catch (_e) {
        console.warn('[WebViewFetcher] poll runJS error (page closed)', (_e as Error).message);
        WebViewFetcher.stopPolling();
        WebViewFetcher.clearTimers();
        const reject = WebViewFetcher.pendingReject;
        WebViewFetcher.pendingResolve = null;
        WebViewFetcher.pendingReject = null;
        WebViewFetcher.pendingController = null;
        if (reject) reject(new Error('WebView page closed: ' + ((_e as Error).message || String(_e))));
        WebViewFetcher.processNext();
      }
    }, 500);
  }

  /** 停止轮询 */
  private static stopPolling(): void {
    if (WebViewFetcher.pollIntervalId >= 0) {
      clearInterval(WebViewFetcher.pollIntervalId);
      WebViewFetcher.pollIntervalId = -1;
    }
  }

  /** 取消所有待处理的 WebView 请求（页面退出时调用） */
  static cancelPending(): void {
    WebViewFetcher.stopPolling();
    WebViewFetcher.clearTimers();
    // 挂起的请求必须结算，否则调用方会一直等待一个永远不会 resolve 的 Promise。
    const reject = WebViewFetcher.pendingReject;
    WebViewFetcher.pendingResolve = null;
    WebViewFetcher.pendingReject = null;
    WebViewFetcher.pendingController = null;
    WebViewFetcher.controller = null;
    if (reject) reject(new Error('WebView cancelled'));
    // 清除等待注册的回调
    WebViewFetcher.readyWaiters = [];
    // 队列请求仍用新页面注册的控制器继续，这里不清理。
    WebViewFetcher.processNext();
  }

  /** 清除所有定时器 */
  private static clearTimers(): void {
    if (WebViewFetcher.timeoutId >= 0) {
      clearTimeout(WebViewFetcher.timeoutId);
      WebViewFetcher.timeoutId = -1;
    }
    WebViewFetcher.stopPolling();
  }

  private static normalizeNavigationUrl(url: string): string {
    return (url || '').replace(/#.*$/, '').replace(/\/$/, '');
  }

  private static navigationHost(url: string): string {
    const match = (url || '').match(/^https?:\/\/([^\/?#]+)/i);
    return match ? WebViewFetcher.normalizeNavigationHost_(match[1]) : '';
  }

  private static normalizeNavigationHost_(host: string): string {
    return (host || '').toLowerCase().replace(/:\d+$/, '').replace(/^www\./, '');
  }

  private static belongsToActiveNavigation(url: string): boolean {
    const normalized = WebViewFetcher.normalizeNavigationUrl(url);
    if (WebViewFetcher.activeNavigationUrls.has(normalized)) return true;
    const initialHost = WebViewFetcher.navigationHost(WebViewFetcher.initialRequestUrl);
    return !!initialHost && WebViewFetcher.navigationHost(url) === initialHost;
  }

  /** 提取 HTML 并 resolve Promise */
  private static extractAndResolve(): void {
    if (!WebViewFetcher.controller || !WebViewFetcher.pendingResolve) return;

    WebViewFetcher.clearTimers();

    const finalUrl = WebViewFetcher.pendingUrl;
    WebViewFetcher.controller.runJavaScript('document.documentElement.outerHTML')
      .then((html: string) => {
        const decodedHtml = WebViewFetcher.decodeJavaScriptString(html);
        const resolve = WebViewFetcher.pendingResolve;
        WebViewFetcher.pendingResolve = null;
        WebViewFetcher.pendingReject = null;
        WebViewFetcher.pendingController = null;
        WebViewFetcher.pendingAllowedRedirectHosts.clear();
        if (resolve) {
          console.info('[WebViewFetcher] Extracted', decodedHtml.length, 'chars from', finalUrl.substring(0, 60));
          resolve({ html: decodedHtml, finalUrl });
        }
        // 处理队列中的下一个请求
        WebViewFetcher.processNext();
      })
      .catch((err: Error) => {
        const reject = WebViewFetcher.pendingReject;
        WebViewFetcher.pendingResolve = null;
        WebViewFetcher.pendingReject = null;
        WebViewFetcher.pendingController = null;
        WebViewFetcher.pendingAllowedRedirectHosts.clear();
        if (reject) reject(err);
        WebViewFetcher.processNext();
      });
  }

  /**
   * WebView 组件销毁时调用：结算仍挂在旧控制器上的请求并清理全局状态，
   * 避免页面切换后遗留的 pending fetch 一直占用 WebView，导致后续请求
   * 排队等待甚至加载到已销毁的控制器上（表现为 loadUrl 后没有任何页面
   * 事件，直到总超时）。
   */
  static release(controller: web_webview.WebviewController): void {
    // 先结算属于该控制器的挂起请求（无论当前注册的是谁），让队列立即继续。
    if (WebViewFetcher.pendingController === controller && WebViewFetcher.pendingReject) {
      console.info('[WebViewFetcher] Releasing pending fetch for destroyed WebView');
      WebViewFetcher.clearTimers();
      const reject = WebViewFetcher.pendingReject;
      WebViewFetcher.pendingResolve = null;
      WebViewFetcher.pendingReject = null;
      WebViewFetcher.pendingController = null;
      WebViewFetcher.pendingAllowedRedirectHosts.clear();
      if (reject) reject(new Error('WebView page destroyed'));
      WebViewFetcher.processNext();
    }
    // 该控制器仍是当前注册的（新页面尚未注册）：置空让后续请求快速失败，
    // 而不是继续向已销毁的组件 loadUrl。
    if (WebViewFetcher.controller === controller) {
      WebViewFetcher.controller = null;
    }
  }

  /** 清理所有状态（页面销毁时调用） */
  static clearAll(): void {
    WebViewFetcher.clearTimers();
    WebViewFetcher.pendingResolve = null;
    WebViewFetcher.pendingReject = null;
    WebViewFetcher.pendingController = null;
    WebViewFetcher.pendingUrl = '';
    WebViewFetcher.activeNavigationUrls.clear();
    WebViewFetcher.pendingAllowedRedirectHosts.clear();
    WebViewFetcher.requestQueue = [];
    WebViewFetcher.controller = null;
    console.info('[WebViewFetcher] Cleared all state');
  }

  /** 处理队列中的下一个 WebView 请求 */
  private static processNext(): void {
    if (WebViewFetcher.requestQueue.length === 0) return;
    const next = WebViewFetcher.requestQueue.shift();
    if (!next) return;
    console.info('[WebViewFetcher] Processing next queued request');
    // ArkWeb may deliver the previous page's final onPageEnd after outerHTML extraction resolves.
    setTimeout(() => {
      WebViewFetcher.startFetch(next.url, next.timeoutMs, next.headers, next.allowedRedirectHosts)
        .then(next.resolve).catch(next.reject);
    }, 120);
  }
}
