/** qysg 书源定义和返回值的轻量编解码。 */
import {
  BookSource,
  BookSourceFormat,
  BookSourceType,
  isQysgInlineHtml,
  qysgHtmlUrlCandidates,
  isQysgSourceObject,
} from '../../model/BookSource';
import { NetUtil } from '../../util/NetUtil';

export interface QysgSourceDefinition {
  sourceUrl: string;
  sourceName: string;
  html: string;
  /** 外链 html 实际地址，用作 loadData 的 baseUrl；内嵌 html 时为空。 */
  htmlBaseUrl?: string;
  enabled: boolean;
  enabledExplore: boolean;
  group: string;
  author: string;
  help: string;
  login: Object;
}

export interface QysgExploreItem {
  title: string;
  url: string;
  js: string;
  type: number;
  width: number;
}

function asString(value: unknown): string {
  if (value === null || value === undefined) return '';
  return String(value);
}

function parseObject(raw: string): Record<string, Object> {
  try {
    const parsed: unknown = JSON.parse(raw);
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      return parsed as Record<string, Object>;
    }
  } catch (_e) { /* 由调用方报告格式错误 */ }
  return {};
}

interface QysgRemoteHtmlCacheEntry {
  html: string;
  baseUrl: string;
  expiresAt: number;
}

const QYSG_REMOTE_HTML_CACHE_TTL_MS = 10 * 60 * 1000;
const qysgRemoteHtmlCache: Map<string, QysgRemoteHtmlCacheEntry> = new Map();

/** 从已持久化的 BookSource 中读取 qysg HTML。 */
export function decodeQysgSource(source: BookSource): QysgSourceDefinition {
  if (source.sourceFormat !== BookSourceFormat.QYSG) {
    throw new Error('不是 qysg 书源');
  }
  const raw = parseObject(source.rawJson || '');
  const html = asString(raw['html']);
  if (!html.trim()) throw new Error('qysg 书源缺少 html 运行时代码');
  return {
    sourceUrl: source.sourceUrl.replace(/##.*$/, '').trim().replace(/\/+$/, ''),
    sourceName: source.sourceName,
    html: html,
    htmlBaseUrl: '',
    enabled: source.enabled,
    enabledExplore: source.enabledExplore,
    group: source.group,
    author: asString(raw['author']),
    help: asString(raw['help']),
    login: raw['login'] || {},
  };
}

/**
 * 解析轻悦时光书源中的外链 HTML。书源站为节省合集体积，会把完整脚本放在
 * html 字段列出的一个或多个镜像地址中；运行时必须先下载脚本，再交给 ArkWeb
 * 加载，否则 WebView 只会把“http://...”这段文本当成页面内容。
 */
export async function resolveQysgSource(source: BookSource): Promise<QysgSourceDefinition> {
  const definition = decodeQysgSource(source);
  const candidates = qysgHtmlUrlCandidates(definition.html);
  if (candidates.length === 0) return definition;

  const cacheKey = definition.sourceUrl + '\n' + candidates.join('\n');
  const cached = qysgRemoteHtmlCache.get(cacheKey);
  if (cached && cached.expiresAt > Date.now()) {
    return {
      ...definition,
      html: cached.html,
      htmlBaseUrl: cached.baseUrl,
    };
  }

  const requestHeaders: Record<string, string> = {
    'Accept': 'text/html,application/xhtml+xml,*/*',
    'Referer': definition.sourceUrl,
  };
  const errors: string[] = [];
  for (const candidate of candidates) {
    try {
      const html = await NetUtil.httpGet(candidate, requestHeaders, 20000);
      if (!isQysgInlineHtml(html)) {
        errors.push(candidate + ': 返回内容不是可执行 qysg HTML');
        continue;
      }
      qysgRemoteHtmlCache.set(cacheKey, {
        html: html,
        baseUrl: candidate,
        expiresAt: Date.now() + QYSG_REMOTE_HTML_CACHE_TTL_MS,
      });
      console.info('[QysgSourceCodec] resolved external html source=' + source.sourceName +
        ' url=' + candidate + ' bytes=' + html.length.toString());
      return {
        ...definition,
        html: html,
        htmlBaseUrl: candidate,
      };
    } catch (error) {
      errors.push(candidate + ': ' + ((error as Error).message || String(error)));
    }
  }
  throw new Error('qysg 外链 HTML 下载失败（' + errors.join('; ').substring(0, 300) + '）');
}

/** qysg 函数返回值可能是 JSON 字符串，也可能是已经序列化的数组。 */
export function decodeQysgValue(raw: string): unknown {
  let value: unknown = raw;
  for (let i = 0; i < 3; i++) {
    if (typeof value !== 'string') return value;
    const text = value.trim();
    if (!text) return '';
    try {
      value = JSON.parse(text);
    } catch (_e) {
      return value;
    }
  }
  return value;
}

export function decodeQysgArray(raw: string): Object[] {
  const value = decodeQysgValue(raw);
  if (Array.isArray(value)) return value as Object[];
  if (value && typeof value === 'object') {
    const object = value as Record<string, Object>;
    for (const key of ['data', 'list', 'items', 'results']) {
      if (Array.isArray(object[key])) return object[key] as Object[];
    }
  }
  return [];
}

export function decodeQysgObject(raw: string): Record<string, Object> {
  const value = decodeQysgValue(raw);
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    return value as Record<string, Object>;
  }
  return {};
}

