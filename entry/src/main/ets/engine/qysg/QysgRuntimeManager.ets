/**
 * qysg ArkWeb 运行时注册表。
 *
 * qysg 书源依赖完整浏览器环境，不能复用 QuickJS 的同步 ScriptEngine。ArkUI
 * 组件负责提供 WebView，业务层只通过本管理器调用异步生命周期函数。
 */
import web_webview from '@ohos.web.webview';
import util from '@ohos.util';
import { AppDatabase } from '../../data/database/AppDatabase';
import { CacheTable } from '../../data/database/CacheTable';
import { BookSource } from '../../model/BookSource';
import { CookieStore } from '../../util/CookieStore';
import { NetUtil, NetUtilHttpResponse } from '../../util/NetUtil';
import { WebViewFetcher, WebViewInteractiveRequest } from '../web/WebViewFetcher';
import { resolveQysgSource, QysgSourceDefinition } from './QysgSourceCodec';

export interface QysgRuntimeHost {
  invoke(source: QysgSourceDefinition, method: string, args: Object[], isAborted?: () => boolean): Promise<string>;
}

interface PendingOperation {
  resolve: (value: string) => void;
  reject: (error: Error) => void;
}

/** qysg webview() 的一次受控请求。每个运行槽位只允许一个请求进入 ArkWeb，
 * 这样不会让不同书源的页面导航、脚本结果和 Cookie 状态相互覆盖。 */
interface QysgWebviewTask {
  url: string;
  js: string;
  html: string;
  body: string;
  headers: Record<string, string>;
  overrideUrlRegex: string;
  sourceUrlRegex: string;
  resolve: (value: string) => void;
  reject: (error: Error) => void;
}

interface QysgHttpResponse {
  method: string;
  body: string;
  headers: Record<string, string[]>;
  statusCode: number;
  statusMessage: string;
  data: string;
}

function jsonEnvelope(ok: boolean, value: Object | string | number | boolean | null, error: string = ''): string {
  return JSON.stringify({ ok: ok, value: value, error: error });
}

function encodeBase64(value: string): string {
  try {
    const bytes = new util.TextEncoder().encodeInto(value || '');
    return new util.Base64Helper().encodeToStringSync(bytes);
  } catch (_e) {
    return '';
  }
}

function encodeBytes(value: ArrayBuffer): string {
  try {
    return new util.Base64Helper().encodeToStringSync(new Uint8Array(value));
  } catch (_e) {
    return '';
  }
}

function encodeTextBytes(value: string): ArrayBuffer {
  try {
    const encoded = new util.TextEncoder().encodeInto(value || '');
    const copy = new Uint8Array(encoded.length);
    copy.set(encoded);
    return copy.buffer;
  } catch (_e) {
    return new ArrayBuffer(0);
  }
}

function isCloudflareChallengeResponse(response: NetUtilHttpResponse): boolean {
  const data = response.data || '';
  const headers = response.headers || {};
  const headerNames = Object.keys(headers).map((key: string): string => key.toLowerCase());
  const hasCloudflareHeader = headerNames.includes('cf-mitigated') || headerNames.includes('cf-ray');
  const hasExplicitChallengeHeader = Object.keys(headers).some((key: string): boolean => {
    if (key.toLowerCase() !== 'cf-mitigated') return false;
    return (headers[key] || []).some((value: string): boolean =>
      String(value || '').trim().toLowerCase() === 'challenge');
  });
  if (hasExplicitChallengeHeader ||
    ((response.statusCode === 403 || response.statusCode === 503) && hasCloudflareHeader)) {
    return true;
  }

  // 411 是服务端要求 Content-Length 的协议错误，不是 Cloudflare 挑战。
  // 旧版的通用 HTML 启发式会把其中的 WAF/JSD 脚本误认成挑战，从而在
  // 每次搜索（以及离开搜索页后的分页请求）打开验证 WebView。
  if (response.statusCode === 411) return false;

  // JSD 是 Cloudflare 注入正常 HTML 的不可见检测脚本；爱看小说的搜索/正文
  // 响应是 200，但 HTML 尾部同样带有 JSD 标记。只有显式挑战头、独立挑战
  // 标记或错误状态下才把它作为 Cloudflare 挑战，避免每次搜索都弹交互 WebView。
  const hasJsdMarker = /__CF\$cv\$params|cdn-cgi\/challenge-platform\/scripts\/jsd\/main\.js/i
    .test(data);
  const hasIndependentChallengeMarker = /_cf_chl_opt|cf-turnstile|cf-chl-widget|challenge-form|checking your browser|just a moment|cloudflare ray id|访问验证/i
    .test(data);
  const isSuccessfulHtmlResponse = response.statusCode >= 200 && response.statusCode < 400;
  if (hasJsdMarker && isSuccessfulHtmlResponse && !hasIndependentChallengeMarker) return false;
  if (!data.trim() || !WebViewFetcher.isInteractiveChallengeHtml(data)) return false;
  // 没有 Cloudflare 响应头时，仅接受正文中明确的挑战文案/控件；JSD
  // 静默脚本或普通错误页不能单独触发前台交互窗口。
  return hasCloudflareHeader || hasIndependentChallengeMarker;
}

function toQysgHttpResponse(response: NetUtilHttpResponse, method: string, data: string = response.data,
  statusCode: number = response.statusCode, statusMessage: string = response.statusMessage): QysgHttpResponse {
  const responseBody = data === response.data ? response.body : encodeTextBytes(data);
  return {
    method: method.toLowerCase(),
    body: encodeBytes(responseBody),
    headers: response.headers,
    statusCode: statusCode,
    statusMessage: statusMessage,
    data: data,
  };
}

function decodeBase64(value: string): string {
  try {
    let normalized = (value || '').replace(/-/g, '+').replace(/_/g, '/').replace(/\s/g, '');
    while (normalized.length % 4 !== 0) normalized += '=';
    const bytes = new util.Base64Helper().decodeSync(normalized);
    return new util.TextDecoder('utf-8', { fatal: false }).decodeToString(bytes);
  } catch (_e) {
    return '';
  }
}

function parseHeaders(value: Object): Record<string, string> {
  if (!value) return {};
  try {
    // 轻悦时光 Http.Get/Head/Post 会再次 stringify 已经是 JSON 字符串的
    // headers（企鹅阅读详情即如此），需要解开两层才能保留 Referer 等头。
    let parsed: Object | string = value;
    for (let depth = 0; depth < 3 && typeof parsed === 'string'; depth++) {
      parsed = JSON.parse(parsed as string) as Object | string;
    }
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return {};
    const out: Record<string, string> = {};
    Object.keys(parsed as Record<string, Object>).forEach((key: string): void => {
      const item = (parsed as Record<string, Object>)[key];
      if (typeof item === 'string') out[key] = item;
      else if (Array.isArray(item)) out[key] = item.join(', ');
      else if (item !== undefined && item !== null) out[key] = String(item);
    });
    return out;
  } catch (_e) {
    return {};
  }
}

