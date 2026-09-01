/** qysg 返回对象到现有领域模型的映射。 */
import { BookType } from '../../model/Book';
import {
  BookSource,
  BookSourceBookInfo,
  BookSourceChapter,
  BookSourceType,
} from '../../model/BookSource';
import { SearchResult } from '../../model/SearchResult';
import {
  qysgAbsoluteUrl,
  qysgContentType,
  decodeQysgArray,
  decodeQysgObject,
  decodeQysgValue,
} from './QysgSourceCodec';

function value(object: Record<string, Object>, ...keys: string[]): string {
  for (const key of keys) {
    const item = object[key];
    if (item !== undefined && item !== null && String(item).trim()) return String(item);
  }
  return '';
}

function boolValue(object: Record<string, Object>, ...keys: string[]): boolean {
  for (const key of keys) {
    const item = object[key];
    if (item === true || item === 'true' || item === 1 || item === '1') return true;
  }
  return false;
}

export function mapQysgBook(raw: Object, source: BookSource): SearchResult {
  const item = (raw && typeof raw === 'object' ? raw : {}) as Record<string, Object>;
  const bookUrl = qysgAbsoluteUrl(source.sourceUrl, value(item, 'bookUrl', 'url', 'bookurl'));
  const contentType = qysgContentType(item['type'], source.sourceType);
  return {
    key: source.sourceUrl + '\n' + bookUrl,
    name: value(item, 'name', 'bookName', 'title'),
    author: value(item, 'author', 'writer'),
    coverUrl: qysgAbsoluteUrl(source.sourceUrl, value(item, 'coverUrl', 'cover', 'image')),
    noteUrl: bookUrl,
    origin: source.sourceName,
    originUrl: source.sourceUrl,
    kind: value(item, 'kind', 'category', 'typeName'),
    wordCount: value(item, 'wordCount', 'words'),
    lastUpdateTime: value(item, 'lastUpdateTime', 'updateTime', 'lastUpdate'),
    latestChapterTitle: value(item, 'latestChapterTitle', 'latestChapter', 'lastChapter'),
    introduce: value(item, 'intro', 'introduce', 'description'),
    helperMsg: '',
    duration: 0,
    searchTime: Date.now(),
    sourceCount: 1,
    sourceOrigins: [source.sourceName],
    sourceOriginUrls: [source.sourceUrl],
    sourceNoteUrls: [bookUrl],
    contentType: contentType,
  };
}

export function mapQysgBooks(raw: string, source: BookSource): SearchResult[] {
  return decodeQysgArray(raw)
    .map((item: Object): SearchResult => mapQysgBook(item, source))
    .filter((item: SearchResult): boolean => !!item.name && !!item.noteUrl);
}

export function mapQysgInfo(raw: string, source: BookSource, requestedUrl: string): BookSourceBookInfo {
  const item = decodeQysgObject(raw);
  const tocUrl = qysgAbsoluteUrl(source.sourceUrl, value(item, 'tocUrl', 'tocURL', 'chapterUrl')) || requestedUrl;
  const type = qysgContentType(item['type'], source.sourceType);
  const info: BookSourceBookInfo = {
    name: value(item, 'name', 'bookName', 'title'),
    author: value(item, 'author', 'writer'),
    coverUrl: qysgAbsoluteUrl(source.sourceUrl, value(item, 'coverUrl', 'cover', 'image')),
    introduce: value(item, 'intro', 'introduce', 'description'),
    kind: value(item, 'kind', 'category', 'typeName'),
    wordCount: value(item, 'wordCount', 'words'),
    lastUpdateTime: value(item, 'lastUpdateTime', 'updateTime', 'lastUpdate'),
    latestChapterTitle: value(item, 'latestChapterTitle', 'latestChapter', 'lastChapter'),
    tocUrl: tocUrl,
    contentType: type,
    chapters: [],
  };
  return info;
}

