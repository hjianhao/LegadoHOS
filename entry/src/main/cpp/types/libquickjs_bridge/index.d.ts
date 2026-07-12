/**
 * QuickJS NAPI Bridge 类型声明
 *
 * 对应 napi_bridge.cpp 的 Init 函数导出的 exports 对象。
 * ArkTS 通过 import qjs from 'libquickjs_bridge.so' 获取 exports 对象。
 */
declare namespace quickjs {
  function createEngine(): number;
  function destroyEngine(engineId: number): void;
  function executeScript(engineId: number, script: string): string;
  function callFunction(engineId: number, functionName: string, argsJson: string): string;
  function onHttpResponse(requestId: number, responseBody: string, isError: boolean): void;
  function registerHttpHandler(engineId: number, handler: (requestId: number, url: string, method: string, headersJson: string, body?: string) => void): void;
}

export default quickjs;