/** qysg 的 htmlToText 兼容实现：保持换行，去除脚本/样式和其余标签。 */
function qysgHtmlToText(value: string): string {
  return (value || '')
    .replace(/<script\b[^<]*(?:(?!<\/script>)<[^<]*)*<\/script>/gi, '')
    .replace(/<style\b[^<]*(?:(?!<\/style>)<[^<]*)*<\/style>/gi, '')
    .replace(/<br\s*\/?\s*>/gi, '\n')
    .replace(/<[^>]+>/g, '')
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/gi, "'")
    .replace(/&lt;/gi, '<')
    .replace(/&gt;/gi, '>');
}

/** 从应用 rawfile 读取内置 jQuery；读取失败时仍由最小兼容层兜底。 */
function loadBundledQysgJquery(context: Context | null): string {
  if (!context) return '';
  try {
    const bytes = context.resourceManager.getRawFileContentSync('qysg/jquery-3.7.1.min.js');
    const script = new util.TextDecoder('utf-8', { fatal: false }).decodeToString(bytes);
    if (!script || script.indexOf('jQuery v3.7.1') < 0) {
      console.warn('[QysgRuntime] bundled jQuery resource is empty or unexpected');
      return '';
    }
    return script;
  } catch (error) {
    console.warn('[QysgRuntime] bundled jQuery load failed:', (error as Error).message);
    return '';
  }
}

/** 原生侧 qysg bridge。方法签名保留足够参数，适配 callHandler 的多参数调用。 */
export class QysgNativeBridge {
  private sourceUrl_: string = '';
  private sourceName_: string = '';
  private context_: Context | null;
  private pending_: Map<string, PendingOperation>;
  private emitResult_: (requestId: string, payload: string) => void;
  private webviewHandler_: ((args: Object[]) => Promise<string>) | null;
  private cookieEnabled_: boolean = true;
  /** 当前 qysg 生命周期调用名，用于区分搜索 POST 与正文/目录请求。 */
  private operation_: string = '';
  /** 同一生命周期内的目录分页可能并发撞上同一个 WAF；只允许一个验证窗口。 */
  private interactiveChallengePromise_: Promise<string> | null = null;
  /** 当前验证窗口对应的原始 URL；共享窗口后各请求仍需重放自己的 URL。 */
  private interactiveChallengeUrl_: string = '';
  /** 验证页已返回正常 HTML 后的短暂冷却，避免短结果列表触发第二次挑战。 */
  private interactiveVerificationAt_: number = 0;
  /** 页面离开后仍可能完成的旧搜索请求；此检查器禁止它再打开交互验证窗口。 */
  private isAborted_: (() => boolean) | null = null;

  constructor(context: Context | null, pending: Map<string, PendingOperation>,
    emitResult: (requestId: string, payload: string) => void,
    webviewHandler?: (args: Object[]) => Promise<string>) {
    this.context_ = context;
    this.pending_ = pending;
    this.emitResult_ = emitResult;
    this.webviewHandler_ = webviewHandler || null;
  }

  setSourceUrl(sourceUrl: string): void {
    this.sourceUrl_ = sourceUrl;
  }

  setSourceName(sourceName: string): void {
    this.sourceName_ = sourceName || '';
  }

  resetForSource(): void {
    this.sourceName_ = '';
    this.cookieEnabled_ = true;
    this.operation_ = '';
    this.interactiveChallengePromise_ = null;
    this.interactiveChallengeUrl_ = '';
    this.interactiveVerificationAt_ = 0;
    this.isAborted_ = null;
  }

  setOperation(operation: string): void {
    this.operation_ = (operation || '').toLowerCase();
  }

  setAbortChecker(isAborted?: () => boolean): void {
    this.isAborted_ = isAborted || null;
  }

  /** qysg JS → ArkTS：完成一个异步生命周期调用。 */
  async complete(operationId: string, ok: boolean, payload: string): Promise<string> {
    const pending = this.pending_.get(String(operationId));
    if (!pending) return '';
    this.pending_.delete(String(operationId));
    if (ok) pending.resolve(payload || '');
    else pending.reject(new Error(payload || 'qysg runtime error'));
    return '';
  }

  /** qysg JS → ArkTS：发起 flutter_inappwebview.callHandler(name, ...args)。
   *
   * ArkWeb 的同步 JavaScript Proxy 不能等待异步 ArkTS 返回值，异步 Proxy 又
   * 不会把返回值交给网页。因此这里同步启动任务，再由 emitResult_ 主动调用
   * 网页侧的 Promise 完成函数，保持 qysg 期望的 Future/Promise 语义。
  */
  callHandler(requestId: string, handler: string, a?: Object, b?: Object, c?: Object, d?: Object,
    e?: Object, f?: Object, g?: Object): void {
    const args: Object[] = [];
    [a, b, c, d, e, f, g].forEach((value: Object | undefined): void => {
      if (value !== undefined) args.push(value);
    });
    const id = String(requestId || '');
    console.info('[QysgBridge] call handler=' + handler + ' request=' + id);
    this.handle_(handler, args).then((value: Object | string | number | boolean | null): void => {
      this.emitResult_(id, jsonEnvelope(true, value));
    }, (error: Error): void => {
      const message = error instanceof Error ? error.message : String(error);
      this.emitResult_(id, jsonEnvelope(false, null, message));
    });
  }