export function mapQysgChapters(raw: string, source: BookSource): BookSourceChapter[] {
  const mapped = decodeQysgArray(raw).map((value: Object, index: number): BookSourceChapter => {
    const item = (value && typeof value === 'object' ? value : {}) as Record<string, Object>;
    const itemIndex = Number(item['index']);
    return {
      title: valueOfChapter(item, 'name', 'title', 'chapterName') || ('第' + (index + 1) + '章'),
      url: qysgAbsoluteUrl(source.sourceUrl, valueOfChapter(item, 'chapterId', 'url', 'chapterUrl')),
      index: Number.isFinite(itemIndex) ? itemIndex : index,
      isVolume: boolValue(item, 'isVolume', 'volume'),
      isVip: boolValue(item, 'isVip', 'vip'),
      isPay: boolValue(item, 'isPay', 'pay'),
      updateTime: valueOfChapter(item, 'updateTime', 'lastUpdateTime'),
      tag: valueOfChapter(item, 'tag'),
    };
  }).filter((item: BookSourceChapter): boolean => !!item.url || !!item.isVolume);
  return normalizeQysgChapters(mapped);
}

/**
 * qysg 漫画源经常通过 WebView 扫描整页锚点。拷贝漫画等站点同时保留桌面、
 * 移动两份 DOM，并把“开始阅读/更新内容”快捷链接放在章节列表外，导致同一
 * chapterId 返回 2～3 次。它们不是不同章节，进入统一目录前应稳定去重并重排
 * index；否则阅读页会显示重复卷名、重复番外，且缓存会把错误目录持久化。
 */
export function normalizeQysgChapters(chapters: BookSourceChapter[]): BookSourceChapter[] {
  const seenUrls = new Set<string>();
  const result: BookSourceChapter[] = [];
  chapters.forEach((chapter: BookSourceChapter): void => {
    const title = (chapter.title || '').replace(/\s+/g, ' ').trim();
    // 这些是详情页快捷入口，不属于目录项；如果源确实将其作为章节返回，
    // 后续真实的同 URL 章节仍会被保留。
    if (/^(?:开始阅读|開始閱讀|更新内容|更新內容)$/i.test(title)) return;
    const url = (chapter.url || '').trim();
    if (url && seenUrls.has(url)) return;
    if (url) seenUrls.add(url);
    result.push({
      title: title || chapter.title || ('第' + (result.length + 1) + '章'),
      url: chapter.url,
      index: result.length,
      isVolume: chapter.isVolume,
      isVip: chapter.isVip,
      isPay: chapter.isPay,
      updateTime: chapter.updateTime,
      tag: chapter.tag,
    });
  });
  if (result.length !== chapters.length) {
    console.info('[QysgMapper] normalized chapters ' + chapters.length + ' -> ' + result.length);
  }
  return result;
}

function valueOfChapter(object: Record<string, Object>, ...keys: string[]): string {
  for (const key of keys) {
    if (object[key] !== undefined && object[key] !== null) return String(object[key]);
  }
  return '';
}

export function mapQysgContent(raw: string, source: BookSource, requestedUrl: string): {
  type: BookType;
  raw: string;
  baseUrl: string;
} {
  const decoded = decodeQysgValue(raw || '');
  let type: unknown = undefined;
  let content = '';
  if (typeof decoded === 'string') {
    content = decoded;
  } else if (decoded && typeof decoded === 'object' && !Array.isArray(decoded)) {
    const object = decoded as Record<string, Object>;
    type = object['type'];
    const value = object['content'] ?? object['data'] ?? object['text'] ?? object['url'];
    content = value === undefined || value === null ? '' : String(value);
  } else if (decoded !== undefined && decoded !== null) {
    content = String(decoded);
  }
  return {
    type: qysgContentType(type, source.sourceType) as BookType,
    raw: content,
    baseUrl: requestedUrl || source.sourceUrl,
  };
}
