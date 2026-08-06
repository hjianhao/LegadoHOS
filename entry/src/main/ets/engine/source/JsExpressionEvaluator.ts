/**
 * JS 表达式求值器
 *
 * 在独立 Worker 线程中执行 QuickJS 脚本，不阻塞 UI 线程。
 * Worker 内可安全调用 java.ajax()，其同步阻塞只会卡 Worker 线程。
 *
 * 支持的表达式格式：
 *   @js:code              — 整段 JS 代码，返回最后一个表达式的值
 *   {{expression}}        — 内联 JS 表达式，在 URL 模板中使用
 *   <js>code</js>         — JS 代码块，可嵌入规则中
 */
import { BookSource } from '../../model/BookSource';
import { globalScriptEngine } from './ScriptEngine';
import { getPolyfillScript, getAjaxPolyfill } from './ScriptApi';
import { NetUtil } from '../../util/NetUtil';
import { CookieStore } from '../../util/CookieStore';
import { LoginInfoStore } from '../../util/LoginInfoStore';
import { isNativeLoaded } from '../../napi/quickjs_bridge';
import { image } from '@kit.ImageKit';

// Worker 的 QuickJS 引擎没有 polyfill，缓存一份在评估时注入
let cachedPolyfill_: string | null = null;
let cachedAjaxPolyfill_: string | null = null;
function getPolyfillForWorker(): string {
  if (!cachedPolyfill_) {
    // QuickJS 引擎没有 console 对象，需要先注入 console shim
    // 否则 polyfill 中大量的 console.log() 会抛出 ReferenceError
    const consoleShim = `
(function() {
  if (typeof console === 'undefined') {
    globalThis.console = {
      log: function() {},
      info: function() {},
      warn: function() {},
      error: function() {},
      debug: function() {}
    };
  }
})();
`;
    cachedPolyfill_ = consoleShim + '\n' + getPolyfillScript();
  }
  if (!cachedAjaxPolyfill_) {
    cachedAjaxPolyfill_ = getAjaxPolyfill();
  }
  return cachedPolyfill_ + '\n' + cachedAjaxPolyfill_;
}

/**
 * 解开 C++ 桥的 JSON.stringify 包装
 *
 * QuickJS NAPI 桥 (napi_bridge.cpp ExecuteScript) 总是对 JS 返回值调用
 * JS_JSONStringify()，导致字符串被额外加上双引号。此函数逆向解开，
 * 恢复原始的 JS 值。
 *
 * 例如: JS 返回 "hello" → 桥返回 "\"hello\"" → 此函数返回 "hello"
 *       JS 返回 42     → 桥返回 "42"       → 此函数返回 "42"
 *       JS 返回 null   → 桥返回 "null"     → 此函数返回 ""
 */
function unwrapJsResult(raw: string): string {
  if (!raw || raw === 'null' || raw === 'undefined') return '';
  // 原生桥会把 QuickJS 异常作为普通字符串返回。异常文本不能继续参与 URL 拼接，
  // 否则会把脚本错误伪装成 HTTP 403/404，误导书源校验结果。
  if (/^(?:SyntaxError|TypeError|ReferenceError|RangeError|EvalError|URIError|InternalError|Error):/.test(raw.trim())) {
    console.warn('[JsEval] JS returned error:', raw.trim().substring(0, 120));
    return '';
  }
  // 仅尝试解开字符串包装（JSON.parse 对对象/数字/布尔值返回原值）
  try {
    const parsed = JSON.parse(raw) as Object;
    if (typeof parsed === 'string') return parsed as string;
    // 数字、布尔值、对象：保持原样（这些场景不需要解开）
    return raw;
  } catch (_e) {
    // 不是合法 JSON（可能是错误消息），返回原值
    return raw;
  }
}

/**
 * 书源脚本通常在同一个 QuickJS 引擎中反复求值。部分 Android 书源依赖
 * 宽松脚本引擎允许形参与局部变量重名（例如形参 sourceUrl 再声明 let
 * sourceUrl），QuickJS 会直接报 parameter name 冲突；统一降为 var 保持
 * 书源兼容性，也允许引擎复用时安全重声明。
 *
 * 另外，少数历史书源把数组解构箭头函数写成 `map([a, b]=>...)`。这不是
 * ECMAScript 标准语法（标准写法是 `map(([a, b])=>...)`），但 Android 端
 * 的书源生态中确实存在这类写法；仅修复 map/filter/reduce 等调用中的参数
 * 外层括号，不触碰普通数组表达式。
 */
function normalizeSourceScript(script: string): string {
  return script
    .replace(/\blet\s+/g, 'var ')
    .replace(/\bconst\s+/g, 'var ')
    .replace(/\.(map|filter|reduce|forEach)\(\s*(\[[^\]]+\])\s*=>/g, '.$1(($2)=>');
}
import worker from '@ohos.worker';

