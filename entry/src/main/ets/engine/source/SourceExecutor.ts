/**
 * 书源执行器（核心）— ArkTS 负责 HTTP，JS 只做解析
 *
 * 避免 NAPI 桥 http.get() 死锁：所有 HTTP 请求在 ArkTS 侧完成，
 * 预取 HTML 后传给 QuickJS 引擎进行规则解析。
 */
import { BookSource, BookSourceBookInfo, BookSourceChapter } from '../../model/BookSource';
import { SearchResult, getBookMergeKey } from '../../model/SearchResult';
import { globalScriptEngine } from './ScriptEngine';
import { getPolyfillScript, buildRuleExecutorScriptWithHtml } from './ScriptApi';
import { RuleParser } from './RuleParser';
import { NetUtil } from '../../util/NetUtil';
import { HtmlUtil } from '../../util/HtmlUtil';
import { getHtmlParser, HtmlElement } from '../../util/HtmlParser';

function getBaseUrl(rawUrl: string): string {
  if (!rawUrl) return '';
  return rawUrl.replace(/##.*$/, '').replace(/\/+$/, '');
}

function buildUrl(template: string, keyword: string, page: number, baseUrl: string): { url: string; method?: string; body?: string; charset?: string } {
  const encoded = encodeURIComponent(keyword);
  let url = template
    .replace(/\{\{key\}\}/g, encoded)
    .replace(/\{\{keyword\}\}/g, encoded)
    .replace(/\{\{page\}\}/g, String(page))
    .replace(/\{\{pageNum\}\}/g, String(page + 1));
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

  // 处理 URL 末尾的 JSON 选项: url,{"method":"POST","body":"..."} 或 url{"method":"POST",...}
  let method = 'GET';
  let body = '';
  let charset = '';

  // 先尝试匹配带逗号的: url,{...}
  let jsonOptMatch = url.match(/^(https?:\/\/[^,]+),(\{.*\})$/);
  if (!jsonOptMatch) {
    // 再尝试不用逗号的: url{...}（某些源省略了逗号）
    jsonOptMatch = url.match(/^(https?:\/\/[^#]+)(\{.*\})$/);
  }
  if (!jsonOptMatch) {
    // 最后尝试: url#xxx{...} (有 # 选择器后跟 JSON)
    jsonOptMatch = url.match(/^(https?:\/\/[^#]+)#[^,]*?,?(\{.*\})$/);
  }

  if (jsonOptMatch) {
    url = jsonOptMatch[1].replace(/#.*$/, ''); // 去掉 # 选择器部分
    try {
      const opts = JSON.parse(jsonOptMatch[2]);
      if (opts.method) method = opts.method.toUpperCase();
      if (opts.body) body = opts.body
        .replace(/\{\{key\}\}/g, encoded)
        .replace(/\{\{keyword\}\}/g, encoded)
        .replace(/\{\{page\}\}/g, String(page));
      if (opts.charset) charset = opts.charset;
    } catch (_e) { /* ignore parse errors */ }
  }

  // 相对路径处理
  if (!url.startsWith('http://') && !url.startsWith('https://') && baseUrl) {
    const base = baseUrl.replace(/\/+$/, '');
    url = base + (url.startsWith('/') ? url : '/' + url);
  }
  // 清理多余的空白
  url = url.trim();

  return { url, method, body, charset };
}

function parseHeader(headerStr: string): Record<string, string> {
  if (!headerStr) return {};
  try { return JSON.parse(headerStr) as Record<string, string>; } catch (_e) { return {}; }
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
    onProgress?: (merged: SearchResult[], processed: number, total: number) => void
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
     * 格式化书名：移除 "作者:XXX"、"XX 著" 等噪声
     * 参考 legado-with-MD3 BookHelp.formatBookName()
     */
    function formatBookName(raw: string): string {
      return raw
        .replace(/\s+作\s*者[:：\s].*$/g, '')
        .replace(/\s+\S+\s+著\s*$/g, '')
        .replace(/[-—·・][\s]*作\s*者[:：\s].*$/g, '')
        .trim();
    }

    /**
     * 判断一个搜索结果是否有效（放宽过滤，只排除明显不是书籍的条目）
     */
    function isValidBookName(name: string): boolean {
      if (!name || name.length < 2 || name.length > 50) return false;
      // 章节标题
      if (/^第[一二三四五六七八九十\d零○\s、.．]/.test(name)) return false;
      if (/最新[：:]\s*第/.test(name) || /^(最新章节|最后更新|今日更新)/.test(name)) return false;
      // 常见非书籍名（精确匹配）
      const commonNonBook = new Set([
        '首页','书架','分类','排行','完本','免费','登录','注册',
        '关于','帮助','联系我们','网站地图','友情链接','设为首页','收藏本站',
      ]);
      if (commonNonBook.has(name)) return false;
      return true;
    }

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
            const merged: SearchResult = {
              key: existing.key,
              name: existing.name,
              author: existing.author,
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
            };
            mergedMap.set(key, merged);
            console.info('[SrcEx] Merged:', r.origin || r.originUrl, '→', cleanName,
              'count:', merged.sourceCount);
          }
        } else {
          urlSet.add(r.originUrl || '');
          // 新书籍
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
          });
        }
      }
    }

    // 每个源独立搜索，每完成一个就触发回调
    const runOneSource = async (source: BookSource): Promise<void> => {
      if (!source.enabled || !source.ruleSearchUrl) return;
      try {
        const results = await this.searchSingle(keyword, source);
        // 增量合并该源的结果到持久 Map
        incrementMerge(results);
      } catch (_e) {
        // 单个源失败不影响其他源
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
  
  private async searchSingle(keyword: string, source: BookSource): Promise<SearchResult[]> {
    if (!source.enabled || !source.ruleSearchUrl) return [];
    const baseUrl = getBaseUrl(source.sourceUrl);
    const { url, method, body, charset } = buildUrl(source.ruleSearchUrl, keyword, 1, baseUrl);

    if (!url || (!url.startsWith('http://') && !url.startsWith('https://'))) {
      console.warn('[SrcEx] Invalid URL for', source.sourceName, ':', url);
      return [];
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
        bodyText = await NetUtil.httpPost(url, body || '', headers);
      } else {
        bodyText = await NetUtil.httpGet(url, headers);
      }
      if (!bodyText) {
        console.warn('[SrcEx] Empty response from', source.sourceName);
        return [];
      }
      console.info('[SrcEx] Got', bodyText.length, 'bytes from', source.sourceName);

      // === 第一步：JSON 直接解析（API 类书源） ===
      try {
        const jsonObj = JSON.parse(bodyText) as Record<string, unknown>;
        const results = this.parseJsonResults(jsonObj, source, baseUrl, 0);
        if (results.length > 0) {
          console.info('[SrcEx] JSON OK:', results.length, 'from', source.sourceName);
          return results;
        }
      } catch (_e) { /* not JSON */ }

      // === 第二步：用 HtmlParser + CSS 选择器提取（使用书源规则） ===
      if (source.ruleSearchList) {
        try {
          const results = this.extractWithParser(bodyText, source, baseUrl);
          if (results.length > 0) {
            console.info('[SrcEx] Parser CSS:', results.length, 'from', source.sourceName);
            return results;
          }
        } catch (_e) {
          console.warn('[SrcEx] Parser error:', (_e as Error).message);
        }
      }

      // === 第三步：通用 HTML 书名提取（兜底） ===
      console.info('[SrcEx] Fallback extract for', source.sourceName);
      const items = this.extractBookNamesFromHtml(bodyText, baseUrl);
      if (items.length > 0) {
        console.info('[SrcEx] Fallback:', items.length, 'items from', source.sourceName);
        return items.map((item, idx: number): SearchResult => {
          // 提取封面（在链接附近找图片）
          let coverUrl = '';
          if (item.url) {
            const pos = bodyText.indexOf(item.url.replace(baseUrl, ''));
            const ctxStart = Math.max(0, (pos >= 0 ? pos : 0) - 800);
            const ctxEnd = Math.min(bodyText.length, (pos >= 0 ? pos : idx * 200) + 1200);
            const ctx = bodyText.substring(ctxStart, ctxEnd);
            const imgM = ctx.match(/<img[^>]*(?:src|data-src|data-original|data-lazy-src)=["']([^"']+)["'][^>]*>/i);
            coverUrl = imgM ? imgM[1] : '';
            if (!coverUrl) {
              const bgM = ctx.match(/background-image:\s*url\(['"]?([^'")\s]+)['"]?\)/i);
              coverUrl = bgM ? bgM[1] : '';
            }
            if (coverUrl && !coverUrl.startsWith('http')) {
              coverUrl = (baseUrl || '') + (coverUrl.startsWith('/') ? coverUrl : '/' + coverUrl);
            }
          }
          return {
            key: (source.sourceUrl || '') + '|' + item.url + '|' + idx,
            name: item.name, author: '',
            coverUrl: coverUrl || '', noteUrl: item.url || '',
            origin: source.sourceName || '未知', originUrl: source.sourceUrl || '',
            kind: '', wordCount: '', lastUpdateTime: '', introduce: '', helperMsg: '',
            duration: 0, searchTime: Date.now(),
            sourceCount: 1, sourceOrigins: [],
          };
        });
      }

      console.warn('[SrcEx] No results from', source.sourceName, '- HTML length:', bodyText.length);
      return [];
    } catch (err) {
      const msg = (err as Error).message;
      if (msg.includes('403') || msg.includes('Cloudflare')) {
        this.lastBlockedUrl = url;
        console.info('[SrcEx] 403/Cloudflare detected for', source.sourceName, url.substring(0, 60));
      }
      console.warn('[SrcEx] Search failed', source.sourceName, ':', msg);
      return [];
    }
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

  async getContent(source: BookSource, contentUrl: string, bookUrl?: string): Promise<string> {
    console.info('[SrcEx] getContent input - chapterUrl:', (contentUrl || '').substring(0, 60), 'bookUrl:', ((bookUrl || '')).substring(0, 60));

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
    console.info('[SrcEx] getContent final URL:', contentUrl.substring(0, 80));
    try {
      const headers: Record<string, string> = {
        'Accept': 'text/html,application/json,*/*',
        'Referer': source.sourceUrl || '',
        ...parseHeader(source.header)
      };
      const body = await NetUtil.httpGet(contentUrl, headers);
      if (!body) return '';

      // JSON 直接解析
      try {
        const json = JSON.parse(body) as Record<string, unknown>;
        if (typeof json === 'string') return json as string;
        if (json['content']) return json['content'] as string;
        if (json['data']) {
          const data = json['data'];
          if (typeof data === 'string') return data;
        }
      } catch (_e) { /* not JSON */ }

      // 规则解析：直接使用书源的内容规则，不通过 QuickJS（避免大数据传参溢出）
      if (source.ruleBookContent) {
        const result = this.parseContentFromRules(body, { content: source.ruleBookContent });
        if (result && result.length > 0) return result;
      }
      return this.stripHtml(body);
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
    // ruleTocUrl 是目录页 URL 模板，可能包含 {{bookUrl}}、{{id}} 等占位符
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
      const body = await NetUtil.httpGet(tocUrl, headers);
      if (!body || body.length < 100) return [];

      // 规则解析：直接使用书源的目录规则，不通过 QuickJS（避免大数据传参溢出）
      const tocRules: Record<string, string> = {
        toc: source.ruleToc || '',
        tocTitle: source.ruleTocTitle || '',
        tocUrlItem: source.ruleTocUrlItem || '',
      };
      if (tocRules.toc) {
        const chapters = this.parseTocFromRules(body, tocRules);
        if (chapters.length > 0) {
          const baseUrl = tocUrl.replace(/^(https?:\/\/[^\/]+).*$/, '$1');
          return chapters.map(ch => ({
            ...ch,
            url: ch.url && !ch.url.startsWith('http')
              ? (baseUrl + (ch.url.startsWith('/') ? ch.url : '/' + ch.url))
              : ch.url
          }));
        }
      }

      // 兜底：从 HTML 中提取章节链接
      const chapters = this.extractTocFromHtml(body, source);
      if (chapters.length > 0) return chapters;
    } catch (err) {
      console.warn('[SrcEx] getToc failed:', (err as Error).message);
      return [];
    }
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

  /**
   * 使用 HtmlParser 解析 HTML，通过 CSS 选择器提取搜索结果
   * 替代之前损坏的 RuleParser 和正则方案
   */
  private extractWithParser(body: string, source: BookSource, baseUrl: string): SearchResult[] {
    if (!body || !source.ruleSearchList) return [];

    const parser = getHtmlParser();
    const doc = parser.parse(body);

    // 用 ruleSearchList 查找结果列表
    const items = parser.querySelectorAll(doc, source.ruleSearchList);
    if (!items || items.length === 0) return [];

    const results: SearchResult[] = [];
    const nameRule = source.ruleSearchName || '';
    const authorRule = source.ruleSearchAuthor || '';
    const coverRule = source.ruleSearchCover || '';
    const noteUrlRule = source.ruleSearchNoteUrl || '';

    for (let idx = 0; idx < items.length; idx++) {
      const item = items[idx];
      if (!item) continue;

      // 提取字段
      let name = '';
      if (nameRule) {
        name = parser.extractAttr(item, nameRule);
      }

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
      let author = '';
      if (authorRule) {
        author = parser.extractAttr(item, authorRule);
      }

      // 封面
      let coverUrl = '';
      if (coverRule) {
        coverUrl = parser.extractAttr(item, coverRule);
      }
      if (!coverUrl) {
        // 取第一个图片
        const imgs = parser.querySelectorAll(item, 'img');
        if (imgs.length > 0) {
          coverUrl = parser.getAttr(imgs[0], 'src') || parser.getAttr(imgs[0], 'data-src') || '';
        }
      }

      // 详情页 URL
      let noteUrl = '';
      if (noteUrlRule) {
        noteUrl = parser.extractAttr(item, noteUrlRule);
      }
      if (!noteUrl) {
        const links = parser.querySelectorAll(item, 'a');
        if (links.length > 0) {
          noteUrl = parser.getAttr(links[0], 'href') || '';
        }
      }

      // 相对路径转绝对
      if (noteUrl && !noteUrl.startsWith('http://') && !noteUrl.startsWith('https://')) {
        noteUrl = (baseUrl || '') + (noteUrl.startsWith('/') ? noteUrl : '/' + noteUrl);
      }
      if (coverUrl && !coverUrl.startsWith('http://') && !coverUrl.startsWith('https://') && !coverUrl.startsWith('data:')) {
        coverUrl = (baseUrl || '') + (coverUrl.startsWith('/') ? coverUrl : '/' + coverUrl);
      }

      results.push({
        key: (source.sourceUrl || '') + '|' + noteUrl + '|' + idx,
        name: name, author: author || '',
        coverUrl: coverUrl || '', noteUrl: noteUrl || '',
        origin: source.sourceName || '未知', originUrl: source.sourceUrl || '',
        kind: '', wordCount: '', lastUpdateTime: '', introduce: '', helperMsg: '',
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
        for (const p of ['data', 'list', 'items', 'results', 'books']) {
          const raw = this.getPath(json, p);
          if (Array.isArray(raw)) { list = raw; break; }
        }
      }
    }
    return list.map((item: unknown) => {
      const itemObj = item as Record<string, unknown>;
      const name = this.firstStr(itemObj, source.ruleSearchName, 'novelName', 'name', 'title', 'bookName');
      const author = this.firstStr(itemObj, source.ruleSearchAuthor, 'authorName', 'author');
      const coverUrl = this.firstStr(itemObj, source.ruleSearchCover, 'cover', 'coverUrl', 'cover_url', 'pic', 'img', 'imageUrl', 'imgUrl', 'thumbnail', 'poster', 'sImg');
      let noteUrl = this.firstStr(itemObj, source.ruleSearchNoteUrl, 'noteUrl', 'bookUrl', 'novelId', 'id', 'url');
      if (noteUrl && !noteUrl.startsWith('http')) {
        const pathStr = /^\d+$/.test(noteUrl) ? '/book/' + noteUrl : '/novel/' + noteUrl;
        noteUrl = (baseUrl || '') + pathStr;
      }
      const kind = this.firstStr(itemObj, source.ruleSearchKind || '', 'kind', 'type', 'category');
      const wordCount = this.firstStr(itemObj, source.ruleSearchWordCount || '', 'wordCount', 'wordNum', 'words');
      const introduce = this.firstStr(itemObj, source.ruleSearchIntroduce || '', 'introduce', 'intro', 'summary');
      return {
        key: (source.sourceUrl || '') + '|' + noteUrl,
        name: name || '未知书名', author: author || '', coverUrl: coverUrl || '',
        noteUrl: noteUrl || '', origin: source.sourceName || '未知',
        originUrl: source.sourceUrl || '',
        kind: kind, wordCount: wordCount,
        lastUpdateTime: '', introduce: introduce, helperMsg: '',
        duration: duration, searchTime: Date.now(),
        sourceCount: 1,
        sourceOrigins: source.sourceName ? [source.sourceName] : []
      };
    });
  }

  private getPath(obj: Record<string, unknown>, path: string): unknown {
    if (!path) return undefined;
    const parts = path.split('.');
    let current: unknown = obj;
    for (const part of parts) {
      if (current === null || current === undefined) return undefined;
      const c = current as Record<string, unknown>;
      if (typeof current === 'object' && part in c) { current = c[part]; } else { return undefined; }
    }
    return current;
  }

  private firstStr(item: Record<string, unknown>, ...paths: (string | undefined)[]): string {
    for (const p of paths) {
      if (!p) continue;
      const val = this.getPath(item, p);
      if (typeof val === 'string' && val) return val;
      if (typeof val === 'number') return String(val);
    }
    return '';
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
    const contentParts = RuleParser.parse(html, rules['content'] || '') as string[];
    if (contentParts && Array.isArray(contentParts)) {
      return contentParts.join('\n');
    }
    return this.stripHtml(html);
  }

  private stripHtml(html: string): string {
    return HtmlUtil.stripHtml(html);
  }

  /**
   * 从规则解析目录列表
   */
  private parseTocFromRules(html: string, rules: Record<string, string>): BookSourceChapter[] {
    const tocRule = rules['toc'] || '';
    if (!tocRule) return [];

    const items = RuleParser.parse(html, tocRule) as unknown[];
    if (!items || !Array.isArray(items)) return [];

    const titleRule = rules['tocTitle'] || '';
    const urlItemRule = rules['tocUrlItem'] || '';

    return items.map((item: unknown, index: number): BookSourceChapter => {
      const itemHtml = typeof item === 'string' ? item : JSON.stringify(item);
      return {
        title: (RuleParser.parse(itemHtml, titleRule) as string[])?.[0] || `第${index + 1}章`,
        url: (RuleParser.parse(itemHtml, urlItemRule) as string[])?.[0] || '',
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
