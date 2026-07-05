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
import { getPolyfillScript } from './ScriptApi';

// Worker 的 QuickJS 引擎没有 polyfill，缓存一份在评估时注入
let cachedPolyfill_: string | null = null;
function getPolyfillForWorker(): string {
  if (!cachedPolyfill_) {
    cachedPolyfill_ = getPolyfillScript();
  }
  return cachedPolyfill_;
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
  /** 额外自定义变量 */
  [key: string]: unknown;
}

export class JsExpressionEvaluator {
  private static workerInstance: worker.ThreadWorker | null = null;
  private static workerPromise: Map<number, { resolve: (v: string) => void; reject: (e: Error) => void }> = new Map();
  private static nextId: number = 1;
  private static workerReady: boolean = false;
  private static workerInitPromise: Promise<boolean> | null = null;

  /**
   * 获取或创建 Worker 实例
   */
  private static async getWorker(): Promise<worker.ThreadWorker | null> {
    if (this.workerInstance) return this.workerInstance;
    if (this.workerInitPromise) return this.workerInitPromise.then(() => this.workerInstance);

    this.workerInitPromise = this.createWorker();
    return this.workerInitPromise.then(() => this.workerInstance);
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

        if (msg.type === 'result' || msg.type === 'error') {
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
  private static sendToWorker(type: string, timeoutMs: number = 30000, code?: string): Promise<any> {
    return new Promise((resolve, reject) => {
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
    // code 包在块作用域 { } 内，每次求值创建独立作用域，避免 let/const 重声明
    // setupCode 留在全局作用域（其中的 jsLib、变量等被复用）
    const fullScript = `${setupCode}\n{\n${code}\n}`;
    const hasAjax = /java\.ajax\s*\(/.test(fullScript);

    // 有 java.ajax() 时必须用 Worker，否则阻塞 UI
    if (hasAjax && !this.workerReady) {
      console.info('[JsEval] Init Worker for java.ajax()...');
      const worker = await this.getWorker();
      if (!worker) {
        console.warn('[JsEval] Worker unavailable, skipping java.ajax()');
        return '';
      }
    }

    // 用 Worker 执行（Worker 的 QuickJS 引擎独立于主线程，需注入 polyfill）
    if (this.workerReady && this.workerInstance) {
      try {
        const polyfill = getPolyfillForWorker();
        const workerScript = polyfill + '\n' + fullScript;
        const result = await this.sendToWorker('eval', 35000, workerScript);
        return unwrapJsResult(result);
      } catch (e) {
        console.warn('[JsEval] Worker failed:', e?.toString()?.substring(0, 80));
        this.workerReady = false;
      }
    }

    // 无 java.ajax() 时安全回退主线程
    if (!hasAjax) {
      try {
        const result = await globalScriptEngine.executeScript(fullScript);
        return unwrapJsResult(result);
      } catch (err) {
        console.error('[JsEval] Evaluate error:', (err instanceof Error) ? err.message : String(err));
        return '';
      }
    }

    return '';
  }

  /**
   * 同步求值（用于无法 await 的上下文）
   * 仅用于简单表达式，不会触发 java.ajax()
   */
  static evaluateSync(code: string, ctx: JsEvalContext): string {
    if (!code || !code.trim()) return '';
    const setupCode = JsExpressionEvaluator.buildContextScript(ctx);
    const fullScript = `${setupCode}\n{\n${code}\n}`;
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

    // source 对象
    if (ctx.source !== undefined) {
      const src = ctx.source;
      const srcObj: Record<string, unknown> = {};
      // source.key = 书源 URL（Legado 兼容，string 属性）
      if (src.sourceUrl) {
        srcObj['sourceUrl'] = src.sourceUrl;
        srcObj['key'] = src.sourceUrl;        // source.key 是字符串，不是函数
      }
      if (src.sourceName) srcObj['sourceName'] = src.sourceName;
      if (src.header) srcObj['header'] = src.header;
      // source 序列化为 JSON 后注入，再添加方法
      parts.push(`var source=${JSON.stringify(srcObj)};`);
      // getKey() — URL-encoded source URL，用于 cookie 操作
      parts.push(`if(typeof source.getKey==='undefined')source.getKey=function(){return encodeURIComponent(source.sourceUrl||'');};`);
      // getUrl() — 返回 sourceUrl（兼容）
      parts.push(`if(typeof source.getUrl==='undefined')source.getUrl=function(){return source.sourceUrl||'';};`);
    }

    // 注入自定义额外变量
    for (const [k, v] of Object.entries(ctx)) {
      if (['key', 'page', 'baseUrl', 'source'].includes(k)) continue;
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
