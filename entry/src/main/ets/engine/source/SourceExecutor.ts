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

function getBaseUrl(rawUrl: string): string {
  if (!rawUrl) return '';
  return rawUrl.replace(/##.*$/, '').replace(/\/+$/, '');
}

function buildUrl(template: string, keyword: string, page: number, baseUrl: string): string {
  const encoded = encodeURIComponent(keyword);
  let url = template
    .replace(/\{\{key\}\}/g, encoded)
    .replace(/\{\{keyword\}\}/g, encoded)
    .replace(/\{\{page\}\}/g, String(page))
    .replace(/\{\{pageNum\}\}/g, String(page + 1));
  // 移除剩余未处理的 {{}} JS 表达式
  url = url.replace(/\{\{[^}]*\}\}/g, '');
  const pageGroupMatch = url.match(/<([^<>]+)>/);
  if (pageGroupMatch) {
    const items = pageGroupMatch[1].split(',');
    const idx = Math.min(page - 1, items.length - 1);
    url = url.replace(pageGroupMatch[0], items[idx].trim());
  }
  // 相对路径处理
  if (!url.startsWith('http://') && !url.startsWith('https://') && baseUrl) {
    const base = baseUrl.replace(/\/+$/, '');
    url = base + (url.startsWith('/') ? url : '/' + url);
  }
  return url;
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

    /** 将新一批结果增量合并到持久 Map 中 */
    function incrementMerge(newResults: SearchResult[]): void {
      for (const r of newResults) {
        const key = getBookMergeKey(r.name, r.author);
        const existing = mergedMap.get(key);
        if (existing) {
          // ★ 创建新对象而非原地修改，确保 ArkUI ForEach 检测到引用变化
          //    参考 legado-with-MD3 的 upsertBooks 模式
          const merged: SearchResult = {
            key: existing.key,
            name: existing.name,
            author: existing.author,
            coverUrl: existing.coverUrl || r.coverUrl,
            noteUrl: existing.noteUrl || r.noteUrl,
            origin: existing.origin,      // 保留第一个源的显示名
            originUrl: existing.originUrl,
            kind: existing.kind || r.kind,
            wordCount: existing.wordCount || r.wordCount,
            lastUpdateTime: existing.lastUpdateTime || r.lastUpdateTime,
            introduce: (r.introduce || '').length > (existing.introduce || '').length
              ? r.introduce : existing.introduce,
            helperMsg: existing.helperMsg || r.helperMsg,
            duration: existing.duration,
            searchTime: existing.searchTime,
            sourceCount: existing.sourceCount,
            // 拷贝一份新数组，避免原地修改
            sourceOrigins: [...existing.sourceOrigins],
          };
          // ★ 用 originUrl（书源 URL，永远唯一）做去重判断
          //    origin（书源名称）可能为空导致多个源均为 '未知'
          if (r.originUrl && !merged.sourceOrigins.some(s => s.startsWith('__url@' + r.originUrl))) {
            // 存 URL 标记用于后续去重
            merged.sourceOrigins.push('__url@' + r.originUrl);
            // 存可读的书源名（用于 Toast 展示）
            if (r.origin) {
              merged.sourceOrigins.push(r.origin);
            }
            merged.sourceCount = merged.sourceOrigins.filter(s => !s.startsWith('__url@')).length;
          }
          // 用新对象替换 Map 中的旧对象
          mergedMap.set(key, merged);
          if (merged.sourceCount > 1) {
            console.info('[SrcEx] Merged source:', r.origin || r.originUrl, 'into', merged.name,
              'count:', merged.sourceCount);
          }
        } else {
          mergedMap.set(key, {
            key: r.key, name: r.name, author: r.author,
            coverUrl: r.coverUrl, noteUrl: r.noteUrl,
            origin: r.origin || '', originUrl: r.originUrl || '',
            kind: r.kind, wordCount: r.wordCount, lastUpdateTime: r.lastUpdateTime,
            introduce: r.introduce, helperMsg: r.helperMsg,
            duration: r.duration, searchTime: r.searchTime,
            sourceCount: 1,
            // 初始条目：存 URL 标记 + 可读名称
            sourceOrigins: (r.originUrl ? ['__url@' + r.originUrl] : []).concat(
              r.origin ? [r.origin] : []
            ),
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
    const url = buildUrl(source.ruleSearchUrl, keyword, 1, baseUrl);

    try {
      const headers: Record<string, string> = {
        'Accept': 'text/html,application/json,*/*',
        'Referer': source.sourceUrl || '',
        ...parseHeader(source.header)
      };
      console.info('[SrcEx] Fetching:', url.substring(0, 80));
      const body = await NetUtil.httpGet(url, headers);
      if (!body) {
        console.warn('[SrcEx] Empty response from', source.sourceName);
        return [];
      }
      console.info('[SrcEx] Got', body.length, 'bytes from', source.sourceName);

      // JSON 直接解析
      try {
        const jsonObj = JSON.parse(body) as Record<string, unknown>;
        const results = this.parseJsonResults(jsonObj, source, baseUrl, 0);
        if (results.length > 0) {
          console.info('[SrcEx] JSON parse OK:', results.length, 'results from', source.sourceName);
          return results;
        }
      } catch (_e) { /* not JSON */ }

      // JS 规则解析（可能 QuickJS 不可用，走直接解析）
      if (source.ruleSearchList) {
        console.info('[SrcEx] Direct HTML parse for', source.sourceName);
        const results = this.parseSearchFromRules(body, {
          'list': source.ruleSearchList,
          'name': source.ruleSearchName || '',
          'author': source.ruleSearchAuthor || '',
          'cover': source.ruleSearchCover || '',
          'noteUrl': source.ruleSearchNoteUrl || ''
        }, source, baseUrl);
        if (results.length > 0) {
          console.info('[SrcEx] Direct parse:', results.length, 'results');
          return results;
        }
      }

      // 兜底：ruleSearchList 为空时尝试简单文本提取
      if (!source.ruleSearchList) {
        console.info('[SrcEx] No ruleSearchList, trying fallback extraction');
        const items = this.extractBookNamesFromHtml(body, baseUrl);
        if (items.length > 0) {
          console.info('[SrcEx] Fallback extracted', items.length, 'items');
          return items.map((item, idx: number): SearchResult => {
            // 尝试从该链接附近提取封面（支持 <img> 和 CSS background-image）
            let coverUrl = '';
            if (item.url) {
              const relPath = item.url.replace(baseUrl, '');
              const pos = body.indexOf(relPath);
              const ctxStart = Math.max(0, (pos >= 0 ? pos : 0) - 800);
              const ctxEnd = Math.min(body.length, (pos >= 0 ? pos : idx * 200) + 1200);
              const ctx = body.substring(ctxStart, ctxEnd);
              // 优先 <img> 标签
              const imgM = ctx.match(/<img[^>]*(?:src|data-src|data-original|data-lazy-src)=["']([^"']+)["'][^>]*>/i);
              coverUrl = imgM ? imgM[1] : '';
              // 其次 CSS background-image（常见于小说站）
              if (!coverUrl) {
                const bgM = ctx.match(/background-image:\s*url\(['"]?([^'")\s]+)['"]?\)/i);
                coverUrl = bgM ? bgM[1] : '';
              }
              if (coverUrl && !coverUrl.startsWith('http')) {
                coverUrl = (baseUrl || '') + (coverUrl.startsWith('/') ? coverUrl : '/' + coverUrl);
              }
            }
            return {
              key: (source.sourceUrl || '') + '|' + idx,
              name: item.name, author: '', coverUrl: coverUrl,
              noteUrl: item.url || url, origin: source.sourceName || '未知',
              originUrl: source.sourceUrl || '',
              kind: '', wordCount: '', lastUpdateTime: '', introduce: '', helperMsg: '',
              duration: 0, searchTime: Date.now(),
              sourceCount: 1,
              sourceOrigins: []
            };
          });
        }
      }

      // 最后尝试：直接用规则解析（不通过 QuickJS，避免大数据传参溢出）
      if (source.ruleSearchList) {
        const results = this.parseSearchFromRules(body, {
          list: source.ruleSearchList,
          name: source.ruleSearchName || '',
          author: source.ruleSearchAuthor || '',
          cover: source.ruleSearchCover || '',
          noteUrl: source.ruleSearchNoteUrl || ''
        }, source, baseUrl);
        if (results.length > 0) {
          console.info('[SrcEx] Rule parse:', results.length, 'results');
          return results;
        }
      }
      console.warn('[SrcEx] No parse method worked for', source.sourceName);
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

  // ============ 规则解析 ============

  private parseSearchFromRules(html: string, rules: Record<string, string>, source: BookSource, baseUrl: string): SearchResult[] {
    const listRule = rules['list'] || '';
    if (!listRule) return [];
    const items = RuleParser.parse(html, listRule) as unknown[];
    if (!items || !Array.isArray(items)) return [];

    return items.map((item: unknown, idx: number): SearchResult => {
      const itemStr = typeof item === 'string' ? item : JSON.stringify(item);
      const name = ((RuleParser.parse(itemStr, rules['name'] || '') as string[])?.[0]) || '';
      const author = ((RuleParser.parse(itemStr, rules['author'] || '') as string[])?.[0]) || '';
      const coverUrl = ((RuleParser.parse(itemStr, rules['cover'] || '') as string[])?.[0])
        || extractFirstImgSrc(itemStr) || '';
      let noteUrl = ((RuleParser.parse(itemStr, rules['noteUrl'] || '') as string[])?.[0]) || '';
      if (noteUrl && !noteUrl.startsWith('http')) {
        noteUrl = (baseUrl || '') + (noteUrl.startsWith('/') ? noteUrl : '/' + noteUrl);
      }
      return {
        key: (source.sourceUrl || '') + '|' + noteUrl + '|' + idx,
        name: name || '未知书名', author: author || '', coverUrl: coverUrl || '',
        noteUrl: noteUrl || '', origin: source.sourceName || '未知',
        originUrl: source.sourceUrl || '',
        kind: '', wordCount: '', lastUpdateTime: '', introduce: '', helperMsg: '',
        duration: 0, searchTime: Date.now(),
      sourceCount: 1,
      sourceOrigins: []
      };
    });
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

    // 判断文本是否像书名（中文书名通常4-20字，不含特殊符号）
    function isBookTitle(text: string): boolean {
      if (text.length < 2 || text.length > 40) return false;
      if (/^(首页|书库|书架|分类|排行|完本|会员|充值|登录|注册|关于|帮助|联系我们|设为首页|收藏本站|RSS|订阅|投稿|我的|个人中心|作者专区|作家专区|手机版|电脑版|客户端|APP下载|返回|上一页|下一页|尾页|跳到页|第.*页|网站地图|友情链接|TAG|标签云|随机|热门|最新|更新|推荐|公告|活动|合作|广告|联系|QQ群|微信|微博|意见反馈|用户协议|隐私政策|免责声明)$/i.test(text)) return false;
      // 书名应当以中文为主
      const cjkCount = (text.match(/[\u4e00-\u9fff]/g) || []).length;
      return cjkCount >= text.length * 0.5;
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
