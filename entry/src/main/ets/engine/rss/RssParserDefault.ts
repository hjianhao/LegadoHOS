/**
 * 默认 RSS/Atom XML 解析器
 * 对应 Android RssParserDefault — 标准 XML Pull Parser
 *
 * 纯 ArkTS 实现，手动状态机解析 XML（无需 XmlPullParser 依赖）
 */

import { RSSArticle } from '../../model/RSSSource';

// --------------- 标签常量 ---------------
const TAG_ITEM = 'item';
const TAG_ENTRY = 'entry';
const TAG_TITLE = 'title';
const TAG_LINK = 'link';
const TAG_DESCRIPTION = 'description';
const TAG_CONTENT_ENCODED = 'content:encoded';
const TAG_CONTENT = 'content';
const TAG_SUMMARY = 'summary';
const TAG_PUB_DATE = 'pubDate';
const TAG_PUBLISHED = 'published';
const TAG_UPDATED = 'updated';
const TAG_MEDIA_THUMBNAIL = 'media:thumbnail';
const TAG_MEDIA_CONTENT = 'media:content';
const TAG_ENCLOSURE = 'enclosure';
const ATTR_URL = 'url';
const ATTR_TYPE = 'type';
const ATTR_HREF = 'href';

/**
 * 解析 RSS/Atom XML 字符串
 * @param sortName  分类名称
 * @param xml       XML 字符串
 * @param sourceUrl 源 URL
 * @returns [文章列表, 错误信息]
 */
export function parseXML(
  sortName: string,
  xml: string,
  sourceUrl: string
): [RSSArticle[], string | null] {
  const articles: RSSArticle[] = [];
  if (!xml || xml.trim().length === 0) {
    return [articles, 'Empty XML content'];
  }

  try {
    console.info('[RssParserDefault] parsing XML, length: ' + xml.length + ', isAtom: ' + (xml.includes('<feed') || xml.includes('xmlns="http://www.w3.org/2005/Atom"')));
    // 诊断：打印前 500 字符，用于判断内容是 HTML 还是 XML
    console.info('[RssParserDefault] content preview (first 500): ' + xml.substring(0, Math.min(500, xml.length)));
    // 简单预清理
    const cleaned = xml.replace(/<!\[CDATA\[/g, '').replace(/\]\]>/g, '');

    // 判断是否为 Atom feed
    const isAtom = cleaned.includes('<feed') || cleaned.includes('xmlns="http://www.w3.org/2005/Atom"');

    if (isAtom) {
      parseAtom(cleaned, sortName, sourceUrl, articles);
    } else {
      parseRSS(cleaned, sortName, sourceUrl, articles);
    }

    // 兜底：如果默认解析没找到文章，且内容看起来像 HTML，尝试提取链接
    if (articles.length === 0) {
      const isHtml = /<(!DOCTYPE|html|head|body|meta|div|span|script|style)\b/i.test(xml);
      if (isHtml) {
        console.info('[RssParserDefault] 未找到 RSS/Atom 条目，内容疑似 HTML，尝试提取链接');
        extractLinksFromHtml(xml, sortName, sourceUrl, articles);
      }
    }

    return [articles, null];
  } catch (e: unknown) {
    const msg = (e instanceof Error) ? e.message : String(e);
    return [articles, `Parse error: ${msg}`];
  }
}

/**
 * 解析标准 RSS 2.0 XML
 */
function parseRSS(xml: string, sortName: string, sourceUrl: string, articles: RSSArticle[]): void {
  // 提取所有 <item>...</item> 块
  const items = extractTags(xml, TAG_ITEM);
  console.info('[RssParserDefault] parseRSS: found ' + items.length + ' items');
  for (const item of items) {
    const article = parseItem(item, sortName, sourceUrl);
    if (article.title) {
      articles.push(article);
    }
  }
}

/**
 * 解析 Atom feed
 */
