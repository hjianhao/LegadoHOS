/**
 * RSS 规则解析器（支持 CSS/XPath/JSONPath/JS 规则）
 *
 * 核心流程（对标 Android AnalyzeRule）：
 * 1. 列表获取：JS 规则 → QuickJS 执行；CSS/XPath → RuleParser.parse
 * 2. 字段提取：逐个字段判断规则类型，JS→QuickJS，CSS→RuleParser
 * 3. 失败兜底 → 默认 RSS/Atom XML 解析
 */

import { RSSArticle, RSSSource } from '../../model/RSSSource';
import { parseXML as defaultParseXML } from './RssParserDefault';
import { RuleParser } from '../source/RuleParser';
import { globalScriptEngine } from '../source/ScriptEngine';
import { getPolyfillScript } from '../source/ScriptApi';

let engineReady = false;

async function ensureEngine(): Promise<void> {
  if (engineReady) return;
  try {
    await globalScriptEngine.initialize();
    const polyfill = getPolyfillScript();
    await globalScriptEngine.executeScript(polyfill);
    engineReady = true;
    console.info('[RssParserByRule] QuickJS engine initialized');
  } catch (e) {
    console.error('[RssParserByRule] engine init failed:', e);
  }
}

export async function parseXML(
  sortName: string,
  sortUrl: string,
  _redirectUrl: string,
  body: string | null,
  rssSource: RSSSource
): Promise<[RSSArticle[], string | null]> {
  if (!body || body.trim().length === 0) {
    throw new Error('获取内容失败: ' + rssSource.sourceUrl);
  }

  const ruleArticles = rssSource.ruleArticles;
  if (!ruleArticles || ruleArticles.trim().length === 0) {
    console.info('[RssParserByRule] 无规则，使用默认解析');
    return defaultParseXML(sortName, body, rssSource.sourceUrl);
  }

  // 判断列表规则类型
  const isJsRule = ruleArticles.trim().startsWith('<js') || ruleArticles.trim().startsWith('@js');

  if (isJsRule) {
    return parseArticlesByJs(sortName, sortUrl, body, rssSource);
  }

  return parseArticlesByCss(sortName, sortUrl, body, rssSource);
}

// ========== JS 列表规则 ==========

