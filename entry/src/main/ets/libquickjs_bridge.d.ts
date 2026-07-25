declare module 'libquickjs_bridge.so' {
  export interface QuickJSBridgeNative {
    createEngine(): number;
    destroyEngine(engineId: number): void;
    executeScript(engineId: number, script: string): string;
    callFunction(engineId: number, functionName: string, argsJson: string): string;
    onHttpResponse(requestId: number, responseText: string, isError: boolean): void;
    registerHttpHandler(engineId: number, callback: Function): void;
    onCookieResponse(requestId: number, result: string): void;
    registerCookieHandler(engineId: number, callback: Function): void;
    onCaptchaResponse(requestId: number, value: string): void;
    registerCaptchaHandler(engineId: number, callback: (requestId: number, imageUrl: string) => void): void;
  }

  const bridge: QuickJSBridgeNative;
  export default bridge;
}
