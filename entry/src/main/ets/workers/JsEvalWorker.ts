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

// 静态导入 QuickJS 原生模块（Worker 中必须用静态 import 而非 requireNapi）
import quickjsBridge from 'libquickjs_bridge.so';

declare function requireNapi(name: string): object;

// ============ RCP HTTP 工具 ============

// Worker 侧的网络配置（由主线程通过 postMessage 同步）
let workerDnsServers: string = '';
let workerDnsEnabled: boolean = false;
let workerProxyHost: string = '';
let workerProxyPort: number = 0;
let workerTimeout: number = 60000;
let rcpSession: rcp.Session | null = null;
let rcpConfigVersion: number = 0;

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

async function httpRequest(url: string, method: string, headers: Record<string, string>, body?: string): Promise<string> {
  try {
    if (!headers['User-Agent']) {
      headers['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36';
    }
    if (method === 'POST' && body && !headers['Content-Type'] && !headers['content-type']) {
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
    }
    const reqHeaders = headers as rcp.RequestHeaders;
    const request = new rcp.Request(url, method.toUpperCase() as rcp.HttpMethod, reqHeaders, body || '');
    const response = await getRcpSession().fetch(request);
    if (response.body === undefined || response.body === null) return '';
    const uint8 = new Uint8Array(response.body);
    const decoder = util.TextDecoder.create('utf-8', { fatal: false } as Record<string, Object>);
    return decoder.decodeToString(uint8);
  } catch (e) {
    return 'HTTP Error: ' + String(e);
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
    const responseText = await httpRequest(url, method, headers, body);
    const isError = responseText.startsWith('HTTP Error:');
    quickjsBridge.onHttpResponse(requestId, isError ? '' : responseText, isError);
  } catch (_e) {
    quickjsBridge.onHttpResponse(requestId, '', true);
  }
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
    }
  };
} catch (_e) { /* ignore setup errors */ }
