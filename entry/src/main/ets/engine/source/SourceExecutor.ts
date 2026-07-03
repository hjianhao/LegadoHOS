/**
 * 书源执行器（核心）— ArkTS 负责 HTTP，JS 只做解析
 *
 * 避免 NAPI 桥 http.get() 死锁：所有 HTTP 请求在 ArkTS 侧完成，
 * 预取 HTML 后传给 QuickJS 引擎进行规则解析。
 */
import { BookSource, BookSourceBookInfo, BookSourceChapter } from '../../model/BookSource';
import { SearchResult, getBookMergeKey } from '../../model/SearchResult';
import { globalScriptEngine } from './ScriptEngine';
import { JsExpressionEvaluator } from './JsExpressionEvaluator';
import { getPolyfillScript, buildRuleExecutorScriptWithHtml } from './ScriptApi';
import { RuleParser } from './RuleParser';
import { splitConnectorRules, firstNonEmpty, mergeAll, interleaveLists } from './RuleAnalyzer';
import { NetUtil } from '../../util/NetUtil';
import { HtmlUtil } from '../../util/HtmlUtil';
import { getHtmlParser, HtmlElement } from '../../util/HtmlParser';
import { CryptoUtil } from '../../util/CryptoUtil';
import { WebViewFetcher } from '../web/WebViewFetcher';

