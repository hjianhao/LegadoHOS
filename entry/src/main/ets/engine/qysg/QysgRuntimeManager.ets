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
import { NetUtil } from '../../util/NetUtil';
import { decodeQysgSource, QysgSourceDefinition } from './QysgSourceCodec';

export interface QysgRuntimeHost {
  invoke(source: QysgSourceDefinition, method: string, args: Object[]): Promise<string>;
}

interface PendingOperation {
  resolve: (value: string) => void;
  reject: (error: Error) => void;
}

interface QysgHttpResponse {
  method: string;
  body: string;
  headers: Record<string, string>;
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

function parseHeaders(value: Object): Record<string, string> {
  if (!value) return {};
  try {
    const parsed: Object | string = typeof value === 'string' ? JSON.parse(value as string) : value;
    if (!parsed || typeof parsed !== 'object') return {};
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

/** 原生侧 qysg bridge。方法签名保留足够参数，适配 callHandler 的多参数调用。 */
export class QysgNativeBridge {
  private sourceUrl_: string = '';
  private context_: Context | null;
  private pending_: Map<string, PendingOperation>;
  private emitResult_: (requestId: string, payload: string) => void;

  constructor(context: Context | null, pending: Map<string, PendingOperation>,
    emitResult: (requestId: string, payload: string) => void) {
    this.context_ = context;
    this.pending_ = pending;
    this.emitResult_ = emitResult;
  }

  setSourceUrl(sourceUrl: string): void {
    this.sourceUrl_ = sourceUrl;
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
        if (this.context_) await CookieStore.getInstance().init(this.context_);
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
      case 'base64encode':
        return encodeBase64(String(args[0] || ''));
      case 'base64decode':
        return String(args[0] || '');
      case 'utf8ToGbkUrlEncoded':
        return encodeURIComponent(String(args[0] || ''));
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
    let data = '';
    console.info('[QysgBridge] http ' + method + ' ' + url);
    if (method === 'POST') data = await NetUtil.httpPost(url, body, headers);
    else data = await NetUtil.httpGet(url, headers);
    console.info('[QysgBridge] http done status=200 bytes=' + data.length.toString());
    return {
      method: method.toLowerCase(),
      body: encodeBase64(data),
      headers: {},
      statusCode: 200,
      statusMessage: 'OK',
      data: data,
    };
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

  static async invoke(source: BookSource, method: string, args: Object[]): Promise<string> {
    console.info('[QysgRuntime] invoke requested source=' + source.sourceName + ' method=' + method);
    if (!source.enabled) throw new Error('书源未启用');
    const definition = decodeQysgSource(source);
    let host = QysgRuntimeManager.hosts_[0];
    // 页面生命周期中 aboutToAppear 可能早于 WebView.onControllerAttached，给隐藏
    // WebView 一个短暂的注册窗口，避免首次搜索/发现请求无谓失败。
    for (let attempt = 0; !host && attempt < 100; attempt++) {
      await new Promise<void>((resolve: () => void): void => {
        setTimeout(resolve, 100);
      });
      host = QysgRuntimeManager.hosts_[0];
    }
    if (!host) {
      console.error('[QysgRuntime] no host after waiting');
      throw new Error('qysg WebView 运行时未就绪，请返回应用主页后重试');
    }
    console.info('[QysgRuntime] dispatching to host method=' + method);
    return await host.invoke(definition, method, args);
  }
}

/** qysg 隐藏 WebView。挂载该组件即可让业务层获得一个运行槽位。 */
@Component
export struct QysgRuntimeHostComponent {
  private controller_: web_webview.WebviewController = new web_webview.WebviewController();
  private controllerAttached_: boolean = false;
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

  aboutToDisappear(): void {
    if (this.hostRegistered_) QysgRuntimeManager.unregisterHost(this);
    this.hostRegistered_ = false;
    this.pending_.forEach((pending: PendingOperation): void => pending.reject(new Error('qysg runtime closed')));
    this.pending_.clear();
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
            (requestId: string, payload: string): void => this.completeBridgeCall_(requestId, payload));
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

  invoke(source: QysgSourceDefinition, method: string, args: Object[]): Promise<string> {
    const run = async (): Promise<string> => {
      console.info('[QysgRuntime] host invoke method=' + method + ' url=' + source.sourceUrl);
      await this.ensureSource_(source);
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
    const key = source.sourceUrl + '\n' + source.html.length + '\n' + source.html.substring(0, 32);
    if (key === this.activeSourceKey_ && this.readyPromise_) return await this.readyPromise_;
    this.activeSourceKey_ = key;
    this.activeSourceUrl_ = source.sourceUrl;
    this.bridge_?.setSourceUrl(source.sourceUrl);
    this.readyPromise_ = new Promise<void>((resolve, reject) => {
      this.readyResolve_ = resolve;
      this.readyReject_ = reject;
    });
    const bootstrap = '<script>(function(){' +
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
      'window.__qysgHost={invoke:async function(id,name,argsJson){try{' +
      'var args=JSON.parse(argsJson),fn=window[name];' +
      'if(typeof fn!=="function")throw new Error("unsupported qysg method: "+name);' +
      'var value=await Promise.resolve(fn.apply(window,args));' +
      'await window.qysgNative.complete(String(id),true,JSON.stringify(value===undefined?null:value));' +
      '}catch(err){await window.qysgNative.complete(String(id),false,String(err&&err.stack||err));}}};' +
      '})();</script>';
    // 注意 callHandler 的拼接脚本不能使用 data: URL，baseUrl 必须是源站地址，
    // 否则 qysg 中相对路径和外部 jQuery 无法解析。
    const html = bootstrap + source.html;
    try {
      console.info('[QysgRuntime] loading source html url=' + source.sourceUrl + ' bytes=' + html.length);
      this.controller_.loadData(html, 'text/html', 'UTF-8', source.sourceUrl);
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
