/**
 * JS 求值 Worker —— 在独立线程中执行 QuickJS 脚本
 *
 * 职责：
 *   1. 加载 quickjs_bridge 原生模块
 *   2. 注册 java.ajax() HTTP 处理器（使用 RCP 发起请求）
 *   3. 通过 postMessage 接收求值请求
 *   4. 执行 JS 并返回结果
 */
import worker from '@ohos.worker';
import util from '@ohos.util';
import rcp from '@hms.collaboration.rcp';
import http from '@ohos.net.http';
import { hostOf, normalizeSetCookies, parseSetCookieLine, parseCookieHeader, cookieMapToHeader } from '../util/CookieStore';

// 静态导入 QuickJS 原生模块（Worker 中必须用静态 import 而非 requireNapi）
import quickjsBridge from 'libquickjs_bridge.so';

declare function requireNapi(name: string): object;

// ============ Worker 侧 Cookie 存储 ============
// 与主线程 CookieStore 保持同步：主线程快照下发，Worker 本地变更上报
let workerCookies: Record<string, string> = {};

/** 请求前注入 Cookie 头 */
function injectCookieHeader(url: string, headers: Record<string, string>): void {
  const host = hostOf(url);
  if (!host) return;
  const cookie = workerCookies[host];
  if (!cookie) return;
  const hasCookie = Object.keys(headers).some(k => k.toLowerCase() === 'cookie');
  if (!hasCookie) {
    headers['Cookie'] = cookie;
  }
}

/** 响应后保存 Set-Cookie，并上报主线程持久化 */
function captureSetCookies(url: string, setCookieRaw: string | string[] | undefined): void {
  const host = hostOf(url);
  if (!host) return;
  const lines = normalizeSetCookies(setCookieRaw);
  if (lines.length === 0) return;
  const existing = parseCookieHeader(workerCookies[host] || '');
  let changed = false;
  for (const line of lines) {
    const pair = parseSetCookieLine(line);
    if (!pair) continue;
    if (pair.expired) {
      if (existing.delete(pair.name)) changed = true;
    } else {
      existing.set(pair.name, pair.value);
      changed = true;
    }
  }
  if (!changed) return;
  const header = cookieMapToHeader(existing);
  if (header) {
    workerCookies[host] = header;
  } else {
    delete workerCookies[host];
  }
  try {
    parentPort.postMessage({ type: 'cookie_set', host: host, cookie: header });
  } catch (_e) { /* worker 初始化前忽略 */ }
}

/** 归一化响应头为小写键对象（保留数组，供 JS 侧读取 set-cookie） */
function headersToJson(headers: Record<string, string | string[] | undefined>): string {
  const out: Record<string, string | string[]> = {};
  for (const k of Object.keys(headers || {})) {
    const v = headers[k];
    if (v !== undefined) out[k.toLowerCase()] = v;
  }
  return JSON.stringify(out);
}

// ============ RCP HTTP 工具 ============

// Worker 侧的网络配置（由主线程通过 postMessage 同步）
let workerDnsServers: string = '';
let workerDnsEnabled: boolean = false;
let workerProxyHost: string = '';
let workerProxyPort: number = 0;
let workerTimeout: number = 60000;
let rcpSession: rcp.Session | null = null;
let rcpConfigVersion: number = 0;

function isTransientConnectionError(message: string): boolean {
  return /(SSL connect error|connection reset|connection refused|socket|network is unreachable|1007900035|osErr\s*104)/i.test(message);
}

interface WorkerHttpResult {
  text: string;
  statusCode: number;
  headersJson: string;
  isError: boolean;
}

async function systemHttpRequest(
  url: string, method: string, headers: Record<string, string>, body?: string
): Promise<WorkerHttpResult> {
  const request = http.createHttp();
  try {
    const response = await request.request(url, {
      method: method.toUpperCase() as http.RequestMethod,
      header: headers,
      extraData: body || '',
      expectDataType: http.HttpDataType.ARRAY_BUFFER,
      connectTimeout: workerTimeout,
      readTimeout: workerTimeout,
    });
    const respHeaders = (response.header || {}) as Record<string, string | string[] | undefined>;
    captureSetCookies(url, respHeaders['set-cookie']);
    let text = '';
    if (typeof response.result === 'string') {
      text = response.result;
    } else if (response.result instanceof ArrayBuffer) {
      text = util.TextDecoder.create('utf-8', { fatal: false } as Record<string, Object>)
        .decodeToString(new Uint8Array(response.result));
    } else {
      text = JSON.stringify(response.result);
    }
    // 非 2xx 不视为错误（状态码交由脚本判断）
    return { text: text, statusCode: response.responseCode, headersJson: headersToJson(respHeaders), isError: false };
  } finally {
    request.destroy();
  }
}

