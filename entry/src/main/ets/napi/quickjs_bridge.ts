/**
 * QuickJS NAPI 桥接
 *
 * 提供 ArkTS 侧调用 QuickJS JavaScript 引擎的能力。
 *
 * 加载方式（按优先级）：
 * 1. import('libquickjs_bridge.so') — HarmonyOS NEXT API 12+
 * 2. requireNapi('quickjs_bridge') — 兼容方式
 * 3. 降级为 mock 实现（书源搜索走直接 HTTP 回退）
 */
export interface QuickJSBridge {
  createEngine(): number;
  destroyEngine(engineId: number): void;
  executeScript(engineId: number, script: string): string;
  callFunction(engineId: number, functionName: string, argsJson: string): string;
  onHttpResponse(requestId: number, responseBody: string, isError: boolean): void;
  registerHttpHandler(handler: (requestId: number, url: string, method: string, headersJson: string, body?: string) => void): void;
}

declare function requireNapi(name: string): object;

// ====== Mock 实现（降级方案） ======
function createMockBridge(): QuickJSBridge {
  return {
    createEngine(): number {
      return 0;
    },
    destroyEngine(_id: number): void {},
    executeScript(_id: number, _s: string): string {
      return 'null';
    },
    callFunction(_id: number, _fn: string, _args: string): string {
      return '[]';
    },
    onHttpResponse(_id: number, _b: string, _e: boolean): void {},
    registerHttpHandler(_h: object): void {},
  };
}

// ====== 桥接实例（可变，后续可被原生模块替换） ======
let currentBridge: QuickJSBridge = createMockBridge();

// 标记是否已成功加载原生模块
let nativeLoaded: boolean = false;

/**
 * 尝试加载原生 QuickJS 模块
 * 应在 ScriptEngine.initialize() 中调用
 */
export async function tryLoadNative(): Promise<boolean> {
  if (nativeLoaded) return true;

  // 方式 1: import('libquickjs_bridge.so') — HarmonyOS NEXT 推荐方式
  try {
    const mod = await import('libquickjs_bridge.so');
    // NAPI 模块可能直接返回 exports 对象，也可能返回 { default: exports }
    const native = (mod as any).default || mod;
    if (native && typeof native.createEngine === 'function') {
      currentBridge = native as QuickJSBridge;
      nativeLoaded = true;
      console.info('[NAPI] Native module loaded via import(libquickjs_bridge.so)');
      console.info('[NAPI] createEngine type:', typeof native.createEngine);
      return true;
    } else {
      console.warn('[NAPI] import returned but createEngine not found, keys:', Object.keys(native).join(','));
    }
  } catch (e) {
    console.warn('[NAPI] import(libquickjs_bridge.so) failed:', e?.toString()?.substring(0, 120));
  }

  // 方式 2: requireNapi('quickjs_bridge') — 兼容方式
  if (!nativeLoaded) {
    try {
      const native = requireNapi('quickjs_bridge');
      if (native && typeof (native as QuickJSBridge).createEngine === 'function') {
        currentBridge = native as QuickJSBridge;
        nativeLoaded = true;
        console.info('[NAPI] Native module loaded via requireNapi');
        return true;
      } else {
        console.warn('[NAPI] requireNapi returned null or invalid');
      }
    } catch (e) {
      console.warn('[NAPI] requireNapi threw:', e?.toString()?.substring(0, 100));
    }
  }

  console.info('[NAPI] Native module not available, using mock');
  return false;
}

/**
 * 获取当前桥接实例（可能在 tryLoadNative 后被替换）
 */
export function getBridge(): QuickJSBridge {
  return currentBridge;
}

/**
 * QuickJS 原生模块是否已加载成功
 */
export function isNativeLoaded(): boolean {
  return nativeLoaded;
}

// ====== 模块加载时立即尝试同步加载 ======
// 先试 requireNapi（同步的方法）
try {
  const native = requireNapi('quickjs_bridge');
  if (native && typeof (native as QuickJSBridge).createEngine === 'function') {
    currentBridge = native as QuickJSBridge;
    nativeLoaded = true;
    console.info('[NAPI] Native module loaded (sync) via requireNapi');
  }
} catch (_e) { /* will try async import later */ }

export default currentBridge;