  private async handle_(handler: string, args: Object[]): Promise<Object | string | number | boolean | null> {
    switch (handler) {
      case 'CookieJar':
        this.cookieEnabled_ = args.length === 0 || String(args[0]).toLowerCase() !== 'false';
        if (this.context_ && this.cookieEnabled_) await CookieStore.getInstance().init(this.context_);
        return true;
      case 'getsourceurl':
        return this.sourceUrl_;
      case 'getsearch':
        // qysg 约定：-1 表示不限制搜索内容类型，0/1/2 分别表示小说、
        // 音频、漫画。App 已在搜索页按书源类型筛选，桥接层不能固定返回 0，
        // 否则漫画源会被书源自身的 getsearch 类型判断直接返回空数组。
        return -1;
      case 'getWebViewUA':
        return 'Mozilla/5.0 (Linux; Android 12; HarmonyOS) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36';
      case 'device':
        return 'ohos';
      case 'version':
        return '0.0.0';
      case 'buildNumber':
        return 0;
      case 'log':
        console.info('[Qysg] ' + String(args[0] || ''));
        return true;
      case 'text':
        console.info('[Qysg][source-text:' + String(args[0] || '') + '] ' + String(args[1] || '').substring(0, 1000));
        return true;
      case 'showToast':
      case 'showLongToast':
        console.info('[Qysg][toast] ' + String(args[0] || ''));
        return true;
      case 'htmlToText':
        return qysgHtmlToText(String(args[0] || ''));
      case 'getLoginUser':
        return '';
      case 'getdurChapterIndex':
        return 0;
      case 'getReadBook':
        return null;
      case 'refreshContent':
      case 'refreshExplore':
      case 'setHtml':
      case 'showvideoplay':
      case 'startBrowserDpwithHtml':
      case 'voice':
      case 'showsvg':
        // 这些调用需要前台页面/媒体控制器。明确返回 false，避免源脚本把
        // “尚未实现”当成刷新、播放或 SVG 写入成功。
        console.warn('[QysgBridge] unsupported foreground handler=' + handler);
        return false;
      case 'getsvg':
      case 'addsvg':
        return [];
      case 'base64encode':
        return encodeBase64(String(args[0] || ''));
      case 'base64decode':
        return decodeBase64(String(args[0] || ''));
      case 'utf8ToGbkUrlEncoded':
        // qysg 书源会把该结果直接放入 GBK 表单的百分号编码中；不能用
        // encodeURIComponent（UTF-8），否则旧站会把关键词解码成乱码并返回空页。
        return NetUtil.encodeUrlComponent(String(args[0] || ''), 'gbk');
      case 'toSimplified':
      case 'toTraditional':
        // qysg 将这两个能力作为可选文本服务。HOS 尚未内置繁简转换库时，
        // 返回原文比返回空字符串更符合书源的降级预期。
        console.info('[QysgBridge] ' + handler + ' fallback: identity');
        return String(args[0] || '');
      case 'getWidth':
      case 'getHeight':
        return 0;
      case 'id':
        return '';
      case 'openurl':
      case 'startBrowser':
      case 'startBrowserWithShouldOverrideUrlLoading':
      case 'startBrowserDp':
      case 'back':
      case 'getVerificationCode':
      case 'addbook':
      case 'searchbook':
        // 这些动作需要前台 UI 或业务写操作。先明确返回“不支持”，避免
        // 书源误以为操作成功而继续提交付费/登录状态。
        console.warn('[QysgBridge] unsupported foreground handler=' + handler);
        return handler === 'back' ? false : '';
      case 'webview':
        if (!this.webviewHandler_) {
          throw new Error('qysg webview bridge unavailable');
        }
        return await this.webviewHandler_(args);
      case 'webviewajax':
        if (!this.webviewHandler_) {
          throw new Error('qysg webview bridge unavailable');
        }
        // webViewGetAjax(url, html, body, header, ajaxRegex) 与普通 webview
        // 的参数顺序不同，统一转换为 webview 队列的七参数形式；没有可用的
        // ArkWeb 请求拦截回调时，队列会至少返回加载后的 DOM，并按正则提取。
        return await this.webviewHandler_([
          args.length > 0 ? args[0] : '', '',
          args.length > 1 ? args[1] : '', args.length > 2 ? args[2] : '',
          args.length > 3 ? args[3] : '', args.length > 4 ? args[4] : '', '']);
      case 'cache.get':
        return await this.cacheGet_(String(args[0] || ''), false);
      case 'cache.set':
        await this.cacheSet_(String(args[0] || ''), String(args[1] || ''), false);
        return true;
      case 'cache.remove':
        await this.cacheRemove_(String(args[0] || ''), false);
        return true;
      case 'cache.allget':
        return await this.cacheGet_(String(args[0] || ''), true);
      case 'cache.allset':
        await this.cacheSet_(String(args[0] || ''), String(args[1] || ''), true);
        return true;
      case 'cache.allremove':
        await this.cacheRemove_(String(args[0] || ''), true);
        return true;
      case 'cookie.get':
        return CookieStore.getInstance().getCookie(String(args[0] || ''));
      case 'cookie.set':
        await CookieStore.getInstance().setCookie(String(args[0] || ''), String(args[1] || ''));
        return true;
      case 'cookie.remove':
        await CookieStore.getInstance().removeCookie(String(args[0] || ''));
        return true;
      case 'cookie.setcookie':
        await this.setSingleCookie_(String(args[0] || ''), String(args[1] || ''), String(args[2] || ''));
        return true;
      case 'cookie.getCookie':
        return this.getSingleCookie_(String(args[0] || ''), String(args[1] || ''));
      case 'http':
        return await this.http_(args);
      default:
        throw new Error('unsupported qysg bridge: ' + handler);
    }
  }

  private cacheKey_(key: string, shared: boolean): string {
    return (shared ? 'qysg:shared:' : 'qysg:' + this.sourceUrl_ + ':') + key;
  }

  private async cacheGet_(key: string, shared: boolean): Promise<string | null> {
    await AppDatabase.getInstance().waitForInit();
    return await new CacheTable(AppDatabase.getInstance().rdbStore).get(this.cacheKey_(key, shared));
  }

  private async cacheSet_(key: string, value: string, shared: boolean): Promise<void> {
    await AppDatabase.getInstance().waitForInit();
    await new CacheTable(AppDatabase.getInstance().rdbStore).put(this.cacheKey_(key, shared), value);
  }

  private async cacheRemove_(key: string, shared: boolean): Promise<void> {
    await AppDatabase.getInstance().waitForInit();
    await new CacheTable(AppDatabase.getInstance().rdbStore).remove(this.cacheKey_(key, shared));
  }

  private async setSingleCookie_(url: string, key: string, value: string): Promise<void> {
    const store = CookieStore.getInstance();
    const old = store.getCookie(url);
    const pairs: Record<string, string> = {};
    old.split(';').forEach((part: string): void => {
      const index = part.indexOf('=');
      if (index > 0) pairs[part.substring(0, index).trim()] = part.substring(index + 1).trim();
    });
    pairs[key] = value;
    const header = Object.keys(pairs).map((name: string): string => name + '=' + pairs[name]).join('; ');
    await store.setCookie(url, header);
  }