async function parseArticlesByJs(
  sortName: string,
  sortUrl: string,
  body: string,
  rssSource: RSSSource
): Promise<[RSSArticle[], string | null]> {
  console.info('[RssParserByRule] JS规则解析');

  try {
    await ensureEngine();

    const jsCode = extractJsCode(rssSource.ruleArticles);
    const escapedBody = JSON.stringify(body);

    // 构建包装脚本：注入 body + RSS源配置，执行 articles 规则
    const wrapperScript = `
var __body = ${escapedBody};
var __sourceUrl = ${JSON.stringify(rssSource.sourceUrl)};
var __sortUrl = ${JSON.stringify(sortUrl)};

var __titleRule = ${JSON.stringify(rssSource.ruleTitle || '')};
var __linkRule = ${JSON.stringify(rssSource.ruleLink || '')};
var __pubDateRule = ${JSON.stringify(rssSource.rulePubDate || '')};
var __descRule = ${JSON.stringify(rssSource.ruleDescription || '')};
var __imageRule = ${JSON.stringify(rssSource.ruleImage || '')};

// ---- 结果对象构造函数 ----
function Result(name, author, kind) {
  this.name = name; this.author = author; this.kind = kind;
}
Result.prototype = {
  result: '',
  html() { return __body; },
  _result: '',
  _title: '', _link: '', _pubDate: '', _description: '', _image: '',
};

// ---- 执行 articles 规则 ----
function __execArticles() {
  var result = new Result('', '', 'rss');
  ${jsCode}
  return result._result;
}

__execArticles();
`;

    const articlesResult = await globalScriptEngine.executeScript(wrapperScript);
    console.info('[RssParserByRule] JS articles result length: ' + (articlesResult ? articlesResult.length : 0));

    if (!articlesResult || articlesResult === 'null' || articlesResult === 'undefined') {
      console.info('[RssParserByRule] JS结果为空，使用默认解析');
      return defaultParseXML(sortName, body, rssSource.sourceUrl);
    }

    // 尝试解析结果（可能是 JSON 数组、HTML 片段列表、或纯文本）
    let items: string[] = [];

    try {
      const parsed: Object = JSON.parse(articlesResult) as Object;
      if (Array.isArray(parsed)) {
        items = (parsed as Object[]).map((v: Object): string => String(v));
      } else if (typeof parsed === 'object' && parsed !== null) {
        items = [JSON.stringify(parsed)];
      }
    } catch (_e) {
      // 不是 JSON —— 可能是以分隔符分隔的列表，或单个文本
      const trimmed = articlesResult.trim();
      if (trimmed.indexOf('##') > 0) {
        items = trimmed.split('##').filter((s: string): boolean => s.trim().length > 0);
      } else if (trimmed.indexOf('\n') > 0) {
        items = trimmed.split('\n').filter((s: string): boolean => s.trim().length > 0);
      } else {
        items = [trimmed];
      }
    }

    console.info('[RssParserByRule] JS items count: ' + items.length);

    const articleList: RSSArticle[] = [];
    for (let idx = 0; idx < items.length; idx++) {
      const itemHtml = items[idx];

      // 字段提取：先尝试从 item 中解析（可能是 JSON 对象），否则用 RuleParser 从 HTML 中提取
      const title = evalField(itemHtml, rssSource.ruleTitle, rssSource.sourceUrl, 'title');
      if (!title) continue;

      const article: RSSArticle = {
        origin: rssSource.sourceUrl,
        sort: sortName,
        title: title,
        link: '',
        pubDate: null,
        description: null,
        content: null,
        image: null,
        order: 0,
        group: '默认分组',
        read: false,
        variable: null,
        type: 0,
        durPos: 0,
      };

      article.link = evalField(itemHtml, rssSource.ruleLink, rssSource.sourceUrl, 'link');
      article.pubDate = evalField(itemHtml, rssSource.rulePubDate, rssSource.sourceUrl, 'pubDate') || null;
      article.description = evalField(itemHtml, rssSource.ruleDescription, rssSource.sourceUrl, 'description') || null;
      article.image = evalField(itemHtml, rssSource.ruleImage, rssSource.sourceUrl, 'image') || null;

      if (article.link && !article.link.startsWith('http')) {
        article.link = getAbsoluteURL(sortUrl, article.link);
      }

      articleList.push(article);
    }

    // 下一页
    let nextUrl: string | null = null;
    if (rssSource.ruleNextPage) {
      nextUrl = resolveNextPage(body, sortUrl, rssSource.ruleNextPage);
    }

    console.info('[RssParserByRule] JS parsed ' + articleList.length + ' articles');
    return [articleList, nextUrl];

  } catch (e) {
    const msg = (e instanceof Error) ? e.message : String(e);
    console.error('[RssParserByRule] JS error: ' + msg);
    return defaultParseXML(sortName, body, rssSource.sourceUrl);
  }
}

// ========== CSS/JSONPath/XPath 列表规则 ==========

async function parseArticlesByCss(
  sortName: string,
  sortUrl: string,
  body: string,
  rssSource: RSSSource
): Promise<[RSSArticle[], string | null]> {
  const articleList: RSSArticle[] = [];
  let ruleArticles = rssSource.ruleArticles;
  let reverse = false;

  if (ruleArticles.startsWith('-')) {
    reverse = true;
    ruleArticles = ruleArticles.substring(1);
  }

  try {
    const result: Object = RuleParser.parse(body, ruleArticles) as Object;
    let collection: string[] = [];
    if (Array.isArray(result)) {
      collection = (result as Object[]).map((v: Object): string => String(v));
    } else if (typeof result === 'string' && result) {
      collection = [result as string];
    }
    console.info('[RssParserByRule] CSS列表大小: ' + collection.length);

    for (let i = 0; i < collection.length; i++) {
      const itemHtml = collection[i];

      const title = evalField(itemHtml, rssSource.ruleTitle, rssSource.sourceUrl, 'title');
      if (!title) continue;

      const article: RSSArticle = {
        origin: rssSource.sourceUrl,
        sort: sortName,
        title: title,
        link: '',
        pubDate: null,
        description: null,
        content: null,
        image: null,
        order: 0,
        group: '默认分组',
        read: false,
        variable: null,
        type: 0,
        durPos: 0,
      };

      article.link = evalField(itemHtml, rssSource.ruleLink, rssSource.sourceUrl, 'link');
      article.pubDate = evalField(itemHtml, rssSource.rulePubDate, rssSource.sourceUrl, 'pubDate') || null;
      article.description = evalField(itemHtml, rssSource.ruleDescription, rssSource.sourceUrl, 'description') || null;
      article.image = evalField(itemHtml, rssSource.ruleImage, rssSource.sourceUrl, 'image') || null;

      if (article.link && !article.link.startsWith('http')) {
        article.link = getAbsoluteURL(sortUrl, article.link);
      }

      articleList.push(article);
    }

    if (reverse) articleList.reverse();

    let nextUrl: string | null = null;
    if (rssSource.ruleNextPage) {
      nextUrl = resolveNextPage(body, sortUrl, rssSource.ruleNextPage);
    }

    return [articleList, nextUrl];

  } catch (e) {
    const msg = (e instanceof Error) ? e.message : String(e);
    console.error('[RssParserByRule] CSS解析失败: ' + msg);
    return defaultParseXML(sortName, body, rssSource.sourceUrl);
  }
}