function parseAtom(xml: string, sortName: string, sourceUrl: string, articles: RSSArticle[]): void {
  const entries = extractTags(xml, TAG_ENTRY);
  for (const entry of entries) {
    const title = extractTagContent(entry, TAG_TITLE) || '';
    const link = extractAtomLink(entry) || '';
    const pubDate = extractTagContent(entry, TAG_PUBLISHED)
      || extractTagContent(entry, TAG_UPDATED) || null;
    const description = extractTagContent(entry, TAG_CONTENT)
      || extractTagContent(entry, TAG_SUMMARY) || null;
    const image = extractAtomImage(entry) || null;

    articles.push({
      origin: sourceUrl,
      sort: sortName,
      link,
      title,
      order: 0,
      pubDate,
      description,
      content: null,
      image,
      group: '默认分组',
      read: false,
      variable: null,
      type: 0,
      durPos: 0,
    });
  }
}

/**
 * 提取标签内容（简单正则）
 */
function extractTags(xml: string, tag: string): string[] {
  const results: string[] = [];
  // 匹配自闭合标签和完整标签
  const regex = new RegExp(`<${tag}(?:\\s[^>]*?)?>[\\s\\S]*?<\\/${tag}>`, 'gi');
  let match: RegExpExecArray | null;
  // eslint-disable-next-line no-cond-assign
  while ((match = regex.exec(xml)) !== null) {
    results.push(match[0]);
  }
  if (results.length === 0) {
    // 诊断：检查 content 中是否存在该标签（不区分大小写）
    const hasOpenTag = new RegExp(`<${tag}[\\s>]`, 'i').test(xml);
    const hasCloseTag = new RegExp(`<\\/${tag}>`, 'i').test(xml);
    console.info(`[RssParserDefault] extractTags<${tag}>: found 0. hasOpenTag=${hasOpenTag}, hasCloseTag=${hasCloseTag}`);
  }
  return results;
}

function extractTagContent(xml: string, tag: string): string | null {
  const regex = new RegExp(`<${tag}(?:\\s[^>]*?)?>([\\s\\S]*?)<\\/${tag}>`, 'i');
  const match = regex.exec(xml);
  if (match) {
    return match[1].trim();
  }
  // 自闭合
  const selfClose = new RegExp(`<${tag}(?:\\s[^>]*?)?\\s*\\/>`, 'i');
  if (selfClose.test(xml)) {
    return '';
  }
  return null;
}

function extractAttribute(xml: string, tag: string, attr: string): string | null {
  const regex = new RegExp(`<${tag}[^>]*?\\s${attr}\\s*=\\s*["']([^"']+)["']`, 'i');
  const match = regex.exec(xml);
  return match ? match[1] : null;
}

function extractAtomLink(entryXml: string): string | null {
  // 找 <link href="..." /> 或 <link>...</link>
  const links = extractTags(entryXml, TAG_LINK);
  for (const linkXml of links) {
    const href = extractAttribute(linkXml, TAG_LINK, ATTR_HREF);
    if (href) return href;
    // 链接内容
    const content = linkXml.replace(/<\/?link[^>]*>/g, '').trim();
    if (content) return content;
  }
  // 自闭合带 href
  const href = extractAttribute(entryXml, TAG_LINK, ATTR_HREF);
  if (href) return href;
  // <link>content</link>
  const content = extractTagContent(entryXml, TAG_LINK);
  return content;
}

function extractAtomImage(entryXml: string): string | null {
  // Atom 中没有标准的缩略图，找 media:content 或 media:thumbnail
  const mediaUrl = extractAttribute(entryXml, TAG_MEDIA_CONTENT, ATTR_URL);
  if (mediaUrl) return mediaUrl;
  return extractAttribute(entryXml, TAG_MEDIA_THUMBNAIL, ATTR_URL);
}

/**
 * 解析单个 <item> 块
 */
