/**
 * 规则驱动的 RSS 解析器
 * 对应 Android RssParserByRule — 使用 CSS/JSONPath/XPath + JS 选择器规则
 *
 * 复用现有 RuleParser (静态方法) 引擎进行元素提取
 */

import { RSSArticle, RSSSource } from '../../model/RSSSource';
import { parseXML as defaultParseXML } from './RssParserDefault';
import { RuleParser } from '../source/RuleParser';

/**
 * 使用规则解析 RSS XML/HTML
 *
 * @param sortName   分类名称
 * @param sortUrl    分类 URL（当前请求的 URL）
 * @param redirectUrl 重定向后 URL
 * @param body       响应体 HTML/XML
 * @param rssSource  RSS 源
 * @returns [文章列表, 下一页 URL]
 */
export async function parseXML(
  sortName: string,
  sortUrl: string,
  redirectUrl: string,
  body: string | null,
  rssSource: RSSSource
): Promise<[RSSArticle[], string | null]> {
  if (!body || body.trim().length === 0) {
    throw new Error(`获取内容失败: ${rssSource.sourceUrl}`);
  }

  const sourceUrl = rssSource.sourceUrl;
  const ruleArticles = rssSource.ruleArticles;

  if (!ruleArticles || ruleArticles.trim().length === 0) {
    // 无规则 → 默认标准 RSS XML 解析
    console.info(`[RssParserByRule] ruleArticles 为空, 使用默认解析`);
    return defaultParseXML(sortName, body, sourceUrl);
  }

  // 使用规则解析
  const articleList: RSSArticle[] = [];
  let nextUrl: string | null = null;
  let reverse = false;
  let articlesRule = ruleArticles;

  if (articlesRule.startsWith('-')) {
    reverse = true;
    articlesRule = articlesRule.substring(1);
  }

  try {
    // 获取文章列表元素
    let collection: any[] = [];
    const parsedList = RuleParser.parse(body, articlesRule);
    if (Array.isArray(parsedList)) {
      collection = parsedList;
    } else if (typeof parsedList === 'string') {
      // 单字符串当做一个元素
      if (parsedList) collection = [parsedList];
    }
    console.info(`[RssParserByRule] 列表大小: ${collection.length}`);

    // 获取下一页 URL
    if (rssSource.ruleNextPage) {
      const nextRule = rssSource.ruleNextPage.trim().toUpperCase();
      if (nextRule === 'PAGE') {
        nextUrl = sortUrl;
      } else {
        const nextStr = RuleParser.parse(body, rssSource.ruleNextPage);
        if (nextStr && typeof nextStr === 'string' && nextStr.length > 0) {
          nextUrl = getAbsoluteURL(sortUrl, nextStr);
        }
      }
    }

    // 逐项提取
    for (let i = 0; i < collection.length; i++) {
      const item = collection[i];
      const article = extractArticle(
        sourceUrl, item,
        rssSource.ruleTitle,
        rssSource.rulePubDate,
        rssSource.ruleDescription,
        rssSource.ruleImage,
        rssSource.ruleLink,
        i === 0
      );
      if (article && article.title) {
        article.sort = sortName;
        article.origin = sourceUrl;
        articleList.push(article);
      }
    }

    if (reverse) {
      articleList.reverse();
    }

    return [articleList, nextUrl];
  } catch (e: unknown) {
    const msg = (e instanceof Error) ? e.message : String(e);
    console.error(`[RssParserByRule] 解析失败: ${msg}`);
    // 退回到默认解析
    return defaultParseXML(sortName, body, sourceUrl);
  }
}

/**
 * 从单个元素提取文章字段
 */
function extractArticle(
  sourceUrl: string,
  item: any,
  ruleTitle: string | null,
  rulePubDate: string | null,
  ruleDescription: string | null,
  ruleImage: string | null,
  ruleLink: string | null,
  log: boolean
): RSSArticle | null {
  const article: RSSArticle = {
    origin: sourceUrl,
    sort: '',
    link: '',
    title: '',
    order: 0,
    pubDate: null,
    description: null,
    content: null,
    image: null,
    group: '默认分组',
    read: false,
    variable: null,
    type: 0,
    durPos: 0,
  };

  try {
    const itemStr = typeof item === 'string' ? item : JSON.stringify(item);

    if (ruleTitle) {
      const result = RuleParser.parse(itemStr, ruleTitle);
      article.title = Array.isArray(result) ? (result[0] || '') : (result || '');
    }

    if (rulePubDate) {
      const result = RuleParser.parse(itemStr, rulePubDate);
      article.pubDate = Array.isArray(result) ? (result[0] || null) : (result || null);
    }

    if (ruleDescription) {
      const result = RuleParser.parse(itemStr, ruleDescription);
      article.description = Array.isArray(result) ? (result[0] || null) : (result || null);
    }

    if (ruleImage) {
      const result = RuleParser.parse(itemStr, ruleImage);
      article.image = Array.isArray(result) ? (result[0] || null) : (result || null);
    }

    if (ruleLink) {
      const result = RuleParser.parse(itemStr, ruleLink);
      const link = Array.isArray(result) ? (result[0] || '') : (result || '');
      article.link = getAbsoluteURL(sourceUrl, link);
    }

    if (!article.title) {
      return null;
    }

    return article;
  } catch (e) {
    if (log) {
      console.error(`[RssParserByRule] extractItem 失败: ${e}`);
    }
    return null;
  }
}

/**
 * 将相对 URL 转换为绝对 URL
 */
function getAbsoluteURL(base: string, relative: string): string {
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
  // 相对路径: base 去掉最后一段
  const lastSlash = base.lastIndexOf('/');
  if (lastSlash > 8) {
    return base.substring(0, lastSlash + 1) + relative;
  }
  return `${base}/${relative}`;
}
