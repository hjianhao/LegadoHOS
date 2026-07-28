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

export class JsExpressionEvaluator {
  /**
   * 验证码输入回调：Worker 请求时调用，返回 Promise<string> 等待用户输入。
   * image 为通过应用 HTTP 栈（带 Cookie）抓取的验证码图片，
   * 保证取图会话与后续提交会话一致；抓取失败时为 null，调用方可退回 URL 加载。
   */
  static captchaHandler: ((url: string, image?: image.PixelMap | null) => Promise<string>) | null = null;
  private static workerInstance: worker.ThreadWorker | null = null;
  private static workerPromise: Map<number, { resolve: (v: string) => void; reject: (e: Error) => void }> = new Map();
  private static nextId: number = 1;
  private static workerReady: boolean = false;
  private static workerInitPromise: Promise<boolean> | null = null;
  // QuickJS 的同步网络/验证码桥会占住 Worker。串行派发可让超时从真正执行时
  // 开始计算，也避免一个慢请求把已经排队的脚本全部误判为超时。
  private static workerEvalQueue: Promise<void> = Promise.resolve();

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
            pending.resolve(String(msg.value || ''));
          }
        } else if (msg.type === 'result' || msg.type === 'error') {
          const pending = this.workerPromise.get(msg.id);
          if (pending) {
            this.workerPromise.delete(msg.id);
            if (msg.type === 'result') {
              pending.resolve(msg.value || 'null');
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

      // 发送 init 消息触发 Worker 初始化
      workerInstance.postMessage({ type: 'init' });

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
  private static sendToWorker(type: string, timeoutMs: number = 30000, code?: string): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      const id = this.nextId++;
      const timer = setTimeout((): void => {
        this.workerPromise.delete(id);
        reject(new Error('Worker timeout'));
      }, timeoutMs);

      this.workerPromise.set(id, {
        resolve: (v: string): void => {
          clearTimeout(timer);
          resolve(v);
        },
        reject: (e: Error): void => {
          clearTimeout(timer);
          reject(e);
        },
      });

      try {
        this.workerInstance!.postMessage({ type, id, code });
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
  private static enqueueWorkerEvaluation(timeoutMs: number, code: string): Promise<string> {
    const task = this.workerEvalQueue
      .catch((): void => {})
      .then(async (): Promise<string> => {
        const workerInstance = await this.getWorker();
        if (!workerInstance) throw new Error('Worker unavailable');
        try {
          return await this.sendToWorker('eval', timeoutMs, code);
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
    const safeCode = code.replace(/\blet\s+/g, 'var ').replace(/\bconst\s+/g, 'var ');
    const fullScript = `${setupCode}\n${safeCode}`;
    // java.get() 只是书源局部变量读取，可以直接在主线程求值。只有同步网络、
    // Cookie 和验证码桥必须进入 Worker，否则普通 URL 计算会被慢请求一起堵住。
    const requiresWorker = /java\.(ajax|post|connect)\s*\(|cookie\.(getCookie|setCookie|replaceCookie|removeCookie)\s*\(|(?:java\.)?getVerificationCode\s*\(|__captchaOp\s*\(/.test(fullScript);

    // 原生主线程引擎可用时，普通表达式直接执行；Worker 即使已经创建也不抢占它们。
    if (!requiresWorker && isNativeLoaded()) {
      try {
        const result = await globalScriptEngine.executeScript(fullScript);
        return unwrapJsResult(result);
      } catch (err) {
        console.warn('[JsEval] Main engine failed, falling back to Worker:',
          (err instanceof Error) ? err.message.substring(0, 80) : String(err).substring(0, 80));
      }
    }

    // 同步网络/验证码脚本必须在 Worker 执行；非原生环境的普通脚本也在这里降级。
    try {
      const workerScript = getPolyfillForWorker() + '\n' + fullScript;
      // 含验证码输入的脚本要留给用户操作时间（__captchaOp 阻塞上限 120s）
      const evalTimeout = /getVerificationCode|__captchaOp/.test(fullScript) ? 125000 : 65000;
      const result = await this.enqueueWorkerEvaluation(evalTimeout, workerScript);
      return unwrapJsResult(result);
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
    const safeCode = code.replace(/\blet\s+/g, 'var ').replace(/\bconst\s+/g, 'var ');
    const fullScript = `${setupCode}\n${safeCode}`;
    try {
      const result = globalScriptEngine.evaluateJsSync(fullScript);
      return result;
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
    if (jsIdx < 0) return { rule, jsCode: '' };
    if (jsIdx > 0 && rule[jsIdx - 1] === '@') return { rule, jsCode: '' };
    return {
      rule: rule.substring(0, jsIdx).trim(),
      jsCode: rule.substring(jsIdx + 4).trim(),
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
  static buildContextScript(ctx: JsEvalContext): string {
    const parts: string[] = [];

    // 书源 jsLib — 最先加载，定义 hosts、getCloudSettings 等核心函数
    if (ctx.jsLib && ctx.jsLib.trim()) {
      parts.push(ctx.jsLib);
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
      // getVariable() / setVariable() — 书源变量持久化（用于 {{Get('url')}} 等 JS 表达式）
      // 变量为空时初始化为 null（而非 '{}'），使 loginUrl 中的
      // JSON.parse(source.getVariable()) 抛异常，触发 catch 分支执行 put(original) 设置默认变量
      const initialVars = ctx.variableBlob || '';
      const varsLiteral = initialVars ? JSON.stringify(initialVars) : 'null';
      parts.push(`(function(){var _vars=${varsLiteral};` +
        `if(typeof source.getVariable==='undefined')source.getVariable=function(){return typeof _vars==='string'?_vars:JSON.stringify(_vars);};` +
        `if(typeof source.setVariable==='undefined')source.setVariable=function(v){_vars=v;};` +
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
