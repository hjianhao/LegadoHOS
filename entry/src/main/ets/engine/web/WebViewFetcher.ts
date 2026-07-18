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

export class WebViewFetcher {
  private static controller: web_webview.WebviewController | null = null;
  private static pendingResolve: ((result: WebViewFetchResult) => void) | null = null;
  private static pendingReject: ((err: Error) => void) | null = null;
  private static pendingUrl: string = '';
  private static timeoutId: number = -1;
  // 追踪页面加载次数（处理重定向场景）
  private static loadCount: number = 0;
  /** 最近一次页面结束时间；重载时重置，用于避免过早提取 WAF 探针页。 */
  private static lastPageEndAt: number = 0;
  // 轮询定时器
  private static pollIntervalId: number = -1;
  // 请求队列：排队等待的 fetch（WebView 同时只能处理一个）
  private static requestQueue: Array<{
    url: string;
    timeoutMs: number;
    headers: Record<string, string>;
    resolve: (result: WebViewFetchResult) => void;
    reject: (err: Error) => void;
  }> = [];

  /** 与 Android Legado 后台 WebView 一致的默认桌面 UA。 */
  private static readonly DEFAULT_USER_AGENT: string =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /** 等待 controller 注册的回调列表（waitForReady 使用） */
  private static readyWaiters: Array<() => void> = [];
  /**
   * 交互式 Cloudflare 验证处理器
   * 页面启动时注册，当请求被 Cloudflare 拦截时弹出 WebView 让用户手动验证
   */
  static interactiveFetcher: ((url: string) => Promise<string>) | null = null;

  /** 交互式验证的 Promise resolve（由 CloudflareDialog 调用） */
  static interactiveResolve: ((html: string) => void) | null = null;

  /** 请求是否需要交互式验证 */
  static needsInteractive(url: string, errorMsg: string): boolean {
    return !!(WebViewFetcher.interactiveFetcher) &&
      (errorMsg.includes('403') || errorMsg.includes('Cloudflare') || errorMsg.includes('503') || errorMsg.includes('page not found'));
  }

