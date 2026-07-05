/**
 * RSS 编排服务
 * 对应 Android Rss.kt — 负责获取文章列表和正文内容
 *
 * 整合网络请求、URL 分析、规则解析、默认 XML 解析
 */

import { RSSArticle, RSSSource } from '../../model/RSSSource';
import { parseXML as parseByRule } from './RssParserByRule';
import { JsExpressionEvaluator, JsEvalContext } from '../source/JsExpressionEvaluator';
import { NetUtil } from '../../util/NetUtil';
import { RuleParser } from '../source/RuleParser';

/**
 * 配置的 HTTP 请求超时（毫秒）
 */
const REQUEST_TIMEOUT = 15000;

/**
 * 分类 URL 条目
 */
export interface SortUrlEntry {
  name: string;
  url: string;
}

/**
 * 获取请求头
 */
function buildHeaders(source: RSSSource | null): Record<string, string> {
  const headers: Record<string, string> = {
    'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36',
  };
  if (source && source.header) {
    try {
      const customHeaders = JSON.parse(source.header) as Record<string, string>;
      const keys = Object.keys(customHeaders);
      for (let i = 0; i < keys.length; i++) {
        const k = keys[i];
        headers[k] = customHeaders[k];
      }
    } catch (_e) { /* not valid JSON */ }
  }
  return headers;
}

/**
 * 解析 sortUrl，支持 JS 表达式
 * 返回实际的请求 URL
 */
async function resolveSortUrl(rssSource: RSSSource): Promise<string> {
  let sortUrl = rssSource.sortUrl || rssSource.sourceUrl;

  if (sortUrl.startsWith('@js:') || sortUrl.startsWith('<js>')) {
    try {
      const jsCode = extractJsCode(sortUrl);
      const ctx: JsEvalContext = { baseUrl: rssSource.sourceUrl, source: rssSource as Object };
      const result = await JsExpressionEvaluator.evaluate(jsCode, ctx);
      if (result && result.trim()) {
        const parts = result.split(/&&|\n/);
        if (parts.length > 0) {
          const first = parts[0].trim();
          const idx = first.indexOf('::');
          return idx > 0 ? first.substring(idx + 2).trim() : first;
        }
        return result.trim();
      }
    } catch (e) {
      console.error(`[RssService] JS sortUrl 执行失败: ${JSON.stringify(e)}`);
    }
    return rssSource.sourceUrl;
  }

  if (sortUrl.includes('::')) {
    const rawUrl = sortUrl.split('::')[1].trim();
    // data: URIs are not real HTTP URLs — use sourceUrl+loginUrl for fetch,
    // and pass the raw data URI to JS rules via rssSource.sortUrl
    if (rawUrl.startsWith('data:')) {
      const loginPath = rssSource.loginUrl || '';
      const base = rssSource.sourceUrl || '';
      if (loginPath && base) {
        const httpUrl = base.replace(/\/+$/, '') + '/' + loginPath.replace(/^\/+/, '');
        console.info('[RssService] data URI detected, using HTTP URL: ' + httpUrl);
        return httpUrl;
      }
    }
    return rawUrl;
  }

  return sortUrl;
}

/**
 * 提取 JS 代码
 */
function extractJsCode(sortUrl: string): string {
  if (sortUrl.startsWith('@js:')) {
    return sortUrl.substring(4);
  }
  if (sortUrl.startsWith('<js>')) {
    const end = sortUrl.lastIndexOf('<');
    if (end > 4) {
      return sortUrl.substring(4, end);
    }
    return sortUrl.substring(4);
  }
  return sortUrl;
}

/**
 * 拆解多分类 sortUrl
 */
export async function resolveSortUrls(sourceUrl: string, sortUrl: string | null): Promise<SortUrlEntry[]> {
  if (!sortUrl || sortUrl.trim().length === 0) {
    const entry: SortUrlEntry = { name: '', url: sourceUrl };
    const result: SortUrlEntry[] = [];
    result.push(entry);
    return result;
  }

  if (sortUrl.startsWith('@js:') || sortUrl.startsWith('<js>')) {
    try {
      const jsCode = extractJsCode(sortUrl);
      const ctx: JsEvalContext = { baseUrl: sourceUrl };
      const result = await JsExpressionEvaluator.evaluate(jsCode, ctx);
      if (result && result.trim()) {
        return parseSortResult(result, sourceUrl);
      }
    } catch (e) {
      console.error(`[RssService] JS sortUrl 执行失败: ${JSON.stringify(e)}`);
    }
    const entry: SortUrlEntry = { name: '', url: sourceUrl };
    const result: SortUrlEntry[] = [];
    result.push(entry);
    return result;
  }

  return parseSortResult(sortUrl, sourceUrl);
}