export interface JsEvalContext {
  /** 搜索关键词（原始未编码） */
  key?: string;
  /** 页码（1-indexed） */
  page?: number;
  /** 基准 URL（书源根域名） */
  baseUrl?: string;
  /** 当前书源对象 */
  source?: Partial<BookSource>;
  /** 书源 JS 库（jsLib），在变量注入前加载 */
  jsLib?: string;
  /** 书源变量的 JSON 字符串（用于 source.getVariable/setVariable 持久化） */
  variableBlob?: string;
  /** 书源登录信息的 JSON 字符串（用于 source.getLoginInfo/getLoginInfoMap） */
  loginInfoJson?: string;
  /** 额外自定义变量 */
  [key: string]: unknown;
}

interface WorkerEvalResult {
  value: string;
  loginHeader: string;
}

export class JsExpressionEvaluator {
  /**
   * 验证码输入回调：Worker 请求时调用，返回 Promise<string> 等待用户输入。
   * image 为通过应用 HTTP 栈（带 Cookie）抓取的验证码图片，
   * 保证取图会话与后续提交会话一致；抓取失败时为 null，调用方可退回 URL 加载。
   */
  static captchaHandler: ((url: string, image?: image.PixelMap | null) => Promise<string>) | null = null;
  private static workerInstance: worker.ThreadWorker | null = null;
  private static workerPromise: Map<number, {
    resolve: (v: string, loginHeader?: string) => void;
    reject: (e: Error) => void;
  }> = new Map();
  private static nextId: number = 1;
  private static workerReady: boolean = false;
  private static workerInitPromise: Promise<boolean> | null = null;
  // QuickJS 的同步网络/验证码桥会占住 Worker。串行派发可让超时从真正执行时
  // 开始计算，也避免一个慢请求把已经排队的脚本全部误判为超时。
  private static workerEvalQueue: Promise<void> = Promise.resolve();
  /** Worker 端已缓存的 jsLib 所属书源 key（sourceUrl），切换书源时重新传输。 */
  private static lastWorkerJsLibKey_: string = '';

