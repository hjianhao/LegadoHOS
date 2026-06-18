/**
 * QuickJS NAPI Bridge 类型声明
 *
 * 对应 napi_bridge.cpp: NAPI_MODULE(quickjs_bridge, Init)
 * 导出的 exports 对象包含以下函数。
 * import qjs from 'libquickjs_bridge.so' 获取 exports 对象。
 */
export function createEngine(): number;
export function destroyEngine(engineId: number): void;
export function executeScript(engineId: number, script: string): string;
export function callFunction(engineId: number, functionName: string, argsJson: string): string;
export function onHttpResponse(requestId: number, responseBody: string, isError: boolean): void;
export function registerHttpHandler(handler: (requestId: number, url: string, method: string, headersJson: string, body?: string) => void): void;