function getRcpSession(): rcp.Session {
  // 配置变更时重建 session
  if (rcpSession) {
    return rcpSession;
  }
  const cfg: rcp.Configuration = {
    transfer: {
      timeout: { connectMs: workerTimeout, transferMs: workerTimeout }
    }
  };
  // DNS
  if (workerDnsEnabled && workerDnsServers) {
    const dnsList = workerDnsServers.split(',').map(s => s.trim()).filter(s => s);
    if (dnsList.length > 0) {
      const dnsServers: rcp.IpAndPort[] = dnsList.map(ip => ({ ip: ip, port: 53 }));
      cfg.dns = { dnsRules: dnsServers } as rcp.DnsConfiguration;
    }
  }
  // Proxy
  if (workerProxyHost && workerProxyPort > 0) {
    cfg.proxy = { url: 'http://' + workerProxyHost + ':' + workerProxyPort } as rcp.WebProxy;
  }
  try {
    rcpSession = rcp.createSession({ requestConfiguration: cfg });
    console.info('[JsWorker] RCP session created, timeout:', workerTimeout, 'dns:', workerDnsEnabled, 'proxy:', workerProxyHost || 'none');
    return rcpSession;
  } catch (err) {
    throw new Error('[JsWorker] create RCP session failed: ' + (err as Error).message);
  }
}