  /**
   * source.putLoginHeader() 在 QuickJS 中修改的是 JS 对象，需在本次求值
   * 返回后同步回 ArkTS source，后续详情/目录请求才能带上 Authorization。
   */
  private static applyLoginHeader_(ctx: JsEvalContext, header: string): void {
    if (!ctx.source || !header || header === 'null' || header === 'undefined') return;
    const src = ctx.source as Record<string, unknown>;
    src['loginHeader'] = header;
    // 现有网络层统一从 source.header 组装请求头；把动态登录头合并进去，
    // 保留原书源 header，并避免修改数据库中的持久化源配置。
    let merged: Record<string, unknown> = {};
    const original = src['header'];
    if (typeof original === 'string' && original.trim() && !/^@js:|^<js>/i.test(original.trim())) {
      try {
        const parsed = JSON.parse(original) as Record<string, unknown>;
        if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) merged = parsed;
      } catch (_e) { /* 非 JSON 请求头规则保持原样，不能覆盖 */ }
    }
    try {
      const login = JSON.parse(header) as Record<string, unknown>;
      if (login && typeof login === 'object' && !Array.isArray(login)) {
        Object.assign(merged, login);
        src['header'] = JSON.stringify(merged);
      }
    } catch (_e) { /* 登录头不是 JSON 时仅保留 loginHeader */ }
  }

  private static captureLoginHeader_(ctx: JsEvalContext): void {
    if (!ctx.source) return;
    try {
      const raw = globalScriptEngine.evaluateJsSync(
        '(typeof source!=="undefined"&&source&&typeof source.getLoginHeader==="function")?' +
        '(source.getLoginHeader()||""):""'
      );
      this.applyLoginHeader_(ctx, unwrapJsResult(raw).trim());
    } catch (_e) { /* source 方法不存在或脚本执行失败时忽略 */ }
  }

  /**
   * 获取或创建 Worker 实例
   */
  private static async getWorker(): Promise<worker.ThreadWorker | null> {
    if (this.workerReady && this.workerInstance) return this.workerInstance;
    // createWorker() 会在等待 init_done 前先写入 workerInstance。并发调用必须先等
    // workerInitPromise，不能仅凭实例已存在就把未就绪的 Worker 返回给调用方。
    if (this.workerInitPromise) {
      const ready = await this.workerInitPromise;
      return ready ? this.workerInstance : null;
    }
    if (this.workerInstance) this.terminateWorker();

    this.workerInitPromise = this.createWorker();
    const ready = await this.workerInitPromise;
    return ready ? this.workerInstance : null;
  }

  private static async createWorker(): Promise<boolean> {
    try {
      // 写法一：{moduleName}/ets/{relativePath} (HarmonyOS NEXT 推荐)
      const workerInstance = new worker.ThreadWorker('entry/ets/workers/JsEvalWorker');
      
      // 用独立 Promise 处理初始化
      let initResolve: (ok: boolean) => void;
      const initPromise = new Promise<boolean>((resolve) => { initResolve = resolve; });

      workerInstance.onmessage = (event: any): void => {
        const msg = event.data;
        if (!msg) return;

        if (msg.type === 'captcha_result') {
          // Worker 验证码请求的结果 → 通过 pending 返回
          const pending = this.workerPromise.get(msg.id);
          if (pending) {
            this.workerPromise.delete(msg.id);
            pending.resolve(String(msg.value || ''), '');
          }
        } else if (msg.type === 'result' || msg.type === 'error') {
          const pending = this.workerPromise.get(msg.id);
          if (pending) {
            this.workerPromise.delete(msg.id);
            if (msg.type === 'result') {
              pending.resolve(msg.value || 'null', String(msg.loginHeader || ''));
            } else {
              pending.reject(new Error(msg.error || 'Worker evaluation error'));
            }
          }
        } else if (msg.type === 'init_done') {
          this.workerReady = msg.ok === true;
          initResolve(msg.ok === true);
        } else if (msg.type === 'destroy_done') {
          this.workerInstance = null;
          this.workerReady = false;
        } else if (msg.type === 'cookie_set') {
          // Worker 侧捕获的 Set-Cookie / cookie.setCookie → 主线程持久化
          const store = CookieStore.getInstance();
          if (msg.cookie) {
            void store.setByHost(String(msg.host || ''), String(msg.cookie));
          } else {
            void store.removeByHost(String(msg.host || ''));
          }
        } else if (msg.type === 'cookie_remove') {
          void CookieStore.getInstance().removeByHost(String(msg.host || ''));
        } else if (msg.type === 'captcha') {
          // Worker 请求验证码输入 → 主线程显示 CaptchaDialog
          const captchaUrl = String(msg.url || '');
          const captchaId = msg.id;
          const handler = JsExpressionEvaluator.captchaHandler;
          const replyCaptcha = (code: string): void => {
            try {
              // 先把最新 Cookie 快照推给 Worker（取验证码图可能刷新了会话 Cookie），
              // 保证 Worker 随后提交验证码的 POST 与取图是同一会话
              this.workerInstance?.postMessage({ type: 'cookie_sync', cookies: CookieStore.getInstance().getSnapshot() });
              this.workerInstance?.postMessage({ type: 'captcha_result', id: captchaId, value: code });
            } catch (_e) { /* worker may be gone */ }
          };
          if (!handler) {
            replyCaptcha('');
            return;
          }
          // 验证码图片必须走应用自己的 HTTP 栈（带 CookieStore），
          // 否则系统图片加载器会另开会话，服务器校验永远对不上
          NetUtil.httpGetBinary(captchaUrl).then(async (buf: ArrayBuffer) => {
            let pm: image.PixelMap | null = null;
            try {
              pm = await image.createImageSource(buf).createPixelMap();
            } catch (_e) { /* 解码失败则退回 URL 加载 */ }
            handler(captchaUrl, pm).then(replyCaptcha);
          }).catch((_e: Error) => {
            handler(captchaUrl, null).then(replyCaptcha);
          });
        }
      };

      workerInstance.onerror = (error: any): void => {
        console.error('[JsEval] Worker error:', error.message);
        this.workerReady = false;
        initResolve(false);
        for (const [id, pending] of this.workerPromise) {
          pending.reject(new Error('Worker crashed'));
          this.workerPromise.delete(id);
        }
      };

      this.workerInstance = workerInstance;

      // 发送 init 消息触发 Worker 初始化；polyfill 随初始化一次性下发，
      // 之后每次 eval 不再全量传输（SharedHeap 传输是批量校验 OOM 主因之一）。
      workerInstance.postMessage({ type: 'init', polyfill: getPolyfillForWorker() });

      // 等待初始化完成或超时
      const timeoutPromise = new Promise<boolean>((resolve) => {
        setTimeout(() => resolve(false), 5000);
      });
      const ok = await Promise.race([initPromise, timeoutPromise]);
      this.workerReady = ok;
      if (ok) {
        console.info('[JsEval] Worker initialized successfully');
        // 同步网络配置（DNS/Proxy/超时）到 Worker
        this.syncNetworkConfigToWorker();
        // 同步 Cookie 快照到 Worker（JS 内 cookie.* 与请求注入都依赖它）
        try {
          this.workerInstance?.postMessage({ type: 'cookie_sync', cookies: CookieStore.getInstance().getSnapshot() });
        } catch (_e) { /* ignore */ }
      } else {
        console.warn('[JsEval] Worker init failed (timeout), falling back');
        this.terminateWorker();
      }
      return ok;
    } catch (e) {
      console.warn('[JsEval] Worker creation failed:', e?.toString()?.substring(0, 100));
      this.workerInstance = null;
      this.workerReady = false;
      return false;
    } finally {
      this.workerInitPromise = null;
    }
  }

  /**
   * 向 Worker 发送消息并等待响应
   */
  private static sendToWorker(type: string, timeoutMs: number = 30000, code?: string,
    jsLibKey: string = '', jsLib?: string): Promise<WorkerEvalResult> {
    return new Promise<WorkerEvalResult>((resolve, reject) => {
      const id = this.nextId++;
      const timer = setTimeout((): void => {
        this.workerPromise.delete(id);
        reject(new Error('Worker timeout'));
      }, timeoutMs);

      this.workerPromise.set(id, {
        resolve: (v: string, loginHeader: string = ''): void => {
          clearTimeout(timer);
          resolve({ value: v, loginHeader: loginHeader });
        },
        reject: (e: Error): void => {
          clearTimeout(timer);
          reject(e);
        },
      });

      try {
        this.workerInstance!.postMessage({ type, id, code, jsLibKey, jsLib });
      } catch (e) {
        clearTimeout(timer);
        this.workerPromise.delete(id);
        reject(e);
      }
    });
  }

  /**
   * 串行执行必须走 Worker 的脚本。
   * Worker 的创建也放进队列，前一个任务超时并销毁 Worker 后，后一个任务能重新初始化。
   */
  private static enqueueWorkerEvaluation(timeoutMs: number, code: string,
    jsLibKey: string = '', jsLib?: string): Promise<WorkerEvalResult> {
    const task = this.workerEvalQueue
      .catch((): void => {})
      .then(async (): Promise<WorkerEvalResult> => {
        const workerInstance = await this.getWorker();
        if (!workerInstance) throw new Error('Worker unavailable');
        try {
          return await this.sendToWorker('eval', timeoutMs, code, jsLibKey, jsLib);
        } catch (err) {
          this.terminateWorker();
          throw err;
        }
      });
    this.workerEvalQueue = task.then((): void => {}, (): void => {});
    return task;
  }

  /**
   * 终止 Worker
   */
  private static terminateWorker(): void {
    if (this.workerInstance) {
      try {
        this.workerInstance.terminate();
      } catch (_e) { /* ignore */ }
      this.workerInstance = null;
      this.workerReady = false;
    }
    // 新 Worker 没有 jsLib/polyfill 缓存，必须重新传输
    this.lastWorkerJsLibKey_ = '';
  }

  /**
   * 释放 Worker 及其 QuickJS 引擎（批量校验等重负载结束后调用）。
   * 引擎全局对象会被所有书源的 jsLib 反复填充（50 个源批量校验后函数定义
   * 堆积数十 KB~MB 级），且 shared heap 随每次 postMessage 增长；主动销毁
   * 可回收这些内存，下次求值时按需重建。
   */
  static releaseWorker(): void {
    if (this.workerInstance || this.workerInitPromise) {
      this.terminateWorker();
      this.workerInitPromise = null;
    }
  }

  /**
   * 同步网络配置（DNS/Proxy/超时）到 Worker
   * 在 Worker 初始化后和网络设置变更时调用
   */
  static syncNetworkConfigToWorker(): void {
    if (!this.workerInstance) return;
    const cfg = NetUtil.getNetworkConfig();
    try {
      this.workerInstance.postMessage({ type: 'config', config: cfg });
      console.info('[JsEval] Network config synced to Worker: dns=', cfg.dnsEnabled, 'proxy=', cfg.proxyHost || 'none', 'timeout=', cfg.timeout);
    } catch (err) {
      console.warn('[JsEval] sync network config failed:', (err as Error).message);
    }
  }

  /**
   * 求值 JS 表达式（异步）
   *
   * 优先使用 Worker 线程执行（不阻塞 UI），
   * Worker 不可用时回退到主线程 ScriptEngine。
   *
   * 返回 JS 执行结果的字符串表示。
   */
  static async evaluate(code: string, ctx: JsEvalContext): Promise<string> {
    if (!code || !code.trim()) return '';

    const setupCode = JsExpressionEvaluator.buildContextScript(ctx);
    // let/const → var：引擎复用时 let 重声明会报错，var 不报
    const safeCode = normalizeSourceScript(code);
    const fullScript = `${setupCode}\n${safeCode}`;
    // java.get() 无第二参数时是书源局部变量读取；带请求参数时是同步网络调用，
    // 必须进入 Worker，避免主线程求值拿不到异步 HTTP 结果或被慢请求阻塞。
    const requiresWorker = /java\.(ajax|post|connect)\s*\(|java\.get\s*\([^,\)]*,|cookie\.(getCookie|setCookie|replaceCookie|removeCookie)\s*\(|(?:java\.)?getVerificationCode\s*\(|__captchaOp\s*\(/.test(fullScript);

    // 原生主线程引擎可用时，普通表达式直接执行；Worker 即使已经创建也不抢占它们。
    if (!requiresWorker && isNativeLoaded()) {
      try {
        const result = await globalScriptEngine.executeScript(fullScript);
        const value = unwrapJsResult(result);
        JsExpressionEvaluator.captureLoginHeader_(ctx);
        return value;
      } catch (err) {
        console.warn('[JsEval] Main engine failed, falling back to Worker:',
          (err instanceof Error) ? err.message.substring(0, 80) : String(err).substring(0, 80));
      }
    }

    // 同步网络/验证码脚本必须在 Worker 执行；非原生环境的普通脚本也在这里降级。
    try {
      // polyfill（console shim + 通用脚本 + ajax mock）已在 Worker 初始化时
      // 一次性注入并执行；jsLib 按源在 Worker 端缓存，仅在切换书源时传输。
      // 之前每次求值都全量传输 36KB 级 polyfill + jsLib，批量校验时
      // SharedHeap 反复分配导致 OOM。
      const workerScript = JsExpressionEvaluator.buildContextScript(ctx, false) + '\n' + safeCode;
      // 提取 jsLib（与 buildContextScript 相同的取值逻辑），只在变化时随消息传输
      let jsLibStr = ctx.jsLib || '';
      if (!jsLibStr && ctx.source) {
        const src = ctx.source as Record<string, unknown>;
        jsLibStr = (src.jsLib as string) || '';
      }
      jsLibStr = normalizeSourceScript(jsLibStr);
      const srcObj = ctx.source as Record<string, unknown> | undefined;
      const jsLibKey = jsLibStr && jsLibStr.trim()
        ? String(srcObj?.['sourceUrl'] || srcObj?.['bookSourceUrl'] || ctx.baseUrl || '') : '';
      const jsLibChanged = jsLibKey !== JsExpressionEvaluator.lastWorkerJsLibKey_;
      if (jsLibChanged) {
        JsExpressionEvaluator.lastWorkerJsLibKey_ = jsLibKey;
      }
      // 含验证码输入的脚本要留给用户操作时间（__captchaOp 阻塞上限 120s）
      const evalTimeout = /getVerificationCode|__captchaOp/.test(fullScript) ? 125000 : 65000;
      const workerResult = await this.enqueueWorkerEvaluation(evalTimeout, workerScript,
        jsLibKey, jsLibChanged ? (jsLibStr || '') : undefined);
      this.applyLoginHeader_(ctx, unwrapJsResult(workerResult.loginHeader).trim());
      return unwrapJsResult(workerResult.value);
    } catch (e) {
      console.warn('[JsEval] Worker failed:', e?.toString()?.substring(0, 80));
      return '';
    }
  }

  /**
   * 同步求值（用于无法 await 的上下文）
   * 仅用于简单表达式，不会触发 java.ajax()
   */
  static evaluateSync(code: string, ctx: JsEvalContext): string {
    if (!code || !code.trim()) return '';
    const setupCode = JsExpressionEvaluator.buildContextScript(ctx);
    const safeCode = normalizeSourceScript(code);
    const fullScript = `${setupCode}\n${safeCode}`;
    try {
      const result = globalScriptEngine.evaluateJsSync(fullScript);
      // 原生桥会把 JS 异常作为普通字符串返回（如 "ReferenceError: cover is not defined"），
      // 必须用 unwrapJsResult 过滤，否则错误文本会被调用方当成字段值（封面 URL 等）。
      const value = unwrapJsResult(result);
      JsExpressionEvaluator.captureLoginHeader_(ctx);
      return value;
    } catch (_e) {
      return '';
    }
  }

  // ... 以下方法保持不变 ...

  /**
   * 处理规则字段中的 @js: 后缀（result 后处理）
   *
   * 规则提取完成后，如果规则包含 @js:code，则执行 JS 代码，
   * 其中 result 变量为 @js: 之前提取到的值。
   *
   * 格式示例:
   *   a.0@href@js:result.replace(/foo/,"bar")
   *   $.path@js:java.aesBase64DecodeToString(result,...)
   *   @@text##regex##repl@js:result.trim()
   *
   * @param rule     原始规则字符串
   * @param value    已提取的值（将作为 result 变量注入）
   * @param ctx      额外的上下文变量（可选）
   * @returns        JS 处理后的值，或原值（不含 @js: 时）
   */
  static processJsResult(rule: string, value: string, ctx?: JsEvalContext): string {
    if (!rule || !value) return value;

    // 查找 @js: 位置（注意排除 @@js:，那是 Legado CSS @@className 语法）
    const jsIdx = rule.indexOf('@js:');
    if (jsIdx < 0) return value;

    // 前面有另一个 @ 则是 @@js:，不匹配
    if (jsIdx > 0 && rule[jsIdx - 1] === '@') return value;

    // 提取 @js: 后的 JS 代码
    const jsCode = rule.substring(jsIdx + 4).trim();
    if (!jsCode) return value;

    // 执行 JS 代码，注入 result 和上下文变量
    const combinedCtx: JsEvalContext = { ...(ctx || {}), result: value };
    const evalResult = JsExpressionEvaluator.evaluateSync(jsCode, combinedCtx);
    if (evalResult && evalResult !== 'null' && evalResult !== 'undefined') {
      try {
        const parsed = JSON.parse(evalResult);
        return typeof parsed === 'string' ? parsed : String(parsed);
      } catch (_e) {
        return evalResult.replace(/^['"`]|['"`]$/g, '');
      }
    }
    return value;
  }

  /** 异步执行规则的 @js: 后处理，支持 Worker QuickJS 降级。 */
  static async processJsResultAsync(rule: string, value: string, ctx?: JsEvalContext): Promise<string> {
    if (!rule || !value) return value;
    const jsIdx = rule.indexOf('@js:');
    if (jsIdx < 0 || (jsIdx > 0 && rule[jsIdx - 1] === '@')) return value;

    const jsCode = rule.substring(jsIdx + 4).trim();
    if (!jsCode) return value;

    const combinedCtx: JsEvalContext = { ...(ctx || {}), result: value };
    const evalResult = await JsExpressionEvaluator.evaluate(jsCode, combinedCtx);
    if (evalResult && evalResult !== 'null' && evalResult !== 'undefined') {
      try {
        const parsed = JSON.parse(evalResult);
        return typeof parsed === 'string' ? parsed : String(parsed);
      } catch (_e) {
        return evalResult.replace(/^['"`]|['"`]$/g, '');
      }
    }
    return value;
  }

  /**
   * 从规则中剥离 @js: 后缀，返回纯规则部分
   * 用于在提取前将 @js: 部分移除，避免 HtmlParser 错误的 CSS 解析
   *
   * @param rule 原始规则
   * @returns { rule, jsCode } — 纯规则部分和 JS 代码（可能为空）
   */
  static stripJsSuffix(rule: string): { rule: string; jsCode: string } {
    if (!rule) return { rule: '', jsCode: '' };
    const jsIdx = rule.indexOf('@js:');
    if (jsIdx >= 0 && !(jsIdx > 0 && rule[jsIdx - 1] === '@')) {
      return {
        rule: rule.substring(0, jsIdx).trim(),
        jsCode: rule.substring(jsIdx + 4).trim(),
      };
    }
    // Legado 书源大量使用 field<js>...</js>##regex##replacement，
    // 不能把 <js> 块留在 CSS 选择器中，否则 a@href 会被解析成无效选择器。
    // 保留 </js> 后面的 ## 后处理规则，供调用方在 JS 返回值上继续执行。
    const jsMatch = rule.match(/<js>([\s\S]*?)<\/js>/i);
    if (!jsMatch || jsMatch.index === undefined) return { rule, jsCode: '' };
    const before = rule.substring(0, jsMatch.index).trim();
    const after = rule.substring(jsMatch.index + jsMatch[0].length).trim();
    return {
      rule: (before + (after ? ' ' + after : '')).trim(),
      jsCode: jsMatch[1].trim(),
    };
  }

  /**
   * 从字符串中提取 JS 代码（自动识别前缀）
   *
   * @param raw 原始规则字符串
   * @returns { code, rest } — JS 代码和剩余部分
   */
  static extractJsCode(raw: string): { code: string; rest: string } {
    if (!raw) return { code: '', rest: '' };

    const trimmed = raw.trim();

    // @js:... 格式
    if (trimmed.startsWith('@js:')) {
      const firstNewline = trimmed.indexOf('\n');
      if (firstNewline < 0) {
        return { code: trimmed.substring(4).trim(), rest: '' };
      }
      return { code: trimmed.substring(4, firstNewline).trim(), rest: trimmed.substring(firstNewline + 1).trim() };
    }

    // <js>...</js> 格式
    if (trimmed.includes('<js>')) {
      const jsMatch = trimmed.match(/<js>([\s\S]*?)<\/js>/);
      if (jsMatch) {
        const rest = trimmed.replace(/<js>[\s\S]*?<\/js>/, '').trim();
        return { code: jsMatch[1].trim(), rest };
      }
    }

    return { code: '', rest: raw };
  }

  /**
   * 判断字符串是否包含 JS 表达式
   */
  static hasJsExpression(str: string): boolean {
    if (!str) return false;
    return str.includes('@js:') || str.includes('<js>') || /\{\{[^}]+\}\}/.test(str);
  }

  /**
   * 构建上下文脚本——将变量注入到 JS 全局作用域
   * 使用 var 声明而非 globalThis 赋值，使变量在 eval 中可直接访问
   */
  static buildContextScript(ctx: JsEvalContext, includeJsLib: boolean = true): string {
    const parts: string[] = [];

    // 书源 jsLib — 最先加载，定义 hosts、getCloudSettings 等核心函数
    // includeJsLib=false 时由调用方单独提取 jsLib（Worker 端按源缓存，避免
    // 每次求值全量传输大段 jsLib 文本造成 SharedHeap 压力）。
    let jsLibStr = ctx.jsLib || '';
    if (!jsLibStr && ctx.source) {
      const src = ctx.source as Record<string, unknown>;
      jsLibStr = (src.jsLib as string) || '';
    }
    if (includeJsLib && jsLibStr && jsLibStr.trim()) {
      parts.push(normalizeSourceScript(jsLibStr.trim()));
    }

    // key / keyword
    if (ctx.key !== undefined) {
      const encoded = encodeURIComponent(String(ctx.key));
      parts.push(`var key=${JSON.stringify(ctx.key)};`);
      parts.push(`var keyword=${JSON.stringify(ctx.key)};`);
      parts.push(`var encodeKey=${JSON.stringify(encoded)};`);
    }

    // page / pageNum
    if (ctx.page !== undefined) {
      const p = typeof ctx.page === 'number' ? ctx.page : parseInt(String(ctx.page), 10);
      parts.push(`var page=${isNaN(p) ? 1 : p};`);
      parts.push(`var pageNum=${isNaN(p) ? 2 : p + 1};`);
    }

    // baseUrl
    if (ctx.baseUrl !== undefined) {
      parts.push(`var baseUrl=${JSON.stringify(ctx.baseUrl)};`);
    }

    // source 对象 — 注入所有字段，与 Legado Android 一致
    // 安卓版直接把整个 BookSource Java 对象注入 Rhino（FEATURE_ENABLE_JAVA_MAP_ACCESS）
    // 所以 JS 可访问 source 的所有字段; 我们逐个字段注入保持兼容
    if (ctx.source !== undefined) {
      const src = ctx.source as Record<string, unknown>;
      const srcObj: Record<string, unknown> = {};

      // 安卓版使用 bookSourceUrl/bookSourceName 等 JSON 原字段名，
      // 我们的 ArkTS 接口使用 sourceUrl/sourceName，加别名
      const aliasMap: Record<string, string[]> = {
        sourceUrl: ['bookSourceUrl'],
        sourceName: ['bookSourceName'],
        group: ['bookSourceGroup', 'sourceGroup'],
        sourceType: ['bookSourceType'],
      };

      for (const key of Object.keys(src)) {
        const val = src[key];
        if (val === undefined || val === null) continue;
        if (typeof val === 'string') {
          if (!val) continue; // 跳过空字符串
          srcObj[key] = val;
          const aliases = aliasMap[key];
          if (aliases) for (const alias of aliases) srcObj[alias] = val;
        } else if (typeof val === 'number' || typeof val === 'boolean') {
          srcObj[key] = val;
          const aliases = aliasMap[key];
          if (aliases) for (const alias of aliases) srcObj[alias] = val;
        }
      }
      // 保证 source.key 始终存在（Legado JS 兼容）
      if (!srcObj['key']) {
        srcObj['key'] = srcObj['sourceUrl'] || srcObj['bookSourceUrl'] || '';
      }

      // source 序列化为 JSON 后注入，再添加方法
      parts.push(`var source=${JSON.stringify(srcObj)};`);
      // getKey() — URL-encoded source URL，用于 cookie 操作
      parts.push(`if(typeof source.getKey==='undefined')source.getKey=function(){return encodeURIComponent(source.sourceUrl||source.bookSourceUrl||'');};`);
      // getUrl() — 返回 sourceUrl（兼容）
      parts.push(`if(typeof source.getUrl==='undefined')source.getUrl=function(){return source.sourceUrl||source.bookSourceUrl||'';};`);
      // getVariable() / setVariable() — 书源变量持久化（用于 {{Get('url')}} 等 JS 表达式）。
      // Android BaseSource.getVariable() 在未初始化时返回空字符串；保持这个
      // 语义，书源的 loginUrl 才能通过 `if (v == "")` 初始化默认变量。
      const initialVars = ctx.variableBlob || '';
      const varsLiteral = initialVars ? JSON.stringify(initialVars) : '""';
      parts.push(`(function(){var _vars=${varsLiteral};` +
        `if(typeof source.getVariable==='undefined')source.getVariable=function(){return typeof _vars==='string'?_vars:JSON.stringify(_vars);};` +
        `if(typeof source.setVariable==='undefined')source.setVariable=function(v){_vars=v;};` +
        `})();`);

      // 登录请求头（对应 Android BaseSource.getLoginHeader* / putLoginHeader）。
      // 书源的 jsLib 经常先用 getLoginHeaderMap() 判断是否需要刷新 Token；
      // 如果只注入 getVariable，纯 URL 规则会直接得到 “TypeError: not a function”。
      const initialLoginHeader = typeof src['loginHeader'] === 'string' ? src['loginHeader'] : '';
      const loginHeaderLiteral = JSON.stringify(initialLoginHeader);
      parts.push(`(function(){var _loginHeader=${loginHeaderLiteral};` +
        `if(typeof source.getLoginHeader==='undefined')source.getLoginHeader=function(){return _loginHeader||null;};` +
        `if(typeof source.getLoginHeaderMap==='undefined')source.getLoginHeaderMap=function(){` +
        `if(!_loginHeader)return null;try{var _h=typeof _loginHeader==='string'?JSON.parse(_loginHeader):_loginHeader;` +
        `if(!_h||typeof _h!=='object')return null;` +
        `if(typeof _h.get!=='function')_h.get=function(k){return _h[k];};return _h;}catch(_e){return null;}};` +
        `if(typeof source.putLoginHeader==='undefined')source.putLoginHeader=function(v){` +
        `_loginHeader=typeof v==='string'?v:JSON.stringify(v||{});return _loginHeader;};` +
        `if(typeof source.removeLoginHeader==='undefined')source.removeLoginHeader=function(){_loginHeader='';};` +
        `})();`);

      // getLoginInfo / getLoginInfoMap / putLoginInfo / removeLoginInfo — 登录凭据（对应 Android BaseSource）
      // 共享同一承载对象：getLoginInfoMap().put() 的修改直接反映到 getLoginInfo()
      // 未显式传入 loginInfoJson 时，自动读取该源已保存的登录信息（搜索/目录/正文等 JS 都能拿到）
      let loginInfoJson = ctx.loginInfoJson;
      if (loginInfoJson === undefined) {
        const sourceKey = String(srcObj['sourceUrl'] || srcObj['bookSourceUrl'] || '');
        if (sourceKey) {
          try {
            loginInfoJson = LoginInfoStore.getInstance().get(sourceKey);
          } catch (_e) { /* Store 未初始化时为空 */ }
        }
      }
      const loginInfoLiteral = JSON.stringify(loginInfoJson || '');
      parts.push(`(function(){var _obj={};try{var _raw=${loginInfoLiteral};if(_raw){var _p=JSON.parse(_raw);if(_p&&typeof _p==='object')_obj=_p;}}catch(_e){}` +
        `if(typeof source.getLoginInfo==='undefined')source.getLoginInfo=function(){var s=JSON.stringify(_obj);return s==='{}'?null:s;};` +
        `if(typeof source.getLoginInfoMap==='undefined')source.getLoginInfoMap=function(){return {` +
        `get:function(k){return _obj[k]!==undefined?_obj[k]:null;},` +
        `put:function(k,v){_obj[k]=String(v);return v;},` +
        `remove:function(k){delete _obj[k];},` +
        `containsKey:function(k){return _obj[k]!==undefined;},` +
        `isEmpty:function(){for(var k in _obj)return false;return true;},` +
        `keySet:function(){return Object.keys(_obj);},` +
        `toString:function(){return JSON.stringify(_obj);}` +
        `};};` +
        `if(typeof source.putLoginInfo==='undefined')source.putLoginInfo=function(info){try{var p=typeof info==='string'?JSON.parse(info):info;_obj=(p&&typeof p==='object')?p:{};}catch(_e){_obj={};}return true;};` +
        `if(typeof source.removeLoginInfo==='undefined')source.removeLoginInfo=function(){_obj={};};` +
        `})();`);
    }

    // 注入自定义额外变量
    for (const [k, v] of Object.entries(ctx)) {
      if (['key', 'page', 'baseUrl', 'source', 'loginInfoJson'].includes(k)) continue;
      if (typeof v === 'string') {
        parts.push(`var ${k}=${JSON.stringify(v)};`);
      } else if (typeof v === 'number') {
        parts.push(`var ${k}=${v};`);
      } else if (typeof v === 'boolean') {
        parts.push(`var ${k}=${v};`);
      } else if (v !== null && v !== undefined) {
        parts.push(`var ${k}=${JSON.stringify(v)};`);
      }
    }

    return parts.join('\n');
  }
}