/** 用于导入预览和单元测试，避免必须先构造 BookSource。 */
export function isQysgJson(value: Object): boolean {
  return isQysgSourceObject(value);
}

export function qysgContentType(value: unknown, fallback: number = BookSourceType.TEXT): number {
  const type = typeof value === 'number' ? value : Number(value);
  if (type === 0 || type === 1 || type === 2 || type === 3) return type;
  if (fallback === 1 || fallback === 2 || fallback === 3) return fallback;
  return BookSourceType.TEXT;
}

export function qysgAbsoluteUrl(base: string, value: string): string {
  const url = (value || '').trim();
  if (!url) return '';
  if (/^https?:\/\//i.test(url) || /^data:/i.test(url)) return url;
  if (url.startsWith('//')) {
    const protocol = base.match(/^([a-z]+:)/i)?.[1] || 'https:';
    return protocol + url;
  }
  const cleanBase = (base || '').replace(/\/+$/, '');
  if (url.startsWith('/')) {
    const match = cleanBase.match(/^(https?:\/\/[^/]+)/i);
    return (match ? match[1] : cleanBase) + url;
  }
  // 仅有协议分隔符的源地址（如 https://example.com）不能把相对路径
  // 拼成 https://relative；有路径时按当前目录解析，无路径时回到站点根目录。
  const originMatch = cleanBase.match(/^(https?:\/\/[^/]+)(\/.*)?$/i);
  if (originMatch) {
    const path = originMatch[2] || '/';
    const slash = path.lastIndexOf('/');
    return originMatch[1] + path.substring(0, slash + 1) + url;
  }
  const slash = cleanBase.lastIndexOf('/');
  return (slash >= 0 ? cleanBase.substring(0, slash + 1) : cleanBase + '/') + url;
}

/**
 * 番茄 qysg 源的搜索结果把书籍身份写成 multi-detail API 地址。
 *
 * 该地址只适合查询详情，在详情代理不可用时会返回 HTTP 200 的空响应；
 * 番茄官网的目录接口则仍可直接按 bookId 返回完整目录。详情函数失败时
 * mapQysgInfo 会把请求地址原样作为 tocUrl，因此在进入 chapter 前统一把
 * 这个身份地址恢复为官方目录地址。仅处理 fqnovel 的 multi-detail URL，
 * 其它 qysg 源和普通书籍 URL 保持不变。
 */
export function normalizeQysgTomatoTocUrl(value: string): string {
  const raw = (value || '').trim();
  const hostMatch = raw.match(/^https?:\/\/([^/?#]+)/i);
  if (!raw || !hostMatch || !/(?:^|\.)fqnovel\.com(?::\d+)?$/i.test(hostMatch[1]) ||
    !/\/reading\/bookapi\/multi-detail\//i.test(raw)) return raw;
  const match = raw.match(/[?&]book_id=(\d{10,})/i);
  if (!match) return raw;
  return 'https://fanqienovel.com/api/reader/directory/detail?bookId=' + match[1];
}