  private getSingleCookie_(url: string, key: string): string {
    const raw = CookieStore.getInstance().getCookie(url);
    const match = raw.match(new RegExp('(?:^|;\\s*)' + key.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&') + '=([^;]*)'));
    return match ? match[1] : '';
  }

  private async http_(args: Object[]): Promise<QysgHttpResponse> {
    const method = String(args[0] || 'get').toUpperCase();
    const url = String(args[1] || '');
    const body = String(args[2] || '');
    const headers = parseHeaders(args[3]);
    const contentType = String(args[5] || '');
    const followRedirects = args.length < 5 || String(args[4]).toLowerCase() !== 'false';
    if (contentType && !headers['Content-Type'] && !headers['content-type']) {
      headers['Content-Type'] = contentType;
    }
    if (!this.cookieEnabled_) headers['X-Legado-Disable-Cookie'] = '1';
    if (this.isAborted_ && this.isAborted_()) {
      console.info('[QysgBridge] skip aborted ' + method + ' ' + url);
      return {
        method: method.toLowerCase(), body: '', headers: {}, statusCode: 499,
        statusMessage: 'Canceled', data: ''
      };
    }
    console.info('[QysgBridge] http ' + method + ' ' + url + ' follow=' + followRedirects);
    const response = await NetUtil.httpDetailed(method, url, body, headers,
      NetUtil.getDefaultTimeout(), followRedirects);
    console.info('[QysgBridge] http done status=' + response.statusCode +
      ' bytes=' + response.data.length.toString());
    if (response.statusCode === 411) {
      console.warn('[QysgBridge] HTTP 411 is not a Cloudflare challenge; skip interactive WebView');
    }
    return await this.resolveInteractiveChallenge_(response, method, url, body, headers, followRedirects);
  }

  /**
   * qysg 的 Http.Get/Post 不经过 SourceExecutor，原先会把 Cloudflare 403
   * 原样交给书源脚本；大多数 qysg 脚本随后 catch 并返回空数组，界面看起来
   * 就像“搜索没有结果”。复用全局交互 WebView 完成挑战，并把用户验证后
   * 的页面作为本次 HTTP 响应交回 qysg 解析器。
   */
  private async resolveInteractiveChallenge_(response: NetUtilHttpResponse, method: string,
    url: string, body: string, headers: Record<string, string>, followRedirects: boolean): Promise<QysgHttpResponse> {
    if (this.isAborted_ && this.isAborted_()) {
      console.info('[QysgBridge] skip interactive challenge for aborted ' + method + ' ' + url);
      return toQysgHttpResponse(response, method);
    }
    if (!isCloudflareChallengeResponse(response) || !WebViewFetcher.interactiveFetcher) {
      return toQysgHttpResponse(response, method);
    }

    // 搜索结果较少时 ArkUI 的 onReachEnd 可能在第一页完成后立即请求下一页。
    // 第一版主的验证 cookie 在 ArkWeb/原生请求之间并不总能即时同步；如果刚
    // 完成过一次验证就再次遇到挑战，不应立刻再弹一个完全相同的窗口。先给
    // 原生请求一次机会，仍是挑战时返回当前响应，让分页自然结束。
    const verificationCooldownMs = 30 * 1000;
    const recentlyVerified = this.operation_ === 'search' &&
      this.interactiveVerificationAt_ > 0 &&
      Date.now() - this.interactiveVerificationAt_ < verificationCooldownMs;
    if (recentlyVerified && !this.interactiveChallengePromise_) {
      console.info('[QysgBridge] Reusing recent search verification; skip duplicate WebView');
      try {
        const retried = await NetUtil.httpDetailed(method, url, body, headers,
          NetUtil.getDefaultTimeout(), followRedirects);
        if (!isCloudflareChallengeResponse(retried)) {
          console.info('[QysgBridge] Cloudflare cleared on retry after recent verification; bytes=' +
            retried.data.length.toString());
          return toQysgHttpResponse(retried, method);
        }
      } catch (retryError) {
        console.warn('[QysgBridge] retry after recent verification failed: ' +
          ((retryError as Error).message || String(retryError)));
      }
      return toQysgHttpResponse(response, method);
    }

    // qysg HTTP 请求会在验证后由此处重放；使用 challenge 模式只回填表单，
    // 避免交互窗口先自动提交一次、随后原生重放再次触发站点限频。
    const purpose = 'challenge';
    const request: WebViewInteractiveRequest | undefined = method === 'POST' ?
      { method: 'POST', body: body } : undefined;
    console.warn('[QysgBridge] Interactive WebView request source=' + this.sourceName_ +
      ' stage=' + (this.operation_ || 'unknown') +
      ' reason=cloudflare-challenge purpose=' + purpose + ' url=' + url);
    try {
      let interactiveHtml: string = '';
      let verificationUrl = url;
      if (this.interactiveChallengePromise_) {
        verificationUrl = this.interactiveChallengeUrl_ || url;
        console.info('[QysgBridge] Reusing active Cloudflare verification window for ' + url);
        interactiveHtml = await this.interactiveChallengePromise_;
      } else {
        this.interactiveChallengeUrl_ = url;
        const pending = WebViewFetcher.fetchInteractive(url, purpose,
          this.operation_ === 'search' ? '搜索需要完成 Cloudflare 验证' : '页面需要完成 Cloudflare 验证', request);
        this.interactiveChallengePromise_ = pending;
        pending.then((): void => {
          if (this.interactiveChallengePromise_ === pending) {
            this.interactiveChallengePromise_ = null;
            this.interactiveChallengeUrl_ = '';
          }
        }, (): void => {
          if (this.interactiveChallengePromise_ === pending) {
            this.interactiveChallengePromise_ = null;
            this.interactiveChallengeUrl_ = '';
          }
        });
        interactiveHtml = await pending;
      }
      if (this.isAborted_ && this.isAborted_()) {
        console.info('[QysgBridge] verification finished for an aborted ' + method + '; skip replay');
        return toQysgHttpResponse(response, method);
      }
      if (interactiveHtml && !WebViewFetcher.isInteractiveChallengeHtml(interactiveHtml)) {
        this.interactiveVerificationAt_ = Date.now();
        console.info('[QysgBridge] Cloudflare verification completed; duplicate-window cooldown started');
      }
      // 验证窗口可能由目录第一页打开，但其余分页也会同时收到 403。验证结束
      // 后每个请求都重放自己的原始 URL/POST body，不能直接把第一页的 HTML
      // 当作其它分页的响应，否则目录会被截断或章节链接串页。
      try {
        const retried = await NetUtil.httpDetailed(method, url, body, headers,
          NetUtil.getDefaultTimeout(), followRedirects);
        if (!isCloudflareChallengeResponse(retried)) {
          console.info('[QysgBridge] Cloudflare cleared; replayed qysg ' + method.toUpperCase() +
            ' bytes=' + retried.data.length.toString());
          return toQysgHttpResponse(retried, method);
        }
        console.warn('[QysgBridge] qysg ' + method.toUpperCase() + ' replay still returned a Cloudflare challenge');
      } catch (retryError) {
        console.warn('[QysgBridge] qysg ' + method.toUpperCase() + ' replay failed: ' +
          ((retryError as Error).message || String(retryError)));
      }
      // 只有真正发起验证的请求才可使用验证窗口提取到的 HTML；共享窗口的其它
      // 请求若重放仍失败，应保留各自的挑战响应，不能错误复用别页正文。
      if (url === verificationUrl && interactiveHtml && !WebViewFetcher.isInteractiveChallengeHtml(interactiveHtml)) {
        console.info('[QysgBridge] interactive WebView returned bytes=' + interactiveHtml.length.toString());
        return toQysgHttpResponse(response, method, interactiveHtml, 200, 'OK');
      }
      console.warn('[QysgBridge] interactive WebView closed before challenge completed');
    } catch (error) {
      console.warn('[QysgBridge] interactive Cloudflare verification failed: ' +
        ((error as Error).message || String(error)));
    }
    // 验证未完成（用户关闭窗口/排队超时/批量校验无人验证）时，不再把挑战页
    // HTML 原样交给书源脚本：脚本多半会解析出 null 并抛出含义不明的
    // TypeError（如 null['更多设置']）。抛出明确错误让校验/阅读界面能直接
    // 报告“需要 Cloudflare 验证”，而不是一串源页面内部的崩溃栈。
    throw new Error('Cloudflare 验证未完成，请求被拦截：' + url);
  }
}

export class QysgRuntimeManager {
  private static hosts_: QysgRuntimeHost[] = [];

  static registerHost(host: QysgRuntimeHost): void {
    if (QysgRuntimeManager.hosts_.indexOf(host) < 0) {
      QysgRuntimeManager.hosts_.push(host);
      console.info('[QysgRuntime] host registered, count=' + QysgRuntimeManager.hosts_.length);
    }
  }

  static unregisterHost(host: QysgRuntimeHost): void {
    QysgRuntimeManager.hosts_ = QysgRuntimeManager.hosts_.filter((item: QysgRuntimeHost): boolean => item !== host);
    console.info('[QysgRuntime] host unregistered, count=' + QysgRuntimeManager.hosts_.length);
  }

  static hasHost(): boolean {
    return QysgRuntimeManager.hosts_.length > 0;
  }

  static async invoke(source: BookSource, method: string, args: Object[],
    isAborted?: () => boolean): Promise<string> {
    console.info('[QysgRuntime] invoke requested source=' + source.sourceName + ' method=' + method);
    // enabled 只控制搜索/发现等主动找书操作。书架中的已有书籍仍需
    // 使用其保存的书源读取详情、目录和正文，即使用户后来停用了该书源。
    // 搜索入口会通过 QysgSourceAdapter.canSearch/canExplore 过滤停用源；
    // 这里也保留运行时兜底，但不能把 info/chapter/content 一概拦截。
    const isReadOperation = method === 'info' || method === 'chapter' || method === 'content';
    if (!source.enabled && !isReadOperation) throw new Error('书源未启用');
    if (isAborted && isAborted()) throw new Error('qysg operation cancelled');
    // qysg 书源的 html 可能是一个或多个远程镜像地址。先解析成真正的脚本，
    // 再交给隐藏 WebView；否则 loadData 会把 URL 文本当成 HTML，所有生命周期
    // 函数都会缺失。
    const definition = await resolveQysgSource(source);
    // 页面切换期间旧页面的隐藏 WebView 可能尚未完成 aboutToDisappear；
    // 优先使用最近注册的运行槽位，避免正文请求误复用搜索页的控制器。
    let host = QysgRuntimeManager.hosts_[QysgRuntimeManager.hosts_.length - 1];
    // 页面生命周期中 aboutToAppear 可能早于 WebView.onControllerAttached，给隐藏
    // WebView 一个短暂的注册窗口，避免首次搜索/发现请求无谓失败。
    for (let attempt = 0; !host && attempt < 100; attempt++) {
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 100);
      });
      host = QysgRuntimeManager.hosts_[QysgRuntimeManager.hosts_.length - 1];
    }
    if (!host) {
      console.error('[QysgRuntime] no host after waiting');
      throw new Error('qysg WebView 运行时未就绪，请返回应用主页后重试');
    }
    console.info('[QysgRuntime] dispatching to host method=' + method);
    return await host.invoke(definition, method, args, isAborted);
  }
}

