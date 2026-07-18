/**
 * QuickJS 脚本引擎封装
 *
 * 提供对 QuickJS NAPI 的高级封装，管理引擎生命周期，
 * 处理 JS 执行、函数调用、异常捕获等。
 *
 * 这是书源书行能力的核心——通过此引擎执行用户书源脚本，
 * 兼容现存的所有 Legado 书源。
 */
import quickjsBridge, { tryLoadNative, getBridge, isNativeLoaded } from '../../napi/quickjs_bridge';
import { CookieStore } from '../../util/CookieStore';

export class ScriptEngine {
  private engineId: number = -1;
  private initialized: boolean = false;

  constructor() {}

  /**
   * 初始化引擎
   * 在 app 启动时调用一次，全局共享
   */
  async initialize(): Promise<void> {
    if (this.initialized) return;

    // 尝试加载原生 QuickJS 模块（如果尚未加载）
    // 这会尝试 import('libquickjs_bridge.so')(HarmonyOS NEXT 推荐方式)
    // 和 requireNapi('quickjs_bridge')（兼容方式）
    const loaded = await tryLoadNative();
    console.info('[ScriptEngine] Native module loaded:', loaded);

    // 使用可能已更新的桥接实例
    const bridge = getBridge();
    try {
      this.engineId = bridge.createEngine();
      this.initialized = true;
      console.info('[ScriptEngine] Engine created, id:', this.engineId);

      // 注册 HTTP 请求处理器（由 ArkTS 侧真正发起网络请求）
      const handler = (requestId: number, url: string, method: string, headersJson: string, body?: string): void => {
        this.handleHttpRequest(requestId, url, method, headersJson, body);
      };
      bridge.registerHttpHandler(this.engineId, handler);

      // 注册 Cookie 操作处理器（JS cookie.* → CookieStore）
      bridge.registerCookieHandler(this.engineId,
        (requestId: number, op: string, url: string, value: string): void => {
          this.handleCookieOp(requestId, op, url, value);
        });
    } catch (err) {
      console.error('[ScriptEngine] Failed to create engine:', err);
      throw err;
    }
  }

  /**
   * 执行 JS 脚本
   */
  async executeScript(script: string): Promise<string> {
    this.checkReady();
    try {
      const result = getBridge().executeScript(this.engineId, script);
      return result;
    } catch (err) {
      console.error('[ScriptEngine] Execute error:', err);
      throw new Error(`JS执行错误: ${err.message}`);
    }
  }

  /** 同步执行 JS（用于简单表达式） */
  evaluateJsSync(script: string): string {
    this.checkReady();
    try {
      return getBridge().executeScript(this.engineId, script);
    } catch (err) {
      console.error('[ScriptEngine] Sync error:', err);
      return '';
    }
  }

  /**
   * 调用 JS 全局函数
   * @param funcName 函数名 (如 "search", "getBookInfo", "getToc", "getContent")
   * @param args 参数数组
   * @returns JSON 字符串结果
   */
  async callFunction(funcName: string, ...args: any[]): Promise<string> {
    this.checkReady();
    try {
      const argsJson = JSON.stringify(args);
      const result = getBridge().callFunction(this.engineId, funcName, argsJson);
      return result;
    } catch (err) {
      console.error(`[ScriptEngine] Call function ${funcName} error:`, err);
      throw new Error(`JS函数调用失败 ${funcName}: ${err.message}`);
    }
  }

  /**
   * 加载书源脚本到引擎中
   * 脚本被定义到全局，后续可通过 callFunction 调用
   */
  async loadSourceScript(script: string): Promise<void> {
    await this.executeScript(script);
  }

  /**
   * 检查脚本是否具有某个函数
   */
  async hasFunction(funcName: string): Promise<boolean> {
    const checkScript = `typeof ${funcName} === 'function'`;
    const result = await this.executeScript(checkScript);
    return result === 'true';
  }

  /**
   * 获取引擎状态：'native' 或 'mock'
   */
  getEngineType(): string {
    return isNativeLoaded() ? 'native' : 'mock';
  }

  /**
   * 销毁引擎
   */
  destroy(): void {
    if (this.engineId >= 0) {
      getBridge().destroyEngine(this.engineId);
      this.initialized = false;
      this.engineId = -1;
      console.info('[ScriptEngine] Engine destroyed');
    }
  }

  /**
   * 处理 HTTP 请求（由 NAPI 桥调用，实际网络请求在 ArkTS 侧完成）
   */
  private async handleHttpRequest(
    requestId: number,
    url: string,
    method: string,
    headersJson: string,
    body?: string
  ): Promise<void> {
    try {
      const netUtil = await import('../../util/NetUtil');
      const headers = JSON.parse(headersJson || '{}');

      let responseBody: string;
      let isError: boolean;

      try {
        if (method === 'GET') {
          responseBody = await netUtil.NetUtil.httpGet(url, headers);
        } else {
          responseBody = await netUtil.NetUtil.httpPost(url, body || '', headers);
        }
        isError = false;
      } catch (err) {
        responseBody = err.message;
        isError = true;
      }

      // 通知 QuickJS 引擎请求完成
      getBridge().onHttpResponse(requestId, responseBody, isError);
    } catch (err) {
      getBridge().onHttpResponse(requestId, err.message, true);
    }
  }

  /**
   * 处理 Cookie 操作（由 NAPI 桥调用，同步返回结果）
   * op: get / set / remove；写操作持久化为异步（fire-and-forget），读操作走内存缓存同步返回
   */
  private handleCookieOp(requestId: number, op: string, url: string, value: string): void {
    let result = '';
    try {
      const store = CookieStore.getInstance();
      if (op === 'get') {
        result = store.getCookie(url);
      } else if (op === 'set') {
        void store.setCookie(url, value);
      } else if (op === 'remove') {
        void store.removeCookie(url);
      }
    } catch (_e) { /* ignore */ }
    getBridge().onCookieResponse(requestId, result);
  }

  private checkReady(): void {
    if (!this.initialized || this.engineId < 0) {
      throw new Error('ScriptEngine 未初始化，请先调用 initialize()');
    }
  }
}

/**
 * 全局单例
 */
export const globalScriptEngine = new ScriptEngine();