async function httpRequest(url: string, method: string, headers: Record<string, string>, body?: string): Promise<WorkerHttpResult> {
  try {
    try {
      url = url.replace(/[^\x00-\x7F]+/g, (part: string): string => encodeURIComponent(part)).replace(/ /g, '%20');
    } catch (_e) { /* 保留原 URL 交由 RCP 报错 */ }
    if (!headers['User-Agent']) {
      headers['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36';
    }
    if (method === 'POST' && body && !headers['Content-Type'] && !headers['content-type']) {
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
    }
    injectCookieHeader(url, headers);
    const reqHeaders = headers as rcp.RequestHeaders;
    const request = new rcp.Request(url, method.toUpperCase() as rcp.HttpMethod, reqHeaders, body || '');
    let response: rcp.Response;
    try {
      response = await getRcpSession().fetch(request);
    } catch (rcpError) {
      const message = (rcpError as Error).message || String(rcpError);
      if (!isTransientConnectionError(message) || workerProxyHost) throw rcpError;
      console.warn('[JsWorker] RCP connection failed, falling back to system HTTP:', message);
      return await systemHttpRequest(url, method, headers, body);
    }
    const respHeaders = (response.headers || {}) as Record<string, string | string[] | undefined>;
    captureSetCookies(url, respHeaders['set-cookie']);
    const statusCode = response.statusCode || 0;
    let text = '';
    if (response.body !== undefined && response.body !== null) {
      const uint8 = new Uint8Array(response.body);
      const decoder = util.TextDecoder.create('utf-8', { fatal: false } as Record<string, Object>);
      text = decoder.decodeToString(uint8);
    }
    // 非 2xx 不视为错误（与 Android OkHttp 一致：状态码由脚本自行判断，如 WAF 401 验证页）
    return { text: text, statusCode: statusCode, headersJson: headersToJson(respHeaders), isError: false };
  } catch (e) {
    return { text: 'HTTP Error: ' + String(e), statusCode: 0, headersJson: '{}', isError: true };
  }
}

// ============ QuickJS 桥 ============

let engineId: number = -1;
let initialized: boolean = false;

async function initEngine(): Promise<boolean> {
  if (initialized) return true;

  // quickjsBridge 已在模块顶部静态导入，无需 requireNapi
  if (!quickjsBridge || typeof quickjsBridge.createEngine !== 'function') {
    console.warn('[JsWorker] Static imported quickjsBridge is invalid');
    return false;
  }
  console.info('[JsWorker] Native module loaded via static import');

  try {
    engineId = quickjsBridge.createEngine();
    initialized = true;

    quickjsBridge.registerHttpHandler(
      engineId,
      (requestId: number, url: string, method: string, headersJson: string, body?: string): void => {
        handleHttpRequest(requestId, url, method, headersJson, body);
      }
    );

    quickjsBridge.registerCookieHandler(
      engineId,
      (requestId: number, op: string, url: string, value: string): void => {
        handleCookieOp(requestId, op, url, value);
      }
    );

    return true;
  } catch (e) {
    console.error('[JsWorker] Engine init error:', e);
    return false;
  }
}

// ============ HTTP 请求处理器 ============

async function handleHttpRequest(
  requestId: number, url: string, method: string, headersJson: string, body?: string
): Promise<void> {
  try {
    const headers = JSON.parse(headersJson || '{}') as Record<string, string>;
    const result = await httpRequest(url, method, headers, body);
    if (result.isError) {
      quickjsBridge.onHttpResponse(requestId, result.text, true, result.headersJson, result.statusCode);
    } else {
      quickjsBridge.onHttpResponse(requestId, result.text, false, result.headersJson, result.statusCode);
    }
  } catch (_e) {
    quickjsBridge.onHttpResponse(requestId, '', true, '{}', 0);
  }
}

// ============ Cookie 操作处理器（JS cookie.* 同步桥） ============

function handleCookieOp(requestId: number, op: string, url: string, value: string): void {
  let result = '';
  try {
    const host = hostOf(url);
    if (host) {
      if (op === 'get') {
        result = workerCookies[host] || '';
      } else if (op === 'set') {
        const existing = parseCookieHeader(workerCookies[host] || '');
        const incoming = parseCookieHeader(value);
        incoming.forEach((v, k) => { existing.set(k, v); });
        const header = cookieMapToHeader(existing);
        if (header) {
          workerCookies[host] = header;
        } else {
          delete workerCookies[host];
        }
        parentPort.postMessage({ type: 'cookie_set', host: host, cookie: header });
      } else if (op === 'remove') {
        delete workerCookies[host];
        parentPort.postMessage({ type: 'cookie_remove', host: host });
      }
    }
  } catch (_e) { /* ignore */ }
  quickjsBridge.onCookieResponse(requestId, result);
}

// ============ JS 执行 ============

async function executeJs(code: string): Promise<string> {
  if (!initialized) {
    const ok = await initEngine();
    if (!ok) return 'null';
  }
  try {
    const result = quickjsBridge.executeScript(engineId, code);
    return result || 'null';
  } catch (e) {
    console.error('[JsWorker] Execute error:', e);
    return 'null';
  }
}

// ============ Worker 消息处理 ============

const parentPort = worker.workerPort;

try {
  parentPort.onmessage = (event: Record<string, any>): void => {
    const msg = event?.data as Record<string, any>;
    if (!msg || !msg.type) return;

    if (msg.type === 'eval') {
      executeJs(msg.code || '')
        .then((value: string): void => {
          parentPort.postMessage({ type: 'result', id: msg.id, value });
        })
        .catch((e: Error): void => {
          parentPort.postMessage({ type: 'error', id: msg.id, error: String(e) });
        });
    } else if (msg.type === 'init') {
      initEngine().then((ok: boolean): void => {
        parentPort.postMessage({ type: 'init_done', ok });
      });
    } else if (msg.type === 'destroy') {
      if (engineId >= 0) {
        quickjsBridge.destroyEngine(engineId);
      }
      initialized = false;
      engineId = -1;
      parentPort.postMessage({ type: 'destroy_done' });
    } else if (msg.type === 'config') {
      // 同步网络配置（DNS/Proxy/超时）到 Worker
      const c = msg.config;
      if (c) {
        const oldVersion = rcpConfigVersion;
        workerDnsServers = c.dnsServers || '';
        workerDnsEnabled = !!c.dnsEnabled;
        workerProxyHost = c.proxyHost || '';
        workerProxyPort = c.proxyPort || 0;
        workerTimeout = c.timeout || 60000;
        rcpConfigVersion++;
        // 配置变了就销毁旧 session，下次请求时重建
        if (rcpSession && rcpConfigVersion !== oldVersion) {
          try { rcpSession.close(); } catch (_) { /* ignore */ }
          rcpSession = null;
        }
        console.info('[JsWorker] Network config updated: dns=', workerDnsEnabled, 'proxy=', workerProxyHost || 'none', 'timeout=', workerTimeout);
      }
    } else if (msg.type === 'cookie_sync') {
      // 主线程下发的 Cookie 全量快照
      const cookies = msg.cookies as Record<string, string>;
      if (cookies && typeof cookies === 'object') {
        workerCookies = { ...cookies };
        console.info('[JsWorker] Cookie snapshot synced,', Object.keys(workerCookies).length, 'hosts');
      }
    }
  };
} catch (_e) { /* ignore setup errors */ }
