/**
 * RSS 编排服务
 * 对应 Android Rss.kt — 负责获取文章列表和正文内容
 *
 * 整合网络请求、URL 分析、规则解析、默认 XML 解析
 */

import { RSSArticle, RSSSource } from '../../model/RSSSource';
import { parseXML as parseByRule } from './RssParserByRule';
import { JsExpressionEvaluator } from '../source/JsExpressionEvaluator';
import http from '@ohos.net.http';
import { RuleParser } from '../source/RuleParser';

/**
 * 配置的 HTTP 请求超时（毫秒）
 */
const REQUEST_TIMEOUT = 15000;

function createHttpRequest(): http.HttpRequest {
  const req = http.createHttp();
  return req;
}

function destroyHttpRequest(req: http.HttpRequest): void {
  try {
    req.destroy();
  } catch (_e) { /* ignore */ }
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
      Object.assign(headers, customHeaders);
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

  // @js: 或 <js> 表达式 — 执行 JS 获取实际 URL
  if (sortUrl.startsWith('@js:') || sortUrl.startsWith('<js>')) {
    try {
      const jsCode = extractJsCode(sortUrl);
      const result = await JsExpressionEvaluator.evaluate(jsCode, {
        baseUrl: rssSource.sourceUrl,
        source: rssSource as Object,
      });
      if (result && result.trim()) {
        // 可能返回 "name::url" 格式，取第一个 URL
        const parts = result.split(/&&|\n/);
        if (parts.length > 0) {
          const first = parts[0].trim();
          const idx = first.indexOf('::');
          return idx > 0 ? first.substring(idx + 2).trim() : first;
        }
        return result.trim();
      }
    } catch (e) {
      console.error(`[RssService] JS sortUrl 执行失败: ${e}`);
    }
    // 失败时回退到源 URL
    return rssSource.sourceUrl;
  }

  // 多分类::分隔
  if (sortUrl.includes('::')) {
    return sortUrl.split('::')[1].trim();
  }

  return sortUrl;
}

/**
 * 提取 JS 代码 (从 @js: 或 <js>...</js> 格式)
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
 * 拆解多分类 sortUrl，返回 [(分类名, URL)] 列表
 * 支持 @js: / <js> 表达式执行
 */
export async function resolveSortUrls(sourceUrl: string, sortUrl: string | null): Promise<Array<{ name: string; url: string }>> {
  if (!sortUrl || sortUrl.trim().length === 0) {
    return [{ name: '', url: sourceUrl }];
  }

  // @js: 或 <js> 表达式 — 执行 JS 获取分类列表
  if (sortUrl.startsWith('@js:') || sortUrl.startsWith('<js>')) {
    try {
      const jsCode = extractJsCode(sortUrl);
      const result = await JsExpressionEvaluator.evaluate(jsCode, {
        baseUrl: sourceUrl,
      });
      if (result && result.trim()) {
        return parseSortResult(result, sourceUrl);
      }
    } catch (e) {
      console.error(`[RssService] JS sortUrl 执行失败: ${e}`);
    }
    // 失败时回退
    return [{ name: '', url: sourceUrl }];
  }

  return parseSortResult(sortUrl, sourceUrl);
}

/**
 * 解析分类结果字符串 "分类名::url&&分类2::url2" 为数组
 */
function parseSortResult(input: string, baseUrl: string): Array<{ name: string; url: string }> {
  const separator = /(?:&&|\n)+/;
  const parts = input.split(separator);
  const results: Array<{ name: string; url: string }> = [];

  for (const part of parts) {
    const t = part.trim();
    if (!t) continue;
    const idx = t.indexOf('::');
    if (idx > 0) {
      const name = t.substring(0, idx).trim();
      let url = t.substring(idx + 2).trim();
      if (url && !url.startsWith('http') && !url.startsWith('{{')) {
        url = getAbsoluteURL(baseUrl, url);
      }
      results.push({ name, url });
    } else {
      results.push({ name: t, url: getAbsoluteURL(baseUrl, t) });
    }
  }

  if (results.length === 0) {
    return [{ name: '', url: baseUrl }];
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
  page: number,
  searchKey: string | null = null
): Promise<[RSSArticle[], string | null]> {
  const actualUrl = await resolveSortUrl(rssSource);
  const url = sortUrl || actualUrl;

  console.info(`[RssService] fetchArticles: ${url}, sortName: ${sortName}`);

  // 构建请求
  const req = createHttpRequest();
  try {
    const response = await req.request(url, {
      method: http.RequestMethod.GET,
      header: buildHeaders(rssSource),
      connectTimeout: REQUEST_TIMEOUT,
      readTimeout: REQUEST_TIMEOUT,
      expectDataType: http.HttpDataType.STRING,
    });

    const body = response.result as string;
    if (!body) {
      throw new Error(`Empty response from ${url}`);
    }

    // 使用规则解析
    const headerObj = response.header as Record<string, string>;
    const locationUrl: string = (headerObj && headerObj['location']) ? headerObj['location'] : url;
    return parseByRule(sortName, url, locationUrl, body, rssSource);
  } catch (e: unknown) {
    const msg = (e instanceof Error) ? e.message : String(e);
    console.error(`[RssService] fetchArticles 失败: ${msg}`);
    throw e;
  } finally {
    destroyHttpRequest(req);
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

  console.info(`[RssService] fetchContent: ${targetUrl}`);

  if (!ruleContent || ruleContent.trim().length === 0) {
    // 无正文规则则直接返回链接，由 WebView 加载
    return targetUrl;
  }

  const req = createHttpRequest();
  try {
    const response = await req.request(targetUrl, {
      method: http.RequestMethod.GET,
      header: buildHeaders(rssSource),
      connectTimeout: REQUEST_TIMEOUT,
      readTimeout: REQUEST_TIMEOUT,
      expectDataType: http.HttpDataType.STRING,
    });

    const body = response.result as string;
    if (!body) {
      throw new Error(`Empty response from ${targetUrl}`);
    }

    // 使用规则提取正文
    const content = RuleParser.parse(body, ruleContent);
    if (typeof content === 'string' && content) {
      return content;
    }
    if (Array.isArray(content) && content.length > 0 && typeof content[0] === 'string') {
      return content[0];
    }
    return body;
  } catch (e: unknown) {
    const msg = (e instanceof Error) ? e.message : String(e);
    console.error(`[RssService] fetchContent 失败: ${msg}`);
    // 失败时返回原始链接，由 WebView 兜底
    return targetUrl;
  } finally {
    destroyHttpRequest(req);
  }
}

/**
 * 绝对 URL 转换
 */
export function getAbsoluteURL(base: string, relative: string): string {
  if (!relative) return base;
  if (/^https?:\/\//i.test(relative)) return relative;
  if (relative.startsWith('//')) return `https:${relative}`;
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
  return `${base}/${relative}`;
}
