/**
 * 搜索引擎 — 参照 Legado 原版实现
 *
 * 支持：
 * - URL 模板：{{key}} / {{page}} / {{pageNum}} / <1,2,3> 翻页组
 * - 结果解析：JSON 路径 / CSS 选择器 / 混合
 * - 自动字段映射：兼容多种常见字段名
 */

import { BookSource } from '../../model/BookSource';
import { toJsRegexReplacement } from '../source/RuleAnalyzer';
import { SearchResult } from '../../model/SearchResult';
import { NetUtil } from '../../util/NetUtil';

// ============ 简单 HTML 书名提取（兜底方案） ============

/**
 * 在 HTML 中搜索可能的搜索结果（书名 + 封面 + 作者）
 * 当书源没有 ruleSearchList 时作为兜底
 */
function extractFallbackResults(html: string, sourceUrl: string, baseUrl: string): SearchResult[] {
  const results: SearchResult[] = [];
  const seen = new Set<string>();

  // 过滤导航词
  const navWords = /^(首页|书库|书架|分类|排行|完本|会员|充值|搜索|登录|注册|关于|帮助|联系我们|设为首页|收藏本站|RSS|订阅|投稿|我的|个人中心|作者专区|作家专区|手机版|电脑版|客户端|APP下载|返回|上一页|下一页|尾页|跳到页|第.*页)$/i;

  // 尝试从 <a> 标签提取：书名 + 附近封面图
  const linkRegex = /<a[^>]*href=["']([^"']*)["'][^>]*>([^<]{2,50})<\/a>/gi;
  let match: RegExpExecArray | null;
  while ((match = linkRegex.exec(html)) !== null) {
    const text = match[2].trim();
    const href = match[1];

    if (text.length < 2 || text.length > 30 || text.includes('<') || navWords.test(text) || seen.has(text)) continue;

    // 尝试从该链接附近提取封面（扩大搜索范围）
    const contextBefore = html.substring(Math.max(0, match.index - 800), match.index);
    const contextAfter = html.substring(match.index, Math.min(html.length, match.index + 400));
    const context = contextBefore + contextAfter;
    let coverMatch = context.match(/<img[^>]*(?:src|data-src|data-original|data-lazy-src)=["']([^"']+)["'][^>]*>/i);
    let coverUrl = coverMatch ? coverMatch[1] : '';
    if (!coverUrl) {
      const bgMatch = context.match(/background-image:\s*url\(["']?([^'")\s]+)["']?\)/i);
      coverUrl = bgMatch ? bgMatch[1] : '';
    }
    if (coverUrl && !coverUrl.startsWith('http')) {
      coverUrl = (baseUrl || '') + (coverUrl.startsWith('/') ? coverUrl : '/' + coverUrl);
    }

    seen.add(text);

    // 尝试从附近提取作者
    const afterLink = html.substring(match.index, Math.min(html.length, match.index + 300));
    const authorRegex = /(?:作者|作\s*者)[：:\s]*([^\s<]{2,10})/i;
    const authorMatch = afterLink.match(authorRegex);
    const author = authorMatch ? authorMatch[1].trim() : '';

    let noteUrl = href;
    if (noteUrl && !noteUrl.startsWith('http')) {
      noteUrl = (baseUrl || '') + (noteUrl.startsWith('/') ? noteUrl : '/' + noteUrl);
    }

    results.push({
      key: (sourceUrl || '') + '|' + noteUrl,
      name: text,
      author: author,
      coverUrl: coverUrl,
      noteUrl: noteUrl,
      origin: '',
      originUrl: sourceUrl || '',
      kind: '', wordCount: '', lastUpdateTime: '', introduce: '', helperMsg: '',
      duration: 0, searchTime: Date.now(),
    sourceCount: 1,
    sourceOrigins: []
    });
  }

  // 如果没有提取到结果，尝试从 <h3>, <h2>, <h4> 标签提取纯书名
  if (results.length === 0) {
    const headerRegex = /<h[2-4][^>]*>([^<]{2,50})<\/h[2-4]>/gi;
    while ((match = headerRegex.exec(html)) !== null) {
      const text = match[1].trim();
      if (text.length >= 2 && text.length <= 30 && !seen.has(text)) {
        seen.add(text);
        results.push({
          key: (sourceUrl || '') + '|' + seen.size,
          name: text,
          author: '', coverUrl: '',
          noteUrl: '',
          origin: '',
          originUrl: sourceUrl || '',
          kind: '', wordCount: '', lastUpdateTime: '', introduce: '', helperMsg: '',
          duration: 0, searchTime: Date.now(),
          sourceCount: 1,
          sourceOrigins: []
        });
      }
    }
  }

  return results.slice(0, 30);
}

// ============ URL 模板处理（参照 Legado AnalyzeUrl） ============

function getBaseUrl(rawUrl: string): string {
  if (!rawUrl) return '';
  return rawUrl.replace(/##.*$/, '').replace(/\/+$/, '');
}

/**
 * 构建搜索 URL — 参照 Legado AnalyzeUrl
 * 支持：
 *   {{key}} / {{keyword}} → URL-encoded 关键词
 *   {{page}} / {{pageNum}} → 页码
 *   <1,2,3> → 翻页组（动态渲染）
 */
function buildSearchUrl(template: string, keyword: string, page: number, baseUrl: string): string {
  const encoded = encodeURIComponent(keyword);
  let url = template
    .replace(/\{\{key\}\}/g, encoded)
    .replace(/\{\{keyword\}\}/g, encoded)
    .replace(/\{\{page\}\}/g, String(page))
    .replace(/\{\{pageNum\}\}/g, String(page + 1));

  // 处理翻页组 <1,2,3> — 取第 page 个
  const pageGroupMatch = url.match(/<([^<>]+)>/);
  if (pageGroupMatch) {
    const items = pageGroupMatch[1].split(',');
    const idx = Math.min(page - 1, items.length - 1);
    url = url.replace(pageGroupMatch[0], items[idx].trim());
  }

  // 移除剩余未处理的 {{}} JS 表达式（某些书源含复杂表达式）
  url = url.replace(/\{\{[^}]*\}\}/g, '');

  // 处理相对路径
  if (url.startsWith('/') && baseUrl) {
    url = baseUrl.replace(/\/+$/, '') + url;
  }

  return url;
}

// ============ 通用内容解析（参照 Legado AnalyzeRule） ============

/**
 * JSON 路径取值 — 支持 a.b.c 数组索引
 */
function getJsonPath(obj: unknown, path: string): unknown {
  if (!path || obj === null || obj === undefined) return undefined;
  // 去掉 $. 前缀
  let clean = path.replace(/^\$\.?/, '');
  if (!clean) return obj;
  const parts = clean.split('.');
  let current: unknown = obj;
  for (const part of parts) {
    if (current === null || current === undefined) return undefined;
    // 匹配 key[N] 格式（如 booklist[0]）
    const arrIdx = part.match(/^(\w+)\[(\d+)\]$/);
    if (arrIdx) {
      const arr = (current as Record<string, unknown>)[arrIdx[1]];
      if (Array.isArray(arr)) current = arr[parseInt(arrIdx[2])];
      else return undefined;
      continue;
    }
    // 匹配 key[*] 格式（如 booklist[*]）—— 返回整个数组
    const arrWild = part.match(/^(\w+)\[\*\]$/);
    if (arrWild) {
      const arr = (current as Record<string, unknown>)[arrWild[1]];
      if (Array.isArray(arr)) { current = arr; }
      else return undefined;
      continue;
    }
    // 匹配裸 [*] 格式——如果当前是数组则返回
    if (part === '[*]') {
      if (Array.isArray(current)) return current;
      return undefined;
    }
    // 普通 key 查找
    if (typeof current === 'object' && part in (current as Record<string, unknown>)) {
      current = (current as Record<string, unknown>)[part];
    } else if (Array.isArray(current)) {
      const idx = parseInt(part);
      if (!isNaN(idx)) current = current[idx];
      else return undefined;
    } else {
      return undefined;
    }
  }
  return current;
}

function jsonStrVal(obj: unknown, path: string): string {
  const val = getJsonPath(obj, path);
  if (typeof val === 'string') return val;
  if (typeof val === 'number') return String(val);
  return '';
}

/**
 * 尝试多个取值路径，返回第一个非空值
 */
function jsonFirstVal(obj: unknown, ...paths: string[]): string {
  for (const p of paths) {
    if (!p) continue;
    const v = jsonStrVal(obj, p);
    if (v) return v;
  }
  return '';
}

// ============ 搜索结果解析（参照 Legado BookList.analyzeBookList） ============

/**
 * 获取 JSON 中的列表（自动尝试常见路径）
 */
function extractJsonList(json: unknown, ruleList: string | undefined): unknown[] {
  let list: unknown[] = [];

  if (ruleList) {
    const raw = getJsonPath(json, ruleList);
    if (Array.isArray(raw)) list = raw;
    else if (raw !== null && raw !== undefined) list = [raw];
  }

  if (list.length === 0) {
    // 自动兼容常见列表路径
    if (Array.isArray(json)) {
      list = json;
    } else {
      for (const p of ['data', 'list', 'items', 'results', 'books', 'novels', 'data.list', 'data.items', 'data.records', 'data.books', 'data.novels', 'data.bookList', 'data.booklist', 'data.content', 'data.result']) {
        const raw = getJsonPath(json, p);
        if (Array.isArray(raw)) { list = raw; break; }
      }
    }
  }

  return list;
}

/**
 * 解析 JSON 搜索结果
 */
function parseJsonSearch(json: unknown, source: BookSource, baseUrl: string, duration: number): SearchResult[] {
  const list = extractJsonList(json, source.ruleSearchList);
  if (list.length === 0) return [];

  return list.map((item: unknown): SearchResult | null => {
    // 字段自动映射 — 兼容多种命名方式
    const name = jsonFirstVal(item,
      source.ruleSearchName,
      'novelName', 'name', 'title', 'bookName', 'book_name',
      'name', 'novel_name', 'bookName', 'book_name'
    );
    const author = jsonFirstVal(item,
      source.ruleSearchAuthor,
      'authorName', 'author', 'author_name'
    );
    const coverUrl = jsonFirstVal(item,
      source.ruleSearchCover,
      'cover', 'coverUrl', 'cover_url', 'pic', 'img', 'imageUrl', 'imgUrl', 'thumbnail', 'poster', 'sImg'
    );
    let noteUrl = jsonFirstVal(item,
      source.ruleSearchNoteUrl,
      'noteUrl', 'bookUrl', 'book_url', 'novelId', 'id', 'url', 'link', 'href'
    );
    const kind = jsonFirstVal(item,
      source.ruleSearchKind,
      'kind', 'type', 'category', 'className', 'class'
    );
    const wordCount = jsonFirstVal(item,
      source.ruleSearchWordCount,
      'wordCount', 'wordNum', 'word_count', 'words'
    );
    const introduce = jsonFirstVal(item,
      source.ruleSearchIntroduce,
      'introduce', 'intro', 'desc', 'description', 'summary'
    );

    if (!name) return null;

    // 拼接完整详情页 URL
    if (noteUrl && !noteUrl.startsWith('http')) {
      // 如果 noteUrl 是 ID（不含 URL 特征），尝试构造完整 URL
      const tocTemplate = source.ruleTocUrl || '';
      if (tocTemplate) {
        // 使用书源的目录 URL 模板
        noteUrl = tocTemplate.replace(/\{\{novelId\}\}/g, noteUrl)
          .replace(/\{\{id\}\}/g, noteUrl)
          .replace(/\{\{key\}\}/g, noteUrl);
        if (!noteUrl.startsWith('http')) {
          noteUrl = (baseUrl || '') + (noteUrl.startsWith('/') ? noteUrl : '/' + noteUrl);
        }
      } else {
        // 无模板时尝试常见路径模式
        const isNumeric = /^\d+$/.test(noteUrl);
        const path = isNumeric ? '/book/' + noteUrl : '/novel/' + noteUrl;
        noteUrl = (baseUrl || '') + path;
      }
    }

    return {
      key: (source.sourceUrl || '') + '|' + noteUrl,
      name: name,
      author: author || '',
      coverUrl: coverUrl || '',
      noteUrl: noteUrl || '',
      origin: source.sourceName || '未知',
      originUrl: source.sourceUrl || '',
      kind: kind,
      wordCount: wordCount,
      lastUpdateTime: '',
      introduce: introduce,
      helperMsg: '',
      duration: duration,
      searchTime: Date.now(),
    sourceCount: 1,
    sourceOrigins: []
    };
  }).filter((r): r is SearchResult => r !== null);
}

/**
 * 按 CSS 类名查找标签内容（支持 .className@attr 选择器）
 */
function getContentByClass(html: string, className: string, attr: string | null, index: number): string {
  // 转义特殊正则字符
  const escName = className.replace(/[-[\]{}()*+?.,\\^$|#\s]/g, '\\$&');
  // 查找包含 class="...className..." 的任意标签
  const classRegex = new RegExp(
    "<(\\w+)[^>]*\\bclass\\s*=\\s*[\"'][^\"']*\\b" + escName + "\\b[^\"']*[\"'][^>]*>",
    'gi'
  );
  let count = 0;
  let match: RegExpExecArray | null;
  while ((match = classRegex.exec(html)) !== null) {
    if (count === index) {
      const fullTag = match[0];
      const tagName = match[1];

      if (attr) {
        const attrMatch = fullTag.match(new RegExp(attr + "\\s*=\\s*[\"']([^\"']*)[\"']", 'i'));
        return attrMatch ? attrMatch[1].trim() : '';
      }

      // 返回文本内容
      const closeRegex = new RegExp('</' + tagName + '>', 'gi');
      const pos = match.index + fullTag.length;
      closeRegex.lastIndex = 0;
      const closeMatch = closeRegex.exec(html.substring(pos));
      if (closeMatch) {
        const content = html.substring(pos, pos + closeMatch.index);
        return content.replace(/<[^>]+>/g, '').trim();
      }
      return '';
    }
    count++;
  }
  return '';
}

/**
 * 简易 HTML 标签解析
 */
function getTagContent(html: string, tag: string, attr: string | null, index: number): string {
  const tagRegex = new RegExp('<' + tag + '[^>]*>', 'gi');
  const closeRegex = new RegExp('</' + tag + '>', 'gi');

  let count = 0;
  let pos = 0;

  // 找到第 index+1 个标签
  let match: RegExpExecArray | null;
  while ((match = tagRegex.exec(html)) !== null) {
    if (count === index) {
      pos = match.index + match[0].length;

      if (attr) {
        // 返回属性值
        const attrMatch = match[0].match(new RegExp(attr + '\\s*=\\s*["\']([^"\']*)["\']', 'i'));
        return attrMatch ? attrMatch[1].trim() : '';
      }

      // 返回文本内容
      const closeMatch = closeRegex.exec(html.substring(pos));
      if (closeMatch) {
        const content = html.substring(pos, pos + closeMatch.index);
        return content.replace(/<[^>]+>/g, '').trim();
      }
      return '';
    }
    count++;
  }
  return '';
}

function extractHtmlField(html: string, selector: string): string {
  if (!selector || !html) return '';

  // 处理 ## 替换
  let cleanSel = selector;
  let replacePattern = '';
  const repIdx = selector.indexOf('##');
  if (repIdx > 0) {
    cleanSel = selector.substring(0, repIdx);
    replacePattern = selector.substring(repIdx + 2);
  }

  // 解析选择器: tag.N@attr | tag@attr | tag@text | .class@attr | .class.N@attr
  let tag = '';
  let idx = 0;
  let target = '';
  let isClassSel = false;

  const classMatch = cleanSel.match(/^\.([\w-]+)(?:\.(\d+))?@(\w+)$/);
  if (classMatch) {
    // CSS 类名选择器 .className@attr
    isClassSel = true;
    tag = classMatch[1];
    idx = parseInt(classMatch[2] || '0');
    target = classMatch[3];
  } else {
    const tagMatch = cleanSel.match(/^(\w[\w-]*)(?:\.(\d+))?@(\w+)$/);
    if (!tagMatch) return '';
    tag = tagMatch[1];
    idx = parseInt(tagMatch[2] || '0');
    target = tagMatch[3];
  }

  const attr = target === 'text' ? null : target;
  let val: string;
  if (isClassSel) {
    // 按类名查找: 找到第 idx+1 个包含该 class 的标签
    val = getContentByClass(html, tag, attr, idx);
  } else {
    val = getTagContent(html, tag, attr, idx);
  }

  // 应用替换
  if (replacePattern && val) {
    const parts = replacePattern.split('##');
    if (parts.length >= 2) {
      try { val = val.replace(new RegExp(parts[0], 'g'), toJsRegexReplacement(parts.slice(1).join('##'))); }
      catch (_e) { /* ignore */ }
    }
  }

  return val;
}

/**
 * 按 CSS 类名分割 HTML
 */
function splitHtmlByClass(html: string, className: string): string[] {
  const cls = className.replace(/^\./, '');
  const fragments: string[] = [];

  // 简易分割：找 class="...className..."
  let startIdx = 0;
  const regex = new RegExp('<([a-z]+)[^>]*class\\s*=\\s*["\'][^"\']*' + cls + '[^"\']*["\'][^>]*>', 'gi');
  let m: RegExpExecArray | null;

  // 收集所有匹配的标签
  const openTags: Array<{ tag: string; start: number; end: number }> = [];
  while ((m = regex.exec(html)) !== null) {
    openTags.push({ tag: m[1], start: m.index, end: regex.lastIndex });
  }

  if (openTags.length === 0) return fragments;

  for (let i = 0; i < openTags.length; i++) {
    const item = openTags[i];
    const closeTag = '</' + item.tag + '>';
    const nextTag = i + 1 < openTags.length ? openTags[i + 1] : null;
    const searchEnd = nextTag ? nextTag.start : html.length;
    const closeIdx = html.indexOf(closeTag, item.end);
    if (closeIdx >= 0 && closeIdx < searchEnd) {
      fragments.push(html.substring(item.end, closeIdx));
    }
  }

  return fragments;
}

function parseHtmlSearch(body: string, source: BookSource, baseUrl: string, duration: number): SearchResult[] {
  const bookListRule = source.ruleSearchList || '';
  if (!bookListRule) return [];

  const items = splitHtmlByClass(body, bookListRule);
  if (items.length === 0) return [];

  return items.map((itemHtml: string): SearchResult | null => {
    const name = extractHtmlField(itemHtml, source.ruleSearchName || 'h3@text')
      || extractHtmlField(itemHtml, 'a@text');

    if (!name) return null;

    const author = extractHtmlField(itemHtml, source.ruleSearchAuthor || '')
      || extractHtmlField(itemHtml, '.author@text');
    let coverUrl = extractHtmlField(itemHtml, source.ruleSearchCover || '')
      || extractHtmlField(itemHtml, 'img@src');
    if (!coverUrl) {
      const lazyM = itemHtml.match(/<img[^>]*(?:data-src|data-original|data-lazy-src)=["']([^"']+)["'][^>]*>/i);
      coverUrl = lazyM ? lazyM[1] : '';
    }
    let noteUrl = extractHtmlField(itemHtml, source.ruleSearchNoteUrl || '')
      || extractHtmlField(itemHtml, 'a@href');

    if (noteUrl && !noteUrl.startsWith('http')) {
      noteUrl = (baseUrl || '') + (noteUrl.startsWith('/') ? noteUrl : '/' + noteUrl);
    }

    const introduce = extractHtmlField(itemHtml, source.ruleSearchIntroduce || '');

    return {
      key: (source.sourceUrl || '') + '|' + noteUrl,
      name: name,
      author: author || '',
      coverUrl: coverUrl || '',
      noteUrl: noteUrl || '',
      origin: source.sourceName || '未知',
      originUrl: source.sourceUrl || '',
      kind: '',
      wordCount: '',
      lastUpdateTime: '',
      introduce: introduce,
      helperMsg: '',
      duration: duration,
      searchTime: Date.now(),
    sourceCount: 1,
    sourceOrigins: []
    };
  }).filter((r): r is SearchResult => r !== null);
}

// ============ 单书源搜索（参照 Legado WebBook.searchBookAwait） ============

async function searchSource(
  source: BookSource,
  keyword: string,
  page: number
): Promise<SearchResult[]> {
  if (!source.enabled || !source.ruleSearchUrl) return [];

  const baseUrl = getBaseUrl(source.sourceUrl);
  const url = buildSearchUrl(source.ruleSearchUrl, keyword, page, baseUrl);

  // 解析书源自定义请求头
  let customHeaders: Record<string, string> = {};
  if (source.header) {
    try {
      customHeaders = JSON.parse(source.header) as Record<string, string>;
    } catch (_e) {
      console.warn('[Search] Invalid header JSON for', source.sourceName);
    }
  }

  try {
    const startTime = Date.now();
    const body = await NetUtil.httpGet(url, {
      'Accept': 'text/html,application/json,*/*',
      'Referer': source.sourceUrl || '',
      ...customHeaders
    });
    const duration = Date.now() - startTime;

    if (!body) return [];

    // 参照 Legado 流程：先尝试 JSON，再尝试 HTML
    let json: unknown = null;
    try { json = JSON.parse(body); } catch (_e) { /* 非 JSON */ }

    if (json) {
      const results = parseJsonSearch(json, source, baseUrl, duration);
      if (results.length > 0) {
        console.info('[Search] JSON results from', source.sourceName, ':', results.length);
        return results;
      }
    }

    // HTML 解析
    if (source.ruleSearchList) {
      const results = parseHtmlSearch(body, source, baseUrl, duration);
      if (results.length > 0) {
        console.info('[Search] HTML results from', source.sourceName, ':', results.length);
        return results;
      }
    }

    // 兜底：从 HTML 提取可能的书名
    console.info('[Search] Trying fallback extraction for', source.sourceName);
    const fallbackResults = extractFallbackResults(body, source.sourceUrl || '', baseUrl);
    if (fallbackResults.length > 0) {
      console.info('[Search] Fallback extracted', fallbackResults.length, 'results');
      // 补充 origin 字段
      return fallbackResults.map((r) => {
        r.origin = source.sourceName || '未知';
        return r;
      });
    }

    console.warn('[Search] No results from', source.sourceName);
    return [];
  } catch (err) {
    console.warn('[Search] Error for', source.sourceName, ':', (err as Error).message);
    return [];
  }
}

// ============ 搜索入口（参照 Legado SearchBooksUseCase） ============

export async function searchBooks(
  sources: BookSource[],
  keyword: string,
  page: number = 1,
  timeoutMs: number = 15000
): Promise<SearchResult[]> {
  if (!keyword.trim() || sources.length === 0) return [];

  const promises = sources.map((src) => searchSource(src, keyword.trim(), page));

  const timeoutPromise = new Promise<SearchResult[]>((resolve) => {
    setTimeout(() => resolve([]), timeoutMs);
  });

  const results = await Promise.race([
    Promise.all(promises).then((nested) => nested.flat()),
    timeoutPromise
  ]);

  return results;
}
