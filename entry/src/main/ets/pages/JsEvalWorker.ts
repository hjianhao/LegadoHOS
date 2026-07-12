/**
 * JS 求值 Worker —— 在独立线程中执行 QuickJS 脚本
 *
 * 职责：
 *   1. 加载 libquickjs_bridge.so 原生模块
 *   2. 注册 java.ajax() HTTP 处理器（使用 RCP 发起请求）
 *   3. 通过 postMessage 接收求值请求
 *   4. 执行 JS 并返回结果
 */
import worker from '@ohos.worker';
import util from '@ohos.util';
import rcp from '@hms.collaboration.rcp';

// ============ RCP HTTP 工具 ============

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
    const response = await rcp.createSession().fetch(request);
    if (response.body === undefined || response.body === null) return '';
    const uint8 = new Uint8Array(response.body);
    const decoder = util.TextDecoder.create('utf-8', { fatal: false } as Record<string, Object>);
    return decoder.decodeToString(uint8);
  } catch (e) {
    return 'HTTP Error: ' + String(e);
  }
}

// ============ QuickJS 桥 ============

let quickjsBridge: any = null;
let engineId: number = -1;
let initialized: boolean = false;

async function initEngine(): Promise<boolean> {
  if (initialized) return true;

  try {
    const mod = await import('libquickjs_bridge.so');
    quickjsBridge = (mod as any).default || mod;
    if (!quickjsBridge || typeof quickjsBridge.createEngine !== 'function') {
      console.warn('[JsWorker] import returned invalid module');
      return false;
    }
  } catch (_e) {
    console.warn('[JsWorker] import(libquickjs_bridge.so) failed');
    return false;
  }

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
    if (quickjsBridge && typeof quickjsBridge.onHttpResponse === 'function') {
      quickjsBridge.onHttpResponse(requestId, isError ? '' : responseText, isError);
    }
  } catch (_e) {
    if (quickjsBridge && typeof quickjsBridge.onHttpResponse === 'function') {
      quickjsBridge.onHttpResponse(requestId, '', true);
    }
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
      if (engineId >= 0 && quickjsBridge && typeof quickjsBridge.destroyEngine === 'function') {
        quickjsBridge.destroyEngine(engineId);
      }
      initialized = false;
      engineId = -1;
      parentPort.postMessage({ type: 'destroy_done' });
    }
  };
} catch (_e) { /* ignore setup errors */ }