/** qysg 隐藏 WebView。挂载该组件即可让业务层获得一个运行槽位。 */
@Component
export struct QysgRuntimeHostComponent {
  private controller_: web_webview.WebviewController = new web_webview.WebviewController();
  /** qysg webview() 使用独立控制器，不能导航主运行页，否则会销毁源脚本。 */
  private webviewController_: web_webview.WebviewController = new web_webview.WebviewController();
  private controllerAttached_: boolean = false;
  private webviewControllerAttached_: boolean = false;
  private activeSourceKey_: string = '';
  private activeSourceUrl_: string = '';
  private readyPromise_: Promise<void> | null = null;
  private readyResolve_: (() => void) | null = null;
  private readyReject_: ((error: Error) => void) | null = null;
  private queue_: Promise<void> = Promise.resolve();
  private operationId_: number = 0;
  private pending_: Map<string, PendingOperation> = new Map();
  private bridge_: QysgNativeBridge | null = null;
  private hostRegistered_: boolean = false;
  private webviewQueue_: QysgWebviewTask[] = [];
  private activeWebviewTask_: QysgWebviewTask | null = null;
  private webviewEvaluateTimer_: number = -1;
  private webviewTimeoutTimer_: number = -1;
  private webviewStartedAt_: number = 0;
  private webviewPageEndAt_: number = 0;
  private webviewEvaluateAttempts_: number = 0;
  private webviewLastValue_: string = '';
  private webviewStableCount_: number = 0;

  private static readonly QYSG_WEBVIEW_TIMEOUT_MS: number = 30000;
  private static readonly QYSG_WEBVIEW_STABLE_WAIT_MS: number = 1200;
  private static readonly QYSG_WEBVIEW_MIN_STABLE_MS: number = 2400;
  private static readonly QYSG_WEBVIEW_RETRY_MS: number = 400;
  private static readonly QYSG_WEBVIEW_SCRIPT_WAIT_MS: number = 9000;

  aboutToDisappear(): void {
    if (this.hostRegistered_) QysgRuntimeManager.unregisterHost(this);
    this.hostRegistered_ = false;
    this.pending_.forEach((pending: PendingOperation): void => pending.reject(new Error('qysg runtime closed')));
    this.pending_.clear();
    this.rejectAllWebviewTasks_(new Error('qysg webview runtime closed'));
  }