// ========== 字段评估（统一入口） ==========

function evalField(html: string, rule: string | null, _sourceUrl: string, fieldName: string): string {
  if (!rule || rule.trim().length === 0) {
    return tryItemField(html, fieldName);
  }

  const trimmed = rule.trim();

  if (trimmed.startsWith('@js:') || trimmed.startsWith('<js')) {
    return evalJsField(html, trimmed, fieldName);
  }

  // CSS / JSONPath / XPath / 正则 — 用 RuleParser
  const result: Object = RuleParser.parse(html, trimmed) as Object;
  if (Array.isArray(result)) {
    const arr = result as Object[];
    return arr.length > 0 ? String(arr[0] || '') : '';
  }
  return String(result || '');
}

function tryItemField(html: string, fieldName: string): string {
  // 尝试作为 JSON 对象解析，直接取属性
  try {
    const obj: Record<string, Object> = JSON.parse(html) as Record<string, Object>;
    if (typeof obj[fieldName] === 'string') return obj[fieldName] as string;
  } catch (_e) {
    // 不是 JSON
  }

  // 尝试常见属性名
  if (fieldName === 'link' || fieldName === 'url') {
    // 尝试从 HTML 中提取 href
    const hrefResult: Object = RuleParser.parse(html, 'a[href]') as Object;
    if (typeof hrefResult === 'string' && hrefResult) return hrefResult as string;
  }

  if (fieldName === 'title') {
    // 作为兜底，返回 HTML 的前200个字符
    const text = html.replace(/<[^>]+>/g, '').trim();
    if (text.length > 0 && text.length < 200) return text;
  }

  return '';
}

function evalJsField(html: string, jsRule: string, _fieldName: string): string {
  if (!engineReady) return '';

  const jsCode = extractJsCode(jsRule);
  if (!jsCode) return '';

  try {
    const escapedHtml = JSON.stringify(html);
    const script = `
var __item = ${escapedHtml};
(function() {
  ${jsCode}
})();
`;
    const result = globalScriptEngine.evaluateJsSync(script);
    if (!result || result === 'null' || result === 'undefined' || result === '""') return '';
    // 去掉可能的外层引号
    return result.replace(/^"/, '').replace(/"$/, '');
  } catch (_e) {
    return '';
  }
}

// ========== 辅助函数 ==========

function extractJsCode(rule: string): string {
  if (!rule) return '';
  const trimmed = rule.trim();
  if (trimmed.startsWith('@js:')) return trimmed.substring(4).trim();
  if (trimmed.startsWith('<js>')) {
    const end = trimmed.lastIndexOf('<');
    if (end > 4) return trimmed.substring(4, end).trim();
    return trimmed.substring(4).trim();
  }
  return trimmed;
}

function resolveNextPage(body: string, sortUrl: string, nextPageRule: string): string | null {
  if (!nextPageRule) return null;
  const nextRule = nextPageRule.trim().toUpperCase();
  if (nextRule === 'PAGE') return sortUrl;

  if (nextPageRule.trim().startsWith('@js:') || nextPageRule.trim().startsWith('<js')) {
    const jsCode = extractJsCode(nextPageRule);
    if (!jsCode) return null;
    try {
      const escapedBody = JSON.stringify(body);
      const script = `var __body = ${escapedBody}; (function(){ ${jsCode} })();`;
      const result = globalScriptEngine.evaluateJsSync(script);
      if (result && result.length > 0) {
        return getAbsoluteURL(sortUrl, result.replace(/^"/, '').replace(/"$/, ''));
      }
    } catch (_e) {
      // ignore
    }
    return null;
  }

  const nextStr: Object = RuleParser.parse(body, nextPageRule) as Object;
  if (nextStr && typeof nextStr === 'string' && nextStr.length > 0) {
    return getAbsoluteURL(sortUrl, nextStr as string);
  }
  return null;
}

function getAbsoluteURL(base: string, relative: string): string {
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
    } catch (_e) { return relative; }
  }
  const lastSlash = base.lastIndexOf('/');
  if (lastSlash > 8) return base.substring(0, lastSlash + 1) + relative;
  return base + '/' + relative;
}