/**
 * 解析分类结果字符串
 */
function parseSortResult(input: string, baseUrl: string): SortUrlEntry[] {
  const separator = /(?:&&|\n)+/;
  const parts = input.split(separator);
  const results: SortUrlEntry[] = [];

  for (const part of parts) {
    const t = part.trim();
    if (!t) continue;
    const idx = t.indexOf('::');
    if (idx > 0) {
      const name = t.substring(0, idx).trim();
      let url = t.substring(idx + 2).trim();
      if (url && !url.startsWith('http') && !url.startsWith('{{')) {
        // 判断是否为关键字（简短、无斜杠、无扩展名）而非路径
        const isKeyword = url.length <= 10 && !url.includes('/') && !url.includes('.');
        if (!isKeyword) {
          url = getAbsoluteURL(baseUrl, url);
        }
        // 关键字保留原样，由 JS 规则处理
      }
      const entry: SortUrlEntry = { name: name, url: url };
      results.push(entry);
    } else {
      const isKeyword = t.length <= 10 && !t.includes('/') && !t.includes('.');
      const entry: SortUrlEntry = { name: t, url: isKeyword ? baseUrl : getAbsoluteURL(baseUrl, t) };
      results.push(entry);
    }
  }

  if (results.length === 0) {
    const entry: SortUrlEntry = { name: '', url: baseUrl };
    results.push(entry);
  }

  return results;
}

/**
 * 获取文章列表（使用 sortUrl）
 * @returns [文章列表, 下一页 URL]
 */
export async function fetchArticles(
  sortName: string,
  sortUrl: string,
  rssSource: RSSSource,
  _page?: number,
  _searchKey?: string | null
): Promise<[RSSArticle[], string | null]> {
  let url = sortUrl;
  if (!url) {
    url = await resolveSortUrl(rssSource);
  }

  console.info('[RssService] fetchArticles: ' + url + ', sortName: ' + sortName);

  try {
    const body = await NetUtil.httpGet(url, buildHeaders(rssSource), REQUEST_TIMEOUT);
    if (!body) {
      const err = new Error('Empty response from ' + url);
      console.error('[RssService] fetchArticles 失败: Empty response');
      throw err;
    }

    return parseByRule(sortName, url, url, body, rssSource);
  } catch (e) {
    const msg = (e instanceof Error) ? e.message : String(e);
    console.error('[RssService] fetchArticles 失败: ' + msg);
    const err = new Error(msg);
    throw err;
  }
}

/**
 * 获取文章正文内容
 * @returns 正文 HTML 字符串
 */
export async function fetchContent(
  article: RSSArticle,
  ruleContent: string,
  rssSource: RSSSource
): Promise<string> {
  const targetUrl = article.link;

  console.info('[RssService] fetchContent: ' + targetUrl);

  if (!ruleContent || ruleContent.trim().length === 0) {
    return targetUrl;
  }

  try {
    const body = await NetUtil.httpGet(targetUrl, buildHeaders(rssSource), REQUEST_TIMEOUT);
    if (!body) {
      console.error('[RssService] fetchContent 失败: Empty response');
      return targetUrl;
    }

    const parsed: string = RuleParser.parse(body, ruleContent) as string;
    if (parsed && parsed.length > 0) {
      return parsed;
    }
    return body;
  } catch (e) {
    const msg = (e instanceof Error) ? e.message : String(e);
    console.error('[RssService] fetchContent 失败: ' + msg);
    return targetUrl;
  }
}

/**
 * 绝对 URL 转换
 */
export function getAbsoluteURL(base: string, relative: string): string {
  if (!relative) return base;
  if (/^https?:\/\//i.test(relative)) return relative;
  if (relative.startsWith('//')) return 'https:' + relative;
  if (relative.startsWith('/')) {
    try {
      const protocolEnd = base.indexOf('://');
      const protocol = protocolEnd > 0 ? base.substring(0, protocolEnd + 3) : 'https://';
      const rest = protocolEnd > 0 ? base.substring(protocolEnd + 3) : base;
      const hostEnd = rest.indexOf('/');
      const host = hostEnd > 0 ? rest.substring(0, hostEnd) : rest;
      return protocol + host + relative;
    } catch (_e) {
      return relative;
    }
  }
  const lastSlash = base.lastIndexOf('/');
  if (lastSlash > 8) {
    return base.substring(0, lastSlash + 1) + relative;
  }
  return base + '/' + relative;
}