  build() {
    Column() {
      Web({ src: '', controller: this.controller_ })
        .width('100%').height('100%')
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .mixedMode(MixedMode.All)
        .onControllerAttached((): void => {
          this.controllerAttached_ = true;
          console.info('[QysgRuntime] WebView controller attached');
          this.bridge_ = new QysgNativeBridge(this.getUIContext().getHostContext() || null, this.pending_,
            (requestId: string, payload: string): void => this.completeBridgeCall_(requestId, payload),
            (args: Object[]): Promise<string> => this.enqueueWebview_(args));
          try {
            // callHandler 必须注册为同步方法：qysg 的桥接 shim 需要拿到它返回的
            // Promise 并继续 .then()。ArkWeb 的 asyncMethodList 明确不返回值，若
            // 把 callHandler 放进去，网页端会得到 undefined，所有 HTTP/缓存调用
            // 都会报“...then is not a function”。complete 只负责回调 pending，
            // 不需要返回值，放在异步列表即可。
            this.controller_.registerJavaScriptProxy(this.bridge_!, 'qysgNative', ['callHandler'], ['complete']);
          } catch (error) {
            console.error('[Qysg] registerJavaScriptProxy failed:', error);
          }
          if (!this.hostRegistered_) {
            QysgRuntimeManager.registerHost(this);
            this.hostRegistered_ = true;
          }
        })
        .onPageEnd((): void => {
          console.info('[QysgRuntime] qysg page ready source=' + this.activeSourceUrl_);
          if (this.readyResolve_) {
            const resolve = this.readyResolve_;
            this.readyResolve_ = null;
            this.readyReject_ = null;
            resolve();
          }
        })
        .onErrorReceive((): void => {
          console.error('[QysgRuntime] qysg page load error');
          if (this.readyReject_) {
            const reject = this.readyReject_;
            this.readyResolve_ = null;
            this.readyReject_ = null;
            reject(new Error('qysg WebView 加载失败'));
          }
        });
      // qysg 的 webview()/webViewGetSource() 需要在不破坏主运行脚本的前提下
      // 访问另一个页面并执行 DOM JavaScript，因此使用第二个隐藏 WebView。
      Web({ src: '', controller: this.webviewController_ })
        .width('100%').height('100%')
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .mixedMode(MixedMode.All)
        .onControllerAttached((): void => {
          this.webviewControllerAttached_ = true;
          console.info('[QysgRuntime] webview controller attached');
          this.processNextWebviewTask_();
        })
        .onPageEnd((): void => {
          this.onWebviewPageEnd_();
        })
        .onErrorReceive((): void => {
          this.finishWebviewTask_(null, new Error('qysg webview 页面加载失败'));
        });
    }
    .width(1).height(1)
    .constraintSize({ minWidth: 1, minHeight: 1 })
    // Visibility.None 会将 Web 组件从渲染树中移除，在部分系统版本上不会触发
    // onControllerAttached/onPageEnd，导致运行时注册成功但搜索请求立即返回空结果。
    // Hidden 保留组件生命周期，同时不在界面上显示。
    .visibility(Visibility.Hidden);
  }

  private completeBridgeCall_(requestId: string, payload: string): void {
    const script = 'window.__qysgBridgeComplete&&window.__qysgBridgeComplete(' +
      JSON.stringify(requestId) + ',' + JSON.stringify(payload) + ');';
    this.controller_.runJavaScript(script).catch((error: Error): void => {
      console.error('[QysgBridge] complete callback failed: ' + String(error));
    });
  }

  /** 将 qysg webview(url, js, html, body, header, ...) 排队到独立 WebView。 */
  private enqueueWebview_(args: Object[]): Promise<string> {
    return new Promise<string>((resolve: (value: string) => void,
      reject: (error: Error) => void): void => {
      const task: QysgWebviewTask = {
        url: String(args[0] || ''),
        js: String(args[1] || '').trim(),
        html: String(args[2] || ''),
        body: String(args[3] || ''),
        headers: parseHeaders(args.length > 4 ? args[4] : ''),
        overrideUrlRegex: String(args[5] || ''),
        sourceUrlRegex: String(args[6] || ''),
        resolve: resolve,
        reject: reject,
      };
      if (!task.url && !task.html) {
        reject(new Error('qysg webview 缺少 URL 和 HTML'));
        return;
      }
      this.webviewQueue_.push(task);
      console.info('[QysgRuntime] webview queued url=' + task.url.substring(0, 120) +
        ' js=' + (task.js ? 'yes' : 'no'));
      this.processNextWebviewTask_();
    });
  }

  private async processNextWebviewTask_(): Promise<void> {
    if (this.activeWebviewTask_ || this.webviewQueue_.length === 0) return;
    const task = this.webviewQueue_.shift();
    if (!task) return;
    this.activeWebviewTask_ = task;
    this.webviewStartedAt_ = Date.now();
    this.webviewPageEndAt_ = 0;
    this.webviewEvaluateAttempts_ = 0;
    this.webviewLastValue_ = '';
    this.webviewStableCount_ = 0;
    try {
      for (let attempt = 0; !this.webviewControllerAttached_ && attempt < 100; attempt++) {
        await new Promise<void>((resolve: () => void): void => {
          setTimeout(resolve, 50);
        });
      }
      if (!this.webviewControllerAttached_) {
        throw new Error('qysg webview 控制器尚未绑定');
      }
      this.webviewTimeoutTimer_ = setTimeout((): void => {
        this.finishWebviewTask_(null, new Error('qysg webview 超时'));
      }, QysgRuntimeHostComponent.QYSG_WEBVIEW_TIMEOUT_MS);

      const webHeaders: Array<web_webview.WebHeader> = [];
      let userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36';
      Object.keys(task.headers).forEach((key: string): void => {
        if (key.toLowerCase() === 'user-agent') {
          if (task.headers[key]) userAgent = task.headers[key];
        } else {
          const webHeader: web_webview.WebHeader = {
            headerKey: key,
            headerValue: task.headers[key],
          };
          webHeaders.push(webHeader);
        }
      });
      this.webviewController_.setCustomUserAgent(userAgent);

      if (task.html) {
        this.webviewController_.loadData(task.html, 'text/html', 'UTF-8', task.url || 'about:blank');
      } else if (task.body) {
        // ArkWeb Controller 没有统一的带 body loadUrl API。先用同一网络策略
        // 获取 POST 响应，再以原 URL 作为 baseUrl 装载，仍保留页面脚本和 DOM。
        const pageHtml = await NetUtil.httpPost(task.url, task.body, task.headers);
        this.webviewController_.loadData(pageHtml, 'text/html', 'UTF-8', task.url);
      } else {
        this.webviewController_.loadUrl(task.url, webHeaders);
      }
      console.info('[QysgRuntime] webview loading url=' + task.url.substring(0, 120));
    } catch (error) {
      this.finishWebviewTask_(null, error instanceof Error ? error : new Error(String(error)));
    }
  }

  private onWebviewPageEnd_(): void {
    if (!this.activeWebviewTask_) return;
    this.webviewPageEndAt_ = Date.now();
    if (this.webviewEvaluateTimer_ >= 0) clearTimeout(this.webviewEvaluateTimer_);
    this.webviewEvaluateTimer_ = setTimeout((): void => {
      this.evaluateWebviewTask_();
    }, QysgRuntimeHostComponent.QYSG_WEBVIEW_STABLE_WAIT_MS);
  }