function getBaseUrl(rawUrl: string): string {
  if (!rawUrl) return '';
  return rawUrl.replace(/##.*$/, '').replace(/\/+$/, '');
}

/** @put / @get 变量存储（跨段变量引用） */
let putGetStore: Record<string, string> = {};

function initPutGetStore(): void {
  putGetStore = {};
}

function processPutGet(rule: string, evalFn: (r: string) => string): string {
  if (!rule) return '';
  let remaining = rule;
  // 处理 @get:varName — 获取之前 put 的变量值
  if (rule.startsWith('@get:')) {
    const varName = rule.slice(5).trim();
    return putGetStore[varName] || '';
  }
  // 处理内嵌 @put:{varName:"subRule"}
  const putMatch = remaining.match(/@put\s*:\s*\{\s*(\w+)\s*:\s*("[^"]*"|'[^']*'|[^}]+)\s*\}/);
  if (putMatch) {
    const varName = putMatch[1].trim();
    let varRule = putMatch[2];
    if ((varRule.startsWith('"') && varRule.endsWith('"')) || (varRule.startsWith("'") && varRule.endsWith("'"))) {
      varRule = varRule.slice(1, -1);
    }
    putGetStore[varName] = evalFn(varRule);
    remaining = remaining.replace(putMatch[0], '');
  }
  if (remaining.trim()) {
    return evalFn(remaining.trim());
  }
  return '';
}

/**
 * 应用连接操作符（|| &&）解析单字段规则
 */
function resolveFieldRule(rule: string, fn: (subRule: string) => string): string {
  if (!rule) return '';
  const { rules, connector } = splitConnectorRules(rule.trim());
  if (!connector || rules.length === 1) return processPutGet(rules[0], fn);
  const values = rules.map(r => processPutGet(r, fn));
  if (connector === '||') return firstNonEmpty(values);
  if (connector === '&&') return mergeAll(values);
  return values[0] || '';
}

function replaceSearchTemplateVars(template: string, keyword: string, page: number): string {
  const encoded = encodeURIComponent(keyword);
  return template
    .replace(/\{\{\s*(page|pageNum)\s*([+-])\s*(\d+)\s*\}\}/g,
      (_match: string, name: string, op: string, rawNum: string): string => {
        const base = name === 'pageNum' ? page + 1 : page;
        const offset = parseInt(rawNum, 10);
        return String(op === '-' ? base - offset : base + offset);
      })
    .replace(/\{\{\s*key\s*\}\}/g, encoded)
    .replace(/\{\{\s*keyword\s*\}\}/g, encoded)
    .replace(/\{\{\s*page\s*\}\}/g, String(page))
    .replace(/\{\{\s*pageNum\s*\}\}/g, String(page + 1));
}

function buildUrl(template: string, keyword: string, page: number, baseUrl: string): { url: string; method?: string; body?: string; charset?: string; webView?: boolean } {
  let url = replaceSearchTemplateVars(template, keyword, page);
  // 移除剩余未处理的 {{}} JS 表达式
  url = url.replace(/\{\{[^}]*\}\}/g, '');

  // 处理 <js>...</js> 和 @js: — 移除（无法执行 JS 时只能兜底）
  url = url.replace(/<js>[\s\S]*?<\/js>/gi, '');
  url = url.replace(/@js:[\s\S]*?(?=,|\{|$)/gi, '');

  // 处理页码分组 <选项1,选项2,...>
  const pageGroupMatch = url.match(/<([^<>]+)>/);
  if (pageGroupMatch) {
    const items = pageGroupMatch[1].split(',');
    const idx = Math.min(page - 1, items.length - 1);
    url = url.replace(pageGroupMatch[0], items[idx].trim());
  }

  // 相对路径处理 — 必须在 JSON 选项提取之前，保证 URL 以 http(s):// 开头
  if (!url.startsWith('http://') && !url.startsWith('https://') && baseUrl) {
    const base = baseUrl.replace(/\/+$/, '');
    url = base + (url.startsWith('/') ? url : '/' + url);
  }

  // 处理 URL 末尾的 JSON 选项: url,{"method":"POST","body":"..."} 或 url{"method":"POST",...}
  let method = 'GET';
  let body = '';
  let charset = '';
  let webView = false;

  // 先尝试匹配带逗号的: url,{...}
  let jsonOptMatch = url.match(/^(https?:\/\/[^,]+),(\{[\s\S]*\})$/);
  if (!jsonOptMatch) {
    // 再尝试不用逗号的: url{...}（某些源省略了逗号）
    jsonOptMatch = url.match(/^(https?:\/\/[^#]+)(\{[\s\S]*\})$/);
  }
  if (!jsonOptMatch) {
    // 最后尝试: url#xxx{...} (有 # 选择器后跟 JSON)
    jsonOptMatch = url.match(/^(https?:\/\/[^#]+)#[^,]*?,?(\{[\s\S]*\})$/);
  }

  /** 从 JSON 字符串中提取 webView/webview 标志 */
  function extractWebView(jsonStr: string): boolean {
    return /"web\s*[Vv]iew"\s*:\s*true/i.test(jsonStr) ||
      /'web\s*[Vv]iew'\s*:\s*true/i.test(jsonStr);
  }

  if (jsonOptMatch) {
    url = jsonOptMatch[1].replace(/#.*$/, '');
    webView = extractWebView(jsonOptMatch[2]);
    try {
      const opts = JSON.parse(jsonOptMatch[2]);
      if (opts.method) method = opts.method.toUpperCase();
      if (opts.body) body = replaceSearchTemplateVars(opts.body, keyword, page);
      if (opts.charset) charset = opts.charset;
      if (opts.webView !== undefined) webView = !!opts.webView;
      if (opts.webview !== undefined) webView = !!opts.webview;
    } catch (_e) {
      const raw = jsonOptMatch[2].replace(/\n/g, ' ');
      const methodMatch = raw.match(/'method'\s*:\s*'([^']*)'/i);
      if (methodMatch) method = methodMatch[1].toUpperCase();
      const charsetMatch = raw.match(/'charset'\s*:\s*'([^']*)'/i);
      if (charsetMatch) charset = charsetMatch[1];
      const bodyMatch = raw.match(/'body'\s*:\s*'(.*)'\s*[,}]?\s*$/);
      if (bodyMatch) {
        body = replaceSearchTemplateVars(bodyMatch[1], keyword, page);
      } else {
        const bodyMatch2 = raw.match(/'body'\s*:\s*'(.*)'\s*[,}]/);
        if (bodyMatch2) body = replaceSearchTemplateVars(bodyMatch2[1], keyword, page);
      }
    }
  }

  // 检查是否有第二层 ,{"webView": true} — 去掉它
  const secondJsonMatch = url.match(/^(https?:\/\/[^#]+?),(\{[\s\S]*\})$/);
  if (secondJsonMatch) {
    url = secondJsonMatch[1];
    if (!webView) webView = extractWebView(secondJsonMatch[2]);
  }

  // ##webView 后缀
  if (/##web\s*[Vv]iew/i.test(url)) {
    webView = true;
    url = url.replace(/##web\s*[Vv]iew/i, '');
  }

  // 清理多余的空白
  url = url.trim();

  return { url, method, body, charset, webView };
}

function parseHeader(headerStr: string): Record<string, string> {
  if (!headerStr) return {};
  const text = headerStr.trim();
  if (!text) return {};
  try {
    return normalizeHeaderMap(JSON.parse(text) as Record<string, unknown>);
  } catch (_e) {
    // 部分 Legado 书源使用 {'User-Agent':'xxx'} 这类 JS 对象写法，非严格 JSON。
  }

  let body = text;
  if (body.startsWith('{') && body.endsWith('}')) {
    body = body.substring(1, body.length - 1);
  }
  const headers: Record<string, string> = {};
  const quotedPair = /['"]?([^'",\n\r:]+)['"]?\s*:\s*(['"])(.*?)\2/g;
  let foundQuoted = false;
  let match: RegExpExecArray | null = quotedPair.exec(body);
  while (match) {
    const key = stripHeaderQuote(match[1]).trim();
    if (key) {
      headers[key] = match[3];
      foundQuoted = true;
    }
    match = quotedPair.exec(body);
  }
  if (foundQuoted) return headers;

  const parts = body.split(/[\n\r,]+/);
  for (let i = 0; i < parts.length; i++) {
    const part = parts[i].trim();
    if (!part) continue;
    const colon = part.indexOf(':');
    if (colon <= 0) continue;
    const key = stripHeaderQuote(part.substring(0, colon)).trim();
    const value = stripHeaderQuote(part.substring(colon + 1)).trim();
    if (key) headers[key] = value;
  }
  return headers;
}

function normalizeHeaderMap(obj: Record<string, unknown>): Record<string, string> {
  const headers: Record<string, string> = {};
  Object.keys(obj).forEach((key: string) => {
    const value = obj[key];
    if (value !== undefined && value !== null) {
      headers[key] = String(value);
    }
  });
  return headers;
}

function stripHeaderQuote(raw: string): string {
  let text = raw.trim();
  if (text.length >= 2) {
    const first = text.charAt(0);
    const last = text.charAt(text.length - 1);
    if ((first === '\'' && last === '\'') || (first === '"' && last === '"')) {
      text = text.substring(1, text.length - 1);
    }
  }
  return text;
}

export class SourceExecutor {
  private engineInitialized: boolean = false;
  /** 上次搜索因 403 失败的 URL */
  lastBlockedUrl: string = '';

  async initialize(): Promise<void> {
    if (this.engineInitialized) return;
    await globalScriptEngine.initialize();
    const polyfill = getPolyfillScript();
    await globalScriptEngine.executeScript(polyfill);
    this.engineInitialized = true;
    console.info('[SourceExecutor] Initialized');
  }

  // ============ 搜索 ============

  /**
   * 搜索（支持增量回调）
   *
   * @param keyword  搜索词
   * @param sources  要搜索的书源列表
   * @param onProgress  进度回调：(当前合并结果, 已处理源数, 总源数) => void
   * @returns 最终合并结果
   */
  async search(
    keyword: string, sources: BookSource[],
    onProgress?: (merged: SearchResult[], processed: number, total: number) => void,
    page: number = 1
  ): Promise<SearchResult[]> {
    if (!this.engineInitialized) await this.initialize();
    if (sources.length === 0) return [];

    const concurrency = AppStorage.get<number>('searchConcurrency') || 16;
    const total = sources.length;
    let processedCount = 0;

    // 持久合并 Map（参考 legado-with-MD3 的 LinkedHashMap 方案）
    // 每完成一个源，只增量合并该源的结果，无需全量重算
    const mergedMap = new Map<string, SearchResult>();
    // 追踪每个合并 key 已见过的 originUrl，用于去重
    const seenUrlsByKey = new Map<string, Set<string>>();

    /**
     * 格式化书名：移除 "作者:XXX"、"XX 著"、"最新章节" 等噪声
     * 参考 legado-with-MD3 BookHelp.formatBookName()
     */
    function formatBookName(raw: string): string {
      let n = raw
        .replace(/\s*[|｜]\s*作\s*者[:：\s].*$/g, '')
        .replace(/\s+作\s*者[:：\s].*$/g, '')
        .replace(/\s+\S+\s+著\s*$/g, '')
        .replace(/[-—·・][\s]*作\s*者[:：\s].*$/g, '')
        // 拆分符：书名 第X章 → 只留书名
        .replace(/\s+第[一二三四五六七八九十\d零○百千]+\s*[章节回卷].*$/g, '')
        .replace(/\s+第[一二三四五六七八九十\d零○百千]+.*$/g, '')
        // 分类标签
        .replace(/\s*[（(]?(全本|全文|完结|完本|连载|连载中|已完结|已完本|精校|精校版|无错版|无删减|未删减|珍藏版|修订版|校对版)[）)]?\s*$/g, '')
        .replace(/\s*[（(]?(玄幻|奇幻|仙侠|武侠|都市|言情|历史|军事|科幻|灵异|游戏|体育|同人|轻小说|二次元|其他|男频|女频|修真|修真小说|竞技|网游|悬疑|推理|恐怖|冒险|穿越|重生|系统|末世|废土|异界|异能|进化|无限|洪荒|西游|水浒|三国|红楼|聊斋|封神|神话|民间|传奇|传说)[）)]?\s*$/g, '')
        // 去掉末尾的 | 或空括号
        .replace(/[\s]*[|｜][\s]*$/g, '')
        .replace(/[\s]*[\[【（(][\]】）)]*$/g, '')
        // 去掉末尾逗号及之后
        .replace(/[\s]*[，,].*$/g, '')
        .replace(/[\s]*[-—]\s*[^-—]+$/g, '')  // "书名 - 网站名"
        .trim();
      n = n.replace(/(最新章节|最后更新|今日更新|本站推荐).*$/g, '');
      n = n.replace(/^[《『""「」''【[（(]+|[》』""「」''】\])）]+$/g, '');
      return n.trim();
    }

    const isValidBookName = (name: string): boolean => this.isValidSearchBookName(name);

    /** 将新一批结果增量合并到持久 Map 中（参考 legado-with-MD3 SearchResultMerger） */
    function incrementMerge(newResults: SearchResult[]): void {
      for (const r of newResults) {
        const rawName = r.name || '';
        const rawAuthor = r.author || '';

        // 1. 清洗书名（formatBookName）
        const cleanName = formatBookName(rawName);

        // 2. 过滤无效结果
        if (!isValidBookName(cleanName)) {
          continue;
        }

       // 3. 用清洗后的名字计算 merge key
       const key = getBookMergeKey(cleanName, rawAuthor);

       // 4. 追踪已见过的 originUrl（去重依据）
        if (!seenUrlsByKey.has(key)) {
          seenUrlsByKey.set(key, new Set<string>());
        }
        const urlSet = seenUrlsByKey.get(key)!;

        // 5. 检查这个源是否已经贡献过这本书
        const isNewSource = r.originUrl && !urlSet.has(r.originUrl);

        const existing = mergedMap.get(key);
        if (existing) {
          if (isNewSource) {
            // 新来源 → 记录 URL 并合并
            urlSet.add(r.originUrl!);
            if (r.author && !existing.author) {
              console.info("[SrcEx] Merge fills author", r.origin || r.originUrl, r.author);
            }
           const merged: SearchResult = {
             key: existing.key,
             name: existing.name,
             author: existing.author || r.author,
             coverUrl: existing.coverUrl || r.coverUrl,
              noteUrl: existing.noteUrl || r.noteUrl,
              origin: existing.origin,       // 保留第一个源的显示名
              originUrl: existing.originUrl,
              kind: existing.kind || r.kind,
              wordCount: existing.wordCount || r.wordCount,
              lastUpdateTime: existing.lastUpdateTime || r.lastUpdateTime,
              introduce: (r.introduce || '').length > (existing.introduce || '').length
                ? r.introduce : existing.introduce,
              helperMsg: existing.helperMsg || r.helperMsg,
              duration: existing.duration,
              searchTime: existing.searchTime,
              sourceCount: existing.sourceCount + 1,
              sourceOrigins: [...existing.sourceOrigins, r.origin || r.originUrl || '未知'],
              sourceOriginUrls: [...(existing.sourceOriginUrls || []), r.originUrl || ''],
              sourceNoteUrls: [...(existing.sourceNoteUrls || []), r.noteUrl || ''],
              latestChapterTitle: existing.latestChapterTitle || r.latestChapterTitle || '',
            };
            mergedMap.set(key, merged);
            console.info('[SrcEx] Merged:', r.origin || r.originUrl, '→', cleanName,
              'count:', merged.sourceCount);
          }
        } else {
          urlSet.add(r.originUrl || '');
          // 新书籍
          if (!rawAuthor) {
            console.info("[SrcEx] New entry no author", r.origin || r.originUrl,
              "key=" + key, "name=\"" + cleanName.substring(0, 20) + "\"",
              "author=\"" + (r.author || "") + "\"");
          }
          mergedMap.set(key, {
            key: r.key,
            name: cleanName,           // 使用清洗后的书名
            author: rawAuthor,
            coverUrl: r.coverUrl || '',
            noteUrl: r.noteUrl || '',
            origin: r.origin || '',
            originUrl: r.originUrl || '',
            kind: r.kind || '',
            wordCount: r.wordCount || '',
            lastUpdateTime: r.lastUpdateTime || '',
            introduce: r.introduce || '',
            helperMsg: r.helperMsg || '',
            duration: r.duration || 0,
            searchTime: r.searchTime || Date.now(),
            sourceCount: 1,
            sourceOrigins: [r.origin || r.originUrl || '未知'],
            sourceOriginUrls: [r.originUrl || ''],
            sourceNoteUrls: [r.noteUrl || ''],
            latestChapterTitle: r.latestChapterTitle || '',
          });
        }
      }
    }

    // 每个源独立搜索，每完成一个就触发回调（加超时兜底）
    const runOneSource = async (source: BookSource): Promise<void> => {
      if (!source.enabled || !source.ruleSearchUrl) return;
      try {
        const results = await this.searchWithTimeout(keyword, source, 20000, page);
        incrementMerge(results);
      } catch (_e) {
        // 单个源失败/超时不影响其他源
      } finally {
        processedCount++;
        // 每完成一个源都回调（无论是否有结果）
        if (onProgress) {
          onProgress(Array.from(mergedMap.values()), processedCount, total);
        }
      }
    };

    // 并发池：逐个启动源，每完成一个就立即回调
    const workerCount = Math.min(concurrency, total);
    const workers: Promise<void>[] = [];

    const worker = async (): Promise<void> => {
      while (nextIdx < total) {
        const i = nextIdx++;
        await runOneSource(sources[i]);
      }
    };

    let nextIdx = 0;
    for (let i = 0; i < workerCount; i++) {
      workers.push(worker());
    }

    // 等待所有 worker 完成，返回最终合并结果
    return Promise.all(workers).then((): SearchResult[] => {
      processedCount = total;
      return Array.from(mergedMap.values());
    });
  }
  
  private async searchSingle(keyword: string, source: BookSource, page: number = 1): Promise<SearchResult[]> {
    if (!source.enabled || !source.ruleSearchUrl) return [];
    const baseUrl = getBaseUrl(source.sourceUrl);
    const { url, method, body, charset, webView } = buildUrl(source.ruleSearchUrl, keyword, page, baseUrl);

    if (!url || (!url.startsWith('http://') && !url.startsWith('https://'))) {
      console.warn('[SrcEx] Invalid URL for', source.sourceName, ':', url);
      return [];
    }

    // 源配置了 webView 且非 POST → 用 WebView 加载（WebView 不支持 POST body）
    if (webView && WebViewFetcher.isReady() && method !== 'POST') {
      console.info('[SrcEx] WebView request (source config) for', source.sourceName);
      try {
        const wvResult = await WebViewFetcher.fetch(url, 30000);
        const bodyText = wvResult.html;
        if (bodyText && bodyText.length > 100) {
          console.info('[SrcEx] WebView got', bodyText.length, 'bytes from', source.sourceName);
          return this.parseResponse(bodyText, source, baseUrl, 0);
        }
      } catch (_wv) { /* WebView failed, try direct */ }
    }

    try {
      const headers: Record<string, string> = {
        'Accept': 'text/html,application/json,*/*',
        'Referer': source.sourceUrl || '',
        ...parseHeader(source.header)
      };
      if (charset) {
        headers['Accept-Charset'] = charset;
      }

      console.info('[SrcEx] Fetching:', (method || 'GET'), url.substring(0, 80));

      let bodyText = '';
      if (method === 'POST') {
        if (!headers['Content-Type'] && !headers['content-type']) {
          headers['Content-Type'] = 'application/x-www-form-urlencoded';
        }
        bodyText = await NetUtil.httpPost(url, body || '', headers, 15000);
      } else {
        bodyText = await NetUtil.httpGet(url, headers, 15000);
      }
      if (!bodyText) {
        console.warn('[SrcEx] Empty response from', source.sourceName);
        return [];
      }
      console.info('[SrcEx] Got', bodyText.length, 'bytes from', source.sourceName);

      return this.parseResponse(bodyText, source, baseUrl, 0);
    } catch (err) {
      const msg = (err as Error).message;
      if ((msg.includes('403') || msg.includes('Cloudflare') || /HTTP\s+5\d\d/.test(msg)) && WebViewFetcher.isReady()) {
        this.lastBlockedUrl = url;
        console.info('[SrcEx] HTTP block/error detected, trying WebView for', source.sourceName, ':', msg);
        try {
          const wvResult = await WebViewFetcher.fetch(url, 20000);
          const wvHtml = wvResult.html;
          if (wvHtml && wvHtml.length > 100) {
            console.info('[SrcEx] WebView got', wvHtml.length, 'bytes for', source.sourceName);
            return this.parseResponse(wvHtml, source, baseUrl, Date.now() - Date.now());
          }
        } catch (_wv) { /* WebView fallback also failed */ }
      }
      console.warn('[SrcEx] Search failed', source.sourceName, ':', msg);
      return [];
    }
  }

  /** 带超时的搜索（20s 总超时，兜底 WebView hang 等） */
  private searchWithTimeout(keyword: string, source: BookSource, timeoutMs: number, page: number = 1): Promise<SearchResult[]> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('搜索超时')), timeoutMs);
      this.searchSingle(keyword, source, page).then(r => { clearTimeout(timer); resolve(r); }).catch(e => { clearTimeout(timer); reject(e); });
    });
  }

  /** 将搜索 HTML dump 到日志（用于诊断） */
  /** 解析搜索响应：先 JSON，再 HTML，再 Fallback */
  private parseResponse(bodyText: string, source: BookSource, baseUrl: string, duration: number): SearchResult[] {
    // JSON 直接解析（API 类书源）
    try {
      const jsonObj = JSON.parse(bodyText) as Record<string, unknown>;
      const results = this.parseJsonResults(jsonObj, source, baseUrl, duration);
      if (results.length > 0) {
        console.info('[SrcEx] JSON OK:', results.length, 'from', source.sourceName);
        return results;
      } else {
        console.info('[SrcEx] JSON parsed but 0 results, ruleSearchList=' + source.ruleSearchList + ' first100=' + bodyText.substring(0, 100));
      }
    } catch (_e) {
      console.info('[SrcEx] JSON parse failed, first100=' + bodyText.substring(0, 100));
      /* not JSON */ }

    // HtmlParser + CSS 选择器
    if (source.ruleSearchList) {
      const results = this.extractWithParser(bodyText, source, baseUrl);
      if (results.length > 0) {
        console.info('[SrcEx] Parser CSS:', results.length, 'from', source.sourceName);
        return results;
      }
    }

    // Fallback
    if (source.ruleSearchList) {
      console.warn('[SrcEx] Skip fallback for configured source', source.sourceName,
        'ruleSearchList=' + source.ruleSearchList);
      return [];
    }
    return this.fallbackExtract(bodyText, source, baseUrl);
  }

  private fallbackExtract(html: string, source: BookSource, baseUrl: string): SearchResult[] {
    const parser = getHtmlParser();
    const doc = parser.parse(html);
    const links = parser.querySelectorAll(doc, 'a[href]');
    const results: SearchResult[] = [];
    const seen = new Set<string>();
    for (const a of links) {
      const rawName = a.text.trim();
      const name = this.formatBookNameForFilter(rawName);
      if (!this.isValidSearchBookName(name) || name.length > 50) continue;
      if (seen.has(name)) continue;
      let href = a.attributes['href'] || '';
      if (!href || /^(#|javascript:|mailto:|tel:)/i.test(href)) continue;
      seen.add(name);
      if (href && !href.startsWith('http')) {
        href = (baseUrl || '') + (href.startsWith('/') ? href : '/' + href);
      }
      results.push({
        key: (source.sourceUrl || '') + '|' + href, name: name, author: '',
        coverUrl: '', noteUrl: href || '', origin: source.sourceName || '未知',
        originUrl: source.sourceUrl || '', kind: '', wordCount: '', lastUpdateTime: '', latestChapterTitle: '',
        introduce: '', helperMsg: '', duration: 0, searchTime: Date.now(),
        sourceCount: 1, sourceOrigins: source.sourceName ? [source.sourceName] : [],
        sourceOriginUrls: source.sourceUrl ? [source.sourceUrl] : [],
        sourceNoteUrls: href ? [href] : []
      });
    }
    if (results.length > 0) {
      console.info('[SrcEx] Fallback:', results.length, 'items from', source.sourceName);
    } else {
      console.warn('[SrcEx] No results from', source.sourceName, '- HTML length:', html.length);
    }
    return results;
  }

  private formatBookNameForFilter(raw: string): string {
    return (raw || '')
      .replace(/\s*[|｜]\s*作\s*者[:：\s].*$/g, '')
      .replace(/\s+作\s*者[:：\s].*$/g, '')
      .replace(/\s+\S+\s+著\s*$/g, '')
      .replace(/[-—·・][\s]*作\s*者[:：\s].*$/g, '')
      .replace(/\s+第[一二三四五六七八九十\d零○百千]+\s*[章节回卷].*$/g, '')
      .replace(/\s+第[一二三四五六七八九十\d零○百千]+.*$/g, '')
      .replace(/\s*[（(]?(全本|全文|完结|完本|连载|连载中|已完结|已完本|精校|精校版|无错版|无删减|未删减|珍藏版|修订版|校对版)[）)]?\s*$/g, '')
      .replace(/\s*[（(]?(玄幻|奇幻|仙侠|武侠|都市|言情|历史|军事|科幻|灵异|游戏|体育|同人|轻小说|二次元|其他|男频|女频|修真|修真小说|竞技|网游|悬疑|推理|恐怖|冒险|穿越|重生|系统|末世|废土|异界|异能|进化|无限|洪荒|西游|水浒|三国|红楼|聊斋|封神|神话|民间|传奇|传说)[）)]?\s*$/g, '')
      .replace(/[\s]*[|｜][\s]*$/g, '')
      .replace(/[\s]*[\[【（(][\]】）)]*$/g, '')
      .replace(/[\s]*[，,].*$/g, '')
      .replace(/[\s]*[-—]\s*[^-—]+$/g, '')
      .replace(/(最新章节|最后更新|今日更新|本站推荐).*$/g, '')
      .replace(/^[《『""「」''【[（(]+|[》』""「」''】\])）]+$/g, '')
      .trim();
  }

  private isValidSearchBookName(name: string): boolean {
    if (!name || name.length < 2 || name.length > 80) return false;
    if (/[�]/.test(name) || /^&#x?[0-9a-f]+;?$/i.test(name)) return false;
    if (/没有找到|未找到|无搜索结果|浏览器没有自动跳转/.test(name)) return false;
    if (/^序号.*作品.*作者?/.test(name)) return false;
    if (/^第\s*[一二三四五六七八九十\d零○百千]+\s*[章节回卷长]/.test(name)) return false;
    if (/^第\s*[一二三四五六七八九十\d零○百千]+$/.test(name)) return false;
    if (/^\d{2,5}\s*[、.．章节回]/.test(name)) return false;
    if (/^(番外|新书|发新书|完本感言|出院了|感谢书友|角色结局|这本书成绩不好)/.test(name)) return false;
    if (/^(最新章节|最后更新|今日更新|本站推荐|热门推荐|本页推荐|精品推荐|推荐阅读|最新入库)$/.test(name)) return false;
    if (/^\d{4}-\d{2}(-\d{2})?$/.test(name)) return false;
    if (/^[0-9\-\.]+$/.test(name)) return false;
    if (/^(玄幻|奇幻|仙侠|武侠|都市|言情|历史|军事|科幻|灵异|游戏|体育|同人|轻小说|二次元|男频|女频|完本|全本|连载|排行榜|热门|推荐|最新|免费|VIP|完结|其他|女生|男生|筛选|总裁|幻想|耽美)$/.test(name)) return false;
    if (/^(网游|网游竞技|网游小说|竞技|体育竞技|体育小说)$/.test(name)) return false;
    if (/^(首页|书架|分类|排行|完本|免费|登录|注册|关于|帮助|联系我们|网站地图|设为首页|收藏本站|会员书架|阅读记录|点击榜|新书榜|推荐榜|收藏榜|口水榜|字数榜|站内搜索|个人中心|小说更新|好评排行|会员帮助|信息反馈|版权声明|广告服务|返回首页|返回上页|错误提交|快速跳转)$/.test(name)) return false;
    if (name.length === 2 && /^[\u4e00-\u9fff]{2}$/.test(name)) {
      const commonCategories = ['玄幻','奇幻','仙侠','武侠','都市','言情','历史','军事','科幻',
        '灵异','游戏','体育','同人','竞技','悬疑','推理','恐怖','冒险','穿越','重生','系统',
        '网游','末世','废土','修真','修仙','异界','异能','进化','无限','洪荒','西游','水浒',
        '三国','红楼','聊斋','封神','神话','民间','传奇','传说','下载','完本','全本','免费',
        '总裁','幻想','耽美','侦探'];
      if (commonCategories.includes(name)) return false;
    }
    if (/最新[：:]\s*第/.test(name) || /^(最新章节|最后更新|今日更新|本站推荐|热门推荐)/.test(name)) return false;
    const commonNonBook = new Set([
      '首页','书架','分类','排行','完本','免费','登录','注册',
      '关于','帮助','联系我们','网站地图','友情链接','设为首页','收藏本站',
      '书库','小说首页','全本书库','完本小说','手机小说','全本小说',
    ]);
    if (commonNonBook.has(name)) return false;
    return true;
  }

  private cleanAuthorName(raw: string): string {
    return (raw || '')
      .replace(/^[\s　]*(作者|作\s*者|著者|作者名|作者名称|author)\s*[:：=－\-]?\s*/i, '')
      .replace(/\s*(著|作品)?\s*$/g, '')
      .trim();
  }

  /** 从 URL 提取 JSON 选项并发送请求（支持 POST/GET + body + headers） */
  private async fetchWithOpts(url: string, headers: Record<string, string>, timeout: number = 30000): Promise<string> {
    let method = 'GET', body = '';
    const jm = url.match(/^(https?:\/\/[^,]+),(\{[\s\S]*\})$/);
    if (jm) {
      try {
        const opts = JSON.parse(jm[2]);
        if (opts.method) method = opts.method.toUpperCase();
        if (opts.body && typeof opts.body === 'string') body = opts.body;
        else if (opts.body && typeof opts.body === 'object') body = JSON.stringify(opts.body);
        // 提取 headers 合并到请求头
        if (opts.headers && typeof opts.headers === 'object') {
          for (const [hk, hv] of Object.entries(opts.headers as Record<string, Object>)) {
            if (typeof hv === 'string') headers[hk] = hv;
          }
        }
      } catch (_e) {
        const r = jm[2].replace(/\n/g, ' ');
        const mm = r.match(/'method'\s*:\s*'([^']*)'/i);
        if (mm) method = mm[1].toUpperCase();
        const bm = r.match(/'body'\s*:\s*'([^']*)'/i);
        if (bm) body = bm[1];
        const hm = r.match(/'headers'\s*:\s*\{([^}]*)\}/i);
        if (hm) {
          const hparts = hm[1].match(/'(\w+)'\s*:\s*'([^']*)'/g);
          if (hparts) {
            for (const hp of hparts) {
              const kv = hp.match(/'(\w+)'\s*:\s*'([^']*)'/);
              if (kv) headers[kv[1]] = kv[2];
            }
          }
        }
      }
      url = jm[1];
    }
    console.info('[SrcEx] fetchWithOpts url=' + url.substring(0, 80) + ' method=' + method + ' bodyLen=' + body.length + ' body=' + body.substring(0, 300) + ' headers=' + JSON.stringify(headers).substring(0, 200));
    if (method === 'POST') {
      headers['Content-Type'] = headers['Content-Type'] || 'application/json';
      return await NetUtil.httpPost(url, body, headers, timeout);
    }
    return await NetUtil.httpGet(url, headers, timeout);
  }

  // ============ 书籍详情 ============

  /**
   * 获取书籍详情信息（名称、作者、封面、简介等）
   * 使用书源的 ruleBookInfo* 规则解析详情页 HTML
   */
  async getBookInfo(source: BookSource, noteUrl: string): Promise<BookSourceBookInfo> {
    if (!noteUrl || !source) return { name: '', author: '', coverUrl: '', introduce: '', kind: '', wordCount: '', lastUpdateTime: '', chapters: [] };
    const baseUrl = getBaseUrl(source.sourceUrl);
    if (!noteUrl.startsWith('http')) {
      noteUrl = (baseUrl || '') + (noteUrl.startsWith('/') ? noteUrl : '/' + noteUrl);
    }
    try {
      const headers: Record<string, string> = {
        'Accept': 'text/html,application/json,*/*',
        'Referer': source.sourceUrl || '',
        ...parseHeader(source.header)
      };
      const body = await this.fetchWithOpts(noteUrl, headers);
      if (!body || body.length < 100) return { name: '', author: '', coverUrl: '', introduce: '', kind: '', wordCount: '', lastUpdateTime: '', chapters: [] };

      const jsonInfo = this.parseJsonBookInfo(body, source, noteUrl);
      if (jsonInfo) return jsonInfo;

      const parser = getHtmlParser();
      const doc = parser.parse(body);
      const root: unknown = doc; // HtmlElement

      const extractField = (rule: string): string => {
        if (!rule) return '';
        return resolveFieldRule(rule, (subRule: string) => {
          const normalized = this.normalizeCssRule(subRule);
          return parser.extractAttr(doc, normalized);
        });
      };

      return {
        name: extractField(source.ruleBookInfoName) || '',
        author: extractField(source.ruleBookInfoAuthor) || '',
        coverUrl: extractField(source.ruleBookInfoCover) || '',
        introduce: extractField(source.ruleBookInfoIntroduce) || '',
        kind: extractField(source.ruleBookInfoKind) || '',
        wordCount: extractField(source.ruleBookInfoWordCount) || '',
        lastUpdateTime: extractField(source.ruleBookInfoLastUpdateTime) || '',
        tocUrl: extractField(source.ruleBookInfoTocUrl) || '',
        chapters: [],
      };
    } catch (_e) {
      return { name: '', author: '', coverUrl: '', introduce: '', kind: '', wordCount: '', lastUpdateTime: '', chapters: [] };
    }
  }

  private parseJsonBookInfo(body: string, source: BookSource, noteUrl: string): BookSourceBookInfo | null {
    try {
      const jsonObj = JSON.parse(body) as Record<string, unknown>;
      let root: Record<string, unknown> = jsonObj;
      if (source.ruleBookInfoInit) {
        const initValue = this.getPath(jsonObj, source.ruleBookInfoInit);
        if (initValue && typeof initValue === 'object' && !Array.isArray(initValue)) {
          root = initValue as Record<string, unknown>;
        }
      }
      const info: BookSourceBookInfo = {
        name: this.extractJsonRuleValue(source.ruleBookInfoName, root),
        author: this.extractJsonRuleValue(source.ruleBookInfoAuthor, root),
        coverUrl: this.extractJsonRuleValue(source.ruleBookInfoCover, root),
        introduce: this.extractJsonRuleValue(source.ruleBookInfoIntroduce, root),
        kind: this.extractJsonRuleValue(source.ruleBookInfoKind, root),
        wordCount: this.extractJsonRuleValue(source.ruleBookInfoWordCount, root),
        lastUpdateTime: this.extractJsonRuleValue(source.ruleBookInfoLastUpdateTime, root),
        tocUrl: this.resolveRuleTemplate(source.ruleBookInfoTocUrl, root, noteUrl),
        chapters: [],
      };
      if (info.name || info.author || info.coverUrl || info.introduce || info.kind || info.wordCount || info.lastUpdateTime || info.tocUrl) {
        console.info('[SrcEx] BookInfo JSON OK tocUrl=', (info.tocUrl || '').substring(0, 100));
        return info;
      }
    } catch (_e) {
      /* not JSON */
    }
    return null;
  }

  private extractJsonRuleValue(rule: string, item: Record<string, unknown>): string {
    if (!rule) return '';
    if (rule.includes('{{')) return this.resolveRuleTemplate(rule, item, '');
    return this.firstStr(item, rule);
  }

  private resolveRuleTemplate(template: string, item: Record<string, unknown>, baseUrl: string): string {
    if (!template) return '';
    let result = template.replace(/\{\{\$\.([^}]+)\}\}/g, (_m: string, path: string) => {
      const value = this.getPath(item, '$.' + path.trim());
      return value !== undefined && value !== null ? String(value) : '';
    });
    result = result.replace(/\{\{([^}]+)\}\}/g, (_m: string, path: string) => {
      const value = this.getPath(item, '$.' + path.trim());
      return value !== undefined && value !== null ? String(value) : '';
    });
    if (result && baseUrl && !result.startsWith('http://') && !result.startsWith('https://')) {
      return this.resolvePageUrl(result, baseUrl);
    }
    return result;
  }

  // ============ 正文内容 ============

  /**
   * 根据 book source 的 URL 模板解析最终 URL
   * 参照 Legado AnalyzeUrl：
   *   {{bookUrl}} → 书籍详情页 URL
   *   {{id}} / {{novelId}} → 章节/书籍 ID（从 chapterUrl 提取）
   *   无模板 → 直接使用原 URL
   */
  private resolveUrl(template: string, bookUrl: string, chapterUrl?: string): string {
    if (!template) return chapterUrl || bookUrl;
    let url = template
      .replace(/\{\{bookUrl\}\}/g, bookUrl)
      .replace(/\{\{bookurl\}\}/g, bookUrl);
    if (chapterUrl) {
      // 从 chapterUrl 提取 ID 用于 {{id}} / {{novelId}} 替换
      const idMatch = chapterUrl.match(/(\d+)/);
      const chapterId = idMatch ? idMatch[1] : chapterUrl;
      url = url
        .replace(/\{\{id\}\}/g, chapterId)
        .replace(/\{\{novelId\}\}/g, chapterId);
    }
    // 处理相对路径
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      const base = bookUrl.replace(/^(https?:\/\/[^\/]+).*$/, '$1');
      url = base + (url.startsWith('/') ? url : '/' + url);
    }
    // 移除剩余 {{}} 表达式
    url = url.replace(/\{\{[^}]*\}\}/g, '');
    return url;
  }

  /**
   * 解析 TOC 章节 URL 中的 {{baseUrl.match(...)}} 模板
   */
  private resolveTocUrlTemplate(url: string, tocUrl: string): string {
    if (!url || !url.includes('{{')) return url;

    // 解析 {{baseUrl.match(/pattern/)[N]}} 模板（支持嵌套括号）
    url = url.replace(/\{\{baseUrl\.match\(/g, '\x00');
    while (url.includes('\x00')) {
      const start = url.indexOf('\x00');
      const afterMatch = start + 1; // past \x00
      // 找匹配的 ) 支持嵌套括号
      let depth = 1;
      let endParen = -1;
      for (let i = afterMatch; i < url.length; i++) {
        if (url[i] === '(') depth++;
        else if (url[i] === ')') {
          depth--;
          if (depth === 0) { endParen = i; break; }
        }
      }
      if (endParen < 0) { url = url.replace('\x00', '{{baseUrl.match('); break; }
      let regexStr = url.substring(afterMatch, endParen);
      // 去掉首尾 /（Legado 正则写法 /pattern/ → pattern）
      if (regexStr.startsWith('/') && regexStr.endsWith('/')) {
        regexStr = regexStr.slice(1, -1);
      }
      // 找后面的 [N]}
      const idxMatch = url.substring(endParen + 1).match(/^\[(\d+)\]\}\}/);
      const idx = idxMatch ? idxMatch[1] : '0';
      let replacement = '';
      try {
        const m = tocUrl.match(new RegExp(regexStr, 'i'));
        if (m) replacement = m[parseInt(idx)] || '';
      } catch (_e) { /* ignore regex errors */ }
      url = url.substring(0, start) + replacement + url.substring(endParen + 1 + (idxMatch ? idxMatch[0].length : 3));
    }

    // 相对路径转绝对路径
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      const baseUrl_ = tocUrl.replace(/^(https?:\/\/[^\/]+).*$/, '$1');
      url = baseUrl_ + (url.startsWith('/') ? url : '/' + url);
    }

    return url;
  }

  private extractBookIdFromUrl(url: string): string {
    if (!url) return '';
    const bookIdMatch = url.match(/bookid[=:]([^&#/?]+)/i);
    if (bookIdMatch) return decodeURIComponent(bookIdMatch[1]);
    const novelMatch = url.match(/\/novel\/([^/?#]+)/i);
    if (novelMatch) return decodeURIComponent(novelMatch[1]);
    const lastPathMatch = url.match(/\/([^/?#]+)(?:[?#].*)?$/);
    return lastPathMatch ? decodeURIComponent(lastPathMatch[1]) : '';
  }

  async getContent(source: BookSource, contentUrl: string, bookUrl?: string): Promise<string> {
    console.info('[SrcEx] getContent input - chapterUrl len=' + (contentUrl || '').length + ':', (contentUrl || '').substring(0, 160));
    console.info('[SrcEx] getContent bookUrl:', ((bookUrl || '')).substring(0, 80));

    // 安全解析 {{baseUrl.match(...)}} 模板
    if (bookUrl && contentUrl && contentUrl.includes('{{')) {
      contentUrl = this.resolveTocUrlTemplate(contentUrl, bookUrl);
      console.info('[SrcEx] getContent after resolveTocUrlTemplate len=' + contentUrl.length);
    }

    console.info('[SrcEx] getContent source.ruleBookContent=[' + (source.ruleBookContent || '') + ']');

    // 用 ruleBookContentUrl 解析正文页 URL（如果书源有配置）
    if (source.ruleBookContentUrl && contentUrl) {
      const resolvedUrl = this.resolveUrl(source.ruleBookContentUrl, bookUrl || source.sourceUrl, contentUrl);
      console.info('[SrcEx] getContent resolved:', resolvedUrl.substring(0, 80));
      // 注意：如果 ruleBookContentUrl 只是 {{bookUrl}}，解析结果会变成书籍详情页 URL
      // 此时应使用原始 chapterUrl
      if (resolvedUrl !== bookUrl || !bookUrl) {
        contentUrl = resolvedUrl;
      } else {
        console.info('[SrcEx] Resolved URL same as bookUrl, keeping original chapterUrl');
      }
    }
    if (!contentUrl) return '';
    if (!contentUrl.startsWith('http://') && !contentUrl.startsWith('https://')) {
      const baseForContent = bookUrl || source.sourceUrl || '';
      if (baseForContent) {
        contentUrl = this.resolvePageUrl(contentUrl, baseForContent);
        console.info('[SrcEx] getContent resolved relative URL:', contentUrl.substring(0, 80));
      }
    }
    console.info('[SrcEx] getContent final URL:', contentUrl.substring(0, 80));
    try {
      // 提取 URL 末尾 JSON 选项（与 buildUrl 一致）
      const headers: Record<string, string> = {
        'Accept': 'text/html,application/json,*/*',
        'Referer': source.sourceUrl || '',
        ...parseHeader(source.header)
      };
      let raw = await this.fetchWithOpts(contentUrl, headers);
      console.info('[SrcEx] getContent raw len=' + (raw || '').length + ' prefix=' + (raw || '').substring(0, 200));
      if (!raw) { console.warn('[SrcEx] getContent empty response'); return ''; }

      // 尝试 JSON 解析 + 内容规则模板替换
      let jsonParsed: Record<string, unknown> | null = null;
      try {
        jsonParsed = JSON.parse(raw) as Record<string, unknown>;
      } catch (_e) { /* not JSON */ }

      if (jsonParsed) {
        // 直接返回已知字段
        if (typeof jsonParsed === 'string') return jsonParsed as string;
        if (jsonParsed['content']) return jsonParsed['content'] as string;
        if (jsonParsed['data']) {
          const data = jsonParsed['data'];
          if (typeof data === 'string') return data;
        }

        // 如果有 ruleBookContent，解析其中的 {{$.xxx}} 模板
        if (source.ruleBookContent && source.ruleBookContent.includes('{{')) {
          let content = source.ruleBookContent;
          console.info('[SrcEx] Content rule before:', content.substring(0, 100));
          // 解析 {{$.xxx}} 从 JSON 中取值
          content = content.replace(/\{\{\$\.([^}]+)\}\}/g, (_m: string, path: string) => {
            const v = RuleParser.parseJsonPath(jsonParsed, '$.' + path);
            let val = '';
            if (v !== null && v !== undefined) {
              if (Array.isArray(v)) {
                // 数组 → 用换行连接
                val = (v as unknown[]).map(item => String(item)).join('\n');
              } else {
                val = String(v);
              }
            }
            console.info('[SrcEx] Content resolve path=' + path + ' val=' + val.substring(0, 80));
            return val;
          });
          console.info('[SrcEx] Content rule after:', content.substring(0, 200));
          // 清理 \r\n → \n（处理真实 CRLF 和转义序列）
          content = content.replace(/\r\n/g, '\n').replace(/\r/g, '\n').replace(/\\r\\n/g, '\n').replace(/\\n/g, '\n');
          // 取纯文本内容（去掉 HTML 标签）
          if (content && content.length > 0) {
            content = this.stripHtml(content);
            content = content.trim();
          }
          return content;
        }
      }

      // 规则解析：直接使用书源的内容规则，不通过 QuickJS（避免大数据传参溢出）
      if (source.ruleBookContent) {
        const contentParts: string[] = [];
        const visited = new Set<string>();
        let pageUrl = contentUrl;
        let pageHtml = raw;
        for (let page = 0; page < 10; page++) {
          if (visited.has(pageUrl)) break;
          visited.add(pageUrl);

          const result = this.parseContentFromRules(pageHtml, { content: source.ruleBookContent });
          if (result && result.length > 0) {
            const cleaned = this.applyReplaceRegex(result, source.ruleBookContentReplaceRegex);
            contentParts.push(cleaned);
            console.info('[SrcEx] getContent page', page + 1, 'extracted', result.length, 'chars, cleaned', cleaned.length, 'chars');
          } else {
            console.info('[SrcEx] getContent page', page + 1, 'empty result, ruleBookContent=[' + source.ruleBookContent + '] htmlLen=' + pageHtml.length);
          }

          const nextRule = source.ruleBookContentNext || '';
          // 兜底：如果 DB 中 ruleBookContentNext 为空，从 rawJson 解析 ruleContent.nextContentUrl
          let nextFromRaw: string = '';
          if (!nextRule) {
            try {
              const rawJson = (source as unknown as Record<string, Object>)['rawJson'] as string;
              if (rawJson) {
                const rj = JSON.parse(rawJson) as Record<string, Object>;
                const rc = rj['ruleContent'] as Record<string, string>;
                if (rc && rc['nextContentUrl']) nextFromRaw = rc['nextContentUrl'];
              }
            } catch (_e) { /* ignore */ }
          }
          const effectiveNextRule = nextRule || nextFromRaw;
          if (!effectiveNextRule) break;
          const nextUrl = this.resolvePageUrl(this.extractHtmlRuleValue(pageHtml, effectiveNextRule), pageUrl);
          if (!nextUrl || visited.has(nextUrl)) break;
          pageUrl = nextUrl;
          pageHtml = await this.fetchWithOpts(pageUrl, headers);
          if (!pageHtml) break;
          console.info('[SrcEx] getContent next page', page + 2, pageUrl.substring(0, 100));
        }
        const merged = contentParts.join('\n');
        if (merged && merged.length > 0) return merged;
      }

      // 兜底：stripHtml
      return this.stripHtml(raw);
    } catch (err) {
      console.warn('[SrcEx] getContent failed:', (err as Error).message);
      return '';
    }
  }

  /**
   * 获取目录（章节列表）
   * @param source 书源
   * @param tocUrl 书籍详情页 URL（即 search 返回的 noteUrl）
   * @returns 章节列表
   */
  async getToc(source: BookSource, tocUrl: string): Promise<BookSourceChapter[]> {
    // 用 ruleTocUrl 解析目录页 URL（如果书源有配置）
    if (source.ruleTocUrl) {
      tocUrl = this.resolveUrl(source.ruleTocUrl, tocUrl);
    }
    if (!tocUrl) return [];
    console.info('[SrcEx] getToc URL:', tocUrl.substring(0, 80));
    try {
      const headers: Record<string, string> = {
        'Accept': 'text/html,application/json,*/*',
        'Referer': source.sourceUrl || '',
        ...parseHeader(source.header)
      };
      let resp = await this.fetchWithOpts(tocUrl, headers);
      // 短响应检测：可能是 JSON 错误（如 {"code":4005,"msg":"认证失败"}）
      if (!resp || resp.length < 100) {
        const body = resp || '';
        console.warn('[SrcEx] getToc short response len=' + (resp ? resp.length : 0) +
          ' body=' + body.substring(0, 200));
        // 尝试解析 JSON 错误码，避免后续用无效数据继续请求
        if (body) {
          try {
            const json = JSON.parse(body) as Record<string, Object>;
            const code = json['code'] as number | undefined;
            const msg = json['msg'] as string | undefined;
            if (code !== undefined && code !== 0 && code !== 200) {
              console.warn('[SrcEx] getToc API error: code=' + code + ' msg=' + (msg || ''));
              console.warn('[SrcEx] getToc giving up - API returned auth/error code, source may need updated token');
              return [];
            }
          } catch (_fe) { /* fallthrough */ }
        }
        if (!resp) return [];
      }
      if (tocUrl.includes('bookshelf.html5.qq.com')) {
        console.info('[SrcEx] TOC DUMP 企鹅:', resp.substring(0, 5000));
      }
	      const parsed = this.parseJsonBookInfo(resp, source, tocUrl);
      if (parsed) {
        console.info('[SrcEx] getToc BookInfo JSON OK tocUrl=', (parsed.tocUrl || '').substring(0, 100));
      }

      const tocBodies: string[] = [resp];
      const visitedToc = new Set<string>();
      visitedToc.add(tocUrl);

      const nextRule = source.ruleTocNextTocUrl || '';
      if (nextRule) {
        try {
          let currentBody = resp;
          let currentUrl = tocUrl;
          while (tocBodies.length < 60) {
            const nextUrls = this.collectTocPageUrls(currentBody, nextRule, currentUrl);
            const newUrls: string[] = [];
            for (const url of nextUrls) {
              if (url && !visitedToc.has(url)) {
                newUrls.push(url);
              }
            }
            if (newUrls.length === 0) {
              break;
            }

            if (newUrls.length > 1) {
              const pageUrls: string[] = [];
              for (const url of newUrls) {
                if (tocBodies.length + pageUrls.length >= 60) {
                  break;
                }
                visitedToc.add(url);
                pageUrls.push(url);
              }

              const maxConcurrency = 5;
              const pageResults: (string | null)[] = new Array(pageUrls.length);
              let nextIdx = 0;
              const workers: Promise<void>[] = [];
              const fetchPage = async (): Promise<void> => {
                while (nextIdx < pageUrls.length) {
                  const i = nextIdx++;
                  try {
                    const b = await this.fetchWithOpts(pageUrls[i], headers);
                    if (b && b.length > 100) {
                      pageResults[i] = b;
                    }
                  } catch (_pf) { /* skip */ }
                }
              };
              const workerCount = Math.min(maxConcurrency, pageUrls.length);
              for (let w = 0; w < workerCount; w++) {
                workers.push(fetchPage());
              }
              await Promise.all(workers);
              for (let i = 0; i < pageResults.length; i++) {
                if (pageResults[i]) {
                  tocBodies.push(pageResults[i]!);
                }
              }
              break;
            }

            const nextUrl = newUrls[0];
            visitedToc.add(nextUrl);
            const nextBody = await this.fetchWithOpts(nextUrl, headers);
            if (!nextBody || nextBody.length < 100) {
              break;
            }
            tocBodies.push(nextBody);
            currentBody = nextBody;
            currentUrl = nextUrl;
          }
        } catch (_e) {
          /* ignore */
        }
      }
      console.info('[SrcEx] getToc pages fetched:', tocBodies.length);

      const bodyText = tocBodies.join('\n');

      // 规则解析
      let tocListRule = source.ruleToc || '';
      let reverseToc = false;
      if (tocListRule.startsWith('-')) {
        reverseToc = true;
        tocListRule = tocListRule.substring(1);
      } else if (tocListRule.startsWith('+')) {
        tocListRule = tocListRule.substring(1);
      }
      const tocRules: Record<string, string> = {
        toc: tocListRule,
        tocTitle: source.ruleTocTitle || '',
        tocUrlItem: source.ruleTocUrlItem || '',
      };
      if (tocRules.toc) {
        let chapters: BookSourceChapter[] = [];
        if (tocRules.toc.startsWith('$.')) {
          try {
            chapters = await this.parseJsonToc(JSON.parse(bodyText) as Record<string, unknown>, tocRules, tocUrl);
          } catch (_je) { /* fallback */ }
        }
        if (chapters.length === 0) {
          chapters = this.parseTocFromRules(bodyText, tocRules);
        }
        // 去重
        const seen = new Set<string>();
        const deduped: BookSourceChapter[] = [];
        for (let ci = 0; ci < chapters.length; ci++) { const ch = chapters[ci];
          const key = ch.title + '|' + ch.url;
          if (!seen.has(key)) {
            seen.add(key);
            deduped.push(ch);
          }
        }
        chapters = deduped;
        // 智能排序
        if (reverseToc) {
          chapters.reverse();
        } else if (chapters.length > 1) {
          // 通用排序：按标题中的数字排序（支持中文数字如"第四百九十八"）
          const cnNumMap: Record<string, number> = {
            '零': 0, '一': 1, '二': 2, '三': 3, '四': 4,
            '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
            '十': 10, '百': 100, '千': 1000, '万': 10000,
          };
          const extractChapterNum = (title: string): number => {
            // 优先：阿拉伯数字
            const arabicM = title.match(/(\d+)/);
            if (arabicM) return parseInt(arabicM[1]);
            // 中文数字：第xxx章 → xxx
            const cnM = title.match(/第([零一二三四五六七八九十百千万]+)章/);
            if (cnM) {
              let cn = cnM[1];
              let result = 0;
              let section = 0;
              for (let i = 0; i < cn.length; i++) {
                const ch = cn.charAt(i);
                const num = cnNumMap[ch];
                if (num === undefined) continue;
                if (num >= 10) {
                  section = (section || 1) * num;
                  result += section;
                  section = 0;
                } else {
                  section = num;
                }
              }
              result += section;
              return result > 0 ? result : 0;
            }
            return 0;
          };
          chapters.sort((a, b) => extractChapterNum(a.title) - extractChapterNum(b.title));
        }
        chapters.forEach((ch, idx) => { ch.index = idx; });
        console.info('[SrcEx] getToc final:', chapters.length, 'chapters (from', tocBodies.length, 'pages)');
        if (chapters.length > 0) {
          return chapters.map(ch => ({
            ...ch,
            url: this.resolveTocUrlTemplate(ch.url, tocUrl) || ch.url,
          }));
        }
      }

      // 兜底：从 HTML 中提取章节链接
      const tocChapters = this.extractTocFromHtml(bodyText, source);
      if (tocChapters.length > 0) return tocChapters;

      // 无结果（或结果太少）？尝试从当前页面提取 ruleBookInfoTocUrl 作为真实目录页 URL
      if (source.ruleBookInfoTocUrl) {
        // 当作 CSS 选择器解析，从当前 HTML 中提取真实的目录页 URL
        const parser = getHtmlParser();
        const doc = parser.parse(bodyText);
        const cssRule = this.normalizeCssRule(source.ruleBookInfoTocUrl);
        const tocPageUrl = parser.extractAttr(doc, cssRule);
        if (tocPageUrl && tocPageUrl.startsWith('http') && tocPageUrl !== tocUrl) {
          console.info('[SrcEx] getToc resolve ruleBookInfoTocUrl CSS:', tocPageUrl.substring(0, 80));
          const altResp = await this.fetchWithOpts(tocPageUrl, {
            'Accept': 'text/html,application/json,*/*',
            'Referer': source.sourceUrl || '',
            ...parseHeader(source.header)
          });
          if (altResp && altResp.length > 100) {
            let altChapters: BookSourceChapter[] = [];
            if (tocRules.toc.startsWith('$.')) {
              try {
                const jsonObj = JSON.parse(altResp) as Record<string, unknown>;
                altChapters = await this.parseJsonToc(jsonObj, tocRules, tocPageUrl);
              } catch (_je2) { /* fallback */ }
            }
            if (altChapters.length === 0) {
              altChapters = this.parseTocFromRules(altResp, tocRules);
            }
            if (altChapters.length > 0) {
              console.info('[SrcEx] AltToc got', altChapters.length, 'chapters from', tocPageUrl.substring(0, 60));
              return altChapters.map(ch => ({
                ...ch,
                url: this.resolveTocUrlTemplate(ch.url, tocPageUrl) || ch.url,
              }));
            }
          }
        }
      }
    } catch (err) {
      console.warn('[SrcEx] getToc failed:', (err as Error).message);
      return [];
    }
    return [];
  }

  // ============ JS 引擎加载 ============

  private async loadSource(source: BookSource): Promise<void> {
    if (!this.engineInitialized) await this.initialize();
    const wrapperScript = buildRuleExecutorScriptWithHtml(
      source.ruleSearchList, source.ruleSearchName,
      source.ruleSearchAuthor, source.ruleSearchCover,
      source.ruleSearchNoteUrl,
      source.ruleToc || '', source.ruleTocTitle || '', source.ruleTocUrlItem || '',
      source.ruleBookContent || '',
    );
    await globalScriptEngine.loadSourceScript(wrapperScript);
  }

  // ============ HtmlParser + CSS 选择器提取 ============

  private extractTocPageUrls(body: string, rule: string, currentUrl: string): string[] {
    if (!body || !rule) return [];

    const parser = getHtmlParser();
    const doc = parser.parse(body);
    const urls: string[] = [];
    const seen = new Set<string>();

    const addUrl = (raw: string): void => {
      const url = this.resolvePageUrl(raw, currentUrl);
      if (url && !seen.has(url)) {
        seen.add(url);
        urls.push(url);
      }
    };

    const rawParts = splitConnectorRules(rule).rules;
    for (const rawPart of rawParts) {
      const normalized = this.normalizeCssRule(rawPart.trim());
      if (!normalized || normalized.startsWith('<js>')) {
        continue;
      }

      const normalizedParts = splitConnectorRules(normalized).rules;
      for (const part of normalizedParts) {
        const trimmed = part.trim();
        if (!trimmed) {
          continue;
        }

        const attrMatch = trimmed.match(/^(.*?)@([\w-]+)$/i);
        if (!attrMatch) {
          addUrl(parser.extractAttr(doc, trimmed));
          continue;
        }

        const cssRule = attrMatch[1].trim();
        const attrName = attrMatch[2].toLowerCase();
        if (!cssRule) {
          continue;
        }

        const elements = parser.querySelectorAll(doc, cssRule);
        for (const el of elements) {
          switch (attrName) {
            case 'text':
              addUrl(el.text || '');
              break;
            case 'owntext':
            case 'textnodes':
              addUrl(el.ownText || '');
              break;
            case 'html':
              addUrl(el.innerHtml || '');
              break;
            case 'value':
              addUrl(el.attributes['value'] || '');
              break;
            default:
              addUrl(el.attributes[attrName] || '');
              break;
          }
        }
      }
    }

    return urls;
  }

  private collectTocPageUrls(body: string, rule: string, currentUrl: string): string[] {
    const urls: string[] = [];
    const seen = new Set<string>();
    const add = (url: string): void => {
      if (url && !seen.has(url)) {
        seen.add(url);
        urls.push(url);
      }
    };

    for (const url of this.extractTocPageUrls(body, rule, currentUrl)) {
      add(url);
    }

    const optionUrls = this.extractTocOptionPageUrls(body, currentUrl);
    if (optionUrls.length > 1) {
      for (const url of optionUrls) {
        add(url);
      }
    }

    return urls;
  }

  private extractTocOptionPageUrls(body: string, currentUrl: string): string[] {
    if (!body) return [];

    const parser = getHtmlParser();
    const doc = parser.parse(body);
    const options = parser.querySelectorAll(doc, 'option@value');
    const urls: string[] = [];
    const seen = new Set<string>();
    for (const option of options) {
      const raw = option.attributes['value'] || '';
      if (!this.isLikelyUrlValue(raw)) {
        continue;
      }
      const url = this.resolvePageUrl(raw, currentUrl);
      if (url && !seen.has(url)) {
        seen.add(url);
        urls.push(url);
      }
    }
    return urls;
  }

  private isLikelyUrlValue(value: string): boolean {
    const raw = (value || '').trim();
    if (!raw || raw.startsWith('#') || raw.startsWith('javascript:')) return false;
    return /^(https?:)?\/\//i.test(raw) || raw.startsWith('/') || raw.startsWith('./') ||
      raw.startsWith('../') || raw.startsWith('?') || /\.(html?|php|aspx?)([?#].*)?$/i.test(raw) ||
      raw.includes('/');
  }

  /**
   * 将 Legado Default 规则语法转换为标准 CSS
   * - id.xxx → #xxx
   * - .class@tag → .class tag (后代)
   * - tag@tag → tag tag (后代)
   * - @@class → .class (简写)
   * 仅当 @ 后为已知 HTML 标签名或 .class 时才展开，避免误转换 @js: @put: 等
   */
  private normalizeCssRule(rule: string): string {
    if (!rule) return '';
    const htmlTags = new Set<string>(['div','span','a','p','li','ul','ol','tr','td','th','table','tbody','thead',
      'tfoot','h1','h2','h3','h4','h5','h6','img','dl','dt','dd','em','strong','b','i','u','s','br','hr',
      'form','input','button','select','option','textarea','label','pre','code','blockquote','section','nav',
      'header','footer','article','aside','main','figure','figcaption','video','audio','source','iframe']);
    // 1. id.xxx → #xxx
    let normalized = rule.replace(/\bid\.([\w-]+)/g, '#$1');
    // 2. @@class →  .class (Legado 简写)
    normalized = normalized.replace(/@@([\w-]+)/g, '.$1');
    // 2.4. Legado 范围选择器: tag.N:M → tag.N||tag.M, tag.N:M:O → tag.N||tag.M||tag.O
    normalized = normalized.replace(/(\.[\w-]+|\w[\w-]*)\.(\d+)((?::\d+)+)/g,
      (_m: string, sel: string, firstIdx: string, rest: string) => {
        const indices = [parseInt(firstIdx, 10)];
        for (const part of rest.split(':').filter(x => x)) {
          indices.push(parseInt(part, 10));
        }
        // 展开为 || 多选: p.1||p.2||p.4，.N 由 HtmlParser 按 Legado 位置索引处理。
        return indices.map(i => sel + '.' + i).join('||');
      });
    // 2.5. 保留 Legado .N / !N 位置索引，HtmlParser 会在选择阶段处理。
    // 3. @后跟标签名 → 空格 + 标签名（后代）
    normalized = normalized.replace(/@(\w[\w-]*)/g, (match: string, afterAt: string) => {
      if (htmlTags.has(afterAt.toLowerCase())) return ' ' + afterAt;
      if (afterAt.startsWith('.')) return ' ' + afterAt;
      if (afterAt.startsWith('#')) return ' ' + afterAt;
      return match;
    });
    return normalized;
  }

  private buildCssRuleCandidates(rule: string): string[] {
    const normalized = this.normalizeCssRule(rule);
    const candidates: string[] = [];
    const add = (candidate: string): void => {
      const cleaned = candidate.replace(/\s+/g, ' ').trim();
      if (cleaned && !candidates.includes(cleaned)) {
        candidates.push(cleaned);
      }
    };
    add(normalized);

    // 浏览器 DOM 会给 table 自动补 tbody，但原始 HTML 常常没有显式 tbody。
    // 对 tbody 路径多试一次去 tbody 的选择器，兼容 tbody@tr!0 / id.xxx@tbody@tr。
    if (/\btbody\b/i.test(normalized)) {
      add(normalized.replace(/(^|[\s>])tbody(?=($|[\s>]))/gi, '$1'));
    }

    return candidates;
  }

  /**
   * 使用 HtmlParser 解析 HTML，通过 CSS 选择器提取搜索结果
   * 替代之前损坏的 RuleParser 和正则方案
   */
  private extractWithParser(body: string, source: BookSource, baseUrl: string): SearchResult[] {
    if (!body || !source.ruleSearchList) return [];

    const parser = getHtmlParser();
    const doc = parser.parse(body);

    // 用 ruleSearchList 查找结果列表（规则标准化，支持 || 连接器拆分）
    const listParts = splitConnectorRules(source.ruleSearchList || '');
    let items: HtmlElement[] = [];
    for (const part of listParts.rules) {
      const candidates = this.buildCssRuleCandidates(part);
      for (const partNorm of candidates) {
        const found = parser.querySelectorAll(doc, partNorm);
        if (found && found.length > 0) {
          items = found;
          console.info('[SrcEx] CSS list rule matched by "' + part + '" → norm="' + partNorm + '" for', source.sourceName);
          break;
        }
      }
      if (items.length > 0) {
        break;
      }
    }
    if (!items || items.length === 0) {
      console.info('[SrcEx] CSS list rule found 0 items for', source.sourceName,
        'rule:', source.ruleSearchList);
      return [];
    }
    console.info('[SrcEx] CSS list rule found', items.length, 'items for', source.sourceName);

    const nameRule = source.ruleSearchName || '';
    const authorRule = source.ruleSearchAuthor || '';
    const coverRule = source.ruleSearchCover || '';
    const noteUrlRule = source.ruleSearchNoteUrl || '';
    const kindRule = (source as unknown as Record<string, string>).ruleSearchKind || '';
    const wordCountRule = (source as unknown as Record<string, string>).ruleSearchWordCount || '';
    const introRule = (source as unknown as Record<string, string>).ruleSearchIntroduce || '';
    const lastChapterRule = (source as unknown as Record<string, string>).ruleSearchLastChapter || '';

    // 编译 || && 后的子规则
    const compileFieldRule = (rule: string): ((item: HtmlElement) => string) => {
      if (!rule) return (_item: HtmlElement): string => '';
      const { rules, connector } = splitConnectorRules(rule.trim());
      if (!connector || rules.length === 1) {
        const nr = this.normalizeCssRule(rules[0]);
        return (item: HtmlElement): string => {
          return processPutGet(rules[0], (subRule: string) => parser.extractAttr(item, this.normalizeCssRule(subRule)));
        };
      }
      const compiled = rules.map(r => {
        const nr = this.normalizeCssRule(r);
        return (item: HtmlElement): string => {
          return processPutGet(r, (subRule: string) => parser.extractAttr(item, this.normalizeCssRule(subRule)));
        };
      });
      if (connector === '||') {
        return (item: HtmlElement): string => firstNonEmpty(compiled.map(fn => fn(item)));
      }
      if (connector === '&&') {
        return (item: HtmlElement): string => mergeAll(compiled.map(fn => fn(item)));
      }
      return compiled[0];
    };

    const getName = compileFieldRule(nameRule);
    const getAuthor = compileFieldRule(authorRule);
    const getCover = compileFieldRule(coverRule);
    const getNoteUrl = compileFieldRule(noteUrlRule);
    const getKind = compileFieldRule(kindRule);
    const getWordCount = compileFieldRule(wordCountRule);
    const getIntro = compileFieldRule(introRule);
    const getLastChapter = compileFieldRule(lastChapterRule);

    const results: SearchResult[] = [];

    for (let idx = 0; idx < items.length; idx++) {
      const item = items[idx];
      if (!item) continue;

      // 提取字段
      let name = getName(item);

      // 书名兜底：取元素内的第一个 <a> 文本
      if (!name) {
        const links = parser.querySelectorAll(item, 'a');
        if (links.length > 0) {
          name = links[0].text.trim();
        }
      }
      // 再兜底：取元素自身文本
      if (!name) {
        name = item.text.trim();
      }
      if (!name || name.length < 1) continue;

      // 作者
      let author = this.cleanAuthorName(getAuthor(item));
      // DEBUG: 显示归一化后的规则 + 匹配到的元素数
      const _normAuthor = this.normalizeCssRule(authorRule);
      if (idx < 3 || !author) {
        const _htmlSnippet = item.innerHtml ? item.innerHtml.substring(0, 120).replace(/\n/g, '') : '(no html)';
        console.info('[SrcEx] Author debug', source.sourceName,
         'rule=' + authorRule, 'norm=' + _normAuthor, 'got="' + author + '"',
         'html="' + _htmlSnippet + '"');
     }

      // 封面
      let coverUrl = getCover(item);
      // 兜底: 饿狼小说等通过正则从 bookUrl 生成封面URL，IMPORTANT DEBUG
      if (coverUrl && idx < 3) {
        console.info('[SrcEx] Cover OK idx=' + idx + ' url=' + coverUrl.substring(0, 80));
      }
      if (!coverUrl) {
        // 取第一个图片（尝试多种 src 属性）
        const imgs = parser.querySelectorAll(item, 'img');
        if (imgs.length > 0) {
          for (const img of imgs) {
            coverUrl = parser.getAttr(img, 'src') || parser.getAttr(img, 'data-src') ||
              parser.getAttr(img, 'data-original') || parser.getAttr(img, 'data-lazy-src') || '';
            if (coverUrl && !/\.(gif|svg|ico)(\b|$)/i.test(coverUrl)) break;
          }
        }
      }
      // 还找不到？试试背景图
      if (!coverUrl) {
        const bgMatch = item.innerHtml.match(/background(?:-image)?\s*:\s*url\(['"]?([^'")\s]+)['"]?\)/i);
        if (bgMatch) coverUrl = bgMatch[1];
      }

      // 详情页 URL
      let noteUrl = getNoteUrl(item);
      if (!noteUrl) {
        const links = parser.querySelectorAll(item, 'a');
        if (links.length > 0) {
          noteUrl = parser.getAttr(links[0], 'href') || '';
        }
      }

      // 相对路径转绝对
      if (coverUrl && coverUrl.startsWith('//')) {
        coverUrl = (baseUrl ? 'https:' : 'https:') + coverUrl;
      }
      if (coverUrl && !coverUrl.startsWith('http://') && !coverUrl.startsWith('https://') && !coverUrl.startsWith('data:')) {
        coverUrl = (baseUrl || '') + (coverUrl.startsWith('/') ? coverUrl : '/' + coverUrl);
      }
      if (coverUrl && !coverUrl.startsWith('http://') && !coverUrl.startsWith('https://') && !coverUrl.startsWith('data:')) {
        coverUrl = (baseUrl || '') + (coverUrl.startsWith('/') ? coverUrl : '/' + coverUrl);
      }
      if (noteUrl && noteUrl.startsWith('//')) {
        noteUrl = 'https:' + noteUrl;
      }
      if (noteUrl && !noteUrl.startsWith('http://') && !noteUrl.startsWith('https://')) {
        noteUrl = (baseUrl || '') + (noteUrl.startsWith('/') ? noteUrl : '/' + noteUrl);
      }

      const cssKind = getKind(item);
      const cssWordCount = getWordCount(item);
      const cssIntro = getIntro(item);
      const cssLastChapter = getLastChapter(item);

      results.push({
        key: (source.sourceUrl || '') + '|' + noteUrl + '|' + idx,
        name: name, author: author || '',
        coverUrl: coverUrl || '', noteUrl: noteUrl || '',
        origin: source.sourceName || '未知', originUrl: source.sourceUrl || '',
        kind: cssKind || '', wordCount: cssWordCount || '', lastUpdateTime: '', latestChapterTitle: cssLastChapter || '', introduce: cssIntro || '', helperMsg: '',
        duration: 0, searchTime: Date.now(),
        sourceCount: 1, sourceOrigins: [],
      });
    }

    return results;
  }

  // ============ JSON 解析 ============

  private parseJsonResults(json: Record<string, unknown>, source: BookSource, baseUrl: string, duration: number): SearchResult[] {
    let list: unknown[] = [];
    if (source.ruleSearchList) {
      const raw = this.getPath(json, source.ruleSearchList);
      if (Array.isArray(raw)) list = raw;
    }
    if (list.length === 0) {
      if (Array.isArray(json)) { list = json; } else {
        for (const p of ['data', 'list', 'items', 'results', 'books', 'rows', 'data.list', 'data.items', 'data.records', 'data.books', 'data.novels', 'data.bookList', 'data.booklist', 'data.rows']) {
          const raw = this.getPath(json, p);
          if (Array.isArray(raw)) { list = raw; break; }
        }
      }
    }
    return list.map((item: unknown) => {
      const itemObj = item as Record<string, unknown>;
      const name = this.firstStr(itemObj, source.ruleSearchName, 'novelName', 'name', 'title', 'bookName');
      const author = this.cleanAuthorName(this.firstStr(itemObj, source.ruleSearchAuthor, 'authorName', 'author'));
      if (!author) {
        console.info('[SrcEx] Author debug JSON', source.sourceName,
          'rule=' + (source.ruleSearchAuthor || ''), 'name="' + name.substring(0, 20) + '"');
      }
      let rawCover = this.firstStr(itemObj, source.ruleSearchCover, 'cover', 'coverUrl', 'cover_url', 'img', 'image', 'imageUrl', 'imgUrl', 'pic', 'thumbnail', 'poster', 'sImg', 'coverImg', 'cover_img');
      // 过滤非 URL 的封面值（数字 ID 等）
      const coverUrl = (rawCover && /^(https?:\/\/|\/\/|data:)/.test(rawCover)) ? rawCover : '';
      if (!coverUrl && rawCover) {
        console.info('[SrcEx] Bad coverUrl from', source.sourceName, ':', rawCover, 'rule:', source.ruleSearchCover);
      }
      let noteUrl = this.resolveSearchNoteUrl(itemObj, source.ruleSearchNoteUrl, baseUrl) ||
        this.firstStr(itemObj, 'noteUrl', 'bookUrl', 'novelId', 'id', 'url');
      if (noteUrl && !noteUrl.startsWith('http')) {
        const pathStr = /^\d+$/.test(noteUrl) ? '/book/' + noteUrl : '/novel/' + noteUrl;
        noteUrl = noteUrl.startsWith('/') ? (baseUrl || '') + noteUrl : (baseUrl || '') + pathStr;
      }
     const kind = this.firstStr(itemObj, source.ruleSearchKind || '', 'kind', 'type', 'category');
     const wordCount = this.firstStr(itemObj, source.ruleSearchWordCount || '', 'wordCount', 'wordNum', 'words');
     const introduce = this.firstStr(itemObj, source.ruleSearchIntroduce || '', 'introduce', 'intro', 'summary');
     const lastUpdateTime = this.firstStr(itemObj, source.ruleSearchLastUpdateTime || '', 'lastUpdateTime', 'updateTime', 'last_update_time');
     const latestChapterTitle = this.firstStr(itemObj, source.ruleSearchLastChapter || '', 'lastChapter', 'latestChapter', 'latestChapterTitle', 'last_update_chapter');
     return {
       key: (source.sourceUrl || '') + '|' + noteUrl,
       name: name || '未知书名', author: author || '', coverUrl: coverUrl || '',
       noteUrl: noteUrl || '', origin: source.sourceName || '未知',
       originUrl: source.sourceUrl || '',
       kind: kind, wordCount: wordCount,
       lastUpdateTime: lastUpdateTime, latestChapterTitle: latestChapterTitle, introduce: introduce, helperMsg: '',
       duration: duration, searchTime: Date.now(),
        sourceCount: 1,
        sourceOrigins: source.sourceName ? [source.sourceName] : []
      };
    });
  }

  private getPath(obj: Record<string, unknown>, path: string): unknown {
    if (!path) return undefined;
    // 处理 || 备用规则：尝试每个备选，返回第一个有值的
    const alternatives = path.split('||');
    for (const alt of alternatives) {
      const val = this.getSinglePath(obj, alt.trim());
      if (val !== undefined && val !== null) return val;
    }
    return undefined;
  }

  private getSinglePath(obj: Record<string, unknown>, path: string): unknown {
    if (!path) return undefined;
    // 去掉 $. 前缀（JSONPath root）
    let cleanPath = path.replace(/^\$\.?/, '');
    if (!cleanPath) return obj;

    const parts = cleanPath.split('.');
    let current: unknown = obj;
    for (const part of parts) {
      if (current === null || current === undefined) return undefined;
      // 数组索引: [0], [*] 或 key[0], key[*]
      const wildMatch = part.match(/^(\w+)?\[(\d+|\*)\]$/);
      if (wildMatch) {
        const keyName = wildMatch[1];
        const index = wildMatch[2];
        if (keyName) {
          const c = current as Record<string, unknown>;
          if (typeof current === 'object' && keyName in c) { current = c[keyName]; } else { return undefined; }
        }
        if (index === '*') {
          // [*] 返回数组本身，后面不再访问
          return Array.isArray(current) ? current : undefined;
        }
        if (Array.isArray(current)) {
          current = (current as unknown[])[parseInt(index)];
          continue;
        }
        return undefined;
      }
      const c = current as Record<string, unknown>;
      if (typeof current === 'object' && part in c) { current = c[part]; } else { return undefined; }
    }
    return current;
  }

  /** 去掉规则末尾的 @put:... / @js:... 等后缀，只保留 JSONPath 部分 */
  private cleanRule(rule: string): string {
    // ## 分隔符：前面是 JSONPath，后面是后处理规则
    let idx = rule.indexOf('##');
    if (idx < 0) idx = rule.indexOf('@put:');
    if (idx < 0) idx = rule.indexOf('@js:');
    if (idx < 0) idx = rule.indexOf('\n<js>');
    if (idx < 0) idx = rule.indexOf('\nhttps://');
    if (idx < 0) idx = rule.indexOf('\nhttp://');
    return idx >= 0 ? rule.substring(0, idx).trim() : rule;
  }

  /** 处理 <js> 代码、{{result}} 模板 和 ## 正则替换 */
  private postProcessRule(rule: string, value: string): string {
    if (!value) return value;
    let result = value;
    // 0. ## 正则替换: $.resourceName##（.* → 去掉括号内容
    const hashIdx = rule.indexOf('##');
    if (hashIdx >= 0) {
      const afterHash = rule.substring(hashIdx + 2);
      // 支持多级##: ##regex1##replacement1##regex2##replacement2
      const parts = afterHash.split('##');
      for (let i = 0; i + 1 < parts.length; i += 2) {
        const pattern = parts[i];
        const replacement = parts[i + 1];
        try {
          result = result.replace(new RegExp(pattern, 'g'), replacement);
        } catch(_e) {
          console.warn('[SrcEx] ## regex error: ' + pattern);
        }
      }
    }
    // 1. @js: 处理
    result = JsExpressionEvaluator.processJsResult(rule, result);
    // 2. <js>...</js> 代码
    const jsm = rule.match(/<js>([\s\S]*?)<\/js>/);
    if (jsm) {
      const r = this.evaluateSimpleRuleJs(jsm[1], result);
      if (r) {
        result = r;
      }
    }
    // 3. {{result}} 模板
    const tm = rule.match(/https?:\/\/[^\s\n]+\{\{result\}\}[^\s\n]*/);
    if (tm) {
      result = tm[0].replace(/\{\{result\}\}/g, result);
      console.info('[SrcEx] PostRule tmpl: ' + result.substring(0, 100));
    }
    return result;
  }

  private evaluateSimpleRuleJs(jsCode: string, currentResult: string): string {
    const code = (jsCode || '').trim();
    if (!code) return '';
    try {
      const script = 'var result=' + JSON.stringify(currentResult) + ';\n' + code;
      const r = globalScriptEngine.evaluateJsSync(script);
      if (r && r !== 'null' && r !== 'undefined') {
        return r.trim().replace(/^['"]|['"]$/g, '');
      }
    } catch (_e) {
      /* fallback below */
    }

    const numericValue = parseInt(currentResult, 10);
    if (isNaN(numericValue)) return '';
    let match = code.match(/^(\d+)\s*([+-])\s*parseInt\s*\(\s*result\s*\)\s*;?$/);
    if (match) {
      const base = parseInt(match[1], 10);
      return String(match[2] === '+' ? base + numericValue : base - numericValue);
    }
    match = code.match(/^parseInt\s*\(\s*result\s*\)\s*([+-])\s*(\d+)\s*;?$/);
    if (match) {
      const delta = parseInt(match[2], 10);
      return String(match[1] === '+' ? numericValue + delta : numericValue - delta);
    }
    console.warn('[SrcEx] JS postprocess returned empty, rule=' + code.substring(0, 120));
    return '';
  }

  private async postProcessRuleAsync(rule: string, value: string): Promise<string> {
    if (!rule || !value) return value;
    const aesMatch = rule.match(/java\.aesBase64DecodeToString\s*\(\s*result\s*,\s*['"]([^'"]+)['"]\s*,\s*['"]([^'"]+)['"]\s*,\s*['"]([^'"]+)['"]\s*\)/);
    if (aesMatch) {
      return await CryptoUtil.aesBase64DecodeToString(value, aesMatch[1], aesMatch[2], aesMatch[3]);
    }
    return this.postProcessRule(rule, value);
  }

  private firstStr(item: Record<string, unknown>, ...paths: (string | undefined)[]): string {
    for (const p of paths) {
      if (!p) continue;
      const cleaned = this.cleanRule(p);
      const val = this.getPath(item, cleaned);
      let raw = '';
      if (typeof val === 'string') raw = val;
      else if (typeof val === 'number') raw = String(val);
      else continue;
      const processed = this.postProcessRule(p, raw);
      if (processed) return processed;
    }
    return '';
  }

  private resolveSearchNoteUrl(item: Record<string, unknown>, rule: string, baseUrl: string): string {
    if (!rule) return '';
    const usesResultTemplate = /\{\{\s*result\s*\}\}/.test(rule);
    const hasPostProcessor = rule.includes('<js>') || rule.includes('@js:') || rule.includes('##');
    if (usesResultTemplate || hasPostProcessor) {
      return this.firstStr(item, rule);
    }
    if (rule.includes('{{')) {
      return this.resolveRuleTemplate(rule, item, baseUrl);
    }
    return this.firstStr(item, rule);
  }

  // ============ HTML 搜索结果提取（绕过损坏的 RuleParser） ============

  /**
   * 从 HTML 中提取搜索结果（支持真实书源的 CSS 选择器规则）
   *
   * 不依赖 RuleParser（其 CSS 解析有 bug, .class 被提前去掉前缀），
   * 直接在 SourceExecutor 层面实现正确的 CSS 元素匹配。
   *
   * @param html 书源搜索返回的 HTML
   * @param source 书源
   * @param baseUrl 基准 URL
   * @param listRule  列表选择器，如 .result-item / div.book-list > .item / #list
   * @param nameRule  书名选择器，如 h3.title a / .book-name@text
   * @param authorRule 作者选择器
   * @param coverRule  封面选择器
   * @param noteUrlRule 详情页 URL 选择器
   */
  private extractHtmlSearchResults(
    html: string, source: BookSource, baseUrl: string,
    listRule: string, nameRule: string, authorRule: string,
    coverRule: string, noteUrlRule: string
  ): SearchResult[] {
    if (!listRule || !html) return [];

    // 1) 解析 listRule 找到所有结果条目
    const items = this.findElementsByCss(html, listRule);
    if (items.length === 0) return [];

    const results: SearchResult[] = [];

    for (let idx = 0; idx < items.length; idx++) {
      const itemHtml = items[idx];
      if (!itemHtml || itemHtml.length < 10) continue;

      // 2) 从每个条目中提取字段
      const name = this.extractFieldByCss(itemHtml, nameRule) || '';
      const author = this.extractFieldByCss(itemHtml, authorRule) || '';
      const coverRaw = this.extractFieldByCss(itemHtml, coverRule) || '';
      let noteUrl = this.extractFieldByCss(itemHtml, noteUrlRule) || '';

      // 封面兜底：从 HTML 中提取第一张图片
      let coverUrl = coverRaw;
      if (!coverUrl) {
        const imgM = itemHtml.match(/<img[^>]*(?:src|data-src|data-original)=["']([^"']+)["'][^>]*>/i);
        coverUrl = imgM ? imgM[1] : '';
      }

      // 相对路径处理
      if (noteUrl && !noteUrl.startsWith('http://') && !noteUrl.startsWith('https://')) {
        noteUrl = (baseUrl || '') + (noteUrl.startsWith('/') ? noteUrl : '/' + noteUrl);
      }
      if (coverUrl && coverUrl.startsWith('//')) {
        coverUrl = 'https:' + coverUrl;
      }
      if (coverUrl && !coverUrl.startsWith('http://') && !coverUrl.startsWith('https://')) {
        coverUrl = (baseUrl || '') + (coverUrl.startsWith('/') ? coverUrl : '/' + coverUrl);
      }

      if (!name) continue; // 无书名则跳过

      results.push({
        key: (source.sourceUrl || '') + '|' + noteUrl + '|' + idx,
        name: name, author: author || '',
        coverUrl: coverUrl || '',
        noteUrl: noteUrl || '',
        origin: source.sourceName || '未知',
        originUrl: source.sourceUrl || '',
        kind: '', wordCount: '', lastUpdateTime: '', introduce: '', helperMsg: '',
        duration: 0, searchTime: Date.now(),
        sourceCount: 1,
        sourceOrigins: [],
        latestChapterTitle: '',
      });
    }
    return results;
  }

  /**
   * 用简化 CSS 选择器在 HTML 中查找匹配元素
   *
   * 支持的选择器模式：
   *   .class         → 类选择器
   *   tag.class      → 标签+类
   *   #id            → ID 选择器
   *   ancestor > desc → 子元素
   *   ancestor desc   → 后代元素
   *
   * @returns 匹配元素的内层 HTML 字符串数组
   */
  private findElementsByCss(html: string, selector: string): string[] {
    if (!selector || !html) return [];

    const s = selector.trim();

    // 处理后代/子选择器 ul.list > li 或 ul.list li
    if (s.includes('>') || s.includes(' ')) {
      // 先找祖先，再找后代
      const parts = s.split(/\s*>\s*|\s+/).filter(p => p.trim());
      let currentHtml = html;

      for (let i = 0; i < parts.length - 1; i++) {
        const matched = this.findElementsByCss(currentHtml, parts[i]);
        if (matched.length > 0) {
          // 取最后一个匹配的祖先
          currentHtml = matched[matched.length - 1];
        } else {
          return [];
        }
      }

      // 最后的子选择器
      const lastSelector = parts[parts.length - 1];
      return this.findElementsByCss(currentHtml, lastSelector);
    }

    // 解析选择器：tag.class#id
    const tagMatch = s.match(/^(\w+)/);
    const classMatch = s.match(/\.([\w-]+)/);
    const idMatch = s.match(/#([\w-]+)/);

    const tag = tagMatch ? tagMatch[1] : '';
    const cls = classMatch ? classMatch[1] : '';
    const id = idMatch ? idMatch[1] : '';

    // 构建匹配正则
    let pattern: string;

    if (id) {
      // ID 选择器: #id
      pattern = `<[^>]*id=["']${this.escapeRegex(id)}["'][^>]*>([\\s\\S]*?)<\\/[^>]+>`;
    } else if (tag && cls) {
      // tag.class 选择器
      pattern = `<${tag}[^>]*class=["'][^"']*${this.escapeRegex(cls)}[^"']*["'][^>]*>([\\s\\S]*?)<\\/${tag}>`;
    } else if (cls) {
      // .class 选择器
      pattern = `<([a-zA-Z0-9]+)[^>]*class=["'][^"']*${this.escapeRegex(cls)}[^"']*["'][^>]*>([\\s\\S]*?)<\\/\\1>`;
    } else if (tag) {
      // tag 选择器
      pattern = `<${tag}[^>]*>([\\s\\S]*?)<\\/${tag}>`;
    } else {
      return [];
    }

    const regex = new RegExp(pattern, 'gi');
    const results: string[] = [];
    let match: RegExpExecArray | null;

    while ((match = regex.exec(html)) !== null) {
      // .class 模式: match[1] = tagName, match[2] = innerHTML
      // tag.class 模式: match[1] = innerHTML
      // #id 模式: match[1] = innerHTML
      const innerHtml = cls && !tag ? match[2] : match[1];
      if (innerHtml && innerHtml.trim()) {
        results.push(innerHtml.trim());
      }
    }

    return results;
  }

  /**
   * 从 HTML 片段中用 CSS 选择器提取字段值
   *
   * 支持 @text / @href / @src / @html 后缀
   */
  private extractFieldByCss(html: string, rule: string): string {
    if (!rule || !html) return '';

    const s = rule.trim();

    // 提取属性后缀: @text, @href, @src, @html
    let attr = 'text';
    let selector = s;
    const attrMatch = s.match(/^(.*?)@(text|href|src|html)$/i);
    if (attrMatch) {
      selector = attrMatch[1].trim();
      attr = attrMatch[2].toLowerCase();
    }

    // 没有选择器部分 → 当前元素的属性
    if (!selector) {
      if (attr === 'text') return this.stripHtml(html.substring(0, 200));
      const aMatch = html.match(new RegExp(`${attr}=["']([^"']+)["']`, 'i'));
      return aMatch ? aMatch[1] : '';
    }

    // 有选择器 → 在 html 中查找匹配元素
    const elements = this.findElementsByCss(html, selector);
    if (elements.length === 0) return '';

    const elHtml = elements[0];

    if (attr === 'text' || attr === 'html') {
      if (attr === 'text') {
        return this.stripHtml(elHtml.substring(0, 200));
      }
      return elHtml;
    }

    // @href / @src: 从原始 html 中查找属性
    // 在原始的匹配位置附近查找
    const fullMatch = html.match(new RegExp(
      `<[^>]*${this.escapeRegex(selector.replace(/[.#]/g, ''))}[^>]*>`,
      'i'
    ));
    if (fullMatch) {
      const attrValue = fullMatch[0].match(new RegExp(`${attr}=["']([^"']+)["']`, 'i'));
      if (attrValue) return attrValue[1];
    }

    return '';
  }

  /** 转义正则特殊字符 */
  private escapeRegex(str: string): string {
    return str.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  private parseContentFromRules(html: string, rules: Record<string, string>): string {
    const rule = rules['content'] || '';
    if (rule) {
      const value = this.extractHtmlRuleValue(html, rule);
      if (value) {
        return this.stripHtml(value);
      }
    }
    return this.stripHtml(html);
  }

  private extractHtmlRuleValue(html: string, rule: string): string {
    if (!html || !rule) return '';
    const trimmed = rule.trim();
    const textHref = trimmed.match(/^text\.([^@]+)@href$/i);
    if (textHref) {
      const label = this.escapeRegex(textHref[1].trim());
    const re = new RegExp("<a[^>]*href=[\"']([^\"']+)[\"'][^>]*>\\s*[^<]*" + label + "[^<]*\\s*</a>", 'i');
      const m = html.match(re);
      return m ? m[1] : '';
    }
    const parser = getHtmlParser();
    const doc = parser.parse(html);
    return parser.extractAttr(doc, this.normalizeCssRule(trimmed));
  }

  private resolvePageUrl(url: string, currentUrl: string): string {
    if (!url) return '';
    let nextUrl = url.trim();
    if (!nextUrl || nextUrl.startsWith('#') || nextUrl.startsWith('javascript:')) return '';
    if (nextUrl.startsWith('//')) return 'https:' + nextUrl;
    if (nextUrl.startsWith('http://') || nextUrl.startsWith('https://')) return nextUrl;
    const origin = currentUrl.replace(/^(https?:\/\/[^\/]+).*$/, '$1');
    if (nextUrl.startsWith('/')) return origin + nextUrl;
    const base = currentUrl.replace(/[#?].*$/, '').replace(/\/[^\/]*$/, '/');
    return base + nextUrl;
  }

  private applyReplaceRegex(content: string, replaceRule: string): string {
    if (!content || !replaceRule) return content;
    let result = content;
    const rules = replaceRule.startsWith('##') ? replaceRule.substring(2).split('##') : replaceRule.split('##');
    for (let i = 0; i < rules.length; i += 2) {
      const pattern = rules[i];
      const replacement = i + 1 < rules.length ? rules[i + 1] : '';
      if (!pattern) continue;
      try {
        result = result.replace(new RegExp(pattern, 'g'), replacement);
      } catch (_e) {
        /* ignore invalid replacement rule */
      }
    }
    return result.trim();
  }

  private stripHtml(html: string): string {
    return HtmlUtil.stripHtml(html);
  }

  /**
   * 从 JSON 响应解析目录列表（$.xxx JSONPath）
   */
  private async parseJsonToc(json: Record<string, unknown>, rules: Record<string, string>, baseUrl: string): Promise<BookSourceChapter[]> {
    const tocRule = rules['toc'] || '';
    if (!tocRule) return [];

    let list: unknown[] = [];
    const raw = this.getPath(json, tocRule);
    if (Array.isArray(raw)) list = raw;

    if (list.length === 0) {
      for (const p of ['data', 'list', 'rows', 'items', 'data.list', 'data.rows', 'data.items']) {
        const v = this.getPath(json, p);
        if (Array.isArray(v)) { list = v; break; }
      }
    }

    const titleRule = rules['tocTitle'] || '';
    const urlItemRule = rules['tocUrlItem'] || '';

    const chapters: BookSourceChapter[] = [];
    for (let index = 0; index < list.length; index++) {
      const item = list[index];
      const itemObj = item as Record<string, unknown>;

      let title = '';
      if (titleRule) {
        let cleanTitleRule = titleRule;
        let postProcs: string[] = [];
        if (titleRule.includes('##')) {
          const parts = titleRule.split('##');
          cleanTitleRule = parts[0];
          postProcs = parts.slice(1);
        }
        const val = this.getPath(itemObj, cleanTitleRule);
        if (val !== undefined && val !== null) {
          title = String(val);
          for (const proc of postProcs) {
            try {
              const regex = new RegExp(proc);
              const m = title.match(regex);
              if (m && m.length > 1 && m[1] !== undefined) {
                title = m[1];
              } else {
                title = title.replace(regex, '');
              }
            } catch (_e) { /* ignore */ }
          }
        }
      }
      if (!title) {
        title = String(itemObj['title'] || itemObj['name'] || itemObj['serialName'] || '第' + (index + 1) + '章');
      }

      let url = '';
      if (urlItemRule) {
        // 检查是否是复杂模板（如 method/body/headers JSON 格式）
        if (urlItemRule.includes('{\n') || urlItemRule.includes('"method"')) {
          url = this.resolveTocUrlTemplate(urlItemRule, baseUrl);
        } else {
          const cleanUrlRule = this.cleanRule(urlItemRule);
          const val = this.getPath(itemObj, cleanUrlRule);
          if (val !== undefined && val !== null) {
            url = String(val);
            url = await this.postProcessRuleAsync(urlItemRule, url);
          }
        }
        url = url.replace(/\{\{\$\.([^}]+)\}\}/g, (_m: string, path: string) => {
          const v = this.getPath(itemObj, '$.' + path);
          return v !== undefined ? String(v) : '';
        });
      }
      if (!url) {
        url = String(itemObj['url'] || itemObj['link'] || itemObj['chapterUrl'] || '');
        if (url && !url.startsWith('http') && !url.startsWith('//')) {
          const prefix = baseUrl.replace(/^(https?:\/\/[^\/]+).*$/, '$1');
          url = prefix + (url.startsWith('/') ? '' : '/') + url;
        }
      }

      chapters.push({ title: title || '第' + (index + 1) + '章', url, index });
    }
    return chapters;
  }

  /**
   * 从规则解析目录列表
   */
  private parseTocFromRules(html: string, rules: Record<string, string>): BookSourceChapter[] {
    const tocRule = rules['toc'] || '';
    if (!tocRule) return [];

    const parser = getHtmlParser();
    const doc = parser.parse(html);
    const items = parser.querySelectorAll(doc, this.normalizeCssRule(tocRule));
    if (!items || items.length === 0) return [];

    const titleRule = rules['tocTitle'] || '';
    const urlItemRule = rules['tocUrlItem'] || '';

    return items.map((item: HtmlElement, index: number): BookSourceChapter => {
      const parseField = (rule: string): string => {
        if (!rule) return '';
        // 剥离 ## 后缀 post-processing（例如 $.serialName##正文卷. ）
        let postProcessors: string[] = [];
        let cleanRule = rule;
        if (rule.includes('##')) {
          const parts = rule.split('##');
          cleanRule = parts[0];
          postProcessors = parts.slice(1);
        }
        let result = '';
        if (cleanRule === 'text') {
          result = item.text || '';
        } else if (cleanRule === 'ownText' || cleanRule === 'textNodes') {
          result = item.ownText || '';
        } else if (cleanRule === 'href' || cleanRule === 'src') {
          result = parser.getAttr(item, cleanRule);
        } else if (cleanRule === 'html') {
          result = item.innerHtml || '';
        } else if (cleanRule) {
          result = parser.extractAttr(item, this.normalizeCssRule(cleanRule));
        }
        // 应用 ## 后缀 post-processing
        for (const proc of postProcessors) {
          if (proc === 'trim' || proc === 'Trim' || proc === 'TRIM') {
            result = result.trim();
          } else {
            try {
              const regex = new RegExp(proc);
              const match = result.match(regex);
              if (match && match.length > 1 && match[1] !== undefined) {
                result = match[1];
              } else {
                result = result.replace(regex, '');
              }
            } catch (_e) { /* 忽略无效正则 */ }
          }
        }
        // 解析结果中的 {{$.xxx}} 模板（从当前 item 中提取字段值）
        if (result.includes('{{')) {
          result = result.replace(/\{\{\$\.([^}]+)\}\}/g, (_m: string, path: string) => {
            return '';
          });
        }
        return HtmlUtil.stripHtml(result).trim();
      };

      // 用 resolveFieldRule 支持 || && 操作符
      const resolveTocField = (rule: string): string => {
        if (!rule) return '';
        return resolveFieldRule(rule, (subRule: string) => parseField(subRule));
      };

      let title = resolveTocField(titleRule);
      if (title) {
        if (index < 3) console.info('[SrcEx] TocTitle OK titleRule=' + titleRule + ' title=' + title.substring(0, 40));
      } else {
        title = HtmlUtil.stripHtml(item.text || '').trim();
      }
      return {
        title: title || `第${index + 1}章`,
        url: (() => {
          const u = resolveTocField(urlItemRule) || '';
          if (index === 0) console.info('[SrcEx] Chapter0 url len=' + u.length + ':', u.substring(0, 300));
          return u;
        })(),
        index: index,
      };
    });
  }

  /**
   * 从 HTML 中提取章节链接（兜底方案）
   * 查找常见目录结构中的 <a> 标签
   */
  private extractTocFromHtml(html: string, source: BookSource): BookSourceChapter[] {
    const chapters: BookSourceChapter[] = [];
    const seen = new Set<string>();

    // 需要过滤的导航/非章节链接关键词（不限定 ^$，因为可能含额外字符）
    const skipPattern = /(上一章|下一章|回目录|返回目录|目录|首页|返回|下一页|上一页|最后一页|第一页|全部章节|章节目录|加书架|加入书架|推荐|投票|收藏|书签|设置|字体|背景|阅读|开始阅读|搜索|登录|注册|关于|帮助|联系我们|设为首页|收藏本站)/i;

    // 需要跳过的 URL 模式
    const skipUrl = /^(javascript:|#|$|\.(css|js|ico|png|jpg|gif))/i;

    // 查找目录区域常见的标签模式（按精确度排序）
    const patterns = [
      // <dd><a href="...">章节名</a></dd> (常见于小说站)
      /<dd[^>]*>\s*<a[^>]*href=["']([^"']+)["'][^>]*>([^<]{1,100})<\/a>\s*<\/dd>/gi,
      // <li><a href="...">章节名</a></li>
      /<li[^>]*>\s*<a[^>]*href=["']([^"']+)["'][^>]*>([^<]{1,100})<\/a>\s*<\/li>/gi,
      // <a href="...">第X章 ...</a> (含"第"和"章"的链接)
      /<a[^>]*href=["']([^"']+)["'][^>]*>([^<]*第[^<]{1,30}章[^<]{0,80})<\/a>/gi,
    ];

    const baseUrl = getBaseUrl(source.sourceUrl);

    for (const regex of patterns) {
      chapters.length = 0;
      seen.clear();
      let match: RegExpExecArray | null;
      while ((match = regex.exec(html)) !== null) {
        let linkUrl = (match[1] || '').trim();
        const title = (match[2] || '').trim();

        // 基础过滤
        if (!title || !linkUrl) continue;
        if (title.length < 2 || title.length > 80) continue;
        if (skipPattern.test(title)) continue;
        if (skipUrl.test(linkUrl)) continue;
        if (seen.has(linkUrl)) continue;

        // 过滤纯数字/纯标点标题
        if (/^[\d\s\.\-—·,，。、]+$/.test(title)) continue;

        seen.add(linkUrl);

        // 相对路径转绝对
        if (!linkUrl.startsWith('http://') && !linkUrl.startsWith('https://')) {
          linkUrl = (baseUrl || '') + (linkUrl.startsWith('/') ? linkUrl : '/' + linkUrl);
        }

        chapters.push({ title: title, url: linkUrl, index: chapters.length });
      }

      // 至少匹配到 3 个才接受
      if (chapters.length >= 3) break;
    }

    // 后处理：很多网站同时有"最近更新"和"全部章节"两个列表
    // 取第一个以"第1章"/"第一章"/"引子"/"序章"开头的真实章节作为起点
    if (chapters.length > 5) {
      let firstRealIdx = 0;
      for (let i = 0; i < Math.min(chapters.length, 30); i++) {
        const t = chapters[i].title;
        if (/^第[一1]章/.test(t) || /^(引子|序章|楔子|序幕|序言)/.test(t)) {
          firstRealIdx = i;
          break;
        }
      }
      // 如果没找到"第1章"，看第一个标题是否含较高的数字（如1032）
      // 如果是，跳过开头那个"最近更新"分组
      if (firstRealIdx === 0) {
        const firstNum = chapters[0].title.match(/(\d+)/);
        if (firstNum && parseInt(firstNum[1]) > 100) {
          // 找数字回落点：当前后章节数字差 > 500 时看作分界点
          for (let i = 1; i < Math.min(chapters.length, 30); i++) {
            const prevNum = chapters[i - 1].title.match(/(\d+)/);
            const currNum = chapters[i].title.match(/(\d+)/);
            if (prevNum && currNum) {
              const diff = parseInt(prevNum[1]) - parseInt(currNum[1]);
              if (diff > 500) {
                firstRealIdx = i;
                break;
              }
            }
          }
        }
      }
      if (firstRealIdx > 0) {
        console.info('[SrcEx] Trimmed', firstRealIdx, 'non-chapter items from TOC');
        return chapters.slice(firstRealIdx).map((ch, i) => ({ ...ch, index: i }));
      }
    }

    return chapters;
  }

  /**
   * 从 HTML 中提取可能的书名（兜底方案）
   * 增强过滤：排除导航/分类/联系等非书籍链接
   */
  private extractBookNamesFromHtml(html: string, baseUrl: string): Array<{name: string; url: string}> {
    const items: Array<{name: string; url: string}> = [];
    const seen = new Set<string>();

    // 过滤非书籍的导航/功能链接

    // 判断是否为书籍类 URL 路径
    function isBookPath(url: string): boolean {
      return /(?:\/book\/|\/novel\/|\/read\/|\/txt\/|\/info\/|\/chapter\/|\d{5,})/i.test(url);
    }

    /**
     * 判断文本是否像书名（增强版）
     * 参考 legado-with-MD3 classifyBucket + formatBookName
     */
    function isBookTitle(text: string): boolean {
      if (!text || text.length < 2 || text.length > 40) return false;

      // 先清洗再判断
      const cleaned = text
        .replace(/\s+作\s*者[:：\s].*$/g, '')
        .replace(/\s+\S+\s+著\s*$/g, '')
        .trim();

      if (!cleaned) return false;

      // 章节标题：包含"第X章"、"最新：第"等
      if (/^第[一二三四五六七八九十\d零○\s、.．]/.test(cleaned)) return false;
      if (/最新[：:]\s*第/.test(cleaned) || /^(最新章节|最后更新|今日更新)/.test(cleaned)) return false;

      // 精确匹配常见非书籍词
      const commonNonBook = [
        '首页', '书架', '分类', '排行', '榜单', '完本', '全本', '免费',
        '会员', '充值', '登录', '注册', '关于', '帮助', '联系我们',
        '投稿', '我的', '个人中心', '手机版', '电脑版', '客户端',
        '推荐', '公告', '活动', '合作', '广告', '联系', 'QQ群',
        '意见反馈', '用户协议', '隐私政策', '免责声明', '网站地图',
        '友情链接', '设为首页', '收藏本站', 'RSS', '订阅',
        '热门', '随机', '标签', '热门标签',
        '玄幻小说', '武侠小说', '仙侠小说', '都市小说', '言情小说',
        '历史小说', '军事小说', '游戏小说', '科幻小说', '悬疑小说',
        '女生小说', '男生小说', '全部小说', '完本小说', '最新小说',
        '热门小说', '推荐小说', '连载小说', '免费小说',
      ];
      if (commonNonBook.some(w => cleaned === w)) return false;

      // 书名应当以中文为主
      const cjkCount = (cleaned.match(/[\u4e00-\u9fff]/g) || []).length;
      if (cjkCount === 0) return false;

      // 纯数字/纯标点标题
      if (/^[\d\s.．\-—·,，。、：:？?!！…]+$/.test(cleaned)) return false;

      return true;
    }

    // 优先：从 <h2>/<h3> 标题中提取（更可能是书名）
    const headerRegex = /<h([2-4])[^>]*>[\s]*<a[^>]*href=["']([^"']+)["'][^>]*>([^<]{2,50})<\/a>[\s]*<\/h\1>/gi;
    let match: RegExpExecArray | null;
    while ((match = headerRegex.exec(html)) !== null) {
      const text = match[3].trim();
      let linkUrl = match[2].trim();
      if (isBookTitle(text) && !seen.has(text)) {
        if (linkUrl.startsWith('#') || linkUrl.startsWith('javascript:')) continue;
        seen.add(text);
        if (linkUrl && !linkUrl.startsWith('http')) {
          linkUrl = (baseUrl || '') + (linkUrl.startsWith('/') ? linkUrl : '/' + linkUrl);
        }
        items.push({ name: text, url: linkUrl });
      }
    }

    // 补充：从 <li>/<dd>/<div>/<span> 内的 <a> 提取书籍路径
    const linkRegex = /<(?:li|dd|div|p|span)[^>]*>[\s]*<a[^>]*href=["']([^"']+)["'][^>]*>([^<]{2,40})<\/a>/gi;
    while ((match = linkRegex.exec(html)) !== null) {
      const text = match[2].trim();
      let linkUrl = match[1].trim();
      if (linkUrl.startsWith('#') || linkUrl.startsWith('javascript:')) continue;
      if (isBookTitle(text) && (isBookPath(linkUrl) || !seen.has(text))) {
        if (!seen.has(text)) {
          seen.add(text);
          if (linkUrl && !linkUrl.startsWith('http')) {
            linkUrl = (baseUrl || '') + (linkUrl.startsWith('/') ? linkUrl : '/' + linkUrl);
          }
          items.push({ name: text, url: linkUrl });
        }
      }
    }

    // 最后：普通 <a> 标签（仅当结果不足且 URL 像书籍路径）
    if (items.length < 3) {
      const plainRegex = /<a[^>]*href=["']([^"']+)["'][^>]*>([^<]{2,30})<\/a>/gi;
      while ((match = plainRegex.exec(html)) !== null) {
        const text = match[2].trim();
        let linkUrl = match[1].trim();
        if (linkUrl.startsWith('#') || linkUrl.startsWith('javascript:')) continue;
        if (isBookTitle(text) && isBookPath(linkUrl) && !seen.has(text)) {
          seen.add(text);
          if (linkUrl && !linkUrl.startsWith('http')) {
            linkUrl = (baseUrl || '') + (linkUrl.startsWith('/') ? linkUrl : '/' + linkUrl);
          }
          items.push({ name: text, url: linkUrl });
        }
      }
    }

    return items.slice(0, 30);
  }
}

/** 从 HTML 片段中提取第一张图片的 src（支持懒加载和 CSS background-image） */
function extractFirstImgSrc(html: string): string {
  const imgM = html.match(/<img[^>]*(?:src|data-src|data-original|data-lazy-src)=["']([^"']+)["'][^>]*>/i);
  if (imgM) return imgM[1];
  const bgM = html.match(/background-image:\s*url\(['"]?([^'")\s]+)['"]?\)/i);
  return bgM ? bgM[1] : '';
}

export const globalSourceExecutor = new SourceExecutor();