  /** 弹出交互式 WebView 验证 */
  static async fetchInteractive(url: string): Promise<string> {
    if (!WebViewFetcher.interactiveFetcher) {
      throw new Error('Interactive fetcher not registered');
    }
    return await WebViewFetcher.interactiveFetcher(url);
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

    WebViewFetcher.loadCount++;
    WebViewFetcher.lastPageEndAt = Date.now();
    const currentUrl = event?.url || '';
    if (currentUrl) {
      WebViewFetcher.pendingUrl = currentUrl;
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
    headers: Record<string, string> = {}): Promise<WebViewFetchResult> {
    if (!WebViewFetcher.controller) {
      return Promise.reject(new Error('WebView not registered'));
    }

    // 如果上一个 fetch 还没完成，排队等待而不是拒绝
    if (WebViewFetcher.pendingReject) {
      console.info('[WebViewFetcher] Previous fetch still pending, queueing request');
      return new Promise((resolve, reject) => {
        WebViewFetcher.requestQueue.push({ url, timeoutMs, headers, resolve, reject });
      });
    }

    return WebViewFetcher.startFetch(url, timeoutMs, headers);
  }

  /** 实际的 fetch 逻辑 */
  private static startFetch(url: string, timeoutMs: number,
    headers: Record<string, string>): Promise<WebViewFetchResult> {
    return new Promise((resolve: (result: WebViewFetchResult) => void, reject: (err: Error) => void) => {
      WebViewFetcher.pendingResolve = resolve;
      WebViewFetcher.pendingReject = reject;
      WebViewFetcher.pendingUrl = url;
      WebViewFetcher.loadCount = 0;
      WebViewFetcher.lastPageEndAt = 0;
      WebViewFetcher.initialRequestUrl = url;
      WebViewFetcher.redirectCount = 0;

      // 设置总超时
      WebViewFetcher.timeoutId = setTimeout(() => {
        WebViewFetcher.clearTimers();
        WebViewFetcher.pendingResolve = null;
        WebViewFetcher.pendingReject = null;
        reject(new Error('WebView load timeout'));
        WebViewFetcher.processNext();
      }, timeoutMs);

      // 加载 URL
      console.info('[WebViewFetcher] Loading:', url.substring(0, 80));
      let userAgent = WebViewFetcher.DEFAULT_USER_AGENT;
      const webHeaders: Array<web_webview.WebHeader> = [];
      Object.keys(headers).forEach((key: string) => {
        if (key.toLowerCase() === 'user-agent') {
          userAgent = headers[key] || userAgent;
        } else {
          webHeaders.push({ headerKey: key, headerValue: headers[key] });
        }
      });
      WebViewFetcher.controller!.setCustomUserAgent(userAgent);
      WebViewFetcher.controller!.loadUrl(url, webHeaders);
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

    // 首次加载（与 fetch 传入的 URL 相同）不计为重定向
    if (url === WebViewFetcher.initialRequestUrl) {
      return false;
    }

    WebViewFetcher.redirectCount++;
    console.info('[WebViewFetcher] Redirect #' + WebViewFetcher.redirectCount + ' to:', url.substring(0, 60));

    if (WebViewFetcher.redirectCount > WebViewFetcher.maxRedirects) {
      console.warn('[WebViewFetcher] Too many redirects (' + WebViewFetcher.redirectCount + '), aborting');
      WebViewFetcher.clearTimers();
      const reject = WebViewFetcher.pendingReject;
      WebViewFetcher.pendingResolve = null;
      WebViewFetcher.pendingReject = null;
      if (reject) reject(new Error('Too many redirects: ' + WebViewFetcher.redirectCount));
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

  // ========== 私有方法 ==========

  /**
   * ArkWeb 会把 runJavaScript 的字符串结果再编码成 JSON 字符串。
   * 例如 outerHTML 返回 "\u003Chtml..."，需先反序列化后才能交给 HTML 解析器。
   */
  private static decodeJavaScriptString(value: string): string {
    if (!value) return '';
    try {
      const decoded = JSON.parse(value) as unknown;
      return typeof decoded === 'string' ? decoded : value;
    } catch (_e) {
      return value;
    }
  }

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
        if (state.readyState === 'complete' &&
          WebViewFetcher.lastPageEndAt > 0 && Date.now() - WebViewFetcher.lastPageEndAt >= 1500) {
          console.info('[WebViewFetcher] readyState=complete, extracting');
          WebViewFetcher.clearTimers();
          WebViewFetcher.extractAndResolve();
        }
        } catch (_e) {
        // ignore parse errors
        }
      }).catch((_e: Error) => {
        console.warn('[WebViewFetcher] poll JS error (page probably closed)', _e.message);
        WebViewFetcher.stopPolling();
      });
      } catch (_e) {
        console.warn('[WebViewFetcher] poll runJS error (page closed)', (_e as Error).message);
        WebViewFetcher.stopPolling();
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
    WebViewFetcher.controller = null;
    WebViewFetcher.pendingResolve = null;
    WebViewFetcher.pendingReject = null;
    // 清除等待注册的回调
    WebViewFetcher.readyWaiters = [];
  }

  /** 清除所有定时器 */
  private static clearTimers(): void {
    if (WebViewFetcher.timeoutId >= 0) {
      clearTimeout(WebViewFetcher.timeoutId);
      WebViewFetcher.timeoutId = -1;
    }
    WebViewFetcher.stopPolling();
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
        if (reject) reject(err);
        WebViewFetcher.processNext();
      });
  }

  /** 清理所有状态（页面销毁时调用） */
  static clearAll(): void {
    WebViewFetcher.clearTimers();
    WebViewFetcher.pendingResolve = null;
    WebViewFetcher.pendingReject = null;
    WebViewFetcher.pendingUrl = '';
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
    WebViewFetcher.startFetch(next.url, next.timeoutMs, next.headers).then(next.resolve).catch(next.reject);
  }
}