  private async evaluateWebviewTask_(): Promise<void> {
    const task = this.activeWebviewTask_;
    if (!task) return;
    this.webviewEvaluateTimer_ = -1;
    this.webviewEvaluateAttempts_++;
    const script = task.js || 'document.documentElement ? document.documentElement.outerHTML : ""';
    try {
      const raw = await this.webviewController_.runJavaScript(script);
      let value = this.decodeWebviewValue_(raw);
      if (value === this.webviewLastValue_) {
        this.webviewStableCount_++;
      } else {
        this.webviewLastValue_ = value;
        this.webviewStableCount_ = 1;
      }
      if (task.js && !value.trim() &&
        Date.now() - this.webviewStartedAt_ < QysgRuntimeHostComponent.QYSG_WEBVIEW_SCRIPT_WAIT_MS) {
        this.webviewEvaluateTimer_ = setTimeout((): void => {
          this.evaluateWebviewTask_();
        }, QysgRuntimeHostComponent.QYSG_WEBVIEW_RETRY_MS);
        return;
      }
      // qysg 源经常在 onPageEnd 后通过 XMLHttpRequest/定时器补齐目录。不能
      // 看到静态 HTML 中的首个章节就立即完成，否则动态目录会被截成 1~2 章。
      // 至少等待一个稳定窗口，并要求连续两次结果一致；结果发生变化时重新
      // 计数，最长仍受脚本等待上限约束。
      if (task.js && Date.now() - this.webviewStartedAt_ <
        QysgRuntimeHostComponent.QYSG_WEBVIEW_MIN_STABLE_MS &&
        Date.now() - this.webviewStartedAt_ < QysgRuntimeHostComponent.QYSG_WEBVIEW_SCRIPT_WAIT_MS) {
        this.webviewEvaluateTimer_ = setTimeout((): void => {
          this.evaluateWebviewTask_();
        }, QysgRuntimeHostComponent.QYSG_WEBVIEW_RETRY_MS);
        return;
      }
      if (task.js && this.webviewStableCount_ < 2 &&
        Date.now() - this.webviewStartedAt_ < QysgRuntimeHostComponent.QYSG_WEBVIEW_SCRIPT_WAIT_MS) {
        this.webviewEvaluateTimer_ = setTimeout((): void => {
          this.evaluateWebviewTask_();
        }, QysgRuntimeHostComponent.QYSG_WEBVIEW_RETRY_MS);
        return;
      }
      value = this.applyWebviewRegex_(value, task.overrideUrlRegex || task.sourceUrlRegex);
      console.info('[QysgRuntime] webview completed bytes=' + value.length +
        ' attempts=' + this.webviewEvaluateAttempts_);
      this.finishWebviewTask_(value, null);
    } catch (error) {
      if (Date.now() - this.webviewStartedAt_ < QysgRuntimeHostComponent.QYSG_WEBVIEW_SCRIPT_WAIT_MS) {
        this.webviewEvaluateTimer_ = setTimeout((): void => {
          this.evaluateWebviewTask_();
        }, QysgRuntimeHostComponent.QYSG_WEBVIEW_RETRY_MS);
        return;
      }
      this.finishWebviewTask_(null, error instanceof Error ? error : new Error(String(error)));
    }
  }

  private decodeWebviewValue_(raw: Object): string {
    if (raw === undefined || raw === null) return '';
    const text = String(raw);
    try {
      const decoded: string = JSON.parse(text) as string;
      if (typeof decoded === 'string') return decoded;
      return text;
    } catch (_e) {
      return text;
    }
  }

  private applyWebviewRegex_(value: string, regex: string): string {
    if (!regex || !value) return value;
    try {
      const match = value.match(new RegExp(regex));
      if (!match) return value;
      return String(match[1] || match[0] || value);
    } catch (error) {
      console.warn('[QysgRuntime] invalid webview regex:', String(error));
      return value;
    }
  }

  private finishWebviewTask_(value: string | null, error: Error | null): void {
    const task = this.activeWebviewTask_;
    if (!task) return;
    if (this.webviewTimeoutTimer_ >= 0) clearTimeout(this.webviewTimeoutTimer_);
    if (this.webviewEvaluateTimer_ >= 0) clearTimeout(this.webviewEvaluateTimer_);
    this.webviewTimeoutTimer_ = -1;
    this.webviewEvaluateTimer_ = -1;
    this.activeWebviewTask_ = null;
    if (error) {
      console.error('[QysgRuntime] webview failed:', error.message);
      task.reject(error);
    } else {
      task.resolve(value || '');
    }
    setTimeout((): void => {
      this.processNextWebviewTask_();
    }, 0);
  }

  private rejectAllWebviewTasks_(error: Error): void {
    if (this.webviewTimeoutTimer_ >= 0) clearTimeout(this.webviewTimeoutTimer_);
    if (this.webviewEvaluateTimer_ >= 0) clearTimeout(this.webviewEvaluateTimer_);
    this.webviewTimeoutTimer_ = -1;
    this.webviewEvaluateTimer_ = -1;
    const active = this.activeWebviewTask_;
    this.activeWebviewTask_ = null;
    if (active) active.reject(error);
    this.webviewQueue_.forEach((task: QysgWebviewTask): void => task.reject(error));
    this.webviewQueue_ = [];
  }

  invoke(source: QysgSourceDefinition, method: string, args: Object[],
    isAborted?: () => boolean): Promise<string> {
    const run = async (): Promise<string> => {
      console.info('[QysgRuntime] host invoke method=' + method + ' url=' + source.sourceUrl);
      if (isAborted && isAborted()) throw new Error('qysg operation cancelled');
      await this.ensureSource_(source);
      this.bridge_?.setSourceName(source.sourceName);
      this.bridge_?.setOperation(method);
      this.bridge_?.setAbortChecker(isAborted);
      if (isAborted && isAborted()) throw new Error('qysg operation cancelled');
      const operationId = 'qysg-' + (++this.operationId_).toString();
      const result = new Promise<string>((resolve, reject) => {
        this.pending_.set(operationId, { resolve, reject });
      });
      const invokeScript = 'window.__qysgHost.invoke(' + JSON.stringify(operationId) + ',' +
        JSON.stringify(method) + ',' + JSON.stringify(JSON.stringify(args)) + ');';
      try {
        await this.controller_.runJavaScript(invokeScript);
      } catch (error) {
        this.pending_.delete(operationId);
        console.error('[QysgRuntime] runJavaScript failed: ' + String(error));
        throw error instanceof Error ? error : new Error(String(error));
      }
      const payload = await this.withTimeout_(result, 45000, 'qysg ' + method + ' 超时');
      console.info('[QysgRuntime] host invoke completed method=' + method + ' bytes=' + payload.length);
      return payload;
    };
    const result = this.queue_.then(run, run);
    this.queue_ = result.then(() => undefined, () => undefined);
    return result;
  }