function parseItem(itemXml: string, sortName: string, sourceUrl: string): RSSArticle {
  const article: RSSArticle = {
    origin: sourceUrl,
    sort: sortName,
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

  article.title = extractTagContent(itemXml, TAG_TITLE) || '';
  article.link = extractTagContent(itemXml, TAG_LINK) || '';
  article.pubDate = extractTagContent(itemXml, TAG_PUB_DATE) || null;
  article.description = extractTagContent(itemXml, TAG_DESCRIPTION) || null;

  // content:encoded
  const contentEncoded = extractTagContent(itemXml, TAG_CONTENT_ENCODED);
  if (contentEncoded) {
    article.content = contentEncoded;
  }

  // 图片提取
  article.image = extractAttribute(itemXml, TAG_MEDIA_THUMBNAIL, ATTR_URL)
    || extractEnclosureImage(itemXml)
    || (article.description ? getFirstImageUrl(article.description) : null)
    || (article.content ? getFirstImageUrl(article.content) : null);

  return article;
}

function extractEnclosureImage(itemXml: string): string | null {
  const type = extractAttribute(itemXml, TAG_ENCLOSURE, ATTR_TYPE);
  if (type && type.startsWith('image/')) {
    return extractAttribute(itemXml, TAG_ENCLOSURE, ATTR_URL);
  }
  return null;
}

/**
 * 从 HTML 中提取首张图片 URL
 */
function getFirstImageUrl(html: string): string | null {
  const imgRegex = /<img[^>]+src\s*=\s*["']([^"']+)["']/i;
  const match = imgRegex.exec(html);
  if (match) {
    return match[1].trim();
  }
  // 也匹配 <img src='...'> 
  const imgRegex2 = /<img[^>]+src\s*=\s*'([^']+)'/i;
  const match2 = imgRegex2.exec(html);
  return match2 ? match2[1].trim() : null;
}

/**
 * HTML 兜底：当内容不是 RSS/Atom XML 而是 HTML 页面时，
 * 提取页面中的链接作为文章列表
 */
function extractLinksFromHtml(html: string, sortName: string, sourceUrl: string, articles: RSSArticle[]): void {
  // 提取 title 标签内容作为页面标题
  const titleMatch = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i);
  const pageTitle = titleMatch ? titleMatch[1].trim() : '';

  // 提取所有的 <a href="...">text</a>
  const linkRegex = /<a\s[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi;
  const seen = new Set<string>();
  let linkMatch: RegExpExecArray | null;

  while ((linkMatch = linkRegex.exec(html)) !== null) {
    let href = linkMatch[1].trim();
    const text = linkMatch[2].replace(/<[^>]+>/g, '').trim();

    // 跳过空文本、纯空白、javascript:、#锚点
    if (!text || text.length === 0 || text.length > 200) continue;
    if (href.startsWith('javascript:') || href === '#' || href.startsWith('#')) continue;

    // 相对 URL 转绝对 URL
    if (!href.startsWith('http')) {
      if (href.startsWith('//')) {
        href = 'https:' + href;
      } else if (href.startsWith('/')) {
        try {
          const protocolEnd = sourceUrl.indexOf('://');
          const protocol = protocolEnd > 0 ? sourceUrl.substring(0, protocolEnd + 3) : 'https://';
          const rest = protocolEnd > 0 ? sourceUrl.substring(protocolEnd + 3) : sourceUrl;
          const hostEnd = rest.indexOf('/');
          const host = hostEnd > 0 ? rest.substring(0, hostEnd) : rest;
          href = protocol + host + href;
        } catch (_e) {
          continue;
        }
      } else {
        // 相对路径，拼接
        const lastSlash = sourceUrl.lastIndexOf('/');
        if (lastSlash > 8) {
          href = sourceUrl.substring(0, lastSlash + 1) + href;
        } else {
          href = sourceUrl + '/' + href;
        }
      }
    }

    // 去重
    if (seen.has(href)) continue;
    seen.add(href);

    articles.push({
      origin: sourceUrl,
      sort: sortName,
      link: href,
      title: text,
      order: 0,
      pubDate: null,
      description: null,
      content: null,
      image: null,
      group: pageTitle || '默认分组',
      read: false,
      variable: null,
      type: 0,
      durPos: 0,
    });
  }

  console.info('[RssParserDefault] extractLinksFromHtml: found ' + articles.length + ' links');
}