  private async ensureSource_(source: QysgSourceDefinition): Promise<void> {
    if (!this.controllerAttached_) {
      console.error('[QysgRuntime] ensureSource before controller attached');
      throw new Error('qysg WebView 控制器尚未绑定');
    }
    const baseUrl = source.htmlBaseUrl || source.sourceUrl;
    const key = baseUrl + '\n' + source.html.length + '\n' + source.html.substring(0, 32);
    if (key === this.activeSourceKey_ && this.readyPromise_) return await this.readyPromise_;
    this.activeSourceKey_ = key;
    this.activeSourceUrl_ = source.sourceUrl;
    this.bridge_?.resetForSource();
    this.bridge_?.setSourceUrl(source.sourceUrl);
    this.readyPromise_ = new Promise<void>((resolve, reject) => {
      this.readyResolve_ = resolve;
      this.readyReject_ = reject;
    });
    // qysg 源依赖的 CDN jQuery 可能因失效、网络策略或 Cloudflare 无法加载。
    // 先注入应用内的固定版本，再保留下方最小兼容层；源 HTML 自带的 jQuery
    // 若能成功加载仍可覆盖它，不能加载时则使用本地版本保证常用 API 可用。
    const bundledJquery = loadBundledQysgJquery(this.getUIContext().getHostContext() || null);
    const bundledJqueryScript = bundledJquery ? '<script>' + bundledJquery + '</script>' : '';
    if (bundledJquery) {
      console.info('[QysgRuntime] bundled jQuery injected bytes=' + bundledJquery.length.toString());
    }
    const bootstrap = bundledJqueryScript + '<script>(function(){' +
      'var bridgePending={},bridgeSeq=0;' +
      'window.__qysgBridgeComplete=function(id,raw){var p=bridgePending[id];if(!p)return;' +
      'delete bridgePending[id];try{var e=JSON.parse(raw||"{}");if(!e.ok)throw new Error(e.error||"bridge error");' +
      'p.resolve(e.value);}catch(err){p.reject(err);}};' +
      // 部分 qysg 源引用的 jQuery 地址已失效，但仍使用了少量常用 jQuery API。
      // 先提供最小回退，外部 jQuery 成功加载时会覆盖 window.$，不影响完整 jQuery 源。
      'if(!window.$){(function(){function wrap(nodes){var a=[];for(var i=0;i<(nodes||[]).length;i++)' +
      'if(nodes[i])a.push(nodes[i]);var w={length:a.length};for(var j=0;j<a.length;j++)w[j]=a[j];' +
      'w.find=function(s){var out=[];for(var i=0;i<a.length;i++){var ns=a[i].querySelectorAll(s);for(var j=0;j<ns.length;j++)out.push(ns[j]);}' +
      'return wrap(out);};w.each=function(fn){for(var i=0;i<a.length;i++)fn.call(a[i],i,a[i]);return w;};' +
      'w.attr=function(n){return a.length?a[0].getAttribute(n):undefined;};' +
      'w.text=function(){var s="";for(var i=0;i<a.length;i++)s+=a[i].textContent||"";return s;};' +
      // 兼容 qysg 正文分页常用的 $(node).hasClass("curr") 判断。
      // jQuery 失效时使用的最小包装器也必须保持“任一匹配元素包含该类名”语义。
      'w.hasClass=function(c){if(!c)return false;for(var i=0;i<a.length;i++)' +
      'if(a[i].classList&&a[i].classList.contains(c))return true;return false;};' +
      'w.eq=function(i){var n=i<0?a.length+i:i;return wrap(n>=0&&n<a.length?[a[n]]:[]);};' +
      'w.first=function(){return wrap(a.length?[a[0]]:[]);};' +
      'w.last=function(){return wrap(a.length?[a[a.length-1]]:[]);};' +
      'w.clone=function(){var out=[];for(var i=0;i<a.length;i++)out.push(a[i].cloneNode(true));return wrap(out);};' +
      'w.html=function(v){if(v===undefined)return a.length?a[0].innerHTML:"";for(var i=0;i<a.length;i++)a[i].innerHTML=v;return w;};' +
      'w.remove=function(){for(var i=0;i<a.length;i++)if(a[i].parentNode)a[i].parentNode.removeChild(a[i]);return w;};return w;}' +
      'function $(v){if(typeof v==="string"){if(v.charAt(0)==="<"){var d=document.createElement("div");d.innerHTML=v;return wrap(d.firstElementChild?[d.firstElementChild]:[]);}' +
      'try{return wrap(document.querySelectorAll(v));}catch(e){return wrap([]);}}if(v&&v.nodeType)return wrap([v]);return wrap([]);}window.$=$;})();}' +
      'window.flutter_inappwebview={callHandler:function(name){' +
      'var args=Array.prototype.slice.call(arguments,1),id="bridge-"+(++bridgeSeq);' +
      'return new Promise(function(resolve,reject){bridgePending[id]={resolve:resolve,reject:reject};' +
      'try{window.qysgNative.callHandler.apply(window.qysgNative,[id,name].concat(args));}' +
      'catch(err){delete bridgePending[id];reject(err);}});}};' +
      // qysg 音频源通常在 HTML 中声明全局 header。网页 <audio> 会自动带上
      // Referer/User-Agent，但原生 AVPlayer 不会；把安全的媒体请求头附在
      // content 返回的 URL 后，由 AudioPlayer 转成 MediaSource 请求头。
      'function qysgAttachMediaHeaders(name,value){' +
      'if(name!=="content"||typeof value!=="string"||' +
      '(value.indexOf("http://")!==0&&value.indexOf("https://")!==0)||' +
      '(value.indexOf(",{")>=0&&value.indexOf("headers")>=0))return value;' +
      'var sourceHeader=window.header;' +
      'if(!sourceHeader||typeof sourceHeader!=="object"||Array.isArray(sourceHeader))return value;' +
      'var mediaHeaders={};' +
      'for(var h in sourceHeader){' +
      'if(Object.prototype.hasOwnProperty.call(sourceHeader,h)&&' +
      '/^(referer|user-agent|cookie|authorization|origin)$/i.test(h))' +
      'mediaHeaders[h]=String(sourceHeader[h]);}' +
      'if(Object.keys(mediaHeaders).length===0)return value;' +
      'try{return value+","+JSON.stringify({headers:mediaHeaders});}catch(e){return value;}};' +
      'window.__qysgHost={invoke:async function(id,name,argsJson){try{' +
      'var args=JSON.parse(argsJson),fn=window[name];' +
      'if(typeof fn!=="function")throw new Error("unsupported qysg method: "+name);' +
      'var value=qysgAttachMediaHeaders(name,await Promise.resolve(fn.apply(window,args)));' +
      'await window.qysgNative.complete(String(id),true,JSON.stringify(value===undefined?null:value));' +
      '}catch(err){await window.qysgNative.complete(String(id),false,String(err&&err.stack||err));}}};' +
      '})();</script>';
    // 注意 callHandler 的拼接脚本不能使用 data: URL，baseUrl 必须是源站地址，
    // 否则 qysg 中相对路径和外部 jQuery 无法解析。
    const html = bootstrap + source.html;
    try {
      console.info('[QysgRuntime] loading source html url=' + source.sourceUrl + ' bytes=' + html.length);
      this.controller_.loadData(html, 'text/html', 'UTF-8', baseUrl);
    } catch (error) {
      this.readyReject_?.(error as Error);
      throw error instanceof Error ? error : new Error(String(error));
    }
    await this.withTimeout_(this.readyPromise_, 30000, 'qysg WebView 加载超时');
  }

  private async withTimeout_<T>(promise: Promise<T>, timeoutMs: number, message: string): Promise<T> {
    let timer: number = 0;
    const timeout = new Promise<T>((_resolve: (value: T) => void, reject: (error: Error) => void) => {
      timer = setTimeout((): void => reject(new Error(message)), timeoutMs);
    });
    try {
      return await Promise.race([promise, timeout]);
    } finally {
      if (timer) clearTimeout(timer);
    }
  }
}
